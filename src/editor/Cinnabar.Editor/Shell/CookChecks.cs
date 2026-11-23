using Cinnabar.Editor.Link.Cook;

namespace Cinnabar.Editor.Shell;

/// <summary>The state of an open document's cook checks. It starts as <see cref="Pending"/>, so no answer never reads as a clean cook.</summary>
public abstract record CheckState
{
    CheckState()
    {
    }

    public static readonly CheckState Pending = new PendingState();

    /// <summary>No answer has come yet.</summary>
    public sealed record PendingState : CheckState;

    /// <summary>The text cooked.</summary>
    public sealed record Clean(string Text) : CheckState;

    /// <summary>The text did not cook: the answer's first error.</summary>
    public sealed record Failed(string Error) : CheckState;
}

/// <summary>
/// One problem of a cook answer, before an editor places it. A problem in another file has that file's name and line in
/// its text, and line and column 0.
/// </summary>
public sealed record CookLine(string Text, bool Error, int Line, int Column);

/// <summary>What the shell asks of an editor's cook checks, whatever its problems are.</summary>
public interface ICookChecks : IDisposable
{
    CheckState State { get; }

    /// <inheritdoc cref="CookChecks{TProblem}.CookNow"/>
    Task CookNow();

    /// <inheritdoc cref="CookChecks{TProblem}.Restart"/>
    Task Restart();
}

/// <summary>
/// The cook checks of an open document (see docs/editor/material-editor.md#material-editor): a <see cref="PreviewCook"/>
/// of its unsaved text, and the last answer as a <see cref="CheckState"/> and the editor's problems. An answer about a
/// text that has changed since it was sent is dropped, as another check will come.
/// </summary>
public sealed class CookChecks<TProblem> : ICookChecks
{
    readonly Func<bool> _ready;
    readonly Func<string> _text;
    readonly Func<string> _path;
    readonly Func<CookLine, TProblem> _map;
    readonly PreviewCook _cook;
    readonly List<TProblem> _problems = [];

    /// <param name="map">Places a problem in the editor's document: on a node, a style, or nothing.</param>
    /// <param name="ready">Whether a cook can go now; by default, whether the cook daemon is linked.</param>
    /// <param name="cook">Sends a text to the daemon; by default, a preview cook of the asset.</param>
    public CookChecks(EditorShell shell, string guid, Func<string> text, Func<string> path, Func<CookLine, TProblem> map,
        Func<bool>? ready = null, Func<string, Task<PreviewResult>>? cook = null)
    {
        _ready = ready ?? (() => shell.PreviewCooker.Linked);
        _text = text;
        _path = path;
        _map = map;
        _cook = new PreviewCook(_ready, text, cook ?? (t => shell.PreviewCooker.CookPreview(guid, t)), Answered);
    }

    public CheckState State { get; private set; } = CheckState.Pending;

    /// <summary>
    /// Whether a text has cooked clean since the daemon started, so the daemon has put the unsaved text in the cache's
    /// preview area. It stays set when a later text fails, as the area keeps the last clean one; <see cref="Restart"/>
    /// clears it.
    /// </summary>
    public bool CookedClean { get; private set; }

    public IReadOnlyList<TProblem> Problems => _problems;

    /// <summary>
    /// <see cref="CookedClean"/> changed: the first clean answer came, stale or not, after <see cref="Changed"/> of the same
    /// answer, or a restart cleared it.
    /// </summary>
    public event Action? CookedCleanChanged;

    /// <summary>An answer about the current text changed <see cref="State"/> and <see cref="Problems"/>.</summary>
    public event Action? Changed;

    /// <summary>Cooks a moment after the last call.</summary>
    public void Schedule() => _cook.Schedule();

    /// <summary>Sends the unsaved text to the cook daemon now, and shows the answer's problems.</summary>
    public Task CookNow() => _cook.CookNow();

    /// <summary>
    /// A new cook link: the daemon that answered before is gone, and the new one starts with an empty preview area. The
    /// checks start again as pending, and cook now.
    /// </summary>
    public Task Restart()
    {
        _problems.Clear();
        State = CheckState.Pending;
        Changed?.Invoke();
        if (CookedClean)
        {
            CookedClean = false;
            CookedCleanChanged?.Invoke();
        }
        return CookNow();
    }

    // An answer that comes once the link is gone is the cook link's failure, not the text's: the restart that a new link
    // brings checks the text again.
    void Answered(string text, PreviewResult result)
    {
        if (_ready())
        {
            Show(text, result);
        }
    }

    /// <summary>
    /// Shows the answer to a check of a text, unless the text has changed since it was sent. The first clean answer then
    /// sets <see cref="CookedClean"/>, stale or not.
    /// </summary>
    internal void Show(string text, PreviewResult result)
    {
        if (text == _text())
        {
            _problems.Clear();
            var path = _path();
            foreach (var p in result.Problems)
            {
                var mine = string.Equals(Path.GetFullPath(p.File == "" ? "." : p.File), path, StringComparison.OrdinalIgnoreCase);
                var where = mine || p.File == "" ? "" : $"{Path.GetFileName(p.File)}:{p.Line}: ";
                _problems.Add(_map(new CookLine(where + p.Text, p.Error, mine ? (int)p.Line : 0, mine ? (int)Math.Max(p.Column, 1) : 0)));
            }
            State = result.Error == "" ? new CheckState.Clean(text) : new CheckState.Failed(result.Error);
            Changed?.Invoke();
        }
        // The daemon wrote the blob of a clean text before it answered, even of a text that has changed since.
        if (result.Error == "" && !CookedClean)
        {
            CookedClean = true;
            CookedCleanChanged?.Invoke();
        }
    }

    public void Dispose() => _cook.Dispose();
}
