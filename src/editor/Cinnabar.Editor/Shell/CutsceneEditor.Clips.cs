using Cinnabar.Editor.Content;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Shell;

// The sections' clips (see docs/editor/cutscene-editor.md#sections): what the index knows of each, drops of animations
// and sounds, and the section menu's commands.
public sealed partial class CutsceneEditor
{
    /// <summary>
    /// What the index knows of an animation clip, a sound or a cutscene by its GUID, for its sections' bars: a clip's name
    /// in its model, or a sound's or a cutscene's file name, its length, and a sound's peak file. A cutscene has no length
    /// here, since a sub-sequence section plays its trim. Null for another kind or an asset that is not there.
    /// </summary>
    public CutsceneClipInfo? ClipOf(string guid) => _shell.Assets.Find(guid) switch
    {
        { Kind: AssetKind.Animation } a => new(a.Subasset != "" ? a.Subasset : Path.GetFileNameWithoutExtension(a.Path), AssetIndex.LengthOf(a)),
        { Kind: AssetKind.Audio } a => new(Path.GetFileNameWithoutExtension(a.Path), AssetIndex.LengthOf(a), AssetIndex.PeaksOf(a)),
        { Kind: AssetKind.Cutscene } a => new(Path.GetFileNameWithoutExtension(a.Path), null),
        _ => null,
    };

    // The clips among assets dropped from the content browser, by GUID, with the kind of track that each goes on: an
    // animation's, a sound's, or a cutscene's sub-sequence.
    List<(string Guid, string Kind)> ClipsOf(IEnumerable<string> assets) =>
    [
        .. assets.Distinct().Select(g => _shell.Assets.Find(g)).OfType<Asset>()
            .Where(a => a.Kind is AssetKind.Animation or AssetKind.Audio or AssetKind.Cutscene)
            .Select(a => (a.Guid, a.Kind switch
            {
                AssetKind.Animation => "animation",
                AssetKind.Cutscene => "sub_sequence",
                _ => "audio",
            })),
    ];

    /// <summary>
    /// Why a cutscene cannot play as a sub-sequence of the shown level, or null when it can: it would play a cutscene
    /// that plays it, at some depth, which the cooker refuses too. The message names the cycle's path, as the cooker's
    /// does. The open documents' unsaved text counts, and the files of the others.
    /// </summary>
    public string? SubSequenceRefusal(string guid)
    {
        if (CutsceneSubSequences.Cycle(ShownGuid, guid, _shell.CutsceneDocuments.Read) is not { } cycle)
        {
            return null;
        }
        var names = cycle.Select(g => _shell.Assets.Find(g) is { } a ? Path.GetFileNameWithoutExtension(a.Path) : g);
        return $"sub-sequence cycle: {string.Join(" -> ", names)}";
    }

    // How long a dropped clip's section is: a clip's or a sound's length, a cutscene's range, or a second when it has none.
    int DropLength(string guid, string kind) => kind == "sub_sequence"
        ? _shell.CutsceneDocuments.Read(guid) is { } child && CutsceneEdits.RangeOf(child) is var range && range.End > range.Start
            ? range.End - range.Start
            : CutsceneFile.TicksPerSecond
        : ClipOf(guid)?.Length ?? CutsceneFile.TicksPerSecond;

    // Whether a clip of a kind dropped on a row has a track to go on: an animation needs the row's binding, and a locked
    // track takes nothing.
    bool Lands(string kind, string? rowPath)
    {
        var track = CutsceneEdits.ClipTrack(File, kind, rowPath == null ? null : File.Find(rowPath), out var binding);
        return !(kind == "animation" && binding == null) && !(track != null && CutsceneEdits.IsLocked(track, _locked));
    }

    /// <summary>Whether a drop of these assets on a row, by its path, or on no row, would add a section.</summary>
    public bool CanDropClips(IEnumerable<string> assets, string? rowPath) =>
        !Document.InTransaction && ClipsOf(assets).Any(c => Lands(c.Kind, rowPath));

    /// <summary>
    /// Adds a section for each animation, sound and cutscene among dropped assets, at a time, as one undo entry (see
    /// docs/editor/cutscene-editor.md#drops): an animation on the binding of the row, a sound on the row's audio track,
    /// on its binding's, or else on an audio track of no binding, and a cutscene as a sub-sequence of its range. Each is
    /// the clip's length, or a second when the clip has not cooked, and the next starts where it ends. A cutscene that
    /// would make a cycle is refused, with its path in the console. It selects the new sections and returns their paths.
    /// </summary>
    public IReadOnlyList<string> DropClips(IEnumerable<string> assets, string? rowPath, int tick)
    {
        var clips = ClipsOf(assets).Where(c => Lands(c.Kind, rowPath)).ToList();
        if (clips.Count == 0 || Document.InTransaction)
        {
            return [];
        }
        foreach (var (guid, _) in clips.Where(c => c.Kind == "sub_sequence").ToList())
        {
            if (SubSequenceRefusal(guid) is { } cycle)
            {
                _shell.Console.Add(Model.LogLevel.Warning, $"cutscene: {cycle}. The drop adds no section for it.");
                clips.RemoveAll(c => c.Guid == guid);
            }
        }
        if (clips.Count == 0)
        {
            return [];
        }
        List<string> added = [];
        Key(clips.Count == 1 ? "Add Section" : "Add Sections", f =>
        {
            added.Clear();
            var at = tick;
            var target = rowPath == null ? null : f.Find(rowPath);
            foreach (var (guid, kind) in clips)
            {
                var length = DropLength(guid, kind);
                if (CutsceneEdits.AddClipSection(f, kind, target, at, length, guid, _locked) is { } path)
                {
                    added.Add(path);
                    at += length;
                }
            }
        });
        if (added.Count == 0)
        {
            return [];
        }
        if (File.Find(added[^1]) is { } section && CutsceneEdits.TrackOf(section) is { } track)
        {
            if (CutsceneEdits.BindingOf(track) is { } binding && File.Bindings.FirstOrDefault(b => b.Id == binding) is { } owner)
            {
                _folds.Remove(CutsceneFile.PathOf(owner));
            }
            Select(added, SelectMode.Replace);
            RevealRequested?.Invoke(CutsceneFile.PathOf(track));
        }
        return added;
    }

    // The primary selection's clip, when it is an animation or audio section whose asset the index has.
    Asset? SelectedClip => Selected is { Kind: CutsceneBlockKind.Section } section
        && CutsceneEdits.TrackOf(section)?.TrackKind is "animation" or "audio"
        && section.Get("asset")?.Trim() is ['$', .. var guid]
        ? _shell.Assets.Find(guid)
        : null;

    /// <summary>Shows the selected section's clip or sound in the content browser.</summary>
    public void RevealClip()
    {
        if (SelectedClip is { } clip)
        {
            _shell.Content.RevealAsset(clip.Guid);
        }
    }

    /// <summary>
    /// Shows the selected section's clip or sound in the content browser, and opens it as the content browser would,
    /// when its kind has an editor. Animations and sounds have none yet, so it is shown and selected.
    /// </summary>
    public void OpenClip()
    {
        if (SelectedClip is not { } clip)
        {
            return;
        }
        _shell.Content.RevealAsset(clip.Guid);
        if (EditorShell.CanOpen(clip))
        {
            _shell.OpenAsset(clip);
        }
    }

    // The selected sections that Match Clip Length trims, each with the change of its end: a section whose clip's length
    // the index knows, that does not loop, and whose end is not where its clip ends.
    List<(string Path, int Change)> MatchableSections()
    {
        List<(string, int)> sections = [];
        foreach (var path in SelectedPaths)
        {
            if (File.Find(path) is not { Kind: CutsceneBlockKind.Section, Start: { } start, End: { } end } section
                || CutsceneEdits.TrackOf(section) is not { TrackKind: "animation" or "audio" } track
                || CutsceneEdits.IsLocked(section, _locked)
                || section.Get("asset")?.Trim() is not ['$', .. var guid]
                || CutsceneTimelineLayout.SpanOf(track, section, ClipOf(guid)) is not { Loop: false } clip)
            {
                continue;
            }
            var duration = (int)Math.Round((clip.Length - clip.Offset) / clip.Speed);
            if (duration > 0 && duration != end - start)
            {
                sections.Add((path, duration - (end - start)));
            }
        }
        return sections;
    }

    /// <summary>Whether Match Clip Length would trim a selected section.</summary>
    public bool CanMatchClipLength => !Document.InTransaction && MatchableSections().Count > 0;

    /// <summary>
    /// Trims the end of each selected animation or audio section that does not loop to where its clip ends, from its
    /// offset at its speed, as one undo entry. The trim's limits hold: its keys, its eases, a frame and the length.
    /// </summary>
    public void MatchClipLength()
    {
        var sections = MatchableSections();
        if (sections.Count == 0 || Document.InTransaction)
        {
            return;
        }
        Key("Match Clip Length", f =>
        {
            foreach (var (path, change) in sections)
            {
                CutsceneEdits.Trim(f, path, CutsceneEdge.End, change, ripple: false, _locked, ChildStart);
            }
        });
    }
}
