namespace Cinnabar.Editor.Document;

/// <summary>FNV-1a hashes of bytes, in the two widths the editor uses.</summary>
public static class Fnv
{
    /// <summary>The 32-bit hash.</summary>
    public static uint Hash32(ReadOnlySpan<byte> bytes)
    {
        var hash = 2166136261u;
        foreach (var b in bytes)
        {
            hash = (hash ^ b) * 16777619u;
        }
        return hash;
    }

    /// <summary>The 64-bit hash.</summary>
    public static ulong Hash64(ReadOnlySpan<byte> bytes)
    {
        var hash = 0xcbf29ce484222325UL;
        foreach (var b in bytes)
        {
            hash = (hash ^ b) * 0x100000001b3UL;
        }
        return hash;
    }
}
