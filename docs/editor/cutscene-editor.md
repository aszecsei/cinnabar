# Cutscene editor

The cutscene editor edits a cutscene (see [Content: Cutscenes](../content/kinds/cutscenes.md)), which the game plays as [Cinematics](../cinematics/README.md) describes. Each open one is a tab, `CutsceneEditorDocument`, over a `CutsceneEditor` in the shell, which holds its state. Docking can rebuild the view, and tests drive the editor without a window.

The editor is built in steps under [#548](https://github.com/aszecsei/cinnabar/issues/548). This page describes what is built: the tab, its document, its timeline and details, and the check of its unsaved text. These come next:
- the rest of the timeline ([#550](https://github.com/aszecsei/cinnabar/issues/550)): markers, copy and paste, the filter, mute and solo;
- scrubbing and playing in Edit ([#551](https://github.com/aszecsei/cinnabar/issues/551));
- keys from the inspector ([#552](https://github.com/aszecsei/cinnabar/issues/552));
- the curve editor ([#553](https://github.com/aszecsei/cinnabar/issues/553));
- the bindings and the viewport's selection ([#554](https://github.com/aszecsei/cinnabar/issues/554));
- the clips' display ([#556](https://github.com/aszecsei/cinnabar/issues/556)).

**In this document:** [The file](#the-file) · [The tab](#the-tab) · [The timeline](#the-timeline) · [Preview](#preview)

## The file

`CutsceneFile` reads a cutscene's text as whole lines (`TextLine`, which the animation graph and decision editors' files share). It puts each line in the block that `tools/cook/cutscenes.odin` would read it in. It does not write the text again from a model.

- **Blocks nest by keyword, not by indent.** The cooker ignores indents. So a block starts at its keyword line:
  - `binding` and `track` are under the cutscene;
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
- **A track's header** shows its kind's color, its name, a mark when its lines have problems, and the lock.
- **A click on a header** selects the binding or the track, so the details edit its name and settings.

### The ruler

The ruler shows timecode (`mm:ss:ff`), or frames at the display rate with **Show Frames**. Its ticks use `TimelineGeometry.TickSpacing`. Once a frame is 4 pixels wide, they are rounded to whole frames (`FrameSpacing`).
- **The playhead.** A click or a drag on the ruler moves the playhead to a frame. The playhead belongs to the editor, so it is in no undo entry. In this step it only marks where Split, Home and End act. Scrubbing and playing in Edit come with [#551](https://github.com/aszecsei/cinnabar/issues/551).
- **The range bar,** at the bottom of the ruler, is the part that plays: the cutscene's `range`. A drag of either end sets it. When the range is all of the length, the editor removes the setting.
- **The length.** The handle at the top of the ruler is the length. A drag sets `length`, but not to less than the end of a section, range or trigger. Time past the length is shaded.

### Navigation

`TimelineView` is the profiler's view in any unit: a start, a time for each pixel, and the limits of its zoom (`TimelineZoom`). The timeline's unit is ticks.
- **Zoom and scroll.** The wheel zooms about the pointer, and with Shift it scrolls the time. The wheel over the headers scrolls the rows.
- **Pan:** a middle drag, or Alt and a right drag.
- **F** fits the selection, or the whole cutscene when nothing on the timeline is selected.
- **The playhead's keys.** **Home** and **End** move the playhead to the start and the end. **Ctrl+Left** and **Ctrl+Right** move it to the previous or next edge of a section, a range or a trigger.

### Selection

The selection uses the gestures of the node graphs.
- **A click** selects a section, a range, a trigger or a key glyph. Shift adds, and Ctrl toggles.
- **A box:** a drag in empty space selects what the box covers.
- **To clear:** click in empty space, or press Esc.
- **The primary item** is the last one selected. The details show it.

### Edits

Each drag is one undo entry, through `Begin`, `StepFromStart` and `Commit`. Each step sets the blocks from where they were when the drag began, so steps do not add up. Esc during a drag cancels it, and the text and the undo stack stay as they were. During a drag, a tooltip shows the start, end, length and change in the ruler's units.

- **Move:** drag a body, a trigger or a key. Everything selected moves.
  - A key moves inside its section, and everything stays inside the length.
  - A key moves with its section when both are selected.
  - A subtitle whose `audio` names an audio section moves with that section.
- **Trim:** drag an edge of a section or a range.
  - Keys keep their times on the cutscene's time, so a trim of a section's start changes the times of its keys.
  - A trim of the start also changes an animation's or a sound's `offset` (times `speed`) and a sub-sequence's `trim` (times `scale`). So the clip stays where it was.
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
- **Delete** deletes the selected sections, events and keys. When a channel loses its last key, the channel is deleted too.
- **Nudge:** `,` and `.` move the selection one frame, and with Shift, 10 frames.
  - The repeats of a held key are one undo entry (`GraphDocument.EditMerged`). The release of the key ends the entry.
  - No entry stays open between repeats, so Save and Undo still run.
  - Nudges from the command palette merge until another edit.
- **Order:** sections and keys stay in start order in the text, as the cooker needs. When a section moves past another, it goes after it, with its comment.

### Snapping and lock

- **Snapping** is on at first, and **N** turns it off and on. Ctrl during a drag turns it off for that drag.
  - A dragged time snaps to a target within 6 pixels: the playhead, the edges of the other sections and ranges, or the other triggers and keys. A dashed line shows the target.
  - With no target, the time snaps to a frame.
- **Lock.** The padlock in a track's header, or **Lock Track**, locks the track. No edit changes its sections, events and keys, but you can still select them. Locks belong to each user. They are in `cutscene-timeline.json` in the editor's settings, with Show Frames, for each cutscene.

### Keys

Each action is a command, so it is in the command palette, and `keybindings.json` can change its key. None of them is in the ribbon.
- **The timeline's keys are bare letters,** which the viewport and the other panels also use. So each command acts only while the timeline has the keyboard, or while the command palette opened from it has it.
- **Delete.** While the timeline has the keyboard, the scene's Delete deletes the timeline's selection.

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

### Cost

A redraw reads only what `CutsceneTimelineLayout.Visible` gives: the rows in view, and the items in view in each row. It finds the keys with a binary search. A test with 50 tracks and 5,000 keys checks that a redraw takes less than 4 ms.

## Preview

Each committed edit sends the unsaved text to the cook daemon with `Cook_Preview`, through `PreviewCook`. `PreviewCook` waits 250 ms after the last edit, so at most four checks go each second, and it runs one at a time. A drag's steps are not sent: its end is the edit. The daemon's `cutscene_check` reports what a cook of the text would report:

- the text's own problems;
- the assets that it names, against the daemon's index, sub-assets such as clips included;
- its sub-sequences' cycles, depth, trims and binds, with the other cutscenes' sources on disk and the unsaved text in place of this cutscene's own.

The answer's problems are on their blocks by line. An answer about a text that has changed since it was sent is dropped, because its lines are old.

A text without problems goes in the cache's preview area, `<cache>/dev/preview/<guid>.blob`, which scrubbing and playing in Edit will play ([#551](https://github.com/aszecsei/cinnabar/issues/551)). A text with problems leaves the last good one there. The cutscene's own blob does not change until it is saved and cooked.
