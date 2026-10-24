using Avalonia;
using Avalonia.Platform;
using Avalonia.Rendering.Composition;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace Cinnabar.Editor.Viewport;

/// <summary>
/// A texture that the compositor shows. ANGLE imports only D3D11 textures with a keyed mutex, and a D3D12 resource
/// cannot have one, so each host frame is copied into one of these (see docs/editor.md#viewport). Key 0 is the
/// editor's turn and key 1 is the compositor's.
/// </summary>
sealed class ViewportImage : IAsyncDisposable
{
    readonly ID3D11Texture2D _texture;
    readonly IDXGIKeyedMutex _mutex;
    readonly ICompositionImportedGpuImage _imported;
    Task _lastPresent = Task.CompletedTask;

    public PixelSize Size { get; }

    /// <summary>True when the compositor is done with the previous frame, so the image can take the next.</summary>
    public bool Ready => _lastPresent.IsCompleted;

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
        using var resource = _texture.QueryInterface<IDXGIResource>();
        _imported = interop.ImportImage(
            new PlatformHandle(resource.SharedHandle, KnownPlatformGraphicsExternalImageHandleTypes.D3D11TextureGlobalSharedHandle),
            new PlatformGraphicsExternalImageProperties
            {
                Width = size.Width,
                Height = size.Height,
                Format = PlatformGraphicsExternalImageFormat.R8G8B8A8UNorm,
            });
    }

    /// <summary>Copies a frame into the image and gives it to the surface. Call only when <see cref="Ready"/>.</summary>
    public void Present(ID3D11DeviceContext context, ID3D11Texture2D frame, CompositionDrawingSurface surface)
    {
        _mutex.AcquireSync(0, int.MaxValue);
        context.CopyResource(_texture, frame);
        context.Flush();
        _mutex.ReleaseSync(1);
        _lastPresent = surface.UpdateWithKeyedMutexAsync(_imported, acquireIndex: 1, releaseIndex: 0);
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
        _mutex.Dispose();
        _texture.Dispose();
    }
}
