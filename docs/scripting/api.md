# API

What scripts see: the value types, entities and component references, the engine's global libraries, and the mapping from Unity's names. Behaviours have [their own document](behaviours.md).

**In this document:** [Values](#values) · [The entity and component view](#the-entity-and-component-view) · [Engine libraries](#engine-libraries) · [Unity mapping](#unity-mapping) · [Future work](README.md#future-work)

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
- **Fields come from Odin type info.** The game exposes a native component with `script.expose(r, Health)` in its `Register_Proc`, or `script.expose(r, Health, default)` to give `entity:add` a starting value other than zero. The component must already be registered with the world. Registration walks the struct's fields and maps each supported field type: numbers, `bool`, enums (as strings), `[3]f32` (as `vector`), `quaternion128`, `World_Position` and `Entity`. Other fields are hidden from scripts. The struct tag `script:"read"` makes a field read-only, and `script:"-"` hides it. A value of the wrong type raises an error. The engine exposes `Transform`, `LocalTransform` and `Parent`.
- **Names:** the script name of a type is its Odin name without underscores (`Local_Transform` becomes `LocalTransform`). Field and method names are snake_case, the same as the Odin fields that they come from.
- **Writes are immediate.** The script phase is serial, so a field write goes straight to storage. A write that affects the simulation takes effect at the next fixed tick.
- **`entity.transform`** is a reference with Unity's properties: `position` (`WorldPosition`), `rotation`, `scale`, `local_position`, `local_rotation` and `local_scale` for children, and the read-only axes `forward` (+Z), `up` (+Y) and `right` (+X), as in Unity. Setting `position`, `rotation` or `scale` on a child computes its `Local_Transform` from the parent, so the pose stays after propagation. Setting a local field updates the world pose at once.
- **Entity methods:** `get`, `has`, `add`, `remove`, `destroy`, `is_alive`, `teleport(position, rotation?)` (no interpolation, see [World](../world/time.md#fixed-and-variable-rate)), `offset_to(other)` and `move(v)`, which do not allocate a `WorldPosition`, and `set_parent(parent)`, which keeps the world pose, like Unity's `SetParent`. `entity.parent` is the parent or `nil`. `add` and `remove` refuse `Parent` and `LocalTransform`: `set_parent` keeps the two consistent.

### Structural changes

Scripts change the world structure **immediately**, except for despawns. The script phase is serial, and no job reads the world while it runs.

- `World.spawn(position?, rotation?)` creates an entity with a `Transform` at once and returns its handle. `World.spawn(prefab, position?, rotation?)`, with an `Asset` of a cooked prefab first, creates an instance of it with its root at the pose and returns the root, and every behaviour in it gets `awake` and `on_enable` before `spawn` returns, in the prefab's entity order, as in Unity's `Instantiate` ([Editor: Prefabs](../editor/prefabs.md#spawning-at-run-time)). The game registers it with `scene.register_scripts` in its `Register_Proc`; without that, it raises an error.
- `entity:add(T, values?)` and `entity:remove(T)` take effect at once. `values` is a table of field values, and `add` returns the component.
- `entity:destroy()` is deferred to the end of the script phase, as in Unity's `Destroy`. It goes into the script command buffer, which phase 6 of the frame applies.
- `World.query(T, ...)` returns an array of the matching entities, collected before the loop starts. Structural changes inside the loop are therefore safe. A query from a script scans every archetype, so performance-critical work belongs in a native system.

## Engine libraries

| Global | Contents |
|---|---|
| `World` | `spawn`, `query` |
| `Quaternion` | `identity`, `new(x, y, z, w)`, `euler(degrees)`, `angle_axis(degrees, axis)`, `look_rotation(forward, up?)`, `slerp`, `angle`, `rotate_towards(from, to, max_degrees)`. Methods: `inverse`, `normalized`, `euler`, `approx`, `angle_to`, `rotate_towards`, `slerp`. Fields `x`, `y`, `z`, `w`. |
| `WorldPosition` | `origin`, `from_meters(x, y, z)` (for authoring), `lerp`. Methods: `lerp`, `to_meters` (for display). |
| `Time` | `delta` (the frame, or the tick in the fixed step), `time` (world time), `real_time`, `frame`, `fixed_delta`, `alpha` (the interpolation fraction), `in_fixed` (true in the fixed step) |
| `Input` | `is_down(key)`, `was_pressed(key)`, `was_released(key)`, `mouse_position` and `mouse_delta` (vectors in pixels), `scroll` (wheel notches) |
| `Key` | `Key.A`, `Key.Num0`, `Key.Space`, `Key.LeftShift`, `Key.MouseLeft` and the other values of `core.Key` |
| `Debug` | `log`, `warn`, `error`. *`draw_line` waits for a debug renderer.* |
| `Render` | The render quality, for a settings menu, where the game defines it (see [Render](#render)) |
| `Profile` | `begin(name)`, `finish()`, `zone(name, fn, ...)`: zones in the editor's profiler (see [Profile](#profile)) |
| `Physics` | Queries (`raycast`, `raycast_all`, `sphere_cast`, `box_cast`, `capsule_cast`, `overlap_sphere`, `overlap_box`, `overlap_capsule`), `layers(...)`, `gravity()` and `set_gravity`, the effects on a body, with its entity first (`add_force`, `add_impulse`, `velocity`, `set_velocity`, `sleep` and the rest), and a joint's `set_motor(entity, mode, target?, max?)` and `set_joint_enabled(entity, enabled)`, where the game defines it (see [Physics: Scripts](../physics/design.md#scripts)) |

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
| `Render.caps()` | What the device can do: `ray_query`, `vendor`, `video_memory` in bytes, and `aa`, the anti-aliasing techniques that it runs |
| `Render.presets()` | `{ "Low", "Medium", "High", "Ultra" }` |
| `Render.save_quality()` | Writes the quality to the user settings file, as the player's choice on this machine; false if it could not |

- **A quality table** has the settings files' quality keys (see [Rendering: Saved quality](../rendering/quality.md#saved-quality)): `preset`, `shadows`, `ray_traced_shadows`, `ao`, `ao_level`, `gi`, `gi_level`, `fog`, `aa`, `render_scale` and `lod_error`. Enums are their names as strings (`"Ultra"`, `"Fsr"`), `ray_traced_shadows` a boolean, `render_scale` and `lod_error` numbers. `preset` is `"Custom"` when the features match no preset.
- **`set_quality` checks** each field as the settings files' parser does, and raises an error, which changes nothing, for a field that does not exist or a value that does not fit, such as `aa = "Msaa"`. A technique that the device cannot run is limited as `clamp_quality` limits it: FSR becomes temporal AA.
- **Types:** `RenderQuality`, `RenderQualityChange`, every field optional, and `RenderCaps` are in `engine.d.luau`.
- **The sample's** `quality_keys.luau` is a settings menu on keys: F9 takes the next preset, Shift+F9 turns traced shadows on or off, Ctrl+F9 takes the next ambient occlusion technique, Ctrl+Shift+F9 the next render scale, and F6 the next anti-aliasing technique in `Render.caps().aa`. Each saves.

```lua
-- The next anti-aliasing technique that the device runs, saved as the player's choice.
local q = Render.quality()
local techniques = Render.caps().aa
local i = table.find(techniques, q.aa) or 0
Render.set_quality({ aa = techniques[i % #techniques + 1] })
Render.save_quality()
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

## Unity mapping

| Unity | cinnabar |
|---|---|
| `GameObject` | `Entity` |
| `MonoBehaviour` | `Behaviour.define` |
| `[SerializeField]`, public fields | `Field.*` in `Behaviour.define` |
| `GetComponent<T>()`, `TryGetComponent` | `entity:get(T)` |
| `AddComponent<T>()` | `entity:add(T, value?)` |
| `Destroy(obj)` | `entity:destroy()`, deferred to the end of the script phase |
| `Instantiate(prefab, pos, rot)` | `World.spawn(prefab, position, rotation)` |
| `transform.position` | `entity.transform.position`, a `WorldPosition` |
| `Vector3` | `vector` |
| `Quaternion` | `Quaternion` |
| `Mathf` | `math` and the `vector` library |
| `Time.deltaTime`, `Time.time` | `Time.delta`, `Time.time` |
| `Input.GetKey(KeyCode.Space)`, `GetKeyDown` | `Input.is_down(Key.Space)`, `Input.was_pressed` |
| `Debug.Log`, `Debug.DrawLine` | `Debug.log`, `Debug.draw_line` |
| `Random` | `Random`, seeded per world |
| `StartCoroutine`, `yield return new WaitForSeconds(t)` | `self:start_coroutine(fn)`, `wait(t)` |
| `yield return new WaitForFixedUpdate()` | `wait_fixed()` |
| `SendMessage` | `entity:send(name, ...)` |
| `behaviour.enabled`, `OnEnable`, `OnDisable` | `self.enabled`, `on_enable`, `on_disable` |
| `SetActive`, `activeSelf`, `activeInHierarchy` | `entity:set_active(b)`, `entity.active_self`, `entity.active_in_hierarchy` |
| `FixedUpdate` | `fixed_update(dt)`, or a native `Fixed` system for heavy work ([Fixed step](behaviours.md#fixed-step)) |
| `Rigidbody`, `Collider` | `RigidBody`, `Collider` |
| `rb.AddForce(f)`, `rb.velocity` | `Physics.add_force(entity, f)`, `Physics.velocity(entity)` |
| `Physics.Raycast`, `SphereCast`, `OverlapSphere` | `Physics.raycast`, `Physics.sphere_cast`, `Physics.overlap_sphere` |
| `OnCollisionEnter`, `OnCollisionExit`, `OnTriggerEnter`, `OnTriggerExit` | `on_collision_enter(other, point, normal, velocity, impulse)`, `on_collision_exit(other)`, `on_trigger_enter(other)`, `on_trigger_exit(other)`; no `stay` (see [Physics: Events](../physics/design.md#events)) |
| `HingeJoint`, `OnJointBreak` | `Hinge_Joint` and the other joints, `on_joint_break(force, torque)` |
| `GameObject.Find` | Not provided. Use fields or a `Name` index. |
| `Resources.Load` | Not provided. Content refers to content by GUID, so use an asset field. |

## Future work

- **Asset fields of components in scripts.** `expose` skips a component's asset fields ([Rendering](../rendering/assets.md#asset-fields)); they could read and write the `Asset` value that behaviours' fields hold ([Values](#values)). Why: a script cannot swap a mesh or a material. When: with the first script that needs it.
- **`Debug.draw_line`.** The debug renderer exists ([Rendering](../rendering/layers-and-output.md#debug)); the binding does not. One binding each for `line`, `box`, `sphere` and `arrow`, taking `WorldPosition`s and a color.
- **`Random`.** A per-world seeded generator, as the Unity mapping promises, so that replays and tests are deterministic. Luau's `math.random` is per-VM and unseeded by the world.
- **A `Name` index.** `GameObject.Find` stays absent; a maintained index on `Name` would give `World.find(name)` without a scan ([World](../world/README.md#future-work)).
