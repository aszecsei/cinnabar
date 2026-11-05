using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Content;

/// <summary>
/// The pictures that the content browser waits for (see docs/content/daemon-and-operations.md#thumbnails): those of the
/// materials, meshes and prefabs that show, which the host draws, one at a time, the last to show first, as those are what
/// the user is looking at. The daemon owns the file's name, and sees the file at its next pass. Use it on one thread. What it
/// waits for is named by a tile's key: an asset's GUID, or a part of a prefab, whose picture is no asset's, and so is in no
/// index: its file is its prefab's with the part's ID, which goes when its prefab's does.
/// </summary>
public sealed class ThumbnailQueue(AssetIndex index, Action<ILinkMessage> send, Func<bool> canBake, Func<string, bool>? fileExists = null)
{
    /// <summary>A thumbnail's side, in pixels, as the cooker makes a texture's.</summary>
    public const int Size = 256;

    /// <summary>How long to wait for the host's answer, which a lost link or a reload can lose, before asking for the next.</summary>
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(60);

    readonly Func<string, bool> _exists = fileExists ?? File.Exists;
    // What shows, by a tile's key, the last to show last, and how many tiles show each.
    readonly List<string> _wanted = [];
    readonly Dictionary<string, int> _holders = [];
    // A failure lasts as long as its file's name: what changes the asset gets another chance.
    readonly Dictionary<string, string> _failed = [];
    // The parts' pictures that were written, or seen on the disk.
    readonly HashSet<string> _parts = [];
    (uint Id, string Key, string Path, DateTime Asked)? _asked;
    uint _nextId = 1;

    /// <summary>What the content browser still waits for.</summary>
    public int Waiting => _wanted.Count(Bakeable) ;

    /// <summary>Each file that could not be made, and why.</summary>
    public IEnumerable<string> Failures => _failed.Select(f => $"{f.Key}: {f.Value}");

    /// <summary>A thumbnail is ready, or failed, and its tile's key.</summary>
    public event Action<string>? Changed;

    /// <summary>Why an asset's picture could not be made, for its tooltip, or null.</summary>
    public string? FailureOf(Asset asset) => _failed.GetValueOrDefault(asset.Thumbnail);

    /// <summary>Why a part's picture could not be made, or null.</summary>
    public string? FailureOf(string prefab, ulong node) => PartPath(prefab, node) is { } path ? _failed.GetValueOrDefault(path) : null;

    /// <summary>The file of a part's picture, which its prefab's names, or null for a prefab with no picture.</summary>
    public string? PartPath(string prefab, ulong node) =>
        index.Find(prefab) is { Thumbnail: not "" } asset ? $"{Path.ChangeExtension(asset.Thumbnail, null)}.{node:x16}.png" : null;

    /// <summary>The file of a part's picture, if it is ready.</summary>
    public string? PartPicture(string prefab, ulong node)
    {
        if (PartPath(prefab, node) is not { } path)
        {
            return null;
        }
        if (!_parts.Contains(path))
        {
            if (!_exists(path))
            {
                return null;
            }
            _parts.Add(path);
        }
        return path;
    }

    /// <summary>A tile with this key shows.</summary>
    public void Want(string key, DateTime now)
    {
        _holders[key] = _holders.GetValueOrDefault(key) + 1;
        _wanted.Remove(key);
        _wanted.Add(key);
        Pump(now);
    }

    /// <summary>A tile with this key no longer shows.</summary>
    public void Unwant(string key)
    {
        if (_holders.GetValueOrDefault(key) <= 1)
        {
            _holders.Remove(key);
            _wanted.Remove(key);
        }
        else
        {
            _holders[key]--;
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
            if (Picture(_wanted[i]) is { } picture)
            {
                var id = _nextId++;
                _asked = (id, _wanted[i], picture.Path, now);
                send(new CaptureRequest(id, CaptureKind.Thumbnail, picture.Path));
                send(new BakeThumbnail(id, picture.Kind, Convert.FromHexString(picture.Guid), picture.Node, Size, Size));
                return;
            }
        }
    }

    bool Bakeable(string key) => Picture(key) != null;

    // What the host must draw for a tile's key, unless it is ready, or failed, or the host cannot draw it.
    (string Guid, ulong Node, string Path, ThumbnailKind Kind)? Picture(string key)
    {
        if (ContentBrowserModel.ParsePartKey(key) is { } part)
        {
            return PartPath(part.Prefab, part.Id) is { } path && !_failed.ContainsKey(path) && PartPicture(part.Prefab, part.Id) == null
                ? (part.Prefab, part.Id, path, ThumbnailKind.Prefab)
                : null;
        }
        return index.Find(key) is { ThumbnailReady: false, Thumbnail: not "" } asset && !_failed.ContainsKey(asset.Thumbnail) && KindOf(asset.Kind) is { } kind
            ? (asset.Guid, 0, asset.Thumbnail, kind)
            : null;
    }

    /// <summary>The host wrote a picture, or could not.</summary>
    public void Apply(CaptureResult result, DateTime now)
    {
        if (_asked is not { } asked || asked.Id != result.Id)
        {
            return;
        }
        _asked = null;
        if (!result.Ok)
        {
            _failed[asked.Path] = result.Reason;
        }
        else if (ContentBrowserModel.ParsePartKey(asked.Key) != null)
        {
            _parts.Add(asked.Path);
        }
        else
        {
            index.MarkThumbnailReady(asked.Key, asked.Path);
        }
        Changed?.Invoke(asked.Key);
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
        Changed?.Invoke(asked.Key);
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

    /// <summary>Asks for a part's picture again.</summary>
    public void Forget(string prefab, ulong node, DateTime now)
    {
        if (PartPath(prefab, node) is { } path)
        {
            _failed.Remove(path);
        }
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
