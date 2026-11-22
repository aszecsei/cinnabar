using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Commands.Ribbon;
using Cinnabar.Editor.Content;
using Cinnabar.Editor.Docking;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Host;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Viewport;
using ReloadKind = Cinnabar.Editor.Link.Protocol.ReloadKind;
using UnwatchEntity = Cinnabar.Editor.Link.Protocol.UnwatchEntity;
using WatchEntity = Cinnabar.Editor.Link.Protocol.WatchEntity;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The editor's parts and how they connect: the host, the viewport, the panels and their layout, the commands and
/// the ribbon. The window shows a shell, and the shell has no controls of its own, so tests can build one.
/// </summary>
public sealed partial class EditorShell : IDisposable, IMeshHost
{
    public EditorSettings Settings { get; }
    public CommandRegistry Commands { get; } = new();
    public EditorContext Context { get; } = new();
    public MeshSession Mesh { get; }
    /// <summary>The landscape tools' brushes and the maps they paint (see docs/editor/landscape.md).</summary>
    public LandscapeSession Landscape { get; }
    public ConsoleLog Console { get; } = new();
    public HostSession Host { get; }
    public WorldModel World { get; } = new();
    /// <summary>What owners such as a scrub write over the game's world in Edit, outside the document (see docs/editor/link.md#overrides).</summary>
    public WorldOverrides Overrides { get; }
    public ResourceStats Stats { get; } = new();
    public Selection Selection { get; } = new();
    public OutlinerState Outliner { get; } = new();
    public EditorLayout Layout { get; }
    public Workspaces Workspaces { get; }
    public RibbonLayout Ribbon { get; private set; }

    /// <summary>The ribbon's layout changed, as when the game's commands change.</summary>
    public event Action? RibbonChanged;
    public KeyBindings KeyBindings { get; }

    bool _ribbonCollapsed;

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

    /// <summary>The ribbon should show a tab, by its ID, as when a workspace becomes the active one.</summary>
    public event Action<string>? RibbonTabRequested;

    /// <summary>
    /// Makes a workspace the active one (see docs/editor/shell-and-panels.md#workspaces): the panels as it was left, and
    /// the ribbon on the tab that its work mostly uses.
    /// </summary>
    public void SwitchWorkspace(Workspace workspace)
    {
        if (Workspaces.Switch(workspace) && workspace.RibbonTab is { } tab)
        {
            RibbonTabRequested?.Invoke(tab);
        }
        Commands.InvalidateAll();
    }

    public event Action? PaletteRequested;

    readonly EditorOptions _options;

    public EditorShell(EditorOptions options, EditorSettings settings)
    {
        _options = options;
        Settings = settings;
        _previewSlots = new PreviewSlots(PreviewOwners);
        Mesh = new MeshSession(this);
        Landscape = new LandscapeSession(this);
        _gizmo = new GizmoController(label => TryBeginEdit(label, "the gizmo"), SendGizmo);
        Host = new HostSession(options);
        Overrides = new WorldOverrides(this);
        Watches = new EntityWatches(Selection, Host);
        Visibility = new SceneVisibility(World, Selection, Host, settings, Console, () => [.. _scenes.Select(s => (s.Number, s.Path))], WriteSetting, Commands.InvalidateAll);
        Cook = new CookSession(options.Cook, Assets);
        Builder = new ProjectTool(ProjectLayout.Tool(options.EngineRoot), options.EngineRoot, ChildProcess.Start);
        WireTool();
        PreviewCooker = Cook;
        Content = new ContentBrowser(Assets, Cook, Console, MovingScene, Commands.InvalidateAll, ProjectTags.PathFor(options.ProjectPath));
        WireCook();
        Mesh.Subscribe();
        // A saved map is let go of once its cooked blob is current, as a saved mesh is.
        Cook.Cooked += _ => Landscape.ReleaseCooked();
        Mesh.MeshModeChanged += () =>
        {
            if (Mesh.InMeshMode)
            {
                ClearNavProbe();
            }
        };
        Autosave = new Autosave(options.AutosaveDirectory);
        CreateViewports();
        Layout = new EditorLayout(CreatePanels(), new ViewportDocument(ViewportDocument.SceneId, "Scene", () => new SceneDocumentView(this)),
            new ViewportDocument(ViewportDocument.GameId, "Game", () => new ViewportView(this, GameViewport)));
        // The first workspace is the layout that the editor starts with, before a saved one replaces it.
        Workspaces = new Workspaces(Layout, WorkspacePresets.Create(Layout.Save()));
        RestoreLayout();

        Host.Output += Console.Add;
        Host.LogsReceived += (logs, dropped) =>
            Console.AddRange([.. logs.Select(log => new LogLine(ConsoleLog.Level(log.Level), ConsoleLog.Format(log)))], dropped, "game");
        // A soft restart makes a fresh Game_State. A code reload keeps it.
        Host.GameReloaded += kind =>
        {
            if (kind == ReloadKind.SoftRestart)
            {
                OnNewGameState();
            }
        };
        Host.GameMessage += OnGameMessage;
        // The game draws the shown world, which these change (see SendWorldView).
        SceneChanged += SendWorldView;
        ModeChanged += SendWorldView;
        ActiveViewportChanged += SendWorldView;
        Host.StateChanged += OnHostStateChanged;
        // The editor watches the selected entities, so the properties panel has their values, and the game outlines them.
        Selection.Changed += (old, entities) =>
        {
            _selectedSceneIds = [.. entities.Select(World.Find).OfType<EntityNode>().Where(n => n.SceneId != 0).Select(n => (n.Scene, n.SceneId))];
            // The primary entity's scene is the active one, which edits act on.
            FollowSelection();
            foreach (var gone in old.Except(entities).Where(e => !Watches.Contains(e)))
            {
                Host.Send(new UnwatchEntity(gone));
            }
            foreach (var added in entities.Except(old).Where(e => !Watches.Contains(e)))
            {
                Host.Send(new WatchEntity(added));
            }
            SendSelection();
            CancelGizmo();
            SendGizmo();
            Landscape.CancelStroke();
            Landscape.Sync();
        };
        // A snapshot means that every entity is new, so the game knows no watches, no selection and nothing hidden,
        // and the mesh overlay names entities by their old handles. What else a new game state lacks is OnNewGameState's.
        World.Reset += () =>
        {
            Mesh.ResendMeshOverlay();
            foreach (var entity in Selection.Entities.Union(Watches.Handles))
            {
                Host.Send(new WatchEntity(entity));
            }
            SendSelection();
            Visibility.Resend();
        };
        World.EntitiesChanged += OnEntitiesChanged;
        World.EntitiesChanged += UpdateWorldCamera;
        World.TypesChanged += UpdateWorldCamera;
        // An entity that comes back, as an undone delete does, gets a new handle, which the game must hide again.
        World.EntitiesChanged += Visibility.Send;
        Layout.Changed += Commands.InvalidateAll;
        Layout.ActiveDocumentChanged += OnActiveDocumentChanged;
        Layout.DocumentClosing = OnDocumentClosing;
        Layout.DocumentClosed += OnDocumentClosed;
        // Commands such as Delete act on the selected entities.
        Selection.Changed += (_, _) => Commands.InvalidateAll();

        EditorCommands.Register(this);
        LoadSublevelChoice();
        SyncSublevelCommands();
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
        _pendingMaterials.AddRange(options.MaterialPaths);
        _pendingMaterials.AddRange(options.EffectPaths);
        _pendingMaterials.AddRange(options.AnimationGraphPaths);
        _pendingMaterials.AddRange(options.UiDocumentPaths);
        _pendingMaterials.AddRange(options.DecisionPaths);
        _pendingMaterials.AddRange(options.CutscenePaths);
        Assets.Changed += OpenPendingMaterials;
        Assets.Changed += OpenPendingUi;
        Content.AssetCreated += OnAssetCreated;
        Assets.Changed += ExpandArrivedPrefabs;
        Assets.Changed += ReloadChangedPrefabs;
        Assets.Changed += SendWorldView;
    }

    public void RequestPalette() => PaletteRequested?.Invoke();

    GizmoController IMeshHost.Gizmos => _gizmo;

    bool IMeshHost.Pickable(ulong handle) => Pickable(handle);

    void IMeshHost.SendGizmo() => SendGizmo();

    void IMeshHost.Report(string area, string path, IEnumerable<(int Line, string Message, bool IsError)> problems) => Report(area, path, problems);

    IEnumerable<PanelTool> CreatePanels()
    {
        yield return new PanelTool("outliner", "Outliner", "outliner", EditorLayout.LeftDock, () => new OutlinerView(this));
        yield return new PanelTool("properties", "Properties", "properties", EditorLayout.RightDock, () => new PropertiesView(this));
        yield return new PanelTool("faceEditor", "Face", "mesh", EditorLayout.RightDock, () => new FaceEditorView(this));
        yield return new PanelTool("sublevels", "Sublevels", "stage", EditorLayout.RightDock, () => new SublevelsView(this));
        yield return new PanelTool("undoHistory", "Undo History", "history", EditorLayout.RightDock, () => new UndoHistoryView(this));
        yield return new PanelTool("atmosphere", "Atmosphere", "sky", EditorLayout.RightDock, () => new AtmosphereView(this));
        yield return new PanelTool("weather", "Weather Map", "cloud", EditorLayout.RightDock, () => new WeatherMapView(this));
        yield return new PanelTool("console", "Console", "console", EditorLayout.BottomDock, () => new ConsoleView(Console));
        yield return new PanelTool("contentBrowser", "Content Browser", "assets", EditorLayout.BottomDock, () => new ContentBrowserView(this));
        yield return new PanelTool("resourceMonitor", "Resource Monitor", "monitor", EditorLayout.BottomDock, () => new ResourceMonitorView(Stats, CaptureFrame));
        yield return new PanelTool("profiler", "Profiler", "stats", EditorLayout.BottomDock, () => new ProfilerView(this));
    }

    void OnHostStateChanged(HostState previous)
    {
        // A new link is a host that has its own world, from a start, a restart, a crash or a lost link.
        if (Host.Linked && previous is not HostState.Linked)
        {
            OnNewGameState();
        }
        if (!Host.Linked)
        {
            CloseViewportsInGame();
            _previewSlots.DisconnectAll();
            // The game ends the overrides of an editor that goes, so a token that wrote nothing would only seem live.
            Overrides.EndAll(OverrideEnd.LinkClosed);
            if (Stats.Host != null || Stats.Game != null)
            {
                Stats.Clear();
            }
            if (Profiler.Summary != null || Profiler.Status != CaptureStatus.None)
            {
                Profiler.Clear();
            }
            if (World.HasWorld)
            {
                World.Clear();
            }
        }
        Context.Set("host.running", Host.State is HostState.Running);
        Commands.InvalidateAll();
    }

    /// <summary>
    /// The game has a new state, from a new link or a soft restart, which knows nothing that the editor sent: it is in
    /// Edit with its own scene, has no open viewports, cameras, gizmos, selection, hidden entities, viewport settings,
    /// game size, capture source, mesh overlay, live meshes or previews, and answers no request that the old state had. Every cache of what the game was sent, and
    /// every request that waits for the game, starts over here and nowhere else (see docs/editor/link.md#a-new-game-state).
    /// </summary>
    void OnNewGameState()
    {
        // The new state has no overrides, so their owners hear that they ended, and nothing is sent again.
        Overrides.EndAll(OverrideEnd.NewGameState);
        ResetMode();
        SendScene();
        SendViewportTools();
        Mesh.SendLiveMeshes();
        Landscape.SendLiveMaps();
        ResetWorldView();
        // The old state's preview targets are gone. The new state's arrive as Preview_Targets.
        _previewSlots.DisconnectAll();
        _previewSlots.SendAll();
        Thumbnails.Restart(DateTime.UtcNow);
    }

    // The layout file has the arrangement that the editor closed with, which is the active workspace's, and the
    // workspaces' file says which workspace that is and has what the user made of the others.
    void RestoreLayout()
    {
        if (Settings.Read(EditorSettings.LayoutFileName) is not { } json)
        {
            return;
        }
        if (LayoutFile.FromJson(json) is not { } file || !Layout.Restore(file))
        {
            Console.Add(LogLevel.Warning, $"layout: {Path.Combine(Settings.Directory, EditorSettings.LayoutFileName)} is not a layout of this editor, so the default layout is used");
            return;
        }
        if (Settings.Read(Workspaces.FileName) is { } workspaces && !Workspaces.Load(workspaces))
        {
            Console.Add(LogLevel.Warning, $"layout: {Path.Combine(Settings.Directory, Workspaces.FileName)} is not the workspaces of this editor, so the layout is the {Workspaces.Active.Label} workspace's");
        }
    }

    public void SaveLayout()
    {
        WriteSetting("layout", EditorSettings.LayoutFileName, Layout.Save().ToJson());
        WriteSetting("layout", Workspaces.FileName, Workspaces.ToJson());
    }

    // Writes a settings file. A file that cannot be written is a warning with its path, not a failure of what changed.
    void WriteSetting(string area, string name, string text)
    {
        try
        {
            Settings.Write(name, text);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Console.Add(LogLevel.Warning, $"{area}: cannot write {Path.Combine(Settings.Directory, name)}: {e.Message}");
        }
    }

    public void Dispose()
    {
        StopAutomation();
        StopGame();
        Builder.Dispose();
        Host.Dispose();
        Cook.Dispose();
        foreach (var viewport in Viewports)
        {
            viewport.Session.Dispose();
        }
        foreach (var owner in PreviewOwners())
        {
            owner.Dispose();
        }
    }
}
