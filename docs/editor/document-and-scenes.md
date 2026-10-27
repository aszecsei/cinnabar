# Document and scenes

The editor owns the scene: edits are operations with inverses, the host's world mirrors the document, and the scene file is text with stable IDs. This document covers the document model, the modes, and the scene format and loader.

**In this document:** [Document model](#document-model) · [Scenes](#scenes) · [Future work](README.md#future-work)

## Document model

**The editor owns the scene.** The host's world is a mirror of the editor's document while the editor is in edit mode.

- **Why:** the host can lose its world at any time. A crash loses it, and so does a soft restart after a `Game_State` layout change (see [Hot reload](../overview/hot-reload.md#reload-sequence)). Unsaved edits must survive both. If the host owned the scene, they would not.
- **Edits are operations.** Every change is an operation on the document: create or destroy an entity, rename, reparent, set active, add or remove a component, set or reset a field, remove a behaviour, and set or reset a behaviour's field. Each operation returns its inverse when it applies. The editor applies an operation to its document, puts it on the undo stack and sends it to the host in `Apply_Operations`. The host applies it to its world. The editor never waits for the host to confirm an edit.
- **Resetting** a field removes it from the scene, so a component's field is zero and a behaviour's field has its class's default, as in a scene that does not set it.
- **Edits of more than one operation:** destroying an entity destroys its descendants first, each with its own operation, so undo creates each after its parent. Duplicating copies an entity and its descendants with new scene IDs, and a reference inside the copy refers to the copy. Reparenting sets the entity's `Local_Transform`, or for a new root its `Transform`, so it stays where it is in the world: `SceneEdits` composes poses as the engine's propagation does.
- **Transactions:** an interaction groups its operations into one undo entry. A gizmo drag or a drag on a number field sends field values while it moves, and makes one undo entry when the mouse is released. A step that replaces the step before it, such as the next value of the same field, takes its place, so the entry has the last value and the first inverse. An operation that does not fit the document, such as one for an entity that is not there, undoes the transaction's earlier steps and goes to the console.
- **Undo and redo** are Ctrl+Z and Ctrl+Y. A new edit after an undo drops the entries after it. The document is dirty when its position in the history is not the one that the file has, so undoing back to it makes the document clean again. The title bar and the status bar mark a dirty scene with a dot.
- **Save** (Ctrl+S) writes the file through a temporary file, so a crash never leaves half a file. Save As (Ctrl+Shift+S) writes a new file, which the editor then edits. Closing the editor or opening another scene with unsaved changes asks whether to save them.
- **Selection:** the selection is a list of entities. The last one selected is the primary one: the gizmo sits on it, and the properties panel names it. Ctrl toggles an entity in the outliner and the viewport, Shift adds, and Ctrl+A selects every entity. Delete and Duplicate act on every selected entity, without those under another selected entity, in one undo entry.
- **Selection by scene ID:** the editor keeps the selected entities' scene IDs, so a resync, which gives every entity a new handle, keeps the selection. An entity that an edit creates is selected when the host reports it. Entities that the game spawned have no scene ID, and the editor does not edit them.
- **Resync:** when the link connects, the editor sends the whole document as a scene snapshot (`Load_Scene`), and the host replaces its world with it. This is the same path after a crash, a host restart and a soft restart. The host reports a soft restart with an event, and the editor sends the snapshot again. The game loads its own scene at `init`, so without an open document the host shows that.
- **Opening a scene:** `--scene <file>`, or Open Scene (Ctrl+O). A file with an error does not open: its problems go to the console with their lines, and the open scene stays. The title bar and the status bar show the scene's file.
- **Rejected operations:** the host can refuse an operation, for example a field that the new DLL no longer has. It sends `Edit_Problems` with the entity's scene ID and the reason. The document keeps the operation, and the editor shows a warning on the entity, in the outliner and the properties panel, and in the console. A scene load sends its problems too, which replace the ones before them. The document is never changed to match the host.
- **The game's side** maps scene IDs to entities. A load fills the map, and a stale entry, such as for the game's own scene at `init`, makes the game build it again from every entity's `Scene_Entity`. The operations use the loader's procedures for an entity, a component or a field, so they convert values and report problems as a load does.

### Modes

| Mode | The game runs | Edits |
|---|---|---|
| Edit | Transform propagation, render extraction and editor rendering: the selection outline, the gizmo, the icons, the helpers and the debug lines. No `Fixed`, `Update` or `Late` systems, and no scripts. | Operations on the document |
| Play | The full frame, as the game shows it: no editor rendering and no debug layer. | None. The outliner and properties show the host's world, read-only, with a tint. |
| Paused | As in Play, and the full frame of one fixed tick for each step. | None |

- **The game decides what runs.** The editor sends `Set_Mode`, and the game's editor package keeps the mode, because only the game knows what its frame runs. `editor.simulation` tells the game's frame whether to run its world and with what time step: the frame's in Play, one fixed tick for each `Step_Frame` while paused, and nothing in Edit. A frame that does not run its world still propagates transforms (`ecs.update_transforms`), so edits of a parent move its children, and it still renders.
- **No script code outside Play.** While the world does not run, the script runtime is quiet (`script.set_quiet`), and the game settles the world's changes into it each frame (`script.settle`). A behaviour whose entity a scene load or an edit removes ends without `on_disable` or `on_destroy`, and its memory is free. One that an edit deactivates stops its coroutines without `on_disable`. One that an edit activates gets `awake` and `on_enable` in the first script phase of Play, and one that was awake before gets no `on_enable`. Stop counts as Edit, so the behaviours of the play world end the same way when the scene replaces it. Paused is quiet too, except during the frame of a step. Without an editor, the world always runs. A game that an editor has just linked to is in Edit, and so is the fresh state of a soft restart.
- **The viewport shows the game's frame alone outside Edit.** The selection outline, the gizmo, the light, volume and camera icons and their helper shapes, and the game's own debug lines are the debug layer, which the game draws only while editing (`editor.editing`, `editor.debug_shown`; see [Rendering](../rendering/layers-and-output.md#debug)). A click in the viewport still picks and selects, so the outliner and the properties follow it, and Stop brings the outline back on the selection that the editor sends again.
- **Play** (F5) starts the world that the game has, or goes on after a pause. Behaviours that the scene loaded wake in the first script phase, so they get `awake` and `start` as for a scene load. The game's main script keeps running across a stop, as it does across a scene load.
- **Pause** (F6) stops the world where it is, and **Step** (F10) runs one frame of one fixed tick.
- **Stop** (Shift+F5) sets Edit, and the editor sends its scene again, which replaces the game's world. Nothing from play mode reaches the document. Restart Host has no shortcut now: its Shift+F5 went to Stop.
- **No edits while playing.** The shell refuses edits, undo and redo outside Edit, with a line in the console, and it has no document entity for the selection, so the properties panel shows the game's values read-only, there is no gizmo, and the outliner does not reparent. An edit that a drag has under way ends when play starts. Selection, visibility and lock still work. The viewport's frame and the status bar are green while playing and amber while paused.
- **Camera:** in Play and Paused, the game draws from its own camera. The Free Camera command lets the viewport fly the editor's camera, and the game draws from it, instead of giving the game the viewport's input.
- **Input:** while the game plays and the viewport has focus, the viewport sends its keyboard and mouse to the host as `Editor_Input` events: keys and buttons down and up, the mouse's position in frame pixels, and the wheel. The host queues them in `core`, which applies them to the frame's `core.Input` after the window's own messages, so the game reads them as it reads a window. The function keys stay the editor's as well, so F5 and Shift+F5 work while the game has the keys. Losing focus, and the editor's link closing, release every key.
- Entities that the game spawns at run time have no scene ID. The outliner shows them in play mode under their handle.

The mesh files that the scene's entities place are documents of their own beside the scene, `MeshDocument`s in a `MeshSet`, whose edits are `MeshOperation`s on the scene's undo stack, so one Ctrl+Z undoes the last thing the user did whichever file it touched; the host draws them from memory while they are edited (see [Mesh editing](mesh-editing.md#undo-and-saving)). Save writes the scene, then every dirty mesh.

## Scenes

A scene is a source asset with a GUID and a `.meta` file, like every other asset (see [Content pipeline](../content/identity-and-cooking.md#identity)). The cooker parses scenes with `asset_format.scene_parse`, and the editor with `SceneFile` in `Cinnabar.Editor.Document`. The two must agree.

- **Scene IDs:** each entity in a scene has a 64-bit random ID, nonzero and unique in its scene. Operations, the link and the scene file use scene IDs. The host maps them to entity handles, which change on every load. The loader gives each entity a `Scene_Entity` component with its scene ID, and `Entity_Info` carries it to the editor.
- **Text source:** a scene file is text, so it diffs and merges. It starts with `scene 1`, the format's version. It has one block per entity, sorted by scene ID, so an edit changes only the lines of the entity it touches. Fields are written by name. A line that starts with `#` is a comment, and the editor keeps only the comments before `scene 1`.
- **Entity keys:** an entity block has `name`, `parent` (a scene ID) and `active = false` for a disabled entity, then its `component` and `behaviour` blocks with their fields indented. An entity key that the editor does not know is a warning, and the editor writes it back unchanged.
- **Values:** `true` and `false`; a number, or an array of up to four numbers such as `[0, 0.7071068, 0, 0.7071068]`; a quoted string with `\"`, `\\`, `\n` and `\t`; a scene ID after `@`, such as `@1b04c7e95a2f3d88`, or `@0` for none; an asset's GUID after `$`, such as `$9db8150cc7215ffc2708d20d77cf60bf`, or `$0` for none; and a bare word, such as an enum value's name. A number written as an integer is kept exactly. The writer gives every float a point or an exponent, so it reads back as a float.
- **Components by stable ID:** a component block gives the [stable ID](../world/ecs.md#ecs) and the type's name. The loader uses the ID. The name is for people and for error messages.
- **Positions** are raw `i64` values (see [World](../world/positions-and-transforms.md#where-positions-go)), so a scene round-trips exactly. The editor shows meters.
- **Unknown data round-trips.** A component ID or a field that the current DLL does not know is kept, written back unchanged, and reported as a warning. A broken build therefore never deletes scene data.
- **Behaviours** are written by script GUID, with their field values by name.
- **Names:** the engine's `Name` component holds up to 63 bytes in the component itself, because component storage holds no pointers. A longer name is cut at a character boundary. The outliner and the properties panel show names, and `Entity_Info` carries them.
- **Prefab paths:** an entity in a prefab instance is identified by a path: the instance's scene ID, then `#` and the entity's scene ID in the prefab, such as `5f3a9c01e2b47d10#a90b3e7f15c4d2e8`. A prefab in a prefab adds a level for each nesting. The prefab's asset GUID is not in the path, because every instance of a prefab has the same one. The path stays the same when the prefab changes, so overrides in the scene still find their entities.

A sketch of the format:

```
scene 1

entity 5f3a9c01e2b47d10
name = "Door"
parent = @1b04c7e95a2f3d88
component 1 Transform
	position = [16777216, 0, -754974720]
	rotation = [0, 0.7071068, 0, 0.7071068]
	scale = [1, 1, 1]
behaviour 9d2e41c0b7a35f6e81c4d2a90b3e7f15
	open_angle = 90
	trigger = @7a11e0c3d94b2f56
```

**Cooking:** the cooker cannot lay out native components, because their types exist only in the DLL. The cooked blob therefore stores each field as a tagged value with the hash of its name (see [Content pipeline](../content/kinds/scenes.md#scenes)), and the scene loader in `lib/engine/scene` matches them to the fields of the registered types at load. The same code applies a snapshot from the editor.

**Loading** replaces every entity in the world, between frames, with `ecs.despawn_all`. After it, the world gives out the freed slots from the lowest index up, so the handles, and with them the outliner's order, follow the scene's order. The loader spawns every entity before it sets any field, so a field can refer to an entity later in the file.

- A field that the scene does not set is zero. A value is converted to its field's kind: an integer must fit, an enum takes a name or an integer, a position takes three integers, and an entity takes a scene ID.
- What the world cannot use is skipped with a warning, and the rest of the entity still loads: a component that the game does not register, a field that its type does not have, a value that does not fit, a scene ID that is not in the scene, or a behaviour field that the class does not declare.
- `Previous_Transform` starts equal to `Transform`, so nothing interpolates from where the old world was. Behaviours wake in the next script phase.
- The `Name`, `Parent`, `Inactive` and `Scene_Entity` components come from the entity's keys, so a component block for one of them is ignored.
- A component that cooked scenes use gets an explicit ID (see [World](../world/ecs.md#component-registry)). The sample game's components are 1001 and up.

## Future work

- **Prefabs.** A prefab is a scene asset whose entities a scene instantiates with overrides. The scene format reserves the instance paths (`<instance>#<entity>`), the properties panel's Reset already means "back to the prefab's value", `World.spawn(prefab, ...)` is reserved in scripts, and the content browser's glTF import waits to make prefabs of node hierarchies (see [Content pipeline](../content/README.md#future-work)). The design is the document model's: an instance's overrides are operations against the prefab's entities. Do this before any scene is built from repeated props; it is the largest missing piece of the editor.
- **Large worlds and several scenes.** One scene file per world does not scale, and positions reach ±2^38 m. Streaming splits a world into scenes that load and unload separately ([Architecture](../overview/README.md#future-work)), and the editor then edits several open scenes, each with its own document, undo stack and dirty state, in one outliner. Do this with level streaming.
- **Asset references in behaviour fields.** `Field.asset(kind)` is reserved in the prelude and the properties panel already edits asset fields of components (see [Rendering](../rendering/assets.md#asset-fields)). Behaviours need the field kind in the cooker's schema, the scene's `$` values, and the blob's field records. Do this when a script needs to name a sound, a prefab or a mesh.
