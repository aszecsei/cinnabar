using Avalonia;
using Microsoft.Win32.SafeHandles;
using Vortice;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.Direct3D12;
using Vortice.DXGI;

namespace Cinnabar.Editor.Viewport;

/// <summary>
/// The editor's D3D11 device, on the adapter that composites the editor's window. The viewport copies the host's
/// frames with it (see docs/editor.md#viewport).
/// </summary>
sealed class ViewportDevice : IDisposable
{
    public ID3D11Device1 Device { get; }
    public ID3D11DeviceContext Context { get; }
    public string AdapterName { get; }

    // Only D3D12 opens a named shared object, so this device turns the host's names into handles.
    readonly ID3D12Device _names;

    public ViewportDevice(ulong luid)
    {
        using var factory = DXGI.CreateDXGIFactory2<IDXGIFactory4>(false);
        using var adapter = factory.EnumAdapterByLuid<IDXGIAdapter1>(new Luid((uint)luid, (int)(luid >> 32)));
        AdapterName = adapter.Description1.Description;
        D3D12.D3D12CreateDevice(adapter, FeatureLevel.Level_12_0, out ID3D12Device? names).CheckError();
        _names = names!;
        D3D11.D3D11CreateDevice(adapter, DriverType.Unknown, DeviceCreationFlags.BgraSupport, [FeatureLevel.Level_11_1],
            out ID3D11Device device, out ID3D11DeviceContext context).CheckError();
        Device = device.QueryInterface<ID3D11Device1>();
        device.Dispose();
        Context = context;
    }

    /// <summary>Opens a named shared object, or returns null if it does not exist (yet).</summary>
    public SafeFileHandle? OpenByName(string name)
    {
        try
        {
            return new SafeFileHandle(_names.OpenSharedHandleByName(name), ownsHandle: true);
        }
        catch (SharpGen.Runtime.SharpGenException)
        {
            return null;
        }
    }

    public ID3D12Fence OpenFence(SafeFileHandle handle) => _names.OpenSharedHandle<ID3D12Fence>(handle.DangerousGetHandle());

    public void Dispose()
    {
        Context.Dispose();
        Device.Dispose();
        _names.Dispose();
    }
}

/// <summary>
/// One generation of the host's frames: the named textures <c>&lt;prefix&gt;.texture0..2</c> and the fence
/// <c>&lt;prefix&gt;.fence</c>, where the prefix comes from the host's <c>Frame_Target</c> message (see
/// docs/gpu.md#presentation). Fence value v means that texture v % 3 holds frame v, finished.
/// </summary>
sealed class SharedFrames : IDisposable
{
    // SHARED_TEXTURE_COUNT in lib/core/gpu/d3d12/shared.odin.
    const int TextureCount = 3;

    readonly ID3D12Fence _fence;
    readonly ID3D11Texture2D[] _textures;

    public PixelSize Size { get; }

    /// <summary>The number of the newest finished frame, or 0 before the first.</summary>
    public ulong Completed => _fence.CompletedValue;

    SharedFrames(ID3D12Fence fence, ID3D11Texture2D[] textures)
    {
        _fence = fence;
        _textures = textures;
        var desc = textures[0].Description;
        Size = new PixelSize((int)desc.Width, (int)desc.Height);
    }

    /// <summary>
    /// Opens the host's frames, or returns null if the host has not made them yet, or has already replaced them with
    /// another generation while they were opening.
    /// </summary>
    public static SharedFrames? TryOpen(ViewportDevice device, string prefix)
    {
        // The host makes the textures before the fence, so an open fence means the textures exist, unless a resize
        // releases them right after.
        using var fenceHandle = device.OpenByName($"{prefix}.fence");
        if (fenceHandle == null)
        {
            return null;
        }
        var fence = device.OpenFence(fenceHandle);
        var textures = new List<ID3D11Texture2D>(TextureCount);
        try
        {
            for (var i = 0; i < TextureCount; i++)
            {
                using var handle = device.OpenByName($"{prefix}.texture{i}");
                if (handle == null)
                {
                    break;
                }
                textures.Add(device.Device.OpenSharedResource1<ID3D11Texture2D>(handle.DangerousGetHandle()));
            }
        }
        catch (SharpGen.Runtime.SharpGenException e) when (e.HResult == E_HANDLE)
        {
        }
        if (textures.Count == TextureCount)
        {
            return new SharedFrames(fence, [.. textures]);
        }
        textures.ForEach(t => t.Dispose());
        fence.Dispose();
        return null;
    }

    // What opening a shared object gives when its last owner released it a moment ago.
    const int E_HANDLE = unchecked((int)0x80070006);

    public ID3D11Texture2D Texture(ulong frame) => _textures[frame % TextureCount];

    public void Dispose()
    {
        foreach (var texture in _textures)
        {
            texture.Dispose();
        }
        _fence.Dispose();
    }
}
