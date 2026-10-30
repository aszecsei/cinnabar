using Avalonia;
using Avalonia.Controls;
using Avalonia.Platform;
using Avalonia.Rendering.Composition;
using Avalonia.Threading;

using Cinnabar.Editor.Maths;

namespace Cinnabar.Editor.Viewport;

/// <summary>
/// Shows the frames of its <see cref="Session"/> (see docs/editor/viewport.md#viewport). On each composition update, it copies
/// the newest finished frame into a <see cref="ViewportImage"/> and gives that to its surface.
/// </summary>
public sealed class ViewportControl : Control
{
    // One image on screen, one queued, and one to copy into.
    const int MaxImages = 3;

    // Each size that the host renders at is a new generation of its target, so a drag sends only the size it ends at.
    static readonly TimeSpan ResizeSettle = TimeSpan.FromMilliseconds(120);

    readonly Action _update;
    readonly List<ViewportImage> _images = [];
    readonly DispatcherTimer _resize;
    Compositor? _compositor;
    CompositionDrawingSurface? _surface;
    CompositionSurfaceVisual? _visual;
    ICompositionGpuInterop? _interop;
    bool _attached;
    bool _updateQueued;

    public ViewportSession? Session { get; init; }

    public ViewportControl()
    {
        _update = Update;
        ClipToBounds = true;
        _resize = new DispatcherTimer { Interval = ResizeSettle };
        _resize.Tick += (_, _) =>
        {
            _resize.Stop();
            RequestSize();
        };
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        _attached = true;
        _ = InitializeAsync();
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        _attached = false;
        _resize.Stop();
        ReleaseImages();
        _surface?.Dispose();
        _surface = null;
        _visual = null;
        _interop = null;
        base.OnDetachedFromVisualTree(e);
    }

    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        if (change.Property == BoundsProperty)
        {
            LayoutVisual();
            _resize.Stop();
            _resize.Start();
        }
    }

    async Task InitializeAsync()
    {
        if (Session == null)
        {
            return;
        }
        try
        {
            var compositor = ElementComposition.GetElementVisual(this)!.Compositor;
            var interop = await compositor.TryGetCompositionGpuInterop();
            if (!_attached)
            {
                return;
            }
            if (interop == null)
            {
                Session.Fail("viewport: the compositor has no GPU interop for its rendering backend");
                return;
            }
            var description = Describe(interop);
            if (!interop.SupportedImageHandleTypes.Contains(KnownPlatformGraphicsExternalImageHandleTypes.D3D11TextureGlobalSharedHandle))
            {
                Session.Fail($"viewport: the compositor cannot import D3D11 textures ({description})");
                return;
            }
            if (interop.DeviceLuid is not { Length: 8 } luid)
            {
                Session.Fail("viewport: the compositor does not report its adapter's LUID");
                return;
            }
            _compositor = compositor;
            _interop = interop;
            _surface = compositor.CreateDrawingSurface();
            _visual = compositor.CreateSurfaceVisual();
            _visual.Surface = _surface;
            ElementComposition.SetElementChildVisual(this, _visual);
            LayoutVisual();
            Session.Attach(BitConverter.ToUInt64(luid), description);
            RequestSize();
            QueueUpdate();
        }
        catch (Exception e)
        {
            Session.Fail($"viewport: {e.Message}");
        }
    }

    void QueueUpdate()
    {
        if (!_updateQueued && _attached && _compositor != null)
        {
            _updateQueued = true;
            _compositor.RequestCompositionUpdate(_update);
        }
    }

    // Runs once per composition frame while the control is attached, so it polls the host's fence at display rate.
    void Update()
    {
        _updateQueued = false;
        if (!_attached || Session?.Device is not { } device || _surface == null)
        {
            return;
        }
        var frames = Session.Poll();
        // Without a host, the last frame would stay on screen as if the game were frozen.
        _visual!.Visible = Session.HasPicture;
        if (!Session.HasPicture)
        {
            ReleaseImages();
        }
        foreach (var image in _images)
        {
            if (image.TakeCopied(device.Context) is var copied and > 0)
            {
                Session.Copied(copied);
            }
        }
        if (frames != null)
        {
            PresentLatest(frames, device);
        }
        LayoutVisual();
        QueueUpdate();
    }

    void PresentLatest(SharedFrames frames, ViewportDevice device)
    {
        var latest = frames.Completed;
        if (latest == 0 || latest == Session!.FrameShown)
        {
            return;
        }
        // A resize leaves images of the old size, which the compositor no longer needs once they are ready.
        foreach (var old in _images.Where(i => i.Ready && i.Size != frames.Size).ToList())
        {
            _images.Remove(old);
            _ = old.DisposeAsync();
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
        // The fence says the frame is finished, so the copy reads a complete frame. The host draws into this texture
        // again only after the editor acknowledges the copy (see docs/editor/viewport.md#viewport).
        image.Present(device.Context, frames.Texture(latest), latest, _surface!);
        Session.Presented(latest);
    }

    // The host renders at the viewport's size in physical pixels.
    void RequestSize()
    {
        var scaling = TopLevel.GetTopLevel(this)?.RenderScaling ?? 1;
        Session?.RequestSize(new PixelSize((int)Math.Round(Bounds.Width * scaling), (int)Math.Round(Bounds.Height * scaling)));
    }

    /// <summary>A point of the control in pixels of the host's frame, from its top left, or null before the first frame.</summary>
    public Vec2? FramePoint(Point point)
    {
        if (_visual == null || Session is not { FrameSize: { Width: > 0, Height: > 0 } frame } || _visual.Size.X <= 0 || _visual.Size.Y <= 0)
        {
            return null;
        }
        return new Vec2(
            (point.X - _visual.Offset.X) * frame.Width / _visual.Size.X,
            (point.Y - _visual.Offset.Y) * frame.Height / _visual.Size.Y);
    }

    /// <summary>How many frame pixels a unit of the control's length covers.</summary>
    public double FrameScale => _visual is { Size.Y: > 0 } && Session is { FrameSize.Height: > 0 } ? Session.FrameSize.Height / _visual.Size.Y : 1;

    void LayoutVisual()
    {
        if (_visual == null || Session == null)
        {
            return;
        }
        var bounds = Bounds.Size;
        var frame = Session.FrameSize;
        if (frame.Width <= 0 || frame.Height <= 0)
        {
            _visual.Size = new Vector(bounds.Width, bounds.Height);
            _visual.Offset = default;
            return;
        }
        var scale = Session.Scale == ViewportScale.Fit
            ? Math.Min(bounds.Width / frame.Width, bounds.Height / frame.Height)
            : 1 / (TopLevel.GetTopLevel(this)?.RenderScaling ?? 1);
        var size = new Vector(frame.Width * scale, frame.Height * scale);
        _visual.Size = size;
        _visual.Offset = new Vector3D(Math.Round((bounds.Width - size.X) / 2), Math.Round((bounds.Height - size.Y) / 2), 0);
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
