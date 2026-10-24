using System.Net;
using System.Net.Sockets;
using System.Threading.Channels;

namespace Cinnabar.Editor.Link;

/// <summary>
/// The editor's end of a link (see docs/editor.md#editor-link): a TCP connection to the host or the cook daemon, with a
/// task that reads and a task that writes. Events are raised on the reading task's thread.
/// </summary>
public sealed class LinkClient : IAsyncDisposable
{
    readonly TcpClient _tcp;
    readonly NetworkStream _stream;
    readonly MessageReader _read;
    readonly Channel<byte[]> _outgoing = Channel.CreateUnbounded<byte[]>(new UnboundedChannelOptions { SingleReader = true });
    readonly CancellationTokenSource _stop = new();
    Task _reading = Task.CompletedTask;
    Task _writing = Task.CompletedTask;
    int _closed;

    /// <summary>A message and its request ID.</summary>
    public event Action<ILinkMessage, uint>? Received;

    /// <summary>The link closed: with null when the host closed it or <see cref="DisposeAsync"/> did, and with the error otherwise.</summary>
    public event Action<Exception?>? Closed;

    LinkClient(TcpClient tcp, MessageReader read)
    {
        _tcp = tcp;
        _read = read;
        _tcp.NoDelay = true;
        _stream = tcp.GetStream();
    }

    /// <summary>
    /// Connects to a port on this machine, for the link whose messages <paramref name="read"/> reads. Subscribe to
    /// the events, then call <see cref="Start"/>.
    /// </summary>
    public static async Task<LinkClient> ConnectAsync(int port, MessageReader read, CancellationToken cancel)
    {
        var tcp = new TcpClient();
        try
        {
            await tcp.ConnectAsync(IPAddress.Loopback, port, cancel);
            return new LinkClient(tcp, read);
        }
        catch
        {
            tcp.Dispose();
            throw;
        }
    }

    /// <summary>
    /// A port on this machine that was free a moment ago, for a child process to listen on. Another program could take
    /// it before the child listens, and then the editor reports that the link did not open.
    /// </summary>
    public static int FreePort()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }

    public void Start()
    {
        _reading = Task.Run(ReadLoop);
        _writing = Task.Run(WriteLoop);
    }

    /// <summary>Queues a message. It never blocks. After the link closes, messages are dropped.</summary>
    public void Send(ILinkMessage message, uint request = 0) => _outgoing.Writer.TryWrite(LinkFrame.Encode(message, request));

    async Task ReadLoop()
    {
        var header = new byte[LinkFrame.HeaderSize];
        try
        {
            while (true)
            {
                await _stream.ReadExactlyAsync(header, _stop.Token);
                var h = LinkFrame.ReadHeader(header);
                var payload = new byte[h.Length];
                await _stream.ReadExactlyAsync(payload, _stop.Token);
                Received?.Invoke(LinkFrame.Decode(h.Kind, payload, _read), h.Request);
            }
        }
        catch (Exception e) when (e is EndOfStreamException or OperationCanceledException or ObjectDisposedException)
        {
            Close(null);
        }
        catch (Exception e)
        {
            Close(e);
        }
    }

    async Task WriteLoop()
    {
        try
        {
            await foreach (var frame in _outgoing.Reader.ReadAllAsync(_stop.Token))
            {
                await _stream.WriteAsync(frame, _stop.Token);
            }
        }
        catch (Exception e) when (e is OperationCanceledException or ObjectDisposedException)
        {
            Close(null);
        }
        catch (Exception e)
        {
            Close(e);
        }
    }

    void Close(Exception? error)
    {
        if (Interlocked.Exchange(ref _closed, 1) == 1)
        {
            return;
        }
        _stop.Cancel();
        _outgoing.Writer.TryComplete();
        _tcp.Dispose();
        Closed?.Invoke(error);
    }

    public async ValueTask DisposeAsync()
    {
        Close(null);
        await Task.WhenAll(_reading, _writing);
        _stop.Dispose();
    }
}
