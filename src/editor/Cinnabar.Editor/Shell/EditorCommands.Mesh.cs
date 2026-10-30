using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Mesh;

namespace Cinnabar.Editor.Shell;

static partial class EditorCommands
{
    static void RegisterMesh(EditorShell shell)
    {
        var commands = shell.Commands;
        // Mesh mode (see docs/editor/mesh-editing.md#mesh-mode). Its keys, Tab, 1, 2, 3, [ and ], are the viewport's, as the
        // tools' are.
        commands.Register(new Command(EditMesh, "Edit Mesh", shell.ToggleMeshMode)
        {
            Description = "Edit the selected entities' mesh files: select their vertices, edges and faces and move them. Tab in the viewport enters and leaves.",
            Icon = "mesh",
            CanExecuteWhen = () => shell.CanEditMesh,
            IsCheckedWhen = () => shell.InMeshMode,
        });
        commands.Register(new Command(ObjectMode, "Object Mode", shell.LeaveMeshMode)
        {
            Description = "Leave mesh mode and select entities again. The meshes stay live until they are saved and cooked.",
            Icon = "select",
            CanExecuteWhen = () => shell.InMeshMode,
        });
        ElementCommand(shell, MeshVertices, MeshElement.Vertices, "Vertices", "select", "Select and move vertices. 1 in the viewport.");
        ElementCommand(shell, MeshEdges, MeshElement.Edges, "Edges", "local", "Select and move edges. 2 in the viewport.");
        ElementCommand(shell, MeshFaces, MeshElement.Faces, "Faces", "mesh", "Select and move faces. 3 in the viewport.");
        commands.Register(new Command(MeshBlock, "Block", () =>
        {
            if (shell.MeshTool == MeshTool.Create && shell.Primitive == PrimitiveKind.Block)
            {
                shell.SetMeshTool(MeshTool.Select);
            }
            else
            {
                shell.SetPrimitive(PrimitiveKind.Block);
            }
        })
        {
            Description = "Drag a rectangle on the grid to add a box a grid cell high: a new mesh file and entity, or faces of the edited mesh in mesh mode. Ctrl at the release makes a new entity anyway.",
            Icon = "add",
            CanExecuteWhen = () => shell.CanEditScene,
            IsCheckedWhen = () => shell.MeshTool == MeshTool.Create && shell.Primitive == PrimitiveKind.Block,
        });
        commands.Register(new Command(MeshCreate, "Create", () => shell.SetMeshTool(shell.MeshTool == MeshTool.Create ? MeshTool.Select : MeshTool.Create))
        {
            Description = "Drag a rectangle on the grid to add the chosen primitive, a grid cell high, with its parameters, which stay editable until the next edit.",
            Icon = "add",
            CanExecuteWhen = () => shell.CanEditScene,
            IsCheckedWhen = () => shell.MeshTool == MeshTool.Create,
        });
        commands.Register(ChoiceCommand.ForEnum(MeshPrimitive, "Primitive", () => shell.Primitive, shell.SetPrimitive,
            description: "The primitive that Create makes: a block, a wedge, a cylinder, a cone, a sphere, an arch, stairs, a torus or a plane.",
            canExecuteWhen: () => shell.CanEditScene));
        Parameter(shell, MeshSides, "Sides", EditorShell.SideOptions, p => Nearest(EditorShell.SideOptions, p.Sides), (p, v) => p with { Sides = (int)Number(v) }, "The sides of a cylinder, a cone, an arch, or a torus's tube.");
        Parameter(shell, MeshSegments, "Segments", EditorShell.SegmentOptions, p => Nearest(EditorShell.SegmentOptions, p.Segments), (p, v) => p with { Segments = (int)Number(v) }, "The segments around a sphere or a torus.");
        Parameter(shell, MeshRings, "Rings", EditorShell.RingOptions, p => Nearest(EditorShell.RingOptions, p.Rings), (p, v) => p with { Rings = (int)Number(v) }, "The rings of a sphere, from pole to pole.");
        Parameter(shell, MeshSteps, "Steps", EditorShell.StepOptions, p => Nearest(EditorShell.StepOptions, p.Steps), (p, v) => p with { Steps = (int)Number(v) }, "The steps of a staircase.");
        Parameter(shell, MeshArc, "Arc", EditorShell.ArcOptions, p => Nearest(EditorShell.ArcOptions, p.Arc), (p, v) => p with { Arc = Number(v) }, "An arch's arc, in degrees.");
        Parameter(shell, MeshThickness, "Thickness", EditorShell.ThicknessOptions, p => Nearest(EditorShell.ThicknessOptions, p.Thickness), (p, v) => p with { Thickness = Number(v) }, "An arch's wall, in meters.");
        Parameter(shell, MeshTubeRadius, "Tube", EditorShell.TubeOptions, p => Nearest(EditorShell.TubeOptions, p.TubeRadius), (p, v) => p with { TubeRadius = Number(v) }, "A torus's tube radius, in meters.");
        ModeTool(shell, MeshCut, MeshTool.Cut, "Cut", "scale-tool", "A loop cut: hover an edge to see the loop through the quads around the mesh, and click to cut it there. Snap puts the cut on the grid.");
        ModeTool(shell, MeshDraw, MeshTool.Draw, "Draw", "graph", "Click the corners of a polygon on a face, or on the grid, and press Enter or click the first corner to close it: a face cut into the face, or a new plane.");
        commands.Register(new Command(MeshApplyPoints, "Apply Points", shell.ApplyToolPoints)
        {
            Description = "Draw with the corners clicked so far, as Enter in the viewport does.",
            Icon = "play",
            CanExecuteWhen = () => shell.ToolPointCount > 0,
        });
        MeshToolCommand(shell, MeshExtrude, "Extrude", "move", shell.Extrude, "Pull the selected faces out along their normal with walls, or open edges out as quads; then drag the gizmo for the distance. Shift at the start of a Move drag does the same.");
        MeshToolCommand(shell, MeshPushPull, "Push/Pull", "move", shell.PushPull, "Move the selected faces along their normal, stretching their neighbors; then drag the gizmo for the distance.", MeshElement.Faces);
        MeshToolCommand(shell, MeshOffset, "Offset", "scale-tool", shell.Offset, "Move each selected face along its own normal, keeping corners sharp where they meet; then drag the gizmo for the distance.", MeshElement.Faces);
        MeshToolCommand(shell, MeshInset, "Inset", "collapse", shell.Inset, "Shrink the selected faces inside a ring of new faces; then drag the gizmo for the distance.", MeshElement.Faces);
        MeshToolCommand(shell, MeshOutset, "Outset", "panels", shell.Outset, "Grow the selected faces outside a ring of new faces; then drag the gizmo for the distance.", MeshElement.Faces);
        MeshToolCommand(shell, MeshDuplicate, "Duplicate Faces", "copy", shell.DuplicateFaces, "Copy the selected faces in place and select the copies, so a drag moves them.", MeshElement.Faces);
        MeshToolCommand(shell, MeshCollapse, "Collapse", "collapse", shell.Collapse, "Merge the selected vertices into one at their centroid, each edge into its middle, or each face into a point.");
        MeshToolCommand(shell, MeshMergeFaces, "Merge Faces", "mesh", shell.MergeFaces, "Dissolve the edges between selected faces that share a plane into one face.", MeshElement.Faces);
        MeshToolCommand(shell, MeshInvert, "Invert", "rotate", shell.InvertFaces, "Turn the selected faces to face the other way, with their textures reading the same.", MeshElement.Faces);
        MeshToolCommand(shell, MeshDetach, "Detach", "scene", () => shell.Detach(keepSource: false), "Move the selected faces into a new mesh file and entity at the same pose.", MeshElement.Faces);
        MeshToolCommand(shell, MeshExtract, "Extract", "copy", () => shell.Detach(keepSource: true), "Copy the selected faces into a new mesh file and entity at the same pose.", MeshElement.Faces);
        MeshToolCommand(shell, MeshBevel, "Bevel", "rotate", shell.Bevel, "Replace the selected vertices with a face each, or the selected edges with a strip of faces in segments; then drag the gizmo for the width.");
        commands.Register(new Command(MeshRecalculateNormals, "Recalculate Normals", () => shell.RecalculateNormals())
        {
            Description = "Mark an edge sharp where its faces' normals differ by more than the angle, and smooth otherwise, on the selected faces or the whole mesh.",
            Icon = "reset",
            CanExecuteWhen = () => shell.CanEditInMeshMode,
        });
        commands.Register(new ChoiceCommand(MeshNormalAngle, "Angle", EditorShell.NormalAngles, () => Nearest(EditorShell.NormalAngles, shell.NormalAngle), v => shell.SetNormalAngle(Number(v)))
        {
            Description = "The angle, in degrees, beyond which Recalculate Normals marks an edge sharp.",
            CanExecuteWhen = () => shell.InMeshMode,
        });
        commands.Register(new ChoiceCommand(MeshBevelSegments, "Segments", EditorShell.BevelSegmentOptions, () => Nearest(EditorShell.BevelSegmentOptions, shell.BevelSegments), v => shell.SetBevelSegments((int)Number(v)))
        {
            Description = "The segments of an edge bevel's strip: one is a chamfer.",
            CanExecuteWhen = () => shell.InMeshMode,
        });
        commands.Register(new Command(MeshClean, "Clean", () => shell.Clean())
        {
            Description = "Merge vertices within a tenth of a millimeter, remove degenerate faces and unused vertices, dissolve vertices on straight edges, and report edges with more than two faces.",
            Icon = "reset",
            CanExecuteWhen = () => shell.CanEditInMeshMode,
        });
    }

    static void ElementCommand(EditorShell shell, string id, MeshElement kind, string label, string icon, string description) =>
        shell.Commands.Register(new Command(id, label, () => shell.SetMeshElement(kind))
        {
            Description = description,
            Icon = icon,
            CanExecuteWhen = () => shell.InMeshMode,
            IsCheckedWhen = () => shell.InMeshMode && shell.MeshElement == kind,
        });

    static void Parameter(EditorShell shell, string id, string label, IReadOnlyList<string> options, Func<PrimitiveParameters, string> get, Func<PrimitiveParameters, string, PrimitiveParameters> set, string description) =>
        shell.Commands.Register(new ChoiceCommand(id, label, options, () => get(shell.PrimitiveParameters), value => shell.SetPrimitiveParameters(set(shell.PrimitiveParameters, value)))
        {
            Description = description,
            CanExecuteWhen = () => shell.CanEditScene,
        });

    static void ModeTool(EditorShell shell, string id, MeshTool tool, string label, string icon, string description) =>
        shell.Commands.Register(new Command(id, label, () => shell.SetMeshTool(shell.MeshTool == tool ? MeshTool.Select : tool))
        {
            Description = description,
            Icon = icon,
            CanExecuteWhen = () => shell.CanEditScene,
            IsCheckedWhen = () => shell.MeshTool == tool,
        });

    static void MeshToolCommand(EditorShell shell, string id, string label, string icon, Func<bool> run, string description, MeshElement? kind = null) =>
        shell.Commands.Register(new Command(id, label, () => run())
        {
            Description = description,
            Icon = icon,
            CanExecuteWhen = () => shell.CanRunMeshTool(kind),
        });

    // The selection in mesh mode, the pivot, and the grid.
    static void RegisterMeshSelection(EditorShell shell)
    {
        var commands = shell.Commands;
        commands.Register(new Command(MeshSelectLinked, "Select Linked", shell.SelectLinked)
        {
            Description = "Select every element that the selected ones connect to, in each mesh.",
            Icon = "select",
            CanExecuteWhen = () => shell.InMeshMode && !shell.MeshSelection.IsEmpty,
        });
        commands.Register(new Command(MeshGrow, "Grow", shell.GrowSelection)
        {
            Description = "Add the selected elements' neighbors to the selection.",
            Icon = "add",
            CanExecuteWhen = () => shell.InMeshMode && !shell.MeshSelection.IsEmpty,
        });
        commands.Register(new Command(MeshShrink, "Shrink", shell.ShrinkSelection)
        {
            Description = "Drop the selection's boundary: the elements with a neighbor that is not selected.",
            Icon = "collapse",
            CanExecuteWhen = () => shell.InMeshMode && !shell.MeshSelection.IsEmpty,
        });
        commands.Register(new Command(MeshKeepPlanar, "Keep Planar", shell.ToggleKeepPlanar)
        {
            Description = "A Move drag keeps the faces it would bend flat, by moving their other vertices along.",
            Icon = "mesh",
            CanExecuteWhen = () => shell.InMeshMode,
            IsCheckedWhen = () => shell.KeepPlanar,
        });
        commands.Register(new Command(MeshEditPivot, "Edit Pivot", shell.ToggleEditPivot)
        {
            Description = "The gizmo moves the mesh's entity, with the geometry staying where it is. Snap puts the pivot on the grid.",
            Icon = "move",
            CanExecuteWhen = () => shell.InMeshMode,
            IsCheckedWhen = () => shell.EditPivot,
        });
        commands.Register(new Command(MeshCenterPivot, "Center Pivot", () => shell.CenterPivot())
        {
            Description = "Put the mesh's entity at the center of its bounds, with the geometry staying where it is.",
            Icon = "frame",
            CanExecuteWhen = () => shell.CanEditInMeshMode,
        });
        commands.Register(new Command(MeshPivotToGrid, "Pivot to Grid", () => shell.PivotToGrid())
        {
            Description = "Snap the mesh's entity to the grid, with the geometry staying where it is.",
            Icon = "snap",
            CanExecuteWhen = () => shell.CanEditInMeshMode,
        });
        commands.Register(new Command(MeshGridToggle, "Show Grid", shell.ToggleShowGrid)
        {
            Description = "Draw the grid that mesh mode snaps to, on the plane through the selection facing the camera.",
            Icon = "snap",
            IsCheckedWhen = () => shell.ShowGrid,
        });
        commands.Register(new Command(MeshGridFiner, "Finer Grid", shell.FinerGrid)
        {
            Description = "Halve the grid's size, down to 1/64 m. [ in the viewport.",
            Icon = "chevron-down",
            CanExecuteWhen = () => shell.GridSize > MeshGrid.MinSize,
        });
        commands.Register(new Command(MeshGridCoarser, "Coarser Grid", shell.CoarserGrid)
        {
            Description = "Double the grid's size, up to 16 m. ] in the viewport.",
            Icon = "collapse",
            CanExecuteWhen = () => shell.GridSize < MeshGrid.MaxSize,
        });
        commands.Register(new Command(MeshSelectThrough, "Select Through", shell.ToggleSelectThrough)
        {
            Description = "Let a box and a click in mesh mode take faces that face away, and their vertices and edges.",
            Icon = "visible",
            IsCheckedWhen = () => shell.SelectThrough,
        });
    }
}
