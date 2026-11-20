using BeginOverride = Cinnabar.Editor.Link.Protocol.BeginOverride;
using OverrideAnimator = Cinnabar.Editor.Link.Protocol.OverrideAnimator;
using OverrideCamera = Cinnabar.Editor.Link.Protocol.OverrideCamera;
using OverrideEndReason = Cinnabar.Editor.Link.Protocol.OverrideEndReason;
using OverrideEnded = Cinnabar.Editor.Link.Protocol.OverrideEnded;
using OverrideField = Cinnabar.Editor.Link.Protocol.OverrideField;
using OverrideFrame = Cinnabar.Editor.Link.Protocol.OverrideFrame;
using OverrideSpawn = Cinnabar.Editor.Link.Protocol.OverrideSpawn;
using OverrideTransform = Cinnabar.Editor.Link.Protocol.OverrideTransform;
using ReleaseOverride = Cinnabar.Editor.Link.Protocol.ReleaseOverride;

namespace Cinnabar.Editor.Shell;

/// <summary>Why an override ended.</summary>
public enum OverrideEnd
{
    /// <summary>Its owner released it.</summary>
    Released,

    /// <summary>The game was not in Edit with the editor's scene, so it did not start.</summary>
    NotEditing,

    /// <summary>The game held as many overrides as it can, so it did not start.</summary>
    Full,

    /// <summary>The mode changed from Edit.</summary>
    Mode,

    /// <summary>The editor's scene replaced the game's world.</summary>
    SceneLoaded,

    /// <summary>The game's code reloaded.</summary>
    CodeReloaded,

    /// <summary>The game has a new state, from a new link or a soft restart, which has no overrides.</summary>
    NewGameState,

    /// <summary>The link to the game closed, and the game ended its overrides.</summary>
    LinkClosed,
}

/// <summary>
/// What an override writes over the game's world for one frame (see docs/editor/link.md#overrides). It is the whole of
/// the override's state: what an earlier frame wrote and this one does not goes back to the document's value. Entities
/// are named by the game's scene numbers, as the operations that the editor sends name them.
/// </summary>
public sealed record OverrideWrites
{
    public IReadOnlyList<OverrideSpawn> Spawns { get; init; } = [];
    public IReadOnlyList<OverrideField> Fields { get; init; } = [];
    public IReadOnlyList<OverrideTransform> Transforms { get; init; } = [];
    public IReadOnlyList<OverrideAnimator> Animators { get; init; } = [];
    public IReadOnlyList<OverrideCamera> Cameras { get; init; } = [];
}

/// <summary>
/// An owner's hold on an override: values that the game writes over its world in Edit, outside the document. Through a
/// token that has ended, <see cref="Write"/> and <see cref="Release"/> do nothing, and <see cref="Ended"/> tells the
/// owner once when and why its override ended, whoever ended it.
/// </summary>
public sealed class OverrideToken
{
    readonly WorldOverrides _overrides;

    internal OverrideToken(WorldOverrides overrides, ulong id, string owner)
    {
        _overrides = overrides;
        Id = id;
        Owner = owner;
    }

    /// <summary>The override's number on the link, which only goes up.</summary>
    public ulong Id { get; }

    /// <summary>Who holds it, for messages.</summary>
    public string Owner { get; }

    public bool IsLive => _overrides.IsLive(this);

    public event Action<OverrideEnd>? Ended;

    /// <summary>Sends the override's writes for this frame, and returns false for a token that has ended.</summary>
    public bool Write(OverrideWrites writes) => _overrides.Write(this, writes);

    /// <summary>Ends the override: the game's world shows the document again, in the same frame.</summary>
    public void Release() => _overrides.End(this, OverrideEnd.Released);

    internal void RaiseEnded(OverrideEnd reason) => Ended?.Invoke(reason);
}

/// <summary>
/// The editor's overrides of the game's world in Edit (see docs/editor/link.md#overrides). A scrub, a preview or another
/// owner begins one and gets a token. Nothing here touches the document: no undo entry, no dirty scene, and saves hold
/// the document's values. <see cref="End"/> is the one place that a token ends.
/// </summary>
public sealed class WorldOverrides(EditorShell shell)
{
    readonly Dictionary<ulong, OverrideToken> _live = [];
    // The last number given. It never goes back, even across game states, so the game drops a late message.
    ulong _last;

    public IReadOnlyCollection<OverrideToken> Live => _live.Values;

    /// <summary>Begins an override, or returns null while the game is not linked or the editor does not edit.</summary>
    public OverrideToken? Begin(string owner)
    {
        if (!shell.Host.Linked || !shell.IsEditing)
        {
            return null;
        }
        var token = new OverrideToken(this, ++_last, owner);
        _live[token.Id] = token;
        shell.Host.Send(new BeginOverride(token.Id));
        return token;
    }

    internal bool IsLive(OverrideToken token) => _live.TryGetValue(token.Id, out var live) && live == token;

    internal bool Write(OverrideToken token, OverrideWrites writes)
    {
        if (!IsLive(token))
        {
            return false;
        }
        shell.Host.Send(new OverrideFrame(token.Id, [.. writes.Spawns], [.. writes.Fields], [.. writes.Transforms], [.. writes.Animators], [.. writes.Cameras]));
        return true;
    }

    /// <summary>Ends a live token, and tells the game only when its owner released it: the game ended the others.</summary>
    internal void End(OverrideToken token, OverrideEnd reason)
    {
        if (!IsLive(token))
        {
            return;
        }
        _live.Remove(token.Id);
        if (reason == OverrideEnd.Released)
        {
            shell.Host.Send(new ReleaseOverride(token.Id));
        }
        token.RaiseEnded(reason);
    }

    /// <summary>The game ended an override, or did not start it.</summary>
    internal void OnEnded(OverrideEnded ended)
    {
        if (_live.TryGetValue(ended.Override, out var token))
        {
            End(token, ended.Reason switch
            {
                OverrideEndReason.NotEditing => OverrideEnd.NotEditing,
                OverrideEndReason.Full => OverrideEnd.Full,
                OverrideEndReason.Mode => OverrideEnd.Mode,
                OverrideEndReason.SceneLoaded => OverrideEnd.SceneLoaded,
                OverrideEndReason.CodeReloaded => OverrideEnd.CodeReloaded,
                _ => throw new ArgumentOutOfRangeException(nameof(ended), ended.Reason, "an end that the editor does not know"),
            });
        }
    }

    /// <summary>Ends every token, which the game ends too: at Play, and for a new game state, which has none.</summary>
    internal void EndAll(OverrideEnd reason)
    {
        foreach (var token in _live.Values.ToList())
        {
            End(token, reason);
        }
    }
}
