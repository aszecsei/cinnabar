using Cinnabar.Editor.Document;
using LogLevel = Cinnabar.Editor.Model.LogLevel;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The open cutscenes' documents, one for each GUID (see docs/editor/cutscene-editor.md#sub-sequences): a cutscene open
/// in its own tab and in context in another's is one document, so an edit in one shows in the other, and each document
/// keeps its own undo stack and dirty state. Each holder takes a <see cref="Lease"/>; the document closes when the last
/// lease goes. A cutscene that no tab holds is read from its file, by its time.
/// </summary>
public sealed class CutsceneDocuments(EditorShell shell)
{
    sealed class Entry(CutsceneDocument document)
    {
        public CutsceneDocument Document { get; } = document;

        public int Leases;
    }

    readonly Dictionary<string, Entry> _open = new(StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<string, (DateTime Modified, CutsceneFile? File)> _read = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>A hold on an open document. Its first dispose lets the document go; a second does nothing.</summary>
    public sealed class Lease : IDisposable
    {
        CutsceneDocuments? _owner;

        internal Lease(CutsceneDocuments owner, CutsceneDocument document)
        {
            _owner = owner;
            Document = document;
        }

        public CutsceneDocument Document { get; }

        /// <summary>Whether no other lease holds the document, so it closes with this one.</summary>
        public bool IsLast => _owner?._open.TryGetValue(Document.Guid, out var entry) == true && entry.Leases == 1;

        public void Dispose()
        {
            if (_owner is { } owner)
            {
                _owner = null;
                owner.Release(Document);
            }
        }
    }

    /// <summary>The open document of a GUID, or null when no lease holds one.</summary>
    public CutsceneDocument? Find(string guid) => _open.TryGetValue(guid, out var entry) ? entry.Document : null;

    /// <summary>A lease on a document that a tab opened, which the store keeps for other holders of its GUID.</summary>
    public Lease Adopt(CutsceneDocument document)
    {
        if (!_open.TryGetValue(document.Guid, out var entry))
        {
            entry = new Entry(document);
            _open[document.Guid] = entry;
        }
        else if (entry.Document != document)
        {
            throw new InvalidOperationException($"cutscene {document.Guid} is open in another document");
        }
        entry.Leases++;
        return new Lease(this, document);
    }

    /// <summary>
    /// A lease on a cutscene's document by its GUID: the open one, or one read from its file now. Null, with the reason
    /// in the console, when the index does not know the GUID or its file does not read.
    /// </summary>
    public Lease? Acquire(string guid)
    {
        if (Find(guid) is { } open)
        {
            return Adopt(open);
        }
        if (shell.Assets.Find(guid) is not { } asset || shell.Assets.FullPath(asset) is not { } path)
        {
            shell.Console.Add(LogLevel.Warning, $"cutscene: no cutscene has the GUID {guid}");
            return null;
        }
        var (document, problem) = CutsceneDocument.Open(path, guid);
        if (document == null)
        {
            shell.Console.Add(LogLevel.Warning, $"cutscene: cannot open {path}: {problem?.Message}");
            return null;
        }
        return Adopt(document);
    }

    void Release(CutsceneDocument document)
    {
        if (_open.TryGetValue(document.Guid, out var entry) && entry.Document == document && --entry.Leases == 0)
        {
            _open.Remove(document.Guid);
        }
    }

    /// <summary>
    /// A cutscene's text by its GUID: the open document's, saved or not, or else its file's, read again only when the
    /// file's time changes. Null when it cannot be read.
    /// </summary>
    public CutsceneFile? Read(string guid)
    {
        if (Find(guid) is { } open)
        {
            return open.Graph;
        }
        if (shell.Assets.Find(guid) is not { } asset || shell.Assets.FullPath(asset) is not { } path)
        {
            return null;
        }
        var modified = File.Exists(path) ? File.GetLastWriteTimeUtc(path) : default;
        if (_read.TryGetValue(guid, out var cached) && cached.Modified == modified)
        {
            return cached.File;
        }
        CutsceneFile? file = null;
        try
        {
            file = Utf8Text.Decode(File.ReadAllBytes(path)) is { } text ? CutsceneFile.Parse(text).File : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
        _read[guid] = (modified, file);
        return file;
    }

    /// <summary>Each open document follows its asset's file, as when the content browser moves or renames it.</summary>
    internal void FollowMoves()
    {
        foreach (var entry in _open.Values)
        {
            if (shell.Assets.Find(entry.Document.Guid) is { } asset && shell.Assets.FullPath(asset) is { } path
                && !string.Equals(path, entry.Document.Path, StringComparison.OrdinalIgnoreCase))
            {
                entry.Document.Move(path);
            }
        }
    }
}
