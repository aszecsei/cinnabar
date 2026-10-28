using Cinnabar.Editor.Viewport;
using ClosePreviewMessage = Cinnabar.Editor.Link.Protocol.ClosePreview;
using OpenPreviewMessage = Cinnabar.Editor.Link.Protocol.OpenPreview;
using PreviewAcknowledged = Cinnabar.Editor.Link.Protocol.PreviewAcknowledged;
using PreviewMesh = Cinnabar.Editor.Link.Protocol.PreviewMesh;
using PreviewSettings = Cinnabar.Editor.Link.Protocol.PreviewSettings;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// What a preview pane shows and how its camera moves: a material editor's preview of a material on a mesh, or an
/// effect's preview, which picks no mesh.
/// </summary>
public interface IPreviewOwner
{
    /// <summary>The preview's frames, or null when every preview is in use.</summary>
    ViewportSession? Preview { get; }

    /// <summary>Whether the pane offers the meshes to show the preview on.</summary>
    bool PicksMesh { get; }

    PreviewMesh Mesh { get; }

    /// <summary>What the pane says until the first frame comes, with the host linked.</summary>
    string Waiting { get; }

    void SetMesh(PreviewMesh mesh);

    /// <summary>Turns the preview's camera by pixels of mouse movement.</summary>
    void Orbit(double dx, double dy);

    /// <summary>Moves the preview's camera nearer or farther by wheel notches.</summary>
    void Zoom(double notches);
}

/// <summary>
/// An open effect preview (see docs/rendering/particles.md#previews): the game's frames of an effect, which plays at
/// the preview's origin over a ground. It shows the cooked effect, which the daemon cooks again when the script editor
/// saves it, so the preview starts it again.
/// </summary>
public sealed class EffectPreview : IPreviewOwner, IDisposable
{
    // The preview's camera starts here, looking down a little at the effect, and its pitch stays short of looking
    // straight down or up.
    const float StartYaw = 0.6f;
    const float StartPitch = 0.3f;
    const float StartDistance = 4f;
    const float MaxPitch = 1.45f;

    readonly EditorShell _shell;

    internal EffectPreview(EditorShell shell, Link.Cook.Asset asset, string path, int? previewId)
    {
        _shell = shell;
        Guid = asset.Guid;
        Path = path;
        Title = System.IO.Path.GetFileNameWithoutExtension(path);
        PreviewId = previewId;
        if (previewId != null)
        {
            Preview = new ViewportSession();
            Preview.SizeRequested += size =>
            {
                Size = (Math.Clamp(size.Width, 16, 1024), Math.Clamp(size.Height, 16, 1024));
                SendSettings();
            };
            Preview.FrameCopied += (generation, frame) => _shell.Host.Send(new PreviewAcknowledged((uint)previewId, generation, frame));
            Preview.Failed += message => _shell.Console.Add(Panels.LogLevel.Warning, message);
        }
    }

    public string Guid { get; }

    public string Path { get; }

    public string Title { get; }

    /// <summary>The preview's ID, or null when every preview is in use.</summary>
    public int? PreviewId { get; }

    public ViewportSession? Preview { get; }

    public bool PicksMesh => false;

    public PreviewMesh Mesh => PreviewMesh.Plane;

    public string Waiting => "The preview draws once the effect cooks.";

    public float Yaw { get; private set; } = StartYaw;
    public float Pitch { get; private set; } = StartPitch;
    public float Distance { get; private set; } = StartDistance;
    public (int Width, int Height) Size { get; private set; } = (256, 256);

    public void SetMesh(PreviewMesh mesh)
    {
    }

    public void Orbit(double dx, double dy)
    {
        Yaw += (float)(dx * 0.01);
        Pitch = Math.Clamp(Pitch + (float)(dy * 0.01), -MaxPitch, MaxPitch);
        SendSettings();
    }

    public void Zoom(double notches)
    {
        Distance = Math.Clamp(Distance * (float)Math.Pow(0.9, notches), 0.6f, 40f);
        SendSettings();
    }

    /// <summary>Tells the game what the preview shows, as when the host links.</summary>
    internal void SendPreview()
    {
        if (PreviewId is not { } id)
        {
            return;
        }
        _shell.Host.Send(new OpenPreviewMessage((uint)id, Convert.FromHexString(Guid), false));
        SendSettings();
    }

    void SendSettings()
    {
        if (PreviewId is { } id)
        {
            _shell.Host.Send(new PreviewSettings((uint)id, PreviewMesh.Plane, new byte[16], Yaw, Pitch, Distance, Size.Width, Size.Height));
        }
    }

    internal void ClosePreview()
    {
        if (PreviewId is { } id)
        {
            _shell.Host.Send(new ClosePreviewMessage((uint)id));
            Preview?.Disconnect();
        }
    }

    public void Dispose() => Preview?.Dispose();
}
