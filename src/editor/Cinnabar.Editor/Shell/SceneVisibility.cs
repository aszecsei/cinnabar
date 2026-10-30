using System.Text.Json;
using Cinnabar.Editor.Host;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;
using SetHidden = Cinnabar.Editor.Link.Protocol.SetHidden;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// Visibility and lock (see docs/editor/shell-and-panels.md#outliner): the entities that the user hid, which the game does not draw,
/// and the ones that the user locked, which the viewport does not pick. Both apply to an entity's descendants too.
/// They are the editor's own state, by scene ID: they change neither the scene nor the game's Disabled, and the editor
/// keeps them for each user and each scene in <c>scene-views.json</c>.
/// </summary>
public sealed class SceneVisibility(
    WorldModel world,
    Selection selection,
    HostSession host,
    EditorSettings settings,
    ConsoleLog console,
    Func<string?> scenePath,
    Action<string, string, string> write,
    Action changed)
{
    public const string FileName = "scene-views.json";

    readonly HashSet<ulong> _hidden = [];
    readonly HashSet<ulong> _locked = [];
    string _sentHidden = "";

    /// <summary>An entity was hidden, shown, locked or unlocked.</summary>
    public event Action? Changed;

    /// <summary>Whether the user hid this entity itself.</summary>
    public bool IsHidden(ulong sceneId) => _hidden.Contains(sceneId);

    /// <summary>Whether the user locked this entity itself.</summary>
    public bool IsLocked(ulong sceneId) => _locked.Contains(sceneId);

    /// <summary>Whether the entity or one of its ancestors is hidden, so the game does not draw it.</summary>
    public bool IsHiddenInTree(ulong handle) => InTree(handle, _hidden);

    /// <summary>Whether the entity or one of its ancestors is locked, so the viewport does not pick it.</summary>
    public bool IsLockedInTree(ulong handle) => InTree(handle, _locked);

    public bool HasHidden => _hidden.Count > 0;

    /// <summary>The picks that the viewport may select: not locked, and not hidden.</summary>
    public bool Pickable(ulong handle) => world.Find(handle) != null && !IsLockedInTree(handle) && !IsHiddenInTree(handle);

    bool InTree(ulong handle, HashSet<ulong> set)
    {
        var node = world.Find(handle);
        for (var depth = 0; node != null && depth < 64; depth++)
        {
            if (set.Contains(node.SceneId))
            {
                return true;
            }
            node = node.Parent == 0 ? null : world.Find(node.Parent);
        }
        return false;
    }

    /// <summary>Hides or shows entities by scene ID. Entities that the game spawned have none, and are always shown.</summary>
    public void SetHidden(IEnumerable<ulong> sceneIds, bool hidden) => Change(_hidden, sceneIds, hidden);

    /// <summary>Locks or unlocks entities by scene ID.</summary>
    public void SetLocked(IEnumerable<ulong> sceneIds, bool locked) => Change(_locked, sceneIds, locked);

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

    List<ulong> SelectedSceneIds() => [.. selection.Entities.Select(h => world.Find(h)?.SceneId ?? 0).Where(id => id != 0)];

    void Change(HashSet<ulong> set, IEnumerable<ulong> sceneIds, bool add)
    {
        var any = false;
        foreach (var id in sceneIds.Where(id => id != 0))
        {
            any |= add ? set.Add(id) : set.Remove(id);
        }
        if (!any)
        {
            return;
        }
        Save();
        Send();
        changed();
        Changed?.Invoke();
    }

    /// <summary>
    /// Sends the hidden list to the game, which hides by handle, so the list goes again whenever the handles of hidden
    /// entities change.
    /// </summary>
    public void Send()
    {
        var handles = _hidden.Select(id => world.FindScene(id)?.Handle ?? 0).Where(h => h != 0).Order().ToArray();
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

    /// <summary>Loads the open scene's hidden and locked entities, as the user left them.</summary>
    public void Load()
    {
        _hidden.Clear();
        _locked.Clear();
        if (scenePath() is { } path && ReadViews().GetValueOrDefault(SceneKey(path)) is { } view)
        {
            static IEnumerable<ulong> Ids(List<string>? ids) =>
                (ids ?? []).Select(s => ulong.TryParse(s, System.Globalization.NumberStyles.HexNumber, null, out var id) ? id : 0).Where(id => id != 0);
            _hidden.UnionWith(Ids(view.Hidden));
            _locked.UnionWith(Ids(view.Locked));
        }
        _sentHidden = "";
        Send();
        Changed?.Invoke();
    }

    public void Save()
    {
        if (scenePath() is not { } path)
        {
            return;
        }
        var views = ReadViews();
        var key = SceneKey(path);
        if (_hidden.Count == 0 && _locked.Count == 0)
        {
            views.Remove(key);
        }
        else
        {
            views[key] = new SceneView([.. _hidden.Order().Select(id => id.ToString("x16"))], [.. _locked.Order().Select(id => id.ToString("x16"))]);
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
