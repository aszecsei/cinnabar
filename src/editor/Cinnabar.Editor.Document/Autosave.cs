using System.Globalization;
using System.Text;

namespace Cinnabar.Editor.Document;

/// <summary>
/// Autosaves of dirty scenes (see docs/editor/processes-and-projects.md#crash-recovery), in one directory, by default
/// <c>build/editor/autosave/</c>. A scene's autosave is named for its file and a hash of its full path, so two scenes
/// with one name do not share one. Saving the scene, or discarding its changes, deletes the autosave.
/// </summary>
public sealed class Autosave(string directory)
{
    public static readonly TimeSpan Interval = TimeSpan.FromSeconds(30);

    DateTime _last = DateTime.MinValue;

    public string Directory { get; } = Path.GetFullPath(directory);

    /// <summary>Where the autosave of a scene file goes.</summary>
    public string PathOf(string scenePath)
    {
        var full = Path.GetFullPath(scenePath);
        // FNV-1a of the path, without case, as Windows compares paths.
        var hash = Fnv.Hash32(Encoding.UTF8.GetBytes(full.ToLowerInvariant()));
        return Path.Combine(Directory, $"{Path.GetFileNameWithoutExtension(full)}.{hash.ToString("x8", CultureInfo.InvariantCulture)}{SceneFile.Extension}");
    }

    /// <summary>Writes the document's autosave if it is dirty and <see cref="Interval"/> has passed since the last one.</summary>
    public bool WriteIfDue(SceneDocument document, DateTime now)
    {
        if (!document.IsDirty || now - _last < Interval)
        {
            return false;
        }
        Write(document);
        _last = now;
        return true;
    }

    public void Write(SceneDocument document) => SceneDocument.WriteAtomically(PathOf(document.Path), SceneFile.Write(document.Scene));

    /// <summary>The autosave of a scene file, if there is one that is newer than the file.</summary>
    public string? Newer(string scenePath)
    {
        var autosave = PathOf(scenePath);
        return File.Exists(autosave) && (!File.Exists(scenePath) || File.GetLastWriteTimeUtc(autosave) > File.GetLastWriteTimeUtc(scenePath))
            ? autosave
            : null;
    }

    public void Delete(string scenePath)
    {
        var autosave = PathOf(scenePath);
        if (File.Exists(autosave))
        {
            File.Delete(autosave);
        }
    }
}
