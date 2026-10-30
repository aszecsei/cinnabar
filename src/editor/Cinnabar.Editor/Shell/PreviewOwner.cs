using Cinnabar.Editor.Viewport;
using ClosePreviewMessage = Cinnabar.Editor.Link.Protocol.ClosePreview;
using OpenPreviewMessage = Cinnabar.Editor.Link.Protocol.OpenPreview;
using PreviewAcknowledged = Cinnabar.Editor.Link.Protocol.PreviewAcknowledged;
using PreviewMesh = Cinnabar.Editor.Link.Protocol.PreviewMesh;
using PreviewSettings = Cinnabar.Editor.Link.Protocol.PreviewSettings;
using PreviewTarget = Cinnabar.Editor.Link.Protocol.PreviewTarget;

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
/// A document with a preview slot: its frames from the game, its camera, and its link to the game. The preview's ID is
/// the slot, which <see cref="PreviewSlots"/> hands out.
/// </summary>
public abstract class PreviewOwner : IPreviewOwner, IDisposable
{
    // The preview's pitch stays short of looking straight down or up.
    const float MaxPitch = 1.45f;

    readonly float _maxDistance;
    protected readonly EditorShell _shell;

    protected PreviewOwner(EditorShell shell, int? previewId, float yaw, float pitch, float distance, float maxDistance)
    {
        _shell = shell;
        PreviewId = previewId;
        Yaw = yaw;
        Pitch = pitch;
        Distance = distance;
        _maxDistance = maxDistance;
        if (previewId != null)
        {
            Preview = new ViewportSession();
            Preview.SizeRequested += size =>
            {
                Size = (Math.Clamp(size.Width, 16, 1024), Math.Clamp(size.Height, 16, 1024));
                SendSettings();
            };
            Preview.FrameCopied += (generation, frame) => _shell.Host.Send(new PreviewAcknowledged((uint)previewId, generation, frame));
            Preview.Failed += message => _shell.Console.Add(Model.LogLevel.Warning, message);
        }
    }

    /// <summary>The GUID of the asset that the preview shows.</summary>
    public abstract string Guid { get; }

    /// <summary>The preview's ID, or null when every preview is in use, or for a document with none.</summary>
    public int? PreviewId { get; }

    /// <summary>The preview's frames, or null without a preview.</summary>
    public ViewportSession? Preview { get; }

    public abstract bool PicksMesh { get; }

    public abstract PreviewMesh Mesh { get; }

    public abstract string Waiting { get; }

    public float Yaw { get; private set; }
    public float Pitch { get; private set; }
    public float Distance { get; private set; }
    public (int Width, int Height) Size { get; private set; } = (256, 256);

    /// <summary>Whether the game shows the unsaved text that the daemon cooked into the cache's preview area.</summary>
    protected virtual bool ShowsUnsavedText => false;

    public abstract void SetMesh(PreviewMesh mesh);

    public void Orbit(double dx, double dy)
    {
        Yaw += (float)(dx * 0.01);
        Pitch = Math.Clamp(Pitch + (float)(dy * 0.01), -MaxPitch, MaxPitch);
        SendSettings();
    }

    public void Zoom(double notches)
    {
        Distance = Math.Clamp(Distance * (float)Math.Pow(0.9, notches), 0.6f, _maxDistance);
        SendSettings();
    }

    /// <summary>Tells the game what the preview shows, as when the host links.</summary>
    internal void SendPreview()
    {
        if (PreviewId is not { } id)
        {
            return;
        }
        _shell.Host.Send(new OpenPreviewMessage((uint)id, Convert.FromHexString(Guid), ShowsUnsavedText));
        SendSettings();
    }

    protected void SendSettings()
    {
        if (PreviewId is { } id)
        {
            _shell.Host.Send(new PreviewSettings((uint)id, Mesh, new byte[16], Yaw, Pitch, Distance, Size.Width, Size.Height));
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

    public virtual void Dispose() => Preview?.Dispose();
}

/// <summary>The shell's preview slots (see docs/editor/material-editor.md#material-editor): which are in use, and the link of each to the game.</summary>
public sealed class PreviewSlots(Func<IEnumerable<PreviewOwner>> owners)
{
    /// <summary>The first preview ID that no owner has, or null when every one is in use.</summary>
    public int? Free() =>
        Enumerable.Range(0, EditorShell.MaxPreviews).Cast<int?>().FirstOrDefault(id => !owners().Any(o => o.PreviewId == id));

    /// <summary>Tells the game what each preview shows, as a new link needs.</summary>
    public void SendAll()
    {
        foreach (var owner in owners())
        {
            owner.SendPreview();
        }
    }

    /// <summary>Drops each preview's frames, as a lost link does.</summary>
    public void DisconnectAll()
    {
        foreach (var owner in owners())
        {
            owner.Preview?.Disconnect();
        }
    }

    /// <summary>Gives a preview's frame target to the owner of its slot.</summary>
    public void Route(PreviewTarget target)
    {
        if (owners().FirstOrDefault(o => o.PreviewId == (int)target.Id) is { Preview: { } session })
        {
            session.Connect(target.Prefix, target.Generation);
        }
    }
}
