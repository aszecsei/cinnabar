using Avalonia;
using Avalonia.Controls;
using Avalonia.Platform;
using Avalonia.Rendering.Composition;

namespace Cinnabar.Editor.Viewport;

/// <summary>
/// Shows the host's frames (see docs/editor.md#viewport). On each composition update, it copies the newest finished
/// frame into a <see cref="ViewportImage"/> and gives that to its surface, scaled to fit with its aspect ratio kept.
/// </summary>
public sealed class ViewportControl : Control
{
    // One image on screen, one queued, and one to copy into.
    const int MaxImages = 3;
    const long OpenRetryMilliseconds = 100;

    readonly Action _update;
    readonly List<ViewportImage> _images = [];
    Compositor? _compositor;
    CompositionDrawingSurface? _surface;
    CompositionSurfaceVisual? _visual;
    ICompositionGpuInterop? _interop;
    ViewportDevice? _device;
    SharedFrames? _frames;
    string? _sharedName;
    long _lastOpen;
    bool _updateQueued;

    /// <summary>The LUID of the adapter that composites the window. The host must render on it.</summary>
    public event Action<ulong>? Ready;

    /// <summary>The viewport cannot show frames, and why.</summary>
    public event Action<string>? Failed;

    public string AdapterName => _device?.AdapterName ?? "";

    /// <summary>What the compositor's GPU interop supports, for the status bar.</summary>
    public string Interop { get; private set; } = "";

    public ulong FrameShown { get; private set; }
    public ulong FramesPresented { get; private set; }
    public PixelSize FrameSize => _frames?.Size ?? default;

    public ViewportControl() => _update = Update;

    /// <summary>Shows the frames of the host that renders into the shared target <paramref name="name"/>.</summary>
    public void Connect(string name)
    {
        Disconnect();
        _sharedName = name;
        QueueUpdate();
    }

    public void Disconnect()
    {
        _sharedName = null;
        _frames?.Dispose();
        _frames = null;
        FrameShown = 0;
        ReleaseImages();
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        _ = InitializeAsync();
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        Disconnect();
        _surface?.Dispose();
        _surface = null;
        _device?.Dispose();
        _device = null;
        base.OnDetachedFromVisualTree(e);
    }

    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        if (change.Property == BoundsProperty)
        {
            LayoutVisual();
        }
    }

    async Task InitializeAsync()
    {
        try
        {
            _compositor = ElementComposition.GetElementVisual(this)!.Compositor;
            _interop = await _compositor.TryGetCompositionGpuInterop();
            if (_interop == null)
            {
                Failed?.Invoke("viewport: the compositor has no GPU interop for its rendering backend");
                return;
            }
            Interop = Describe(_interop);
            if (!_interop.SupportedImageHandleTypes.Contains(KnownPlatformGraphicsExternalImageHandleTypes.D3D11TextureGlobalSharedHandle))
            {
                Failed?.Invoke($"viewport: the compositor cannot import D3D11 textures ({Interop})");
                return;
            }
            if (_interop.DeviceLuid is not { Length: 8 } luid)
            {
                Failed?.Invoke("viewport: the compositor does not report its adapter's LUID");
                return;
            }
            var adapter = BitConverter.ToUInt64(luid);
            _device = new ViewportDevice(adapter);
            _surface = _compositor.CreateDrawingSurface();
            _visual = _compositor.CreateSurfaceVisual();
            _visual.Surface = _surface;
            ElementComposition.SetElementChildVisual(this, _visual);
            LayoutVisual();
            Ready?.Invoke(adapter);
        }
        catch (Exception e)
        {
            Failed?.Invoke($"viewport: {e.Message}");
        }
    }

    void QueueUpdate()
    {
        if (!_updateQueued && _compositor != null)
        {
            _updateQueued = true;
            _compositor.RequestCompositionUpdate(_update);
        }
    }

    void Update()
    {
        _updateQueued = false;
        if (_device == null || _sharedName == null)
        {
            return;
        }
        if (_frames == null && Environment.TickCount64 - _lastOpen >= OpenRetryMilliseconds)
        {
            _lastOpen = Environment.TickCount64;
            try
            {
                _frames = SharedFrames.TryOpen(_device, _sharedName);
            }
            catch (Exception e)
            {
                Failed?.Invoke($"viewport: cannot open {_sharedName}: {e.Message}");
            }
            LayoutVisual();
        }
        if (_frames != null)
        {
            PresentLatest(_frames, _device);
        }
        QueueUpdate();
    }

    void PresentLatest(SharedFrames frames, ViewportDevice device)
    {
        var latest = frames.Completed;
        if (latest == 0 || latest == FrameShown)
        {
            return;
        }
        var image = _images.FirstOrDefault(i => i.Ready && i.Size == frames.Size);
        if (image == null)
        {
            if (_images.Count >= MaxImages)
            {
                // The compositor holds every image. The next update shows a newer frame.
                return;
            }
            image = new ViewportImage(device.Device, _interop!, frames.Size);
            _images.Add(image);
        }
        // The fence says the frame is finished, so the copy reads a complete frame. The host draws into this
        // texture again only two frames later, and the copy is queued now. The editor link's frame acknowledgements
        // will make that a guarantee.
        image.Present(device.Context, frames.Texture(latest), _surface!);
        FrameShown = latest;
        FramesPresented++;
    }

    void LayoutVisual()
    {
        if (_visual == null)
        {
            return;
        }
        var bounds = Bounds.Size;
        var frame = FrameSize;
        if (frame.Width <= 0 || frame.Height <= 0)
        {
            _visual.Size = new Vector(bounds.Width, bounds.Height);
            _visual.Offset = default;
            return;
        }
        var scale = Math.Min(bounds.Width / frame.Width, bounds.Height / frame.Height);
        var size = new Vector(frame.Width * scale, frame.Height * scale);
        _visual.Size = size;
        _visual.Offset = new Vector3D((bounds.Width - size.X) / 2, (bounds.Height - size.Y) / 2, 0);
    }

    void ReleaseImages()
    {
        foreach (var image in _images)
        {
            _ = image.DisposeAsync();
        }
        _images.Clear();
    }

    static string Describe(ICompositionGpuInterop interop)
    {
        var images = interop.SupportedImageHandleTypes.Select(t => $"{t} ({interop.GetSynchronizationCapabilities(t)})");
        var semaphores = interop.SupportedSemaphoreTypes.Count == 0 ? "none" : string.Join(", ", interop.SupportedSemaphoreTypes);
        return $"images: {string.Join(", ", images)}; semaphores: {semaphores}";
    }
}
