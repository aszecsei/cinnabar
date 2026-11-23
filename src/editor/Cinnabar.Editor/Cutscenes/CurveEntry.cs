using System.Globalization;

namespace Cinnabar.Editor.Cutscenes;

/// <summary>What a typed entry in the curve editor's time or value box does with its number.</summary>
public enum CurveEntryOp
{
    /// <summary><c>x</c> or <c>=x</c>: each selected key takes x.</summary>
    Set,
    /// <summary><c>+=x</c>: each selected key moves up or later by x.</summary>
    Add,
    /// <summary><c>-=x</c>: each selected key moves down or earlier by x.</summary>
    Subtract,
}

/// <summary>
/// A typed entry in the curve editor's time or value box (see docs/editor/cutscene-editor.md#typed-times-and-values): a
/// number to set, or <c>+=</c> or <c>-=</c> and a number to offset by. The box reads the number: a time as timecode or
/// frames, a value as a finite number.
/// </summary>
public readonly record struct CurveEntry(CurveEntryOp Op, double Operand)
{
    /// <summary>Reads an entry whose number <paramref name="number"/> reads, or null when it does not.</summary>
    public static CurveEntry? Parse(string text, Func<string, double?> number)
    {
        text = text.Trim();
        var (op, rest) = text.StartsWith("+=", StringComparison.Ordinal) ? (CurveEntryOp.Add, text[2..])
            : text.StartsWith("-=", StringComparison.Ordinal) ? (CurveEntryOp.Subtract, text[2..])
            : text.StartsWith('=') ? (CurveEntryOp.Set, text[1..])
            : (CurveEntryOp.Set, text);
        return number(rest.Trim()) is { } x && double.IsFinite(x) ? new CurveEntry(op, x) : null;
    }

    /// <summary>Reads a value entry: the number is any finite number, written as the files write numbers.</summary>
    public static CurveEntry? ParseValue(string text) =>
        Parse(text, s => double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : null);

    /// <summary>Reads a time entry at a display rate: the number is timecode or frames, in ticks.</summary>
    public static CurveEntry? ParseTime(string text, int rate) =>
        Parse(text, s => CutsceneTime.TryParse(s, rate, out var ticks) ? ticks : null);

    /// <summary>What the entry makes of a key's number.</summary>
    public double Apply(double current) => Op switch
    {
        CurveEntryOp.Add => current + Operand,
        CurveEntryOp.Subtract => current - Operand,
        _ => Operand,
    };
}
