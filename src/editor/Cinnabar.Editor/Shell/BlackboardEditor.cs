using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// An open blackboard in its editor (see docs/editor/decision-editor.md#blackboards): a table of its keys, each a name, a
/// type and a default, with the problems of the last check of its text on their rows. Renaming a key renames it in the
/// decisions that read it too. The view turns input into calls here, so tests can drive the editor without a window.
/// </summary>
public sealed class BlackboardEditor : IGraphEditor
{
    readonly EditorShell _shell;
    readonly List<GraphProblem> _problems = [];
    readonly PreviewCook _cook;

    internal BlackboardEditor(EditorShell shell, BlackboardDocument document)
    {
        _shell = shell;
        Document = document;
        _cook = new PreviewCook(() => _shell.PreviewCooker.Linked, () => Document.Text, text => _shell.PreviewCooker.CookPreview(Guid, text), ShowProblems);
        Document.Changed += OnDocumentChanged;
    }

    public BlackboardDocument Document { get; }

    IGraphDocument IGraphEditor.Document => Document;

    public string Noun => "blackboard";

    public string Guid => Document.Guid;

    BlackboardFile File => Document.Graph;

    /// <summary>The keys in their slots' order.</summary>
    public IReadOnlyList<BlackboardKey> Keys => [.. File.Keys];

    /// <summary>The problems of the last check, each with its key's line, or 0 for one of no line.</summary>
    public IReadOnlyList<GraphProblem> Problems => _problems;

    /// <summary>The blackboard or its document's state changed.</summary>
    public event Action? Changed;

    public event Action? ProblemsChanged;

    void OnDocumentChanged()
    {
        Changed?.Invoke();
        _shell.Commands.InvalidateAll();
        _shell.OnBlackboardChanged(Guid);
        if (!Document.InTransaction)
        {
            _cook.Schedule();
        }
    }

    /// <summary>The problems on a key's line.</summary>
    public IEnumerable<GraphProblem> ProblemsOf(BlackboardKey key)
    {
        var line = File.LineOf(key);
        return _problems.Where(p => p.Line == line);
    }

    /// <summary>The key with a name, or null.</summary>
    public BlackboardKey? Find(string name) => File.Find(name);

    /// <summary>Adds a key of a type with a name that no key has, and returns its name.</summary>
    public string AddKey(string type)
    {
        var names = File.Keys.Select(k => k.Name).ToHashSet();
        var name = Enumerable.Range(1, int.MaxValue).Select(n => $"{type}{n}").First(n => !names.Contains(n));
        Document.Edit($"Add {name}", f => f.AddKey(type, name, type == "enum" ? ["a", "b"] : [], null));
        return name;
    }

    /// <summary>Changes a key's type, its enum's names and its default. Its name stays: <see cref="RenameKey"/> changes that.</summary>
    public void SetKey(string name, string type, IReadOnlyList<string> values, string? @default) =>
        Document.Edit($"Set {name}", f =>
        {
            if (f.Find(name) is { } key)
            {
                BlackboardFile.SetKey(key, type, name, values, @default);
            }
        });

    public void RemoveKey(string name) =>
        Document.Edit($"Remove {name}", f =>
        {
            if (f.Find(name) is { } key)
            {
                f.Remove(key);
            }
        });

    /// <summary>Moves a key one slot up (-1) or down (1).</summary>
    public void MoveKey(string name, int by) =>
        Document.Edit(by < 0 ? $"Move {name} Up" : $"Move {name} Down", f =>
        {
            if (f.Find(name) is { } key)
            {
                f.Move(key, by);
            }
        });

    /// <summary>Whether a key can take a name: a word that no other key has.</summary>
    public bool CanRename(string name, string newName) =>
        newName == name || (MaterialFile.IsIdentifier(newName) && File.Find(newName) == null);

    /// <summary>The decisions that read a key, which <see cref="RenameKey"/> changes too, so the view can ask first.</summary>
    public IReadOnlyList<Asset> DecisionsReading(string name) => _shell.DecisionsReading(Guid, name);

    /// <summary>
    /// Renames a key, in one entry here and one in each decision that reads it, which opens in its editor and stays
    /// unsaved. It returns false, and changes nothing, for a name that the key cannot have.
    /// </summary>
    public bool RenameKey(string name, string newName)
    {
        if (newName == name)
        {
            return true;
        }
        if (!CanRename(name, newName) || File.Find(name) is not { } key)
        {
            return false;
        }
        // The decisions are found while their text still names the key.
        var decisions = DecisionsReading(name);
        Document.Edit($"Rename {name} to {newName}", f => BlackboardFile.SetKey(f.Find(name)!, key.Type, newName, key.Values, key.Default));
        foreach (var asset in decisions)
        {
            if (_shell.OpenDecision(asset) is { } editor)
            {
                editor.RenameKey(name, newName);
            }
        }
        return true;
    }

    /// <summary>Sends the unsaved text to the cook daemon now, and shows the answer's problems.</summary>
    public Task CookNow() => _cook.CookNow();

    /// <summary>Shows the answer to a check of a text, unless the blackboard has changed since it was sent.</summary>
    public void ShowProblems(string text, PreviewResult result)
    {
        if (text != Document.Text)
        {
            return;
        }
        _problems.Clear();
        foreach (var p in result.Problems)
        {
            var mine = string.Equals(Path.GetFullPath(p.File == "" ? "." : p.File), Document.Path, StringComparison.OrdinalIgnoreCase);
            var where = mine || p.File == "" ? "" : $"{Path.GetFileName(p.File)}:{p.Line}: ";
            _problems.Add(new GraphProblem(null, where + p.Text, p.Error, mine ? (int)p.Line : 0));
        }
        ProblemsChanged?.Invoke();
    }

    public void Dispose()
    {
        _cook.Dispose();
        Document.Changed -= OnDocumentChanged;
    }
}
