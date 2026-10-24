using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Commands.Ribbon;
using Cinnabar.Editor.Docking;
using Cinnabar.Editor.Host;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Viewport;
using FrameAcknowledged = Cinnabar.Editor.Link.Protocol.FrameAcknowledged;
using ViewportSize = Cinnabar.Editor.Link.Protocol.ViewportSize;

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
    public EditorLayout Layout { get; }
    public RibbonLayout Ribbon { get; }
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
        Host.StateChanged += OnHostStateChanged;
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
    }

    public void RequestPalette() => PaletteRequested?.Invoke();

    IEnumerable<PanelTool> CreatePanels()
    {
        PanelTool Empty(string id, string title, string icon, string dock, string message) =>
            new(id, title, icon, dock, () => new EmptyPanelView(message));

        yield return Empty("outliner", "Outliner", "outliner", EditorLayout.LeftDock,
            "The world's entities appear here when the editor link connects to the host.");
        yield return Empty("properties", "Properties", "properties", EditorLayout.RightDock,
            "The selected entity's components and behaviours appear here.");
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
        if (!Host.Linked)
        {
            Viewport.Disconnect();
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
