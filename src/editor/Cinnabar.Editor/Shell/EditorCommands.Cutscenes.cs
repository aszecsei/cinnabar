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
    public const string CutsceneMuteTrack = "cutscene.muteTrack";
    public const string CutsceneSoloTrack = "cutscene.soloTrack";
    public const string CutsceneAddMarker = "cutscene.addMarker";
    public const string CutsceneCopy = "cutscene.copy";
    public const string CutsceneCut = "cutscene.cut";
    public const string CutscenePaste = "cutscene.paste";
    public const string CutsceneFind = "cutscene.find";
    public const string CutsceneKeysUnderSelection = "cutscene.keysUnderSelection";
    public const string CutscenePlayPause = "cutscene.playPause";
    public const string CutsceneStepBack = "cutscene.stepBack";
    public const string CutsceneStepForward = "cutscene.stepForward";
    public const string CutsceneStepBack10 = "cutscene.stepBack10";
    public const string CutsceneStepForward10 = "cutscene.stepForward10";
    public const string CutsceneShuttleBack = "cutscene.shuttleBack";
    public const string CutsceneShuttlePause = "cutscene.shuttlePause";
    public const string CutsceneShuttleForward = "cutscene.shuttleForward";
    public const string CutsceneSetIn = "cutscene.setIn";
    public const string CutsceneSetOut = "cutscene.setOut";
    public const string CutsceneClearInOut = "cutscene.clearInOut";
    public const string CutsceneLoop = "cutscene.loop";
    public const string CutscenePreviousKey = "cutscene.previousKey";
    public const string CutsceneNextKey = "cutscene.nextKey";
    public const string CutsceneGoToTime = "cutscene.goToTime";
    public const string CutsceneScrubSound = "cutscene.scrubSound";
    public const string CutscenePreviewEvents = "cutscene.previewEvents";

    /// <summary>The timeline's commands, which act on the active cutscene while its timeline has the keyboard.</summary>
    public static readonly string[] CutsceneTimelineCommands =
    [
        CutsceneFrame, CutsceneGoToStart, CutsceneGoToEnd, CutscenePreviousEdge, CutsceneNextEdge, CutsceneSplit, CutsceneRippleDelete,
        CutsceneNudgeEarlier, CutsceneNudgeLater, CutsceneNudgeEarlier10, CutsceneNudgeLater10, CutsceneSnap, CutsceneShowFrames, CutsceneLockTrack,
        CutsceneMuteTrack, CutsceneSoloTrack, CutsceneAddMarker, CutsceneCopy, CutsceneCut, CutscenePaste, CutsceneFind,
        CutsceneKeysUnderSelection, CutscenePlayPause, CutsceneStepBack, CutsceneStepForward, CutsceneStepBack10, CutsceneStepForward10,
        CutsceneShuttleBack, CutsceneShuttlePause, CutsceneShuttleForward, CutsceneSetIn, CutsceneSetOut, CutsceneClearInOut, CutsceneLoop,
        CutscenePreviousKey, CutsceneNextKey, CutsceneGoToTime, CutsceneScrubSound, CutscenePreviewEvents,
    ];

    // The cutscene editor's timeline (see docs/editor/cutscene-editor.md#the-timeline). Its keys are bare letters, which
    // the viewport and the other panels use too, so each command acts only while the timeline has the keyboard. Delete
    // and Duplicate are the scene's Delete and Duplicate, which act on the timeline then. A command that cannot act
    // leaves its key to the focused control, so Ctrl+C and Ctrl+V still reach a text box.
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
        void Toggle(string id, string label, string description, string shortcut, Func<CutsceneEditor, bool> get, Action<CutsceneEditor, bool> set) =>
            commands.Register(new Command(id, label, () =>
            {
                if (Timeline() is { } editor)
                {
                    set(editor, !get(editor));
                }
            })
            {
                Description = description,
                Icon = "cutscene",
                Shortcut = shortcut,
                CanExecuteWhen = () => Timeline() != null,
                IsCheckedWhen = () => shell.ActiveCutscene is { } editor && get(editor),
            });
        commands.Register(new Command(CutscenePlayPause, "Play/Pause", () =>
        {
            if (Timeline() is { } editor && shell.CutscenePreview.CanPlay(editor))
            {
                shell.CutscenePreview.PlayPause();
            }
        })
        {
            Description = "Play the cutscene in the game from the playhead, or pause it. The game keeps the time while it plays.",
            Icon = "play",
            Shortcut = "Space",
            CanExecuteWhen = () => Timeline() is { } editor && shell.CutscenePreview.CanPlay(editor),
            IsCheckedWhen = () => shell.ActiveCutscene is { } editor && shell.CutscenePreview.IsPlayingIn(editor),
        });
        Register(CutsceneStepBack, "Step Back", "cutscene", "Move the playhead a frame earlier, and pause the preview.", "Left", e => e.Step(-1));
        Register(CutsceneStepForward, "Step Forward", "cutscene", "Move the playhead a frame later, and pause the preview.", "Right", e => e.Step(1));
        Register(CutsceneStepBack10, "Step Back 10 Frames", "cutscene", "Move the playhead 10 frames earlier, and pause the preview.", "Shift+Left", e => e.Step(-10));
        Register(CutsceneStepForward10, "Step Forward 10 Frames", "cutscene", "Move the playhead 10 frames later, and pause the preview.", "Shift+Right", e => e.Step(10));
        Register(CutsceneShuttleBack, "Shuttle Back", "cutscene",
            "Play the cutscene backward in the game; each press doubles the rate, up to 8×. With Shuttle Pause held, step a frame back.", "J",
            e => Shuttle(e, -1));
        Register(CutsceneShuttleForward, "Shuttle Forward", "cutscene",
            "Play the cutscene forward in the game; each press doubles the rate, up to 8×. With Shuttle Pause held, step a frame on.", "L",
            e => Shuttle(e, 1));
        Register(CutsceneShuttlePause, "Shuttle Pause", "cutscene",
            "Pause the preview. While its key is held, Shuttle Back and Shuttle Forward step a frame.", "K",
            e =>
            {
                e.ShuttleHeld = true;
                shell.CutscenePreview.Pause();
            });
        Register(CutsceneSetIn, "Set In", "cutscene", "Set the loop's in point at the playhead.", "I", e => e.SetIn(e.Playhead));
        Register(CutsceneSetOut, "Set Out", "cutscene", "Set the loop's out point at the playhead.", "O", e => e.SetOut(e.Playhead));
        Register(CutsceneClearInOut, "Clear In and Out", "cutscene", "Clear the in and the out point, so the loop is the whole cutscene.", "Alt+X",
            e => e.ClearInOut(),
            e => e.InPoint != null || e.OutPoint != null);
        Toggle(CutsceneLoop, "Loop", "Play between the in and the out point, or the whole cutscene without them, and go back to the start at the end.", "Ctrl+L",
            e => e.Loop, (e, on) => e.Loop = on);
        Register(CutscenePreviousKey, "Previous Key", "cutscene", "Move the playhead back to the key or the edge before it on the selected tracks, or on every track with none selected.", "Up",
            e => e.SetPlayhead(e.KeyEdges().LastOrDefault(t => t < e.Playhead)));
        Register(CutsceneNextKey, "Next Key", "cutscene", "Move the playhead on to the key or the edge after it on the selected tracks, or on every track with none selected.", "Down",
            e => e.SetPlayhead(e.KeyEdges().FirstOrDefault(t => t > e.Playhead, e.Playhead)));
        Register(CutsceneGoToTime, "Go to Time", "cutscene", "Type a time, as timecode or as frames, and move the playhead there.", "Ctrl+G",
            e => e.RequestGoToTime());
        Toggle(CutsceneScrubSound, "Scrub Sound", "Play short grains of the sound under the playhead while it is dragged. Each user's.", "Alt+S",
            e => e.ScrubSound, (e, on) => e.ScrubSound = on);
        Toggle(CutscenePreviewEvents, "Events in Preview", "Send the event tracks' events to the scripts while the preview plays, never while it is scrubbed. Each user's.", "Alt+E",
            e => e.PreviewEvents, (e, on) => e.PreviewEvents = on);
        Register(CutsceneFrame, "Frame Selection", "frame", "Fit the selected sections, events and keys in the timeline, or the whole cutscene when none is selected.", "F",
            e => e.RequestFrame());
        Register(CutsceneGoToStart, "Go to Start", "cutscene", "Move the playhead to the cutscene's start.", "Home", e => e.SetPlayhead(0));
        Register(CutsceneGoToEnd, "Go to End", "cutscene", "Move the playhead to the cutscene's end.", "End", e => e.SetPlayhead(e.File.Length ?? 0));
        Register(CutscenePreviousEdge, "Previous Edge", "cutscene", "Move the playhead back to the marker or the edge of a section, a range or a trigger before it.", "Ctrl+Left",
            e => e.SetPlayhead(Edges(e).LastOrDefault(t => t < e.Playhead)));
        Register(CutsceneNextEdge, "Next Edge", "cutscene", "Move the playhead on to the marker or the edge of a section, a range or a trigger after it.", "Ctrl+Right",
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
        Register(CutsceneMuteTrack, "Mute Track", "cutscene", "Mute or unmute the selected track in the preview. Mutes are each user's, and do not change the cutscene.",
            null,
            e => e.SetMuted(e.SelectedTrack!.Id!.Value, !e.Muted.Contains(e.SelectedTrack.Id.Value)),
            e => e.SelectedTrack?.Id != null);
        Register(CutsceneSoloTrack, "Solo Track", "cutscene", "Solo the selected track, or end its solo: while any track is soloed, the preview plays only those. Solos are each user's.",
            null,
            e => e.SetSoloed(e.SelectedTrack!.Id!.Value, !e.Soloed.Contains(e.SelectedTrack.Id.Value)),
            e => e.SelectedTrack?.Id != null);
        Register(CutsceneAddMarker, "Add Marker", "cutscene", "Add a marker at the playhead, or select the one there.", "M",
            e => e.AddMarker(), e => !e.Document.InTransaction);
        Register(CutsceneCopy, "Copy", "copy", "Copy the selected sections, events, keys and markers.", "Ctrl+C",
            e => e.Copy(), e => e.CanCopy);
        Register(CutsceneCut, "Cut", "copy", "Copy the selected sections, events, keys and markers, then delete them.", "Ctrl+X",
            e => e.Cut(), e => e.CanEditSelection);
        Register(CutscenePaste, "Paste", "copy", "Paste what was copied at the playhead, keeping its times, on the selected track or binding, or else on the tracks it came from.", "Ctrl+V",
            e => e.Paste(), e => e.CanPaste);
        Register(CutsceneFind, "Find Track", "search", "Put the keyboard in the timeline's search box, which filters the tracks by binding or track name.", "Ctrl+F",
            e => e.RequestFind());
        commands.Register(new Command(CutsceneKeysUnderSelection, "Keys Under Selection", () =>
        {
            if (Timeline() is { } editor)
            {
                editor.SetKeysUnderSelection(!editor.KeysUnderSelection);
            }
        })
        {
            Description = "Show only the tracks with keys in the span of the selection, as it is when this is turned on, or show them all again.",
            Icon = "search",
            CanExecuteWhen = () => Timeline() != null,
            IsCheckedWhen = () => shell.ActiveCutscene?.KeysUnderSelection == true,
        });
    }

    static List<int> Edges(CutsceneEditor editor) => editor.Layout().Edges();

    // J and L play, or step a frame while K is held.
    static void Shuttle(CutsceneEditor editor, int direction)
    {
        if (editor.ShuttleHeld)
        {
            editor.Step(direction);
        }
        else
        {
            editor.Shuttle(direction);
        }
    }
}
