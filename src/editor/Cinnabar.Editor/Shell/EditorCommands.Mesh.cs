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
        commands.Register(new Command(EditMesh, "Edit Mesh", shell.Mesh.ToggleMeshMode)
        {
            Description = "Edit the selected entities' mesh files: select their vertices, edges and faces and move them. Tab in the viewport enters and leaves.",
            Icon = "mesh",
            CanExecuteWhen = () => shell.Mesh.CanEditMesh,
            IsCheckedWhen = () => shell.Mesh.InMeshMode,
        });
        commands.Register(new Command(ObjectMode, "Object Mode", shell.Mesh.LeaveMeshMode)
        {
            Description = "Leave mesh mode and select entities again. The meshes stay live until they are saved and cooked.",
            Icon = "select",
            CanExecuteWhen = () => shell.Mesh.InMeshMode,
        });
        ElementCommand(shell, MeshVertices, MeshElement.Vertices, "Vertices", "select", "Select and move vertices. 1 in the viewport.");
        ElementCommand(shell, MeshEdges, MeshElement.Edges, "Edges", "local", "Select and move edges. 2 in the viewport.");
        ElementCommand(shell, MeshFaces, MeshElement.Faces, "Faces", "mesh", "Select and move faces. 3 in the viewport.");
        commands.Register(new Command(MeshBlock, "Block", () =>
        {
            if (shell.Mesh.MeshTool == MeshTool.Create && shell.Mesh.Tools.Primitive == PrimitiveKind.Block)
            {
                shell.Mesh.SetMeshTool(MeshTool.Select);
            }
            else
            {
                shell.Mesh.Tools.SetPrimitive(PrimitiveKind.Block);
            }
        })
        {
            Description = "Drag a rectangle on the grid to add a box a grid cell high: a new mesh file and entity, or faces of the edited mesh in mesh mode. Ctrl at the release makes a new entity anyway.",
            Icon = "add",
            CanExecuteWhen = () => shell.CanEditScene,
            IsCheckedWhen = () => shell.Mesh.MeshTool == MeshTool.Create && shell.Mesh.Tools.Primitive == PrimitiveKind.Block,
        });
        commands.Register(new Command(MeshCreate, "Create", () => shell.Mesh.SetMeshTool(shell.Mesh.MeshTool == MeshTool.Create ? MeshTool.Select : MeshTool.Create))
        {
            Description = "Drag a rectangle on the grid to add the chosen primitive, a grid cell high, with its parameters, which stay editable until the next edit.",
            Icon = "add",
            CanExecuteWhen = () => shell.CanEditScene,
            IsCheckedWhen = () => shell.Mesh.MeshTool == MeshTool.Create,
        });
        commands.Register(ChoiceCommand.ForEnum(MeshPrimitive, "Primitive", () => shell.Mesh.Tools.Primitive, shell.Mesh.Tools.SetPrimitive,
            description: "The primitive that Create makes: a block, a wedge, a cylinder, a cone, a sphere, an arch, stairs, a torus or a plane.",
            canExecuteWhen: () => shell.CanEditScene));
        Parameter(shell, MeshSides, "Sides", MeshToolRunner.SideOptions, p => Nearest(MeshToolRunner.SideOptions, p.Sides), (p, v) => p with { Sides = (int)Number(v) }, "The sides of a cylinder, a cone, an arch, or a torus's tube.");
        Parameter(shell, MeshSegments, "Segments", MeshToolRunner.SegmentOptions, p => Nearest(MeshToolRunner.SegmentOptions, p.Segments), (p, v) => p with { Segments = (int)Number(v) }, "The segments around a sphere or a torus.");
        Parameter(shell, MeshRings, "Rings", MeshToolRunner.RingOptions, p => Nearest(MeshToolRunner.RingOptions, p.Rings), (p, v) => p with { Rings = (int)Number(v) }, "The rings of a sphere, from pole to pole.");
        Parameter(shell, MeshSteps, "Steps", MeshToolRunner.StepOptions, p => Nearest(MeshToolRunner.StepOptions, p.Steps), (p, v) => p with { Steps = (int)Number(v) }, "The steps of a staircase.");
        Parameter(shell, MeshArc, "Arc", MeshToolRunner.ArcOptions, p => Nearest(MeshToolRunner.ArcOptions, p.Arc), (p, v) => p with { Arc = Number(v) }, "An arch's arc, in degrees.");
        Parameter(shell, MeshThickness, "Thickness", MeshToolRunner.ThicknessOptions, p => Nearest(MeshToolRunner.ThicknessOptions, p.Thickness), (p, v) => p with { Thickness = Number(v) }, "An arch's wall, in meters.");
        Parameter(shell, MeshTubeRadius, "Tube", MeshToolRunner.TubeOptions, p => Nearest(MeshToolRunner.TubeOptions, p.TubeRadius), (p, v) => p with { TubeRadius = Number(v) }, "A torus's tube radius, in meters.");
        ModeTool(shell, MeshCut, MeshTool.Cut, "Cut", "scale-tool", "A loop cut: hover an edge to see the loop through the quads around the mesh, and click to cut it there. Snap puts the cut on the grid.");
        ModeTool(shell, MeshDraw, MeshTool.Draw, "Draw", "graph", "Click the corners of a polygon on a face, or on the grid, and press Enter or click the first corner to close it: a face cut into the face, or a new plane.");
        commands.Register(new Command(MeshApplyPoints, "Apply Points", shell.Mesh.Tools.ApplyToolPoints)
        {
            Description = "Draw with the corners clicked so far, as Enter in the viewport does.",
            Icon = "play",
            CanExecuteWhen = () => shell.Mesh.Tools.ToolPointCount > 0,
        });
        MeshToolCommand(shell, MeshExtrude, "Extrude", "move", shell.Mesh.Tools.Extrude, "Pull the selected faces out along their normal with walls, or open edges out as quads; then drag the gizmo for the distance. Shift at the start of a Move drag does the same.");
        MeshToolCommand(shell, MeshPushPull, "Push/Pull", "move", shell.Mesh.Tools.PushPull, "Move the selected faces along their normal, stretching their neighbors; then drag the gizmo for the distance.", MeshElement.Faces);
        MeshToolCommand(shell, MeshOffset, "Offset", "scale-tool", shell.Mesh.Tools.Offset, "Move each selected face along its own normal, keeping corners sharp where they meet; then drag the gizmo for the distance.", MeshElement.Faces);
        MeshToolCommand(shell, MeshInset, "Inset", "collapse", shell.Mesh.Tools.Inset, "Shrink the selected faces inside a ring of new faces; then drag the gizmo for the distance.", MeshElement.Faces);
        MeshToolCommand(shell, MeshOutset, "Outset", "panels", shell.Mesh.Tools.Outset, "Grow the selected faces outside a ring of new faces; then drag the gizmo for the distance.", MeshElement.Faces);
        MeshToolCommand(shell, MeshDuplicate, "Duplicate Faces", "copy", shell.Mesh.Tools.DuplicateFaces, "Copy the selected faces in place and select the copies, so a drag moves them.", MeshElement.Faces);
        MeshToolCommand(shell, MeshCollapse, "Collapse", "collapse", shell.Mesh.Tools.Collapse, "Merge the selected vertices into one at their centroid, each edge into its middle, or each face into a point.");
        MeshToolCommand(shell, MeshMergeFaces, "Merge Faces", "mesh", shell.Mesh.Tools.MergeFaces, "Dissolve the edges between selected faces that share a plane into one face.", MeshElement.Faces);
        MeshToolCommand(shell, MeshInvert, "Invert", "rotate", shell.Mesh.Tools.InvertFaces, "Turn the selected faces to face the other way, with their textures reading the same.", MeshElement.Faces);
        MeshToolCommand(shell, MeshDetach, "Detach", "scene", () => shell.Mesh.Tools.Detach(keepSource: false), "Move the selected faces into a new mesh file and entity at the same pose.", MeshElement.Faces);
        MeshToolCommand(shell, MeshExtract, "Extract", "copy", () => shell.Mesh.Tools.Detach(keepSource: true), "Copy the selected faces into a new mesh file and entity at the same pose.", MeshElement.Faces);
        MeshToolCommand(shell, MeshBevel, "Bevel", "rotate", shell.Mesh.Tools.Bevel, "Replace the selected vertices with a face each, or the selected edges with a strip of faces in segments; then drag the gizmo for the width.");
        commands.Register(new Command(MeshRecalculateNormals, "Recalculate Normals", () => shell.Mesh.Tools.RecalculateNormals())
        {
            Description = "Mark an edge sharp where its faces' normals differ by more than the angle, and smooth otherwise, on the selected faces or the whole mesh.",
            Icon = "reset",
            CanExecuteWhen = () => shell.Mesh.CanEditInMeshMode,
        });
        commands.Register(new ChoiceCommand(MeshNormalAngle, "Angle", MeshToolRunner.NormalAngles, () => Nearest(MeshToolRunner.NormalAngles, shell.Mesh.Tools.NormalAngle), v => shell.Mesh.Tools.SetNormalAngle(Number(v)))
        {
            Description = "The angle, in degrees, beyond which Recalculate Normals marks an edge sharp.",
            CanExecuteWhen = () => shell.Mesh.InMeshMode,
        });
        commands.Register(new ChoiceCommand(MeshBevelSegments, "Segments", MeshToolRunner.BevelSegmentOptions, () => Nearest(MeshToolRunner.BevelSegmentOptions, shell.Mesh.Tools.BevelSegments), v => shell.Mesh.Tools.SetBevelSegments((int)Number(v)))
        {
            Description = "The segments of an edge bevel's strip: one is a chamfer.",
            CanExecuteWhen = () => shell.Mesh.InMeshMode,
        });
        commands.Register(new Command(MeshClean, "Clean", () => shell.Mesh.Tools.Clean())
        {
            Description = "Merge vertices within a tenth of a millimeter, remove degenerate faces and unused vertices, dissolve vertices on straight edges, and report edges with more than two faces.",
            Icon = "reset",
            CanExecuteWhen = () => shell.Mesh.CanEditInMeshMode,
        });
    }

    static void ElementCommand(EditorShell shell, string id, MeshElement kind, string label, string icon, string description) =>
        shell.Commands.Register(new Command(id, label, () => shell.Mesh.SetMeshElement(kind))
        {
            Description = description,
            Icon = icon,
            CanExecuteWhen = () => shell.Mesh.InMeshMode,
            IsCheckedWhen = () => shell.Mesh.InMeshMode && shell.Mesh.MeshElement == kind,
        });

    static void Parameter(EditorShell shell, string id, string label, IReadOnlyList<string> options, Func<PrimitiveParameters, string> get, Func<PrimitiveParameters, string, PrimitiveParameters> set, string description) =>
        shell.Commands.Register(new ChoiceCommand(id, label, options, () => get(shell.Mesh.Tools.PrimitiveParameters), value => shell.Mesh.Tools.SetPrimitiveParameters(set(shell.Mesh.Tools.PrimitiveParameters, value)))
        {
            Description = description,
            CanExecuteWhen = () => shell.CanEditScene,
        });

    static void ModeTool(EditorShell shell, string id, MeshTool tool, string label, string icon, string description) =>
        shell.Commands.Register(new Command(id, label, () => shell.Mesh.SetMeshTool(shell.Mesh.MeshTool == tool ? MeshTool.Select : tool))
        {
            Description = description,
            Icon = icon,
            CanExecuteWhen = () => shell.CanEditScene,
            IsCheckedWhen = () => shell.Mesh.MeshTool == tool,
        });

    static void MeshToolCommand(EditorShell shell, string id, string label, string icon, Func<bool> run, string description, MeshElement? kind = null) =>
        shell.Commands.Register(new Command(id, label, () => run())
        {
            Description = description,
            Icon = icon,
            CanExecuteWhen = () => shell.Mesh.Tools.CanRunMeshTool(kind),
        });

    // The selection in mesh mode, the pivot, and the grid.
    static void RegisterMeshSelection(EditorShell shell)
    {
        var commands = shell.Commands;
        commands.Register(new Command(MeshSelectLinked, "Select Linked", shell.Mesh.SelectLinked)
        {
            Description = "Select every element that the selected ones connect to, in each mesh.",
            Icon = "select",
            CanExecuteWhen = () => shell.Mesh.InMeshMode && !shell.Mesh.MeshSelection.IsEmpty,
        });
        commands.Register(new Command(MeshGrow, "Grow", shell.Mesh.GrowSelection)
        {
            Description = "Add the selected elements' neighbors to the selection.",
            Icon = "add",
            CanExecuteWhen = () => shell.Mesh.InMeshMode && !shell.Mesh.MeshSelection.IsEmpty,
        });
        commands.Register(new Command(MeshShrink, "Shrink", shell.Mesh.ShrinkSelection)
        {
            Description = "Drop the selection's boundary: the elements with a neighbor that is not selected.",
            Icon = "collapse",
            CanExecuteWhen = () => shell.Mesh.InMeshMode && !shell.Mesh.MeshSelection.IsEmpty,
        });
        commands.Register(new Command(MeshKeepPlanar, "Keep Planar", shell.Mesh.ToggleKeepPlanar)
        {
            Description = "A Move drag keeps the faces it would bend flat, by moving their other vertices along.",
            Icon = "mesh",
            CanExecuteWhen = () => shell.Mesh.InMeshMode,
            IsCheckedWhen = () => shell.Mesh.KeepPlanar,
        });
        commands.Register(new Command(MeshEditPivot, "Edit Pivot", shell.Mesh.ToggleEditPivot)
        {
            Description = "The gizmo moves the mesh's entity, with the geometry staying where it is. Snap puts the pivot on the grid.",
            Icon = "move",
            CanExecuteWhen = () => shell.Mesh.InMeshMode,
            IsCheckedWhen = () => shell.Mesh.EditPivot,
        });
        commands.Register(new Command(MeshCenterPivot, "Center Pivot", () => shell.Mesh.CenterPivot())
        {
            Description = "Put the mesh's entity at the center of its bounds, with the geometry staying where it is.",
            Icon = "frame",
            CanExecuteWhen = () => shell.Mesh.CanEditInMeshMode,
        });
        commands.Register(new Command(MeshPivotToGrid, "Pivot to Grid", () => shell.Mesh.PivotToGrid())
        {
            Description = "Snap the mesh's entity to the grid, with the geometry staying where it is.",
            Icon = "snap",
            CanExecuteWhen = () => shell.Mesh.CanEditInMeshMode,
        });
        commands.Register(new Command(MeshGridToggle, "Show Grid", shell.Mesh.ToggleShowGrid)
        {
            Description = "Draw the grid that mesh mode snaps to, on the plane through the selection facing the camera.",
            Icon = "snap",
            IsCheckedWhen = () => shell.Mesh.ShowGrid,
        });
        commands.Register(new Command(MeshGridFiner, "Finer Grid", shell.Mesh.FinerGrid)
        {
            Description = "Halve the grid's size, down to 1/64 m. [ in the viewport.",
            Icon = "chevron-down",
            CanExecuteWhen = () => shell.Mesh.GridSize > MeshGrid.MinSize,
        });
        commands.Register(new Command(MeshGridCoarser, "Coarser Grid", shell.Mesh.CoarserGrid)
        {
            Description = "Double the grid's size, up to 16 m. ] in the viewport.",
            Icon = "collapse",
            CanExecuteWhen = () => shell.Mesh.GridSize < MeshGrid.MaxSize,
        });
        commands.Register(new Command(MeshSelectThrough, "Select Through", shell.Mesh.ToggleSelectThrough)
        {
            Description = "Let a box and a click in mesh mode take faces that face away, and their vertices and edges.",
            Icon = "visible",
            IsCheckedWhen = () => shell.Mesh.SelectThrough,
        });
    }
}
