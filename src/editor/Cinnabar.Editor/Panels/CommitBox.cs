using System.Globalization;
using Avalonia.Controls;
using Avalonia.Input;
using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Panels;

/// <summary>What a box's commit made of a text: the document took it, or refused it, with the problem to show.</summary>
abstract record Verdict
{
    public static readonly Verdict Took = new TookText();

    /// <summary>A refusal. With no problem, the setter has said why itself, as a field editor does in the console.</summary>
    public static Verdict Refused(string? problem) => new RefusedText(problem);

    public sealed record TookText : Verdict;

    public sealed record RefusedText(string? Problem) : Verdict;
}

/// <summary>
/// The lifecycle that every box which edits a value shares: Enter, or Ctrl+Enter in a box of lines, and the loss of
/// the focus commit the text, Escape puts the value back, and a text commits once. A refused text puts the value back
/// and shows the problem as the box's tip. The box never commits again what it last committed or showed.
/// </summary>
/// <remarks>
/// <para>
/// The text to compare with is the box's state, not the value that it shows. The value is the document's or the
/// game's, formatted, such as 45° for a typed 45, so a box that committed on Enter and kept the focus differed from
/// it, and committed again when it lost the focus: a second undo entry for one edit. And a focused box does not
/// follow the value, so after a scrub of its field by the name, its old text differed too, and losing the focus put
/// the old value back.
/// </para>
/// <para>
/// A commit can build the box's panel again, which takes the box away and so makes it lose the focus inside the
/// commit. The state says that the text is committed before the commit runs, so that loss commits nothing.
/// </para>
/// </remarks>
sealed class CommitBox
{
    // Idle: the box has no focus, and compares with the value. Editing: it has the focus since the baseline, which is
    // what it had then or after its last commit or refusal; Committed says whether it committed since it took the focus.
    abstract record State
    {
        public sealed record Idle : State;

        public sealed record Editing(string Baseline, bool Committed) : State;
    }

    static readonly State IdleState = new State.Idle();

    readonly Control _box;
    readonly Func<string> _text;
    readonly Action<string> _show;
    readonly Func<string, Verdict> _commit;
    readonly Func<string> _value;
    State _state = IdleState;

    /// <param name="box">The control that has the focus and the keys, and shows a problem as its tip.</param>
    /// <param name="text">What the box has.</param>
    /// <param name="show">Puts a text in the box.</param>
    /// <param name="commit">Sets the value from a text.</param>
    /// <param name="value">The value as the box shows it, which a refusal, Escape and the loss of the focus put back.</param>
    /// <param name="multiline">Whether Enter starts a line, and Ctrl+Enter commits.</param>
    /// <param name="keys">Whether Enter and Escape are the box's, and not a list's that it has open.</param>
    CommitBox(Control box, Func<string> text, Action<string> show, Func<string, Verdict> commit, Func<string> value, bool multiline, Func<bool> keys)
    {
        _box = box;
        _text = text;
        _show = show;
        _commit = commit;
        _value = value;
        box.GotFocus += (_, _) =>
        {
            ClearProblem();
            _state = new State.Editing(_text(), Committed: false);
        };
        box.KeyDown += (_, e) =>
        {
            if (!keys())
            {
                return;
            }
            if (e.Key == Key.Enter && (!multiline || e.KeyModifiers == KeyModifiers.Control))
            {
                Commit();
                e.Handled = true;
            }
            else if (e.Key == Key.Escape)
            {
                ClearProblem();
                PutBack();
                e.Handled = true;
            }
        };
        box.LostFocus += (_, _) =>
        {
            Commit();
            // A box that committed nothing shows the value again, which may have changed under it. One that committed
            // keeps its text until the new value comes, which is the next thing that it shows.
            if (_state is not State.Editing { Committed: true })
            {
                _show(_value());
            }
            _state = IdleState;
        };
    }

    /// <summary>A text box. With <paramref name="multiline"/>, Enter starts a line and Ctrl+Enter commits.</summary>
    public static void Attach(TextBox box, Func<string, Verdict> commit, Func<string> value, bool multiline = false) =>
        _ = new CommitBox(box, () => box.Text ?? "", text => box.Text = text, commit, value, multiline, () => true);

    /// <summary>A box that completes its text: Enter and Escape are the list's while it is open.</summary>
    public static void Attach(AutoCompleteBox box, Func<string, Verdict> commit, Func<string> value) =>
        _ = new CommitBox(box, () => box.Text ?? "", text => box.Text = text, commit, value, multiline: false, () => !box.IsDropDownOpen);

    /// <summary>
    /// A box over a text that only it changes, as a panel's box over a document's text is: the value is the text that
    /// it started with, and then each text that the setter took.
    /// </summary>
    public static void Attach(TextBox box, Func<string, Verdict> commit, bool multiline = false)
    {
        var last = box.Text ?? "";
        Attach(box, Remember(commit, t => last = t), () => last, multiline);
    }

    /// <inheritdoc cref="Attach(TextBox, Func{string, Verdict}, bool)"/>
    public static void Attach(AutoCompleteBox box, Func<string, Verdict> commit)
    {
        var last = box.Text ?? "";
        Attach(box, Remember(commit, t => last = t), () => last);
    }

    // A commit that keeps the text as the value when the setter takes it.
    static Func<string, Verdict> Remember(Func<string, Verdict> commit, Action<string> keep) => text =>
    {
        var verdict = commit(text);
        if (verdict is Verdict.TookText)
        {
            keep(text);
        }
        return verdict;
    };

    void Commit()
    {
        var text = _text();
        var baseline = _state is State.Editing editing ? editing.Baseline : _value();
        if (text == baseline)
        {
            return;
        }
        ClearProblem();
        var before = _state;
        var committing = new State.Editing(text, Committed: true);
        _state = committing;
        if (_commit(text) is Verdict.RefusedText refused)
        {
            // A box that lost the focus inside the commit stays idle.
            if (ReferenceEquals(_state, committing))
            {
                _state = before;
            }
            PutBack();
            ShowProblem(refused.Problem);
        }
    }

    void PutBack()
    {
        _show(_value());
        if (_state is State.Editing editing)
        {
            _state = editing with { Baseline = _text() };
        }
    }

    void ShowProblem(string? problem)
    {
        if (problem == null)
        {
            return;
        }
        ToolTip.SetTip(_box, problem);
        // A tip opens only on a box in a window.
        if (TopLevel.GetTopLevel(_box) != null)
        {
            ToolTip.SetIsOpen(_box, true);
        }
    }

    // The box's own tip is only a problem's: a caller's tip is on the border around it, which shows again.
    void ClearProblem()
    {
        if (ToolTip.GetTip(_box) != null)
        {
            if (TopLevel.GetTopLevel(_box) != null)
            {
                ToolTip.SetIsOpen(_box, false);
            }
            ToolTip.SetTip(_box, null);
        }
    }
}

/// <summary>How a box reads and writes one kind of value: the text that shows a value, and the value of a typed text.</summary>
interface IValueFormat<T>
{
    string Format(T value);

    /// <summary>The value of a text, or the problem with it, which the box shows as its tip.</summary>
    bool TryParse(string text, out T value, out string problem);
}

/// <summary>The formats that the editor's boxes share. Each reads numbers in the invariant culture, as the files do.</summary>
static class ValueFormats
{
    /// <summary>Text as it is typed.</summary>
    public static readonly IValueFormat<string> Text = new TextFormat();

    /// <summary>A number from <paramref name="min"/> to <paramref name="max"/>, shown with <paramref name="pattern"/>, or as short as reads back the same.</summary>
    public static IValueFormat<double> Number(double min = double.NegativeInfinity, double max = double.PositiveInfinity, string pattern = "R") =>
        new NumberFormat(min, max, pattern);

    /// <summary>A whole number from <paramref name="min"/> to <paramref name="max"/>.</summary>
    public static IValueFormat<int> Integer(int min = int.MinValue, int max = int.MaxValue) => new IntegerFormat(min, max);

    /// <summary>
    /// A number, or numbers as a material's or an animation graph's values write them, such as 0.5 or [1, 0, 0]:
    /// <paramref name="count"/> of them, or one to four for 0.
    /// </summary>
    public static IValueFormat<GraphNumbers> Numbers(int count = 0) => new NumbersFormat(count);

    /// <summary>A time or an ID in ticks, as a cutscene writes it and the cooker reads it.</summary>
    public static readonly IValueFormat<int> Ticks = new TicksFormat();

    /// <summary>A number, or null for an empty box, which is the default.</summary>
    public static IValueFormat<double?> OptionalNumber(double min = double.NegativeInfinity, double max = double.PositiveInfinity) =>
        new OptionalNumberFormat(Number(min, max));

    /// <summary>A value that <paramref name="parse"/> reads, or null for <paramref name="problem"/>, and <paramref name="format"/> writes.</summary>
    public static IValueFormat<T> Of<T>(Func<string, T?> parse, Func<T, string> format, string problem) where T : class =>
        new DelegateFormat<T>(parse, format, problem);

    /// <summary>A value of <paramref name="format"/>, or null for an empty box, which is the default.</summary>
    public static IValueFormat<T?> Optional<T>(IValueFormat<T> format) where T : class => new OptionalFormat<T>(format);

    /// <summary>A value of <paramref name="format"/> that <paramref name="takes"/>, or <paramref name="problem"/>.</summary>
    public static IValueFormat<T> Where<T>(this IValueFormat<T> format, Func<T, bool> takes, string problem) => new CheckedFormat<T>(format, takes, problem);

    // What a number between two bounds is, where an infinite bound or the type's own is none.
    static string Range(string noun, string? min, string? max) => (min, max) switch
    {
        ({ } lo, { } hi) => $"{noun} from {lo} to {hi}",
        ({ } lo, null) => $"{noun} of at least {lo}",
        (null, { } hi) => $"{noun} of at most {hi}",
        _ => noun,
    };

    sealed class TextFormat : IValueFormat<string>
    {
        public string Format(string value) => value;

        public bool TryParse(string text, out string value, out string problem)
        {
            (value, problem) = (text, "");
            return true;
        }
    }

    sealed class NumberFormat(double min, double max, string pattern) : IValueFormat<double>
    {
        public string Format(double value) => value.ToString(pattern, CultureInfo.InvariantCulture);

        public bool TryParse(string text, out double value, out string problem)
        {
            problem = Range("a number", double.IsFinite(min) ? Format(min) : null, double.IsFinite(max) ? Format(max) : null);
            return double.TryParse(text.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out value)
                && double.IsFinite(value) && value >= min && value <= max;
        }
    }

    sealed class IntegerFormat(int min, int max) : IValueFormat<int>
    {
        public string Format(int value) => value.ToString(CultureInfo.InvariantCulture);

        public bool TryParse(string text, out int value, out string problem)
        {
            problem = Range("a whole number", min > int.MinValue ? Format(min) : null, max < int.MaxValue ? Format(max) : null);
            return int.TryParse(text.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out value) && value >= min && value <= max;
        }
    }

    sealed class NumbersFormat(int count) : IValueFormat<GraphNumbers>
    {
        public string Format(GraphNumbers value) => value.Write();

        public bool TryParse(string text, out GraphNumbers value, out string problem)
        {
            problem = count switch
            {
                0 => "a number, which fills every component, or up to four, such as [1, 0.5, 0]",
                1 => "a number, such as 0.5",
                _ => $"{count} numbers, such as [{string.Join(", ", Enumerable.Repeat("0", count))}]",
            };
            value = GraphNumbers.TryParse(text) is { } n && (count == 0 || n.Values.Count == count) ? n : null!;
            return value != null;
        }
    }

    sealed class TicksFormat : IValueFormat<int>
    {
        public string Format(int value) => value.ToString(CultureInfo.InvariantCulture);

        public bool TryParse(string text, out int value, out string problem)
        {
            problem = "a whole number of ticks, such as 1500";
            return CutsceneFile.TryParseTicks(text.Trim(), out value);
        }
    }

    sealed class OptionalFormat<T>(IValueFormat<T> format) : IValueFormat<T?> where T : class
    {
        public string Format(T? value) => value == null ? "" : format.Format(value);

        public bool TryParse(string text, out T? value, out string problem)
        {
            if (text.Trim() == "")
            {
                (value, problem) = (null, "");
                return true;
            }
            var parsed = format.TryParse(text, out var v, out problem);
            value = parsed ? v : null;
            return parsed;
        }
    }

    sealed class OptionalNumberFormat(IValueFormat<double> format) : IValueFormat<double?>
    {
        public string Format(double? value) => value is { } v ? format.Format(v) : "";

        public bool TryParse(string text, out double? value, out string problem)
        {
            if (text.Trim() == "")
            {
                (value, problem) = (null, "");
                return true;
            }
            var parsed = format.TryParse(text, out var v, out problem);
            value = parsed ? v : null;
            return parsed;
        }
    }

    sealed class DelegateFormat<T>(Func<string, T?> parse, Func<T, string> format, string check) : IValueFormat<T> where T : class
    {
        public string Format(T value) => format(value);

        public bool TryParse(string text, out T value, out string problem)
        {
            problem = check;
            value = parse(text)!;
            return value != null;
        }
    }

    sealed class CheckedFormat<T>(IValueFormat<T> format, Func<T, bool> takes, string check) : IValueFormat<T>
    {
        public string Format(T value) => format.Format(value);

        public bool TryParse(string text, out T value, out string problem)
        {
            if (!format.TryParse(text, out value, out problem))
            {
                return false;
            }
            problem = check;
            return takes(value);
        }
    }
}
