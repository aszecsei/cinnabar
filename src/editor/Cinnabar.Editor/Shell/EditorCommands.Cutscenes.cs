using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Document;
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
    public const string CutsceneKeyTransform = "cutscene.keyTransform";
    public const string CutsceneKeyTrackedFields = "cutscene.keyTrackedFields";
    public const string CutsceneAutoKey = "cutscene.autoKey";
    public const string CutsceneAutoKeyAddTracks = "cutscene.autoKeyAddTracks";
    public const string CutsceneKeyPreviewValues = "cutscene.keyPreviewValues";
    public const string CutsceneCurves = "cutscene.curves";
    public const string CutsceneCurvesNormalized = "cutscene.curvesNormalized";
    public const string CutsceneTangentAuto = "cutscene.tangentAuto";
    public const string CutsceneTangentUnify = "cutscene.tangentUnify";
    public const string CutsceneTangentBreak = "cutscene.tangentBreak";
    public const string CutsceneTangentLinear = "cutscene.tangentLinear";
    public const string CutsceneTangentConstant = "cutscene.tangentConstant";
    public const string CutsceneTangentFlatten = "cutscene.tangentFlatten";
    public const string CutsceneTangentWeighted = "cutscene.tangentWeighted";
    public const string CutsceneCurveValueSnap = "cutscene.curveValueSnap";
    public const string CutscenePreInfinity = "cutscene.preInfinity";
    public const string CutscenePostInfinity = "cutscene.postInfinity";
    public const string CutsceneAddBindingSelected = "cutscene.addBindingSelected";
    public const string CutsceneRebindToSelection = "cutscene.rebindToSelection";
    public const string CutsceneFilterSelected = "cutscene.filterSelected";
    public const string CutsceneSpawnPrefab = "cutscene.spawnPrefab";
    public const string CutsceneAddSlot = "cutscene.addSlot";
    public const string CutsceneConvertToPossessed = "cutscene.convertToPossessed";
    public const string CutsceneConvertToSpawned = "cutscene.convertToSpawned";
    public const string CutsceneConvertToSlot = "cutscene.convertToSlot";
    public const string CutscenePickBinding = "cutscene.pickBinding";
    public const string CutsceneStandInSelection = "cutscene.standInSelection";
    public const string CutsceneRevealClip = "cutscene.revealClip";
    public const string CutsceneOpenClip = "cutscene.openClip";
    public const string CutsceneMatchClipLength = "cutscene.matchClipLength";
    public const string CutsceneAddEvent = "cutscene.addEvent";
    public const string CutsceneJumpToHandler = "cutscene.jumpToHandler";
    public const string CutsceneOpenSubSequence = "cutscene.openSubSequence";
    public const string CutsceneUpOneLevel = "cutscene.upOneLevel";
    public const string CutsceneOpenInOwnTab = "cutscene.openInOwnTab";
    public const string CutsceneNewShot = "cutscene.newShot";
    public const string CutsceneShots = "cutscene.shots";

    /// <summary>The timeline's commands, which act on the active cutscene while its timeline has the keyboard.</summary>
    public static readonly string[] CutsceneTimelineCommands =
    [
        CutsceneFrame, CutsceneGoToStart, CutsceneGoToEnd, CutscenePreviousEdge, CutsceneNextEdge, CutsceneSplit, CutsceneRippleDelete,
        CutsceneNudgeEarlier, CutsceneNudgeLater, CutsceneNudgeEarlier10, CutsceneNudgeLater10, CutsceneSnap, CutsceneShowFrames, CutsceneLockTrack,
        CutsceneMuteTrack, CutsceneSoloTrack, CutsceneAddMarker, CutsceneCopy, CutsceneCut, CutscenePaste, CutsceneFind,
        CutsceneKeysUnderSelection, CutscenePlayPause, CutsceneStepBack, CutsceneStepForward, CutsceneStepBack10, CutsceneStepForward10,
        CutsceneShuttleBack, CutsceneShuttlePause, CutsceneShuttleForward, CutsceneSetIn, CutsceneSetOut, CutsceneClearInOut, CutsceneLoop,
        CutscenePreviousKey, CutsceneNextKey, CutsceneGoToTime, CutsceneScrubSound, CutscenePreviewEvents,
        CutsceneCurves, CutsceneCurvesNormalized, CutsceneTangentAuto, CutsceneTangentUnify, CutsceneTangentBreak, CutsceneTangentLinear,
        CutsceneTangentConstant, CutsceneTangentFlatten, CutsceneTangentWeighted, CutscenePreInfinity, CutscenePostInfinity,
        CutsceneCurveValueSnap, CutsceneRevealClip, CutsceneOpenClip, CutsceneMatchClipLength, CutsceneAddEvent, CutsceneJumpToHandler,
        CutsceneOpenSubSequence, CutsceneUpOneLevel, CutsceneOpenInOwnTab, CutsceneNewShot, CutsceneShots,
    ];

    /// <summary>
    /// The keying commands, which key the selected entities into the cutscene that holds the preview, wherever the
    /// keyboard is: the viewport, the timeline or the inspector.
    /// </summary>
    public static readonly string[] CutsceneKeyCommands =
        [CutsceneKeyTransform, CutsceneKeyTrackedFields, CutsceneAutoKey, CutsceneAutoKeyAddTracks, CutsceneKeyPreviewValues];

    /// <summary>
    /// The bindings' commands, which act between the entities selected in the viewport or the Outliner and the active
    /// cutscene, or the one that holds the preview, wherever the keyboard is (see docs/editor/cutscene-editor.md#bindings).
    /// </summary>
    public static readonly string[] CutsceneBindingCommands =
    [
        CutsceneAddBindingSelected, CutsceneRebindToSelection, CutsceneFilterSelected, CutsceneSpawnPrefab, CutsceneAddSlot, CutsceneConvertToPossessed,
        CutsceneConvertToSpawned, CutsceneConvertToSlot, CutscenePickBinding, CutsceneStandInSelection,
    ];

    // The cutscene editor's timeline (see docs/editor/cutscene-editor.md#the-timeline). Its keys are bare letters, which
    // the viewport and the other panels use too, so they are shortcuts of the timeline and the curve editor alone, and
    // the cutscene editor takes the commands while one of them has the keyboard (see CutsceneEditor.Handler). Nothing
    // else runs them. Delete and Duplicate are the scene's, which the cutscene editor takes then too.
    static void RegisterCutscenes(EditorShell shell)
    {
        var commands = shell.Commands;
        void Register(string id, string label, string icon, string description, string? shortcut, Func<CutsceneEditor, bool>? isOn = null) =>
            commands.Register(new Command(id, label, () => { })
            {
                Description = description,
                Icon = icon,
                Shortcut = shortcut,
                ShortcutScopes = [ShortcutScopes.CutsceneTimeline],
                CanExecuteWhen = () => false,
                IsCheckedWhen = isOn == null ? null : () => shell.ActiveCutscene is { } editor && isOn(editor),
            });
        Register(CutscenePlayPause, "Play/Pause", "play", "Play the cutscene in the game from the playhead, or pause it. The game keeps the time while it plays.", "Space",
            e => shell.CutscenePreview.IsPlayingIn(e));
        Register(CutsceneStepBack, "Step Back", "cutscene", "Move the playhead a frame earlier, and pause the preview.", "Left");
        Register(CutsceneStepForward, "Step Forward", "cutscene", "Move the playhead a frame later, and pause the preview.", "Right");
        Register(CutsceneStepBack10, "Step Back 10 Frames", "cutscene", "Move the playhead 10 frames earlier, and pause the preview.", "Shift+Left");
        Register(CutsceneStepForward10, "Step Forward 10 Frames", "cutscene", "Move the playhead 10 frames later, and pause the preview.", "Shift+Right");
        Register(CutsceneShuttleBack, "Shuttle Back", "cutscene",
            "Play the cutscene backward in the game; each press doubles the rate, up to 8×. With Shuttle Pause held, step a frame back.", "J");
        Register(CutsceneShuttleForward, "Shuttle Forward", "cutscene",
            "Play the cutscene forward in the game; each press doubles the rate, up to 8×. With Shuttle Pause held, step a frame on.", "L");
        Register(CutsceneShuttlePause, "Shuttle Pause", "cutscene",
            "Pause the preview. While its key is held, Shuttle Back and Shuttle Forward step a frame.", "K");
        Register(CutsceneSetIn, "Set In", "cutscene", "Set the loop's in point at the playhead.", "I");
        Register(CutsceneSetOut, "Set Out", "cutscene", "Set the loop's out point at the playhead.", "O");
        Register(CutsceneClearInOut, "Clear In and Out", "cutscene", "Clear the in and the out point, so the loop is the whole cutscene.", "Alt+X");
        Register(CutsceneLoop, "Loop", "cutscene", "Play between the in and the out point, or the whole cutscene without them, and go back to the start at the end.", "Ctrl+L",
            e => e.Loop);
        Register(CutscenePreviousKey, "Previous Key", "cutscene", "Move the playhead back to the key or the edge before it on the selected tracks, or on every track with none selected.", "Up");
        Register(CutsceneNextKey, "Next Key", "cutscene", "Move the playhead on to the key or the edge after it on the selected tracks, or on every track with none selected.", "Down");
        Register(CutsceneGoToTime, "Go to Time", "cutscene", "Type a time, as timecode or as frames, and move the playhead there.", "Ctrl+G");
        Register(CutsceneScrubSound, "Scrub Sound", "cutscene", "Play short grains of the sound under the playhead while it is dragged. Each user's.", "Alt+S",
            e => e.ScrubSound);
        Register(CutscenePreviewEvents, "Events in Preview", "cutscene", "Send the event tracks' events to the scripts while the preview plays, never while it is scrubbed. Each user's.", "Alt+E",
            e => e.PreviewEvents);
        Register(CutsceneFrame, "Frame Selection", "frame",
            "Fit the selected sections, events and keys in the timeline, or the whole cutscene when none is selected. In the curve editor, fit the selected keys, or every curve, in time and value.", "F");
        // The curve editor (see docs/editor/cutscene-editor.md#curves). Its tangent keys are the digits, as in other graph
        // editors, and they act on the selected keys while the curve editor has the keyboard.
        Register(CutsceneCurves, "Curve Editor", "cutscene", "Show the curves of the selected tracks below the timeline, on its time.", "Ctrl+E",
            e => e.CurvesOpen);
        Register(CutsceneCurvesNormalized, "Normalized Curves", "cutscene", "Scale each curve to -1 to 1 in the curve editor, to compare curves of different sizes. The keys keep their values.", "Alt+N",
            e => e.CurvesNormalized);
        Register(CutsceneCurveValueSnap, "Value Snap", "cutscene", "Snap a key that a drag in the curve editor moves to the value grid's lines. Ctrl during the drag does not snap.", "Alt+V",
            e => e.ValueSnap);
        Register(CutsceneTangentAuto, "Auto Tangents", "cutscene", "Make the selected keys smooth, with slopes that the curve computes and that do not overshoot.", "D1");
        Register(CutsceneTangentUnify, "Unify Tangents", "cutscene", "Give the selected keys one slope, the mean of their in and out slopes, which their handles then move together.", "D2");
        Register(CutsceneTangentBreak, "Break Tangents", "cutscene", "Keep the selected keys' slopes, and let their in and out handles move apart.", "D3");
        Register(CutsceneTangentLinear, "Linear", "cutscene", "Join the selected keys to the next keys with straight lines.", "D4");
        Register(CutsceneTangentConstant, "Constant", "cutscene", "Hold the selected keys' values until the next keys: a step.", "D5");
        Register(CutsceneTangentFlatten, "Flatten Tangents", "cutscene", "Make the selected keys' slopes flat.", "D6");
        Register(CutsceneTangentWeighted, "Weighted Tangents", "cutscene", "Weight the selected keys' tangents, so that a drag of a handle sets how far it reaches as well as its slope, or when all are weighted, take their weights away.", "D7");
        Register(CutscenePreInfinity, "Next Pre-Infinity", "cutscene", "Step what the curves of the selected keys, or the shown curves, do before their first key: constant, linear, cycle, cycle with offset, oscillate.", "D8");
        Register(CutscenePostInfinity, "Next Post-Infinity", "cutscene", "Step what the curves of the selected keys, or the shown curves, do after their last key: constant, linear, cycle, cycle with offset, oscillate.", "D9");
        Register(CutsceneGoToStart, "Go to Start", "cutscene", "Move the playhead to the cutscene's start.", "Home");
        Register(CutsceneGoToEnd, "Go to End", "cutscene", "Move the playhead to the cutscene's end.", "End");
        Register(CutscenePreviousEdge, "Previous Edge", "cutscene", "Move the playhead back to the marker or the edge of a section, a range or a trigger before it.", "Ctrl+Left");
        Register(CutsceneNextEdge, "Next Edge", "cutscene", "Move the playhead on to the marker or the edge of a section, a range or a trigger after it.", "Ctrl+Right");
        Register(CutsceneSplit, "Split", "cutscene", "Split the selected sections at the playhead, into two that keep the curve's values at the cut.", "S");
        Register(CutsceneRippleDelete, "Ripple Delete", "delete", "Delete the selected sections, events and keys, and move the later sections on each track back over the gap.", "Shift+Delete");
        Register(CutsceneNudgeEarlier, "Nudge Earlier", "move", "Move the selection a frame earlier. Held, the repeats are one undo entry.", "OemComma");
        Register(CutsceneNudgeLater, "Nudge Later", "move", "Move the selection a frame later. Held, the repeats are one undo entry.", "OemPeriod");
        Register(CutsceneNudgeEarlier10, "Nudge Earlier 10 Frames", "move", "Move the selection 10 frames earlier.", "Shift+OemComma");
        Register(CutsceneNudgeLater10, "Nudge Later 10 Frames", "move", "Move the selection 10 frames later.", "Shift+OemPeriod");
        Register(CutsceneSnap, "Snap", "snap",
            "Snap drags to frames, the playhead, and the edges, events and keys of the timeline. Ctrl during a drag turns it off for that drag.", "N",
            e => e.Snap);
        Register(CutsceneShowFrames, "Show Frames", "cutscene", "Show times on the ruler as frames at the cutscene's rate, not as timecode.", null,
            e => e.ShowFrames);
        Register(CutsceneLockTrack, "Lock Track", "locked", "Lock or unlock the selected track, so no edit changes its sections, events and keys. Locks are each user's.", null);
        Register(CutsceneMuteTrack, "Mute Track", "cutscene", "Mute or unmute the selected track in the preview. Mutes are each user's, and do not change the cutscene.", null);
        Register(CutsceneSoloTrack, "Solo Track", "cutscene", "Solo the selected track, or end its solo: while any track is soloed, the preview plays only those. Solos are each user's.", null);
        Register(CutsceneAddMarker, "Add Marker", "cutscene", "Add a marker at the playhead, or select the one there.", "M");
        Register(CutsceneCopy, "Copy", "copy", "Copy the selected sections, events, keys and markers.", "Ctrl+C");
        Register(CutsceneCut, "Cut", "copy", "Copy the selected sections, events, keys and markers, then delete them.", "Ctrl+X");
        Register(CutscenePaste, "Paste", "copy", "Paste what was copied at the playhead, keeping its times, on the selected track or binding, or else on the tracks it came from.", "Ctrl+V");
        Register(CutsceneFind, "Find Track", "search", "Put the keyboard in the timeline's search box, which filters the tracks by binding or track name.", "Ctrl+F");
        Register(CutsceneKeysUnderSelection, "Keys Under Selection", "search",
            "Show only the tracks with keys in the span of the selection, as it is when this is turned on, or show them all again.", null,
            e => e.KeysUnderSelection);
        // The section menu's (see docs/editor/cutscene-editor.md#the-section-menu).
        Register(CutsceneRevealClip, "Reveal in Content Browser", "search", "Show the selected section's animation clip or sound in the content browser.", null);
        Register(CutsceneOpenClip, "Open Clip", "cutscene",
            "Show the selected section's animation clip or sound in the content browser, and open it there. Clips and sounds have no editor yet, so they are only shown.", null);
        Register(CutsceneMatchClipLength, "Match Clip Length", "cutscene",
            "Trim each selected animation or audio section that does not loop so that it ends where its clip ends.", null);
        // Event keys (see docs/editor/cutscene-editor.md#events).
        Register(CutsceneAddEvent, "Add Event", "cutscene",
            "Add a trigger at the playhead on the selected event track, or on an event track of the selected binding, named for the first event that its behaviours handle.", "E");
        Register(CutsceneJumpToHandler, "Jump to Handler", "script", "Open the script of the selected trigger's or range's handler at its line, in the script editor.", null);
        // Sub-sequences (see docs/editor/cutscene-editor.md#sub-sequences). Enter is Key Preview Values' everywhere, so
        // opening one in context is Ctrl+Enter.
        Register(CutsceneOpenSubSequence, "Open Sub-sequence", "cutscene",
            "Show the selected sub-sequence's tracks in this tab, in context: the ruler keeps this cutscene's time, and the preview plays it around the shot.", "Ctrl+Enter");
        Register(CutsceneUpOneLevel, "Up One Level", "cutscene", "Show the cutscene that plays the sub-sequence shown in context.", "Back");
        Register(CutsceneOpenInOwnTab, "Open in Own Tab", "cutscene",
            "Open the sub-sequence shown in context, or the selected one, as its own asset in its own tab, on its own time. Both tabs edit one document.", null);
        // Shots (see docs/editor/cutscene-editor.md#shot-list). Ctrl+Shift+N is Create Entity's everywhere, so a new shot
        // is Ctrl+Alt+N.
        Register(CutsceneNewShot, "New Shot at Playhead", "cutscene",
            "Make a new cutscene beside this one, move the selected sections into it, and play it from a sub-sequence section in their place. With nothing selected, the new shot is empty and starts at the playhead.", "Ctrl+Alt+N");
        Register(CutsceneShots, "Shot List", "cutscene", "Show the sub-sequence sections in time order beside the timeline, to go to, rename and reorder them.", null);
        // Keys (see docs/editor/cutscene-editor.md#keying) act on the selection wherever the keyboard is, so K stays the
        // timeline's Shuttle Pause.
        commands.Register(new Command(CutsceneKeyTransform, "Key Transform", () => shell.Keying.KeyTransform())
        {
            Description = "Key the position, rotation and scale of each selected entity that the previewed cutscene binds, at its playhead.",
            Icon = "cutscene",
            Shortcut = "Ctrl+K",
            CanExecuteWhen = () => shell.Keying.KeyTransformRefusal() == null,
        });
        commands.Register(new Command(CutsceneKeyTrackedFields, "Key Tracked Fields", () => shell.Keying.KeyTrackedFields())
        {
            Description = "Key every field of each selected entity that a track of the previewed cutscene animates, at its playhead.",
            Icon = "cutscene",
            Shortcut = "Ctrl+Shift+K",
            CanExecuteWhen = () => shell.Keying.KeyTrackedFieldsRefusal() == null,
        });
        commands.Register(new Command(CutsceneAutoKey, "Auto-Key", () => shell.Keying.AutoKey = !shell.Keying.AutoKey)
        {
            Description = "Key each edit of a field of an entity that the previewed cutscene binds, from the inspector or a gizmo, at the playhead, in place of a scene edit.",
            Icon = "cutscene",
            Shortcut = "Alt+K",
            IsCheckedWhen = () => shell.Keying.AutoKey,
        });
        commands.Register(new Command(CutsceneAutoKeyAddTracks, "Auto-Key: Add Tracks", () => shell.Keying.AutoKeyAddTracks = !shell.Keying.AutoKeyAddTracks)
        {
            Description = "With auto-key, add the track of a field that has none. Without it, an edit of a field that no track animates goes to the scene.",
            Icon = "cutscene",
            Shortcut = "Alt+Shift+K",
            IsCheckedWhen = () => shell.Keying.AutoKeyAddTracks,
        });
        commands.Register(new Command(CutsceneKeyPreviewValues, "Key Preview Values", () => shell.Keying.KeyPreviewValues())
        {
            Description = "Key the values that were changed over the preview at the playhead, which a move of the playhead would drop.",
            Icon = "cutscene",
            Shortcut = "Enter",
            CanExecuteWhen = () => shell.Keying.KeyPreviewValuesRefusal() == null,
        });
        // Bindings (see docs/editor/cutscene-editor.md#bindings) act on the entities selected in the viewport or the
        // Outliner, where the keyboard is when the designer picks them.
        CutsceneEditor? Bindings() => shell.ActiveCutscene ?? shell.CutscenePreview.Owner;
        commands.Register(new Command(CutsceneAddBindingSelected, "Add Binding: Selected Entities", () => Bindings()?.Possess(shell.Selection.Entities))
        {
            Description = "Add a binding to the cutscene that possesses each selected entity that no binding possesses yet.",
            Icon = "cutscene",
            Shortcut = "Ctrl+Shift+B",
            CanExecuteWhen = () => Bindings() is { } editor && editor.PossessRefusal() == null,
        });
        commands.Register(new Command(CutsceneRebindToSelection, "Rebind to Selection", () => Bindings()?.Rebind(shell.Selection.Entity))
        {
            Description = "Point the selected binding at the selected entity, and keep its tracks.",
            Icon = "cutscene",
            CanExecuteWhen = () => Bindings() is { } editor && editor.RebindRefusal(shell.Selection.Entity) == null,
        });
        commands.Register(new Command(CutsceneSpawnPrefab, "Add Binding: Spawn Prefab…", () => Bindings()?.RequestSpawnPrefab())
        {
            Description = "Pick a prefab for the cutscene to spawn, and add a binding for it.",
            Icon = "cutscene",
            CanExecuteWhen = () => Bindings() is { } editor && !editor.Document.InTransaction,
        });
        commands.Register(new Command(CutsceneAddSlot, "Add Binding: Script Slot", () => Bindings()?.AddSlot("Slot"))
        {
            Description = "Add a binding whose entity a script gives when it plays the cutscene. Rename it to the name that the script uses.",
            Icon = "cutscene",
            CanExecuteWhen = () => Bindings() is { } editor && !editor.Document.InTransaction,
        });
        commands.Register(new Command(CutsceneConvertToPossessed, "Convert Binding to Possessed", () => Bindings()?.Convert(CutsceneBindingKind.Possessed))
        {
            Description = "Make the selected binding possess the selected entity, or a script slot's stand-in, and keep its tracks.",
            Icon = "cutscene",
            CanExecuteWhen = () => Bindings() is { } editor && editor.ConvertRefusal(CutsceneBindingKind.Possessed) == null,
        });
        commands.Register(new Command(CutsceneConvertToSpawned, "Convert Binding to Spawned", () => Bindings()?.Convert(CutsceneBindingKind.Spawned))
        {
            Description = "Make the selected binding spawn its entity's prefab where the entity is, and keep its tracks.",
            Icon = "cutscene",
            CanExecuteWhen = () => Bindings() is { } editor && editor.ConvertRefusal(CutsceneBindingKind.Spawned) == null,
        });
        commands.Register(new Command(CutsceneConvertToSlot, "Convert Binding to Script Slot", () => Bindings()?.Convert(CutsceneBindingKind.Provided))
        {
            Description = "Make the selected binding one whose entity a script gives, keep its tracks, and preview it with what it bound.",
            Icon = "cutscene",
            CanExecuteWhen = () => Bindings() is { } editor && editor.ConvertRefusal(CutsceneBindingKind.Provided) == null,
        });
        commands.Register(new Command(CutscenePickBinding, "Pick Binding's Entity", () =>
        {
            if (Bindings() is { } editor && !editor.CancelPick())
            {
                editor.ArmPick();
            }
        })
        {
            Description = "Point the selected binding at the next entity selected in the viewport or the Outliner. Esc cancels.",
            Icon = "cutscene",
            CanExecuteWhen = () => Bindings() is { } editor && (editor.Picking != null || editor.PickRefusal() == null),
            IsCheckedWhen = () => Bindings()?.Picking != null,
        });
        commands.Register(new Command(CutsceneStandInSelection, "Stand In Selection", () => Bindings()?.StandInSelection())
        {
            Description = "Preview the selected script slot with the selected entity. The stand-in is yours, and not saved in the cutscene.",
            Icon = "cutscene",
            CanExecuteWhen = () => Bindings() is { } editor && editor.StandInRefusal() == null,
        });
        commands.Register(new Command(CutsceneFilterSelected, "Show Selected Entities' Bindings", () =>
        {
            if (Bindings() is { } editor)
            {
                editor.SetSelectedOnly(!editor.SelectedOnly);
            }
        })
        {
            Description = "Show only the bindings of the entities selected in the viewport or the Outliner, and their tracks, or show them all again.",
            Icon = "search",
            CanExecuteWhen = () => Bindings() != null,
            IsCheckedWhen = () => Bindings()?.SelectedOnly == true,
        });
    }
}
