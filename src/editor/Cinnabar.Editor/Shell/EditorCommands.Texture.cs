using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Mesh;

namespace Cinnabar.Editor.Shell;

static partial class EditorCommands
{
    static void RegisterTexture(EditorShell shell)
    {
        var commands = shell.Commands;
        // The texture tools (see docs/editor/mesh-editing.md#texture-tools), on the selected faces.
        TextureCommand(shell, TextureShiftLeft, "Shift Left", "move", () => shell.Mesh.ShiftTexture(1, 0), "Move the texture left on the selected faces by an eighth of a repeat. Left arrow in the viewport; Shift for ten times, Ctrl for a tenth.");
        TextureCommand(shell, TextureShiftRight, "Shift Right", "move", () => shell.Mesh.ShiftTexture(-1, 0), "Move the texture right on the selected faces by an eighth of a repeat. Right arrow in the viewport.");
        TextureCommand(shell, TextureShiftUp, "Shift Up", "move", () => shell.Mesh.ShiftTexture(0, 1), "Move the texture up on the selected faces by an eighth of a repeat. Up arrow in the viewport.");
        TextureCommand(shell, TextureShiftDown, "Shift Down", "move", () => shell.Mesh.ShiftTexture(0, -1), "Move the texture down on the selected faces by an eighth of a repeat. Down arrow in the viewport.");
        TextureCommand(shell, TextureRotateLeft, "Rotate Left", "rotate", () => shell.Mesh.RotateTexture(1), "Turn the texture on the selected faces by 15 degrees. , in the viewport.");
        TextureCommand(shell, TextureRotateRight, "Rotate Right", "rotate", () => shell.Mesh.RotateTexture(-1), "Turn the texture on the selected faces by 15 degrees the other way. . in the viewport.");
        TextureCommand(shell, TextureScaleUp, "Scale Up", "scale-tool", () => shell.Mesh.ScaleTexture(1), "Make the texture larger on the selected faces by a quarter. = in the viewport.");
        TextureCommand(shell, TextureScaleDown, "Scale Down", "scale-tool", () => shell.Mesh.ScaleTexture(-1), "Make the texture smaller on the selected faces by a quarter. - in the viewport.");
        TextureCommand(shell, TextureResetScale, "Reset Scale", "reset", shell.Mesh.ResetTextureScale, "Set the selected faces' scale from their texture's size at the project's texel density, so the dev grid's lines meet the grid again.");
        TextureCommand(shell, TextureAlignWorld, "Align World", "world", () => shell.Mesh.AlignTexture(TextureAlignment.World), "Set the selected faces' texture axes from each face's normal's nearest world axis, so neighbors across a right angle share a seam.");
        TextureCommand(shell, TextureAlignFace, "Align Face", "mesh", () => shell.Mesh.AlignTexture(TextureAlignment.Face), "Set the selected faces' texture axes from each face's own plane, with u along its longest edge.");
        commands.Register(new Command(TextureAlignEdge, "Align to Edge", () => shell.Mesh.AlignTexture(TextureAlignment.ToEdge))
        {
            Description = "Set the texture's u axis of each selected edge's faces along the edge. Select edges first.",
            Icon = "local",
            CanExecuteWhen = () => shell.Mesh.CanRunMeshTool(MeshElement.Edges),
        });
        TextureCommand(shell, TextureAlignToFace, "Align to Face", "copy", () => shell.Mesh.AlignTexture(TextureAlignment.ToFace), "Carry the active face's texture onto the other selected faces, turned around their shared edges, so it flows around a corner without a seam. Click the face to copy from, then Shift-click the others.");
        TextureCommand(shell, TextureFit, "Fit", "frame", () => shell.Mesh.FitTexture(true, true), "Scale and shift the texture so one repeat covers each selected face's bounding rectangle.");
        TextureCommand(shell, TextureFitU, "Fit U", "frame", () => shell.Mesh.FitTexture(true, false), "Fit the texture across each selected face, along u only.");
        TextureCommand(shell, TextureFitV, "Fit V", "frame", () => shell.Mesh.FitTexture(false, true), "Fit the texture down each selected face, along v only.");
        TextureCommand(shell, TextureJustifyLeft, "Justify Left", "select", () => shell.Mesh.JustifyTexture(Justification.Left), "Shift the texture so its left edge is on each selected face's left.");
        TextureCommand(shell, TextureJustifyRight, "Justify Right", "select", () => shell.Mesh.JustifyTexture(Justification.Right), "Shift the texture so its right edge is on each selected face's right.");
        TextureCommand(shell, TextureJustifyTop, "Justify Top", "select", () => shell.Mesh.JustifyTexture(Justification.Top), "Shift the texture so its top edge is on each selected face's top.");
        TextureCommand(shell, TextureJustifyBottom, "Justify Bottom", "select", () => shell.Mesh.JustifyTexture(Justification.Bottom), "Shift the texture so its bottom edge is on each selected face's bottom.");
        TextureCommand(shell, TextureJustifyCenter, "Justify Center", "select", () => shell.Mesh.JustifyTexture(Justification.Center), "Shift the texture so its center is on each selected face's center.");
        TextureCommand(shell, TextureFlipU, "Flip U", "undo", () => shell.Mesh.FlipTexture(true, false), "Mirror the texture across each selected face, left to right.");
        TextureCommand(shell, TextureFlipV, "Flip V", "redo", () => shell.Mesh.FlipTexture(false, true), "Mirror the texture across each selected face, top to bottom.");
        TextureCommand(shell, TextureHotspot, "Hotspot", "texture", () => shell.Mesh.ApplyHotspot(HotspotChoice.Best), "Map each selected face onto the hotspot rectangle of its material that fits its shape and size best. A material without hotspots gets Fit.");
        TextureCommand(shell, TextureHotspotNext, "Next Hotspot", "step", () => shell.Mesh.ApplyHotspot(HotspotChoice.Next), "Map each selected face onto the next best hotspot rectangle after the one it is on.");
        TextureCommand(shell, TextureHotspotRandom, "Random Hotspot", "snap", () => shell.Mesh.ApplyHotspot(HotspotChoice.Random), "Map each selected face onto its best hotspot rectangle, flipped or turned at random for variety.");
        commands.Register(new Command(MeshTransformTexture, "Transform Texture", shell.Mesh.ToggleTextureGizmo)
        {
            Description = "The gizmo shifts, turns or scales the selected faces' textures instead of moving their vertices, with the Move, Rotate and Scale tools.",
            Icon = "texture",
            CanExecuteWhen = () => shell.Mesh.InMeshMode,
            IsCheckedWhen = () => shell.Mesh.TextureGizmo,
        });
        commands.Register(new ChoiceCommand(MeshDevMaterial, "Dev Material", [.. MeshSession.DevMaterials.Select(d => d.Name)],
            () => MeshSession.DevMaterials.FirstOrDefault(d => shell.Mesh.SelectedFaces is [var (guid, face), ..] && shell.Mesh.Meshes.Find(guid)?.Data is { } m && face < m.Faces.Length && m.Materials[m.Faces[face].Slot] == d.Guid)?.Name ?? "Gray",
            name => shell.Mesh.SetFaceMaterial(MeshSession.DevMaterials.First(d => d.Name == name).Guid))
        {
            Description = "Give the selected faces one of the engine's dev materials: the measured grid in a color.",
            CanExecuteWhen = () => shell.Mesh.CanRunTextureTool,
        });
        commands.Register(new ChoiceCommand(MeshTexelDensity, "Density", MeshSession.DensityOptions, () => Nearest(MeshSession.DensityOptions, shell.Mesh.TexelDensity), v => shell.Mesh.SetTexelDensity(Number(v)))
        {
            Description = "The project's texel density, in texels per meter: what new faces and Reset Scale map the texture at. Saved in the project's settings.",
            CanExecuteWhen = () => shell.IsEditing,
        });
    }

    static void TextureCommand(EditorShell shell, string id, string label, string icon, Func<bool> run, string description) =>
        shell.Commands.Register(new Command(id, label, () => run())
        {
            Description = description,
            Icon = icon,
            CanExecuteWhen = () => shell.Mesh.CanRunTextureTool,
        });
}
