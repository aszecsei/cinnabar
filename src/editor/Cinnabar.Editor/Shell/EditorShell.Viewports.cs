using System.Text.Json;
using Cinnabar.Editor.Tools;
using Cinnabar.Editor.Viewport;
using CloseViewport = Cinnabar.Editor.Link.Protocol.CloseViewport;
using FrameAcknowledged = Cinnabar.Editor.Link.Protocol.FrameAcknowledged;
using LogLevel = Cinnabar.Editor.Model.LogLevel;
using OpenViewport = Cinnabar.Editor.Link.Protocol.OpenViewport;
using ViewportAcknowledged = Cinnabar.Editor.Link.Protocol.ViewportAcknowledged;
using ViewportSettings = Cinnabar.Editor.Link.Protocol.ViewportSettings;
using ViewportSize = Cinnabar.Editor.Link.Protocol.ViewportSize;
using ViewportTarget = Cinnabar.Editor.Link.Protocol.ViewportTarget;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The editor's viewports of the scene (see docs/editor/viewport.md#several-viewports): which the arrangement shows,
/// which one is active, and each one's link to the game. The tools act in the active viewport, the one that the mouse
/// last used: <see cref="Camera"/>, <see cref="FrameSize"/> and <see cref="ViewportSettings"/> are its own, so a tool
/// that reads them works in whichever viewport the user is in.
/// </summary>
public sealed partial class EditorShell
{
    /// <summary>Every viewport, by its number. The first is always open.</summary>
    public IReadOnlyList<SceneViewport> Viewports { get; private set; } = [];

    /// <summary>The first viewport, which shows the host's frame target.</summary>
    public SceneViewport MainViewport => Viewports[0];

    /// <summary>The first viewport's frames, which the captures and the host's adapter follow.</summary>
    public ViewportSession Viewport => MainViewport.Session;

    public IEnumerable<SceneViewport> OpenViewports => Viewports.Where(v => v.IsOpen);

    /// <summary>The viewport that the tools act in: the one that the mouse last used, among the open ones.</summary>
    public SceneViewport ActiveViewport { get; private set; } = null!;

    /// <summary>Another viewport is the active one.</summary>
    public event Action? ActiveViewportChanged;

    public ViewportArrangement Arrangement { get; private set; }

    /// <summary>The arrangement shows other viewports.</summary>
    public event Action? ArrangementChanged;

    /// <summary>The active viewport's camera.</summary>
    public EditorCamera Camera => ActiveViewport.Camera;

    /// <summary>The active viewport's frame size in pixels.</summary>
    public (double Width, double Height) FrameSize => ActiveViewport.FrameSize;

    // What viewport.json holds: the arrangement, and how each viewport draws.
    sealed record ViewportFile(ViewportArrangement Arrangement, List<ViewportSettings>? Viewports);

    // Makes the viewports with the user's settings, and connects each to the host.
    void CreateViewports()
    {
        var file = LoadViewportFile();
        Viewports = [.. Enumerable.Range(0, SceneViewport.Max).Select(i =>
            new SceneViewport(i, file.Viewports is { } all && i < all.Count ? all[i] : DefaultViewportSettings))];
        ActiveViewport = MainViewport;
        // The host renders on the adapter that composites the editor, which the first viewport finds.
        Viewport.AdapterFound += Host.Start;
        foreach (var viewport in Viewports)
        {
            var v = viewport;
            v.Session.Failed += message => Console.Add(LogLevel.Error, message);
            v.Camera.Changed += () => SendCamera(v);
            if (v.IsMain)
            {
                v.Session.SizeRequested += size => Host.Send(new ViewportSize(size.Width, size.Height));
                v.Session.FrameCopied += (generation, frame) => Host.Send(new FrameAcknowledged(generation, frame));
            }
            else
            {
                v.Session.SizeRequested += _ => SendOpenViewport(v);
                v.Session.FrameCopied += (generation, frame) => Host.Send(new ViewportAcknowledged((uint)v.Index, generation, frame));
            }
        }
        Open(file.Arrangement);
    }

    /// <summary>Makes a viewport the active one, unless it is closed or a gizmo drag holds the active one.</summary>
    public void ActivateViewport(SceneViewport viewport)
    {
        if (viewport == ActiveViewport || !viewport.IsOpen || _gizmo.IsDragging)
        {
            return;
        }
        ActiveViewport = viewport;
        Commands.InvalidateAll();
        ActiveViewportChanged?.Invoke();
        // The ribbon's View tab shows the active viewport's settings.
        ViewportSettingsChanged?.Invoke();
    }

    /// <summary>Shows the viewports of an arrangement, and closes the others.</summary>
    public void SetArrangement(ViewportArrangement arrangement)
    {
        if (arrangement == Arrangement)
        {
            return;
        }
        Open(arrangement);
        SaveViewportFile();
        Commands.InvalidateAll();
        ArrangementChanged?.Invoke();
    }

    void Open(ViewportArrangement arrangement)
    {
        Arrangement = arrangement;
        var count = SceneViewport.Count(arrangement);
        foreach (var viewport in Viewports.Where(v => !v.IsMain))
        {
            var open = viewport.Index < count;
            if (open == viewport.IsOpen)
            {
                continue;
            }
            // A viewport that opens for the first time starts from the first one's view. It is still closed here, so
            // SendViewport tells the game of the camera, once.
            if (open && !viewport.Placed)
            {
                viewport.Placed = true;
                viewport.Camera.Place(MainViewport.Camera.Position, MainViewport.Camera.Yaw, MainViewport.Camera.Pitch);
            }
            viewport.IsOpen = open;
            if (open)
            {
                viewport.SentGizmo = viewport.SentHandles = "";
                SendViewport(viewport);
            }
            else
            {
                if (Host.Linked)
                {
                    Host.Send(new CloseViewport((uint)viewport.Index));
                }
                viewport.Session.Disconnect();
            }
        }
        if (!ActiveViewport.IsOpen)
        {
            ActiveViewport = MainViewport;
            ActiveViewportChanged?.Invoke();
            ViewportSettingsChanged?.Invoke();
        }
        SendGizmo();
    }

    // Tells the game of an open viewport: its camera, how it draws, and for one other than the first, that it is open.
    // The game keeps none of them for a viewport that is closed, or after a new game state.
    void SendViewport(SceneViewport viewport)
    {
        if (!Host.Linked)
        {
            return;
        }
        Host.Send(viewport.Camera.ToMessage((uint)viewport.Index));
        SendViewportSettings(viewport);
        SendOpenViewport(viewport);
    }

    // Tells the game that an extra viewport is open, at the size that its control asked for. Before the control has a
    // size, its first one sends this.
    void SendOpenViewport(SceneViewport viewport)
    {
        if (Host.Linked && viewport is { IsOpen: true, IsMain: false, Session.RequestedSize: { Width: > 0, Height: > 0 } size })
        {
            Host.Send(new OpenViewport((uint)viewport.Index, size.Width, size.Height));
            // The gizmo keeps its size on screen, so a new frame size changes it.
            SendGizmo();
        }
    }

    // The game made a target for an extra viewport, or a new generation of it.
    void OnViewportTarget(ViewportTarget target)
    {
        if (target.Viewport > 0 && target.Viewport < Viewports.Count && Viewports[(int)target.Viewport] is { IsOpen: true } viewport)
        {
            viewport.Session.Connect(target.Prefix, target.Generation);
            SendGizmo();
        }
    }

    void DisconnectViewports()
    {
        foreach (var viewport in Viewports)
        {
            viewport.Session.Disconnect();
        }
    }

    ViewportFile LoadViewportFile()
    {
        var none = new ViewportFile(ViewportArrangement.Single, null);
        if (Settings.Read(EditorSettings.ViewportFileName) is not { } json)
        {
            return none;
        }
        try
        {
            using var document = JsonDocument.Parse(json);
            if (document.RootElement.ValueKind == JsonValueKind.Object && document.RootElement.TryGetProperty(nameof(ViewportFile.Viewports), out _))
            {
                return JsonSerializer.Deserialize<ViewportFile>(json) is { } file && Enum.IsDefined(file.Arrangement) ? file : none;
            }
            // An editor with one viewport wrote that viewport's settings alone, which every viewport now starts from.
            var settings = JsonSerializer.Deserialize<ViewportSettings>(json) ?? DefaultViewportSettings;
            return new ViewportFile(ViewportArrangement.Single, [.. Enumerable.Repeat(settings, SceneViewport.Max)]);
        }
        catch (JsonException)
        {
            Console.Add(LogLevel.Warning, $"viewport: {Path.Combine(Settings.Directory, EditorSettings.ViewportFileName)} is not the viewports' settings, so the defaults are used");
            return none;
        }
    }

    void SaveViewportFile() =>
        WriteSetting("viewport", EditorSettings.ViewportFileName, JsonSerializer.Serialize(new ViewportFile(Arrangement, [.. Viewports.Select(v => v.Settings)])));
}
