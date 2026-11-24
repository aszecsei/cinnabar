using System.Text.Json;
using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The project's sublevels in the editor (see docs/editor/shell-and-panels.md#sublevels): their declarations in
/// <c>project.settings</c>, the editor's choice of the ones that Edit loads, which each user keeps for each project in
/// <c>sublevels.json</c>, and putting the selection in one.
/// </summary>
public sealed partial class EditorShell
{
    /// <summary>The editor's settings file that keeps, for each project, the sublevels that Edit does not load.</summary>
    public const string SublevelsFileName = "sublevels.json";

    /// <summary>A sublevel was declared, changed or taken out, or Edit loaded or unloaded one, or the mode changed.</summary>
    public event Action? SublevelsChanged;

    /// <summary>
    /// The sublevels that the project declares, with whether each starts active, in the order of the files. The files
    /// are read again when either one's time changes, as a pull or another program can change them.
    /// </summary>
    public IReadOnlyList<(string Name, bool Active)> DeclaredSublevels
    {
        get
        {
            var stamp = (StampOf(ProjectPath), StampOf(ProjectSettings.UserPath(ProjectPath)));
            if (_declared is not { } declared || declared.Stamp != stamp)
            {
                _declared = declared = (stamp, ProjectSettings.Sublevels(ProjectPath));
            }
            return declared.Sublevels;
        }
    }

    // The declarations as the files had them at their times.
    ((DateTime, DateTime) Stamp, IReadOnlyList<(string Name, bool Active)> Sublevels)? _declared;

    static DateTime StampOf(string path) => File.Exists(path) ? File.GetLastWriteTimeUtc(path) : DateTime.MinValue;

    /// <summary>The sublevels that the project declares, then those that the open scenes use without a declaration.</summary>
    public IReadOnlyList<string> KnownSublevels()
    {
        var names = DeclaredSublevels.Select(s => s.Name).ToList();
        names.AddRange(UsedSublevels().Where(s => !names.Contains(s)).Order(StringComparer.Ordinal));
        return names;
    }

    /// <summary>The sublevels that entities of the open scenes are in, without the base.</summary>
    public IReadOnlySet<string> UsedSublevels()
    {
        var used = new HashSet<string>(StringComparer.Ordinal);
        foreach (var document in _scenes)
        {
            var flat = document.Expanded.Flat;
            used.UnionWith(flat.Entities.Select(flat.SublevelOf).Where(s => s != ""));
        }
        return used;
    }

    /// <summary>How many entities of the open scenes are in the sublevel, or with "" in the base, descendants included.</summary>
    public int SublevelCount(string sublevel) => _scenes.Sum(d => d.Expanded.Flat.Entities.Count(e => d.Expanded.Flat.SublevelOf(e) == sublevel));

    /// <summary>The sublevel that an entity of an open scene is in, or "" for the base and for an entity that the game spawned.</summary>
    public string SublevelOf(EntityNode node) =>
        SceneOf(node)?.Expanded.Flat is { } flat && flat.Find(node.SceneId) is { } entity ? flat.SublevelOf(entity) : "";

    /// <summary>
    /// Declares a sublevel in <c>project.settings</c>, or changes whether it starts active. A name that a sublevel cannot
    /// have is refused, and the console says why.
    /// </summary>
    public bool DeclareSublevel(string name, bool active)
    {
        if (!SceneFile.IsSublevelName(name))
        {
            Console.Add(LogLevel.Error, $"sublevels: \"{name}\" is not a sublevel's name: it has 1 to {SceneFile.MaxSublevelName} letters, digits and underscores");
            return false;
        }
        if (!DeclaredSublevels.Any(s => s.Name == name) && DeclaredSublevels.Count >= MaxSublevels)
        {
            Console.Add(LogLevel.Error, $"sublevels: a project has at most {MaxSublevels} sublevels");
            return false;
        }
        return WriteSublevel(name, active ? "active" : "inactive");
    }

    /// <summary>
    /// Takes a sublevel's declaration out of <c>project.settings</c>. One that entities of the open scenes are in stays,
    /// as the scenes would not cook without it, and the console says why.
    /// </summary>
    public bool RemoveSublevel(string name)
    {
        if (SublevelCount(name) is var count and > 0)
        {
            Console.Add(LogLevel.Error, $"sublevels: cannot remove {name}: {count} {(count == 1 ? "entity is" : "entities are")} in it. Put them in another sublevel first.");
            return false;
        }
        return WriteSublevel(name, null);
    }

    /// <summary>The most sublevels that a project declares, as the game's settings hold them (<c>format.MAX_SUBLEVELS</c>).</summary>
    public const int MaxSublevels = 32;

    bool WriteSublevel(string name, string? value)
    {
        try
        {
            ProjectSettings.Set(ProjectPath, ProjectSettings.SublevelPrefix + name, value);
            // A write within the file time's resolution would otherwise keep the old declarations.
            _declared = null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Console.Add(LogLevel.Error, $"project: cannot write {ProjectPath}: {e.Message}");
            return false;
        }
        OnSublevelsChanged();
        return true;
    }

    /// <summary>
    /// Puts the selected entities of the open scenes in a sublevel, or with "" in the base, with their descendants: one
    /// undo entry in each scene that changes. A child goes with its root, so a child whose root is not selected stays,
    /// and the console says why.
    /// </summary>
    public bool AssignSublevel(string sublevel)
    {
        if (!IsEditing)
        {
            Console.Add(LogLevel.Warning, "sublevels: cannot assign a sublevel while the game plays. Stop it to edit the scene.");
            return false;
        }
        var changed = false;
        var nodes = Selection.Entities.Select(World.Find).OfType<EntityNode>().Where(n => n.SceneId != 0);
        foreach (var group in nodes.GroupBy(n => n.Scene))
        {
            if (SceneByNumber(group.Key) is not { } document)
            {
                continue;
            }
            var flat = document.Expanded.Flat;
            var selected = group.Select(n => flat.Find(n.SceneId)).OfType<SceneEntity>().ToList();
            var ids = selected.Select(e => e.Id).ToHashSet();
            var roots = new List<SceneEntity>();
            foreach (var entity in selected)
            {
                if (entity.Parent == 0)
                {
                    roots.Add(entity);
                }
                else if (!HasSelectedAncestor(flat, entity, ids))
                {
                    var parent = flat.Find(entity.Parent) is { } p ? Label(p) : $"{entity.Parent:x16}";
                    Console.Add(LogLevel.Warning, $"sublevels: {Label(entity)} stays in its parent's sublevel: a child is in its parent's, so put {parent}'s root in a sublevel instead");
                }
            }
            var ops = roots.Where(e => flat.SublevelOf(e) != sublevel).Select(e => (Operation)new SetSublevel(e.Id, sublevel == "" ? null : sublevel)).ToArray();
            if (ops.Length == 0)
            {
                continue;
            }
            var what = ops.Length == 1 ? Label(flat.Find(ops[0].Entity)!) : $"{ops.Length} Entities";
            changed |= Edit(document, sublevel == "" ? $"Move {what} to the Base" : $"Move {what} to {sublevel}", ops);
        }
        return changed;
    }

    static bool HasSelectedAncestor(Scene flat, SceneEntity entity, HashSet<ulong> ids)
    {
        var parent = entity.Parent;
        for (var depth = 0; parent != 0 && depth < 64; depth++)
        {
            if (ids.Contains(parent))
            {
                return true;
            }
            parent = flat.Find(parent)?.Parent ?? 0;
        }
        return false;
    }

    void OnSublevelsChanged()
    {
        SyncSublevelCommands();
        SublevelsChanged?.Invoke();
    }

    /// <summary>The ID of the command that puts the selection in a sublevel, or with "" in the base.</summary>
    public static string AssignSublevelCommand(string sublevel) => $"sublevel.assign.{(sublevel == "" ? "base" : sublevel)}";

    /// <summary>The ID of the command that loads or unloads a sublevel in Edit.</summary>
    public static string LoadSublevelCommand(string sublevel) => $"sublevel.load.{sublevel}";

    // The commands of the sublevels that the project declares, which follow its declarations as the game's commands
    // follow the game. A sublevel named base has no Move command of its own, since the base's has its ID: the panel and
    // the outliner's menu still move entities there.
    readonly List<string> _sublevelCommands = [];

    void SyncSublevelCommands()
    {
        var names = DeclaredSublevels.Select(s => s.Name).ToList();
        var ids = names.SelectMany(n => new[] { AssignSublevelCommand(n), LoadSublevelCommand(n) }).Prepend(AssignSublevelCommand("")).ToList();
        if (ids.SequenceEqual(_sublevelCommands))
        {
            return;
        }
        foreach (var id in _sublevelCommands)
        {
            Commands.Unregister(id);
        }
        _sublevelCommands.Clear();
        void Add(Command command)
        {
            if (Commands.Find(command.Id) == null)
            {
                Commands.Register(command);
                _sublevelCommands.Add(command.Id);
            }
        }
        bool CanAssign() => IsEditing && Selection.Entities.Count > 0;
        Add(new Command(AssignSublevelCommand(""), "Move to the Base", () => AssignSublevel(""))
        {
            Description = "Put the selected roots in the scene's base, which every sublevel's parts go with.",
            CanExecuteWhen = CanAssign,
        });
        foreach (var name in names)
        {
            Add(new Command(AssignSublevelCommand(name), $"Move to {name}", () => AssignSublevel(name))
            {
                Description = $"Put the selected roots in the {name} sublevel, with their descendants.",
                CanExecuteWhen = CanAssign,
            });
            Add(Command.Toggle(LoadSublevelCommand(name), $"Load {name} in Edit", () => IsSublevelChosen(name), on => SetSublevelLoaded(name, on),
                $"Whether Edit loads the {name} sublevel's parts of the open scenes."));
        }
    }

    static string ProjectKey(string path) => Path.GetFullPath(path).ToLowerInvariant();

    Dictionary<string, List<string>> ReadSublevelChoices()
    {
        try
        {
            return Settings.Read(SublevelsFileName) is { } text ? JsonSerializer.Deserialize<Dictionary<string, List<string>>>(text) ?? [] : [];
        }
        catch (JsonException e)
        {
            Console.Add(LogLevel.Warning, $"sublevels: {Path.Combine(Settings.Directory, SublevelsFileName)}: {e.Message}");
            return [];
        }
    }

    // The sublevels that the user last left unloaded in this project. Every other sublevel loads.
    void LoadSublevelChoice()
    {
        _unloadedSublevels.Clear();
        if (ReadSublevelChoices().GetValueOrDefault(ProjectKey(ProjectPath)) is { } unloaded)
        {
            _unloadedSublevels.UnionWith(unloaded.Where(SceneFile.IsSublevelName));
        }
    }

    void SaveSublevelChoice()
    {
        var choices = ReadSublevelChoices();
        var key = ProjectKey(ProjectPath);
        if (_unloadedSublevels.Count == 0)
        {
            choices.Remove(key);
        }
        else
        {
            choices[key] = [.. _unloadedSublevels.Order(StringComparer.Ordinal)];
        }
        WriteSetting("sublevels", SublevelsFileName, JsonSerializer.Serialize(choices, new JsonSerializerOptions { WriteIndented = true }));
    }
}
