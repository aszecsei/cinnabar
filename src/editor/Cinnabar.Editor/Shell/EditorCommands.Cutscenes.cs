using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Shell;

static partial class EditorCommands
{
    public const string CutsceneFrame = "cutscene.frame";
    public const string CutsceneGoToStart = "cutscene.goToStart";
    public const string CutsceneGoToEnd = "cutscene.goToEnd";
    public const string CutscenePreviousEdge = "cutscene.previousEdge";
    public const string CutsceneNextEdge = "cutscene.nextEdge";
    public const string CutsceneSplit = "cutscene.split";
    public const string CutsceneRippleDelete = "cutscene.rippleDelete";
    public const string CutsceneNudgeEarlier = "cutscene.nudgeEarlier";
    public const string CutsceneNudgeLater = "cutscene.nudgeLater";
    public const string CutsceneNudgeEarlier10 = "cutscene.nudgeEarlier10";
    public const string CutsceneNudgeLater10 = "cutscene.nudgeLater10";
    public const string CutsceneSnap = "cutscene.snap";
    public const string CutsceneShowFrames = "cutscene.showFrames";
    public const string CutsceneLockTrack = "cutscene.lockTrack";

    /// <summary>The timeline's commands, which act on the active cutscene while its timeline has the keyboard.</summary>
    public static readonly string[] CutsceneTimelineCommands =
    [
        CutsceneFrame, CutsceneGoToStart, CutsceneGoToEnd, CutscenePreviousEdge, CutsceneNextEdge, CutsceneSplit, CutsceneRippleDelete,
        CutsceneNudgeEarlier, CutsceneNudgeLater, CutsceneNudgeEarlier10, CutsceneNudgeLater10, CutsceneSnap, CutsceneShowFrames, CutsceneLockTrack,
    ];

    // The cutscene editor's timeline (see docs/editor/cutscene-editor.md#the-timeline). Its keys are bare letters, which
    // the viewport and the other panels use too, so each command acts only while the timeline has the keyboard. Delete
    // is the scene's Delete, which acts on the timeline then.
    static void RegisterCutscenes(EditorShell shell)
    {
        var commands = shell.Commands;
        CutsceneEditor? Timeline() => shell.ActiveCutscene is { TimelineFocused: true } editor ? editor : null;
        void Register(string id, string label, string icon, string description, string? shortcut, Action<CutsceneEditor> run, Func<CutsceneEditor, bool>? can = null)
        {
            commands.Register(new Command(id, label, () =>
            {
                if (Timeline() is { } editor && (can == null || can(editor)))
                {
                    run(editor);
                }
            })
            {
                Description = description,
                Icon = icon,
                Shortcut = shortcut,
                CanExecuteWhen = () => Timeline() is { } editor && (can == null || can(editor)),
            });
        }
        Register(CutsceneFrame, "Frame Selection", "frame", "Fit the selected sections, events and keys in the timeline, or the whole cutscene when none is selected.", "F",
            e => e.RequestFrame());
        Register(CutsceneGoToStart, "Go to Start", "cutscene", "Move the playhead to the cutscene's start.", "Home", e => e.SetPlayhead(0));
        Register(CutsceneGoToEnd, "Go to End", "cutscene", "Move the playhead to the cutscene's end.", "End", e => e.SetPlayhead(e.File.Length ?? 0));
        Register(CutscenePreviousEdge, "Previous Edge", "cutscene", "Move the playhead back to the edge of a section, a range or a trigger before it.", "Ctrl+Left",
            e => e.SetPlayhead(Edges(e).LastOrDefault(t => t < e.Playhead)));
        Register(CutsceneNextEdge, "Next Edge", "cutscene", "Move the playhead on to the edge of a section, a range or a trigger after it.", "Ctrl+Right",
            e => e.SetPlayhead(Edges(e).FirstOrDefault(t => t > e.Playhead, e.Playhead)));
        Register(CutsceneSplit, "Split", "cutscene", "Split the selected sections at the playhead, into two that keep the curve's values at the cut.", "S",
            e => e.Split(), e => e.CanSplit);
        Register(CutsceneRippleDelete, "Ripple Delete", "delete", "Delete the selected sections, events and keys, and move the later sections on each track back over the gap.", "Shift+Delete",
            e => e.DeleteSelected(ripple: true), e => e.CanEditSelection);
        Register(CutsceneNudgeEarlier, "Nudge Earlier", "move", "Move the selection a frame earlier. Held, the repeats are one undo entry.", "OemComma",
            e => e.Nudge(-1), e => e.CanEditSelection);
        Register(CutsceneNudgeLater, "Nudge Later", "move", "Move the selection a frame later. Held, the repeats are one undo entry.", "OemPeriod",
            e => e.Nudge(1), e => e.CanEditSelection);
        Register(CutsceneNudgeEarlier10, "Nudge Earlier 10 Frames", "move", "Move the selection 10 frames earlier.", "Shift+OemComma",
            e => e.Nudge(-10), e => e.CanEditSelection);
        Register(CutsceneNudgeLater10, "Nudge Later 10 Frames", "move", "Move the selection 10 frames later.", "Shift+OemPeriod",
            e => e.Nudge(10), e => e.CanEditSelection);
        commands.Register(new Command(CutsceneSnap, "Snap", () =>
        {
            if (Timeline() is { } editor)
            {
                editor.Snap = !editor.Snap;
            }
        })
        {
            Description = "Snap drags to frames, the playhead, and the edges, events and keys of the timeline. Ctrl during a drag turns it off for that drag.",
            Icon = "snap",
            Shortcut = "N",
            CanExecuteWhen = () => Timeline() != null,
            IsCheckedWhen = () => shell.ActiveCutscene?.Snap == true,
        });
        commands.Register(new Command(CutsceneShowFrames, "Show Frames", () =>
        {
            if (Timeline() is { } editor)
            {
                editor.ShowFrames = !editor.ShowFrames;
            }
        })
        {
            Description = "Show times on the ruler as frames at the cutscene's rate, not as timecode.",
            Icon = "cutscene",
            CanExecuteWhen = () => Timeline() != null,
            IsCheckedWhen = () => shell.ActiveCutscene?.ShowFrames == true,
        });
        Register(CutsceneLockTrack, "Lock Track", "locked", "Lock or unlock the selected track, so no edit changes its sections, events and keys. Locks are each user's.",
            null,
            e => e.SetLocked(e.SelectedTrack!.Id!.Value, !e.Locked.Contains(e.SelectedTrack.Id.Value)),
            e => e.SelectedTrack?.Id != null);
    }

    static List<int> Edges(CutsceneEditor editor) => CutsceneTimelineLayout.Build(editor.File, editor.Folds).Edges();
}
