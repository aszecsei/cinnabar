using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Cinnabar.Editor.Model;

/// <summary>A request from a tool: its id, which the response repeats, the command, and the command's arguments.</summary>
public sealed record AutomationRequest(long Id, string? Command, string[]? Views = null, string? Path = null);

/// <summary>What <c>status</c> answers: the host and the scene.</summary>
public sealed record AutomationStatus(bool Linked, string HostState, string Mode, string? Scene, string? Game, int? HostPid);

/// <summary>The answer to a request. Files are the ones a capture wrote, the sidecar last.</summary>
public sealed record AutomationResponse(long Id, bool Ok, string[]? Files = null, string? Error = null, AutomationStatus? Status = null);

/// <summary>What the editor writes beside its build for tools to find it: the port, and the editor's process, so a stale file is known.</summary>
public sealed record AutomationInfo(int Port, int Pid, DateTime Started);

/// <summary>
/// The automation server (see docs/editor/capture.md#automation): a loopback socket on which a tool such as editorctl
/// sends one JSON request per line and reads one JSON response per line. Requests run one at a time, through the
/// handler, which the shell gives; the server knows nothing of the editor itself.
/// </summary>
public sealed class AutomationServer : IAsyncDisposable
{
    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    readonly Func<AutomationRequest, CancellationToken, Task<AutomationResponse>> _handle;
    readonly SemaphoreSlim _gate = new(1, 1);
    readonly CancellationTokenSource _closing = new();
    TcpListener? _listener;
    Task? _accepting;

    public AutomationServer(Func<AutomationRequest, CancellationToken, Task<AutomationResponse>> handle) => _handle = handle;

    /// <summary>The port, once started. The OS picks it.</summary>
    public int Port { get; private set; }

    public void Start()
    {
        _listener = new TcpListener(IPAddress.Loopback, 0);
        _listener.Start();
        Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
        _accepting = AcceptAsync(_listener, _closing.Token);
    }

    async Task AcceptAsync(TcpListener listener, CancellationToken cancel)
    {
        while (!cancel.IsCancellationRequested)
        {
            TcpClient client;
            try
            {
                client = await listener.AcceptTcpClientAsync(cancel);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (SocketException)
            {
                return;
            }
            _ = ServeAsync(client, cancel);
        }
    }

    async Task ServeAsync(TcpClient client, CancellationToken cancel)
    {
        using (client)
        {
            try
            {
                var stream = client.GetStream();
                using var reader = new StreamReader(stream, new UTF8Encoding(false));
                await using var writer = new StreamWriter(stream, new UTF8Encoding(false)) { AutoFlush = true, NewLine = "\n" };
                while (await reader.ReadLineAsync(cancel) is { } line)
                {
                    if (line.Trim().Length == 0)
                    {
                        continue;
                    }
                    var response = await AnswerAsync(line, cancel);
                    await writer.WriteLineAsync(JsonSerializer.Serialize(response, Json).AsMemory(), cancel);
                }
            }
            catch (Exception e) when (e is IOException or SocketException or OperationCanceledException or ObjectDisposedException)
            {
                // The tool went away, or the editor is closing.
            }
        }
    }

    async Task<AutomationResponse> AnswerAsync(string line, CancellationToken cancel)
    {
        AutomationRequest? request;
        try
        {
            request = JsonSerializer.Deserialize<AutomationRequest>(line, Json);
        }
        catch (JsonException e)
        {
            return new AutomationResponse(0, false, Error: $"the request is not JSON: {e.Message}");
        }
        if (request == null || string.IsNullOrEmpty(request.Command))
        {
            return new AutomationResponse(request?.Id ?? 0, false, Error: "the request names no command");
        }
        await _gate.WaitAsync(cancel);
        try
        {
            return await _handle(request, cancel);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            return new AutomationResponse(request.Id, false, Error: e.Message);
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>Writes the info file, with its directory, in one move, so a reader never sees half of it.</summary>
    public static void WriteInfo(string path, AutomationInfo info)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path + ".tmp", JsonSerializer.Serialize(info, Json));
        File.Move(path + ".tmp", path, overwrite: true);
    }

    /// <summary>Reads the info file, or null when it is missing or not an info file.</summary>
    public static AutomationInfo? ReadInfo(string path)
    {
        try
        {
            return File.Exists(path) ? JsonSerializer.Deserialize<AutomationInfo>(File.ReadAllText(path), Json) : null;
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    public static void DeleteInfo(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // A file that cannot go is stale, and its pid tells readers so.
        }
    }

    public async ValueTask DisposeAsync()
    {
        await _closing.CancelAsync();
        _listener?.Stop();
        if (_accepting != null)
        {
            try
            {
                await _accepting;
            }
            catch (OperationCanceledException)
            {
            }
        }
        _closing.Dispose();
        _gate.Dispose();
    }
}
