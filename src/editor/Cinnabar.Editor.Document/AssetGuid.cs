namespace Cinnabar.Editor.Document;

/// <summary>
/// An asset's GUID as the text formats write it: 32 hex digits, which <see cref="Text"/> holds in lower case. It reads
/// as the engine's <c>format.guid_parse</c> and <c>format.guid_ref</c> do, and
/// <c>lib/engine/asset/format/testdata/lexemes.json</c> pins the two together. A format that takes <c>$0</c> for no
/// asset, or that refuses a GUID of zeros, checks for it itself.
/// </summary>
public readonly record struct AssetGuid
{
    readonly string? _text;

    AssetGuid(string text) => _text = text;

    /// <summary>The 32 hex digits in lower case, or "" for the default value.</summary>
    public string Text => _text ?? "";

    /// <summary>Whether every digit is 0, which no asset has. The default value is zero too.</summary>
    public bool IsZero => Text.All(c => c == '0');

    /// <summary>Reads 32 hex digits, in either case.</summary>
    public static bool TryParse(ReadOnlySpan<char> text, out AssetGuid guid)
    {
        guid = default;
        if (text.Length != 32)
        {
            return false;
        }
        foreach (var c in text)
        {
            if (!char.IsAsciiHexDigit(c))
            {
                return false;
            }
        }
        guid = new AssetGuid(text.ToString().ToLowerInvariant());
        return true;
    }

    /// <summary>Reads <c>$</c> and 32 hex digits, as an asset reference in a text format.</summary>
    public static bool TryParseRef(ReadOnlySpan<char> text, out AssetGuid guid)
    {
        guid = default;
        return text.Length == 33 && text[0] == '$' && TryParse(text[1..], out guid);
    }

    public override string ToString() => Text;
}
