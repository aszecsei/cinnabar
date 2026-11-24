using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Wire = Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// Where the preview of a streamed world is (see docs/editor/world-view.md#the-preview): nowhere, at the active scene
/// view's camera as it moves, or at a position that was pinned.
/// </summary>
public abstract record WorldPreview
{
    public sealed record Off : WorldPreview;

    public sealed record FollowCamera : WorldPreview;

    /// <summary>A raw World_Position.</summary>
    public sealed record Pinned(long[] Position) : WorldPreview;
}

/// <summary>The World editor's documents and the world that the viewport shows (see docs/editor/world-view.md).</summary>
public sealed partial class EditorShell
{
    // The component ID of World_Streamer in lib/engine/streaming.
    const ulong WorldStreamerId = 144;

    // The last World_View that the game was sent, as a key of its content. The game starts with none, which is the empty key.
    // OnNewGameState resets it.
    string _sentWorldView = "";
    // What the game last said that its streaming has in, while it plays. SetStreamed is the only writer: Stop and OnNewGameState clear it.
    Wire.StreamedScenes? _streamed;
    // The world file that a streamer names, as it was read from disk, with the file's time.
    (string Path, DateTime Modified, WorldFile? File)? _streamerWorld;

    /// <summary>The open World editors, in the order that they were opened or shown.</summary>
    public IReadOnlyList<WorldEditor> Worlds => [.. _graphEditors.OfType<WorldEditor>()];

    /// <summary>Where the preview is. <see cref="SetPreview"/> is the only writer.</summary>
    public WorldPreview Preview { get; private set; } = new WorldPreview.Off();

    /// <summary>The preview changed, or what the game has streamed in did.</summary>
    public event Action? WorldStateChanged;

    /// <summary>The scenes that the preview loads, by GUID, in the shown world's order. None without a preview, and in Play.</summary>
    public IReadOnlyList<string> PreviewedScenes =>
        ShownWorld() is { } world && PreviewPosition is { } position
            ? [.. world.File.Scenes.Where(s => WorldStreaming.WouldLoad(s, position)).Select(s => s.Guid)]
            : [];

    /// <summary>
    /// Opens a world in the World editor, or shows its open editor. A file that does not start with <c>world 1</c>
    /// opens in the script editor instead, with the reason in the console.
    /// </summary>
    public WorldEditor? OpenWorld(Asset asset) => OpenEditor(asset) as WorldEditor;

    internal void OnWorldChanged() => SendWorldView();

    /// <summary>The active scene view's pivot as a raw World_Position, or the origin without a camera.</summary>
    internal long[] ViewPivot() => ActiveViewport is { HasCamera: true } view ? view.Camera.Pivot : [0, 0, 0];

    /// <summary>
    /// Sets where the preview is, from the World editor's bar or its commands. Only in Edit does it show: in Play, the
    /// game's own scenes do.
    /// </summary>
    public void SetPreview(WorldPreview preview)
    {
        Preview = preview;
        WorldStateChanged?.Invoke();
        SendWorldView();
    }

    /// <summary>Pins the preview at the active scene view's camera. Returns false without one.</summary>
    public bool PinPreview()
    {
        if (ActiveViewport is not { HasCamera: true } view)
        {
            return false;
        }
        SetPreview(new WorldPreview.Pinned([.. view.Camera.Position]));
        return true;
    }

    // The preview's position as a raw World_Position, or null for none.
    long[]? PreviewPosition => !IsEditing
        ? null
        : Preview switch
        {
            WorldPreview.Pinned pinned => pinned.Position,
            WorldPreview.FollowCamera when ActiveViewport is { HasCamera: true } view => view.Camera.Position,
            _ => null,
        };

    /// <summary>What the game has of a scene of the world that streams, in Play: "Loading", "Ready", or "" for a scene that it does not have in.</summary>
    internal string StreamedState(string world, string scene) =>
        _streamed is { } streamed && SameGuid(streamed.World, world) && streamed.Scenes.FirstOrDefault(s => SameGuid(s.Guid, scene)) is { } found
            ? found.Ready ? "Ready" : "Loading"
            : "";

    static bool SameGuid(byte[] wire, string guid) => string.Equals(Convert.ToHexStringLower(wire), guid, StringComparison.OrdinalIgnoreCase);

    // The world that the viewport shows, with its GUID: the World editor opened last that is still open, else the world of
    // the first streamer in the open scenes, read from disk.
    (string Guid, WorldFile File)? ShownWorld()
    {
        if (_graphEditors.OfType<WorldEditor>().LastOrDefault() is { } editor)
        {
            return (editor.Guid, editor.Document.Graph);
        }
        if (StreamerWorld() is not { } guid || Assets.Find(guid) is not { } asset || Assets.FullPath(asset) is not { } path)
        {
            return null;
        }
        return ReadWorldFile(path) is { } file ? (guid, file) : null;
    }

    // The GUID of the world that the first World_Streamer of the open scenes names, or null for none.
    string? StreamerWorld()
    {
        var streamer = _scenes.SelectMany(s => s.Expanded.Flat.Entities).SelectMany(e => e.Components).FirstOrDefault(c => c.Id == WorldStreamerId);
        return streamer?.Fields.FirstOrDefault(f => f.Name == "world")?.Value.Asset is { Length: > 0 } guid ? guid : null;
    }

    WorldFile? ReadWorldFile(string path)
    {
        try
        {
            var modified = File.GetLastWriteTimeUtc(path);
            if (_streamerWorld is { } cached && cached.Path == path && cached.Modified == modified)
            {
                return cached.File;
            }
            var file = WorldFile.Parse(File.ReadAllText(path)).File;
            _streamerWorld = (path, modified, file);
            return file;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    // The game draws the shown world's scenes (see lib/engine/editor/world_view.odin), and is sent a World_View only when
    // what it would draw changes.
    void SendWorldView()
    {
        var view = BuildWorldView();
        var key = view.Scenes.Length == 0 && view.Preview.Length == 0
            ? ""
            : string.Join(";", view.Scenes.Select(s =>
                $"{string.Join(",", s.Min)}|{string.Join(",", s.Max)}|{s.LoadDistance}|{s.UnloadDistance}|{s.Persistent}{s.Active}{s.Previewed}{s.Loaded}"))
                + "#" + string.Join(";", view.Preview.Select(p => string.Join(",", p.Position)));
        if (key == _sentWorldView)
        {
            return;
        }
        _sentWorldView = key;
        Host.Send(view);
    }

    Wire.WorldView BuildWorldView()
    {
        if (ShownWorld() is not { } world)
        {
            return new Wire.WorldView([], []);
        }
        var position = PreviewPosition;
        var active = Scene is { } scene ? GuidOf(scene) : null;
        List<Wire.WorldViewScene> scenes = [];
        foreach (var s in world.File.Scenes)
        {
            var persistent = s.Persistent;
            long[] min = [0, 0, 0], max = [0, 0, 0];
            var (load, unload) = (0.0, 0.0);
            if (!persistent)
            {
                // A scene without bounds or a load distance has nothing to draw. The cooker reports it.
                if (s.RawMin is not { } lowest || s.RawMax is not { } highest || s.LoadDistance is not { } distance)
                {
                    continue;
                }
                (min, max, load) = (lowest, highest, distance);
                unload = s.UnloadDistance ?? distance * WorldFile.DefaultUnloadFactor;
            }
            var loaded = _streamed is { } streamed && SameGuid(streamed.World, world.Guid) && streamed.Scenes.Any(x => SameGuid(x.Guid, s.Guid));
            scenes.Add(new Wire.WorldViewScene(min, max, (float)load, (float)unload, persistent,
                string.Equals(active, s.Guid, StringComparison.OrdinalIgnoreCase), position != null && WorldStreaming.WouldLoad(s, position), loaded));
        }
        // Only a pinned position has a mark, since a camera is its own mark.
        return new Wire.WorldView([.. scenes], position != null && Preview is WorldPreview.Pinned ? [new Wire.NavProbePoint([.. position])] : []);
    }

    /// <summary>
    /// Opens the scenes that the preview loads, and closes the open scenes of the world that it does not (see
    /// docs/editor/world-view.md#the-preview). Scenes that are not in the world stay, and so does the last open scene.
    /// </summary>
    public void OpenPreviewedScenes()
    {
        if (ShownWorld() is not { } world)
        {
            return;
        }
        var previewed = PreviewedScenes;
        foreach (var guid in previewed)
        {
            if (SceneOfGuid(guid) == null && Assets.Find(guid) is { } asset && Assets.FullPath(asset) is { } path)
            {
                AddScene(path);
            }
        }
        foreach (var open in _scenes.ToList())
        {
            if (GuidOf(open) is { } guid && world.File.Find(guid) != null && !previewed.Contains(guid.ToLowerInvariant()))
            {
                RequestCloseScene(open);
            }
        }
    }

    // The preview follows the active scene view's camera as it moves.
    void OnPreviewCameraMoved(EditorViewport viewport)
    {
        if (Preview is WorldPreview.FollowCamera && viewport == ActiveViewport)
        {
            SendWorldView();
        }
    }

    // The only writer of what the game has streamed in.
    void SetStreamed(Wire.StreamedScenes? streamed)
    {
        _streamed = streamed;
        WorldStateChanged?.Invoke();
    }

    // A new game state has no world view and no streaming.
    void ResetWorldView()
    {
        SetStreamed(null);
        _sentWorldView = "";
        SendWorldView();
    }

    void OnStreamedScenes(Wire.StreamedScenes streamed)
    {
        SetStreamed(streamed);
        SendWorldView();
    }
}
