using Avalonia;
using Avalonia.Platform;
using Avalonia.Rendering.Composition;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace Cinnabar.Editor.Viewport;

/// <summary>
/// A texture that the compositor shows. ANGLE imports only D3D11 textures with a keyed mutex, and a D3D12 resource
/// cannot have one, so each host frame is copied into one of these (see docs/editor/viewport.md#viewport). Key 0 is the
/// editor's turn and key 1 is the compositor's.
/// </summary>
sealed class ViewportImage : IAsyncDisposable
{
    readonly ID3D11Texture2D _texture;
    readonly IDXGIKeyedMutex _mutex;
    readonly ICompositionImportedGpuImage _imported;
    // Signals when the GPU has finished the copy, so the host may draw into its texture again.
    readonly ID3D11Query _copied;
    Task _lastPresent = Task.CompletedTask;

    public PixelSize Size { get; }

    /// <summary>True when the compositor is done with the previous frame, so the image can take the next.</summary>
    public bool Ready => _lastPresent.IsCompleted;

    /// <summary>The frame whose copy the GPU may not have finished yet, or 0.</summary>
    public ulong Copying { get; private set; }

    public ViewportImage(ID3D11Device device, ICompositionGpuInterop interop, PixelSize size)
    {
        Size = size;
        _texture = device.CreateTexture2D(new Texture2DDescription
        {
            Width = (uint)size.Width,
            Height = (uint)size.Height,
            MipLevels = 1,
            ArraySize = 1,
            // The host's frames are R8G8B8A8_TYPELESS, written through an sRGB view, so the bytes are already sRGB
            // and the compositor shows them as they are.
            Format = Format.R8G8B8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Default,
            BindFlags = BindFlags.ShaderResource | BindFlags.RenderTarget,
            MiscFlags = ResourceOptionFlags.SharedKeyedMutex,
        });
        _mutex = _texture.QueryInterface<IDXGIKeyedMutex>();
        _copied = device.CreateQuery(new QueryDescription(QueryType.Event));
        using var resource = _texture.QueryInterface<IDXGIResource>();
        _imported = interop.ImportImage(
            new PlatformHandle(resource.SharedHandle, KnownPlatformGraphicsExternalImageHandleTypes.D3D11TextureGlobalSharedHandle),
            new PlatformGraphicsExternalImageProperties
            {
                Width = size.Width,
                Height = size.Height,
                Format = PlatformGraphicsExternalImageFormat.R8G8B8A8UNorm,
                // D3D's rows start at the top. Without this, the compositor takes the first row as the bottom one, as
                // OpenGL does, and shows the frame upside down.
                TopLeftOrigin = true,
            });
    }

    /// <summary>Copies a frame into the image and gives it to the surface. Call only when <see cref="Ready"/>.</summary>
    public void Present(ID3D11DeviceContext context, ID3D11Texture2D frame, ulong number, CompositionDrawingSurface surface)
    {
        _mutex.AcquireSync(0, int.MaxValue);
        context.CopyResource(_texture, frame);
        context.End(_copied);
        Copying = number;
        context.Flush();
        _mutex.ReleaseSync(1);
        _lastPresent = surface.UpdateWithKeyedMutexAsync(_imported, acquireIndex: 1, releaseIndex: 0);
    }

    /// <summary>The frame whose copy the GPU has just finished, or 0. It reports each frame once.</summary>
    public ulong TakeCopied(ID3D11DeviceContext context)
    {
        // S_OK once the query's point in the command stream has passed, and S_FALSE before.
        if (Copying == 0 || context.GetData(_copied, IntPtr.Zero, 0, AsyncGetDataFlags.DoNotFlush).Code != 0)
        {
            return 0;
        }
        var frame = Copying;
        Copying = 0;
        return frame;
    }

    public async ValueTask DisposeAsync()
    {
        try
        {
            await _lastPresent;
        }
        catch (Exception)
        {
            // The surface is going away with the image. Nothing waits for this frame.
        }
        await _imported.DisposeAsync();
        _copied.Dispose();
        _mutex.Dispose();
        _texture.Dispose();
    }
}
