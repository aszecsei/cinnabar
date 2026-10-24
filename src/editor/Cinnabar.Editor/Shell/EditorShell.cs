using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Commands.Ribbon;
using Cinnabar.Editor.Content;
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
public sealed partial class EditorShell : IDisposable
{
    public EditorSettings Settings { get; }
    public CommandRegistry Commands { get; } = new();
    public EditorContext Context { get; } = new();
    public ConsoleLog Console { get; } = new();
    public HostSession Host { get; }
    public ViewportSession Viewport { get; } = new();
    public WorldModel World { get; } = new();
    public ResourceStats Stats { get; } = new();
    public Selection Selection { get; } = new();
    public EditorLayout Layout { get; }
    public RibbonLayout Ribbon { get; private set; }

    /// <summary>The ribbon's layout changed, as when the game's commands change.</summary>
    public event Action? RibbonChanged;
    public KeyBindings KeyBindings { get; }

    bool _ribbonCollapsed;
    bool _linked;

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
        Cook = new CookSession(options.Cook, Assets);
        WireCook();
        Autosave = new Autosave(options.AutosaveDirectory);
        Layout = new EditorLayout(CreatePanels(), new ViewportDocument(Viewport, () => new ViewportView(this)));
        RestoreLayout();

        Viewport.AdapterFound += Host.Start;
        Viewport.Failed += message => Console.Add(LogLevel.Error, message);
        Viewport.SizeRequested += size => Host.Send(new ViewportSize(size.Width, size.Height));
        Viewport.FrameCopied += (generation, frame) => Host.Send(new FrameAcknowledged(generation, frame));
        Host.Output += Console.Add;
        Host.LogReceived += log => Console.Add(ConsoleLog.Level(log.Level), ConsoleLog.Format(log));
        Host.FrameTargetChanged += target =>
        {
            Viewport.Connect(target.Prefix, target.Generation);
            // The gizmo keeps its size on screen, so a new frame size changes it.
            SendGizmo();
        };
        // A soft restart starts the game with its own scene, so the editor sends the document again.
        Host.GameReloaded += kind =>
        {
            if (kind == ReloadKind.SoftRestart)
            {
                // The new game state starts in Edit, with the game's own scene.
                ResetMode();
                SendScene();
            }
        };
        Host.GameMessage += OnGameMessage;
        Host.StateChanged += OnHostStateChanged;
        // The editor watches the selected entities, so the properties panel has their values, and the game outlines them.
        Selection.Changed += (old, entities) =>
        {
            _selectedSceneIds = [.. entities.Select(e => World.Find(e)?.SceneId ?? 0).Where(id => id != 0)];
            foreach (var gone in old.Except(entities))
            {
                Host.Send(new UnwatchEntity(gone));
            }
            foreach (var added in entities.Except(old))
            {
                Host.Send(new WatchEntity(added));
            }
            SendSelection();
            CancelGizmo();
            SendGizmo();
        };
        // A snapshot means a new stream from the game, which knows no watches and no selection yet.
        World.Reset += () =>
        {
            foreach (var entity in Selection.Entities)
            {
                Host.Send(new WatchEntity(entity));
            }
            SendSelection();
            ResendHidden();
        };
        World.EntitiesChanged += OnEntitiesChanged;
        // An entity that comes back, as an undone delete does, gets a new handle, which the game must hide again.
        World.EntitiesChanged += SendHidden;
        Layout.Changed += Commands.InvalidateAll;
        // Commands such as Delete act on the selected entities.
        Selection.Changed += (_, _) => Commands.InvalidateAll();
        Camera.Changed += SendCamera;

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

    public void RequestPalette() => PaletteRequested?.Invoke();

    IEnumerable<PanelTool> CreatePanels()
    {
        yield return new PanelTool("outliner", "Outliner", "outliner", EditorLayout.LeftDock, () => new OutlinerView(this));
        yield return new PanelTool("properties", "Properties", "properties", EditorLayout.RightDock, () => new PropertiesView(this));
        yield return new PanelTool("undoHistory", "Undo History", "history", EditorLayout.RightDock, () => new UndoHistoryView(this));
        yield return new PanelTool("console", "Console", "console", EditorLayout.BottomDock, () => new ConsoleView(Console));
        yield return new PanelTool("contentBrowser", "Content Browser", "assets", EditorLayout.BottomDock, () => new ContentBrowserView(this));
        yield return new PanelTool("resourceMonitor", "Resource Monitor", "monitor", EditorLayout.BottomDock, () => new ResourceMonitorView(Stats));
    }

    void OnHostStateChanged()
    {
        // A new link is a host that has its own world, from a start, a restart or a crash.
        if (Host.Linked && !_linked)
        {
            ResetMode();
            SendScene();
            SendViewportTools();
        }
        _linked = Host.Linked;
        if (!Host.Linked)
        {
            Viewport.Disconnect();
            if (Stats.Host != null || Stats.Game != null)
            {
                Stats.Clear();
            }
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
        Cook.Dispose();
        Viewport.Dispose();
    }
}
