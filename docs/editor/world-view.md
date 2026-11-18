# World view

How the editor shows a streamed world: the World editor for `.world` assets, the bounds of the world's scenes in the viewport, a preview of what loads from a position, and the scenes that the game has loaded in Play. Read [World: Streaming](../world/streaming.md) for the policy and [Content: Worlds](../content/kinds/worlds.md) for the asset first.

**In this document:** [The World editor](#the-world-editor) · [Which world shows](#which-world-shows) · [The viewport](#the-viewport) · [The preview](#the-preview) · [Play](#play) · [Limits](#limits)

## The World editor

A `.world` asset opens in the World editor, a document beside the scenes. It is a table with a row for each scene of the world, in the file's order.

| Column | What it edits |
|---|---|
| Scene | The scene's asset, by name. A GUID that names no asset shows as the GUID. |
| Persistent | `persistent`. A persistent scene keeps its lines of bounds and distances, which the cooker ignores, and its other cells are empty. A scene that stops being persistent without bounds gets a new scene's. |
| Min, Max | `min` and `max`, in meters. |
| Load | `load_distance`, in meters. |
| Unload | `unload_distance`, in meters. An empty cell removes the line, so the cooker uses `load_distance` times `DEFAULT_UNLOAD_FACTOR` (1.25). |
| Play | In Play, the game's state of the scene ([Play](#play)). |

- **Add Scene** asks for a scene asset that the world does not name yet. The new scene is not persistent. It has a 40 m box around the active scene view's pivot, and a `load_distance` of 25 m.
- **Remove** removes a scene's lines.
- **The file keeps its lines.** `WorldFile` (`Cinnabar.Editor.Document`) reads the text as whole lines, as the [blackboard editor](decision-editor.md#blackboards) does. Comments, blank lines and line endings write back as they were, and an edit changes only its own lines. A coordinate keeps the text's meters, which the cooker turns into `World_Position` units.
- **Undo and save** are those of every text document. Each edit is one entry on the World editor's own undo stack.
- **Problems.** The cook daemon checks the unsaved text (`world_check` in `tools/cook/worlds.odin`), as the cooker would: a `min` above `max`, a missing `load_distance`, and a GUID that names no scene. Each problem shows on its scene's row.
- **A file that does not start with `world 1`** opens in the script editor, as before.

## Which world shows

The viewport shows one world at a time, or none:

1. **The World editor opened or shown last** that is still open. Opening a world that is already open shows its editor, and makes it last. The viewport shows its unsaved edits.
2. **Otherwise, the world of the first `World_Streamer`** (component 144) in the open scenes, in the order that the scenes opened. The editor reads that world's file from disk.

The world changes when a World editor opens or closes, a scene opens or closes, or an edit changes a streamer's `world`.

## The viewport

The viewport draws each scene of the shown world that is not persistent. It draws the scene's bounds as a box, and a fainter box grown by the scene's `load_distance`.

| Color | Scene |
|---|---|
| Orange | The editor's active scene ([Several scenes](document-and-scenes.md#several-scenes)). |
| Green | A scene that the preview loads, or, in Play, that the game has loaded. |
| Grey | Any other scene. |

- **The load box is an outer bound.** The policy measures the distance from a source to the bounds, so the region that loads has round edges and corners inside the box.
- **The Shapes setting** of the viewport's toolbar shows them ([Toolbar](viewport.md#toolbar)): `None` hides them. `Selected` and `All` both draw every scene. They draw in Edit, Play and Paused.
- **The editor works out each scene's state.** It sends the scenes as a `World_View` with their bounds, distances and flags (`persistent`, `active`, `previewed` and `loaded`), and the game only draws them (`lib/engine/editor/world_view.odin`). The editor sends a `World_View` only when what it would send changes, and again to a new game state.

## The preview

The preview shows which scenes the policy would load from a position. The World editor's preview bar sets it.

| Preview | Position |
|---|---|
| Off | None. |
| Camera | The active scene view's camera, as it moves. |
| Pinned | The camera's position when **Pin Here** was pressed. A white sphere marks it. |

- **What the preview loads** is what the policy loads from the position: every persistent scene, and each scene whose distance to its bounds is at most its `load_distance` (`WorldStreaming.WouldLoad`, as `scene_distance` in `lib/engine/streaming`). The preview starts with nothing loaded, so the unload distance plays no part.
- **The bar lists** the scenes that the preview loads. They draw green.
- **Open Previewed Scenes** opens them in the editor ([Several scenes](document-and-scenes.md#several-scenes)):
  1. Each scene that the preview loads and that is not open opens beside the open ones (Add Scene).
  2. Then each open scene of the world that the preview does not load closes (Close Scene). A scene with unsaved changes asks first.
  3. Scenes that are not in the world stay open, so the scene with the streamer stays.
  4. With no scene open, the first scene opens with Open Scene.
- **The preview is for Edit.** In Play, the game's own scenes show instead.

## Play

In Play, the game streams the world as the camera moves ([World: Streaming](../world/streaming.md#the-policy)).

- **The game sends a `Streamed_Scenes`** when the scenes that the policy has in change, and to a new editor. It has the world's GUID and each scene's GUID, its number and whether it is ready. It comes from `streaming.loaded`, and `streaming.changes` says when to send it.
- **The World editor's Play column** shows `Loading` or `Ready` for each scene that the game has in, when the World editor shows the world that streams.
- **The viewport** draws the game's scenes green.
- **Stop** clears them, as the world goes back to the editor's scenes.

## Limits

- **One world shows at a time.** A second World editor or a second streamer is not drawn.
- **The preview has one position.** The policy's other sources, the `Stream_Source` entities, are not part of it.
- **The editor does not edit streamed scenes in Play.** It edits a scene that it opened, in Edit.
- **The scenes' names** come from the content browser's index. A scene that the index does not know shows its GUID.
