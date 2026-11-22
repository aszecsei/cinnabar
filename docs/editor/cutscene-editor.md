# Cutscene editor

The cutscene editor edits a cutscene (see [Content: Cutscenes](../content/kinds/cutscenes.md)), which the game plays as [Cinematics](../cinematics/README.md) describes. Each open one is a tab, `CutsceneEditorDocument`, over a `CutsceneEditor` in the shell, which holds its state. Docking can rebuild the view, and tests drive the editor without a window.

The editor is built in steps under [#548](https://github.com/aszecsei/cinnabar/issues/548). This page describes what is built: the tab, its document, its outline and details, and the check of its unsaved text. The timeline ([#550](https://github.com/aszecsei/cinnabar/issues/550)), scrubbing and playing in Edit ([#551](https://github.com/aszecsei/cinnabar/issues/551)), keys from the inspector ([#552](https://github.com/aszecsei/cinnabar/issues/552)), the curve editor ([#553](https://github.com/aszecsei/cinnabar/issues/553)) and the bindings' rows ([#554](https://github.com/aszecsei/cinnabar/issues/554)) come next.

**In this document:** [The file](#the-file) · [The tab](#the-tab) · [Preview](#preview)

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

  The selection is a path, and so it stays across an undo.
- **Undo:** each editor has its own undo stack of the text (`GraphDocument`), and a drag is one entry. Undo, Redo and Save act on the cutscene editor whose tab is active. Esc during a drag cancels it, and nothing goes on the stack. Save is disabled during a drag. A document is dirty when its position in its history is not the one that its file has, and its tab marks it with a dot.
- **Saving** writes the text through a temporary file, and the cook daemon then cooks it. A save that would replace what another program wrote asks first.
- **Closing** a tab with unsaved changes asks to save them, and so does closing the editor. An open cutscene follows its file when the content browser moves or renames it.
- **New Cutscene,** in the content browser's menu and in the Gameplay tab's New Asset group, makes a cutscene of 10 s at 30 frames a second, with an empty camera cut track. It opens in its tab when the index has it.

## The tab

- **Toolbar:**
  - Save, and Open in Script Editor;
  - the cutscene's length as timecode (`mm:ss:ff`) and as frames at its display rate;
  - the check's state: waiting for the cook daemon, cooks, or the count of errors, with the first error as its tooltip, and "not saved".
- **Outline:** a row for the cutscene, each binding and each track, with each track's sections, triggers and ranges under it. A section's row shows its span as timecode. A row whose lines have problems has a mark, with the problems as its tooltip. A problem on a channel or a key shows on its section's row. The selected row lists its problems under it. A click selects a row's block. The timeline ([#550](https://github.com/aszecsei/cinnabar/issues/550)) takes the outline's place.
- **Details:** the selected block's fields, under the outline:
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

## Preview

Each committed edit sends the unsaved text to the cook daemon with `Cook_Preview`, through `PreviewCook`. `PreviewCook` waits 250 ms after the last edit, so at most four checks go each second, and it runs one at a time. A drag's steps are not sent: its end is the edit. The daemon's `cutscene_check` reports what a cook of the text would report:

- the text's own problems;
- the assets that it names, against the daemon's index, sub-assets such as clips included;
- its sub-sequences' cycles, depth, trims and binds, with the other cutscenes' sources on disk and the unsaved text in place of this cutscene's own.

The answer's problems are on their blocks by line. An answer about a text that has changed since it was sent is dropped, because its lines are old.

A text without problems goes in the cache's preview area, `<cache>/dev/preview/<guid>.blob`, which scrubbing and playing in Edit will play ([#551](https://github.com/aszecsei/cinnabar/issues/551)). A text with problems leaves the last good one there. The cutscene's own blob does not change until it is saved and cooked.
