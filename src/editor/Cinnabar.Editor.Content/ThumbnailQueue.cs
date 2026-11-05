using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Content;

/// <summary>
/// The pictures that the content browser waits for (see docs/content/daemon-and-operations.md#thumbnails): those of the
/// materials, meshes and prefabs that show, which the host draws, one at a time, the last to show first, as those are what
/// the user is looking at. The daemon owns the file's name, and sees the file at its next pass. Use it on one thread.
/// </summary>
public sealed class ThumbnailQueue(AssetIndex index, Action<ILinkMessage> send, Func<bool> canBake)
{
    /// <summary>A thumbnail's side, in pixels, as the cooker makes a texture's.</summary>
    public const int Size = 256;

    /// <summary>How long to wait for the host's answer, which a lost link or a reload can lose, before asking for the next.</summary>
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(60);

    // What shows, by GUID, the last to show last, and how many tiles show each.
    readonly List<string> _wanted = [];
    readonly Dictionary<string, int> _holders = [];
    // A failure lasts as long as its file's name: what changes the asset gets another chance.
    readonly Dictionary<string, string> _failed = [];
    (uint Id, string Guid, string Path, DateTime Asked)? _asked;
    uint _nextId = 1;

    /// <summary>What the content browser still waits for.</summary>
    public int Waiting => _wanted.Count(Bakeable) ;

    /// <summary>Each file that could not be made, and why.</summary>
    public IEnumerable<string> Failures => _failed.Select(f => $"{f.Key}: {f.Value}");

    /// <summary>A thumbnail is ready, or failed, and its asset's GUID.</summary>
    public event Action<string>? Changed;

    /// <summary>Why an asset's picture could not be made, for its tooltip, or null.</summary>
    public string? FailureOf(Asset asset) => _failed.GetValueOrDefault(asset.Thumbnail);

    /// <summary>A tile of the asset shows.</summary>
    public void Want(string guid, DateTime now)
    {
        _holders[guid] = _holders.GetValueOrDefault(guid) + 1;
        _wanted.Remove(guid);
        _wanted.Add(guid);
        Pump(now);
    }

    /// <summary>A tile of the asset no longer shows.</summary>
    public void Unwant(string guid)
    {
        if (_holders.GetValueOrDefault(guid) <= 1)
        {
            _holders.Remove(guid);
            _wanted.Remove(guid);
        }
        else
        {
            _holders[guid]--;
        }
    }

    /// <summary>Asks for the next picture, if nothing is on its way and the host can draw, and gives up on an answer that is lost.</summary>
    public void Pump(DateTime now)
    {
        if (_asked is { } asked)
        {
            if (now - asked.Asked < Timeout)
            {
                return;
            }
            _asked = null;
        }
        if (!canBake())
        {
            return;
        }
        for (var i = _wanted.Count - 1; i >= 0; i--)
        {
            if (index.Find(_wanted[i]) is { } asset && Bakeable(_wanted[i]) && KindOf(asset.Kind) is { } kind)
            {
                var id = _nextId++;
                _asked = (id, asset.Guid, asset.Thumbnail, now);
                send(new CaptureRequest(id, CaptureKind.Thumbnail, asset.Thumbnail));
                send(new BakeThumbnail(id, kind, Convert.FromHexString(asset.Guid), 0, Size, Size));
                return;
            }
        }
    }

    bool Bakeable(string guid) =>
        index.Find(guid) is { ThumbnailReady: false, Thumbnail: not "" } asset && !_failed.ContainsKey(asset.Thumbnail) && KindOf(asset.Kind) != null;

    /// <summary>The host wrote a picture, or could not.</summary>
    public void Apply(CaptureResult result, DateTime now)
    {
        if (_asked is not { } asked || asked.Id != result.Id)
        {
            return;
        }
        _asked = null;
        if (result.Ok)
        {
            index.MarkThumbnailReady(asked.Guid, asked.Path);
        }
        else
        {
            _failed[asked.Path] = result.Reason;
        }
        Changed?.Invoke(asked.Guid);
        Pump(now);
    }

    /// <summary>The game could not draw a picture.</summary>
    public void Apply(ThumbnailFailed failed, DateTime now)
    {
        if (_asked is not { } asked || asked.Id != failed.Id)
        {
            return;
        }
        _asked = null;
        _failed[asked.Path] = failed.Reason;
        Changed?.Invoke(asked.Guid);
        Pump(now);
    }

    /// <summary>Asks again for what a lost link lost, and for what a new game can draw.</summary>
    public void Restart(DateTime now)
    {
        _asked = null;
        Pump(now);
    }

    /// <summary>Asks for a picture again, as Regenerate does, whatever happened last time.</summary>
    public void Forget(Asset asset, DateTime now)
    {
        _failed.Remove(asset.Thumbnail);
        Pump(now);
    }

    static ThumbnailKind? KindOf(AssetKind kind) => kind switch
    {
        AssetKind.Material or AssetKind.MaterialInstance => ThumbnailKind.Material,
        AssetKind.Mesh => ThumbnailKind.Mesh,
        AssetKind.Prefab => ThumbnailKind.Prefab,
        _ => null,
    };
}
