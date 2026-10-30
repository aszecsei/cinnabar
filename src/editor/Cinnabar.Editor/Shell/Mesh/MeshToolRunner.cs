using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Tools;
using GizmoKind = Cinnabar.Editor.Link.Protocol.GizmoKind;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The mesh tools (see docs/editor/mesh-editing.md#mesh-tools): each runs on the sub-selection of every
/// edited mesh as one undo entry. A tool with a distance, such as Extrude, opens the entry and waits for a drag of the
/// gizmo, whose steps set the distance and replace each other; releasing commits and Escape cancels. Cut and Draw are
/// tool modes that take points from clicks until Enter. Detach and Extract make a new mesh and entity, and the
/// primitives fill a dragged rectangle, with parameters that stay editable until the next edit.
/// </summary>
public sealed partial class MeshToolRunner
{
    readonly MeshSession _session;
    readonly IMeshHost _shell;

    internal MeshToolRunner(MeshSession session, IMeshHost shell) => (_session, _shell) = (session, shell);

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

    internal string? PendingLabel => _pending?.Label;

    // Any edit but a primitive's own parameter change ends its parameters' editability.
    internal void ForgetStalePrimitive()
    {
        if (!_remaking && _lastPrimitive is { } last && _shell.Scene != null && (_shell.Scene.History.Count != last.Position || _shell.Scene.Position != last.Position))
        {
            _lastPrimitive = null;
        }
    }

    /// <summary>The angle that Recalculate Normals marks edges sharp beyond, in degrees.</summary>
    public double NormalAngle { get; private set; } = 30;

    public int BevelSegments { get; private set; } = 1;

    /// <summary>The primitive that the Create tool makes.</summary>
    public PrimitiveKind Primitive { get; private set; } = PrimitiveKind.Block;

    public PrimitiveParameters PrimitiveParameters { get; private set; } = PrimitiveParameters.Default;

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
        _session.CanEditInMeshMode && !_session.MeshSelection.IsEmpty && (kind == null || _session.MeshElement == kind);

    /// <summary>
    /// Runs a tool on the selected elements of each edited mesh, as one undo entry, and selects what it leaves. A
    /// result that fails validation is refused with the reason in the console, and nothing changes.
    /// </summary>
    public bool RunMeshTool(string label, Func<MeshData, IEnumerable<int>, ToolResult> run, MeshElement? requires = null)
    {
        CommitPendingDistance();
        if (!CanRunMeshTool(requires) || _shell.Scene == null)
        {
            return false;
        }
        var ops = new List<Operation>();
        var items = new List<MeshItem>();
        MeshElement? kind = null;
        foreach (var guid in _session.MeshSelection.Guids)
        {
            if (_session.FindMeshData(guid) is not { } mesh)
            {
                continue;
            }
            var result = run(mesh, _session.MeshSelection.Of(guid));
            if (result.Mesh.Validate() is { Count: > 0 } problems)
            {
                _shell.Console.Add(LogLevel.Error, $"mesh: cannot {label.ToLowerInvariant()}: {string.Join("; ", problems)}");
                return false;
            }
            if (!ReferenceEquals(result.Mesh, mesh))
            {
                ops.Add(new MeshOperation(guid, mesh, result.Mesh, _session.Meshes));
            }
            kind = result.Kind;
            items.AddRange(result.Selected.Select(i => new MeshItem(guid, i)));
        }
        if (ops.Count == 0)
        {
            _shell.Console.Add(LogLevel.Info, $"mesh: {label.ToLowerInvariant()} changed nothing");
            return false;
        }
        if (!_shell.Edit(label, [.. ops]))
        {
            return false;
        }
        _session.SetMeshSelection(new MeshSelection(kind ?? _session.MeshElement, [.. items]), switchKind: true);
        return true;
    }

    /// <summary>Acts on the whole of each edited mesh, as Clean and Recalculate Normals do without a selection.</summary>
    public bool RunWholeMeshTool(string label, Func<MeshData, (MeshData Mesh, IReadOnlyList<string> Problems)> run)
    {
        CommitPendingDistance();
        if (!_session.InMeshMode || !_shell.IsEditing || _shell.Scene == null)
        {
            return false;
        }
        var ops = new List<Operation>();
        foreach (var (guid, _) in _session.EditedMeshes)
        {
            if (_session.FindMeshData(guid) is not { } mesh)
            {
                continue;
            }
            var (result, problems) = run(mesh);
            foreach (var p in problems)
            {
                _shell.Console.Add(LogLevel.Warning, $"mesh: {_session.Meshes.Find(guid)?.Title}: {p}");
            }
            if (!ReferenceEquals(result, mesh) && !result.Faces.SequenceEqual(mesh.Faces))
            {
                ops.Add(new MeshOperation(guid, mesh, result, _session.Meshes));
            }
            else if (!ReferenceEquals(result, mesh))
            {
                ops.Add(new MeshOperation(guid, mesh, result, _session.Meshes));
            }
        }
        if (ops.Count == 0)
        {
            _shell.Console.Add(LogLevel.Info, $"mesh: {label.ToLowerInvariant()} changed nothing");
            return false;
        }
        var ok = _shell.Edit(label, [.. ops]);
        if (ok)
        {
            _session.SetMeshSelection(_session.MeshSelection.Pruned(_session.FindMeshData));
        }
        return ok;
    }

    public void SetNormalAngle(double degrees)
    {
        NormalAngle = Math.Clamp(degrees, 1, 180);
        _session.OnMeshModeChanged();
    }

    public void SetBevelSegments(int segments)
    {
        BevelSegments = Math.Clamp(segments, 1, 16);
        _session.OnMeshModeChanged();
    }

    /// <summary>Extrude: faces out along their average normal with walls, or open edges out as quads, by a dragged distance.</summary>
    public bool Extrude() => _session.MeshElement switch
    {
        MeshElement.Faces => BeginDistanceTool("Extrude", (m, s, d) => MeshTools.Extrude(m, s, d, _session.Texture.ScaleForFaces(m, s)), requires: MeshElement.Faces),
        MeshElement.Edges => BeginDistanceTool("Extrude", (m, s, d) => MeshTools.ExtrudeEdges(m, s, d, _session.Texture.ScaleForEdges(m, s)), requires: MeshElement.Edges),
        _ => false,
    };

    public bool PushPull() => BeginDistanceTool("Push/Pull", (m, s, d) => MeshTools.PushPull(m, s, d), requires: MeshElement.Faces);

    public bool Offset() => BeginDistanceTool("Offset", (m, s, d) => MeshTools.Offset(m, s, d), requires: MeshElement.Faces);

    public bool Inset() => BeginDistanceTool("Inset", (m, s, d) => MeshTools.Inset(m, s, Math.Abs(d)), magnitude: true, requires: MeshElement.Faces);

    public bool Outset() => BeginDistanceTool("Outset", (m, s, d) => MeshTools.Inset(m, s, -Math.Abs(d)), magnitude: true, requires: MeshElement.Faces);

    public bool Bevel() => _session.MeshElement switch
    {
        MeshElement.Vertices => BeginDistanceTool("Bevel", (m, s, d) => MeshBevel.Vertices(m, s, Math.Abs(d)), magnitude: true, requires: MeshElement.Vertices),
        MeshElement.Edges => BeginDistanceTool("Bevel", (m, s, d) => MeshBevel.Edges(m, s, Math.Abs(d), BevelSegments), magnitude: true, requires: MeshElement.Edges),
        _ => false,
    };

    public bool DuplicateFaces() => RunMeshTool("Duplicate", MeshTools.Duplicate, MeshElement.Faces);

    public bool Collapse() => RunMeshTool("Collapse", (m, s) => MeshTools.Collapse(m, _session.MeshElement, s));

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
        foreach (var guid in _session.EditedMeshes.Keys)
        {
            if (_session.FindMeshData(guid) is { } mesh)
            {
                reported.AddRange(Enumerable.Range(0, mesh.Edges.Length).Where(e => mesh.FacesOfEdge(mesh.Edges[e]).Count > 2).Select(e => new MeshItem(guid, e)));
            }
        }
        if (reported.Count > 0)
        {
            _session.SetMeshSelection(new MeshSelection(MeshElement.Edges, [.. reported]), switchKind: true);
            _shell.Console.Add(LogLevel.Warning, $"mesh: clean: {reported.Count} {(reported.Count == 1 ? "edge has" : "edges have")} more than two faces, and {(reported.Count == 1 ? "is" : "are")} selected");
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
        if (!CanRunMeshTool(MeshElement.Faces) || _shell.Scene == null)
        {
            return false;
        }
        var guids = _session.MeshSelection.Guids.Where(g => _session.FindMeshData(g) != null && _session.PlacementOf(g) != null).ToList();
        if (guids.Count == 0 || _shell.Scene.Expanded.Flat.Find(_session.EditedMeshes[guids[0]]) is not { } source || SceneEdits.WorldPose(_shell.Scene.Expanded.Flat, source) is not { } pose)
        {
            return false;
        }
        var first = _session.PlacementOf(guids[0])!;
        MeshData? combined = null;
        var ops = new List<Operation>();
        foreach (var guid in guids)
        {
            var mesh = _session.FindMeshData(guid)!;
            var placement = _session.PlacementOf(guid)!;
            var (extracted, remaining) = MeshTools.Split(mesh, _session.MeshSelection.Of(guid));
            if (extracted.Faces.Length == 0)
            {
                continue;
            }
            var inFirst = guid == guids[0] ? extracted : extracted.With(vertices: extracted.Vertices.Select(v => first.ToLocal(placement.ToView(v))));
            combined = combined == null ? inFirst : Append(combined, inFirst);
            if (!keepSource)
            {
                ops.Add(new MeshOperation(guid, mesh, remaining, _session.Meshes));
            }
        }
        if (combined == null)
        {
            return false;
        }
        var label = keepSource ? "Extract" : "Detach";
        var name = _session.NewMeshName(label.ToLowerInvariant());
        var renderer = source.Components.Find(c => c.Id == SceneEdits.MeshRendererId);
        var (create, document) = NewMeshEntity(name, combined, pose, renderer?.Fields.Where(f => f.Name.StartsWith("materials.", StringComparison.Ordinal)).ToList() ?? []);
        if (!_shell.Edit(label, [new CreateMesh(document, _session.Meshes), create, .. ops]))
        {
            return false;
        }
        _session.AddEditedMesh(document.Guid, create.Created.Id);
        _session.SetMeshSelection(new MeshSelection(MeshElement.Faces, [.. Enumerable.Range(0, combined.Faces.Length).Select(i => new MeshItem(document.Guid, i))]));
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
        var directory = Path.Combine(Path.GetDirectoryName(_shell.Scene!.Path)!, $"{Path.GetFileNameWithoutExtension(_shell.Scene.Path)}_meshes");
        var document = new MeshDocument(Path.Combine(directory, name + MeshFile.Extension), guid, data, saved: false);
        var create = SceneEdits.NewEntity(_shell.Scene.Expanded.Flat, pose.Position);
        create.Created.Name = name;
        create.Created.Components[0] = new SceneComponent(SceneEdits.TransformId, "Transform", SceneEdits.TransformFields(pose));
        var fields = new List<SceneField> { new("mesh", SceneValue.AssetRef(guid)) };
        fields.AddRange(materials.Count > 0 ? materials : [new SceneField("materials.0", SceneValue.AssetRef(_session.DefaultMeshMaterial))]);
        fields.Add(new SceneField("cast_shadows", SceneValue.Of(true)));
        create.Created.Components.Add(new SceneComponent(SceneEdits.MeshRendererId, "Mesh_Renderer", fields));
        return (create, document);
    }
}
