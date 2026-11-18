# API

What scripts see: the value types, entities and component references, the engine's global libraries, and the mapping from Unity's names. Behaviours have [their own document](behaviours.md).

**In this document:** [Values](#values) · [The entity and component view](#the-entity-and-component-view) · [Engine libraries](#engine-libraries) · [Save](#save) · [Game.quit](#gamequit) · [Display](#display) · [Random](#random) · [Unity mapping](#unity-mapping)

## Values

| Script type | Luau representation | Allocates | Notes |
|---|---|---|---|
| Number | `number` (`f64`) | No | |
| 64-bit ID | `integer64` | No | Component IDs, raw values for the editor link |
| `vector` | Built-in `vector`, 3 × `f32` | No | Unity's `Vector3`. Matches `[3]f32` exactly. |
| `Entity` | Tagged light userdata, payload = the 64-bit handle | No | Equality is by value, so entities work as table keys. |
| Component type | Tagged light userdata, payload = the component ID | No | The globals `Transform`, `Health` and so on |
| `Asset` | Tagged light userdata, payload = one more than the index of its GUID in the runtime's table of the assets that scripts refer to | No | From a behaviour's `Field.asset`. Two references to one asset are the same value, so they compare equal and work as table keys. `asset.guid` is its 32 hex digits. At most 4096 assets at once. |
| `WorldPosition` | Tagged userdata, 24 bytes | Yes | `a - b` gives a `vector`, and `p + v`, `v + p` and `p - v` give a `WorldPosition`. See [World](../world/positions-and-transforms.md#where-positions-go). |
| `Quaternion` | Tagged userdata, 16 bytes | Yes | `q * q`, `q * v` |
| Component reference | Tagged userdata: entity handle and component ID | Yes | The result of `entity:get(Health)` |
| Behaviour instance | Table with the class as its metatable | Yes | The result of `entity:get(Door)` |

- All light userdata share one metatable in Luau. Its metamethods dispatch on the light userdata tag. Full userdata get one metatable per tag with `lua_setuserdatametatable`. `typeof` gives `Entity`, `ComponentType`, `Asset`, `WorldPosition`, `Quaternion` and `ComponentRef`.
- Userdata tags and light userdata tags are engine constants. They never depend on registration order.
- Luau sets each metatable only once, so `init` makes them, and a code reload keeps them. Their metamethods are dispatcher closures, so they reach the new DLL's bindings.
- `WorldPosition` and `Quaternion` values are immutable, so scripts can share them, as `Quaternion.identity` and `WorldPosition.origin` are shared.

### Globals that change

In a sandbox, `luau_load` resolves a chain such as `Time.delta` once, and keeps the value. A field that changes after the script loads would look frozen. The compiler's `mutableGlobals` option turns this off for the globals that `format.script_mutable_globals` lists, `Time` and `Input`, so their fields are read each time the code runs. The cooker and `script.compile` both pass the list. A new global whose fields change must go in it.
- Entity handles are value types, so a script never sees a stale object. `entity:is_alive()` checks the generation. Any other use of a dead entity raises an error, like Unity's `MissingReferenceException`.

## The entity and component view

- `entity:get(T)` returns a component reference for a native component type, or the instance for a behaviour class. It returns `nil` if the entity does not have it. `entity:has(T)` does not allocate.
- **A component reference holds no pointer.** Each field access looks up the entity's row again, because storage moves when components are added or removed. A reference to a removed component raises an error.
- **Fields come from Odin type info.** The game exposes a native component with `script.expose(r, Health)` in its `Register_Proc`, or `script.expose(r, Health, default)` to give `entity:add` a starting value other than zero. The component must already be registered with the world. Registration walks the struct's fields and maps each supported field type: numbers, `bool`, enums (as strings), `[3]f32` (as `vector`), `quaternion128`, `World_Position` and `Entity`. Other fields are hidden from scripts. The struct tag `script:"read"` makes a field read-only, and `script:"-"` hides it. A value of the wrong type raises an error. The engine exposes `Transform`, `LocalTransform` and `Parent`, and the renderer's `Tint`, whose default is white, intensity 1 and alpha 1 (see [GPU scene](../rendering/gpu-scene.md#tints)).
- **Names:** the script name of a type is its Odin name without underscores (`Local_Transform` becomes `LocalTransform`). Field and method names are snake_case, the same as the Odin fields that they come from.
- **Writes are immediate.** The script phase is serial, so a field write goes straight to storage. A write that affects the simulation takes effect at the next fixed tick.
- **`entity.transform`** is a reference with Unity's properties: `position` (`WorldPosition`), `rotation`, `scale`, `local_position`, `local_rotation` and `local_scale` for children, and the read-only axes `forward` (+Z), `up` (+Y) and `right` (+X), as in Unity. Setting `position`, `rotation` or `scale` on a child computes its `Local_Transform` from the parent, so the pose stays after propagation. Setting a local field updates the world pose at once.
- **Entity methods:** `get`, `has`, `add`, `remove`, `destroy`, `is_alive`, `teleport(position, rotation?)` (no interpolation, see [World](../world/time.md#fixed-and-variable-rate)), `offset_to(other)` and `move(v)`, which do not allocate a `WorldPosition`, and `set_parent(parent)`, which keeps the world pose, like Unity's `SetParent`. `entity.parent` is the parent or `nil`. `add` and `remove` refuse `Parent` and `LocalTransform`: `set_parent` keeps the two consistent.

### Structural changes

Scripts change the world structure **immediately**, except for despawns. The script phase is serial, and no job reads the world while it runs.

- `World.spawn(position?, rotation?)` creates an entity with a `Transform` at once and returns its handle. `World.spawn(prefab, position?, rotation?)`, with an `Asset` of a cooked prefab first, creates an instance of it with its root at the pose and returns the root, and every behaviour in it gets `awake` and `on_enable` before `spawn` returns, in the prefab's entity order, as in Unity's `Instantiate` ([Editor: Prefabs](../editor/prefabs.md#spawning-at-run-time)). The game registers it with `scene.register_scripts` in its `Register_Proc`; without that, it raises an error. A root that a behaviour spawns, with or without a prefab, belongs to the scene of the behaviour's entity, and goes when that scene unloads ([World: Scenes: Ownership](../world/scenes.md#ownership)).
- `entity:add(T, values?)` and `entity:remove(T)` take effect at once. `values` is a table of field values, and `add` returns the component.
- `entity:destroy()` is deferred to the end of the script phase or fixed step, as in Unity's `Destroy`. It goes into the step's command buffer, which the end of the step applies: phase 6 of the frame for the script phase. Outside a step, as in a main script's top level or `on_reload`, it despawns at once (see [Behaviours: Outside a phase](behaviours.md#outside-a-phase)).
- `World.query(T, ...)` returns an array of the matching entities, collected before the loop starts. Structural changes inside the loop are therefore safe. A query from a script scans every archetype, so performance-critical work belongs in a native system.
- `World.editing()` is true while the script runs in the editor's Edit mode, as a behaviour with `edit_mode` does there ([Behaviours: Edit mode](behaviours.md#edit-mode)).
- `World.version()` gives a version, and every later write is newer than it. `World.changed(since, T, ...)` returns an array of the entities in the chunks where a component `T` was written since the version, or that gained a row. It works by chunk (see [ECS: Change versions](../world/ecs.md#change-versions)), so it can give entities that did not change, and it does not report the entities that left. A script's own writes count.

## Engine libraries

| Global | Contents |
|---|---|
| `World` | `spawn`, `query`, `version`, `changed` |
| `Quaternion` | `identity`, `new(x, y, z, w)`, `euler(degrees)`, `angle_axis(degrees, axis)`, `look_rotation(forward, up?)`, `slerp`, `angle`, `rotate_towards(from, to, max_degrees)`. Methods: `inverse`, `normalized`, `euler`, `approx`, `angle_to`, `rotate_towards`, `slerp`. Fields `x`, `y`, `z`, `w`. |
| `WorldPosition` | `origin`, `from_meters(x, y, z)` (for authoring), `lerp`. Methods: `lerp`, `to_meters` (for display). |
| `Time` | `delta` (the frame, or the tick in the fixed step), `time` (world time), `real_time`, `frame`, `fixed_delta`, `alpha` (the interpolation fraction), `in_fixed` (true in the fixed step), `real_delta` (the frame's seconds, which neither the time scale nor a pause changes), `scale` (the time scale that `Game.set_time_scale` set, 1 by default, also while paused) |
| `Game` | `set_paused(paused)`: a paused world takes no time while the scripts and the UI run on; `set_time_scale(scale)`: how fast the world's time runs, kept between 0 and 4 and 1 when it is not a number, for hit-stop and slow motion (see [Time: Time scale](../world/time.md#time-scale)); `quit()`: ends the game, except under the editor (see [Game.quit](#gamequit)) |
| `Scene` | `load(scene)`: loads a scene `Asset` beside the scenes that are loaded, at the start of the next frame, and gives its number; `unload(number)`: unloads one scene with what it owns, at the start of the next frame; `of(entity)`: the number of the scene that an entity belongs to, or nil; `pending(behaviour, field)`: the scene `Asset` that an entity field of the behaviour waits for, or nil; `state(number)`: `"loading"`, `"ready"`, or nil for a scene that is not loaded. A `World_Streamer` entity's behaviours get `on_scene_loading`, `on_scene_ready`, `on_scene_unloaded` and `on_scene_failed` with `(number, scene)` ([World: Streaming: Events](../world/streaming.md#events)). See [World: Scenes: Scripts](../world/scenes.md#scripts). |
| `Camera` | The scene's camera component, which the standard game exposes: `vertical_fov` (in radians), `near`, `far`, `projection` (`"Perspective"` or `"Orthographic"`), `orthographic_height` (in meters), `view_model_fov` (in radians) and `view_model_near`. 0 in a field means its default. The game reads the camera each frame, so `entity:get(Camera).vertical_fov = 1.2` shows in that frame (see [Rendering: Components](../rendering/assets.md#components)) |
| `Input` | `is_down(key)`, `was_pressed(key)`, `was_released(key)`, `mouse_position` and `mouse_delta` (vectors in pixels), `scroll` (wheel notches), `gamepad_connected(pad)`, `gamepad_is_down(pad, button)`, `gamepad_was_pressed(pad, button)`, `gamepad_was_released(pad, button)`, `gamepad_axis(pad, axis)` (pads in slots 1 to 4), `gamepad_rumble(pad, low, high, seconds)` (runs the low-frequency and high-frequency motors, each 0 to 1, for up to 10 seconds, and 0 seconds stops them; the pad stops by itself when the window loses the focus, and it does not vibrate under the editor), `gamepad_direction_down(pad, direction)` and `gamepad_direction_pressed(pad, direction)` (a stick pushed one way, or a trigger pulled, as a digital input), `define_action(name, defaults)`, `action_down(name, pad?)`, `action_pressed(name, pad?)`, `action_released(name, pad?)` and `action_value(name, pad?)` (named actions; with a pad of 1 to 4 only that pad is read, with nil the keys and every pad), `bindings(name)`, `set_bindings(name, bindings)` and `reset_bindings(name?)` (what the player remaps; a binding is a string such as `"key:W"`, `"pad:A"` or `"pad:LeftStickUp"`), `any_pressed(device?)` (the binding of the key, button or direction pressed this frame, for "press the new key"; `"keyboard"`, `"gamepad"` or both), `text` (the characters typed since the last frame, in UTF-8), `composition` and `composition_cursor` (what an IME composes, and the bytes of it before the cursor). See [Input](../core/input.md#input). |
| `Key` | `Key.A`, `Key.Num0`, `Key.Space`, `Key.LeftShift`, `Key.MouseLeft` and the other values of `core.Key` |
| `GamepadButton` | `GamepadButton.A`, `GamepadButton.LeftBumper`, `GamepadButton.DpadUp` and the other values of `core.Gamepad_Button` |
| `GamepadAxis` | `GamepadAxis.LeftX`, `GamepadAxis.RightY`, `GamepadAxis.LeftTrigger` and the other values of `core.Gamepad_Axis` |
| `GamepadDirection` | `GamepadDirection.LeftStickUp`, `GamepadDirection.RightTrigger` and the other values of `core.Gamepad_Direction` |
| `Debug` | `log`, `warn`, `error` |
| `Random` | The world's generator: `value()`, `range(min, max)`, `integer(min, max)`, `seed(n)`, `get_seed()`, `inside_unit_sphere()`, `on_unit_sphere()`, `inside_unit_circle()`, `rotation()` (see [Random](#random)) |
| `Render` | The render quality, for a settings menu, where the game defines it (see [Render](#render)) |
| `Save` | `read(name)` and `write(name, data)`: a table of strings, numbers and booleans in a file of the player's data, where the game defines it (see [Save](#save)) |
| `Display` | The window mode, the resolution, HDR and its brightness, for an options menu, where the game defines it (see [Display](#display)) |
| `Profile` | `begin(name)`, `finish()`, `zone(name, fn, ...)`: zones in the editor's profiler (see [Profile](#profile)) |
| `Audio` | `play(sound, position?, gain?, bus?, pitch?)` and `set_bus_gain(bus, gain)`. See [Audio: Scripts](../audio/design.md#scripts). |
| `Physics` | Queries (`raycast`, `raycast_all`, `sphere_cast`, `box_cast`, `capsule_cast`, `overlap_sphere`, `overlap_box`, `overlap_capsule`), `layers(...)`, `gravity()` and `set_gravity`, the effects on a body, with its entity first (`add_force`, `add_impulse`, `velocity`, `set_velocity`, `sleep` and the rest), and a joint's `set_motor(entity, mode, target?, max?)` and `set_joint_enabled(entity, enabled)`, and a character's `move_character(entity, velocity, gravity?)`, `character_ground(entity)` and `is_grounded(entity)`, where the game defines it (see [Physics: Scripts](../physics/design.md#scripts)) |
| `Ui` | A document's elements by its entity and their ids: `set`, `set_text`, `set_visible`, `focus`, `get_text`, `bind`, `add` and `remove`, and `wants_input()`, where the game defines it. The entity's behaviours get the document's events as `on_<event>(id)` (see [UI: Scripts](../ui/design.md#scripts)) |
| `Animation` | An Animator's graph's parameters by name, with its entity first (`set_float`, `set_bool`, `trigger`, `reset_trigger`, `get_float`, `get_bool`), its current `state` and its `root_motion` in the world, where the game defines it (see [Animation: Scripts](../animation/design.md#scripts)) |
| `Blackboard` | An agent's blackboard by its keys' names: `get(entity, key)` and `set(entity, key, value)`, where the game defines it (see [AI: Agents: Scripts](../ai/agents.md#scripts)) |
| `Agent` | `current_action(entity)`: the name of the action that an agent runs, or nil; `decision(entity)` and `set_decision(entity, decision)`: its decision as an `Asset`, which a script can swap; `scores(entity)`: what its decision scored in its last think, by option and consideration, or nil; `plan(entity)`: its goal or its methods, its plan and the step that runs, or nil; where the game defines them (see [AI: Agents: Scripts](../ai/agents.md#scripts)) |
| `Action`, `Param` | `Action.define(name, params)` makes an action class, which agents' decisions start by name, with its parameters from `Param` (see [AI: Agents: Script actions](../ai/agents.md#script-actions)) |
| `Perception` | `noise(position, loudness, tag, source?)`: a noise that agents hear in the next tick, where the game defines it. An agent's behaviours get `on_perceive(entity, sense)` and `on_forget(entity)` (see [AI: Perception: Scripts](../ai/perception.md#scripts)) |
| `Navigation` | Queries on the navmeshes by an agent type's name: `nearest(point, agent, extents?)`, `find_path(start, goal, agent, max_nodes?)`, `raycast(start, finish, agent)` and `random_point(around, radius, agent)`, an entity's path: `request_path(entity, goal)` and `path(entity)`, and an agent's moves: `move_to(entity, target)`, which gives the move's ticket, `move_status(entity, ticket)`, `stop(entity)`, `arrived(entity)` and `velocity(entity)`, where the game defines it (see [AI: Navigation: Scripts](../ai/navigation.md#scripts)) |
| `Sprites` | A Sprite_Renderer's animations and frames by their names in its sheet, with its entity first: `play`, `stop`, `set_frame`, `animation` and `finished`, where the game defines it. See [Rendering: 2D](../rendering/2d.md#scripts). |

- **Angles are in degrees**, as in Unity. Euler angles apply z, then x, then y, as in Unity.
- `==` on quaternions is approximate, as in Unity's `==`. `==` on positions is exact.
- An arithmetic result outside the world (±2^38 m) raises an error.

A game adds its own globals with `script.define(r, "Game.frame", procedure, "() -> number")` in its registration procedure: the qualified name gives the binding its stable ID and its place in the definition file ([Types and tooling](tooling-and-hot-reload.md#types-and-tooling)).

## Render

The render quality's bindings, for a settings menu in Luau (`lib/engine/project/scripts.odin`). A game defines them in its registration procedure with `project.define_quality_bindings(r, &state.script_quality)`, where `script_quality` is a `project.Script_Quality` in its `Game_State` that `project.script_quality(&renderer, settings_path)` made, so its address stays across reloads. The bindings find it in the VM's registry.

| Binding | What it does |
|---|---|
| `Render.quality()` | The renderer's quality as a `RenderQuality` table |
| `Render.set_quality(t)` | Makes the fields that `t` gives the quality's from the next frame on, as far as the device can do them. A `preset` sets every feature first |
| `Render.caps()` | What the device can do: `ray_query`, `vendor`, `video_memory` in bytes, `aa`, the anti-aliasing techniques that it runs, `gi`, the global illumination's, and `reflections`, the reflections', with `Ray_Traced` only where the device has `ray_query` |
| `Render.presets()` | `{ "Low", "Medium", "High", "Ultra" }` |
| `Render.save_quality()` | Writes the quality to the user settings file, as the player's choice on this machine; false if it could not |

- **A quality table** has the settings files' quality keys (see [Rendering: Saved quality](../rendering/quality.md#saved-quality)): `preset`, `shadows`, `ray_traced_shadows`, `ao`, `ao_level`, `gi`, `gi_level`, `fog`, `aa`, `render_scale`, `lod_error`, `mesh_pool`, `texture_pool`, `texture_anisotropy`, `virtual_shadows`, `reflections`, `reflections_level`, `clouds`, `virtual_shadow_cache` and `atlas_shadow_cache`. Enums are their names as strings (`"Ultra"`, `"Fsr"`), `ray_traced_shadows`, `virtual_shadows`, `virtual_shadow_cache` and `atlas_shadow_cache` booleans, `render_scale`, `lod_error`, `mesh_pool` and `texture_pool` numbers. `preset` is `"Custom"` when the features match no preset.
- **`set_quality` checks** each field as the settings files' parser does, and raises an error, which changes nothing, for a field that does not exist or a value that does not fit, such as `aa = "Msaa"`. A technique that the device cannot run is limited as `clamp_quality` limits it: FSR becomes temporal AA.
- **Types:** `RenderQuality`, `RenderQualityChange`, every field optional, and `RenderCaps` are in `engine.d.luau`.
- **The sample's** `quality_keys.luau` is a settings menu on keys: F9 takes the next preset, Shift+F9 turns traced shadows on or off, Ctrl+F9 takes the next ambient occlusion technique, Ctrl+Shift+F9 the next render scale, F6 the next anti-aliasing technique in `Render.caps().aa`, Shift+F6 the next global illumination technique in `Render.caps().gi`, and Ctrl+F6 the next reflection technique in `Render.caps().reflections`. Each saves.

```lua
-- The next anti-aliasing technique that the device runs, saved as the player's choice.
local q = Render.quality()
local techniques = Render.caps().aa
local i = table.find(techniques, q.aa) or 0
Render.set_quality({ aa = techniques[i % #techniques + 1] })
Render.save_quality()
```

## Save

A save is a table of strings, numbers and booleans in a file of the player's data, such as personal records, options and key bindings (`lib/engine/save`). The standard game defines the bindings, so every project has them. The engine keeps no store: the data lives in the script's own tables, and a script reads a save when it starts and writes it when the player changes something.

| Binding | What it does |
|---|---|
| `Save.read(name)` | The save's entries as a `SaveData` table, or nil when there is no file. A malformed line is a warning in the log with its number, and the other lines are in the table |
| `Save.write(name, data)` | Writes the table to the save, and is true; false if the write failed |

- **Names:** `name` is 1 to 32 of `a` to `z`, `0` to `9`, `_` and `-`. It is the file's stem, so a slash, a dot or a capital raises an error. A save is `<save_dir>/<name>.save`. The folder is `Platform_API.save_dir`: `build/save` in the project's folder under the development host, and `%LOCALAPPDATA%\<game.name>` in a release (see [Building and running](../overview/building-and-running.md#build-layout)).
- **Keys and values:** a key is one or more of `A` to `Z`, `a` to `z`, `0` to `9`, `_` and `.`, so `options.volume` is one key, not a nested table. A value is a string, a number or a boolean. A bad key, a table, a function or another value, and a number that is not finite, raise an error, and `write` then writes nothing.
- **Atomic writes:** `write` replaces the whole file through a temporary file and a rename (`file_write`), so a crash leaves the old save or the new one, never half of one. The keys are written in order, so an unchanged table gives an unchanged file.
- **The format** is text, which a player can read and edit: the first line is `save 1`, then one `key = value` line each. A value is a number, `true`, `false` or a string in double quotes, with the escapes `\"`, `\\`, `\n`, `\r` and `\t`. Blank lines and lines that start with `#` are skipped. A number is the shortest text that reads back as the same value. A file that does not start with `save 1` is not read: `read` gives an empty table and a warning.
- **Type:** `SaveData`, `{ [string]: string | number | boolean }`, is in `engine.d.luau`.

```lua
local options = Save.read("options") or { volume = 0.8, invert_y = false }
options.volume = 0.5
if not Save.write("options", options) then
	Debug.warn("could not save the options")
end
```

## Game.quit

`Game.quit()` ends the game after the current frame, as a Quit button does: `game_update` returns false, and the host's loop or the release's stops. It does nothing while an editor is linked, and logs that the editor keeps the game running, since the editor decides when its game ends. `Game.set_paused(paused)` stops the world's time (see [The game package: The frame](../world/game-package.md#the-frame)).

## Display

The display's bindings, for the Display section of an options menu in Luau (`lib/engine/project/display_scripts.odin`). `game.register_scripts` defines them with `project.define_display_bindings(r)`, after the Render bindings, whose renderer and settings file they use. The window's modes and sizes are in [Presentation: Window modes](../gpu/presentation.md#window-modes).

| Binding | What it does |
|---|---|
| `Display.modes()` | `{ "Windowed", "Borderless", "Fullscreen" }` |
| `Display.resolutions()` | The sizes of the display modes of the window's monitor as `{ width, height }` tables, largest first, each size once |
| `Display.get()` | A `DisplayState`: `mode`, the client size as `width` and `height`, `hdr` (HDR output is on), `hdr_available` (the display is in HDR now) and `paper_white` in nits, the one in effect |
| `Display.set(change)` | Gives the display the fields of a `DisplayChange` that it has, any of `mode`, `width`, `height`, `hdr` and `paper_white`. It applies from the next frame |
| `Display.save()` | Writes `display.mode`, `display.width`, `display.height`, `output` and, if one was set, `display.paper_white` to the user settings file, as `Render.save_quality` does; false if it could not |

- **`set` raises an error**, which changes nothing, for a field that does not exist (and `hdr_available`, which is read only), a `mode` that is not in `Display.modes()`, a size that is not a whole number of pixels from 1 to 16384, a size in `Fullscreen` that is not in `Display.resolutions()`, and a `paper_white` outside 80 to 500. A `width` or `height` alone takes the other from the mode: the size that `Windowed` last had, or in `Fullscreen` the current display mode, or the monitor's own on the way in. `Borderless` covers the monitor whatever the size, and keeps it for `Windowed`. A change that the window refuses, such as in the editor's shared mode, is logged, and `Display.get` shows what the window is.
- **`hdr = true`** asks for the output `Auto`, which is HDR10 on a display in HDR, and keeps an explicit HDR request as it is. `hdr = false` asks for `Sdr`. `CINNABAR_OUTPUT` replaces both.
- **`paper_white`** replaces the volume's and the display's paper white in HDR, in the scene and in the UI.
- **Types:** `DisplaySize`, `DisplayState` and `DisplayChange`, every field optional, are in `engine.d.luau`.
- **The sample's** `display_keys.luau` is such a menu on keys: F5 takes the next window mode, Shift+F5 the next resolution, Ctrl+F5 turns HDR on or off, and Ctrl+Shift+F5 takes the next paper white. Each saves.

```lua
-- Fullscreen at the monitor's largest mode, in HDR, saved as the player's choice.
local largest = Display.resolutions()[1]
Display.set({ mode = "Fullscreen", width = largest.width, height = largest.height, hdr = true })
Display.save()
```

## Profile

Zones of a script's own code in the editor's profiler ([Profiling](../core/profiling.md#zones)). Each callback is already a zone, named after its class, so these split a callback's time further.

| Binding | What it does |
|---|---|
| `Profile.begin(name)` | Opens a zone |
| `Profile.finish()` | Closes the innermost zone that the script opened. With none open, it does nothing |
| `Profile.zone(name, fn, ...)` | Calls `fn(...)` in a zone and returns its results |

- **Zones end with their callback.** A zone that is still open when the callback returns or a coroutine yields is closed there, marked unbalanced in the profiler, and the first one logs a warning. A zone cannot span a `wait`.
- **Names are interned**, so a name built from changing values, such as an entity's ID, fills the profiler's name table. Use fixed names.
- Without the profiler (`-define:PROFILE=false`), the bindings do nothing, and `zone` only calls `fn`.

## Random

The world's random numbers (`lib/engine/script/random.odin`). Use them in place of `math.random` when a replay or a test must repeat. The generator is the engine's, xoshiro256\*\* in `lib/engine/random`, so one seed gives one sequence on every platform. `Navigation.random_point` draws from it too.

| Binding | What it gives |
|---|---|
| `Random.value()` | A number from 0 up to 1, without 1 |
| `Random.range(min, max)` | A number from `min` up to `max`, without `max` |
| `Random.integer(min, max)` | An integer from `min` to `max`, with both, as `math.random(min, max)` gives. Unity's `Range` for integers leaves out `max` |
| `Random.seed(n)` | Makes `n` the world's seed and starts its sequence. `n` is an integer from -2^53 to 2^53 |
| `Random.get_seed()` | The world's seed, for example to log it for a replay |
| `Random.inside_unit_sphere()`, `Random.on_unit_sphere()` | A `vector` inside the sphere of radius 1, or on its surface |
| `Random.inside_unit_circle()` | A `vector` inside the circle of radius 1 in the XY plane, with `z` 0 |
| `Random.rotation()` | A uniform `Quaternion` |

- **One generator for each world.** Its state is in the `Runtime` in `Game_State`, so a code reload keeps it. `math.random` is a different generator, and the world does not seed it.
- **The seed comes from the clock** when `script.init` opens the VM, as in Unity, so each run is different. To repeat a run, a script calls `Random.seed(n)`, or the game calls `script.seed_random(&state.scripts, seed)` from Odin.
- **Play in the editor starts the sequence again.** Each Play from Edit calls `script.restart_random`, so the same play draws the same numbers. Play after Pause continues the sequence (see [Editor: Modes](../editor/document-and-scenes.md#modes)).
- **The same calls give the same numbers.** The sequence depends only on the seed and on the order of the draws. A draw in `update` runs once for each frame, so a different frame rate changes the sequence after it. Draw in `fixed_update` when a replay must repeat at any frame rate.
- **Errors:** `integer` raises an error when a bound is not an integer or `max` is less than `min`. `seed` raises an error when `n` is not an integer in its range.

## Unity mapping

| Unity | cinnabar |
|---|---|
| `GameObject` | `Entity` |
| `MonoBehaviour` | `Behaviour.define` |
| `[SerializeField]`, public fields | `Field.*` in `Behaviour.define` |
| `GetComponent<T>()`, `TryGetComponent` | `entity:get(T)` |
| `AddComponent<T>()` | `entity:add(T, value?)` |
| `Destroy(obj)` | `entity:destroy()`, deferred to the end of the script phase or fixed step; at once outside one |
| `Instantiate(prefab, pos, rot)` | `World.spawn(prefab, position, rotation)` |
| `transform.position` | `entity.transform.position`, a `WorldPosition` |
| `Vector3` | `vector` |
| `Quaternion` | `Quaternion` |
| `Mathf` | `math` and the `vector` library |
| `Time.deltaTime`, `Time.time` | `Time.delta`, `Time.time` |
| `Input.GetKey(KeyCode.Space)`, `GetKeyDown` | `Input.is_down(Key.Space)`, `Input.was_pressed` |
| `Debug.Log` | `Debug.log` |
| `Random.value`, `Random.Range`, `Random.InitState`, `insideUnitSphere`, `onUnitSphere`, `insideUnitCircle`, `rotation` | `Random.value()`, `Random.range(min, max)` for numbers and `Random.integer(min, max)` for integers, `Random.seed(n)`, `Random.inside_unit_sphere()`, `Random.on_unit_sphere()`, `Random.inside_unit_circle()`, `Random.rotation()` (see [Random](#random)) |
| `StartCoroutine`, `yield return new WaitForSeconds(t)` | `self:start_coroutine(fn)`, `wait(t)` |
| `yield return new WaitForFixedUpdate()` | `wait_fixed()` |
| `SendMessage` | `entity:send(name, ...)` |
| `behaviour.enabled`, `OnEnable`, `OnDisable` | `self.enabled`, `on_enable`, `on_disable` |
| `SetActive`, `activeSelf`, `activeInHierarchy` | `entity:set_active(b)`, `entity.active_self`, `entity.active_in_hierarchy` |
| `FixedUpdate` | `fixed_update(dt)`, or a native `Fixed` system for heavy work ([Fixed step](behaviours.md#fixed-step)) |
| `Rigidbody`, `Collider` | `RigidBody`, `Collider` |
| `rb.AddForce(f)`, `rb.velocity` | `Physics.add_force(entity, f)`, `Physics.velocity(entity)` |
| `CharacterController.Move`, `isGrounded` | `Physics.move_character(entity, velocity, gravity?)` in `fixed_update`, `Physics.is_grounded(entity)` (see [Physics: Characters](../physics/design.md#characters)) |
| `AudioSource.PlayClipAtPoint(clip, position)` | `Audio.play(sound, position)` |
| `Physics.Raycast`, `SphereCast`, `OverlapSphere` | `Physics.raycast`, `Physics.sphere_cast`, `Physics.overlap_sphere` |
| `OnCollisionEnter`, `OnCollisionExit`, `OnTriggerEnter`, `OnTriggerExit` | `on_collision_enter(other, point, normal, velocity, impulse)`, `on_collision_exit(other)`, `on_trigger_enter(other)`, `on_trigger_exit(other)`; no `stay` (see [Physics: Events](../physics/design.md#events)) |
| `animator.SetFloat`, `SetBool`, `SetTrigger`, `ResetTrigger` | `Animation.set_float(entity, name, v)`, `set_bool`, `trigger`, `reset_trigger` (see [Animation: Scripts](../animation/design.md#scripts)) |
| `SpriteRenderer.sprite`, `animator.Play(name)` on a 2D sprite | `Sprites.set_frame(entity, name)`, `Sprites.play(entity, name)` (see [Rendering: 2D](../rendering/2d.md#scripts)) |
| `AnimationEvent` | `on_animation_event(name, ...)`, from markers authored in the graph |
| `OnAnimatorMove`, `animator.deltaPosition` | `Animation.root_motion(entity)` or the `RootMotion` component, which nothing applies until gameplay does |
| UI Toolkit's `UIDocument`, `rootVisualElement.Q<Label>(name).text` | `Ui_Document`, `Ui.set_text(entity, id, text)` (see [UI: Scripts](../ui/design.md#scripts)) |
| `Button.clicked` | `click="name"` in the document, and `on_name(id)` on the entity's behaviour |
| `HingeJoint`, `OnJointBreak` | `Hinge_Joint` and the other joints, `on_joint_break(force, torque)` |
| `NavMeshAgent.SetDestination`, `isStopped`, `remainingDistance`, `velocity` | A `NavAgent` with a `Character`, `Navigation.move_to(entity, target)`, `Navigation.stop(entity)`, `Navigation.arrived(entity)`, `Navigation.velocity(entity)` (see [AI: Navigation: Crowds](../ai/navigation.md#crowds)) |
| AI Perception's `OnTargetPerceptionUpdated`, `ReportNoiseEvent` | `on_perceive(entity, sense)` and `on_forget(entity)` on an agent's behaviour, `Perception.noise(position, loudness, tag, source?)` |
| `GameObject.Find` | Not provided. Use entity fields. |
| `Resources.Load` | Not provided. Content refers to content by GUID, so use an asset field. |
