using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Tools;
using GizmoKind = Cinnabar.Editor.Link.Protocol.GizmoKind;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The mesh tools in the shell (see docs/editor/mesh-editing.md#mesh-tools): each runs on the sub-selection of every
/// edited mesh as one undo entry. A tool with a distance, such as Extrude, opens the entry and waits for a drag of the
/// gizmo, whose steps set the distance and replace each other; releasing commits and Escape cancels. Cut and Draw are
/// tool modes that take points from clicks until Enter. Detach and Extract make a new mesh and entity, and the
/// primitives fill a dragged rectangle, with parameters that stay editable until the next edit.
/// </summary>
public sealed partial class EditorShell
{
    // A tool whose distance the next gizmo drag sets, with its undo entry open: each mesh's snapshot and selection from
    // before it ran, and how to run it at a distance.
    sealed record PendingDistance(string Label, Vec3 Axis, bool Magnitude, Dictionary<string, (MeshData Start, IReadOnlyList<int> Selected)> Meshes,
        Func<MeshData, IEnumerable<int>, double, ToolResult> Run);

    // What the last primitive was made from, so a parameter change makes it again in place of the same undo entry.
    sealed record LastPrimitive(int Position, long[] Corner, Vec3 Size, int Axis, string? Mesh);

    PendingDistance? _pending;
    // The loop that the Cut tool would make from the edge under the mouse: its mesh and its points.
    (string Guid, List<CutPoint.OnEdge> Points)? _loopPreview;
    readonly List<CutPoint> _toolPoints = [];
    string? _toolMesh;
    readonly List<long[]> _planePoints = [];
    LastPrimitive? _lastPrimitive;

    /// <summary>A tool ran and waits for a drag of the gizmo to set its distance.</summary>
    public bool HasPendingDistance => _pending != null;

    /// <summary>The angle that Recalculate Normals marks edges sharp beyond, in degrees.</summary>
    public double NormalAngle { get; private set; } = 30;

    public int BevelSegments { get; private set; } = 1;

    /// <summary>The primitive that the Create tool makes.</summary>
    public PrimitiveKind Primitive { get; private set; } = PrimitiveKind.Block;

    public PrimitiveParameters PrimitiveParameters { get; private set; } = PrimitiveParameters.Default;

    /// <summary>The points a Draw has so far.</summary>
    public int ToolPointCount => _toolPoints.Count + _planePoints.Count;

    /// <summary>The edge of an edited mesh under a pixel, by its mesh and its index, with how far along it the mouse is, or null.</summary>
    (string Guid, int Edge, double T)? EdgeAt(Vec2 pixel)
    {
        var (width, height) = FrameSize;
        var ray = Camera.Ray(pixel, width, height);
        (string, int, double)? best = null;
        var bestDistance = double.MaxValue;
        foreach (var guid in InMeshMode ? _editedMeshes.Keys.ToList() : [])
        {
            if (FindMeshData(guid) is not { } mesh || PlacementOf(guid) is not { } placement)
            {
                continue;
            }
            var hit = MeshPick.Face(mesh, placement, ray, SelectThrough);
            if (MeshPick.Edge(mesh, placement, Camera, pixel, width, height, hit?.Distance) is not { } edge)
            {
                continue;
            }
            var e = mesh.Edges[edge];
            var (a, b) = (placement.ToView(mesh.Vertices[e.A]), placement.ToView(mesh.Vertices[e.B]));
            var distance = hit?.Distance ?? Vec3.Dot(a, Camera.Forward);
            if (distance < bestDistance)
            {
                var t = AlongRay(a, b, ray);
                if (Snap)
                {
                    // The point along the edge nearest a grid point.
                    var snapped = Camera.RelativeTo(SnapToGrid(a + (b - a) * t));
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
        if (MeshTool != MeshTool.Cut || !InMeshMode)
        {
            return;
        }
        (string, List<CutPoint.OnEdge>)? preview = null;
        if (EdgeAt(pixel) is var (guid, edge, t) && FindMeshData(guid) is { } mesh)
        {
            preview = (guid, MeshCut.Loop(mesh, edge, t));
        }
        if (preview?.Item1 != _loopPreview?.Guid || !(preview?.Item2 ?? []).SequenceEqual(_loopPreview?.Points ?? []))
        {
            _loopPreview = preview;
            SendMeshOverlay();
        }
    }

    /// <summary>A click with the Cut tool: a loop cut from the edge under it, at once.</summary>
    public bool CutAt(Vec2 pixel)
    {
        if (MeshTool != MeshTool.Cut || !InMeshMode || !IsEditing || Scene == null)
        {
            return false;
        }
        CommitPendingDistance();
        if (EdgeAt(pixel) is not var (guid, edge, t) || FindMeshData(guid) is not { } mesh)
        {
            return true;
        }
        var (result, reason) = MeshCut.LoopCut(mesh, edge, t);
        if (reason != null)
        {
            Console.Add(LogLevel.Warning, $"mesh: {reason}");
            return true;
        }
        if (result.Mesh.Validate() is { Count: > 0 } problems)
        {
            Console.Add(LogLevel.Error, $"mesh: cannot cut: {string.Join("; ", problems)}");
            return true;
        }
        _loopPreview = null;
        if (Edit("Cut", new MeshOperation(guid, mesh, result.Mesh, Meshes)))
        {
            SetMeshSelection(new MeshSelection(result.Kind, [.. result.Selected.Select(i => new MeshItem(guid, i))]), switchKind: true);
        }
        return true;
    }

    public static readonly IReadOnlyList<string> NormalAngles = ["15", "30", "45", "60", "90"];
    public static readonly IReadOnlyList<string> BevelSegmentOptions = ["1", "2", "3", "4", "6", "8"];
    public static readonly IReadOnlyList<string> SideOptions = ["3", "4", "5", "6", "8", "12", "16", "24", "32", "48", "64"];
    public static readonly IReadOnlyList<string> SegmentOptions = ["8", "12", "16", "24", "32", "48", "64"];
    public static readonly IReadOnlyList<string> RingOptions = ["4", "6", "8", "12", "16", "24", "32"];
    public static readonly IReadOnlyList<string> StepOptions = ["2", "3", "4", "6", "8", "10", "12", "16"];
    public static readonly IReadOnlyList<string> ArcOptions = ["90", "120", "180", "270", "360"];
    public static readonly IReadOnlyList<string> ThicknessOptions = ["0.0625", "0.125", "0.25", "0.5", "1"];
    public static readonly IReadOnlyList<string> TubeOptions = ["0.0625", "0.125", "0.25", "0.5"];

    /// <summary>Whether a tool of an element kind can run now: mesh mode, with that kind selected.</summary>
    public bool CanRunMeshTool(MeshElement? kind = null) =>
        CanEditInMeshMode && !MeshSelection.IsEmpty && (kind == null || MeshElement == kind);

    /// <summary>
    /// Runs a tool on the selected elements of each edited mesh, as one undo entry, and selects what it leaves. A
    /// result that fails validation is refused with the reason in the console, and nothing changes.
    /// </summary>
    public bool RunMeshTool(string label, Func<MeshData, IEnumerable<int>, ToolResult> run, MeshElement? requires = null)
    {
        CommitPendingDistance();
        if (!CanRunMeshTool(requires) || Scene == null)
        {
            return false;
        }
        var ops = new List<Operation>();
        var items = new List<MeshItem>();
        MeshElement? kind = null;
        foreach (var guid in MeshSelection.Guids)
        {
            if (FindMeshData(guid) is not { } mesh)
            {
                continue;
            }
            var result = run(mesh, MeshSelection.Of(guid));
            if (result.Mesh.Validate() is { Count: > 0 } problems)
            {
                Console.Add(LogLevel.Error, $"mesh: cannot {label.ToLowerInvariant()}: {string.Join("; ", problems)}");
                return false;
            }
            if (!ReferenceEquals(result.Mesh, mesh))
            {
                ops.Add(new MeshOperation(guid, mesh, result.Mesh, Meshes));
            }
            kind = result.Kind;
            items.AddRange(result.Selected.Select(i => new MeshItem(guid, i)));
        }
        if (ops.Count == 0)
        {
            Console.Add(LogLevel.Info, $"mesh: {label.ToLowerInvariant()} changed nothing");
            return false;
        }
        if (!Edit(label, [.. ops]))
        {
            return false;
        }
        SetMeshSelection(new MeshSelection(kind ?? MeshElement, [.. items]), switchKind: true);
        return true;
    }

    /// <summary>Acts on the whole of each edited mesh, as Clean and Recalculate Normals do without a selection.</summary>
    public bool RunWholeMeshTool(string label, Func<MeshData, (MeshData Mesh, IReadOnlyList<string> Problems)> run)
    {
        CommitPendingDistance();
        if (!InMeshMode || !IsEditing || Scene == null)
        {
            return false;
        }
        var ops = new List<Operation>();
        foreach (var (guid, _) in _editedMeshes)
        {
            if (FindMeshData(guid) is not { } mesh)
            {
                continue;
            }
            var (result, problems) = run(mesh);
            foreach (var p in problems)
            {
                Console.Add(LogLevel.Warning, $"mesh: {Meshes.Find(guid)?.Title}: {p}");
            }
            if (!ReferenceEquals(result, mesh) && !result.Faces.SequenceEqual(mesh.Faces))
            {
                ops.Add(new MeshOperation(guid, mesh, result, Meshes));
            }
            else if (!ReferenceEquals(result, mesh))
            {
                ops.Add(new MeshOperation(guid, mesh, result, Meshes));
            }
        }
        if (ops.Count == 0)
        {
            Console.Add(LogLevel.Info, $"mesh: {label.ToLowerInvariant()} changed nothing");
            return false;
        }
        var ok = Edit(label, [.. ops]);
        if (ok)
        {
            SetMeshSelection(MeshSelection.Pruned(FindMeshData));
        }
        return ok;
    }

    /// <summary>
    /// Runs a tool that takes a distance: it opens the undo entry and waits for a drag of the gizmo, whose steps run
    /// the tool at the distance along the selection's normal, or by the drag's length for a width. Until the drag,
    /// nothing changes, and an entry without a drag leaves no history.
    /// </summary>
    public bool BeginDistanceTool(string label, Func<MeshData, IEnumerable<int>, double, ToolResult> run, bool magnitude = false, MeshElement? requires = null)
    {
        CommitPendingDistance();
        if (!CanRunMeshTool(requires) || Scene is not { InTransaction: false })
        {
            return false;
        }
        var meshes = new Dictionary<string, (MeshData, IReadOnlyList<int>)>();
        var axis = Vec3.Zero;
        foreach (var guid in MeshSelection.Guids)
        {
            if (FindMeshData(guid) is not { } mesh || PlacementOf(guid) is not { } placement)
            {
                continue;
            }
            var selected = MeshSelection.Of(guid).ToList();
            meshes[guid] = (mesh, selected);
            foreach (var v in MeshSelection.VerticesOf(mesh, selected))
            {
                foreach (var f in mesh.FacesOfVertex(v))
                {
                    axis += placement.NormalToView(mesh.FaceNormal(f));
                }
            }
        }
        if (meshes.Count == 0)
        {
            return false;
        }
        axis = axis.Length > 1e-9 ? axis.Normalized() : Vec3.UnitY;
        BeginEdit(label);
        _pending = new PendingDistance(label, axis, magnitude, meshes, run);
        OnMeshModeChanged();
        Console.Add(LogLevel.Info, $"mesh: {label.ToLowerInvariant()}: drag the gizmo for the {(magnitude ? "width" : "distance")}, or Escape");
        return true;
    }

    /// <summary>Ends a pending distance tool as it is: with its drag's last distance, or with no entry when nothing was dragged.</summary>
    public void CommitPendingDistance()
    {
        if (_pending == null)
        {
            return;
        }
        _pending = null;
        if (!_gizmo.IsDragging)
        {
            CommitEdit();
        }
        OnMeshModeChanged();
    }

    /// <summary>Cancels a pending distance tool: the mesh is as before it.</summary>
    public void CancelPendingDistance()
    {
        if (_pending == null)
        {
            return;
        }
        _pending = null;
        _gizmo.Drop();
        CancelEdit();
        MeshSelection = MeshSelection.Pruned(FindMeshData);
        SendGizmo();
        OnMeshModeChanged();
    }

    /// <summary>The gizmo while a distance is pending: Move, whatever the tool.</summary>
    GizmoKind ActiveGizmoKind => InMeshMode && (_pending != null || EditPivot) ? GizmoKind.Translate : Gizmo.KindOf(Tool);

    // A gizmo drag with a distance pending: each step runs the tool at the change along the axis, or its length, on
    // every mesh, replacing the step before. Releasing ends the tool; one that ended during the drag ignores it.
    sealed class DistanceDrag(EditorShell shell) : IGizmoTarget
    {
        MeshElement? _kind;
        List<MeshItem> _items = [];
        bool _pending;

        public IReadOnlyList<Operation> Drag(GizmoDrag drag, Vec2 pixel, bool snap)
        {
            if (shell._pending is not { } pending)
            {
                return [];
            }
            var change = drag.Update(pixel, null);
            var distance = pending.Magnitude ? change.Translation.Length : Vec3.Dot(change.Translation, pending.Axis);
            if (snap)
            {
                distance = Math.Round(distance / shell.GridSize) * shell.GridSize;
            }
            var ops = new List<Operation>();
            (_kind, _items) = (null, []);
            foreach (var (guid, (start, selected)) in pending.Meshes)
            {
                var result = pending.Run(start, selected, distance);
                ops.Add(new MeshOperation(guid, shell.FindMeshData(guid) ?? start, result.Mesh, shell.Meshes));
                _kind = result.Kind;
                _items.AddRange(result.Selected.Select(i => new MeshItem(guid, i)));
            }
            return ops;
        }

        public void Previewed()
        {
            shell.MeshElement = _kind ?? shell.MeshElement;
            shell.MeshSelection = new MeshSelection(shell.MeshElement, [.. _items]);
            shell.SendMeshOverlay();
        }

        public void Ending()
        {
            _pending = shell._pending != null;
            shell._pending = null;
        }

        public void Ended(bool committed)
        {
            if (!_pending)
            {
                return;
            }
            if (!committed)
            {
                shell.MeshSelection = shell.MeshSelection.Pruned(shell.FindMeshData);
            }
            shell.OnMeshModeChanged();
        }
    }

    public void SetNormalAngle(double degrees)
    {
        NormalAngle = Math.Clamp(degrees, 1, 180);
        OnMeshModeChanged();
    }

    public void SetBevelSegments(int segments)
    {
        BevelSegments = Math.Clamp(segments, 1, 16);
        OnMeshModeChanged();
    }

    /// <summary>Extrude: faces out along their average normal with walls, or open edges out as quads, by a dragged distance.</summary>
    public bool Extrude() => MeshElement switch
    {
        MeshElement.Faces => BeginDistanceTool("Extrude", (m, s, d) => MeshTools.Extrude(m, s, d, ScaleForFaces(m, s)), requires: MeshElement.Faces),
        MeshElement.Edges => BeginDistanceTool("Extrude", (m, s, d) => MeshTools.ExtrudeEdges(m, s, d, ScaleForEdges(m, s)), requires: MeshElement.Edges),
        _ => false,
    };

    public bool PushPull() => BeginDistanceTool("Push/Pull", (m, s, d) => MeshTools.PushPull(m, s, d), requires: MeshElement.Faces);

    public bool Offset() => BeginDistanceTool("Offset", (m, s, d) => MeshTools.Offset(m, s, d), requires: MeshElement.Faces);

    public bool Inset() => BeginDistanceTool("Inset", (m, s, d) => MeshTools.Inset(m, s, Math.Abs(d)), magnitude: true, requires: MeshElement.Faces);

    public bool Outset() => BeginDistanceTool("Outset", (m, s, d) => MeshTools.Inset(m, s, -Math.Abs(d)), magnitude: true, requires: MeshElement.Faces);

    public bool Bevel() => MeshElement switch
    {
        MeshElement.Vertices => BeginDistanceTool("Bevel", (m, s, d) => MeshBevel.Vertices(m, s, Math.Abs(d)), magnitude: true, requires: MeshElement.Vertices),
        MeshElement.Edges => BeginDistanceTool("Bevel", (m, s, d) => MeshBevel.Edges(m, s, Math.Abs(d), BevelSegments), magnitude: true, requires: MeshElement.Edges),
        _ => false,
    };

    public bool DuplicateFaces() => RunMeshTool("Duplicate", MeshTools.Duplicate, MeshElement.Faces);

    public bool Collapse() => RunMeshTool("Collapse", (m, s) => MeshTools.Collapse(m, MeshElement, s));

    public bool MergeFaces() => RunMeshTool("Merge Faces", MeshTools.MergeFaces, MeshElement.Faces);

    public bool InvertFaces() => RunMeshTool("Invert", MeshTools.Invert, MeshElement.Faces);

    /// <summary>Recalculate Normals: on the selected faces, or on the whole mesh with none selected.</summary>
    public bool RecalculateNormals() => CanRunMeshTool(MeshElement.Faces)
        ? RunMeshTool("Recalculate Normals", (m, s) => new ToolResult(MeshTools.RecalculateNormals(m, NormalAngle, s), MeshElement.Faces, [.. s]), MeshElement.Faces)
        : RunWholeMeshTool("Recalculate Normals", m => (MeshTools.RecalculateNormals(m, NormalAngle), []));

    /// <summary>Clean, whose report is the edges with more than two faces: they are selected, in the Edges kind, so they can be found.</summary>
    public bool Clean()
    {
        var cleaned = RunWholeMeshTool("Clean", MeshTools.Clean);
        var reported = new List<MeshItem>();
        foreach (var guid in _editedMeshes.Keys)
        {
            if (FindMeshData(guid) is { } mesh)
            {
                reported.AddRange(Enumerable.Range(0, mesh.Edges.Length).Where(e => mesh.FacesOfEdge(mesh.Edges[e]).Count > 2).Select(e => new MeshItem(guid, e)));
            }
        }
        if (reported.Count > 0)
        {
            SetMeshSelection(new MeshSelection(MeshElement.Edges, [.. reported]), switchKind: true);
            Console.Add(LogLevel.Warning, $"mesh: clean: {reported.Count} {(reported.Count == 1 ? "edge has" : "edges have")} more than two faces, and {(reported.Count == 1 ? "is" : "are")} selected");
        }
        return cleaned;
    }

    /// <summary>
    /// Detach moves the selected faces into a new mesh asset and entity at the first source's pose, as Extract copies
    /// them. Faces of several meshes go into one, in the first mesh's space.
    /// </summary>
    public bool Detach(bool keepSource)
    {
        CommitPendingDistance();
        if (!CanRunMeshTool(MeshElement.Faces) || Scene == null)
        {
            return false;
        }
        var guids = MeshSelection.Guids.Where(g => FindMeshData(g) != null && PlacementOf(g) != null).ToList();
        if (guids.Count == 0 || Scene.Expanded.Flat.Find(_editedMeshes[guids[0]]) is not { } source || SceneEdits.WorldPose(Scene.Expanded.Flat, source) is not { } pose)
        {
            return false;
        }
        var first = PlacementOf(guids[0])!;
        MeshData? combined = null;
        var ops = new List<Operation>();
        foreach (var guid in guids)
        {
            var mesh = FindMeshData(guid)!;
            var placement = PlacementOf(guid)!;
            var (extracted, remaining) = MeshTools.Split(mesh, MeshSelection.Of(guid));
            if (extracted.Faces.Length == 0)
            {
                continue;
            }
            var inFirst = guid == guids[0] ? extracted : extracted.With(vertices: extracted.Vertices.Select(v => first.ToLocal(placement.ToView(v))));
            combined = combined == null ? inFirst : Append(combined, inFirst);
            if (!keepSource)
            {
                ops.Add(new MeshOperation(guid, mesh, remaining, Meshes));
            }
        }
        if (combined == null)
        {
            return false;
        }
        var label = keepSource ? "Extract" : "Detach";
        var name = NewMeshName(label.ToLowerInvariant());
        var renderer = source.Components.Find(c => c.Id == SceneEdits.MeshRendererId);
        var (create, document) = NewMeshEntity(name, combined, pose, renderer?.Fields.Where(f => f.Name.StartsWith("materials.", StringComparison.Ordinal)).ToList() ?? []);
        if (!Edit(label, [new CreateMesh(document, Meshes), create, .. ops]))
        {
            return false;
        }
        _editedMeshes[document.Guid] = create.Created.Id;
        SetMeshSelection(new MeshSelection(MeshElement.Faces, [.. Enumerable.Range(0, combined.Faces.Length).Select(i => new MeshItem(document.Guid, i))]));
        return true;
    }

    // A mesh's faces appended to another, with their vertices and sharp edges, in the other's space already.
    static MeshData Append(MeshData to, MeshData from)
    {
        var offset = to.Vertices.Length;
        return to.With(
            vertices: to.Vertices.AddRange(from.Vertices),
            faces: to.Faces.AddRange(from.Faces.Select(f => f with { Corners = [.. f.Corners.Select(c => c + offset)] })),
            sharpEdges: to.SharpEdges.AddRange(from.SharpEdges.Select(e => new MeshEdge(e.A + offset, e.B + offset))));
    }

    // A new mesh document beside the scene and the entity that places it, at a pose, with material fields given.
    (CreateEntity Create, MeshDocument Document) NewMeshEntity(string name, MeshData data, Pose pose, IReadOnlyList<SceneField> materials)
    {
        var guid = Convert.ToHexStringLower(Guid.NewGuid().ToByteArray());
        var directory = Path.Combine(Path.GetDirectoryName(Scene!.Path)!, $"{Path.GetFileNameWithoutExtension(Scene.Path)}_meshes");
        var document = new MeshDocument(Path.Combine(directory, name + MeshFile.Extension), guid, data, saved: false);
        var create = SceneEdits.NewEntity(Scene.Expanded.Flat, pose.Position);
        create.Created.Name = name;
        create.Created.Components[0] = new SceneComponent(SceneEdits.TransformId, "Transform", SceneEdits.TransformFields(pose));
        var fields = new List<SceneField> { new("mesh", SceneValue.AssetRef(guid)) };
        fields.AddRange(materials.Count > 0 ? materials : [new SceneField("materials.0", SceneValue.AssetRef(DefaultMeshMaterial))]);
        fields.Add(new SceneField("cast_shadows", SceneValue.Of(true)));
        create.Created.Components.Add(new SceneComponent(SceneEdits.MeshRendererId, "Mesh_Renderer", fields));
        return (create, document);
    }

    /// <summary>Picks the primitive that the Create tool makes, and turns the tool on.</summary>
    public void SetPrimitive(PrimitiveKind kind)
    {
        Primitive = kind;
        if (MeshTool != MeshTool.Create)
        {
            SetMeshTool(MeshTool.Create);
        }
        OnMeshModeChanged();
    }

    /// <summary>
    /// Changes the primitives' parameters. The last primitive made, if it is the last edit, is made again with them in
    /// place of its undo entry, so the sides can be set after seeing the cylinder.
    /// </summary>
    public void SetPrimitiveParameters(PrimitiveParameters parameters)
    {
        PrimitiveParameters = parameters;
        if (_lastPrimitive is { } last && CanRemakePrimitive(last))
        {
            // The remake's own undo fires selection and mesh events, which must not forget the primitive.
            _remaking = true;
            try
            {
                Scene!.Undo();
                MakePrimitive(last.Corner, last.Size, last.Axis, last.Mesh);
            }
            finally
            {
                _remaking = false;
            }
        }
        OnMeshModeChanged();
    }

    bool _remaking;

    // The last primitive's entry is the last edit, and nothing is open.
    bool CanRemakePrimitive(LastPrimitive last) =>
        Scene != null && !Scene.InTransaction && Scene.Position == last.Position && Scene.History.Count == last.Position;

    // The primitive filling a box, as faces of an edited mesh or as a new mesh and entity.
    void MakePrimitive(long[] corner, Vec3 size, int axis, string? mesh)
    {
        if (Scene == null)
        {
            return;
        }
        // The entry goes where the position is: a remake has undone the entry before, which the new one replaces.
        var position = Scene.Position;
        if (mesh != null && FindMeshData(mesh) is { } data && PlacementOf(mesh) is { } placement)
        {
            var made = Primitives.Make(Primitive, Vec3.Zero, size, axis, PrimitiveParameters, NewFaceScale(data.Materials[0]), data.Materials[0]);
            var cornerRelative = Camera.RelativeTo(corner);
            var local = made.With(vertices: made.Vertices.Select(v => placement.ToLocal(cornerRelative + v)));
            var after = Append(data, local);
            if (Edit(Primitive.ToString(), new MeshOperation(mesh, data, after, Meshes)))
            {
                SetMeshSelection(new MeshSelection(MeshElement.Faces, [.. Enumerable.Range(data.Faces.Length, made.Faces.Length).Select(i => new MeshItem(mesh, i))]));
                _lastPrimitive = new LastPrimitive(position + 1, corner, size, axis, mesh);
            }
            return;
        }
        var block = Primitives.Make(Primitive, Vec3.Zero, size, axis, PrimitiveParameters, NewFaceScale(DefaultMeshMaterial), DefaultMeshMaterial);
        var name = NewMeshName(Primitive.ToString().ToLowerInvariant());
        var (create, document) = NewMeshEntity(name, block, new Pose(corner, Quat.Identity, [1, 1, 1]), []);
        if (!Edit(Primitive.ToString(), new CreateMesh(document, Meshes), create))
        {
            return;
        }
        _lastPrimitive = new LastPrimitive(position + 1, corner, size, axis, null);
        SelectScene(create.Created.Id);
        if (InMeshMode)
        {
            _editedMeshes[document.Guid] = create.Created.Id;
            SetMeshSelection(new MeshSelection(MeshElement.Faces, [.. Enumerable.Range(0, block.Faces.Length).Select(i => new MeshItem(document.Guid, i))]));
        }
    }

    /// <summary>
    /// A click with the Cut or Draw tool: a point on the edited mesh under it, on a vertex, an edge or a face, or for a
    /// Draw on nothing, a point on the grid. A Draw's click near its first corner closes it. Returns whether the click
    /// was taken.
    /// </summary>
    public bool AddToolPoint(Vec2 pixel)
    {
        if (MeshTool == MeshTool.Cut)
        {
            return CutAt(pixel);
        }
        if (MeshTool != MeshTool.Draw || !IsEditing || Scene == null)
        {
            return false;
        }
        var (width, height) = FrameSize;
        var ray = Camera.Ray(pixel, width, height);
        if (MeshTool == MeshTool.Draw && _planePoints.Count > 0)
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
        foreach (var guid in InMeshMode ? _editedMeshes.Keys.ToList() : [])
        {
            if (FindMeshData(guid) is not { } mesh || PlacementOf(guid) is not { } placement)
            {
                continue;
            }
            var hit = MeshPick.Face(mesh, placement, ray, SelectThrough);
            var vertex = MeshPick.Vertex(mesh, placement, Camera, pixel, width, height, hit?.Distance);
            var edge = vertex == null ? MeshPick.Edge(mesh, placement, Camera, pixel, width, height, hit?.Distance) : null;
            double? distance = hit?.Distance;
            if (distance == null && vertex is { } v)
            {
                distance = Vec3.Dot(placement.ToView(mesh.Vertices[v]), Camera.Forward);
            }
            if (distance == null && edge is { } e)
            {
                distance = Vec3.Dot(placement.ToView(mesh.Vertices[mesh.Edges[e].A]), Camera.Forward);
            }
            if (distance is { } d && d < bestDistance)
            {
                (best, bestHit, bestVertex, bestEdge, bestDistance) = (guid, hit, vertex, edge, d);
            }
        }
        if (best == null)
        {
            return MeshTool == MeshTool.Draw && _toolPoints.Count == 0 && AddPlanePoint(pixel);
        }
        if (_toolMesh != null && _toolMesh != best)
        {
            Console.Add(LogLevel.Warning, "mesh: a cut's points are on one mesh");
            return true;
        }
        var data = FindMeshData(best)!;
        var at = PlacementOf(best)!;
        if (MeshTool == MeshTool.Draw)
        {
            // Every corner is on the first click's face, where the ray meets its plane.
            var face = _toolPoints is [CutPoint.OnFace first, ..] ? first.Face
                : bestHit?.Face ?? (bestVertex is { } bv ? data.FacesOfVertex(bv)[0] : data.FacesOfEdge(data.Edges[bestEdge!.Value])[0]);
            var normal = at.NormalToView(data.FaceNormal(face));
            if (MeshGrid.HitPlane(at.ToView(data.Vertices[data.Faces[face].Corners[0]]), normal, ray) is not { } onPlane)
            {
                return true;
            }
            if (_toolPoints.Count >= 3 && Camera.Project(at.ToView(((CutPoint.OnFace)_toolPoints[0]).Position), width, height) is { } start && (start - pixel).Length <= MeshPick.HitPixels)
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
        OnMeshModeChanged();
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
        var (origin, axis) = GridPlane();
        if (_planePoints.Count > 0)
        {
            (origin, axis) = (_planePoints[0], MeshGrid.NearestAxis(Camera.Forward));
        }
        if (PointOnGrid(pixel, origin, axis) is not { } point)
        {
            return false;
        }
        var (width, height) = FrameSize;
        if (_planePoints.Count >= 3 && Camera.Project(Camera.RelativeTo(_planePoints[0]), width, height) is { } start && (start - pixel).Length <= MeshPick.HitPixels)
        {
            ApplyToolPoints();
            return true;
        }
        _planePoints.Add(point);
        OnMeshModeChanged();
        return true;
    }

    /// <summary>Enter: applies the Cut or the Draw with its points.</summary>
    public void ApplyToolPoints()
    {
        if (Scene == null)
        {
            return;
        }
        if (_planePoints.Count > 0)
        {
            var points = _planePoints.ToList();
            var axis = MeshGrid.NearestAxis(Camera.Forward);
            // The plane fronts toward the camera.
            var front = MeshGrid.AxisVector(axis) * (Vec3.Dot(MeshGrid.AxisVector(axis), Camera.Forward) > 0 ? -1 : 1);
            var data = MeshCut.Plane([.. points.Select(p => Vec3.Between(points[0], p))], front, DefaultMeshMaterial, NewFaceScale(DefaultMeshMaterial));
            CancelToolPoints();
            if (data == null)
            {
                Console.Add(LogLevel.Warning, "mesh: a polygon has three or more corners and does not cross itself");
                return;
            }
            var (create, document) = NewMeshEntity(NewMeshName("plane"), data, new Pose(points[0], Quat.Identity, [1, 1, 1]), []);
            if (Edit("Draw", new CreateMesh(document, Meshes), create))
            {
                SelectScene(create.Created.Id);
            }
            return;
        }
        if (_toolMesh is not { } guid || FindMeshData(guid) is not { } mesh)
        {
            CancelToolPoints();
            return;
        }
        var toolPoints = _toolPoints.ToList();
        var tool = MeshTool;
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
            Console.Add(LogLevel.Warning, $"mesh: {reason}");
            return;
        }
        if (result.Mesh.Validate() is { Count: > 0 } problems)
        {
            Console.Add(LogLevel.Error, $"mesh: cannot {tool.ToString().ToLowerInvariant()}: {string.Join("; ", problems)}");
            return;
        }
        if (Edit(tool.ToString(), new MeshOperation(guid, mesh, result.Mesh, Meshes)))
        {
            SetMeshSelection(new MeshSelection(result.Kind, [.. result.Selected.Select(i => new MeshItem(guid, i))]), switchKind: true);
        }
    }

    // The points of a Draw on a mesh, or of the loop a Cut would make, as the overlay marks them: x, y, z each, in
    // the mesh's space.
    float[] ToolMarks(string guid, MeshData mesh)
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
        OnMeshModeChanged();
    }

    public void CancelToolPoints()
    {
        _toolPoints.Clear();
        _planePoints.Clear();
        _toolMesh = null;
        _loopPreview = null;
        OnMeshModeChanged();
    }
}
