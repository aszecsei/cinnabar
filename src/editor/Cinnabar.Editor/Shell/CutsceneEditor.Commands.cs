using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Shell;

public sealed partial class CutsceneEditor
{
    /// <summary>
    /// The timeline's commands (see <see cref="EditorCommands.CutsceneTimelineCommands"/>), and the scene's Delete and
    /// Duplicate, while a pane has the keyboard, as the active editor's tab takes them (see <see cref="EditorScope"/>).
    /// Their keys are shortcuts of the <see cref="ShortcutScopes.CutsceneTimeline"/> scope, which the timeline and the
    /// curve editor have. Delete deletes what is selected, or else the selected binding with its tracks.
    /// </summary>
    public ScopedCommand? Handler(string commandId) => commandId switch
    {
        _ when !TimelineFocused => null,
        EditorCommands.DeleteEntity => new(() =>
        {
            if (CanEditSelection)
            {
                DeleteSelected(ripple: false);
            }
            else
            {
                _ = DeleteBinding();
            }
        }, () => CanEditSelection || CanDeleteBinding),
        EditorCommands.DuplicateEntity => new(Duplicate, () => CanDuplicate),

        EditorCommands.CutscenePlayPause => new(_shell.CutscenePreview.PlayPause, () => _shell.CutscenePreview.CanPlay(this)),
        EditorCommands.CutsceneStepBack => new(() => Step(-1)),
        EditorCommands.CutsceneStepForward => new(() => Step(1)),
        EditorCommands.CutsceneStepBack10 => new(() => Step(-10)),
        EditorCommands.CutsceneStepForward10 => new(() => Step(10)),
        EditorCommands.CutsceneShuttleBack => new(() => ShuttleOrStep(-1)),
        EditorCommands.CutsceneShuttleForward => new(() => ShuttleOrStep(1)),
        EditorCommands.CutsceneShuttlePause => new(() =>
        {
            BeginShuttleHold();
            _shell.CutscenePreview.Pause();
        }),
        EditorCommands.CutsceneSetIn => new(() => SetIn(Playhead)),
        EditorCommands.CutsceneSetOut => new(() => SetOut(Playhead)),
        EditorCommands.CutsceneClearInOut => new(ClearInOut, () => InPoint != null || OutPoint != null),
        EditorCommands.CutsceneLoop => new(() => Loop = !Loop),
        EditorCommands.CutscenePreviousKey => new(() => SetPlayhead(KeyEdges().LastOrDefault(t => t < Playhead))),
        EditorCommands.CutsceneNextKey => new(() => SetPlayhead(KeyEdges().FirstOrDefault(t => t > Playhead, Playhead))),
        EditorCommands.CutsceneGoToTime => new(RequestGoToTime),
        EditorCommands.CutsceneScrubSound => new(() => ScrubSound = !ScrubSound),
        EditorCommands.CutscenePreviewEvents => new(() => PreviewEvents = !PreviewEvents),
        EditorCommands.CutsceneFrame => new(() =>
        {
            if (KeyboardPane == CutscenePane.Curves)
            {
                RequestFrameCurves();
            }
            else
            {
                RequestFrame();
            }
        }),

        EditorCommands.CutsceneCurves => new(() => CurvesOpen = !CurvesOpen),
        EditorCommands.CutsceneCurvesNormalized => new(() => CurvesNormalized = !CurvesNormalized),
        EditorCommands.CutsceneCurveValueSnap => new(() => ValueSnap = !ValueSnap),
        EditorCommands.CutsceneTangentAuto => TangentsCommand(TangentMode.Auto),
        EditorCommands.CutsceneTangentUnify => TangentsCommand(TangentMode.Unify),
        EditorCommands.CutsceneTangentBreak => TangentsCommand(TangentMode.Break),
        EditorCommands.CutsceneTangentLinear => TangentsCommand(TangentMode.Linear),
        EditorCommands.CutsceneTangentConstant => TangentsCommand(TangentMode.Constant),
        EditorCommands.CutsceneTangentFlatten => TangentsCommand(TangentMode.Flatten),
        EditorCommands.CutsceneTangentWeighted => new(ToggleWeighted, () => CurvesCanEdit && WeighableKeys.Count > 0),
        EditorCommands.CutscenePreInfinity => NextInfinityCommand(InfinitySide.Pre),
        EditorCommands.CutscenePostInfinity => NextInfinityCommand(InfinitySide.Post),

        EditorCommands.CutsceneGoToStart => new(() => SetPlayhead(0)),
        EditorCommands.CutsceneGoToEnd => new(() => SetPlayhead(File.Length ?? 0)),
        EditorCommands.CutscenePreviousEdge => new(() => SetPlayhead(Layout().Edges().LastOrDefault(t => t < Playhead))),
        EditorCommands.CutsceneNextEdge => new(() => SetPlayhead(Layout().Edges().FirstOrDefault(t => t > Playhead, Playhead))),
        EditorCommands.CutsceneSplit => new(Split, () => CanSplit),
        EditorCommands.CutsceneRippleDelete => new(() => DeleteSelected(ripple: true), () => CanEditSelection),
        EditorCommands.CutsceneNudgeEarlier => new(() => Nudge(-1), () => CanEditSelection),
        EditorCommands.CutsceneNudgeLater => new(() => Nudge(1), () => CanEditSelection),
        EditorCommands.CutsceneNudgeEarlier10 => new(() => Nudge(-10), () => CanEditSelection),
        EditorCommands.CutsceneNudgeLater10 => new(() => Nudge(10), () => CanEditSelection),
        EditorCommands.CutsceneSnap => new(() => Snap = !Snap),
        EditorCommands.CutsceneShowFrames => new(() => ShowFrames = !ShowFrames),
        EditorCommands.CutsceneLockTrack => TrackToggle(id => SetLocked(id, !Locked.Contains(id))),
        EditorCommands.CutsceneMuteTrack => TrackToggle(id => SetMuted(id, !Muted.Contains(id))),
        EditorCommands.CutsceneSoloTrack => TrackToggle(id => SetSoloed(id, !Soloed.Contains(id))),
        EditorCommands.CutsceneAddMarker => new(AddMarker, () => !Document.InTransaction),
        EditorCommands.CutsceneCopy => new(Copy, () => CanCopy),
        EditorCommands.CutsceneCut => new(Cut, () => CanEditSelection),
        EditorCommands.CutscenePaste => new(() => Paste(), () => CanPaste),
        EditorCommands.CutsceneFind => new(RequestFind),
        EditorCommands.CutsceneKeysUnderSelection => new(() => SetKeysUnderSelection(!KeysUnderSelection)),
        EditorCommands.CutsceneRevealClip => new(RevealClip, () => SelectedClip != null),
        EditorCommands.CutsceneOpenClip => new(OpenClip, () => SelectedClip != null),
        EditorCommands.CutsceneMatchClipLength => new(MatchClipLength, () => CanMatchClipLength),
        EditorCommands.CutsceneAddEvent => new(AddEvent, () => !Document.InTransaction),
        EditorCommands.CutsceneJumpToHandler => new(JumpToHandler, () => JumpToHandlerRefusal() == null),
        _ => null,
    };

    // The curve editor's key edits act on the selected keys while it has the keyboard, and not during a drag.
    bool CurvesCanEdit => KeyboardPane == CutscenePane.Curves && !Document.InTransaction;

    ScopedCommand TangentsCommand(TangentMode mode) => new(() => SetTangents(mode), () => CurvesCanEdit && TangentKeys.Count > 0);

    ScopedCommand NextInfinityCommand(InfinitySide side) => new(() => NextInfinity(side), () => CurvesCanEdit && InfinityCurves.Count > 0);

    // Lock, Mute and Solo act on the selected track.
    ScopedCommand TrackToggle(Action<int> toggle) => new(() => toggle(SelectedTrack!.Id!.Value), () => SelectedTrack?.Id != null);

    // J and L play, or step a frame while K is held.
    void ShuttleOrStep(int direction)
    {
        if (ShuttleHeld)
        {
            Step(direction);
        }
        else
        {
            Shuttle(direction);
        }
    }
}
