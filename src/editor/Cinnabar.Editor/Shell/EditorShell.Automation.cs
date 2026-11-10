using Avalonia.Threading;
using Cinnabar.Editor.Content;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Model;
using LogLevel = Cinnabar.Editor.Model.LogLevel;

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
                    Status: new AutomationStatus(Host.Linked, Host.State.Name, Mode.ToString(), Scene?.Path, Host.Game, Host.ProcessId, [.. ShownViewports.Select(v => v.Index)]));
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
                if (AutomationViewport(request, scene: false) is not { } target)
                {
                    return new AutomationResponse(request.Id, false, Error: $"viewport {request.Viewport} is not one of the viewports, 0 to {Viewports.Count - 1}");
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
            case "ui":
                return CaptureUiResponse(request);
            case "content":
                return ContentResponse(request);
            default:
                return new AutomationResponse(request.Id, false, Error: $"unknown command {request.Command}; the commands are status, screenshot, gif, viewport, camera, ui and content");
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
