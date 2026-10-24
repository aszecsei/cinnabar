using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Commands.Ribbon;
using Cinnabar.Editor.Docking;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Host;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Viewport;
using FrameAcknowledged = Cinnabar.Editor.Link.Protocol.FrameAcknowledged;
using ReloadKind = Cinnabar.Editor.Link.Protocol.ReloadKind;
using UnwatchEntity = Cinnabar.Editor.Link.Protocol.UnwatchEntity;
using ViewportSize = Cinnabar.Editor.Link.Protocol.ViewportSize;
using WatchEntity = Cinnabar.Editor.Link.Protocol.WatchEntity;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The editor's parts and how they connect: the host, the viewport, the panels and their layout, the commands and
/// the ribbon. The window shows a shell, and the shell has no controls of its own, so tests can build one.
/// </summary>
public sealed class EditorShell : IDisposable
{
    public EditorSettings Settings { get; }
    public CommandRegistry Commands { get; } = new();
    public EditorContext Context { get; } = new();
    public ConsoleLog Console { get; } = new();
    public HostSession Host { get; }
    public ViewportSession Viewport { get; } = new();
    public WorldModel World { get; } = new();
    public Selection Selection { get; } = new();
    public EditorLayout Layout { get; }
    public RibbonLayout Ribbon { get; }
    public KeyBindings KeyBindings { get; }

    bool _ribbonCollapsed;
    bool _linked;

    /// <summary>The open scene, which the host's world mirrors. Null until one is opened.</summary>
    public SceneDocument? Scene { get; private set; }

    public event Action? SceneChanged;

    /// <summary>The user asked to pick a scene file. The window shows the picker, and calls <see cref="OpenScene"/>.</summary>
    public event Action? OpenSceneRequested;

    public bool RibbonCollapsed
    {
        get => _ribbonCollapsed;
        set
        {
            if (_ribbonCollapsed != value)
            {
                _ribbonCollapsed = value;
                RibbonCollapsedChanged?.Invoke();
            }
        }
    }

    public event Action? RibbonCollapsedChanged;

    public event Action? PaletteRequested;

    public EditorShell(EditorOptions options, EditorSettings settings)
    {
        Settings = settings;
        Host = new HostSession(options);
        Layout = new EditorLayout(CreatePanels(), new ViewportDocument(Viewport));
        RestoreLayout();

        Viewport.AdapterFound += Host.Start;
        Viewport.Failed += message => Console.Add(LogLevel.Error, message);
        Viewport.SizeRequested += size => Host.Send(new ViewportSize(size.Width, size.Height));
        Viewport.FrameCopied += (generation, frame) => Host.Send(new FrameAcknowledged(generation, frame));
        Host.Output += Console.Add;
        Host.LogReceived += log => Console.Add(ConsoleLog.Level(log.Level), ConsoleLog.Format(log));
        Host.FrameTargetChanged += target => Viewport.Connect(target.Prefix, target.Generation);
        // A soft restart starts the game with its own scene, so the editor sends the document again.
        Host.GameReloaded += kind =>
        {
            if (kind == ReloadKind.SoftRestart)
            {
                SendScene();
            }
        };
        Host.GameMessage += message => World.Apply(message);
        Host.StateChanged += OnHostStateChanged;
        // The editor watches the selected entity, so the properties panel has its values.
        Selection.Changed += (old, entity) =>
        {
            if (old != 0)
            {
                Host.Send(new UnwatchEntity(old));
            }
            if (entity != 0)
            {
                Host.Send(new WatchEntity(entity));
            }
        };
        // A snapshot means a new stream from the game, which knows no watches yet.
        World.Reset += () =>
        {
            if (!Selection.IsEmpty)
            {
                Host.Send(new WatchEntity(Selection.Entity));
            }
        };
        World.EntitiesChanged += () =>
        {
            if (!Selection.IsEmpty && World.Find(Selection.Entity) == null)
            {
                Selection.Clear();
            }
        };
        Layout.Changed += Commands.InvalidateAll;

        EditorCommands.Register(this);
        Ribbon = DefaultRibbon.Create(Layout.Panels);
        foreach (var error in Ribbon.Validate(Commands))
        {
            Console.Add(LogLevel.Error, error);
        }
        var (overrides, warning) = settings.ReadKeyBindings();
        if (warning != null)
        {
            Console.Add(LogLevel.Warning, warning);
        }
        KeyBindings = new KeyBindings(Commands, overrides);
        foreach (var w in KeyBindings.Warnings)
        {
            Console.Add(LogLevel.Warning, w);
        }
        if (options.ScenePath != null)
        {
            OpenScene(options.ScenePath);
        }
    }

    public void RequestOpenScene() => OpenSceneRequested?.Invoke();

    /// <summary>
    /// Opens a scene file, and replaces the host's world with it. A file with an error is not opened: the problems go
    /// to the console with their lines, and the scene that was open stays.
    /// </summary>
    public bool OpenScene(string path)
    {
        var (document, problems) = SceneDocument.Open(path);
        foreach (var p in problems)
        {
            var location = p.Line > 0 ? $"{path}:{p.Line}" : path;
            Console.Add(p.IsError ? LogLevel.Error : LogLevel.Warning, $"scene: {location}: {p.Message}");
        }
        if (document == null)
        {
            Console.Add(LogLevel.Error, $"scene: cannot open {path}");
            return false;
        }
        Scene = document;
        Console.Add(LogLevel.Info, $"scene: opened {document.Path}, {document.Scene.Entities.Count} entities");
        SceneChanged?.Invoke();
        SendScene();
        return true;
    }

    // The host replaces its world with the document. Its next entity snapshot shows the result.
    void SendScene()
    {
        if (Scene != null && Host.Linked)
        {
            Host.Send(SceneSnapshot.ToMessage(Scene.Scene));
        }
    }

    public void RequestPalette() => PaletteRequested?.Invoke();

    IEnumerable<PanelTool> CreatePanels()
    {
        PanelTool Empty(string id, string title, string icon, string dock, string message) =>
            new(id, title, icon, dock, () => new EmptyPanelView(message));

        yield return new PanelTool("outliner", "Outliner", "outliner", EditorLayout.LeftDock, () => new OutlinerView(World, Selection));
        yield return new PanelTool("properties", "Properties", "properties", EditorLayout.RightDock, () => new PropertiesView(World, Selection));
        yield return Empty("undoHistory", "Undo History", "history", EditorLayout.RightDock,
            "Edits appear here once scenes can be edited.");
        yield return new PanelTool("console", "Console", "console", EditorLayout.BottomDock, () => new ConsoleView(Console));
        yield return Empty("assetBrowser", "Asset Browser", "assets", EditorLayout.BottomDock,
            "The content roots appear here once the cook daemon runs.");
        yield return Empty("resourceMonitor", "Resource Monitor", "monitor", EditorLayout.BottomDock,
            "Frame times, memory and GPU counters arrive over the editor link.");
    }

    void OnHostStateChanged()
    {
        // A new link is a host that has its own world, from a start, a restart or a crash.
        if (Host.Linked && !_linked)
        {
            SendScene();
        }
        _linked = Host.Linked;
        if (!Host.Linked)
        {
            Viewport.Disconnect();
            if (World.HasWorld)
            {
                World.Clear();
            }
        }
        else if (Viewport.RequestedSize is { Width: > 0, Height: > 0 } size)
        {
            // The viewport asked before the host could hear it.
            Host.Send(new ViewportSize(size.Width, size.Height));
        }
        Context.Set("host.running", Host.State == HostState.Running);
        Commands.InvalidateAll();
    }

    void RestoreLayout()
    {
        if (Settings.Read(EditorSettings.LayoutFileName) is not { } json)
        {
            return;
        }
        if (LayoutFile.FromJson(json) is not { } file || !Layout.Restore(file))
        {
            Console.Add(LogLevel.Warning, $"layout: {Path.Combine(Settings.Directory, EditorSettings.LayoutFileName)} is not a layout of this editor, so the default layout is used");
        }
    }

    public void SaveLayout() => Settings.Write(EditorSettings.LayoutFileName, Layout.Save().ToJson());

    public void Dispose()
    {
        Host.Dispose();
        Viewport.Dispose();
    }
}
