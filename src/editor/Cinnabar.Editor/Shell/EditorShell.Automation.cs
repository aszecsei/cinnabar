using Avalonia.Threading;
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

    public int AutomationPort => _automation?.Port ?? 0;

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

    /// <summary>Runs a request on the UI thread: the captures and the status are the shell's.</summary>
    public async Task<AutomationResponse> HandleAutomation(AutomationRequest request, CancellationToken cancel)
    {
        switch (request.Command)
        {
            case "status":
                return new AutomationResponse(request.Id, true,
                    Status: new AutomationStatus(Host.Linked, Host.State.ToString(), Mode.ToString(), Scene?.Path, Host.Game, Host.ProcessId));
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
                return Response(request.Id, await Screenshot(views, request.Path));
            case "gif":
                return Response(request.Id, await Gif(request.Path));
            default:
                return new AutomationResponse(request.Id, false, Error: $"unknown command {request.Command}; the commands are status, screenshot and gif");
        }
    }

    static AutomationResponse Response(long id, CaptureOutcome outcome) => new(id, outcome.Ok, [.. outcome.Files], outcome.Error);
}
