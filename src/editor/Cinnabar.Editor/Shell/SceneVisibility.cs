using System.Text.Json;
using Cinnabar.Editor.Host;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;
using SetHidden = Cinnabar.Editor.Link.Protocol.SetHidden;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// Visibility and lock (see docs/editor/shell-and-panels.md#outliner): the entities that the user hid, which the game does not draw,
/// and the ones that the user locked, which the viewport does not pick. Both apply to an entity's descendants too.
/// They are the editor's own state, by scene and scene ID: they change neither the scene nor the game's Disabled, and
/// the editor keeps them for each user and each scene file in <c>scene-views.json</c>. Each open scene has its own (see
/// docs/editor/document-and-scenes.md#several-scenes).
/// </summary>
public sealed class SceneVisibility(
    WorldModel world,
    Selection selection,
    HostSession host,
    EditorSettings settings,
    ConsoleLog console,
    Func<IReadOnlyList<(uint Number, string Path)>> scenes,
    Action<string, string, string> write)
{
    public const string FileName = "scene-views.json";

    readonly HashSet<(uint Scene, ulong Id)> _hidden = [];
    readonly HashSet<(uint Scene, ulong Id)> _locked = [];
    string _sentHidden = "";

    /// <summary>An entity was hidden, shown, locked or unlocked.</summary>
    public event Action? Changed;

    /// <summary>Whether the user hid this entity of the scene with the number itself.</summary>
    public bool IsHidden(uint scene, ulong sceneId) => _hidden.Contains((scene, sceneId));

    /// <summary>Whether the user locked this entity of the scene with the number itself.</summary>
    public bool IsLocked(uint scene, ulong sceneId) => _locked.Contains((scene, sceneId));

    /// <summary>Whether the entity or one of its ancestors is hidden, so the game does not draw it.</summary>
    public bool IsHiddenInTree(ulong handle) => InTree(handle, _hidden);

    /// <summary>Whether the entity or one of its ancestors is locked, so the viewport does not pick it.</summary>
    public bool IsLockedInTree(ulong handle) => InTree(handle, _locked);

    public bool HasHidden => _hidden.Count > 0;

    /// <summary>The picks that the viewport may select: not locked, and not hidden.</summary>
    public bool Pickable(ulong handle) => world.Find(handle) != null && !IsLockedInTree(handle) && !IsHiddenInTree(handle);

    bool InTree(ulong handle, HashSet<(uint, ulong)> set)
    {
        var node = world.Find(handle);
        for (var depth = 0; node != null && depth < 64; depth++)
        {
            if (node.SceneId != 0 && set.Contains((node.Scene, node.SceneId)))
            {
                return true;
            }
            node = node.Parent == 0 ? null : world.Find(node.Parent);
        }
        return false;
    }

    /// <summary>
    /// Hides or shows entities by scene and scene ID. Entities that the game spawned have none, and are always shown.
    /// </summary>
    public void SetHidden(IEnumerable<(uint Scene, ulong Id)> entities, bool hidden) => Change(_hidden, entities, hidden);

    /// <summary>Locks or unlocks entities by scene and scene ID.</summary>
    public void SetLocked(IEnumerable<(uint Scene, ulong Id)> entities, bool locked) => Change(_locked, entities, locked);

    /// <summary>Hides the selected entities, or shows them if they are all hidden.</summary>
    public void ToggleHideSelected()
    {
        var ids = SelectedSceneIds();
        SetHidden(ids, !ids.All(_hidden.Contains));
    }

    /// <summary>Locks the selected entities, or unlocks them if they are all locked.</summary>
    public void ToggleLockSelected()
    {
        var ids = SelectedSceneIds();
        SetLocked(ids, !ids.All(_locked.Contains));
    }

    public void ShowAll() => SetHidden([.. _hidden], false);

    List<(uint Scene, ulong Id)> SelectedSceneIds() =>
        [.. selection.Entities.Select(world.Find).OfType<EntityNode>().Where(n => n.SceneId != 0).Select(n => (n.Scene, n.SceneId))];

    void Change(HashSet<(uint, ulong)> set, IEnumerable<(uint Scene, ulong Id)> entities, bool add)
    {
        var any = false;
        foreach (var id in entities.Where(e => e.Id != 0))
        {
            any |= add ? set.Add(id) : set.Remove(id);
        }
        if (!any)
        {
            return;
        }
        Save();
        Send();
        Changed?.Invoke();
    }

    /// <summary>
    /// Sends the hidden list to the game, which hides by handle, so the list goes again whenever the handles of hidden
    /// entities change.
    /// </summary>
    public void Send()
    {
        var handles = _hidden.Select(e => world.FindScene(e.Scene, e.Id)?.Handle ?? 0).Where(h => h != 0).Order().ToArray();
        var key = string.Join(",", handles);
        if (key != _sentHidden && host.Linked)
        {
            _sentHidden = key;
            host.Send(new SetHidden(handles));
        }
    }

    sealed record SceneView(List<string> Hidden, List<string> Locked);

    static string SceneKey(string path) => Path.GetFullPath(path).ToLowerInvariant();

    Dictionary<string, SceneView> ReadViews()
    {
        try
        {
            return settings.Read(FileName) is { } text ? JsonSerializer.Deserialize<Dictionary<string, SceneView>>(text) ?? [] : [];
        }
        catch (JsonException e)
        {
            console.Add(LogLevel.Warning, $"scene views: {Path.Combine(settings.Directory, FileName)}: {e.Message}");
            return [];
        }
    }

    /// <summary>Loads each open scene's hidden and locked entities, as the user left them in its file.</summary>
    public void Load()
    {
        _hidden.Clear();
        _locked.Clear();
        var views = ReadViews();
        foreach (var (number, path) in scenes())
        {
            if (views.GetValueOrDefault(SceneKey(path)) is { } view)
            {
                IEnumerable<(uint, ulong)> Ids(List<string>? ids) =>
                    (ids ?? []).Select(s => ulong.TryParse(s, System.Globalization.NumberStyles.HexNumber, null, out var id) ? id : 0).Where(id => id != 0).Select(id => (number, id));
                _hidden.UnionWith(Ids(view.Hidden));
                _locked.UnionWith(Ids(view.Locked));
            }
        }
        _sentHidden = "";
        Send();
        Changed?.Invoke();
    }

    /// <summary>Writes each open scene's hidden and locked entities under its file.</summary>
    public void Save()
    {
        var open = scenes();
        if (open.Count == 0)
        {
            return;
        }
        var views = ReadViews();
        foreach (var (number, path) in open)
        {
            var key = SceneKey(path);
            var hidden = _hidden.Where(e => e.Scene == number).Select(e => e.Id).Order().ToList();
            var locked = _locked.Where(e => e.Scene == number).Select(e => e.Id).Order().ToList();
            if (hidden.Count == 0 && locked.Count == 0)
            {
                views.Remove(key);
            }
            else
            {
                views[key] = new SceneView([.. hidden.Select(id => id.ToString("x16"))], [.. locked.Select(id => id.ToString("x16"))]);
            }
        }
        write("scene views", FileName, JsonSerializer.Serialize(views, new JsonSerializerOptions { WriteIndented = true }));
    }

    /// <summary>A new link, or a resync, has a game that hides nothing yet.</summary>
    public void Resend()
    {
        _sentHidden = "";
        Send();
    }
}
