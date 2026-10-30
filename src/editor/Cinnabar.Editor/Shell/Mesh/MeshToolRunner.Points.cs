using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Tools;
using GizmoKind = Cinnabar.Editor.Link.Protocol.GizmoKind;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The Cut and Draw tools: the edge under the mouse, the loop a Cut would make, and the points that a Cut or a Draw takes
/// from clicks until Enter.
/// </summary>
public sealed partial class MeshToolRunner
{
    /// <summary>The points a Draw has so far.</summary>
    public int ToolPointCount => _toolPoints.Count + _planePoints.Count;

    /// <summary>The edge of an edited mesh under a pixel, by its mesh and its index, with how far along it the mouse is, or null.</summary>
    (string Guid, int Edge, double T)? EdgeAt(Vec2 pixel)
    {
        var (width, height) = _shell.FrameSize;
        var ray = _shell.Camera.Ray(pixel, width, height);
        (string, int, double)? best = null;
        var bestDistance = double.MaxValue;
        foreach (var guid in _session.InMeshMode ? _session.EditedMeshes.Keys.ToList() : [])
        {
            if (_session.FindMeshData(guid) is not { } mesh || _session.PlacementOf(guid) is not { } placement)
            {
                continue;
            }
            var hit = MeshPick.Face(mesh, placement, ray, _session.SelectThrough);
            if (MeshPick.Edge(mesh, placement, _shell.Camera, pixel, width, height, hit?.Distance) is not { } edge)
            {
                continue;
            }
            var e = mesh.Edges[edge];
            var (a, b) = (placement.ToView(mesh.Vertices[e.A]), placement.ToView(mesh.Vertices[e.B]));
            var distance = hit?.Distance ?? Vec3.Dot(a, _shell.Camera.Forward);
            if (distance < bestDistance)
            {
                var t = AlongRay(a, b, ray);
                if (_shell.Snap)
                {
                    // The point along the edge nearest a grid point.
                    var snapped = _shell.Camera.RelativeTo(_session.SnapToGrid(a + (b - a) * t));
                    t = AlongSegment(a, b, snapped);
                }
                best = (guid, edge, t);
                bestDistance = distance;
            }
        }
        return best;
    }

    static double AlongSegment(Vec3 a, Vec3 b, Vec3 p)
    {
        var ab = b - a;
        var length = Vec3.Dot(ab, ab);
        return length < 1e-12 ? 0 : Math.Clamp(Vec3.Dot(p - a, ab) / length, 0, 1);
    }

    /// <summary>With the Cut tool, shows the loop that a click on the edge under the mouse would cut.</summary>
    public void HoverCut(Vec2 pixel)
    {
        if (_session.MeshTool != MeshTool.Cut || !_session.InMeshMode)
        {
            return;
        }
        (string, List<CutPoint.OnEdge>)? preview = null;
        if (EdgeAt(pixel) is var (guid, edge, t) && _session.FindMeshData(guid) is { } mesh)
        {
            preview = (guid, MeshCut.Loop(mesh, edge, t));
        }
        if (preview?.Item1 != _loopPreview?.Guid || !(preview?.Item2 ?? []).SequenceEqual(_loopPreview?.Points ?? []))
        {
            _loopPreview = preview;
            _session.SendMeshOverlay();
        }
    }

    /// <summary>A click with the Cut tool: a loop cut from the edge under it, at once.</summary>
    public bool CutAt(Vec2 pixel)
    {
        if (_session.MeshTool != MeshTool.Cut || !_session.InMeshMode || !_shell.IsEditing || _shell.Scene == null)
        {
            return false;
        }
        CommitPendingDistance();
        if (EdgeAt(pixel) is not var (guid, edge, t) || _session.FindMeshData(guid) is not { } mesh)
        {
            return true;
        }
        var (result, reason) = MeshCut.LoopCut(mesh, edge, t);
        if (reason != null)
        {
            _shell.Console.Add(LogLevel.Warning, $"mesh: {reason}");
            return true;
        }
        if (result.Mesh.Validate() is { Count: > 0 } problems)
        {
            _shell.Console.Add(LogLevel.Error, $"mesh: cannot cut: {string.Join("; ", problems)}");
            return true;
        }
        _loopPreview = null;
        if (_shell.Edit("Cut", new MeshOperation(guid, mesh, result.Mesh, _session.Meshes)))
        {
            _session.SetMeshSelection(new MeshSelection(result.Kind, [.. result.Selected.Select(i => new MeshItem(guid, i))]), switchKind: true);
        }
        return true;
    }

    /// <summary>
    /// A click with the Cut or Draw tool: a point on the edited mesh under it, on a vertex, an edge or a face, or for a
    /// Draw on nothing, a point on the grid. A Draw's click near its first corner closes it. Returns whether the click
    /// was taken.
    /// </summary>
    public bool AddToolPoint(Vec2 pixel)
    {
        if (_session.MeshTool == MeshTool.Cut)
        {
            return CutAt(pixel);
        }
        if (_session.MeshTool != MeshTool.Draw || !_shell.IsEditing || _shell.Scene == null)
        {
            return false;
        }
        var (width, height) = _shell.FrameSize;
        var ray = _shell.Camera.Ray(pixel, width, height);
        if (_session.MeshTool == MeshTool.Draw && _planePoints.Count > 0)
        {
            return AddPlanePoint(pixel);
        }
        // The nearest edited mesh under the click, and the element there: a face hit, or a vertex or an edge within
        // reach, which a click right on a box's edge may find without a face.
        string? best = null;
        FaceHit? bestHit = null;
        int? bestVertex = null;
        int? bestEdge = null;
        var bestDistance = double.MaxValue;
        foreach (var guid in _session.InMeshMode ? _session.EditedMeshes.Keys.ToList() : [])
        {
            if (_session.FindMeshData(guid) is not { } mesh || _session.PlacementOf(guid) is not { } placement)
            {
                continue;
            }
            var hit = MeshPick.Face(mesh, placement, ray, _session.SelectThrough);
            var vertex = MeshPick.Vertex(mesh, placement, _shell.Camera, pixel, width, height, hit?.Distance);
            var edge = vertex == null ? MeshPick.Edge(mesh, placement, _shell.Camera, pixel, width, height, hit?.Distance) : null;
            double? distance = hit?.Distance;
            if (distance == null && vertex is { } v)
            {
                distance = Vec3.Dot(placement.ToView(mesh.Vertices[v]), _shell.Camera.Forward);
            }
            if (distance == null && edge is { } e)
            {
                distance = Vec3.Dot(placement.ToView(mesh.Vertices[mesh.Edges[e].A]), _shell.Camera.Forward);
            }
            if (distance is { } d && d < bestDistance)
            {
                (best, bestHit, bestVertex, bestEdge, bestDistance) = (guid, hit, vertex, edge, d);
            }
        }
        if (best == null)
        {
            return _session.MeshTool == MeshTool.Draw && _toolPoints.Count == 0 && AddPlanePoint(pixel);
        }
        if (_toolMesh != null && _toolMesh != best)
        {
            _shell.Console.Add(LogLevel.Warning, "mesh: a cut's points are on one mesh");
            return true;
        }
        var data = _session.FindMeshData(best)!;
        var at = _session.PlacementOf(best)!;
        if (_session.MeshTool == MeshTool.Draw)
        {
            // Every corner is on the first click's face, where the ray meets its plane.
            var face = _toolPoints is [CutPoint.OnFace first, ..] ? first.Face
                : bestHit?.Face ?? (bestVertex is { } bv ? data.FacesOfVertex(bv)[0] : data.FacesOfEdge(data.Edges[bestEdge!.Value])[0]);
            var normal = at.NormalToView(data.FaceNormal(face));
            if (MeshGrid.HitPlane(at.ToView(data.Vertices[data.Faces[face].Corners[0]]), normal, ray) is not { } onPlane)
            {
                return true;
            }
            if (_toolPoints.Count >= 3 && _shell.Camera.Project(at.ToView(((CutPoint.OnFace)_toolPoints[0]).Position), width, height) is { } start && (start - pixel).Length <= MeshPick.HitPixels)
            {
                ApplyToolPoints();
                return true;
            }
            _toolPoints.Add(new CutPoint.OnFace(face, at.ToLocal(onPlane)));
        }
        else if (bestVertex is { } vertex)
        {
            _toolPoints.Add(new CutPoint.OnVertex(vertex));
        }
        else if (bestEdge is { } edge)
        {
            var e = data.Edges[edge];
            _toolPoints.Add(new CutPoint.OnEdge(e.A, e.B, AlongRay(at.ToView(data.Vertices[e.A]), at.ToView(data.Vertices[e.B]), ray)));
        }
        else if (bestHit is { } faceHit)
        {
            _toolPoints.Add(new CutPoint.OnFace(faceHit.Face, at.ToLocal(faceHit.Point)));
        }
        _toolMesh = best;
        _session.OnMeshModeChanged();
        return true;
    }

    // Where along a segment the camera's ray passes nearest, 0 at a and 1 at b.
    static double AlongRay(Vec3 a, Vec3 b, Vec3 ray)
    {
        var d = b - a;
        var denominator = Vec3.Dot(d, d) - Vec3.Dot(d, ray) * Vec3.Dot(d, ray);
        if (denominator < 1e-12)
        {
            return 0;
        }
        return Math.Clamp((Vec3.Dot(a, ray) * Vec3.Dot(d, ray) - Vec3.Dot(a, d)) / denominator, 0, 1);
    }

    bool AddPlanePoint(Vec2 pixel)
    {
        var (origin, axis) = _session.GridPlane();
        if (_planePoints.Count > 0)
        {
            (origin, axis) = (_planePoints[0], MeshGrid.NearestAxis(_shell.Camera.Forward));
        }
        if (_session.PointOnGrid(pixel, origin, axis) is not { } point)
        {
            return false;
        }
        var (width, height) = _shell.FrameSize;
        if (_planePoints.Count >= 3 && _shell.Camera.Project(_shell.Camera.RelativeTo(_planePoints[0]), width, height) is { } start && (start - pixel).Length <= MeshPick.HitPixels)
        {
            ApplyToolPoints();
            return true;
        }
        _planePoints.Add(point);
        _session.OnMeshModeChanged();
        return true;
    }

    /// <summary>Enter: applies the Cut or the Draw with its points.</summary>
    public void ApplyToolPoints()
    {
        if (_shell.Scene == null)
        {
            return;
        }
        if (_planePoints.Count > 0)
        {
            var points = _planePoints.ToList();
            var axis = MeshGrid.NearestAxis(_shell.Camera.Forward);
            // The plane fronts toward the camera.
            var front = MeshGrid.AxisVector(axis) * (Vec3.Dot(MeshGrid.AxisVector(axis), _shell.Camera.Forward) > 0 ? -1 : 1);
            var data = MeshCut.Plane([.. points.Select(p => Vec3.Between(points[0], p))], front, _session.DefaultMeshMaterial, _session.Texture.NewFaceScale(_session.DefaultMeshMaterial));
            CancelToolPoints();
            if (data == null)
            {
                _shell.Console.Add(LogLevel.Warning, "mesh: a polygon has three or more corners and does not cross itself");
                return;
            }
            var (create, document) = NewMeshEntity(_session.NewMeshName("plane"), data, new Pose(points[0], Quat.Identity, [1, 1, 1]), []);
            if (_shell.Edit("Draw", new CreateMesh(document, _session.Meshes), create))
            {
                _shell.SelectScene(create.Created.Id);
            }
            return;
        }
        if (_toolMesh is not { } guid || _session.FindMeshData(guid) is not { } mesh)
        {
            CancelToolPoints();
            return;
        }
        var toolPoints = _toolPoints.ToList();
        var tool = _session.MeshTool;
        CancelToolPoints();
        ToolResult result;
        string? reason;
        if (tool == MeshTool.Draw)
        {
            if (toolPoints is not [CutPoint.OnFace first, ..])
            {
                return;
            }
            (result, reason) = MeshCut.Draw(mesh, first.Face, [.. toolPoints.OfType<CutPoint.OnFace>().Select(p => p.Position)]);
        }
        else
        {
            (result, reason) = MeshCut.Cut(mesh, toolPoints);
        }
        if (reason != null)
        {
            _shell.Console.Add(LogLevel.Warning, $"mesh: {reason}");
            return;
        }
        if (result.Mesh.Validate() is { Count: > 0 } problems)
        {
            _shell.Console.Add(LogLevel.Error, $"mesh: cannot {tool.ToString().ToLowerInvariant()}: {string.Join("; ", problems)}");
            return;
        }
        if (_shell.Edit(tool.ToString(), new MeshOperation(guid, mesh, result.Mesh, _session.Meshes)))
        {
            _session.SetMeshSelection(new MeshSelection(result.Kind, [.. result.Selected.Select(i => new MeshItem(guid, i))]), switchKind: true);
        }
    }

    // The points of a Draw on a mesh, or of the loop a Cut would make, as the overlay marks them: x, y, z each, in
    // the mesh's space.
    internal float[] ToolMarks(string guid, MeshData mesh)
    {
        IEnumerable<CutPoint> points = _loopPreview is { } preview && preview.Guid == guid ? preview.Points : _toolMesh == guid ? _toolPoints : [];
        var marks = new List<float>();
        foreach (var point in points)
        {
            Vec3? position = point switch
            {
                CutPoint.OnVertex v when v.Vertex < mesh.Vertices.Length => mesh.Vertices[v.Vertex],
                CutPoint.OnEdge e when e.A < mesh.Vertices.Length && e.B < mesh.Vertices.Length => mesh.Vertices[e.A] + (mesh.Vertices[e.B] - mesh.Vertices[e.A]) * e.T,
                CutPoint.OnFace f => f.Position,
                _ => null,
            };
            if (position is { } p)
            {
                marks.AddRange([(float)p.X, (float)p.Y, (float)p.Z]);
            }
        }
        return [.. marks];
    }

    /// <summary>Backspace: drops the last point.</summary>
    public void RemoveLastToolPoint()
    {
        if (_planePoints.Count > 0)
        {
            _planePoints.RemoveAt(_planePoints.Count - 1);
        }
        else if (_toolPoints.Count > 0)
        {
            _toolPoints.RemoveAt(_toolPoints.Count - 1);
            if (_toolPoints.Count == 0)
            {
                _toolMesh = null;
            }
        }
        _session.OnMeshModeChanged();
    }

    public void CancelToolPoints()
    {
        _toolPoints.Clear();
        _planePoints.Clear();
        _toolMesh = null;
        _loopPreview = null;
        _session.OnMeshModeChanged();
    }
}
