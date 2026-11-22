# Cutscene editor

The cutscene editor edits a cutscene (see [Content: Cutscenes](../content/kinds/cutscenes.md)), which the game plays as [Cinematics](../cinematics/README.md) describes. Each open one is a tab, `CutsceneEditorDocument`, over a `CutsceneEditor` in the shell, which holds its state. Docking can rebuild the view, and tests drive the editor without a window.

The editor is built in steps under [#548](https://github.com/aszecsei/cinnabar/issues/548). This page describes what is built: the tab, its document, its timeline and details, the check of its unsaved text, and its preview in Edit. These come next:
- a scene view that looks through the cut camera, and the camera tools ([#555](https://github.com/aszecsei/cinnabar/issues/555));
- keys from the inspector ([#552](https://github.com/aszecsei/cinnabar/issues/552));
- the curve editor ([#553](https://github.com/aszecsei/cinnabar/issues/553));
- the bindings and the viewport's selection ([#554](https://github.com/aszecsei/cinnabar/issues/554)), with the filter that shows the tracks of the entities selected in the viewport;
- the clips' display ([#556](https://github.com/aszecsei/cinnabar/issues/556)).

**In this document:** [The file](#the-file) · [The tab](#the-tab) · [The timeline](#the-timeline) · [Preview](#preview)

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
  - the check's state: waiting for the cook daemon, cooks, or the count of errors, with the first error as its tooltip, and "not saved".
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
  - Each channel gets a key at the cut in both halves. After a constant key, the value holds. After the other kinds, the value is on a straight line between the keys on each side. A Bezier key's tangents are not kept. The curve editor ([#553](https://github.com/aszecsei/cinnabar/issues/553)) will give exact values.
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
- **The timeline's keys are bare letters,** which the viewport and the other panels also use. So each command acts only while the timeline has the keyboard, or while the command palette opened from it has it. When another window, such as a floating panel, becomes active, the timeline does not have the keyboard.
- **Delete and Duplicate.** While the timeline has the keyboard, the scene's Delete deletes the timeline's selection, and its Duplicate duplicates it.
- **Copy and paste.** A command that cannot act leaves its key to the focused control, and a text box keeps Ctrl+C, Ctrl+X and Ctrl+V. So the timeline's copy and paste take those keys only while it has the keyboard.

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

### Cost

A redraw reads only the draw list that `CutsceneTimelineLayout.Visible` gives: the rows in view, and the items in view in each row. It finds the keys with a binary search. Each bar's label is made when the rows are built. `CutsceneFile` keeps an index of its blocks by path, which a change of a keyword line or of the tree drops, so a lookup of a selected path does not search the file.

A test with 50 tracks and 5,000 keys checks two times:
- the draw list takes less than 4 ms;
- a drag's step takes less than 50 ms. A step reads the text again, edits it, and builds the rows again, through a search filter that keeps every row.

The test does not measure Avalonia's drawing.

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
- **The frame counter.** While a session is open, the Game view shows the playhead's timecode and frame and the shot there at its top left: the camera of the cutscene's own camera cut section over the time (`CutsceneTimelineLayout.ShotAt`), or "gameplay". A sub-sequence's own cuts show as "gameplay" there.

### The game's side

`lib/engine/editor/cutscene_preview.odin` holds the open preview in the editor's `Session`. It loads the cutscene with `cutscene.open_live`, as a player loads one, but without a player's slot and without its hold on gameplay. It pushes no input context, hides no UI, and suspends no systems on the bindings (`Player_Context.unheld`). It evaluates the cutscene with `seek` and `evaluate`, as a scrub does (see [Evaluation](../cinematics/evaluation.md)).

- **A layer with the overrides.** The preview's writes are one more layer with the [overrides](link.md#overrides). `lift_overrides` puts them back with `cutscene.lift`, which keeps the drives, the camera cut's claim and the voices. `lay_overrides` evaluates the preview again at its time. So poll, the edit-mode behaviours and what the game sends the editor see the document. An edit of a field that the preview writes goes to the document, under the preview.
- **The frame.** In Edit, `update_cutscene_preview` runs once a frame after the players. It follows a newer unsaved blob and a reload's bindings, moves a playing preview by the frame's real time, and evaluates it. Forward play moves as a player's clock does, so camera cuts blend.
- **The mix.** `Cutscene_Preview_Settings` calls `cutscene.set_mix` (see [Evaluation: The editor's mix](../cinematics/evaluation.md#the-editors-mix)). A silenced track evaluates as a muted one: it writes no field, so the next lay leaves the document's value; it plays no voice and drives no `Animator`; and a silenced camera cut track gives the views back. A silenced sub-sequence track plays no child, though the child stays loaded. With events on, `update_cutscene_preview` sends the events that a play crossed in the same frame, with `cutscene.send_events`.
- **Marks.** The bound entities and the spawned ones are in `Overridden_Entities`, so the Outliner marks them. The fields that the preview writes are in `Entity_Values.held`.
- **Ends.** `end_overrides` ends the preview with the overrides: at `Set_Mode`, `Load_Scene`, a code reload and a new link. `close_live` restores what the tracks wrote, despawns the spawned entities and unloads the assets. A new game state frees the preview without the world.
