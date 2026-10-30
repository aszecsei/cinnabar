using Cinnabar.Editor.Commands;

namespace Cinnabar.Editor.Shell;

static partial class EditorCommands
{
    static void RegisterContent(EditorShell shell)
    {
        var commands = shell.Commands;
        // The asset commands act on the content browser's folder and selection. Their keys, F2, Ctrl+D and Delete, work
        // while the content browser has focus, as the same keys act on entities elsewhere.
        NewAssetCommand(shell, NewScript, Link.Cook.AssetTemplate.Script, "New Script", "script", "Add a Luau module to the content browser's folder.");
        NewAssetCommand(shell, NewBehaviour, Link.Cook.AssetTemplate.Behaviour, "New Behaviour", "script", "Add a script that defines a behaviour, named for its file, to the content browser's folder.");
        NewAssetCommand(shell, NewSceneAsset, Link.Cook.AssetTemplate.Scene, "New Scene", "scene", "Add an empty scene to the content browser's folder.");
        NewAssetCommand(shell, NewMaterial, Link.Cook.AssetTemplate.Material, "New Material", "material", "Add a material graph, lit, to the content browser's folder.");
        NewAssetCommand(shell, NewMaterialFunction, Link.Cook.AssetTemplate.MaterialFunction, "New Material Function", "material-function", "Add a material function, a graph that materials call as a node, to the content browser's folder.");
        NewAssetCommand(shell, NewMesh, Link.Cook.AssetTemplate.Mesh, "New Mesh", "mesh", "Add a mesh file, a 1 m box to build level geometry from, to the content browser's folder.");
        NewAssetCommand(shell, NewPrefab, Link.Cook.AssetTemplate.Prefab, "New Prefab", "prefab", "Add a prefab, an entity that scenes place as instances, to the content browser's folder.");
        NewAssetCommand(shell, NewEffect, Link.Cook.AssetTemplate.Effect, "New Effect", "effect", "Add an effect, emitters of particles that a Particle_System places, to the content browser's folder.");
        NewAssetCommand(shell, NewFolder, null, "New Folder", "folder", "Add a folder to the content browser's folder.");
        commands.Register(new Command(RenameAsset, "Rename Asset", shell.RequestRenameSelected)
        {
            Description = "Rename the asset selected in the content browser, with its .meta file. F2 in the content browser.",
            CanExecuteWhen = () => shell.CanChangeContent && shell.SelectedAssets.Count == 1 && !shell.SelectionHasSubassets,
        });
        commands.Register(new Command(DuplicateAsset, "Duplicate Asset", () => _ = shell.DuplicateSelectedAssets())
        {
            Description = "Copy the assets selected in the content browser, each with a new GUID. Ctrl+D in the content browser.",
            Icon = "copy",
            CanExecuteWhen = () => shell.CanChangeContent && shell.SelectedAssets.Count > 0 && !shell.SelectionHasSubassets,
        });
        commands.Register(new Command(DeleteAsset, "Delete Asset", shell.RequestDeleteSelected)
        {
            Description = "Send the assets selected in the content browser to the Recycle Bin, after showing what uses them. Delete in the content browser.",
            Icon = "delete",
            CanExecuteWhen = () => shell.CanChangeContent && shell.SelectedAssets.Count > 0 && !shell.SelectionHasSubassets,
        });
        commands.Register(new Command(Reimport, "Re-import", () => _ = shell.ReimportSelectedAssets())
        {
            Description = "Cook the assets selected in the content browser again, also when they are up to date.",
            Icon = "restart",
            CanExecuteWhen = () => shell.CanChangeContent && shell.SelectedAssets.Count > 0 && !shell.SelectionHasSubassets,
        });
    }

    static void NewAssetCommand(EditorShell shell, string id, Link.Cook.AssetTemplate? template, string label, string icon, string description) =>
        shell.Commands.Register(new Command(id, label, () => shell.RequestNewAsset(template))
        {
            Description = description,
            Icon = icon,
            CanExecuteWhen = () => shell.CanChangeContent && shell.ContentFolder != null,
        });
}
