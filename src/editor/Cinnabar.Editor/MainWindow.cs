using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using Cinnabar.Editor.Content;
using Cinnabar.Editor.Host;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Ribbon;
using Cinnabar.Editor.Shell;
using Dock.Avalonia.Controls;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor;

/// <summary>The shell's window: the ribbon, the docked panels, the status bar and the command palette.</summary>
public sealed class MainWindow : Window
{
    readonly EditorShell _shell;
    readonly TextBlock _hostStatus = new();
    readonly TextBlock _cookStatus = new();
    readonly TextBlock _worldStatus = new();
    readonly TextBlock _sceneStatus = new();
    readonly TextBlock _modeStatus = new() { Text = "Edit" };
    Border? _status;
    readonly Ellipse _hostDot = new() { Width = 8, Height = 8, VerticalAlignment = VerticalAlignment.Center };
    readonly Ellipse _cookDot = new() { Width = 8, Height = 8, VerticalAlignment = VerticalAlignment.Center };
    // The autosave is due at most every 30 s, so a check every few seconds is close enough.
    readonly DispatcherTimer _autosave = new() { Interval = TimeSpan.FromSeconds(5) };
    // Set once the user has answered about unsaved changes, so the second Close goes through.
    bool _closing;

    public MainWindow(EditorShell shell)
    {
        _shell = shell;
        Title = "cinnabar editor";
        Width = 1600;
        Height = 900;

        var views = new CommandViews(shell.Commands, shell.KeyBindings);
        var ribbon = new RibbonView(shell, views);
        var dock = new DockControl
        {
            Factory = shell.Layout.Factory,
            Layout = shell.Layout.Root,
            InitializeFactory = true,
            InitializeLayout = false,
        };
        shell.Layout.RootChanged += () => dock.Layout = shell.Layout.Root;

        var main = new DockPanel();
        DockPanel.SetDock(ribbon, DockSide.Top);
        main.Children.Add(ribbon);
        var status = StatusBar();
        DockPanel.SetDock(status, DockSide.Bottom);
        main.Children.Add(status);
        main.Children.Add(dock);

        var palette = new CommandPalette(views);
        shell.PaletteRequested += palette.Open;
        shell.OpenSceneRequested += () => _ = PickScene();
        shell.OpenSceneFileRequested += path => _ = OpenSceneFile(path);
        shell.SaveAsRequested += () => _ = PickSaveAs();
        shell.RestoreOffered += () => _ = OfferRestore();
        shell.Content.NewAssetRequested += template => _ = AskNewAsset(template);
        shell.MakePrefabRequested += name => _ = AskMakePrefab(name);
        shell.MakeVariantRequested += name => _ = AskMakeVariant(name);
        shell.Content.RenameRequested += item => _ = AskRename(item);
        shell.Content.DeleteRequested += items => _ = ConfirmDelete(items);
        shell.Content.OperationFailed += error => _ = Dialogs.Ask(this, "The content did not change", error, "OK");
        shell.MaterialCloseRequested += editor => _ = AskCloseMaterial(editor);
        shell.SceneChanged += UpdateSceneStatus;
        UpdateSceneStatus();
        Content = new Grid { Children = { main, palette } };

        foreach (var (id, shortcut) in shell.KeyBindings.All)
        {
            if (views.Gesture(id) is { } gesture)
            {
                KeyBindings.Add(new KeyBinding { Gesture = gesture, Command = views.Adapter(id) });
            }
            else
            {
                shell.Console.Add(LogLevel.Warning, $"key bindings: {shortcut} for {id} is not a key gesture");
            }
        }

        shell.Host.StateChanged += UpdateHostStatus;
        UpdateHostStatus();
        shell.Cook.StateChanged += UpdateCookStatus;
        UpdateCookStatus();
        shell.World.EntitiesChanged += UpdateWorldStatus;
        shell.Selection.Changed += (_, _) => UpdateWorldStatus();
        shell.ModeChanged += UpdateModeStatus;
        shell.Mesh.MeshModeChanged += UpdateModeStatus;
        _autosave.Tick += (_, _) => shell.Tick(DateTime.UtcNow);
        _autosave.Start();
        // The command line's scene opened before the window could ask about its autosave.
        Opened += (_, _) =>
        {
            shell.StartCook();
            shell.StartAutomation();
            if (shell.PendingRestore != null)
            {
                _ = OfferRestore();
            }
        };
        Closing += OnClosing;
        Closed += (_, _) =>
        {
            _autosave.Stop();
            shell.Dispose();
        };
    }

    async void OnClosing(object? sender, WindowClosingEventArgs e)
    {
        if (_closing)
        {
            return;
        }
        e.Cancel = true;
        if (await ConfirmDiscardMaterials() && await ConfirmDiscard("closing"))
        {
            _closing = true;
            _shell.SaveLayout();
            Close();
        }
    }

    /// <summary>Asks about a material editor's unsaved changes when its document closes.</summary>
    async Task AskCloseMaterial(Shell.MaterialEditor editor)
    {
        var answer = await Dialogs.Ask(this, "Unsaved changes", $"{editor.Document.Title} has changes that are not saved. Save them before closing it?",
            "Save", "Don't Save", "Cancel");
        if (answer is "Save" or "Don't Save")
        {
            _shell.CloseMaterial(editor, discard: answer == "Don't Save");
        }
    }

    // Asks about each material editor's unsaved changes before the editor closes, and returns whether to go on.
    async Task<bool> ConfirmDiscardMaterials()
    {
        foreach (var editor in _shell.Materials.Where(m => m.Document.IsDirty).ToList())
        {
            var answer = await Dialogs.Ask(this, "Unsaved changes", $"{editor.Document.Title} has changes that are not saved. Save them before closing?",
                "Save", "Don't Save", "Cancel");
            if (answer == "Cancel" || answer == null || (answer == "Save" && !_shell.SaveMaterial(editor)))
            {
                return false;
            }
        }
        return true;
    }

    /// <summary>Asks about unsaved changes, the scene's and its meshes', before they would be lost, and returns whether to go on.</summary>
    async Task<bool> ConfirmDiscard(string doing)
    {
        if (_shell.Scene is not { } scene || (!scene.IsDirty && !_shell.Mesh.Meshes.AnyDirty))
        {
            return true;
        }
        var what = scene.IsDirty
            ? _shell.Mesh.Meshes.AnyDirty ? $"{scene.Title} and its meshes have" : $"{scene.Title} has"
            : $"The meshes of {scene.Title} have";
        var answer = await Dialogs.Ask(this, "Unsaved changes", $"{what} changes that are not saved. Save them before {doing}?",
            "Save", "Don't Save", "Cancel");
        switch (answer)
        {
            case "Save":
                return _shell.SaveScene();
            case "Don't Save":
                _shell.DiscardChanges();
                return true;
            default:
                return false;
        }
    }

    async Task OfferRestore()
    {
        if (_shell.Scene is not { } scene || _shell.PendingRestore is not { } autosave)
        {
            return;
        }
        var when = File.GetLastWriteTime(autosave).ToString("g", System.Globalization.CultureInfo.CurrentCulture);
        var answer = await Dialogs.Ask(this, "Restore unsaved changes",
            $"The editor autosaved changes to {scene.Title} at {when} that the file does not have. It may have closed without saving them. Restore them?",
            "Restore", "Discard");
        if (answer == "Restore")
        {
            _shell.RestoreAutosave();
        }
        else
        {
            _shell.DiscardAutosave();
        }
    }

    async Task AskMakePrefab(string suggested)
    {
        var place = _shell.Content.Folder is { } folder ? folder.Display : "the content browser's folder";
        var name = await Dialogs.AskName(this, "Make Prefab", $"Name the prefab, which the next save writes in {place}.", suggested, "Make");
        if (name != null)
        {
            _shell.MakePrefab(name);
        }
    }

    async Task AskMakeVariant(string suggested)
    {
        var place = _shell.Content.Folder is { } folder ? folder.Display : "the content browser's folder";
        var name = await Dialogs.AskName(this, "Make Variant", $"Name the variant, which the next save writes in {place}.", suggested, "Make");
        if (name != null)
        {
            _shell.MakeVariant(name);
        }
    }

    async Task AskNewAsset(Link.Cook.AssetTemplate? template)
    {
        if (_shell.Content.Folder is not { } folder)
        {
            return;
        }
        var (title, what) = template switch
        {
            Link.Cook.AssetTemplate.Script => ("New Script", "script"),
            Link.Cook.AssetTemplate.Behaviour => ("New Behaviour", "behaviour, whose class is named for its file,"),
            Link.Cook.AssetTemplate.Scene => ("New Scene", "scene"),
            Link.Cook.AssetTemplate.Material => ("New Material", "material"),
            Link.Cook.AssetTemplate.MaterialFunction => ("New Material Function", "material function"),
            Link.Cook.AssetTemplate.Mesh => ("New Mesh", "mesh, a 1 m box,"),
            Link.Cook.AssetTemplate.Prefab => ("New Prefab", "prefab"),
            Link.Cook.AssetTemplate.Effect => ("New Effect", "effect"),
            _ => ("New Folder", "folder"),
        };
        var place = folder.Display;
        var name = await Dialogs.AskName(this, title, $"Name the new {what} in {place}.", _shell.Content.NewName(template), "Create");
        if (name != null)
        {
            await _shell.Content.Create(template, name);
        }
    }

    async Task AskRename(Shell.ContentItem item)
    {
        string current;
        if (item.Guid is { } guid && _shell.Assets.Find(guid) is { } asset)
        {
            current = System.IO.Path.GetFileNameWithoutExtension(asset.Path);
        }
        else if (item.Folder is { Path: not "" } folder)
        {
            current = folder.Name;
        }
        else
        {
            return;
        }
        var name = await Dialogs.AskName(this, "Rename", $"Rename {current}. Its .meta file goes with it, so it keeps its GUID.", current, "Rename");
        if (name != null && name != current)
        {
            await _shell.Content.Rename(item, name);
        }
    }

    async Task ConfirmDelete(IReadOnlyList<Shell.ContentItem> items)
    {
        var (deleted, users) = _shell.Content.DeleteEffects(items);
        var names = items.Select(i => i.Guid is { } g ? _shell.Assets.Find(g)?.Path is { } p ? System.IO.Path.GetFileName(p) : null : i.Folder?.Name)
            .OfType<string>().ToList();
        if (names.Count == 0)
        {
            return;
        }
        var what = names.Count == 1 ? names[0] : $"{names.Count} items";
        var message = $"Send {what} to the Recycle Bin";
        message += deleted.Count > 0 && items.Any(i => i.Folder != null) ? $", with the {deleted.Count} {(deleted.Count == 1 ? "asset" : "assets")} in it?" : "?";
        if (users.Count > 0)
        {
            const int Shown = 8;
            var list = string.Join("\n", users.Take(Shown).Select(u => $"    {u.Root}/{u.Path}"));
            if (users.Count > Shown)
            {
                list += $"\n    and {users.Count - Shown} more";
            }
            message += $"\n\nThese use it, and will fail to cook until they no longer do:\n{list}";
        }
        if (await Dialogs.Ask(this, "Delete", message, "Delete", "Cancel") == "Delete")
        {
            await _shell.Content.Delete(items);
        }
    }

    async Task PickSaveAs()
    {
        if (_shell.Scene is not { } scene)
        {
            return;
        }
        var file = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = "Save Scene As",
            SuggestedFileName = scene.Title,
            DefaultExtension = Document.SceneFile.Extension,
            FileTypeChoices = [new FilePickerFileType("Scenes") { Patterns = [$"*{Document.SceneFile.Extension}"] }],
            SuggestedStartLocation = await StorageProvider.TryGetFolderFromPathAsync(System.IO.Path.GetDirectoryName(scene.Path)!),
        });
        if (file?.TryGetLocalPath() is { } path)
        {
            _shell.SaveScene(path);
        }
    }

    Control StatusBar()
    {
        var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16, Children = { _sceneStatus, _worldStatus, _modeStatus } };
        var left = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            Children = { _hostDot, _hostStatus, new Border { Width = 10 }, _cookDot, _cookStatus },
        };
        var bar = new DockPanel { Children = { right, left } };
        DockPanel.SetDock(right, DockSide.Right);
        _status = new Border { Classes = { "status" }, Child = bar };
        return _status;
    }

    async Task PickScene()
    {
        if (!await ConfirmDiscard("opening another scene"))
        {
            return;
        }
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "Open Scene",
            AllowMultiple = false,
            FileTypeFilter = [new FilePickerFileType("Scenes and prefabs") { Patterns = [$"*{Document.SceneFile.Extension}", $"*{Document.SceneFile.PrefabExtension}"] }],
            SuggestedStartLocation = _shell.Scene is { } open
                ? await StorageProvider.TryGetFolderFromPathAsync(System.IO.Path.GetDirectoryName(open.Path)!)
                : null,
        });
        if (files.Count == 1 && files[0].TryGetLocalPath() is { } path)
        {
            _shell.OpenScene(path);
        }
    }

    async Task OpenSceneFile(string path)
    {
        if (await ConfirmDiscard("opening another scene"))
        {
            _shell.OpenScene(path);
        }
    }

    void UpdateSceneStatus()
    {
        var scene = _shell.Scene;
        var dirty = scene is { IsDirty: true } ? " •" : "";
        Title = scene == null ? "cinnabar editor" : $"{scene.Title}{dirty} - cinnabar editor";
        // A prefab open as the document says so, since its rules differ from a scene's.
        _sceneStatus.Text = scene == null ? "No scene" : scene.IsPrefab ? $"Prefab  ·  {scene.Title}{dirty}" : scene.Title + dirty;
        ToolTip.SetTip(_sceneStatus, scene?.Path);
    }

    void UpdateWorldStatus()
    {
        var count = _shell.World.Entities.Count;
        var selected = _shell.Selection.Count switch
        {
            0 => "",
            1 => $"  ·  {_shell.World.Find(_shell.Selection.Entity)?.Label ?? Model.EntityNode.Format(_shell.Selection.Entity)} selected",
            var n => $"  ·  {n} selected",
        };
        _worldStatus.Text = _shell.World.HasWorld ? $"{count} {(count == 1 ? "entity" : "entities")}{selected}" : "";
    }

    // Play mode tints the status bar, as the viewport's frame, so nobody edits by mistake while the game runs.
    void UpdateModeStatus()
    {
        _modeStatus.Text = _shell.Mode switch
        {
            Link.Protocol.EditorMode.Play => _shell.FreeCamera ? "Play, free camera" : "Play",
            Link.Protocol.EditorMode.Paused => "Paused",
            _ => _shell.Mesh.InMeshMode ? $"Mesh  ·  {_shell.Mesh.MeshStatus}" : "Edit",
        };
        _status?.Classes.Set("playing", _shell.Mode == Link.Protocol.EditorMode.Play);
        _status?.Classes.Set("paused", _shell.Mode == Link.Protocol.EditorMode.Paused);
    }

    void UpdateCookStatus()
    {
        var cook = _shell.Cook;
        (_cookStatus.Text, _cookDot.Fill) = cook.State switch
        {
            CookState.Linked => ("Cook: watching", Brush.Parse("#4caf50")),
            CookState.Starting => ("Cook: starting, linking", Palette.WarningBrush),
            CookState.Stopped => ("Cook: stopped", Brushes.Gray),
            _ => ($"Cook: exited with code {cook.ExitCode}", Palette.ErrorBrush),
        };
    }

    void UpdateHostStatus()
    {
        var host = _shell.Host;
        (_hostStatus.Text, _hostDot.Fill) = host.State switch
        {
            HostState.Waiting => ("Host: waiting for the viewport", Brushes.Gray),
            HostState.Running when host.Linked => ($"Host: running {host.Game}, linked", Brush.Parse("#4caf50")),
            HostState.Running => ("Host: starting, linking", Palette.WarningBrush),
            HostState.Stopped => ("Host: stopped", Brushes.Gray),
            _ => ($"Host: exited with code {host.ExitCode}", Palette.ErrorBrush),
        };
    }
}
