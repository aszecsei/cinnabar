# Cutscene editor

The cutscene editor edits a cutscene (see [Content: Cutscenes](../content/kinds/cutscenes.md)), which the game plays as [Cinematics](../cinematics/README.md) describes. Each open one is a tab, a `GraphEditorDocument` with the ID `cutscene.{guid}`, over a `CutsceneEditor` in the shell, which holds its state. Docking can rebuild the view, and tests drive the editor without a window.

The editor is built in steps under [#548](https://github.com/aszecsei/cinnabar/issues/548). This page describes what is built: the tab, its document, its timeline and details, the check of its unsaved text, its preview in Edit, keys from the inspector and the viewport, the curve editor, the bindings, the cameras with their lenses and focus, and the first part of the clips' display ([#556](https://github.com/aszecsei/cinnabar/issues/556)): names, loops, eases, drops and the section menu. Waveforms, a clip's events and thumbnails come next.

**In this document:** [The file](#the-file) · [The tab](#the-tab) · [The timeline](#the-timeline) · [Sections](#sections) · [Preview](#preview) · [Keying](#keying) · [Bindings](#bindings) · [Curves](#curves) · [Cameras](#cameras)

## The file

`CutsceneFile` reads a cutscene's text as whole lines (`TextLine`, which the animation graph and decision editors' files share). It puts each line in the block that `tools/cook/cutscenes.odin` would read it in. It does not write the text again from a model.

- **Blocks nest by keyword, not by indent.** The cooker ignores indents. So a block starts at its keyword line:
  - `binding`, `track` and `marker` are under the cutscene;
  - `section`, `trigger` and `range` are under a track;
  - `channel` is under a section;
  - `key` is under a channel.

  A block's settings are the lines up to the next keyword line. A sub-sequence's `bind <child> = <parent>` lines are its section's settings. The comments and blank lines above a block are its own, so removing a block takes its comment. A line that the cooker has no place for, such as a key outside a channel, stays in the open block, for the cooker to report.
- **Round trip:** a file reads and writes back as it was, with its comments, its blank lines and each line's ending. An edit changes only its own lines:
  - a setting's value, keeping its indent and its comment;
  - a block's keyword line, such as a name, a section's span or a key's time;
  - a setting line added or removed.

  A new setting goes after the block's last setting, before its first child block, because the cooker reads a setting after a child as the child's. Opening a file does not make it dirty.
- **Comments:** a `#` starts a comment as the cooker's `format.strip_comment` with `hash_in_word` says, at the line's start or after a space or a tab, outside quotes. So a `possess` path, `@<guid>/<instance>#<entity>`, is one value (`TextLine` with `hashInWord`).
- **It reads only the structure.** What a block's lines mean, and whether they are right, is the cooker's to say. So a cutscene with problems still opens, with its problems on its blocks. Only one file is refused: a file whose first line that is not a comment is not `cutscene 1`. That file opens in the script editor, with the reason in the console.
- **It agrees with the cooker.** `tools/cook/testdata/cutscenes/template.cutscene` is the text of a new cutscene. The cooker's tests check that it is `CUTSCENE_TEMPLATE`, and the editor's tests open it. The sample's cutscenes, `intro` and `fox_walk`, read and write back unchanged.
- **Paths:** an undo reads the text again, which replaces every block object. So the editor names a block by a path that the text gives:
  - its kind and ID, such as `section:6`;
  - for a channel, its section's path and its name;
  - for a key, its channel's path and its place in the channel.

  The selection is a path, and so it stays across an undo. A block whose path another block has too, as two sections with one ID have, cannot be selected, so an edit cannot land on the other. The cooker reports the ID.
- **Undo:** each editor has its own undo stack of the text (`GraphDocument`), and a drag is one entry. Undo, Redo and Save act on the cutscene editor whose tab is active. Esc during a drag cancels it, and nothing goes on the stack. Save is disabled during a drag. A document is dirty when its position in its history is not the one that its file has, and its tab marks it with a dot.
- **Saving** writes the text through a temporary file, and the cook daemon then cooks it. A save that would replace what another program wrote asks first.
- **Closing** a tab with unsaved changes asks to save them, and so does closing the editor. An open cutscene follows its file when the content browser moves or renames it.
- **New Cutscene,** in the content browser's menu and in the Gameplay tab's New Asset group, makes a cutscene of 10 s at 30 frames a second, with an empty camera cut track. It opens in its tab when the index has it. `--cutscene <file>` on the editor's command line opens one when the editor starts.

## The tab

- **Toolbar:**
  - Save, and Open in Script Editor;
  - the cutscene's length as timecode (`mm:ss:ff`) and as frames at its display rate;
  - the check's state: waiting for the cook daemon, cooking (before the first answer), cooks, or the count of errors ("does not cook" for an error on no line), with the error as its tooltip, and "not saved".
- **Timeline:** the bindings, tracks, sections, events and keys on one time axis (see [The timeline](#the-timeline)).
- **Details:** the primary selected block's fields, under the timeline:
  - its ID;
  - a binding's or a track's name;
  - a section's or a range's start and end;
  - a trigger's time;
  - a key's time, value and interpolation;
  - a marker's time, name and color;
  - the cutscene's length;
  - a row for each other setting, with a button that removes it;
  - a box that adds a setting as `name = value`.

  A time's name scrubs it a frame a pixel, ten frames with Shift and a frame every ten pixels with Ctrl, in one undo entry. Esc cancels the scrub. A typed value is one entry.
- **Esc** is Cancel (`edit.cancel`), a shortcut in the `cutsceneEditor` scope. While the keyboard is anywhere in the tab, the tab is the focused command scope (`CutsceneCancelScope`, see [Commands](shell-and-panels.md#commands)). Cancel cancels the first of these that is under way:
  1. a drag on the timeline, then one on the curves;
  2. a field's scrub;
  3. an armed pick of a binding's entity;
  4. in the timeline or the curves, whichever has the keyboard, a box, or else the selection.

  A text box, such as the search box or the time box, keeps its own Esc, except during a drag.
- **The Cinematics workspace** puts the Scene and the Game side by side over a dock for the asset editors' tabs, with the outliner on the left and the properties and the undo history on the right (see [Workspaces](shell-and-panels.md#workspaces)). In a layout with that dock, `EditorLayout.EditorDocumentsDock`, a cutscene, a graph or any other asset editor opens there and not beside the scene view. A workspace switch keeps the open tabs, in the new layout's editors' dock or beside its scene view.

## The timeline

`CutsceneTimeline` draws the cutscene. `CutsceneTimelineInput` turns its pointer, wheel and Esc into edits. The rest is pure code that tests call without a window:
- `CutsceneTimelineLayout`, in `Cinnabar.Editor.Tools`, makes the rows, culls them, merges keys and hit-tests;
- `TimelineSnap`, also in `Cinnabar.Editor.Tools`, snaps times;
- `CutsceneEdits`, in `Cinnabar.Editor.Document`, makes the edits.

### Rows

On the left is a header for each row, and on the right is the time area. Both scroll together.
- **The order:** the tracks that have no binding come first, as camera cuts, audio, events, presentation and sub-sequences. Then each binding has a row, with its tracks under it. Its fold arrow hides them.
- **A track's row** shows its sections, ranges and triggers, and the keys of all its sections. Its fold arrow shows a row for each channel name, with that channel's keys.
- **Glyphs:** keys and triggers closer than 2 pixels draw as one glyph, as the profiler merges zones.
- **A binding's header** shows whether it possesses or spawns, its name, the name of its entity or prefab, and a warning when that is not there (see [Bindings](#bindings)).
- **A track's header** shows its kind's color, its name, a mark when its lines have problems, and at its right end, mute (M), solo (S) and the lock.
- **A click on a header** selects the binding or the track, so the details edit its name and settings.

### The ruler

The ruler shows timecode (`mm:ss:ff`), or frames at the display rate with **Show Frames**. Its ticks use `TimelineGeometry.TickSpacing` in whole seconds where a second fits, and in whole frames below that (`FrameSpacing`). So every tick is on a frame, and a label is a round timecode.
- **The playhead.** A click or a drag on the ruler moves the playhead to a frame. The playhead belongs to the editor, so it is in no undo entry. It marks where Split, Home and End act, and the [preview](#preview) shows the world at it.
- **The range bar,** at the bottom of the ruler, is the part that plays: the cutscene's `range`. A drag of either end sets it. When the range is all of the length, the editor removes the setting.
- **The length.** The handle at the top of the ruler is the length. A drag sets `length`, but not to less than the end of a section, range or trigger, or a marker. Time past the length is shaded.
- **Markers** are flags in the top of the ruler, in their colors, with their names while they fit (see [Markers](#markers)). A flag is over the handles: a press on it selects its marker.

### Navigation

`TimelineView` is the profiler's view in any unit: a start, a time for each pixel, and the limits of its zoom (`TimelineZoom`). The timeline's unit is ticks.
- **Zoom and scroll.** The wheel zooms about the pointer, and with Shift it scrolls the time. The wheel over the headers scrolls the rows.
- **Pan:** a middle drag, or Alt and a right drag.
- **F** fits the selection, or the whole cutscene when nothing on the timeline is selected.
- **The playhead's keys.** **Home** and **End** move the playhead to the start and the end. **Ctrl+Left** and **Ctrl+Right** move it to the previous or next marker, or edge of a section, a range or a trigger.

### Selection

The selection uses the gestures of the node graphs.
- **A click** selects a section, a range, a trigger, a key glyph or a marker's flag. Shift adds, and Ctrl toggles.
- **A box:** a drag in empty space selects what the box covers.
- **To clear:** click in empty space, or press Esc.
- **The primary item** is the last one selected. The details show it.
- **Keys.** A key's path is its place in its channel, so another key can have it after an edit. An edit by the editor gives the selection the moved keys' new paths. Esc during a drag puts back the selection that the drag began with. After an undo or a redo, a selected key stays selected only if its path still holds the same line. A delete clears the selection.

### Edits

Each drag is one undo entry, through `Begin`, `StepFromStart` and `Commit`. Each step sets the blocks from where they were when the drag began, so steps do not add up. Esc during a drag cancels it, and the text and the undo stack stay as they were. During a drag, a tooltip shows the start, end, length and change in the ruler's units.

- **Move:** drag a body, a trigger, a key or a marker's flag. Everything selected moves.
  - A key moves inside its section, and everything stays inside the length.
  - A key moves with its section when both are selected.
  - A subtitle whose `audio` names an audio section moves with that section.
- **Trim:** drag an edge of a section or a range.
  - Keys keep their times on the cutscene's time, so a trim of a section's start changes the times of its keys.
  - A trim of the start also changes an animation's or a sound's `offset` (times `speed`) and a sub-sequence's `trim` (times `scale`). So the clip stays where it was. A sub-sequence section with no `trim` plays from the start of its child's range, so the editor reads the child's file for that start.
  - A section keeps its keys, its eases and blend in, and one frame at least.
  - A camera cut or sub-sequence section stops at its neighbours.
- **Slip:** Alt and a drag of a body. The edges stay and the source moves under them.
  - The source is an animation's or a sound's `offset`, or a sub-sequence's `trim`. It does not go below 0.
  - A drag to the right plays earlier source.
  - The other kinds have no source.
- **Ripple:** Shift and a drag of an edge. The section keeps its start, its length changes, and the sections after it on its track move by the same amount. **Ripple Delete** (Shift+Delete) deletes the selection and moves the later sections of each track back over the gap.
- **Split** (S) splits each selected section at the playhead.
  - The second half has the next section ID and starts where the first ends. Its keys move back by the cut, and its source starts later.
  - The second half takes the ease out, the blend out and the post roll. The first half keeps the ease in, the blend in and the pre roll.
  - Each channel gets a key at the cut in both halves, with the curve's value there as the runtime evaluates it ([The evaluator](#the-evaluator)). The new key has the interpolation of the key before it, or `auto` after a Bezier key, so a Bezier key's tangents are not kept. A channel of assets, whose keys the evaluator does not read, holds the key before the cut.
- **Delete** deletes the selected sections, events, keys and markers. When a channel loses its last key, the channel is deleted too. A subtitle whose audio section is deleted stays, but loses its `audio`, so that it does not name a section that is gone.
- **Nudge:** `,` and `.` move the selection one frame, and with Shift, 10 frames.
  - The repeats of a held key are one undo entry (`GraphDocument.EditMerged`). The release of the key ends the entry.
  - No entry stays open between repeats, so Save and Undo still run.
  - Nudges from the command palette merge until another edit.
- **Order:** sections and keys stay in start order in the text, as the cooker needs. When a section moves past another, it goes after it, with its comment. Markers stay in time order among the places that markers have in the text.

### Snapping and lock

- **Snapping** is on at first, and **N** turns it off and on. Ctrl during a drag turns it off for that drag.
  - A dragged time snaps to a target within 6 pixels: the playhead, the markers, the edges of the other sections and ranges, or the other triggers and keys. A dashed line shows the target.
  - With no target, the time snaps to a frame.
- **Lock.** The padlock in a track's header, or **Lock Track**, locks the track. No edit changes its sections, events and keys, but you can still select them. Markers are on no track, so no lock holds them. Locks belong to each user. They are in `cutscene-timeline.json` in the editor's settings, with Show Frames, mute and solo, for each cutscene.

### Markers

A marker is a named, colored point on the cutscene's time, such as a beat of the music or the start of a shot. It is in the asset as a `marker` block (see [Content: Cutscenes](../content/kinds/cutscenes.md#markers)), so every user sees it.
- **M** (**Add Marker**) adds a marker at the playhead, named "Marker" and its ID, and selects it. When a marker is at the playhead already, M selects that one.
- A new marker goes after the last marker in the text, or with none, before the first binding or track, so the header's settings stay above it.
- **A drag of its flag** moves it, as one entry that snaps and that Esc cancels. Nudge and Delete act on it too.
- **The details** edit its time, its name and its color (`#rrggbb`). An empty color is the default amber.
- A faint line in its color runs down the rows at its time.

### Copy and paste

The clipboard is the shell's, `EditorShell.CutsceneClipboard`, and the system's clipboard does not change. A copy pastes only into the cutscene that it came from, because its blocks name that cutscene's bindings by ID, as a camera cut's `camera` and a sub-sequence's `bind` do. A copy (`CutsceneEdits.Copy`) holds copies of the selected sections (with their channels and keys), triggers, ranges, keys and markers, their times, and for each, a copy of its track without its sections.
- **Copy** (Ctrl+C) copies. **Cut** (Ctrl+X) copies and then deletes, in one entry; a block on a locked track is copied but stays.
- **Paste** (Ctrl+V) puts the earliest copied time at the playhead, and keeps the times of the blocks to each other, in one entry. It selects what it pasted.
  - **Where:** with a track selected, or a block on one, a copy from one track of that kind goes onto that track. Otherwise each copied track's blocks go onto a track of its kind on the selected track's or binding's binding. With nothing selected, they go back onto the tracks they came from, or onto a track of the same kind on the same binding.
  - **Bindings, as the cooker wants them:** a camera cut, sub-sequence or presentation track takes no binding, so its blocks go onto the cutscene's own track of that kind. A transform, property or animation track needs one, so with a target that has none, its blocks stay on their own binding.
  - **A missing track:** when the target has no track of a copied kind, the editor asks (`PasteTracksRequested`). **Add Tracks** adds one like the copied track, on that binding, in the paste's entry. **Cancel** pastes nothing.
  - **IDs:** pasted sections, triggers, ranges and markers take new IDs. A pasted subtitle's `audio` names its pasted sound's new ID, or is removed when its sound was not pasted.
  - **Keys** go into the section of the target track that holds their new time, in the channel of their name, in place of a key at that time. A key with no such section or channel is left out.
  - A locked track takes nothing. When what is pasted ends past the length, the length grows to hold it.
  - A paste does not stop at a camera cut's or a sub-sequence's neighbours, as a move does not. So a pasted camera cut that blends in from gameplay, right after a cut, is a problem that the check reports.
- **Duplicate** (Ctrl+D) is the scene's Duplicate, which acts on the timeline while it has the keyboard. It pastes the selection onto its own tracks right after itself: it moves by the span from its earliest start to its latest end, or by a frame for a single point. The clipboard does not change.

### Search and filter

A strip over the timeline filters its rows. A filter belongs to the tab, and the editor does not save it. Every build of the rows takes it (`CutsceneRowFilter`), so hit tests, the edges of Ctrl+Left and Ctrl+Right, and F see the rows that are drawn.
- **The search box** filters by name as you type, ignoring case. A binding whose name has the text shows all of its tracks. A track whose name has the text shows with its binding. **Ctrl+F** (**Find Track**) puts the keyboard in the box, and Esc there clears it and gives the keyboard back to the timeline.
- **Keys under selection,** the strip's toggle or the **Keys Under Selection** command, shows only the tracks that have a key between the earliest start and the latest end of the selection. It keeps the span that the selection had when it was turned on, so a click in the filtered rows does not change which rows there are. With nothing selected, it hides nothing.
- **The selection.** When a filter hides a track, what is selected on it leaves the selection, so Delete never acts on what is not in view.

### Mute and solo

The **M** and **S** buttons in a track's header, and **Mute Track** and **Solo Track**, mute and solo the track for this user. They change no file but `cutscene-timeline.json`, so they do not dirty the cutscene.
- `CutsceneEditor.Audible(track)` says whether the preview plays a track. It does not when the user muted the track, or when the user soloed other tracks and not this one. The tracks that it silences go to the game in the preview's mix (see [The game's side](#the-games-side)), and a silenced track writes, plays and cuts to nothing there, as a muted one does.
- A track whose asset sets `muted = true` plays in no preview and no game. Its M is struck through, and a press on it does nothing: edit the setting to change it.
- A track that is not audible draws its sections grey, which differs from a locked track's faint colors.

### Keys

Each action is a command, so it is in the command palette, and `keybindings.json` can change its key. None of them is in the ribbon.
- **The timeline's keys are bare letters,** which the viewport and the other panels also use. So they are shortcuts of the `cutsceneTimeline` scope, which only the timeline and the curve editor have (see [Commands](shell-and-panels.md#commands)), and the cutscene editor takes the commands as a command scope (`CutsceneEditor.Handler`). Each acts only while one of the two panes has the keyboard, or while the command palette opened from one of them has it. When another window, such as a floating panel, becomes active, neither has the keyboard. Which pane has it is one value, `CutsceneEditor.KeyboardPane`, which each pane's `FocusFollower` sets.
- **Frame Selection and Delete** act on the pane that has the keyboard: in the curve editor, F frames the curves and Delete deletes the selected keys.
- **Delete and Duplicate.** While the timeline has the keyboard, the scene's Delete deletes the timeline's selection, and its Duplicate duplicates it. The cutscene's tab takes them as a command scope (see [Commands](shell-and-panels.md#commands)).
- **Copy and paste.** The timeline's copy and paste take Ctrl+C, Ctrl+X and Ctrl+V only in the two panes, so a text box keeps them. In a pane, a key whose command cannot act now does nothing, and does not reach the window.
- **Keying.** Key Transform and Key Tracked Fields act on the selected entities wherever the keyboard is (see [Keying](#keying)). K is Shuttle Pause, so they use Ctrl+K and Ctrl+Shift+K.

| Command | ID | Key |
|---|---|---|
| Frame Selection | `cutscene.frame` | F |
| Go to Start, Go to End | `cutscene.goToStart`, `cutscene.goToEnd` | Home, End |
| Previous Edge, Next Edge | `cutscene.previousEdge`, `cutscene.nextEdge` | Ctrl+Left, Ctrl+Right |
| Split | `cutscene.split` | S |
| Delete | `entity.delete` | Delete |
| Ripple Delete | `cutscene.rippleDelete` | Shift+Delete |
| Nudge Earlier, Nudge Later | `cutscene.nudgeEarlier`, `cutscene.nudgeLater` | `,` and `.` (`OemComma`, `OemPeriod`) |
| Nudge Earlier 10 Frames, Nudge Later 10 Frames | `cutscene.nudgeEarlier10`, `cutscene.nudgeLater10` | Shift+`,`, Shift+`.` |
| Snap | `cutscene.snap` | N |
| Show Frames | `cutscene.showFrames` | None |
| Lock Track | `cutscene.lockTrack` | None |
| Mute Track, Solo Track | `cutscene.muteTrack`, `cutscene.soloTrack` | None |
| Add Marker | `cutscene.addMarker` | M |
| Copy, Cut, Paste | `cutscene.copy`, `cutscene.cut`, `cutscene.paste` | Ctrl+C, Ctrl+X, Ctrl+V |
| Duplicate | `entity.duplicate` | Ctrl+D |
| Find Track | `cutscene.find` | Ctrl+F |
| Keys Under Selection | `cutscene.keysUnderSelection` | None |
| Play/Pause | `cutscene.playPause` | Space |
| Step Back, Step Forward | `cutscene.stepBack`, `cutscene.stepForward` | Left, Right |
| Step Back 10 Frames, Step Forward 10 Frames | `cutscene.stepBack10`, `cutscene.stepForward10` | Shift+Left, Shift+Right |
| Shuttle Back, Shuttle Pause, Shuttle Forward | `cutscene.shuttleBack`, `cutscene.shuttlePause`, `cutscene.shuttleForward` | J, K, L |
| Set In, Set Out | `cutscene.setIn`, `cutscene.setOut` | I, O |
| Clear In and Out | `cutscene.clearInOut` | Alt+X |
| Loop | `cutscene.loop` | Ctrl+L |
| Previous Key, Next Key | `cutscene.previousKey`, `cutscene.nextKey` | Up, Down |
| Go to Time | `cutscene.goToTime` | Ctrl+G |
| Scrub Sound | `cutscene.scrubSound` | Alt+S |
| Events in Preview | `cutscene.previewEvents` | Alt+E |
| Key Transform | `cutscene.keyTransform` | Ctrl+K |
| Key Tracked Fields | `cutscene.keyTrackedFields` | Ctrl+Shift+K |
| Curve Editor | `cutscene.curves` | Ctrl+E |
| Normalized Curves | `cutscene.curvesNormalized` | Alt+N |
| Auto Tangents, Unify Tangents, Break Tangents | `cutscene.tangentAuto`, `cutscene.tangentUnify`, `cutscene.tangentBreak` | 1, 2, 3 (`D1`, `D2`, `D3`) |
| Linear, Constant, Flatten Tangents | `cutscene.tangentLinear`, `cutscene.tangentConstant`, `cutscene.tangentFlatten` | 4, 5, 6 (`D4`, `D5`, `D6`) |
| Weighted Tangents | `cutscene.tangentWeighted` | 7 (`D7`) |
| Next Pre-Infinity, Next Post-Infinity | `cutscene.preInfinity`, `cutscene.postInfinity` | 8, 9 (`D8`, `D9`) |
| Value Snap | `cutscene.curveValueSnap` | Alt+V |
| Reveal in Content Browser | `cutscene.revealClip` | None |
| Open Clip | `cutscene.openClip` | None |
| Match Clip Length | `cutscene.matchClipLength` | None |

### Cost

A redraw reads only the draw list that `CutsceneTimelineLayout.Visible` gives: the rows in view, and the items in view in each row. It finds the keys with a binary search. Each bar's label, and its clip's name and length from the index, are found when the rows are built, not when they draw. A clip's loop marks are made only for the part in view. `CutsceneFile` keeps an index of its blocks by path, which a change of a keyword line or of the tree drops, so a lookup of a selected path does not search the file.

A test with 50 tracks and 5,000 keys checks two times:
- the draw list takes less than 4 ms;
- a drag's step takes less than 50 ms. A step reads the text again, edits it, and builds the rows again, through a search filter that keeps every row.

The test does not measure Avalonia's drawing.

## Sections

An animation or audio section shows what plays in it, so a designer can time to it without playing. `CutsceneTimelineLayout` finds what each bar shows when the rows are built, and its pure helpers, which tests call, place the marks: `Hints`, `ClipMarks`, `LabelRoom`, `Overlaps` and `Handles`.

### Labels

- **The name.** An animation section shows its clip's name in its model, and an audio section its sound's file name. A section whose clip is not in the index shows its ID, as other sections do.
- **The visible part.** A label starts 4 pixels into the part of its bar in view, so a section that starts off screen still shows its name. It is clipped to that part, and a part narrower than 16 pixels shows no label.

### Lengths

The daemon's index has a sound's and an animation clip's length in ticks, from its cooked blob (see [Daemon and operations](../content/daemon-and-operations.md#cook-daemon)). `AssetIndex.LengthOf` gives it, or null when there is none: before the asset has cooked, and for a clip of one pose, whose length is 0. A clip with no length shows its name, but no loops and no hints.

### Loops and hints

The clip's time at a time t on the cutscene is `offset + (t - start) × speed`. An audio section's speed is 1.
- **Loops.** A section with `loop = true` has a mark at each point where its clip starts again. Marks closer than 2 pixels draw as one band.
- **The clip's end.** A section with no loop that is longer than what is left of its clip has a dashed line where the clip ends. The rest of the bar is darker: there, the pose holds, or the sound is silent.
- **Hints.** A faint bar past each edge shows the part of the clip's pass that the section cuts off: before its start, back to the start of that pass, and after its end, on to the end of that pass. With no loop, the hint before the start is the part of the clip before its `offset`.
- **Pitch.** A sound's `pitch` channel changes its rate over the section, so an audio section with one shows no loops and no hints. Match Clip Length does not act on it.

### Eases and blends

- **Ramps.** Each section but a camera cut draws its `ease_in` and `ease_out` as ramps of the runtime's smoothstep shape (see [Cinematics: Evaluation](../cinematics/evaluation.md#sections-and-blending)). An audio section's eases are its fade in and fade out.
- **Handles.** A small square at the top of the bar marks each ease's end: the ease in's at its start and its ease in, the ease out's at its end less its ease out. In the top 9 pixels of a row, a handle is nearer than a key or an edge, so a key at the end of an ease does not take its handle. A bar narrower than 15 pixels has no handles.
- **A drag of a handle** sets its ease, as one undo entry that snaps and that Esc cancels. Its tooltip shows the ease. The ease is clamped to 0 and to the section's duration less its other ease, as the cooker needs, and 0 removes the setting. A locked track's handles do not move.
- **Blends.** Where two sections on a track overlap, the overlap is darker, and the earlier section's ease out and the later one's ease in, across it, are the blend's curve. Their handles are at the two ends of the overlap when both eases are 0. A drag of either one to the overlap's other end, which is a snap target, makes a crossfade whose weights sum to 1.
- **Camera cuts** have no eases: their `blend_in` and `blend_out` blend with gameplay, and the details edit them.

### Drops

An animation clip or a sound dropped from the content browser adds a section at the drop's time, snapped as a drag is, with the clip's length. A clip that has not cooked yet has no length, so its section is a second long.
- **An animation** goes on the animation track of the binding under the pointer, on the binding's row or on one of its tracks' rows. The drop adds the track, after the binding's tracks, when the binding has none. Elsewhere, an animation has no binding to play on, and the drop is refused.
- **A sound** goes on the audio track under the pointer. On a binding's rows, it goes on that binding's audio track, which the drop adds when there is none, so the sound plays at the entity. Elsewhere, it goes on the first audio track of no binding, which the drop adds when there is none.
- **Several clips** go one after another, from the drop's time. A model file is not a clip: it spawns its prefab, as before.
- The drop is one undo entry, and it selects the new sections. A section goes among its track's sections in start order, and the length grows when the section ends past it. A locked track takes nothing.

### The section menu

A right click on an animation or audio section selects it, unless it is selected already, and opens its menu. Alt and a right drag still pans.
- **Reveal in Content Browser** shows the section's clip or sound in the content browser. A clip shows in its model.
- **Open Clip** shows it, and opens it as the content browser does. Animations and sounds have no editor or preview yet, so for now it only shows and selects them.
- **Match Clip Length** trims the end of each selected animation or audio section that does not loop to where its clip ends: `(length - offset) / speed` after its start. It is one undo entry, and it keeps the trim's limits: the keys, the eases, a frame and the length.

## Preview

In Edit, the game shows the tab's cutscene in the world at the playhead, outside the document. Scrubbing, playing and stepping never edit a scene: they make no undo entry, and no scene becomes dirty.

### The unsaved text

Each committed edit sends the unsaved text to the cook daemon with `Cook_Preview`, through `PreviewCook`. `PreviewCook` waits 250 ms after the last edit, so at most four checks go each second, and it runs one at a time. A drag's steps are not sent: its end is the edit. The daemon's `cutscene_check` reports what a cook of the text would report:

- the text's own problems;
- the assets that it names, against the daemon's index, sub-assets such as clips included;
- its sub-sequences' cycles, depth, trims and binds, with the other cutscenes' sources on disk and the unsaved text in place of this cutscene's own.

The answer's problems are on their blocks by line. An answer about a text that has changed since it was sent is dropped, because its lines are old.

A text without problems goes in the cache's preview area, `<cache>/dev/preview/<guid>.blob`, which the preview plays. A text with problems leaves the last good one there. The cutscene's own blob does not change until it is saved and cooked.

### The session

`EditorShell.CutscenePreview` holds the preview's session. Its state is one value, `CutscenePreviewState`, which only `Become` changes (see [State with a lifecycle](../overview/conventions.md#state-with-a-lifecycle)):

| State | What it holds |
|---|---|
| `Closed` | Why the game ended the last session, or nothing, and the rate at which the next session plays at once, or nothing. |
| `Opening` | The ticket and the tab. The editor sent `Cutscene_Preview_Open` and waits for `Cutscene_Preview_Opened`. |
| `Open` | The ticket, the tab, the cutscene's range, and its transport: `Paused`, or `Playing` at a rate. |

- **One preview at a time.** `Owner` is the tab that holds the preview. It is apart from the state, so it outlives a session. A tab that becomes active takes the preview when no session is live. Another tab shows "preview inactive" and a **Preview here** button, which takes it.
- **Tickets.** Each `Cutscene_Preview_Open` has a new ticket, which only goes up. The game drops a message with an older ticket, and the editor drops an answer to a ticket that is not its session's. A new Open ends the session before it, in the game too.
- **The unsaved text.** An Open says `unsaved` once the tab's text has cooked clean. The game then plays the blob in the preview area, and follows a newer one there at the same time. The first clean cook of a session that played the saved blob opens a new session that plays the unsaved one.
- **Ends.** Closing the tab sends `Cutscene_Preview_Close`. Play, a lost link and a new game state end the session without a message, because the game ends it itself. The game sends `Cutscene_Preview_Ended` when it cannot open the session (`Not_Editing`, `Failed`), at a mode change (`Mode`), when the editor's scene loads (`Scene_Loaded`) and at a code reload (`Code_Reloaded`).
- **The mix.** Each `Cutscene_Preview_Open` is followed by `Cutscene_Preview_Settings` with the same ticket: the scrub sound, the events, and the tracks that [mute and solo](#mute-and-solo) silence. The game forgets them with the session, and messages are in order, so the game has them before the session's first frame. A change of any of them, or a committed edit, sends them again.
- **Opening again.** After a load or a code reload, the editor opens the session again at once. Each time the editor sends its scene (`Load_Scene`), a closed session opens again for the owner at the playhead: after Stop, in `OnNewGameState`, and when a scene opens, so a session that the game refused without a scene opens with the scene. A session that played when the link or the game state went plays again, at its rate. During playback the playhead is the last tick that the game reported, so a reconnect goes on from there. A scrub or a step while a session opens again keeps it paused.

### Scrub, play and step

- **Scrub.** A move of the playhead by the editor sends `Cutscene_Preview_Time` at most once a frame, with the latest tick. The view calls `Flush` from `RequestAnimationFrame`. The game shows that time in the same frame. A scrub pauses playback.
- **Play.** Space sends `Cutscene_Preview_Play` from the playhead at the rate in the toolbar's box, 0.1× to 4×. From the end that it plays toward, it starts at the other end. The game owns the clock: it moves the time by each frame's real time at the rate, and sends `Cutscene_Preview_Tick` in each poll. The editor draws the playhead from the tick and does not wait for it. At the range's end the game stops, and sends one tick with `playing` false. Space again pauses at the playhead.
- **Shuttle.** L plays forward at 1×, and each press doubles the rate, up to 8×. J does the same backward. A press the other way starts again at 1× that way. K pauses. While K is held, L and J step one frame on or back. Commands fire on a key's press, so K sets `CutsceneEditor.ShuttleHeld`, and the timeline clears it at the release of Shuttle Pause's key, as `keybindings.json` has it, or when it loses the keyboard.
- **Loop.** I and O set an in and an out point at the playhead, and **Clear In and Out** clears them. The ruler shows the span between them. **Loop** plays that span again and again, or the cutscene's range without the points. The points go in time order, whichever is set first, and a span with no length does not loop. A change of the points or the loop while the preview plays sends the play again from the playhead at its rate. The game wraps with a seek, which moves each voice to its new place on the audio's clock, so the sound restarts at the loop's start without a click. The points and the loop are the tab's, and the editor does not save them.
- **Step.** Left and Right move the playhead one frame, and Shift moves it 10 frames. Up and Down move it to the previous or the next key, or edge of a section, a range or a trigger, on the selected tracks, or on every track that the filter shows when no track is selected. A folded binding's tracks count. A step pauses playback.
- **Follow.** While the preview plays, the timeline pages when the playhead leaves it: forward, the playhead starts again near the left edge, and backward, near the right one. A pan or a zoom by hand stops it until the next play.
- **Typing a time.** A click on the playhead's time, or **Go to Time**, shows a box. It reads timecode, `[[hh:]mm:]ss:ff`, or a count of frames, `120` or `120f`, at the cutscene's rate (`CutsceneTime.TryParse`). Enter moves the playhead there, and Enter or Esc gives the keyboard back to the timeline. The time always shows the frame that is drawn, from the integer playhead.
- **Sound.** While the preview plays, its audio tracks play. While it is scrubbed, they play short grains under the playhead (see [Tracks: Audio tracks](../cinematics/tracks.md#audio-tracks)). **Scrub Sound** turns the grains off and on.
- **Events.** **Events in Preview** sends the event tracks' events while the preview plays. A scrub or a step never sends them. They go where a player's go: to the behaviours' `on_<name>`, which in Edit only the behaviours that run in edit mode get, in the next edit phase, and to the game's native handlers (`register_event_handler`), at once. What a handler changes is not the preview's to give back when it ends, so the toggle is off at first.
- **Each user's.** The scrub sound and the events are each user's, for each cutscene, in `cutscene-timeline.json` with the locks, mutes and solos. The play rate is the tab's.
- **The frame counter.** While a session is open, the Game view shows the playhead's timecode and frame and the shot there at its bottom left: the camera of the cutscene's own camera cut section over the time (`CutsceneTimelineLayout.ShotAt`), or "gameplay". A sub-sequence's own cuts show as "gameplay" there.

### The game's side

`lib/engine/editor/cutscene_preview.odin` holds the open preview in the editor's `Session`. It loads the cutscene with `cutscene.open_live`, as a player loads one, but without a player's slot and without its hold on gameplay. It pushes no input context, hides no UI, and suspends no systems on the bindings (`Player_Context.preview`). It evaluates the cutscene with `seek` and `evaluate`, as a scrub does (see [Evaluation](../cinematics/evaluation.md)).

- **A layer with the overrides.** The preview's writes are one more layer with the [overrides](link.md#overrides). `lift_overrides` puts them back with `cutscene.lift`, which keeps the drives, the camera cut's claim and the voices. `lay_overrides` evaluates the preview again at its time. So poll, the edit-mode behaviours and what the game sends the editor see the document. A scene edit of a field that the preview writes goes to the document, under the preview.
- **Values over the preview.** `Cutscene_Preview_Values` lays the editor's [preview values](#preview-values) over the preview, after its evaluation in `lay_cutscene_preview` and again in `update_cutscene_preview`. They are an `Override`'s fields and poses, which save what they write over once, so the lift gives back the document, also of a field that no track writes. They show only while the preview is paused at their tick. A `Time`, a `Play`, a `Close`, a new ticket and `end_overrides` drop them, so a lost message from the editor cannot leave them at another time. Their fields are in `Entity_Values.held`, and `shown_preview.values` names their serial while they show.
- **The frame.** In Edit, `update_cutscene_preview` runs once a frame after the players. It follows a newer unsaved blob and a reload's bindings, moves a playing preview by the frame's real time, and evaluates it. Forward play moves as a player's clock does, so camera cuts blend.
- **The mix.** `Cutscene_Preview_Settings` calls `cutscene.set_mix` (see [Evaluation: The editor's mix](../cinematics/evaluation.md#the-editors-mix)). A silenced track evaluates as a muted one: it writes no field, so the next lay leaves the document's value; it plays no voice and drives no `Animator`; and a silenced camera cut track gives the views back. A silenced sub-sequence track plays no child, though the child stays loaded. With events on, `update_cutscene_preview` sends the events that a play crossed in the same frame, with `cutscene.send_events`.
- **Marks.** The bound entities and the spawned ones are in `Overridden_Entities`, so the Outliner marks them. The fields that the preview writes are in `Entity_Values.held`.
- **Ends.** `end_overrides` ends the preview with the overrides: at `Set_Mode`, `Load_Scene`, a code reload and a new link. `close_live` restores what the tracks wrote, despawns the spawned entities and unloads the assets. A new game state frees the preview without the world.

## Keying

A designer poses the world in the viewport and the inspector, and keys it. A key from the inspector or the viewport goes into the cutscene that holds the preview (`CutscenePreview.Owner`), at its playhead, as one undo entry in the cutscene's text. The scene does not change. `Keying` in the shell does the work, and `CutsceneKeying`, in `Cinnabar.Editor.Document`, makes the text's edits.

### The key button

While a cutscene holds the preview in Edit, the properties panel shows a key button after each field that a track can animate, on an entity that a binding possesses. The binding's `possess` names the entity's scene by its GUID and the entity by its scene ID, as `@<guid>/<id>`. A spawned binding's entity cannot be selected, so it has no buttons. The fields are:
- a root's `Transform` and a child's `Local_Transform`: position (or offset), rotation and scale, which a transform track keys;
- the other fields of a number, a bool, an integer, an enum, a `[2]f32`, a `[3]f32` or a color, which a property track keys. An `f64`, an entity, an asset and a read-only field have none.

The button has four states at the playhead:

| State | Shows |
|---|---|
| No track animates the field. | ◇, dim |
| A track animates it, with no key at the playhead. | ◇ |
| A key at the playhead holds it. | ◆, red |
| A key is at the playhead, and the world shows another value. | ◆, amber |

A click keys the field's value at the playhead, and adds its track when it has none. The playhead, an edit of the cutscene, the preview and the game's values change the buttons in place, without a build of the panel. A right-click on the field's name or on its button gives **Add Track**, **Key**, **Remove Key** and **Go to Track**, after an instance's Apply to Prefab and Revert. Go to Track shows the cutscene's tab and selects the track, with its binding unfolded and the filter cleared when it hides the track.

### What a key holds

A key holds what the world shows. The game lays the preview and the overrides over the document, so a field that one of them holds shows another value than the document's. The game sends that value too: for an entity with a held field, `Entity_Values.shown` has its components as the world shows them, with the preview's ticket and time (see [Link: World](link.md#world)). A field that nothing holds is keyed at the document's value.

The world's values come at most twenty times a second, and they are taken before a poll, so they come a little after the playhead moves. So a held field keys only with values that are fresh:
- the preview is this cutscene's, and it is paused: "Pause the preview to key" while it plays;
- the values' ticket is the session's, and their time is the playhead, or past the cutscene's range, its end, where the game holds the time: "Waiting for the preview to show the playhead" until they come;
- the world shows the tab's text: in a session that plays the unsaved text, the values name the blob that the daemon wrote for the text as it is now (`CutsceneEditor.CleanBlob`, the blob's file time in the preview area), and in a session that plays the saved file, the text is not changed. Otherwise "Waiting for the preview to show the cutscene's last edit", so a key never takes back an edit that the preview does not show yet.

A refused key disables the button, and its tooltip says why. The warning state needs fresh values too. Without them, a key at the playhead shows as keyed.

### Where a key goes

- **The track:** for a property, the binding's property track with the field's `component` and `field`. For a pose, the binding's last transform track. When there is none, the key adds one after the binding's last track: a property track named for the field, or a transform track named "Transform", which is relative.
- **The section:** the last section over the playhead that is not additive. When the track has none at all, a new section over the cutscene's length. Otherwise the nearest section grows to the playhead, as a trim does, so its keys keep their times on the cutscene's time.
- **The channels:** `value`; `x` and `y`; `x`, `y` and `z`; `r`, `g` and `b` for a color; or a transform track's `position_*`, `rotation_*` and `scale_*`. A section that names a vector's or a color's channels the other way keeps its names. A missing channel goes after the section's channels.
- **The key:** a key at the playhead's time takes the new value and keeps its interpolation. A new key is `auto` for a number, a vector, a color and a pose, and `constant` for a bool, an integer and an enum, which step. Its value is the shortest text that reads back as the same `f32`. An integer over 2^24, or a value that is not finite, is refused.
- **A transform track's space** (see [Tracks: Transform tracks](../cinematics/tracks.md#transform-tracks)):
  - **Relative:** the keys are the pose from the binding's own pose, which is the document's: the position's offset in the own rotation's axes, in meters, and the rotation after the own one. The scale is the world's.
  - **Absolute:** the keys are the world's pose from the track's `origin`. The first position key of a track with no `origin` sets it to the whole meters nearest the entity, so the cooker's units are exact, however far from the world's origin.
  - **Relative to another binding:** refused, as the other binding's pose is not watched.
- **Rotation:** each angle moves by whole turns to its key next to it, so the curve turns the short way. The warning compares rotations as rotations, so a whole turn is the same.
- **Remove Key** removes the field's keys at the playhead, and a channel that loses its last key.

### Commands

| Command | Key | What it keys |
|---|---|---|
| **Key Transform** (`cutscene.keyTransform`) | Ctrl+K | the position, rotation and scale of each selected entity that a binding possesses |
| **Key Tracked Fields** (`cutscene.keyTrackedFields`) | Ctrl+Shift+K | each field of the selected entities that a property track animates, and the parts of the pose that the transform track keys |
| **Auto-Key** (`cutscene.autoKey`) | Alt+K | turns [auto-key](#auto-key) on or off |
| **Auto-Key: Add Tracks** (`cutscene.autoKeyAddTracks`) | Alt+Shift+K | lets auto-key add the track of a field that has none |
| **Key Preview Values** (`cutscene.keyPreviewValues`) | Enter | the [preview values](#preview-values) at the playhead |

Each key is one undo entry for all the selected entities. They act wherever the keyboard is, in the viewport, the timeline and the inspector, so K stays the timeline's Shuttle Pause. A text box keeps its own Enter, as no shortcut fires while one has the keyboard. Like the timeline's commands, they are not in the ribbon.

### Undo

A key is in the cutscene's history. While the cutscene's tab or another editor's tab is active, Undo and Redo act on that tab, as always. While no such tab is active, as when the viewport has the keyboard, they act on what was edited last (`EditorShell.LastEdited`):
- a committed scene edit makes it the scene;
- a key makes it the cutscene.

So Ctrl+K and then Ctrl+Z in the viewport takes the key back, and a second Ctrl+Z takes back the cutscene's entry before it. Redo goes the same way. The cutscene's tab closing, or another tab taking the preview, makes it the scene again. Only these two edits set it, so an edit in the cutscene's tab, which is active then, does not.

### Where an edit goes

While a cutscene holds the preview in Edit, an edit of a field of an entity in the properties panel, or a gizmo drag in a scene view, can go to the cutscene and not to the scene. `Keying.Route` decides, as a `FieldRoute`:

| Route | When | What the edit does |
|---|---|---|
| `Scene` | No cutscene holds the preview, or nothing holds the field and auto-key does not key it | A scene edit, as always |
| `Preview` | The preview or values over it hold the field, and auto-key is off | Sets a [preview value](#preview-values) |
| `Key` | [Auto-key](#auto-key) is on, and the field has a track, or **Auto-Key: Add Tracks** is on | Keys the field at the playhead |
| `Refused` | The field is held, but the preview plays, its values are not fresh, its track is locked, a drag is under way in the cutscene, or no track can key it | Nothing. The console says why. |
| `Possess` | Auto-key and Add Tracks are on, and no binding possesses the entity | Nothing. The edit, or a gizmo's press, asks whether to possess it (see [Possessing](#possessing)). |

**A field that the preview holds never goes to the scene.** It goes to the cutscene, or nowhere with a reason, so a change is never lost and never written to the scene without a word. Reset, Override, Stop Overriding and Apply to Prefab are always scene edits.

The rows of a held field show what the world shows, from `Entity_Values.shown` with the preview values over it (`Keying.ShownComponent`), and the field's name is in italics, with a tooltip that says where its edits go. A drag or a typed value starts from that value. A row of a field that nothing holds shows the document's value, which is what the world shows too.

`FieldEditor` sends each edit that sets a value through one seam: its `FieldSink`, which the properties panel gives each component field's editor, and the scene when the sink says `Scene`. A drag opens an `IFieldEdit`: the scene's `SceneEdit`, or a drag of preview values or of keys. `ScrubSession` and `GizmoController` take either.

### Preview values

A change to a held field with auto-key off is a preview value. `EditorShell.PreviewValues` holds them, as one `PreviewValuesState`, which only `Become` changes:

| State | What it holds |
|---|---|
| `Empty` | Nothing. |
| `Holding` | The session's ticket, the tab, the playhead's tick, a serial, the set fields, and each set field's component's bytes with them written, from what the world showed before the first. |
| `Settling` | The same, with the text that keyed them. |

- **The world shows them.** Each change sends `Cutscene_Preview_Values` with a new serial. The game lays them over the preview, so they show in the viewport in the next frame. The scene does not change.
- **The key button.** The button compares its key with the value, so it shows amber. A click keys the field at the value.
- **Enter.** **Key Preview Values** keys every held value at the playhead, as one undo entry. The values then wait in `Settling` until the preview shows a blob cooked from the keyed text, so the world does not show the old curve while the daemon cooks it.
- **Drops.** A move of the playhead, another session, another owner, a play, a lost link and a new game state drop them, through the one writer, `Follow`, which `Keying.Raise` calls. The world shows the curve again, and nothing was written.
- **Fresh values.** A key from the world's values waits until they name the values: `shown_preview.values` must be 0 with none, or one of the serials since the state left `Empty`. Values of the editor's own are read from its bytes, so they need no word from the game.

### Auto-key

**Auto-Key** (Alt+K) turns each edit of a field of a bound entity, from the properties panel or a gizmo, into a key at the playhead. A field that has no track gets one only with **Auto-Key: Add Tracks** (Alt+Shift+K); without it, its edit goes to the scene, as the cutscene does not animate it. While auto-key is on and a cutscene holds the preview, a red border goes round the scene views and the cutscene's timeline.

- **A typed value** is one undo entry, which keys the value. The value shows over the preview at once, and stays until the preview shows the key.
- **A drag** is one undo entry in the cutscene from its press to its release, through `CutsceneEditor.BeginDrag` and `StepDrag`, with each step from the drag's start. The cutscene does not cook a drag's steps, so each step shows as a preview value. Esc cancels the drag: the text and the values go back as they were, and nothing goes on the undo stack.
- **Keys are computed in the editor**, from the edited value, so a drag does not wait for the game's values. A key of a child's pose in an absolute track, or one relative to another binding, needs the world's composed `Transform`, so it waits until the world shows the values.
- Auto-key is the session's, not saved.

### Gizmo keys

A gizmo drag of selected entities whose pose the cutscene holds goes to the cutscene, as a field edit does: preview values, or with auto-key, keys. `Keying.PoseRoute` routes each selected entity's position, and the entities must agree. A mix of entities whose drags go to the scene and to the cutscene is refused. The drag starts from the pose that the world shows (`Keying.ShownWorldPose`), and the gizmo stands there, not at the document's pose. `PoseEdit` takes that pose as its start. The drag is one undo entry, and Esc cancels it.

### Possessing

An entity that no binding possesses, in a scene that the cutscene can name by its GUID, has an empty key button. A click asks whether to possess it (`Keying.AskPossess`, which the main window answers with a dialog). **Possess** adds a binding, `possess = @<guid>/<id>`, named after the entity and made unique, after the last binding, and then its track and its key, all as one undo entry. **Cancel** changes nothing. **Key Transform** asks the same for the selected entities that no binding has, and keys them all.

With auto-key and add tracks on, an edit or a gizmo drag of such an entity asks once (`FieldRoute.Possess`). A yes adds the binding, as an undo entry of its own, and the edit is refused, so the next one keys. A no is remembered for the tab, and the entity's edits go to the scene.

### Several entities

With several entities selected, a field that a track can key for each of them, or that possessing would let it key, has one key button. It shows their state when they agree, and otherwise a track's, with a tooltip that says their keys differ. A click keys the field of each, adding tracks where they have none, as one undo entry; Remove Key removes each one's keys at the playhead. The rows' edits route as one: the entities must agree.

### Relative to another binding

A transform track whose space is `relative <id>` keys the world's pose in the other binding's `Transform`, the inverse of the engine's `track_frame`: the position is the difference in units, in meters, in the other's axes, and the rotation comes after the other's. While a cutscene holds the preview, `Keying` watches each entity that its tracks are relative to (`EditorShell.Watch`), and lets it go when the cutscene gives the preview away or its tab closes. The other's pose is the document's, or what the world shows when the preview holds it, with the same freshness. A spawned binding, or one whose scene is not open, has no entity in the editor, so its tracks refuse keys with the reason. A space that names no binding, or the track's own, refuses them too.

### Limits

- After a key's value changes, the warning can show until the daemon cooks the text and the preview follows it.
- A preview value of a child's pose in an absolute track, or one relative to another binding, keys once the world shows it, at most 20 times a second.
- A possess names an entity by its scene's asset GUID and its folded scene ID. An entity of a sublevel's part, which a binding names by the part's GUID, has no key button, as the editor does not name it by its part yet.
- Auto-key asks to possess an entity at an edit or a gizmo's press, never while it only routes one, and not while another question is open.

## Bindings

A binding names what the cutscene's tracks act on (see [Cinematics: Bindings](../cinematics/bindings.md)). It is one of three kinds: an entity of a scene that it possesses, `possess = @<guid>/<id>`; a prefab that it spawns for the cutscene, `spawn = $<guid>`; or a script slot, `provided = true`, whose entity a script gives when it plays the cutscene. Each binding is a row of the timeline, with its tracks under it. The edits are in `CutsceneBindings`, in `Cinnabar.Editor.Document`. The editor's side is in `CutsceneEditor`.

### A binding's row

The header shows these items:
- a dot for a possessed entity, a ring for a spawned prefab, or a square for a script slot;
- the binding's name;
- the name of its entity or prefab, or of a slot's stand-in, when that name is different.

`CutsceneEditor.InfoOf` gives each binding's kind, the name of its entity or prefab, and its state. `CutsceneTimelineLayout.Build` puts them on the row.

| State | When | The header |
|---|---|---|
| Bound | The open scene has the entity, or the index has the prefab. A slot with no stand-in is bound. | The name of the entity or prefab |
| Not loaded | The entity's scene is not open in the editor | An amber mark |
| Broken | One of these: the open scene does not have the entity; no scene has the GUID; the index has no such prefab; a slot's stand-in is missing; the binding has none of `possess`, `spawn` and `provided`, or more than one | A red mark |

The pointer on a marked header shows the reason. The state comes from the scene documents and the asset index, not from the game. Thus it shows when the game is not connected. The rows change when a scene opens, closes or changes, and at each asset snapshot. Before the cook daemon sends its first snapshot, these rules apply:
- a binding whose scene is not open shows as not loaded;
- a spawned binding shows as bound, with no name.

### Possess and spawn

| Command | Key | What it does |
|---|---|---|
| **Add Binding: Selected Entities** (`cutscene.addBindingSelected`) | Ctrl+Shift+B | Adds a binding for each selected entity that no binding possesses yet |
| **Rebind to Selection** (`cutscene.rebindToSelection`) | | Points the selected binding at the primary selected entity |
| **Show Selected Entities' Bindings** (`cutscene.filterSelected`) | | Shows only the bindings of the selected entities (see [Selection sync](#selection-sync)) |
| **Add Binding: Spawn Prefab…** (`cutscene.spawnPrefab`) | | Opens the prefab picker, and adds a binding that spawns the prefab that you pick |
| **Add Binding: Script Slot** (`cutscene.addSlot`) | | Adds a script slot with the name Slot (see [Script slots](#script-slots)) |
| **Convert Binding to Possessed**, **to Spawned** and **to Script Slot** (`cutscene.convertToPossessed`, `cutscene.convertToSpawned`, `cutscene.convertToSlot`) | | Converts the selected binding (see [Convert](#convert)) |
| **Pick Binding's Entity** (`cutscene.pickBinding`) | | Arms a pick, or cancels it (see [Rebind and delete](#rebind-and-delete)) |
| **Stand In Selection** (`cutscene.standInSelection`) | | Makes the selected entity the stand-in of the selected slot |

These commands act on the active cutscene, or on the cutscene that holds the preview. As the keys do, they work wherever the keyboard is. Thus a designer can select entities in the viewport or the Outliner, and add bindings at once. Ctrl+B is Build Project, so the add command uses Ctrl+Shift+B. The commands are not in the ribbon, as the timeline's commands are not.

- **Possess.** A new binding gets the name of its entity, made unique. It goes after the last binding, as a possess from a key does (see [Possessing](#possessing)). These entities are not possessed:
  - entities that the game spawned;
  - entities of a scene that has no GUID yet.

  An entity dragged from the Outliner onto the timeline is possessed too. If the entity is in the selection, the whole selection is possessed. In a scene view, a drag that starts on a selected entity drags it to the timeline in the same way. While a cutscene's tab is active or holds the preview, the view picks under each press. Only the entity in front counts, as for a click. A drag is a box select, as before, in these conditions:
  - the pick has not answered when the pointer moves;
  - the pick found no selected entity.
- **Spawn.** A prefab dragged from the content browser onto the timeline adds a binding that spawns the prefab, with the prefab's name. Some files make a prefab, for example a USD stage. A drop of such a file spawns its prefab, as a drop in the viewport places it.
  - **Add Binding ▾** is beside the **Selected entities** toggle. Its items are Selected Entities, Spawn Prefab… and Script Slot. The **Spawn Prefab…** button beside it opens a picker of the prefabs that the asset index knows. The picker has a search box.
  - **A spawn at a place.** Drag a prefab from the content browser into a scene view, and hold **Ctrl** as you drop it. If a cutscene holds the preview, this adds a binding to that cutscene, and does not place the prefab in the scene. The binding's `position` is where the drag showed the prefab, in meters. A new transform track keys no offset at the playhead, so the spawn's first key is at the drop point (`CutsceneBindings.AddSpawnAt`). The spawn uses Ctrl because Alt on a drop already makes plain entities of a placed prefab. A part of a prefab does not spawn in this way.
- Each add is one undo entry for all its bindings, and selects their rows. Undo follows the add while no other editor's tab is active (see [Undo](#undo)).

### Rebind and delete

- **Rebind.** There are two ways to rebind:
  - the Rebind to Selection command;
  - a drop of an entity on a binding's row with Alt held. It rebinds that row's binding, and both selections stay as they are.

  A rebind changes only the binding's `possess`. The tracks name the binding by its ID, so they do not change. The editor refuses a rebind in these conditions:
  - the binding does not possess: to point it at an entity is a [convert](#convert);
  - another binding possesses the entity, or it is a slot's stand-in.
- **Fix a broken binding.** The details strip of a broken possessed binding has these items:
  - **Pick** arms a pick (`CutsceneEditor.Picking`). The next entity that you select in the viewport or the Outliner becomes the binding's, as one undo entry, and the row stays selected. An entity that another binding has, or that is a slot's stand-in, does not become the binding's: the pick stays armed, and the row stays selected. The Outliner works without the game. Esc, in the viewport or the tab, cancels the pick. Another row cancels it too. The selection is the shell's, so the shell holds the one pick, with its cutscene. Another cutscene's tab, or the close of the pick's own tab, cancels it, and a pick armed in one cutscene ends any other.
  - A button for each entity of the open scenes that has the binding's name, up to eight (`CutsceneEditor.CandidatesOf`). A new binding has its entity's name, so these are the entities that have the old name. A button rebinds to its entity.
- **Delete.** Delete, while the timeline has the keyboard and a binding's row is selected, removes the binding and its tracks as one undo entry. A row that the filter hides is not deleted.
  - If the binding has tracks, the editor asks first (`EditorShell.AskDeleteBinding`). The main window answers with a dialog.
  - If a track of the binding is locked, the editor does not delete it.
  - If other blocks name the binding by its ID, the editor does not delete it. These blocks can name a binding: another binding's `parent` or constraints; a camera cut's `camera` or constraints; a transform track's `space = relative <id>`; an event's `value = entity <id>`; a sub-sequence's `bind`. The refusal names those blocks (`CutsceneEditor.DeleteBindingRefusal`).
- **Rename.** The name box in the details strip renames a binding, as it renames a track. A rename changes only the name.
- **The details strip** of a binding shows these items: what it possesses or spawns, or a slot's stand-in; why it is not loaded or broken; the fixes above; the converts; and why Delete refuses it.

### Convert

**Convert to** in the details strip, or a convert command, makes the selected binding another kind. The binding keeps its ID, its name and its tracks. Each convert is one undo entry (`CutsceneEditor.Convert`, with the edits in `CutsceneBindings`). The cooker refuses some settings on some kinds, so a convert removes them:

| To | What it writes | When the editor refuses it |
|---|---|---|
| Spawned | `spawn` is the prefab of the possessed entity, or a slot's prefab stand-in. `position`, `rotation` and `scale` are the entity's world pose in its scene, so relative tracks keep their meaning. `possess`, `provided` and `policy` go. | The entity's scene is not open. The entity is not the root of a prefab's instance. The instance is a part of its prefab. |
| Possessed | `possess` is the one selected entity, or with nothing selected, a slot's stand-in. `spawn`, `provided`, `parent`, `position`, `rotation` and `scale` go. | Not exactly one entity is selected. Another binding possesses the entity. Another binding spawns under this one (its `parent`), because a parent is a spawned binding. |
| Script slot | `provided = true`. `possess`, `spawn` and the settings that only a spawn has go. `policy` stays. What the binding bound becomes the slot's stand-in. | Another binding spawns under this one. |

A spawned binding that becomes possessed takes the pose of the entity. Relative tracks then move from that pose, which can differ from the spawn's.

### Script slots

A script slot is a binding whose entity a script gives when it plays the cutscene. The script names it by the binding's name, for example `Cutscene.play(asset, { bindings = { Companion = Quest.companion() } })` (see [Cinematics: Bindings](../cinematics/bindings.md)). A slot is `provided = true` in the text. It can have a `policy`: a required slot that no script fills fails the cutscene.

- **The stand-in.** The editor previews a slot with a stand-in: an entity of a scene, or a prefab. The stand-in belongs to you, not to the asset. It is saved with your view of the timeline (`CutsceneTimelineView.StandIns`, by the binding's ID). The details strip of a slot sets it with **Use Selection** (or **Stand In Selection**), **Prefab…** or **Clear**. A change of stand-in is not an undo entry, and the document does not change.
- **The preview.** The preview cooks `CutsceneEditor.CookText`, not the document's text. `CutsceneStandIns.PreviewText` puts each stand-in on its slot's `provided` line: `possess = …` or `spawn = …`. A spawn has no `policy`, so for a prefab it makes the `policy` line a comment. Every line stays where it was, so the cooker's problems are on the lines that you edit. In the preview, a slot with no stand-in is missing, whatever its policy, and its tracks do nothing.
- **The stand-in as the slot's entity.** A slot with an entity stand-in selects that entity, and the entity selects the slot's row. Keys and auto-key act on it as on a possessed binding's entity.
- A slot keeps its stand-in when it converts to another kind. Thus an undo that makes it a slot again finds the stand-in.

### Selection sync

- **A binding's row selects its entity.** Binding rows selected on the timeline select the entities that they possess in the viewport and the Outliner.
  - Some rows have no entity in the world: a broken, not loaded or spawned binding's row. Such a row does not change the world's selection. Thus the entity that a rebind would use stays selected.
- **An entity selects its row.** An entity selected in the viewport or the Outliner that a binding possesses selects that binding's row, and the timeline scrolls to it.
  - An entity that no binding possesses, or a cleared selection, does not change the timeline's selection. Thus keys stay selected while the designer picks an entity to key.
- One side does not write back to the other while it writes (`CutsceneEditor._syncing`).
- A new row is selected only for a binding that the selected entities did not have before. A resync, which gives the same entities new handles, does not change the timeline's selection.
- **Selected entities** is the toggle beside the search box. When it is on, the timeline shows only these rows:
  - the bindings of the entities selected in the viewport or the Outliner;
  - their tracks.

  It hides the tracks that no binding has. The rows follow the selection while the toggle is on. The toggle is a field of `CutsceneRowFilter`, so every build of the rows uses it.

### Limits

- A spawned binding's row does not select the entity that the preview spawned, because the game does not send which entity that is. The same is true of a slot with a prefab stand-in.
- A drag from a scene view needs the game: the pick under the press needs a linked host. Without one, a drag is a box select.
- The prefab picker lists whole prefabs. A part of a prefab does not spawn.

## Curves

The curve editor shows the curves of the selected tracks over time, below the timeline. A designer shapes the motion between keys there: drags keys in time and value, drags tangent handles, and sets tangent modes. Every edit is one undo entry and shows in the preview as soon as the text cooks, as the timeline's edits do.

### The pane

- **Curve Editor** (Ctrl+E), or the toolbar's **Curves** button, opens it below the timeline, with a split between them. It is the tab's, and not saved.
- **Its toolbar** (`CutsceneCurveBar`) is above its curves: Normalized, Value snap, Before and After for the [infinity](#infinity), and the [Time and Value boxes](#typed-times-and-values).
- **The curves are the selection's.** A selected track shows each of its channels. A selected section, channel or key shows its channel. A selection of keys only keeps the curves that showed and adds its own, so a click on a key does not hide the other curves. With nothing selected, the curves stay.
- **The list** on the left is as wide as the timeline's headers. Each row is one channel of one section, with its color. A click on the color hides or shows the curve. A click on the name selects the curve's keys.
- **Colors:** the part of a channel's name after its last `_`, or the whole name, sets its color: `x` or `r` is red, `y` or `g` green, `z` or `b` blue, and `w` or `a` grey. So `position_x` is red. Other channels take colors from a palette in the order that they show.
- **A channel of assets,** such as a property track's `$<guid>` keys, has no curve.

### The view

- **Time is the timeline's.** The two panes share one `TimelineView` (`CutsceneEditor.TimeView`), so a zoom or a pan in one moves the other, and the playhead and the markers are at the same pixels. A zoom or a pan by hand in either pane turns off the timeline's follow, as in [Scrub, play and step](#scrub-play-and-step).
- **The value axis is the pane's own** (`ValueAxis`), with values going up. It fits the curves when the set of curves changes. `Canvas2DView` is not used, as it has one zoom for both axes.
- **Navigation:**
  - The wheel zooms the time about the pointer, and Shift and the wheel zoom the values.
  - The middle button pans both axes.
  - Alt and a right drag zoom each axis about the press: right and left zoom the time, and up and down the values.
- **F** (Frame Selection, with the curve editor's keyboard) fits the selected keys in time and value, or every curve when no key of the curves is selected.
- **Normalized Curves** (Alt+N, or the curve toolbar's **Normalized** button) shows each curve from its least value at -1 to its most at 1, so curves of different sizes can be compared. It changes no value: a drag moves a key by the curve's own amount. A flat curve shows at 0.
- **The grid** has a line for each round value, with 0 brighter, and a line for each frame or group of frames, as the timeline has.

### Keys

- **A click** on a key selects it. Ctrl adds or removes it, and Shift adds it. A drag in empty space selects the keys in a box. A click in empty space clears the selection.
- **The selection is the timeline's.** A key selected in the curve editor is selected on the timeline too. Undo and Esc put it back as the timeline's drags do.
- **A drag** of a selected key moves every selected key in time and value, as one undo entry (`Move Keys`). Esc cancels it.
  - Time snaps as the timeline's drags do: to the edges of the sections, the triggers, the other keys, the markers and the playhead within 6 pixels, or else to frames. Ctrl turns snapping off for the drag, and Snap (N) for all of them.
  - **Value Snap** (Alt+V, or the curve toolbar's **Value snap** button) puts the grabbed key's value on the grid's lines, and moves the other keys by as much. It is off at first, and the tab's. Ctrl turns it off for the drag too. In the normalized view, it snaps the shown value.
  - Shift moves only along the axis that has moved more.
  - A key stays inside its section, and keys that pass each other change places, as on the timeline.
- **A double-click** on a curve adds a key there, with the value that the curve has there, and selects it (`Add Key`). After a `linear` or a `constant` key, the new key takes that interpolation, so a straight line or a step stays as it was. Otherwise the new key is `auto`, which can change the curve's shape around it.
- **Delete,** with the curve editor's keyboard, deletes the selected keys. A channel that loses its last key goes too.
- A locked track's curve is dim. Its keys do not move, and it takes no key.

### Tangents

A key's interpolation decides the segment from it to the next key, as [Tracks: Curves](../cinematics/tracks.md#curves) says. The commands act on the selected keys, with the curve editor's keyboard, as one undo entry. Each writes only the key's interpolation and what follows it, so `teleport` and the line's comment stay.

| Command | Key | The key becomes |
|---|---|---|
| Auto Tangents | 1 | `auto`. The evaluator computes the slope, which does not overshoot. A new key is `auto`. |
| Unify Tangents | 2 | `bezier <s>`: one slope, the mean of the key's in and out slopes. |
| Break Tangents | 3 | `bezier <in> <out>`: the slopes that the curve has at the key, which its handles then move apart. |
| Linear | 4 | `linear`: a straight line to the next key. |
| Constant | 5 | `constant`: the value holds until the next key. |
| Flatten Tangents | 6 | `bezier 0`, or `bezier 0 0` when broken: flat. |

- Auto, Linear and Constant drop the slopes and the weights. Unify, Break and Flatten keep a Bezier key's weights.
- For a key that is not a Bezier key, Unify and Break start from the slopes that the evaluator gives it. So an `auto` key keeps its curve's shape. A `linear` or a `constant` key's segment to the next key becomes a curve.
- **Handles.** A selected `bezier` or `auto` key shows a handle on each side that has a key. A key without weights has handles 40 pixels long, which show the slope's direction on screen. A weighted key's handles are its [weights](#weights).
- **A drag of a handle** sets the slope from the key to the pointer, as one undo entry (`Drag Tangent`) that Esc cancels. An `auto` key becomes a Bezier key. A key that is not broken takes the slope on both sides, and a broken key on the handle's side only.

### Weights

A weight is how far a handle reaches into its segment, from 0 to 1 of the segment's duration ([Tracks: Curves](../cinematics/tracks.md#curves)).
- **Weighted Tangents** (7) weights the selected `bezier` and `auto` keys, or when all of them are weighted, takes their weights away, as one undo entry. Linear and constant keys have no handles, and it leaves them.
  - A key that it weights becomes `bezier` with the slopes that it had, an `auto` key's computed ones too, and `weights 0.33333334 0.33333334`. That is the reach of a key without weights, so the curve keeps its shape.
  - A key whose weights it takes away keeps its slopes.
- **A weighted handle** is at its control point: the weight's part of the segment's duration across, and the slope over that time up. A handle shorter than 12 pixels shows at 12 pixels along its slope, so it is not under its key.
- **A drag of a weighted handle** sets the slope, as for any handle, and that side's weight from how far across the pointer is, from 0 to 1. Each side has its own weight, so an unbroken key's other side keeps its weight. The tooltip shows both.

### Infinity

A curve's infinity is what it does before its first key and after its last, inside its section: constant, linear, cycle, cycle with offset or oscillate ([Tracks: Curves](../cinematics/tracks.md#curves)). It is a channel's `pre_infinity` and `post_infinity`, and constant writes neither.
- **Before** and **After** on the curve toolbar show and set it for the curves of the selected keys, or with no key selected, for every curve that shows. A blank box means that the curves differ. **Next Pre-Infinity** (8) and **Next Post-Infinity** (9) step to the next mode. Each is one undo entry.
- A curve that does not take a mode keeps its own: an audio track's `pitch` takes only constant, and a curve of assets has none.
- **The curve draws dashed** from its section's start to its first key and from its last key to its section's end, as the runtime evaluates it there. Its span in the normalized view, and F with no key selected, take in those parts on a side that is not constant.
- **A double-click** on a dashed part adds a key with the value that it shows. The new key changes the keys' span, so a cycle's repeats change.
- **Split** keeps the modes in both halves. A cut in a dashed part keys the value there, which changes the keys' span in the same way.

### Typed times and values

The curve toolbar's **Time** and **Value** boxes show the time and the value that every selected key has, or a dash when they differ. The time is on the cutscene's time, as timecode or as frames, as the ruler shows it.
- **Type an entry and press Enter:** a number sets every selected key, and `+=` or `-=` and a number moves each by it. An offset of times moves the keys together, as a drag does, so at a section's edge they all stop. Esc, or a click away, puts back what the keys have. Each entry is one undo entry (`Set Key Time`, `Set Key Value`).
- **A time** is timecode or frames at the display rate, as Go to Time takes. A key stays inside its section, and the selection follows the keys as they sort. An entry that would put two selected keys of one curve at one time changes nothing, and the box's tip says why. A key can land on a key that is not selected, as with a drag, and the cooker reports it.
- **A value** is a number. A stepped curve's key takes a whole number.
- An entry that does not read changes nothing, and the box's tip says what it takes.
- **The preview follows a drag when it ends.** The text cooks when the undo entry closes, as for the timeline's drags, so the viewport shows a drag of a key or a handle at its release.

### Stepped curves

A property track whose field is an integer, a bool or an enum steps, as the runtime's `curve_step` evaluates it. The editor knows from the game's component types (`EditorShell.SteppedChannel`). Before the game describes them, the curve draws as smooth.
- The curve draws as steps, and its keys have no handles.
- The tangent commands leave its keys.
- A double-click adds a `constant` key with a whole value, and a drag moves its keys by whole values.

### The evaluator

`CutsceneCurve` in `Cinnabar.Editor.Document` is the editor's copy of the runtime's evaluator, the keyed curve with `i32` times in `lib/core/math` (`keyed.odin` and `exact.odin`), line for line. It does the same `f64` arithmetic in the same order, without fused multiply-adds, with the same 48 halvings for a weighted segment. `CurveKey.Parse` reads a key line as the cooker does: each number as an `f64` that must be finite, then an `f32`.
- `CutsceneCurveTests` reads `lib/core/math/testdata/curve.txt`, the curve that the runtime's test writes, and checks that the editor gives the same `f32` bits at each of its ticks.
- The curve editor samples each curve at whole ticks only, one sample for each pixel, clamped to its section, as the runtime samples it, with its infinity.
- It reads a channel's `pre_infinity` and `post_infinity` as the cooker does. `CutsceneCurveTests` checks the golden file's infinity blocks too.
- Split takes its values from it.

### Limits

- **Value snapping is for drags.** A typed value is exact.
- **A curve per section.** A track with several sections has a curve for each section's channel, named with the section's ID.

## Cameras

A designer works as a camera operator: they look through a camera of the cutscene in a scene view, fly it into place, key it, and check the framing against the final aspect. The scene views draw from the editor camera until a designer asks for a camera. The Game view always draws from the game's camera, which shows the cut camera while a session is open (see [Preview](#preview)). `ViewLooks` in the shell holds what each scene view draws from. `CutsceneEditor.Cameras.cs` holds the cutscene's side.

### Which bindings are cameras

A binding is a camera when one of these is true (`CutsceneEditor.IsCamera`):
- a camera cut section names it as its `camera`;
- the entity that it possesses has a `Camera`;
- the root of the prefab that it spawns has a `Camera`, as the prefab's file has it.

A camera binding's row has a small camera at its right end. It is lit while the active scene view looks through the camera. A click on it starts or ends the look.

### Look through

A scene view looks through a camera of the cutscene that holds the preview, in place of its editor camera. There are three ways to start it:
- the View menu's **Look Through** submenu: **Editor Camera**, **Cuts**, and each camera binding;
- the camera on a binding's row, for the active scene view, or the first scene view while the Game view is active;
- the commands **Look Through Camera**, on the selected binding, **Look Through Cuts** and **Editor Camera**.

A look starts the cutscene's preview session when another tab holds it.

- **One state.** Each scene view's look is one value (`ViewLook`): `Editor`, `Cuts`, or `Camera` with its binding. `ViewLooks.Become` is the one writer, and it tells the game.
- **By binding.** The editor names the camera by its binding's ID, and the game finds the entity, because the editor has no entity for a spawned binding. `Viewport_Look` carries the view, the look's serial, the session's ticket and the source.
- **Cuts.** With **Look Through Cuts**, the view draws from the camera of the camera cut section at the playhead, as the Game view does. It changes as the playhead moves.
- **The game draws it.** `frame_viewports` draws the view from `render.camera_view` of the camera's entity, with its lens and depth of field. When the drawn camera changes, the view's histories start again. Picks use the drawn camera's projection, so a click selects what is under it.
- **The game answers.** `Viewport_Look_Shown` tells the editor what the view drew: the binding, the pose and the lens, as the world shows them with the preview's layer on. The game sends it only when it changes. The editor takes an answer only when its serial is the look's.
- **Sessions.** A look follows the tab that holds the preview. The editor tells the game again for each new session of that tab, as after a cook, a reconnect or a new game state. When another tab takes the preview, or the tab closes, the view draws from its editor camera again.
- **No camera.** When the camera is not there, or no cut section is over the playhead, the game draws the view from its editor camera. The view's look stays, and it draws through the camera again when the camera is back.
- **The editor camera stays.** A look never moves the editor camera. Frame Selected, Frame Scene, a turn to an axis, a change of the projection and the 2D view move it, so each of them ends the look first.

### Pilot

While a scene view looks through a spawned camera, its fly, orbit and pan controls move the camera, not the editor camera (`ViewLooks.Move`). The pilot's camera is an `EditorCamera` that starts at the pose that the game reported, with the camera's field of view.

- **The world shows it at once.** Each move sets the binding's pose as a [preview value](#preview-values), by its binding's ID (`Override_Target_Kind.Binding`). The game finds the binding's entity at each lay, so the value stays when a new blob spawns the camera again. The scene view and the Game view both show the move.
- **Auto-key.** With [auto-key](#auto-key) on, the first move of a mouse gesture starts a drag in the cutscene. Each move keys the pose at the playhead, and the release commits it: one key and one undo entry, "Pilot <name>". A click with no move keys nothing.
- **Without auto-key.** The pose holds over the preview until Enter keys it, or the playhead moves and drops it. It stays held when the look ends, so Enter still keys it.
- **The keys.** `PilotKeys` keys the pose in the camera's transform track's space. A relative track, the default, keys the offset from the pose that the binding spawns with, in its axes, and the turn after its rotation. An absolute track keys the pose from its origin, which the first key sets. The rotation's angles turn the short way from the keys next to them.
- **Settling.** Keyed values stay until the preview shows the text that keyed them. The game's `Cutscene_Preview_Shown` says which blob and values the world shows, so a binding's pose settles without an entity of the editor's.
- **Play.** A gesture pauses a playing preview first, as values show only at a paused playhead.
- **Esc.** During a gesture, Esc takes the gesture back: no undo entry, the values as they were, and the pilot's camera where it started. Otherwise, Esc ends the look, and the view draws from its editor camera again.
- **The speed line** says "Piloting", with the flying speed. A view that cannot pilot says why.

### New camera from view

**New Camera from View** (Ctrl+Shift+C) adds a camera where the active scene view looks from, as one undo entry, "New Camera":
- a binding, "Camera", that spawns the camera prefab with the view's position and rotation;
- a transform key with no offset at the playhead;
- a `focal_length` key at the playhead, from the view's field of view on the prefab's sensor (`Lens.FocalLength`);
- a cut to the camera at the playhead, when no cut is over it and the playhead is before the length (`CutsceneEdits.AddCut`). The cut runs to the next cut's start, else to the range's end, else to the length, else for a second. It adds the camera cut track when there is none.

The view's pose is the one that it draws: the camera that it looks through, or its editor camera. An orthographic editor camera has no lens, so the command does not run there.

The camera prefab is the engine's `lib/engine/content/prefabs/cinematic_camera.prefab`: a Camera with a 35 mm lens on a 36 by 24 mm sensor, with no depth of field. When the asset index does not have it, the command takes the first prefab, by name, whose root has a Cinematic_Camera.

### Frame guides

Each viewport, the Game view too, has a **Guides** menu on its toolbar (see [Viewport: Toolbar](viewport.md#toolbar)). The editor draws the guides over the frame that the game shares (`FrameGuidesOverlay`), so no capture has them and they cost the game nothing.
- **Aspect Mask** shades the frame outside an aspect. The aspect is **Camera**, the drawn camera's sensor aspect, which the presentation track's letterbox uses too, or 2.39:1, 1.85:1, 16:9, 4:3, or a custom value from 1 to 4. A view without a camera's lens takes 16:9 for Camera.
- **Safe Areas** draws the action safe area, 93% of the framed shot, and the title safe area, 90%.
- **Rule of Thirds** draws a grid of thirds and a centre mark over the framed shot.
- **Camera Info** writes the camera's name, its focal length and the shot's name while a scene view looks through a camera. The Game view writes the shot's name.

The guides are each user's, for each viewport, in `viewport.json`. `FrameGuides` in `Cinnabar.Editor.Tools` gives their rectangles in the frame's pixels, which `FrameGuidesTests` checks for each aspect.

### Lens

A camera binding's details show its **Lens** under its binding rows (`CutsceneLensRows`, and `CutsceneEditor.Lens.cs` in the shell). The lens is the camera's `Cinematic_Camera` ([Rendering: Components](../rendering/assets.md#components)):
- **Focal length** in millimeters, with the vertical field of view that it gives on the sensor (`Lens.VerticalFov`, the runtime's formula).
- **Sensor**: a preset, Full frame, Super 35, Super 16 or IMAX 70 mm, which sets the width and the height together.
- **Focus** in meters, **Aperture** as an f-number (0 is no depth of field), and **Focus offset** in meters (see [Focus](#focus)).

Each number has a key button, as the inspector's fields have (see [The key button](#the-key-button)), with the same menu: Add Track, Key, Remove Key and Go to Track. A key goes on a property track of component 160.
- **A typed value** keys at the playhead, as one undo entry, with [auto-key](#auto-key) on. Otherwise it is a [preview value](#preview-values) until Enter or the key button keys it.
- **A drag on a field's name** scrubs it: 0.1 mm a pixel for the focal length, 1 cm for the focus and the offset, and 0.1 for the aperture, ten times as far with Shift and a tenth with Ctrl. The view shows each step at once. With auto-key, the drag is one key and one undo entry, and Esc in the timeline cancels it.
- **The shown value** is the value over the preview, else the track's curve at the playhead (`CutsceneKeying.ValuesAt`, with the runtime's evaluator), else the spawned prefab's root's value, else 0, which is the default. Where sections of the track overlap and blend, it is the top section's.
- **A spawned camera** has no entity in the editor. Its values go over the preview by its binding's ID (`Override_Target_Kind.Binding` on an `Override_Field`), and the game finds the binding's entity at each lay, as it does for a [pilot's](#pilot) pose. Enter keys them with the other values.
- **A possessed camera's** lens goes where the inspector's fields go (see [Where an edit goes](#where-an-edit-goes)), through its entity, so the details and the inspector share one value over the preview and one key state. The inspector's Sensor goes there too while a cutscene that possesses the camera holds the preview.

The rows are built once for the selected binding and show new values in place, so a drag keeps its handle while it changes them.

### Focus

The depth of field focuses at the **Focus** distance, or on a binding's entity.
- **Focus On** sets the binding's own `focus = <binding>` constraint (see [Cinematics: Camera cut tracks](../cinematics/tracks.md#camera-cut-tracks)), as one undo entry. It holds over the whole cutscene, so it is not keyed. A camera cut section's `focus` holds while the section shows. The focus is then the target's distance along the camera's axis plus the **Focus offset**, which a track can key.
- **Pick Focus** sets the focus distance to the depth of what a view that looks through the camera draws at a pixel. The details' **Pick Focus** button, or the command `cutscene.pickFocus`, arms it, and the next click in that view picks. Esc disarms it. **Ctrl+click** in the view picks at once, in place of a toggle of the selection.
- **The depth** is `Pick_Result.depth` from a 1-pixel `Pick_Request` to that view. The view draws, and picks, through the camera's projection, so the depth is the distance along the camera's axis, which the focus takes. A host test checks it to within 1 cm.
- **Where it goes:** the picked depth goes as a typed focus does: a key with auto-key, otherwise a value over the preview.
- **Refusals:** a pick that hits nothing sets nothing. An answer that comes after the view's look or its session changed sets nothing. While a Focus On constraint sets the focus, a pick is refused, as the runtime does not take the distance then.

### The cut strip

The camera cut track's row names each cut's camera from the cut's start up to the next cut's start (`CutsceneTimelineLayout.CutNames`), so a name shows past a short cut's end when a gap follows it. A name with less than 16 pixels of room is left out. Hovering a cut shows its camera, its start and end and its length, as timecode.

### Frustums

While a cutscene's preview is open, the helpers draw each camera's frustum in a colour for what it is at the playhead (`helpers.odin`): white when it is selected, the camera cut track's orange when it is the shot on screen, and grey otherwise. A camera that a scene view looks through has no frustum.

### Limits

- **Pilot moves only a spawned camera with no parent binding.** A possessed camera moves with the gizmo, and its keys go as [Gizmo keys](#gizmo-keys) says. A camera whose track is relative to another binding is not piloted.
- **No roll.** The pilot's camera has a yaw and a pitch, so a rolled camera loses its roll at the first move.
- **A cut's constraints win.** A camera cut section's `look_at` and `follow` write the camera's rotation and position after its track. While a pilot's pose is held over the preview, the view shows the pose. Once the keys settle, the constraint aims or moves the camera again, so a pilot's keys show only where no constraint writes the same part.
- **The wheel changes the flying speed.** It does not dolly, because a pilot's move ends with a mouse release. Alt and the right button dolly.
- **The editing tools are off in a view that looks through a camera.** The gizmo, a box select, mesh mode, the landscape brush and drops act in the editor camera's view. A click still selects.
- **The frustums are the same in every view.** The helpers' lines are shared by the scene views, so a camera that any view looks through has no frustum in the others either.
- **No cut thumbnails yet.** A cut's hover shows its camera and its times, not a picture of its first frame. That waits for render out ([#559](https://github.com/aszecsei/cinnabar/issues/559)), which makes the preview's renders.
- **A preview value keys at the preview's time.** Past the range's end, the preview stands at the end, so Enter keys a held lens value there.
