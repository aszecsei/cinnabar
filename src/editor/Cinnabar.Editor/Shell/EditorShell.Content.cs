using System.ComponentModel;
using System.Diagnostics;
using Cinnabar.Editor.Content;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;
using AssetKind = Cinnabar.Editor.Link.Cook.AssetKind;

namespace Cinnabar.Editor.Shell;

/// <summary>The content roots: the cook daemon, its index, and what the content browser does with an asset.</summary>
public sealed partial class EditorShell
{
    /// <summary>The cook daemon's index, which the content browser shows.</summary>
    public AssetIndex Assets { get; } = new();

    public CookSession Cook { get; }

    /// <summary>The user asked to open a scene file. The window asks about unsaved changes, and calls <see cref="OpenScene"/>.</summary>
    public event Action<string>? OpenSceneFileRequested;

    /// <summary>Starts the cook daemon. The window does this once it opens, so tests of the shell start none.</summary>
    public void StartCook() => Cook.Start();

    public void RequestOpenScene(string path)
    {
        if (Scene != null && string.Equals(Path.GetFullPath(Scene.Path), Path.GetFullPath(path), StringComparison.OrdinalIgnoreCase))
        {
            return;
        }
        OpenSceneFileRequested?.Invoke(path);
    }

    /// <summary>
    /// Opens an asset as a double click does: a scene in the editor, a material graph or a material function in the
    /// material editor, and the text assets (scripts, shaders, shading models, HLSL materials and material instances)
    /// in the script editor. Textures, models and meshes have no editor yet.
    /// </summary>
    public void OpenAsset(Link.Cook.Asset asset)
    {
        if (Assets.FullPath(asset) is not { } path)
        {
            return;
        }
        switch (asset.Kind)
        {
            case AssetKind.Scene or AssetKind.Prefab:
                RequestOpenScene(path);
                break;
            case AssetKind.MaterialFunction:
                OpenMaterial(asset);
                break;
            case AssetKind.Material when !IsHlslMaterial(path):
                OpenMaterial(asset);
                break;
            case AssetKind.Script or AssetKind.Shader or AssetKind.ShadingModel or AssetKind.Material or AssetKind.MaterialInstance
                or AssetKind.Effect:
                OpenScript(path);
                break;
        }
    }

    static bool IsHlslMaterial(string path)
    {
        try
        {
            return MaterialFile.IsHlsl(File.ReadAllText(path));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return true;
        }
    }

    /// <summary>Whether a double click opens the asset (see <see cref="OpenAsset"/>).</summary>
    public static bool CanOpen(Link.Cook.Asset asset) =>
        asset.Kind is AssetKind.Scene or AssetKind.Script or AssetKind.Shader or AssetKind.ShadingModel or AssetKind.Material or AssetKind.MaterialInstance
            or AssetKind.MaterialFunction or AssetKind.Effect;

    /// <summary>What opening an asset is called in its menu.</summary>
    public string OpenLabel(Link.Cook.Asset asset) => asset.Kind switch
    {
        AssetKind.Scene => "Open Scene",
        AssetKind.MaterialFunction => "Open in Material Editor",
        AssetKind.Material when Assets.FullPath(asset) is { } path && !IsHlslMaterial(path) => "Open in Material Editor",
        _ => "Open in Script Editor",
    };

    /// <summary>
    /// Opens a file in the script editor that the settings name (see <see cref="EditorSettings.ScriptEditor"/>), at a
    /// line if one is given.
    /// </summary>
    public void OpenScript(string path, uint line = 0)
    {
        var command = Settings.ScriptEditor();
        var args = command.Select(a => a.Replace("{file}", path).Replace("{line}", Math.Max(line, 1).ToString())).ToList();
        try
        {
            // A script editor's command is often a batch file, such as VS Code's code.cmd, which only cmd runs.
            var info = new ProcessStartInfo("cmd.exe", ["/c", .. args]) { UseShellExecute = false, CreateNoWindow = true };
            Process.Start(info)?.Dispose();
        }
        catch (Win32Exception e)
        {
            Console.Add(LogLevel.Warning, $"content: cannot run {string.Join(' ', args)}: {e.Message}");
        }
    }

    /// <summary>Shows a file in Explorer, selected.</summary>
    public void ShowInExplorer(string path)
    {
        try
        {
            Process.Start(new ProcessStartInfo("explorer.exe", [$"/select,{path}"]) { UseShellExecute = false })?.Dispose();
        }
        catch (Win32Exception e)
        {
            Console.Add(LogLevel.Warning, $"content: cannot show {path}: {e.Message}");
        }
    }

    /// <summary>
    /// Adds a script's behaviour to scene entities, as one undo entry, to each that does not have it yet. The script
    /// must define a behaviour.
    /// </summary>
    public bool AddBehaviour(IEnumerable<ulong> sceneIds, string script)
    {
        if (Assets.Find(script) is not { Kind: AssetKind.Script, Behaviour: not "" } asset)
        {
            Console.Add(LogLevel.Warning, "edit: only a script that defines a behaviour adds one");
            return false;
        }
        var entities = sceneIds.Select(id => Scene?.Expanded.Flat.Find(id)).OfType<SceneEntity>()
            .Where(e => !e.Behaviours.Any(b => b.Script == script)).ToList();
        if (entities.Count == 0)
        {
            return false;
        }
        // The host attaches a new behaviour last, and so does the document.
        return Edit($"Add {FieldValues.Humanize(asset.Behaviour)}",
            [.. entities.Select(e => (Operation)new AddBehaviour(e.Id, new SceneBehaviour(script, []), int.MaxValue))]);
    }

    /// <summary>Whether a drop of an asset could add a behaviour to the scene entities.</summary>
    public bool CanAddBehaviour(IEnumerable<ulong> sceneIds, string script) =>
        IsEditing && Assets.Find(script) is { Kind: AssetKind.Script, Behaviour: not "" }
        && sceneIds.Select(id => Scene?.Expanded.Flat.Find(id)).OfType<SceneEntity>().Any(e => !e.Behaviours.Any(b => b.Script == script));

    void WireCook()
    {
        Cook.Output += Console.Add;
        Cook.LogReceived += log => Console.Add(ConsoleLog.Level(log.Level), ConsoleLog.Format(log));
        Cook.StateChanged += Commands.InvalidateAll;
        // A new cook link has cooked no previews.
        Cook.StateChanged += () =>
        {
            if (Cook.State == CookState.Linked)
            {
                foreach (var editor in _materials)
                {
                    _ = editor.CookNow();
                }
            }
        };
    }
}
