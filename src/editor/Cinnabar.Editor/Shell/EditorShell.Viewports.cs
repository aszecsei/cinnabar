using System.Text.Json;
using System.Text.Json.Serialization;
using Avalonia;
using Cinnabar.Editor.Tools;
using Cinnabar.Editor.Viewport;
using CaptureSource = Cinnabar.Editor.Link.Protocol.CaptureSource;
using CloseViewport = Cinnabar.Editor.Link.Protocol.CloseViewport;
using GameSize = Cinnabar.Editor.Link.Protocol.GameSize;
using HelperMode = Cinnabar.Editor.Link.Protocol.HelperMode;
using LogLevel = Cinnabar.Editor.Model.LogLevel;
using OpenViewport = Cinnabar.Editor.Link.Protocol.OpenViewport;
using SetViewportSettings = Cinnabar.Editor.Link.Protocol.SetViewportSettings;
using ViewportAcknowledged = Cinnabar.Editor.Link.Protocol.ViewportAcknowledged;
using ViewportSettings = Cinnabar.Editor.Link.Protocol.ViewportSettings;
using ViewportTarget = Cinnabar.Editor.Link.Protocol.ViewportTarget;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The editor's views of the game (see docs/editor/viewport.md#views): four scene views, in the Scene document by the
/// toggles of <see cref="SceneViews"/>, and the Game view in the Game document, each open in the game exactly while its control is on screen
/// with a size. The tools
/// act in the active scene view, the one that the mouse last used: <see cref="Camera"/>, <see cref="FrameSize"/> and
/// <see cref="ViewportSettings"/> are its own, so a tool that reads them works in whichever scene view the user is in.
/// </summary>
public sealed partial class EditorShell
{
    /// <summary>Every viewport, by its number: the four scene views, then the Game view.</summary>
    public IReadOnlyList<EditorViewport> Viewports { get; private set; } = [];

    public EditorViewport GameViewport => Viewports[EditorViewport.GameIndex];

    /// <summary>The viewports whose controls are on screen with a size, which the game draws.</summary>
    public IEnumerable<EditorViewport> ShownViewports => Viewports.Where(v => v.IsShown);

    public IEnumerable<EditorViewport> ShownSceneViews => ShownViewports.Where(v => !v.IsGame);

    /// <summary>The scene view that the tools act in: the one that the mouse last used. The Game view is never it.</summary>
    public EditorViewport ActiveViewport { get; private set; } = null!;

    /// <summary>
    /// The viewport that the View tab shows and changes: the one that the mouse or the keyboard last used, the Game view
    /// included. It is <see cref="ActiveViewport"/> until the Game view is used.
    /// </summary>
    public EditorViewport SettingsViewport { get; private set; } = null!;

    /// <summary><see cref="ActiveViewport"/> or <see cref="SettingsViewport"/> changed.</summary>
    public event Action? ActiveViewportChanged;

    /// <summary>A viewport was shown or hidden, or has a new size.</summary>
    public event Action? ViewportsChanged;

    /// <summary>The active scene view's camera.</summary>
    public EditorCamera Camera => ActiveViewport.Camera;

    /// <summary>The active scene view's frame size in pixels.</summary>
    public (double Width, double Height) FrameSize => ActiveViewport.FrameSize;

    /// <summary>
    /// The viewport that captures read: the scene view with the lowest number that is shown, or else the Game view if it
    /// is shown, or null when none is.
    /// </summary>
    public EditorViewport? CaptureViewport => ShownSceneViews.FirstOrDefault() ?? (GameViewport.IsShown ? GameViewport : null);

    /// <summary>
    /// Which scene views are in the Scene document: the one state of its layout, the user's choice, kept in <c>viewport.json</c>.
    /// At least one is always in. <see cref="SetSceneViews"/> changes it.
    /// </summary>
    public SceneViewSet SceneViews { get; private set; }

    /// <summary>The scene views that are in the Scene document, by their numbers.</summary>
    public IReadOnlyList<EditorViewport> SceneDocumentViews => [.. Viewports.Take(EditorViewport.SceneViews).Where(v => SceneViews.HasFlag(ViewBit(v.Index)))];

    /// <summary>The name of the preset that <see cref="SceneViews"/> is, or Custom. It is derived, not kept.</summary>
    public string ScenePresetName => ScenePreset.NameOf(SceneViews);

    /// <summary><see cref="SceneViews"/> changed.</summary>
    public event Action? SceneViewsChanged;

    static SceneViewSet ViewBit(int index) => (SceneViewSet)(1 << index);

    // What viewport.json holds: how each viewport draws, and the scene views in the Scene document. Layout is what an
    // earlier editor wrote in place of the views, Single or Quad.
    sealed record ViewportFile(
        List<ViewportSettings>? Viewports,
        SceneViewSet? Views = null,
        [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Layout = null);

    // The Game view's size when it last had one, which is the game's window size; it stays when the Game view hides.
    PixelSize? _gameSize;

    // The viewport that the host was last told to capture, or null before it was told.
    int? _sentCaptureSource;

    // Makes the viewports with the user's settings, and connects each to the host.
    void CreateViewports()
    {
        var (settings, views) = LoadViewportFile();
        SceneViews = views;
        Viewports = [.. Enumerable.Range(0, EditorViewport.Max).Select(i => new EditorViewport(i, settings[i]))];
        ActiveViewport = SettingsViewport = Viewports[0];
        foreach (var viewport in Viewports)
        {
            var v = viewport;
            v.Session.Failed += message => Console.Add(LogLevel.Error, message);
            // The host renders on the adapter that composites the editor, which the first control to attach finds.
            v.Session.AdapterFound += adapter => OnAdapterFound(v, adapter);
            v.Session.PresenceChanged += () => SyncViewport(v);
            v.Session.FrameCopied += (generation, frame) => Host.Send(new ViewportAcknowledged((uint)v.Index, generation, frame));
            if (v.HasCamera)
            {
                v.Camera.Changed += () => SendCamera(v);
            }
        }
    }

    void OnAdapterFound(EditorViewport viewport, ulong adapter)
    {
        if (!Host.CanStart)
        {
            Host.Start(adapter);
        }
        else if (adapter != Host.Adapter)
        {
            Console.Add(LogLevel.Error, $"viewport: {viewport.Title} is on the adapter {adapter:x16}, but the host renders on {Host.Adapter:x16}");
        }
    }

    /// <summary>
    /// Makes a viewport the one that the mouse or the keyboard last used. A scene view becomes the active one, unless a
    /// gizmo drag holds the active one, and the one that the View tab acts on. The Game view becomes only the second.
    /// </summary>
    public void ActivateViewport(EditorViewport viewport)
    {
        if (!viewport.IsShown || _gizmo.IsDragging || (viewport == SettingsViewport && (viewport.IsGame || viewport == ActiveViewport)))
        {
            return;
        }
        if (!viewport.IsGame)
        {
            ActiveViewport = viewport;
        }
        SettingsViewport = viewport;
        Commands.InvalidateAll();
        ActiveViewportChanged?.Invoke();
        // The ribbon's View tab shows the settings of the viewport it acts on.
        ViewportSettingsChanged?.Invoke();
    }

    // The one place that a viewport's open state in the game changes: the game is told what its control's presence is.
    // Shown opens it, a new size opens it again with the size, hidden closes it. A game that is not linked hears of it
    // when it links (see SendViewportTools).
    void SyncViewport(EditorViewport viewport)
    {
        switch (viewport.Session.Presence)
        {
            case ViewportPresence.Shown shown:
                PlaceCamera(viewport);
                if (Host.Linked && viewport.Opened is null)
                {
                    OpenInGame(viewport, shown.Size);
                }
                else if (viewport.Opened is { } opened && opened.Size != shown.Size)
                {
                    viewport.Opened = opened with { Size = shown.Size };
                    Host.Send(new OpenViewport((uint)viewport.Index, viewport.Kind, shown.Size.Width, shown.Size.Height));
                }
                break;
            default:
                if (viewport.Opened != null)
                {
                    viewport.Opened = null;
                    Host.Send(new CloseViewport((uint)viewport.Index));
                }
                viewport.Session.Disconnect();
                break;
        }
        if (viewport.IsGame)
        {
            SendGameSize(resend: false);
        }
        KeepActiveShown();
        // The gizmo keeps its size on screen, so a new frame size changes it.
        SendGizmo();
        SendCaptureSource(resend: false);
        Commands.InvalidateAll();
        ViewportsChanged?.Invoke();
    }

    // A scene view that is shown for the first time starts from the first one's pivot, looking along its own axis.
    void PlaceCamera(EditorViewport viewport)
    {
        if (viewport.Placed)
        {
            return;
        }
        viewport.Placed = true;
        viewport.StartCamera(Viewports[0].Camera);
    }

    /// <summary>
    /// Sets which scene views are in the Scene document, the one place that changes them. The views that leave hide, and
    /// the game closes them; the ones that enter are shown once the document lays them out. Refuses none at all, and says
    /// whether it set them.
    /// </summary>
    public bool SetSceneViews(SceneViewSet views)
    {
        views &= SceneViewSet.All;
        if (views == SceneViewSet.None)
        {
            return false;
        }
        if (views != SceneViews)
        {
            SceneViews = views;
            SaveViewportFile();
            Commands.InvalidateAll();
            SceneViewsChanged?.Invoke();
        }
        return true;
    }

    /// <summary>Puts a scene view in the Scene document or takes it out. The last one cannot be taken out.</summary>
    public bool ToggleSceneView(int index) =>
        SetSceneViews(SceneViews ^ ViewBit(index));

    /// <summary>Whether a scene view may be toggled: not when it is the only one in.</summary>
    public bool CanToggleSceneView(int index) => SceneViews != ViewBit(index);

    // Tells the game that a viewport is open, with what it draws it from: the camera and how it draws.
    void OpenInGame(EditorViewport viewport, PixelSize size)
    {
        var index = (uint)viewport.Index;
        viewport.Opened = new OpenedViewport(size);
        Host.Send(new OpenViewport(index, viewport.Kind, size.Width, size.Height));
        if (viewport.HasCamera)
        {
            Host.Send(viewport.Camera.ToMessage(index));
        }
        Host.Send(new SetViewportSettings(index, viewport.Settings));
    }

    // A viewport that hides cannot stay the one the tools or the View tab act in, while another one is shown.
    void KeepActiveShown()
    {
        var active = ActiveViewport.IsShown ? ActiveViewport : ShownSceneViews.FirstOrDefault() ?? ActiveViewport;
        var settings = SettingsViewport.IsShown ? SettingsViewport : active;
        if (active != ActiveViewport || settings != SettingsViewport)
        {
            ActiveViewport = active;
            SettingsViewport = settings;
            ActiveViewportChanged?.Invoke();
            ViewportSettingsChanged?.Invoke();
        }
    }

    // The Game view's size is the game's window, so it follows the Game view while that is shown, and stays when it hides.
    // A new game state sends the size again.
    void SendGameSize(bool resend)
    {
        if (GameViewport.Session.Presence is ViewportPresence.Shown { Size: var size } && size != _gameSize)
        {
            _gameSize = size;
            resend = true;
        }
        if (resend && _gameSize is { } known)
        {
            Host.Send(new GameSize(known.Width, known.Height));
        }
    }

    // Tells the host which viewport its screenshots and history ring read, when the choice changes or the host is new.
    void SendCaptureSource(bool resend, EditorViewport? use = null)
    {
        var source = (use ?? CaptureViewport)?.Index ?? -1;
        if (Host.Linked && (resend || source != _sentCaptureSource))
        {
            _sentCaptureSource = source;
            Host.Send(new CaptureSource(source));
        }
    }

    // The game made a target for a viewport, or a new generation of it.
    void OnViewportTarget(ViewportTarget target)
    {
        if (target.Viewport < Viewports.Count && Viewports[(int)target.Viewport] is { Opened: not null } viewport)
        {
            viewport.Session.Connect(target.Prefix, target.Generation);
            SendGizmo();
        }
    }

    // The link is gone, and the game that comes back has none of the viewports open.
    void CloseViewportsInGame()
    {
        foreach (var viewport in Viewports)
        {
            viewport.Opened = null;
            viewport.Session.Disconnect();
        }
    }

    /// <summary>The settings for the viewports and the scene views in the Scene document, from <c>viewport.json</c>.</summary>
    (List<ViewportSettings> Settings, SceneViewSet Views) LoadViewportFile()
    {
        var defaults = Enumerable.Range(0, EditorViewport.Max).Select(i => DefaultSettingsOf(i, DefaultViewportSettings)).ToList();
        if (Settings.Read(EditorSettings.ViewportFileName) is not { } json)
        {
            return (defaults, SceneViewSet.Perspective);
        }
        try
        {
            using var document = JsonDocument.Parse(json);
            if (document.RootElement.ValueKind == JsonValueKind.Object && document.RootElement.TryGetProperty(nameof(ViewportFile.Viewports), out _))
            {
                var file = JsonSerializer.Deserialize<ViewportFile>(json);
                var all = file?.Viewports ?? [];
                // A file without the views has the earlier editor's layout: Quad is all four, anything else the first.
                var views = file?.Views is { } kept && (kept & SceneViewSet.All) != SceneViewSet.None ? kept & SceneViewSet.All
                    : string.Equals(file?.Layout, "Quad", StringComparison.OrdinalIgnoreCase) ? SceneViewSet.All : SceneViewSet.Perspective;
                return ([.. defaults.Select((d, i) => i < all.Count ? all[i] : d)], views);
            }
            // An editor with one viewport wrote that viewport's settings alone, which every viewport then starts from.
            var shared = JsonSerializer.Deserialize<ViewportSettings>(json) ?? DefaultViewportSettings;
            return ([.. defaults.Select((_, i) => DefaultSettingsOf(i, shared))], SceneViewSet.Perspective);
        }
        catch (JsonException)
        {
            Console.Add(LogLevel.Warning, $"viewport: {Path.Combine(Settings.Directory, EditorSettings.ViewportFileName)} is not the viewports' settings, so the defaults are used");
            return (defaults, SceneViewSet.Perspective);
        }
    }

    // The Game view draws as a player sees it, so it starts without the editor's icons and shapes.
    static ViewportSettings DefaultSettingsOf(int index, ViewportSettings settings) =>
        index == EditorViewport.GameIndex ? settings with { ShowIcons = false, Helpers = HelperMode.None } : settings;

    void SaveViewportFile() =>
        WriteSetting("viewport", EditorSettings.ViewportFileName, JsonSerializer.Serialize(new ViewportFile([.. Viewports.Select(v => v.Settings)], SceneViews)));
}
