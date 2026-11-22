using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// An open cutscene in its editor (see docs/editor/cutscene-editor.md#the-tab): its document, the block that is
/// selected, and the problems of the last check of its text on their blocks. The view turns input into calls here, so
/// tests can drive the editor without a window. Blocks are named by path, since an undo reads the file again and
/// replaces its block objects.
/// </summary>
public sealed class CutsceneEditor : IGraphEditor
{
    readonly EditorShell _shell;
    readonly List<GraphProblem> _problems = [];
    readonly PreviewCook _cook;

    internal CutsceneEditor(EditorShell shell, CutsceneDocument document)
    {
        _shell = shell;
        Document = document;
        _cook = new PreviewCook(() => _shell.PreviewCooker.Linked, () => Document.Text, text => _shell.PreviewCooker.CookPreview(Guid, text), ShowProblems);
        Document.Changed += OnDocumentChanged;
    }

    public CutsceneDocument Document { get; }

    IGraphDocument IGraphEditor.Document => Document;

    public string Noun => "cutscene";

    public string Guid => Document.Guid;

    public CutsceneFile File => Document.Graph;

    /// <summary>The path of the selected block (see <see cref="CutsceneFile.PathOf"/>), or null for none.</summary>
    public string? Selection { get; private set; }

    /// <summary>The selected block, or null for none.</summary>
    public CutsceneBlock? Selected => Selection is { } path ? File.Find(path) : null;

    /// <summary>The problems of the last check, each with its line, or 0 for one of no line of this file.</summary>
    public IReadOnlyList<GraphProblem> Problems => _problems;

    /// <summary>The cutscene, its document's state or the selection changed.</summary>
    public event Action? Changed;

    public event Action? ProblemsChanged;

    void OnDocumentChanged()
    {
        // An undo or an edit can take the selected block away.
        if (Selection is { } path && File.Find(path) == null)
        {
            Selection = null;
        }
        Changed?.Invoke();
        _shell.Commands.InvalidateAll();
        if (!Document.InTransaction)
        {
            _cook.Schedule();
        }
    }

    /// <summary>Selects a block, or with null, none.</summary>
    public void Select(CutsceneBlock? block)
    {
        var path = block == null ? null : CutsceneFile.PathOf(block);
        if (path == Selection)
        {
            return;
        }
        Selection = path;
        Changed?.Invoke();
    }

    /// <summary>The problems on a block's own lines.</summary>
    public IEnumerable<GraphProblem> ProblemsOf(CutsceneBlock block) => _problems.Where(p => p.Line > 0 && File.BlockAt(p.Line) == block);

    /// <summary>The block whose own lines hold a line, from 1, or null.</summary>
    public CutsceneBlock? BlockAt(int line) => File.BlockAt(line);

    /// <summary>An edit of the selected block in one undo entry. Nothing without a selection.</summary>
    public void EditSelected(string label, Action<CutsceneBlock> edit)
    {
        if (Selection is not { } path)
        {
            return;
        }
        Document.Edit(label, f =>
        {
            if (f.Find(path) is { } block)
            {
                edit(block);
            }
        });
    }

    /// <summary>
    /// Starts a drag of a field of the selected block, such as a scrub of a section's end: one undo entry from here to
    /// <see cref="EndField"/>, whose steps preview as they go. False when a drag is under way or nothing is selected.
    /// </summary>
    public bool BeginField(string label)
    {
        if (Document.InTransaction || Selection == null)
        {
            return false;
        }
        Document.Begin(label);
        return true;
    }

    /// <summary>A step of the drag. Nothing when none is under way.</summary>
    public void StepField(Action<CutsceneBlock> edit)
    {
        if (!Document.InTransaction || Selection is not { } path)
        {
            return;
        }
        Document.Step(f =>
        {
            if (f.Find(path) is { } block)
            {
                edit(block);
            }
        });
    }

    /// <summary>Ends the drag: commits its one undo entry, or with cancel, as with Esc, puts the text back as it was.</summary>
    public void EndField(bool cancel)
    {
        if (!Document.InTransaction)
        {
            return;
        }
        if (cancel)
        {
            Document.Cancel();
        }
        else
        {
            Document.Commit();
        }
    }

    /// <summary>Sends the unsaved text to the cook daemon now, and shows the answer's problems.</summary>
    public Task CookNow() => _cook.CookNow();

    /// <summary>Shows the answer to a check of a text, unless the cutscene has changed since it was sent.</summary>
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
        CookError = result.Error == "" ? null : result.Error;
        ProblemsChanged?.Invoke();
    }

    /// <summary>The last check's error, or null when the text cooked.</summary>
    public string? CookError { get; private set; }

    public void Dispose()
    {
        _cook.Dispose();
        Document.Changed -= OnDocumentChanged;
    }
}
