using PreviewMesh = Cinnabar.Editor.Link.Protocol.PreviewMesh;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// An open effect preview (see docs/rendering/particles.md#previews): the game's frames of an effect, which plays at
/// the preview's origin over a ground. It shows the cooked effect, which the daemon cooks again when the script editor
/// saves it, so the preview starts it again.
/// </summary>
public sealed class EffectPreview : PreviewOwner
{
    // The preview's camera starts here, looking down a little at the effect.
    const float StartYaw = 0.6f;
    const float StartPitch = 0.3f;
    const float StartDistance = 4f;
    const float MaxDistance = 40f;

    internal EffectPreview(EditorShell shell, Link.Cook.Asset asset, string path, int? previewId)
        : base(shell, previewId, StartYaw, StartPitch, StartDistance, MaxDistance)
    {
        Guid = asset.Guid;
        Path = path;
        Title = System.IO.Path.GetFileNameWithoutExtension(path);
    }

    public override string Guid { get; }

    public string Path { get; }

    public string Title { get; }

    public override bool PicksMesh => false;

    public override PreviewMesh Mesh => PreviewMesh.Plane;

    public override string Waiting => "The preview draws once the effect cooks.";

    public override void SetMesh(PreviewMesh mesh)
    {
    }
}
