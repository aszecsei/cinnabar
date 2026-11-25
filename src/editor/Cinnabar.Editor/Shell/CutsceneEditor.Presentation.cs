using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The blocks that the timeline adds at the playhead besides clips, cuts and triggers (see
/// docs/editor/cutscene-editor.md#presentation): a fade, a letterbox or a subtitle on the presentation track, an event
/// range over the in and out points, and a gain key on the selected sound. Each is one undo entry, selected after.
/// </summary>
public sealed partial class CutsceneEditor
{
    /// <summary>How long a new presentation section or event range is when no in and out points give its span: two seconds.</summary>
    public const int NewSpanTicks = 2 * CutsceneFile.TicksPerSecond;

    /// <summary>Adds a presentation section of a kind, <c>fade</c>, <c>letterbox</c> or <c>subtitle</c>, over the in and out points or from the playhead.</summary>
    public void AddPresentation(string kind)
    {
        var (start, end) = NewSpan();
        string? path = null;
        var label = kind switch
        {
            "fade" => "Add Fade",
            "letterbox" => "Add Letterbox",
            _ => "Add Subtitle",
        };
        Key(label, f => path = CutsceneEdits.AddPresentation(f, kind, start, end - start, _locked));
        Reveal(path);
    }

    /// <summary>
    /// Adds an event range over the in and out points, or from the playhead, on the selected event track or binding's,
    /// named for the first range that its behaviours handle.
    /// </summary>
    public void AddEventRange()
    {
        var (start, end) = NewSpan();
        var target = Selected is { Kind: CutsceneBlockKind.Binding } b ? b : Selected is { } block ? CutsceneEdits.TrackOf(block) : null;
        var targetPath = target == null ? null : CutsceneFile.PathOf(target);
        var binding = target?.Kind == CutsceneBlockKind.Binding ? target.Id : CutsceneEdits.BindingOf(target);
        var name = ChoicesFor(binding, range: true) is [var first, ..] ? first.Name : "range";
        string? path = null;
        Key("Add Event Range", f => path = CutsceneEdits.AddEventRange(f, targetPath == null ? null : f.Find(targetPath), start, end, name, _locked));
        Reveal(path);
    }

    /// <summary>Why Add Gain Key cannot run, or null when the selected section is a sound's under the playhead.</summary>
    public string? AddGainKeyRefusal() =>
        Selected is not { Kind: CutsceneBlockKind.Section, Start: { } start, End: { } end } section || CutsceneEdits.TrackOf(section)?.TrackKind != "audio"
            ? "Select an audio section."
            : Playhead < start || Playhead > end ? "Move the playhead into the section."
            : null;

    /// <summary>Keys the selected audio section's gain at the playhead, which the curve editor then shows and moves.</summary>
    public void AddGainKey()
    {
        if (AddGainKeyRefusal() != null || Selection is not { } section)
        {
            return;
        }
        string? path = null;
        Key("Add Gain Key", f => path = CutsceneEdits.AddGainKey(f, section, Playhead, _locked));
        Reveal(path);
    }

    // The span of a new block: the in and out points when the tab has them, else from the playhead for NewSpanTicks.
    (int Start, int End) NewSpan() =>
        (InPoint != null || OutPoint != null) && LoopRange is { } loop ? (loop.Start, loop.End) : (Playhead, Playhead + NewSpanTicks);

    void Reveal(string? path)
    {
        if (path == null || File.Find(path) is not { } added || CutsceneEdits.TrackOf(added) is not { } track)
        {
            return;
        }
        Select([path], SelectMode.Replace);
        RevealRequested?.Invoke(CutsceneFile.PathOf(track));
    }
}
