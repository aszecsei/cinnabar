using System.Globalization;
using Cinnabar.Editor.Content;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;

namespace Cinnabar.Editor.Shell;

/// <summary>A row of the shot list: a sub-sequence section's path, its name, its start and length, and its camera's name.</summary>
public sealed record CutsceneShotRow(string Path, string Name, int Start, int Length, string Camera);

/// <summary>
/// A new shot that waits for its asset (see docs/editor/cutscene-editor.md#new-shots): the document and its text when
/// it was asked for, the blocks that move, the playhead on the shown level's time, the new section's name, and the
/// child's folder and file name.
/// </summary>
public sealed record PendingShot(CutsceneDocument Document, string Text, IReadOnlyList<string> Paths, int At, string Name, ContentFolder Folder, string FileName);

// The shot list and New Shot at Playhead: the shown level's sub-sequence sections, in time order.
public sealed partial class CutsceneEditor
{
    bool _shotsOpen;
    // The new shots whose assets the index does not have yet, each until it does.
    readonly List<Action> _shotWaits = [];
    bool _disposed;

    /// <summary>Whether the shot list shows beside the timeline. The tab's, and not saved.</summary>
    public bool ShotsOpen
    {
        get => _shotsOpen;
        set
        {
            if (_shotsOpen != value)
            {
                _shotsOpen = value;
                Changed?.Invoke();
            }
        }
    }

    /// <summary>
    /// The shown level's shots in time order: each sub-sequence section's name, or its child's file name, its span, and
    /// the camera that it opens on: the child's first cut in the span that it plays, or the shown level's cut at its start.
    /// </summary>
    public IReadOnlyList<CutsceneShotRow> ShotRows =>
    [
        .. CutsceneShots.Shots(File).Select(s =>
        {
            var section = File.Find(s.Path)!;
            var name = section.Name is { Length: > 0 } n ? n : s.Guid is { } g && ClipOf(g) is { } clip ? clip.Name : s.Guid ?? "";
            return new CutsceneShotRow(s.Path, name, s.Start, s.End - s.Start, CameraOf(section, s.Guid));
        }),
    ];

    string CameraOf(CutsceneBlock section, string? guid)
    {
        if (guid != null && _shell.CutsceneDocuments.Read(guid) is { } child && SubSequenceMap.Of(section, child) is { } map)
        {
            var (start, end) = map.Span;
            if (Cuts(child).FirstOrDefault(c => c.Start < end && start < c.End) is { } cut)
            {
                return CameraName(child, cut);
            }
        }
        return Cuts(File).FirstOrDefault(c => c.Start <= section.Start && section.Start < c.End) is { } own ? CameraName(File, own) : "";
    }

    static IEnumerable<CutsceneBlock> Cuts(CutsceneFile file) =>
        file.Tracks.FirstOrDefault(t => t.TrackKind == "camera_cut")?.Children
            .Where(c => c is { Kind: CutsceneBlockKind.Section, Start: not null, End: not null })
            .OrderBy(c => c.Start) ?? Enumerable.Empty<CutsceneBlock>();

    static string CameraName(CutsceneFile file, CutsceneBlock cut) =>
        cut.Get("camera") is { } text && CutsceneFile.TryParseId(text.Trim(), out var id)
            ? file.Bindings.FirstOrDefault(b => b.Id == id)?.Name ?? $"binding {id}"
            : "";

    /// <summary>A click on a shot: selects its section, moves the playhead to its start, and frames it.</summary>
    public void GoToShot(string path)
    {
        if (File.Find(path) is not { Kind: CutsceneBlockKind.Section, Start: { } start })
        {
            return;
        }
        Select([path], SelectMode.Replace);
        SetPlayhead(start);
        RequestFrame();
    }

    /// <summary>Renames a shot's section in one undo entry. An empty name removes it, and the bar shows the child's file name.</summary>
    public void RenameShot(string path, string name)
    {
        if (Document.InTransaction || File.Find(path) is not { Kind: CutsceneBlockKind.Section } section || section.Name == name.Trim()
            || CutsceneEdits.IsLocked(section, _locked))
        {
            return;
        }
        Own(() => Document.Edit("Rename Shot", f => f.Find(path)?.SetName(name.Trim())));
    }

    /// <summary>
    /// Moves a shot to the place of another on its track in one undo entry, as a drag in the shot list does (see
    /// <see cref="CutsceneShots.Reorder"/>). A move to another track or on a locked one is refused, with the reason in
    /// the console.
    /// </summary>
    public bool MoveShot(string path, string toPath)
    {
        if (Document.InTransaction)
        {
            return false;
        }
        if (CutsceneShots.ReorderRefusal(File, path, toPath, _locked) is { } why)
        {
            _shell.Console.Add(Model.LogLevel.Info, $"cutscene: {why}");
            return false;
        }
        Own(() => Document.Edit("Reorder Shots", f => CutsceneShots.Reorder(f, path, toPath, _locked)));
        return true;
    }

    /// <summary>
    /// Why New Shot at Playhead cannot start, or null when it can: a drag is under way, the shown cutscene is not in the
    /// index, or each selected block is on a locked track.
    /// </summary>
    public string? NewShotRefusal()
    {
        if (Documents.Any(d => d.InTransaction))
        {
            return "A drag is under way in the cutscene.";
        }
        if (_shell.Assets.Find(ShownGuid) is null)
        {
            return "The cutscene is not in the asset index.";
        }
        var blocks = _selection.Select(File.Find).OfType<CutsceneBlock>().Where(CutsceneEdits.IsTimed).ToList();
        return blocks.Count > 0 && blocks.All(b => CutsceneEdits.IsLocked(b, _locked)) ? "Each selected block is on a locked track." : null;
    }

    /// <summary>
    /// What New Shot at Playhead makes, or null with the reason in the console: the shown document as it is now, the
    /// selected blocks, the playhead, the shot's name, and a free file name beside the shown cutscene.
    /// </summary>
    internal PendingShot? RequestNewShot()
    {
        if (NewShotRefusal() is { } why)
        {
            _shell.Console.Add(Model.LogLevel.Info, $"cutscene: {why}");
            return null;
        }
        var asset = _shell.Assets.Find(ShownGuid)!;
        var number = (CutsceneShots.Shots(File).Count + 1).ToString("00", CultureInfo.InvariantCulture);
        var stem = $"{System.IO.Path.GetFileNameWithoutExtension(asset.Path)}_shot_{number}";
        var dir = System.IO.Path.GetDirectoryName(Document.Path) ?? "";
        var fileName = ContentBrowser.FreeName(dir, stem, _shell.Assets.ExtensionOf(AssetKind.Cutscene));
        return new PendingShot(Document, Document.Text, [.. _selection.Where(p => File.Find(p) is { } b && CutsceneEdits.IsTimed(b))],
            Playhead, $"Shot {number}", new ContentFolder(asset.Root, AssetIndex.Parent(asset.Path)), fileName);
    }

    /// <summary>
    /// New Shot at Playhead (see docs/editor/cutscene-editor.md#new-shots): asks the cook daemon for a new cutscene beside
    /// the shown one, and once the index has it, moves the selected blocks into it with <see cref="FinishNewShot"/>.
    /// </summary>
    public void NewShotAtPlayhead()
    {
        if (RequestNewShot() is not { } pending)
        {
            return;
        }
        _ = CreateShot(pending);
    }

    async Task CreateShot(PendingShot pending)
    {
        if (await _shell.Content.CreateIn(AssetTemplate.Cutscene, pending.Folder, pending.FileName) is not { } guid)
        {
            return;
        }
        if (_disposed)
        {
            _shell.Console.Add(Model.LogLevel.Info, $"cutscene: the tab closed while the new shot {pending.FileName} was made");
            return;
        }
        if (_shell.Assets.Find(guid) != null)
        {
            FinishNewShot(pending, guid);
            return;
        }
        // The daemon answers before the index has the asset, as for any new asset.
        Action? wait = null;
        wait = () =>
        {
            if (_shell.Assets.Find(guid) != null)
            {
                _shell.Assets.Changed -= wait;
                _shotWaits.Remove(wait!);
                FinishNewShot(pending, guid);
            }
        };
        _shotWaits.Add(wait);
        _shell.Assets.Changed += wait;
    }

    /// <summary>
    /// Moves the pending shot's blocks into the new child, with <see cref="CutsceneShots.NewShot"/>: one undo entry in
    /// the child, which is saved at once, so the cook of the parent reads its bindings, and one in the parent, which
    /// selects the new section. Nothing, with the reason in the console, when the parent's text changed while the asset
    /// was made. Returns whether it moved them.
    /// </summary>
    internal bool FinishNewShot(PendingShot pending, string guid)
    {
        var at = _shell.Assets.Find(guid) is { } made ? _shell.Assets.FullPath(made) : guid;
        if (pending.Document.Text != pending.Text || pending.Document.InTransaction)
        {
            _shell.Console.Add(Model.LogLevel.Info, $"cutscene: the cutscene changed while the new shot was made; its asset is {at}");
            return false;
        }
        if (_shell.CutsceneDocuments.Acquire(guid) is not { } lease)
        {
            return false;
        }
        using (lease)
        {
            var child = lease.Document;
            string? path = null;
            Own(() => pending.Document.Edit("New Shot", parent =>
                child.Edit("New Shot", file => path = CutsceneShots.NewShot(parent, file, pending.Paths, pending.At, guid, pending.Name, LockedOf(pending.Document)))));
            if (path == null)
            {
                return false;
            }
            child.Save();
            if (pending.Document == Document)
            {
                Select([path], SelectMode.Replace);
            }
        }
        return true;
    }

    // The locks of a held document: the shown level's own, or those saved in its settings.
    IReadOnlySet<int> LockedOf(CutsceneDocument document) =>
        document == Document ? _locked : _shell.CutsceneTimelineSettingsOf(document.Guid).Locked.ToHashSet();

    void DisposeShots()
    {
        _disposed = true;
        foreach (var wait in _shotWaits)
        {
            _shell.Assets.Changed -= wait;
        }
        _shotWaits.Clear();
    }
}
