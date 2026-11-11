using Avalonia;
using Avalonia.Threading;
using Cinnabar.Editor.Content;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Model;
using LogLevel = Cinnabar.Editor.Model.LogLevel;
using ViewAxis = Cinnabar.Editor.Tools.ViewAxis;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The automation server (see docs/editor/capture.md#automation): tools reach the shell's captures and its status over a
/// loopback socket, whose port the editor writes to the automation file for them to find. The window starts it, so
/// a shell in a test opens no port.
/// </summary>
public sealed partial class EditorShell
{
    AutomationServer? _automation;
    int _uiCaptures;

    public int AutomationPort => _automation?.Port ?? 0;

    /// <summary>
    /// Draws a window's controls into a PNG: the window of a panel, or the main window for null, and the file's path. It
    /// returns the reason when it cannot. The main window sets it, so a shell in a test has none.
    /// </summary>
    public Func<string?, string, string?>? UiCapture { get; set; }

    public void StartAutomation()
    {
        if (_automation != null)
        {
            return;
        }
        var server = new AutomationServer((request, cancel) => Dispatcher.UIThread.InvokeAsync(() => HandleAutomation(request, cancel)));
        try
        {
            server.Start();
        }
        catch (Exception e)
        {
            Console.Add(LogLevel.Warning, $"automation: cannot listen: {e.Message}");
            return;
        }
        _automation = server;
        try
        {
            AutomationServer.WriteInfo(_options.AutomationFile, new AutomationInfo(server.Port, Environment.ProcessId, DateTime.UtcNow));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Console.Add(LogLevel.Warning, $"automation: cannot write {_options.AutomationFile}: {e.Message}");
        }
        Console.Add(LogLevel.Info, $"automation: listening on 127.0.0.1:{server.Port}, in {_options.AutomationFile}");
    }

    public void StopAutomation()
    {
        if (_automation == null)
        {
            return;
        }
        AutomationServer.DeleteInfo(_options.AutomationFile);
        _ = _automation.DisposeAsync();
        _automation = null;
    }

    /// <summary>Runs a request on the UI thread: the captures, the status, the viewport's settings and the camera are the shell's.</summary>
    public async Task<AutomationResponse> HandleAutomation(AutomationRequest request, CancellationToken cancel)
    {
        switch (request.Command)
        {
            case "status":
                return new AutomationResponse(request.Id, true,
                    Status: new AutomationStatus(Host.Linked, Host.State.Name, Mode.ToString(), Scene?.Path, Host.Game, Host.ProcessId, [.. ShownViewports.Select(v => v.Index)], DrawSizes()));
            case "screenshot":
                List<DebugView> views = [];
                foreach (var name in request.Views ?? [])
                {
                    if (!CaptureModel.TryParseView(name, out var view))
                    {
                        return new AutomationResponse(request.Id, false, Error: $"unknown view {name}; the views are {string.Join(", ", CaptureModel.ViewNames)}");
                    }
                    views.Add(view);
                }
                return Response(request.Id, await Screenshot(views, request.Path, request.Viewport));
            case "gif":
                return Response(request.Id, await Gif(request.Path, request.Viewport));
            case "viewport":
                if (request.Settings is not { Count: > 0 } all)
                {
                    return new AutomationResponse(request.Id, false, Error: "viewport takes settings to change");
                }
                // Shown and layout are the shell's, not a viewport's, so they are not settings to patch. Layout is a preset of the Scene's views.
                var changes = new Dictionary<string, System.Text.Json.JsonElement>(all, StringComparer.OrdinalIgnoreCase);
                if (changes.Remove("layout", out var layout))
                {
                    if (ScenePreset.Find(layout.ToString()) is not { } chosen)
                    {
                        return new AutomationResponse(request.Id, false, Error: $"unknown layout {layout}; the layouts are {string.Join(", ", ScenePreset.All.Select(p => p.Name))}");
                    }
                    SetSceneViews(chosen.Views);
                }
                if (changes.Remove("shown", out var shown) && ShowViewportDocument(request, shown) is { } refusal)
                {
                    return new AutomationResponse(request.Id, false, Error: refusal);
                }
                // The 2D view is a place and a projection of the view's camera.
                if (changes.Remove("view2d", out var view2d) && view2d.ValueKind == System.Text.Json.JsonValueKind.True)
                {
                    if (AutomationViewport(request, scene: true) is not { } flat || !Show2D(flat))
                    {
                        return new AutomationResponse(request.Id, false, Error: $"viewport {request.Viewport} has no editor camera to make the 2D view");
                    }
                }
                // The projection is the view's camera's, not one of its settings.
                if (changes.Remove("projection", out var projection))
                {
                    if (!Enum.TryParse<CameraProjection>(projection.ToString(), ignoreCase: true, out var chosenProjection) || !Enum.IsDefined(chosenProjection))
                    {
                        return new AutomationResponse(request.Id, false, Error: $"unknown projection {projection}; the projections are {string.Join(", ", Enum.GetNames<CameraProjection>())}");
                    }
                    if (AutomationViewport(request, scene: true) is not { } view || !SetProjection(view, chosenProjection))
                    {
                        return new AutomationResponse(request.Id, false, Error: $"viewport {request.Viewport} has no editor camera to set the projection of");
                    }
                }
                // A view along an axis, at once, with the view's projection, which a projection above has just chosen.
                if (changes.Remove("look", out var look))
                {
                    if (!Enum.TryParse<ViewAxis>(look.ToString(), ignoreCase: true, out var axis) || !Enum.IsDefined(axis))
                    {
                        return new AutomationResponse(request.Id, false, Error: $"unknown view {look}; the views are {string.Join(", ", Enum.GetNames<ViewAxis>())}");
                    }
                    if (AutomationViewport(request, scene: true) is not { } along || !LookAlong(along, axis, animate: false))
                    {
                        return new AutomationResponse(request.Id, false, Error: $"viewport {request.Viewport} has no editor camera to turn");
                    }
                }
                if (AutomationViewport(request, scene: false) is not { } target)
                {
                    return new AutomationResponse(request.Id, false, Error: $"viewport {request.Viewport} is not one of the viewports, 0 to {Viewports.Count - 1}");
                }
                // The size is the shell's too: what it opens the viewport in the game at.
                if (changes.Remove("size", out var size))
                {
                    if (!TryParseFixedSize(size.ToString(), out var fixedSize, out var refused))
                    {
                        return new AutomationResponse(request.Id, false, Error: refused);
                    }
                    SetFixedSize(target, fixedSize);
                }
                if (changes.Count == 0)
                {
                    return new AutomationResponse(request.Id, true);
                }
                if (!ViewportSettingsPatch.TryApply(target.Settings, changes, out var settings, out var error))
                {
                    return new AutomationResponse(request.Id, false, Error: error);
                }
                ApplyViewportSettings(target, settings);
                return new AutomationResponse(request.Id, true);
            case "camera":
                if (request.Position is not { Length: 3 } meters)
                {
                    return new AutomationResponse(request.Id, false, Error: "camera takes a position of three numbers, in meters");
                }
                if (AutomationViewport(request, scene: true) is not { HasCamera: true } placed)
                {
                    return new AutomationResponse(request.Id, false, Error: request.Viewport is { } game && game == EditorViewport.GameIndex
                        ? $"viewport {game} is the Game view, which draws from the game's camera and has no editor camera"
                        : $"viewport {request.Viewport} is not one of the viewports, 0 to {Viewports.Count - 1}");
                }
                placed.Camera.Place([.. meters.Select(m => (long)Math.Round(m * (1 << 24)))], request.Yaw ?? placed.Camera.Yaw, request.Pitch ?? placed.Camera.Pitch);
                return new AutomationResponse(request.Id, true);
            case "timing":
                return await TimingResponse(request, cancel);
            case "ui":
                return CaptureUiResponse(request);
            case "content":
                return ContentResponse(request);
            default:
                return new AutomationResponse(request.Id, false, Error: $"unknown command {request.Command}; the commands are status, screenshot, gif, viewport, camera, timing, ui and content");
        }
    }

    /// <summary>The summaries that <c>timing</c> takes when a request does not say, and the most it takes or skips.</summary>
    public const int DefaultTimingSamples = 5, MaxTimingSamples = 100;

    /// <summary>How long <c>timing</c> waits for a summary: the host sends one every 250 ms.</summary>
    public static readonly TimeSpan SummaryWait = TimeSpan.FromSeconds(2);

    /// <summary>
    /// Reads a viewport's <c>size</c>: <c>&lt;width&gt;x&lt;height&gt;</c> in pixels for a size of its own, or <c>pane</c>
    /// for its control's, which is null. The reason is why it is neither.
    /// </summary>
    public static bool TryParseFixedSize(string text, out PixelSize? size, out string reason)
    {
        size = null;
        reason = "";
        if (text.Equals("pane", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }
        var parts = text.Split('x', 'X');
        if (parts.Length == 2 && int.TryParse(parts[0], out var width) && int.TryParse(parts[1], out var height)
            && width >= 1 && height >= 1 && width <= MaxViewportSize && height <= MaxViewportSize)
        {
            size = new PixelSize(width, height);
            return true;
        }
        reason = $"size takes <width>x<height>, each 1 to {MaxViewportSize} pixels, or pane, not {text}";
        return false;
    }

    // The viewports that are shown, with the sizes that the game draws them at.
    AutomationViewportSize[] DrawSizes() =>
        [.. Viewports.Where(v => v.DrawSize != null).Select(v => new AutomationViewportSize(v.Index, v.DrawSize!.Value.Width, v.DrawSize.Value.Height, v.FixedSize != null))];

    // Waits for the host's profile summaries: skips the first ones, whose interval may be from before a change that the
    // request follows, then takes the passes' times from the next ones. A summary without GPU frames has no passes and
    // does not count; a host that sends none for SummaryWait is an error.
    async Task<AutomationResponse> TimingResponse(AutomationRequest request, CancellationToken cancel)
    {
        var samples = request.Samples ?? DefaultTimingSamples;
        var skip = request.Skip ?? 1;
        if (samples < 1 || samples > MaxTimingSamples || skip < 0 || skip > MaxTimingSamples)
        {
            return new AutomationResponse(request.Id, false, Error: $"timing takes 1 to {MaxTimingSamples} samples and skips 0 to {MaxTimingSamples}");
        }
        if (!Host.Linked)
        {
            return new AutomationResponse(request.Id, false, Error: "no host is linked to time");
        }
        if (!ShownViewports.Any())
        {
            return new AutomationResponse(request.Id, false, Error: "no viewport is shown, so no pass draws");
        }
        var arrived = new List<Link.Protocol.ProfileSummary>();
        using var signal = new SemaphoreSlim(0);
        void OnArrived(Link.Protocol.ProfileSummary summary)
        {
            arrived.Add(summary);
            signal.Release();
        }
        Profiler.SummaryArrived += OnArrived;
        try
        {
            var taken = new List<Link.Protocol.ProfileSummary>(samples);
            var seen = 0;
            // A host whose frames never reach the GPU would keep this waiting, so it gives up after this many summaries.
            var most = 4 * (samples + skip) + 8;
            while (taken.Count < samples)
            {
                if (!await signal.WaitAsync(SummaryWait, cancel))
                {
                    return new AutomationResponse(request.Id, false, Error: $"the host sent no profile summary for {SummaryWait.TotalSeconds:0} s");
                }
                var summary = arrived[seen++];
                if (summary.GpuFrames > 0 && seen > skip)
                {
                    taken.Add(summary);
                }
                else if (seen >= most)
                {
                    return new AutomationResponse(request.Id, false, Error: $"the host's last {seen} profile summaries had no GPU frames");
                }
            }
            return new AutomationResponse(request.Id, true, Timing: ProfileTiming.Measure(taken, request.Passes, DrawSizes()));
        }
        finally
        {
            Profiler.SummaryArrived -= OnArrived;
        }
    }

    // Shows or hides the viewport that a request names, and gives the reason when it cannot. A scene view, 0 to 3, goes in
    // the Scene document or out of it, and showing one also brings the Scene's tab to the front; the last one in cannot go
    // out. Viewport 4 is the Game document, which shown opens and brings to the front, or closes: the Game in front is how
    // a tool leaves the Scene.
    string? ShowViewportDocument(AutomationRequest request, System.Text.Json.JsonElement shown)
    {
        if (request.Viewport is not { } number || number < 0 || number >= Viewports.Count)
        {
            return $"shown takes a viewport, 0 to {Viewports.Count - 1}";
        }
        if (shown.ValueKind is not (System.Text.Json.JsonValueKind.True or System.Text.Json.JsonValueKind.False))
        {
            return $"shown takes true or false, not {shown}";
        }
        var viewport = Viewports[number];
        var show = shown.ValueKind == System.Text.Json.JsonValueKind.True;
        if (viewport.IsGame)
        {
            if (show)
            {
                Layout.ShowViewport(viewport.DocumentId);
            }
            else
            {
                Layout.CloseViewport(viewport.DocumentId);
            }
            return null;
        }
        var views = show ? SceneViews | ViewBit(number) : SceneViews & ~ViewBit(number);
        if (!SetSceneViews(views))
        {
            return $"viewport {number} is the only view in the Scene, which keeps one; show another view first, or show viewport {EditorViewport.GameIndex} to put the Game in front";
        }
        if (show)
        {
            Layout.ShowViewport(viewport.DocumentId);
        }
        return null;
    }

    // The viewport that a request names, or null when it is not one. Without a name, the capture viewport, which is the
    // first scene view that is shown; with none shown, the first scene view, so settings and a camera can be set ahead of it.
    EditorViewport? AutomationViewport(AutomationRequest request, bool scene) =>
        request.Viewport is { } index
            ? Viewports.FirstOrDefault(v => v.Index == index)
            : (scene ? ShownSceneViews.FirstOrDefault() : CaptureViewport) ?? Viewports[0];

    // Changes what the content browser shows, each setting in turn, and answers with what it shows then.
    AutomationResponse ContentResponse(AutomationRequest request)
    {
        var model = Content.Model;
        foreach (var (name, value) in request.Settings ?? [])
        {
            var text = value.ToString();
            switch (name)
            {
                case "folder":
                    var slash = text.IndexOf('/');
                    var (root, path) = slash < 0 ? (text, "") : (text[..slash], text[(slash + 1)..]);
                    if (Assets.FindRoot(root) == null)
                    {
                        return new AutomationResponse(request.Id, false, Error: $"no content root is named {root}");
                    }
                    model.Reveal(ContentItem.Of(new ContentFolder(root, path)));
                    break;
                case "search":
                    model.Search = text;
                    break;
                case "view":
                    if (!Enum.TryParse<ContentViewMode>(text, ignoreCase: true, out var mode))
                    {
                        return new AutomationResponse(request.Id, false, Error: $"view takes grid or list, not {text}");
                    }
                    model.ViewMode = mode;
                    break;
                case "tileSize":
                    model.TileSize = value.GetDouble();
                    break;
                case "kinds":
                    foreach (var kind in model.Kinds.ToList())
                    {
                        model.ToggleKind(kind);
                    }
                    foreach (var part in text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
                    {
                        if (!Enum.TryParse<ContentKind>(part, ignoreCase: true, out var kind))
                        {
                            return new AutomationResponse(request.Id, false, Error: $"unknown kind {part}; the kinds are {string.Join(", ", Enum.GetNames<ContentKind>())}");
                        }
                        model.ToggleKind(kind);
                    }
                    break;
                case "tags":
                    foreach (var tag in model.FilterTags.ToList())
                    {
                        model.ToggleTag(tag);
                    }
                    foreach (var part in text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
                    {
                        model.ToggleTag(part);
                    }
                    break;
                case "showTags":
                    model.ShowingTags = value.ValueKind == System.Text.Json.JsonValueKind.True;
                    break;
                case "popOut":
                    if (value.ValueKind == System.Text.Json.JsonValueKind.True)
                    {
                        Layout.PopOut("contentBrowser");
                    }
                    else
                    {
                        Layout.DockBack("contentBrowser");
                    }
                    break;
                case "enter":
                    model.Enter(text);
                    break;
                case "leave":
                    model.Leave();
                    break;
                case "enterNode":
                    model.EnterNode(ulong.Parse(text, System.Globalization.NumberStyles.HexNumber));
                    break;
                case "reveal":
                    if (Assets.Find(text) == null)
                    {
                        return new AutomationResponse(request.Id, false, Error: $"no asset has the GUID {text}");
                    }
                    Content.RevealAsset(text);
                    break;
                case "shown":
                    if (value.ValueKind == System.Text.Json.JsonValueKind.True)
                    {
                        Layout.Show("contentBrowser");
                    }
                    else
                    {
                        Layout.Close("contentBrowser");
                    }
                    break;
                default:
                    return new AutomationResponse(request.Id, false, Error: $"unknown content setting {name}; the settings are folder, search, view, tileSize, kinds, tags, showTags, popOut, enter, enterNode, leave, reveal and shown");
            }
        }
        return new AutomationResponse(request.Id, true, Content: new AutomationContent(model.Folder?.Display, model.Search, [.. model.Selection],
            [.. model.Tiles.Select(t => t.Name)], Thumbnails.Waiting, [.. Thumbnails.Failures]));
    }

    AutomationResponse CaptureUiResponse(AutomationRequest request)
    {
        if (UiCapture is not { } capture)
        {
            return new AutomationResponse(request.Id, false, Error: "the editor has no window to draw");
        }
        var path = CaptureModel.ImagePath(request.Path, _options.CaptureDirectory, DateTime.UtcNow, ++_uiCaptures, "ui");
        var window = string.IsNullOrEmpty(request.Window) ? null : request.Window;
        return capture(window, path) is { } error
            ? new AutomationResponse(request.Id, false, Error: error)
            : new AutomationResponse(request.Id, true, [path]);
    }

    static AutomationResponse Response(long id, CaptureOutcome outcome) => new(id, outcome.Ok, [.. outcome.Files], outcome.Error);
}
