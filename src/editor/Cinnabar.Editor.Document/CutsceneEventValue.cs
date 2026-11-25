using System.Globalization;

namespace Cinnabar.Editor.Document;

/// <summary>The kinds of an event's values, as a <c>value = &lt;kind&gt; &lt;value&gt;</c> line names them.</summary>
public enum CutsceneValueKind
{
    Number,
    Bool,
    String,
    Vector,
    Entity,
    Position,
    Asset,
}

/// <summary>
/// A value of a trigger or a range (see docs/content/kinds/cutscenes.md#triggers-and-ranges): its kind and its text,
/// which is a string's text unquoted, an asset's GUID without its <c>$</c>, a binding's ID, or a number or a vector as
/// the file writes it.
/// </summary>
public readonly record struct CutsceneEventValue(CutsceneValueKind Kind, string Text)
{
    /// <summary>The most values that a trigger or a range has.</summary>
    public const int Max = 4;

    public static readonly CutsceneValueKind[] Kinds = Enum.GetValues<CutsceneValueKind>();

    /// <summary>The word that a value line names a kind by, such as <c>entity</c>.</summary>
    public static string Word(CutsceneValueKind kind) => kind.ToString().ToLowerInvariant();

    /// <summary>A value line's text after <c>value =</c>, or null when its kind is not one.</summary>
    public static CutsceneEventValue? Parse(string line)
    {
        var parts = line.Trim().Split((char[]?)null, 2, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0 || Kinds.Where(k => Word(k) == parts[0]).Cast<CutsceneValueKind?>().FirstOrDefault() is not { } kind)
        {
            return null;
        }
        var text = parts.Length > 1 ? parts[1].Trim() : "";
        return kind switch
        {
            CutsceneValueKind.String => new(kind, TextQuote.Unquote(text) ?? text),
            CutsceneValueKind.Asset => new(kind, text.TrimStart('$')),
            _ => new(kind, text),
        };
    }

    /// <summary>The value's line after <c>value =</c>.</summary>
    public string Format() => Kind switch
    {
        CutsceneValueKind.String => $"string {TextQuote.Quote(Text)}",
        CutsceneValueKind.Asset => $"asset ${Text}",
        _ => $"{Word(Kind)} {Text}",
    };

    /// <summary>A new value of a kind: zero, false, an empty string, the origin, or the first binding, or no asset.</summary>
    public static CutsceneEventValue Default(CutsceneValueKind kind, int? binding = null) => kind switch
    {
        CutsceneValueKind.Number => new(kind, "0"),
        CutsceneValueKind.Bool => new(kind, "false"),
        CutsceneValueKind.String => new(kind, ""),
        CutsceneValueKind.Vector or CutsceneValueKind.Position => new(kind, "[0, 0, 0]"),
        CutsceneValueKind.Entity => new(kind, (binding ?? 1).ToString(CultureInfo.InvariantCulture)),
        _ => new(kind, ""),
    };

    /// <summary>
    /// What is wrong with a value's text for its kind, as the cooker would say, or null when nothing is: a number, true
    /// or false, three numbers in brackets, a binding's ID, or a GUID of 32 hex digits.
    /// </summary>
    public static string? Problem(CutsceneValueKind kind, string text)
    {
        text = text.Trim();
        static bool Number(string s) => double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var n) && double.IsFinite(n);
        return kind switch
        {
            CutsceneValueKind.Number when !Number(text) => "a number",
            CutsceneValueKind.Bool when text is not ("true" or "false") => "true or false",
            CutsceneValueKind.Vector or CutsceneValueKind.Position
                when !(text.StartsWith('[') && text.EndsWith(']') && text[1..^1].Split(',') is { Length: 3 } xyz && xyz.All(v => Number(v.Trim())))
                => "three numbers, such as [0, 1, 0]",
            CutsceneValueKind.Entity when !CutsceneFile.TryParseId(text, out _) => "a binding's ID",
            CutsceneValueKind.Asset when !AssetGuid.TryParse(text, out _) => "an asset's GUID",
            _ => null,
        };
    }
}
