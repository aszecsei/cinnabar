using System.Text;

namespace Cinnabar.Editor.Document;

/// <summary>The one strict UTF-8 decoder of the editor's text files.</summary>
public static class Utf8Text
{
    static readonly UTF8Encoding Strict = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    /// <summary>A file's bytes as text, or null when they are not UTF-8. A byte order mark is kept, as the cooker does.</summary>
    public static string? Decode(byte[] bytes)
    {
        try
        {
            return Strict.GetString(bytes);
        }
        catch (DecoderFallbackException)
        {
            return null;
        }
    }
}
