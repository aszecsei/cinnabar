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
    public int ToolPointCount => Points?.Count ?? 0;

    // The Cut's or the Draw's points, while they are what mesh mode is in the middle of.
    MeshInteraction.ToolPoints? Points => _session.Interaction as MeshInteraction.ToolPoints;

    // The points on a mesh that a click adds to: those under way, or new ones, which first end what was under way, such
    // as a distance tool that waits. Null while a drag that the mouse holds is under way.
    MeshInteraction.ToolPoints.OnMesh? MeshPoints(string mesh) =>
        Points as MeshInteraction.ToolPoints.OnMesh ?? _session.Begin(() => new MeshInteraction.ToolPoints.OnMesh(mesh));

    // The same for the points of a Draw on the grid.
    MeshInteraction.ToolPoints.OnGrid? GridPoints() =>
        Points as MeshInteraction.ToolPoints.OnGrid ?? _session.Begin(() => new MeshInteraction.ToolPoints.OnGrid());

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
        _session.EndOpenEntry();
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
        if (_session.MeshTool == MeshTool.Draw && Points is MeshInteraction.ToolPoints.OnGrid)
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
            return _session.MeshTool == MeshTool.Draw && Points is not MeshInteraction.ToolPoints.OnMesh && AddPlanePoint(pixel);
        }
        var onMesh = Points as MeshInteraction.ToolPoints.OnMesh;
        if (onMesh != null && onMesh.Mesh != best)
        {
            _shell.Console.Add(LogLevel.Warning, "mesh: a cut's points are on one mesh");
            return true;
        }
        var data = _session.FindMeshData(best)!;
        var at = _session.PlacementOf(best)!;
        if (_session.MeshTool == MeshTool.Draw)
        {
            // Every corner is on the first click's face, where the ray meets its plane.
            var face = onMesh?.Points is [CutPoint.OnFace first, ..] ? first.Face
                : bestHit?.Face ?? (bestVertex is { } bv ? data.FacesOfVertex(bv)[0] : data.FacesOfEdge(data.Edges[bestEdge!.Value])[0]);
            var normal = at.NormalToView(data.FaceNormal(face));
            if (MeshGrid.HitPlane(at.ToView(data.Vertices[data.Faces[face].Corners[0]]), normal, ray) is not { } onPlane)
            {
                return true;
            }
            if (onMesh?.Points is { Count: >= 3 } drawn && _shell.Camera.Project(at.ToView(((CutPoint.OnFace)drawn[0]).Position), width, height) is { } start && (start - pixel).Length <= MeshPick.HitPixels)
            {
                ApplyToolPoints();
                return true;
            }
            CutPoint point = new CutPoint.OnFace(face, at.ToLocal(onPlane));
            return AddMeshPoint(best, point);
        }
        if (bestVertex is { } hitVertex)
        {
            return AddMeshPoint(best, new CutPoint.OnVertex(hitVertex));
        }
        if (bestEdge is { } hitEdge)
        {
            var e = data.Edges[hitEdge];
            return AddMeshPoint(best, new CutPoint.OnEdge(e.A, e.B, AlongRay(at.ToView(data.Vertices[e.A]), at.ToView(data.Vertices[e.B]), ray)));
        }
        if (bestHit is { } faceHit)
        {
            return AddMeshPoint(best, new CutPoint.OnFace(faceHit.Face, at.ToLocal(faceHit.Point)));
        }
        return true;
    }

    // Adds a point on a mesh to the Cut's or the Draw's points, and is false when none can start.
    bool AddMeshPoint(string mesh, CutPoint point)
    {
        if (MeshPoints(mesh) is not { } points)
        {
            return false;
        }
        points.Points.Add(point);
        _session.OnMeshModeChanged();
        return true;
    }

    // Where along a segment the camera's ray passes nearest, 0 at a and 1 at b.
    static double AlongRay(Vec3 a, Vec3 b, ViewRay ray)
    {
        var d = b - a;
        var along = ray.Direction;
        // The segment's start, from where the ray starts.
        var from = a - ray.Origin;
        var denominator = Vec3.Dot(d, d) - Vec3.Dot(d, along) * Vec3.Dot(d, along);
        if (denominator < 1e-12)
        {
            return 0;
        }
        return Math.Clamp((Vec3.Dot(from, along) * Vec3.Dot(d, along) - Vec3.Dot(from, d)) / denominator, 0, 1);
    }

    bool AddPlanePoint(Vec2 pixel)
    {
        var (origin, axis) = _session.GridPlane();
        var onGrid = Points as MeshInteraction.ToolPoints.OnGrid;
        if (onGrid?.Points is [var first, ..])
        {
            (origin, axis) = (first, MeshGrid.NearestAxis(_shell.Camera.Forward));
        }
        if (_session.PointOnGrid(pixel, origin, axis) is not { } point)
        {
            return false;
        }
        var (width, height) = _shell.FrameSize;
        if (onGrid?.Points is { Count: >= 3 } corners && _shell.Camera.Project(_shell.Camera.RelativeTo(corners[0]), width, height) is { } start && (start - pixel).Length <= MeshPick.HitPixels)
        {
            ApplyToolPoints();
            return true;
        }
        if (GridPoints() is not { } grid)
        {
            return false;
        }
        grid.Points.Add(point);
        _session.OnMeshModeChanged();
        return true;
    }

    /// <summary>
    /// Enter: applies the Cut or the Draw with its points, which ends them. What else is under way, such as a distance tool
    /// that waits, ends first, so its entry does not refuse the Cut or Draw.
    /// </summary>
    public void ApplyToolPoints()
    {
        if (_shell.Scene == null)
        {
            return;
        }
        _session.Settle();
    }

    // Applies a Cut's or a Draw's points, which are no longer under way: the end of the ToolPoints interaction that keeps
    // what it did.
    internal void Apply(MeshInteraction.ToolPoints toolPoints)
    {
        _loopPreview = null;
        if (_shell.Scene == null)
        {
            return;
        }
        if (toolPoints is MeshInteraction.ToolPoints.OnGrid onGrid)
        {
            var points = onGrid.Points.ToList();
            var axis = MeshGrid.NearestAxis(_shell.Camera.Forward);
            // The plane fronts toward the camera.
            var front = MeshGrid.AxisVector(axis) * (Vec3.Dot(MeshGrid.AxisVector(axis), _shell.Camera.Forward) > 0 ? -1 : 1);
            var data = MeshCut.Plane([.. points.Select(p => Vec3.Between(points[0], p))], front, _session.DefaultMeshMaterial, _session.Texture.NewFaceScale(_session.DefaultMeshMaterial));
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
        if (toolPoints is not MeshInteraction.ToolPoints.OnMesh { Mesh: var guid } onMesh || _session.FindMeshData(guid) is not { } mesh)
        {
            return;
        }
        var cutPoints = onMesh.Points.ToList();
        var tool = _session.MeshTool;
        ToolResult result;
        string? reason;
        if (tool == MeshTool.Draw)
        {
            if (cutPoints is not [CutPoint.OnFace first, ..])
            {
                return;
            }
            (result, reason) = MeshCut.Draw(mesh, first.Face, [.. cutPoints.OfType<CutPoint.OnFace>().Select(p => p.Position)]);
        }
        else
        {
            (result, reason) = MeshCut.Cut(mesh, cutPoints);
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
        IEnumerable<CutPoint> points = _loopPreview is { } preview && preview.Guid == guid ? preview.Points : Points is MeshInteraction.ToolPoints.OnMesh drawn && drawn.Mesh == guid ? drawn.Points : [];
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
        if (Points is not { } points)
        {
            return;
        }
        switch (points)
        {
        case MeshInteraction.ToolPoints.OnGrid { Points.Count: > 0 } grid:
            grid.Points.RemoveAt(grid.Points.Count - 1);
            break;
        case MeshInteraction.ToolPoints.OnMesh { Points.Count: > 0 } onMesh:
            onMesh.Points.RemoveAt(onMesh.Points.Count - 1);
            break;
        }
        // The last point gone, the Cut or the Draw is no longer under way.
        if (points.Count == 0)
        {
            _session.Cancel();
        }
        _session.OnMeshModeChanged();
    }

    /// <summary>Drops a Cut's or a Draw's points, and the loop that the mouse shows.</summary>
    public void CancelToolPoints()
    {
        _session.Cancel<MeshInteraction.ToolPoints>();
        _loopPreview = null;
        _session.OnMeshModeChanged();
    }
}
