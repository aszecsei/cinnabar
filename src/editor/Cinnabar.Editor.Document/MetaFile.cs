using System.Text;

namespace Cinnabar.Editor.Document;

/// <summary>A sub-asset's line in a <c>.meta</c> file: its kind's name, such as <c>mesh</c>, its name and its GUID.</summary>
public sealed record MetaSubasset(string Kind, string Name, string Guid)
{
    /// <summary>The line's key, <c>kind.name</c>, as the index names the sub-asset.</summary>
    public string Key => $"{Kind}.{Name}";
}

/// <summary>
/// A <c>.meta</c> file (see docs/content/identity-and-cooking.md#identity), with the rules of the engine's
/// <c>meta_text</c> and <c>meta_parse</c> in <c>lib/engine/asset/format/format.odin</c>: <c>key = value</c> lines with
/// <c>#</c> comments, a <c>guid</c>, a sub-asset's GUID under <c>kind.name</c>, and the other keys as import settings.
/// A <c>[section]</c> line starts a group of settings, and a setting in it has the key <c>section.key</c>. The daemon
/// owns every <c>.meta</c> file, but for a new file's that the editor writes (see
/// docs/content/daemon-and-operations.md#asset-operations), which <see cref="New"/> builds.
/// </summary>
public sealed class MetaFile
{
    /// <summary>The extension that a source's <c>.meta</c> file adds to its path.</summary>
    public const string Extension = ".meta";

    /// <summary>The comment that a new <c>.meta</c> file starts with: the engine's <c>META_HEADER</c>, which a test holds to it.</summary>
    public const string Header = "# cinnabar asset metadata. Keep this file next to its asset (see docs/content/identity-and-cooking.md#identity).";

    MetaFile(string guid, IReadOnlyList<KeyValuePair<string, string>> settings, IReadOnlyList<MetaSubasset> subassets)
    {
        Guid = guid;
        Settings = settings;
        Subassets = subassets;
    }

    /// <summary>The asset's GUID, 32 lowercase hex digits.</summary>
    public string Guid { get; }

    /// <summary>The import settings in the file's order, each in a section under <c>section.key</c>.</summary>
    public IReadOnlyList<KeyValuePair<string, string>> Settings { get; }

    /// <summary>The sub-assets that the file names, in its order.</summary>
    public IReadOnlyList<MetaSubasset> Subassets { get; }

    /// <summary>A setting's value, such as <c>usage</c> or <c>mip_map.kernel</c>, or null. The first line with the key wins, as in the engine.</summary>
    public string? Setting(string key) => Settings.FirstOrDefault(s => s.Key == key) is { Key: not null } s ? s.Value : null;

    /// <summary>The GUID of a sub-asset by its key, such as <c>sublevel.night</c>, or null.</summary>
    public string? SubassetGuid(string key) => Subassets.FirstOrDefault(s => s.Key == key)?.Guid;

    /// <summary>A builder of a new <c>.meta</c> file with a GUID, 32 hex digits.</summary>
    public static Builder New(string guid) =>
        ParseGuid(guid) is { } parsed ? new Builder(parsed) : throw new ArgumentException($"'{guid}' is not a GUID of 32 hex digits.", nameof(guid));

    /// <summary>
    /// The file's text as <c>meta_text</c> writes it for a file without old text: the header, the GUID, the settings
    /// outside every section, the sub-assets, and then each section, in the order that the settings first name it.
    /// </summary>
    public string Text()
    {
        var text = new StringBuilder();
        text.Append(Header).Append('\n');
        text.Append("guid = ").Append(Guid).Append('\n');
        var sections = new List<string>();
        foreach (var (key, value) in Settings)
        {
            var (section, name) = SplitSection(key);
            if (section == "")
            {
                text.Append(name).Append(" = ").Append(value).Append('\n');
            }
            else if (!sections.Contains(section))
            {
                sections.Add(section);
            }
        }
        foreach (var subasset in Subassets)
        {
            text.Append(subasset.Key).Append(" = ").Append(subasset.Guid).Append('\n');
        }
        foreach (var section in sections)
        {
            text.Append("\n[").Append(section).Append("]\n");
            foreach (var (key, value) in Settings)
            {
                if (SplitSection(key) is var (inSection, name) && inSection == section)
                {
                    text.Append(name).Append(" = ").Append(value).Append('\n');
                }
            }
        }
        return text.ToString();
    }

    /// <summary>
    /// Parses a <c>.meta</c> file's text as <c>meta_parse</c> does, or null. It fails on a malformed line, a sub-asset
    /// without a GUID, a missing guid, a section whose name is not an identifier, or a key in a section that is not
    /// one, such as a <c>guid</c> there.
    /// </summary>
    public static MetaFile? Parse(string text)
    {
        string? guid = null;
        var settings = new List<KeyValuePair<string, string>>();
        var subassets = new List<MetaSubasset>();
        var section = "";
        foreach (var line in text.Split('\n'))
        {
            var trimmed = line.Trim();
            if (trimmed == "" || trimmed[0] == '#')
            {
                continue;
            }
            if (trimmed[0] == '[')
            {
                if (!trimmed.EndsWith(']'))
                {
                    return null;
                }
                section = trimmed[1..^1].Trim();
                if (!IsIdentifier(section))
                {
                    return null;
                }
                continue;
            }
            var equals = trimmed.IndexOf('=');
            if (equals < 0)
            {
                return null;
            }
            var key = trimmed[..equals].Trim();
            var value = trimmed[(equals + 1)..].Trim();
            if (section != "")
            {
                if (!IsIdentifier(key))
                {
                    return null;
                }
                settings.Add(new($"{section}.{key}", value));
            }
            else if (key == "guid")
            {
                if ((guid = ParseGuid(value)) == null)
                {
                    return null;
                }
            }
            else if (key.IndexOf('.') is var dot and > 0)
            {
                if (ParseGuid(value) is not { } subasset)
                {
                    return null;
                }
                subassets.Add(new(key[..dot], key[(dot + 1)..], subasset));
            }
            else
            {
                settings.Add(new(key, value));
            }
        }
        return guid == null ? null : new MetaFile(guid, settings, subassets);
    }

    /// <summary>Reads and parses a <c>.meta</c> file, or null when it cannot be read or does not parse.</summary>
    public static MetaFile? TryRead(string metaPath)
    {
        try
        {
            return Parse(File.ReadAllText(metaPath));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>
    /// Builds a new <c>.meta</c> file: a GUID and settings, each in a section when its key has a dot, as
    /// <c>mip_map.kernel</c> is <c>kernel</c> in <c>[mip_map]</c>.
    /// </summary>
    public sealed class Builder
    {
        readonly string _guid;
        readonly List<KeyValuePair<string, string>> _settings = [];

        internal Builder(string guid) => _guid = guid;

        /// <summary>Adds a setting. A key, and its section's name, are letters, digits and underscores, and not <c>guid</c>, so the file parses.</summary>
        public Builder Set(string key, string value)
        {
            var (section, name) = SplitSection(key);
            if ((section != "" && !IsIdentifier(section)) || !IsIdentifier(name))
            {
                throw new ArgumentException($"'{key}' is not a setting's key.", nameof(key));
            }
            _settings.Add(new(key, value));
            return this;
        }

        /// <summary>The file that the builder has.</summary>
        public MetaFile Build() => new(_guid, [.. _settings], []);

        /// <summary>The file's text (see <see cref="MetaFile.Text"/>).</summary>
        public string Text() => Build().Text();
    }

    static (string Section, string Name) SplitSection(string key) =>
        key.IndexOf('.') is var dot and >= 0 ? (key[..dot], key[(dot + 1)..]) : ("", key);

    // A section's name, or a key in a section, is ASCII letters, digits and underscores, and not guid, as meta_identifier has it.
    static bool IsIdentifier(string name) =>
        name != "" && name != "guid" && name.All(c => c == '_' || char.IsAsciiLetterOrDigit(c));

    // 32 hex digits, as guid_parse reads them, in lowercase.
    static string? ParseGuid(string text) =>
        text.Length == 32 && text.All(char.IsAsciiHexDigit) ? text.ToLowerInvariant() : null;
}
