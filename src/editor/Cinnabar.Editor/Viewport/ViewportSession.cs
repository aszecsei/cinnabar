using Avalonia;

namespace Cinnabar.Editor.Viewport;

public enum ViewportScale
{
    /// <summary>The frame fills the viewport, with its aspect ratio kept.</summary>
    Fit,
    /// <summary>One frame pixel per screen pixel, centered and clipped.</summary>
    Actual,
}

/// <summary>
/// What the viewport shows, apart from any one control: the editor's D3D11 device and the host's shared frames (see
/// docs/editor.md#viewport). Docking can move or rebuild the <see cref="ViewportControl"/>, and the session stays.
/// </summary>
public sealed class ViewportSession : IDisposable
{
    const long OpenRetryMilliseconds = 100;

    ViewportDevice? _device;
    SharedFrames? _frames;
    string? _sharedName;
    long _lastOpen;

    /// <summary>The LUID of the adapter that composites the editor, found by the first control. The host must render on it.</summary>
    public ulong? Adapter { get; private set; }

    public event Action<ulong>? AdapterFound;

    /// <summary>The viewport cannot show frames, and why.</summary>
    public event Action<string>? Failed;

    public string AdapterName => _device?.AdapterName ?? "";

    /// <summary>What the compositor's GPU interop supports.</summary>
    public string Interop { get; private set; } = "";

    public ViewportScale Scale
    {
        get;
        set
        {
            field = value;
            ViewChanged?.Invoke();
        }
    } = ViewportScale.Fit;

    public bool ShowStats
    {
        get;
        set
        {
            field = value;
            ViewChanged?.Invoke();
        }
    }

    /// <summary><see cref="Scale"/> or <see cref="ShowStats"/> changed.</summary>
    public event Action? ViewChanged;

    public ulong FrameShown { get; private set; }
    public ulong FramesPresented { get; private set; }
    public PixelSize FrameSize => _frames?.Size ?? default;

    internal ViewportDevice? Device => _device;

    /// <summary>Shows the frames of the host that renders into the shared target <paramref name="name"/>.</summary>
    public void Connect(string name)
    {
        Disconnect();
        _sharedName = name;
        _lastOpen = 0;
    }

    public void Disconnect()
    {
        _sharedName = null;
        _frames?.Dispose();
        _frames = null;
        FrameShown = 0;
    }

    /// <summary>A control found its compositor's adapter. The first one decides the adapter for the host.</summary>
    internal void Attach(ulong adapter, string interop)
    {
        Interop = interop;
        if (_device != null && Adapter == adapter)
        {
            return;
        }
        if (Adapter != null && Adapter != adapter)
        {
            Failed?.Invoke($"viewport: the window moved to another adapter ({adapter:x16}); the host still renders on {Adapter:x16}");
            return;
        }
        _device = new ViewportDevice(adapter);
        Adapter = adapter;
        AdapterFound?.Invoke(adapter);
    }

    internal void Fail(string message) => Failed?.Invoke(message);

    /// <summary>The host's frames, opened if the host has made them by now.</summary>
    internal SharedFrames? Poll()
    {
        if (_frames != null || _device == null || _sharedName == null || Environment.TickCount64 - _lastOpen < OpenRetryMilliseconds)
        {
            return _frames;
        }
        _lastOpen = Environment.TickCount64;
        try
        {
            _frames = SharedFrames.TryOpen(_device, _sharedName);
        }
        catch (Exception e)
        {
            Failed?.Invoke($"viewport: cannot open {_sharedName}: {e.Message}");
        }
        return _frames;
    }

    internal void Presented(ulong frame)
    {
        FrameShown = frame;
        FramesPresented++;
    }

    public void Dispose()
    {
        Disconnect();
        _device?.Dispose();
        _device = null;
    }
}
