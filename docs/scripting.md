# Scripting

All gameplay logic that spans frames (coroutines, timers, sequences, "wait two seconds") runs in sandboxed Luau, not in the job system. See [Architecture](architecture.md#scripting) for the overview, [World](world.md#the-script-view) for how scripts see entities and components, and [Content pipeline](content-pipeline.md#scripts) for how scripts are cooked and loaded.

The reference API is Unity's. A scripter who knows `GameObject`, `MonoBehaviour`, `GetComponent` and `StartCoroutine` must find the same concepts here, under the names in [Unity mapping](#unity-mapping). The design differs from Unity only where the ECS, fixed-point positions or hot reload require it.

## Packages

| Package | Side | Responsibility |
|---|---|---|
| `lib/core/luau` | Shared | Odin bindings to the Luau C API: VM, compiler and code generator. Its `CMakeLists.txt` builds Luau. The `LUAU_SHARED` config selects `luau.dll` or the static libraries. |
| `lib/core/script` | Host | Package `script_host`: the VM's heap, and every function pointer that Luau stores (see [Host trampolines](#host-trampolines)). The game uses its types, and calls it only through `Platform_API`. |
| `lib/engine/script` | Game | Binding registration, the entity and component view, behaviours, the scheduler, events, module loading and script hot reload. |
| `lib/engine/script/prelude.luau` | Shared | The engine prelude: `Behaviour.define` and `Field`, written in Luau. The runtime runs it at init, and `tools/cook` runs the same source to read behaviours' fields. |

`lib/engine` and games import `lib/core/luau` for types and calls. They never store a Luau function pointer of their own.

## Embedding

- **One copy of Luau.** Luau has internal static state, and its VM heap holds pointers to Luau's own built-in functions. The host and the game DLL must therefore share one copy. In development, Luau is built as `luau.dll`, and both modules load it. In release, it is linked statically. `tools/cook` links the compiler and the analyzer statically. It runs in its own process, so it does not share the VM.
- **Build:** `just luau` builds `lib/core/luau/CMakeLists.txt` twice, into `build/luau/shared` (`luau.dll` with the VM, the compiler and the code generator) and `build/luau/static`. Both builds export the C API with `extern "C"` and use the static CRT, like Odin. `luau_compile` returns memory from Luau's CRT, so the bindings release it with `luau.free_bytecode`. A running host keeps `luau.dll` locked, and a changed `luau.dll` needs a host restart.
- **One VM per `Game_State`.** The game creates the VM in `init` with `script_open` in `Platform_API`, and destroys it in `shutdown`. A code reload keeps the VM. A soft restart destroys it with the rest of the game state, because the world holds references into it.
- **Heap:** the VM is created with `lua_newstate` and a host-side allocator. Luau places small objects in its own size-class pages, so the allocator mostly sees page-sized and large requests. Blocks up to 1 MiB come from TLSF, in 8 MiB pools in one 4 GiB reservation of each VM. A larger block gets its own virtual memory. `script_close`, or a soft restart, releases all of it. The heap, including suspended script coroutines, survives code reload.
- **Errors:** Luau is built with `LUA_USE_LONGJMP`. An error raised in a binding jumps over Odin frames and skips their `defer` statements. Bindings therefore raise errors only before they do work that needs a `defer`.
- **Sandboxing:** the host calls `luaL_sandbox` on the main state and `luaL_sandboxthread` on each module's thread. Scripts have no `os`, `io`, `debug` or `loadstring`, and they cannot change the engine globals.
- **Threading:** a Luau state is not thread-safe. Scripts run only in the serial script phase of the frame (see [Frame](#frame)).

### Host trampolines

Luau stores function pointers in the VM heap and in its global state. A pointer into the DLL image would become stale after a code reload (see [Hot reload](hot-reload.md#rules), rule 3). Every function pointer that Luau stores is therefore a host function in `lib/core/script`:

| Luau hook | Host function | Forwards to |
|---|---|---|
| `lua_Alloc` | Script heap allocator | Nothing. It is host code. |
| Every `lua_CFunction` binding | One dispatcher | The game's binding table, by binding ID |
| Metamethods (`__index`, `__namecall`, `__eq` and others) | The same dispatcher: each metamethod is a binding | The game's binding, which finds the method or field in its per-type tables by userdata tag and atom |
| `useratom` | The atom interner | Nothing. It is host code. |
| `interrupt` | The watchdog | Nothing. It is host code. |
| `panic` | Logs and aborts | Nothing. It is host code. |

The game reaches these through `Platform_API`: `script_open`, `script_close`, `script_push_binding` (a dispatcher closure for a binding name) and `script_atom` (interns a name). `script_open` stores a pointer to the game's `script_host.Bindings` in `lua_Callbacks.userdata`. The table lives in `Game_State`, so its address does not change across a reload, and `on_reload` fills it again. Bindings run with the context in `Bindings.ctx`, which the game sets each time before it runs scripts.

- **Bindings have stable IDs.** A binding's ID is the hash of its qualified name, such as `Entity.get`. The dispatcher closure holds the ID as its upvalue, not an index. Scripts can therefore keep binding functions in locals across a reload, even when the new DLL registers bindings in a different order. A call to a binding that the new DLL no longer registers raises an error that names it.
- **Atoms are stable.** The host interns every name that the game registers as a method or field, and the `useratom` callback gives a string the index of its name. The interner is append-only and host-owned, so an atom never changes meaning. Bindings use `lua_namecallatom` and `lua_tostringatom` to find a method or field without a string compare. Luau asks for a string's atom once, the first time that code needs it, and keeps the answer. A string whose atom was asked for before its name was interned therefore has none, and the binding falls back to a lookup by name.
- **No userdata destructors.** `lua_newuserdatadtor` and `lua_setuserdatadtor` store function pointers, so engine userdata are plain data with no destructor. A userdata never owns a native resource. It holds handles.
- **Bindings can yield.** A binding that waits (such as `wait`) returns a yield request, and the dispatcher calls `lua_yield`.

### Direct field access

Luau's experimental `lua_registeruserdatadirectaccess` lets the VM call a get, set or namecall callback for a tagged userdata without a Luau call frame. It is an optional feature, selected by the `LUAU_DIRECT_ACCESS` config in `lib/core/script`. It is off by default. `CINNABAR_DIRECT_ACCESS=true just build` turns it on for the host, the game DLL and release builds.

- **When the VM uses it:** at load, Luau rewrites each field read, field write and method call whose key has an atom to an instruction that calls the tag's direct access callback when the value is userdata. Every exposed field and every method name is interned, so their accesses qualify. Any other value takes the usual path.
- **Same arguments, different entry.** The VM calls the callback in a C call frame with the metamethod's arguments: the userdata, the key and, for a write, the value. The callbacks are host functions, like the dispatcher (`script_host.direct_access`, through `Platform_API.script_direct_access`), and they call the game's handlers in `Bindings.direct`, which `on_reload` fills again. The handlers do what the metamethods do, so scripts see the same behaviour with the feature on or off. `just test` runs the script tests both ways.
- **The engine's userdata:** component references (field reads and writes), `Quaternion` (fields and methods) and `WorldPosition` (methods). A `Transform` write takes the general path, because a child's write also sets its local pose. Light userdata, such as `Entity`, have no direct access in Luau.
- **The cached slot is a hint.** Luau gives the callback a `cachedslot` for each instruction, which every userdata tag shares. A component reference stores the field's index plus one in it, and uses the field there only if it belongs to the reference's component and has the key's atom. Otherwise it looks up the field again.
- **Why optional:** the API is experimental and can change in a Luau update. With the feature off, nothing calls it, so a Luau update never blocks on it.
- `Bindings.direct_calls` counts the calls, so tests can tell that the path is used.

### Watchdog

The `interrupt` callback checks a deadline at loop back edges and calls. A script that runs past its budget in one resume raises an error with a traceback, and only that coroutine or handler stops. The budget is generous in development (100 ms) and is a crash-report signal in release.

### Garbage collection

- The script phase runs an incremental GC step with a fixed budget each frame. It never runs a full collection during a frame.
- Each loaded module gets a Luau memory category (`lua_setmemcat`): its index + 1, and the last of the 256 modules shares the 255th's. Category 0 is the engine. A module's top level runs in its category, a main script's thread has its module's, and each behaviour instance keeps its class's module's, which its callbacks run in. A coroutine's thread keeps the category of the code that started it, so what a behaviour's coroutines allocate counts toward its module too. `script.memory` gives the VM's total and each module's part, and the editor's resource monitor shows them.

## Values

| Script type | Luau representation | Allocates | Notes |
|---|---|---|---|
| Number | `number` (`f64`) | No | |
| 64-bit ID | `integer64` | No | Component IDs, raw values for the editor link |
| `vector` | Built-in `vector`, 3 × `f32` | No | Unity's `Vector3`. Matches `[3]f32` exactly. |
| `Entity` | Tagged light userdata, payload = the 64-bit handle | No | Equality is by value, so entities work as table keys. |
| Component type | Tagged light userdata, payload = the component ID | No | The globals `Transform`, `Health` and so on |
| Asset reference | Tagged light userdata, payload = the generational asset handle | No | *Not yet: with asset fields in phase 4.* |
| `WorldPosition` | Tagged userdata, 24 bytes | Yes | `a - b` gives a `vector`, and `p + v`, `v + p` and `p - v` give a `WorldPosition`. See [World](world.md#where-positions-go). |
| `Quaternion` | Tagged userdata, 16 bytes | Yes | `q * q`, `q * v` |
| Component reference | Tagged userdata: entity handle and component ID | Yes | The result of `entity:get(Health)` |
| Behaviour instance | Table with the class as its metatable | Yes | The result of `entity:get(Door)` |

- All light userdata share one metatable in Luau. Its metamethods dispatch on the light userdata tag. Full userdata get one metatable per tag with `lua_setuserdatametatable`. `typeof` gives `Entity`, `ComponentType`, `WorldPosition`, `Quaternion` and `ComponentRef`.
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
- **Entity methods:** `get`, `has`, `add`, `remove`, `destroy`, `is_alive`, `teleport(position, rotation?)` (no interpolation, see [World](world.md#fixed-and-variable-rate)), `offset_to(other)` and `move(v)`, which do not allocate a `WorldPosition`, and `set_parent(parent)`, which keeps the world pose, like Unity's `SetParent`. `entity.parent` is the parent or `nil`. `add` and `remove` refuse `Parent` and `LocalTransform`: `set_parent` keeps the two consistent.

### Structural changes

Scripts change the world structure **immediately**, except for despawns. The script phase is serial, and no job reads the world while it runs.

- `World.spawn(position?, rotation?)` creates an entity with a `Transform` at once and returns its handle. With prefabs, `World.spawn(prefab, position?, rotation?)` will create the prefab's components, and its behaviours will get `awake` before `spawn` returns, as in Unity's `Instantiate`.
- `entity:add(T, values?)` and `entity:remove(T)` take effect at once. `values` is a table of field values, and `add` returns the component.
- `entity:destroy()` is deferred to the end of the script phase, as in Unity's `Destroy`. It goes into the script command buffer, which phase 6 of the frame applies.
- `World.query(T, ...)` returns an array of the matching entities, collected before the loop starts. Structural changes inside the loop are therefore safe. A query from a script scans every archetype, so performance-critical work belongs in a native system.

## Engine libraries

| Global | Contents |
|---|---|
| `World` | `spawn`, `query` |
| `Quaternion` | `identity`, `new(x, y, z, w)`, `euler(degrees)`, `angle_axis(degrees, axis)`, `look_rotation(forward, up?)`, `slerp`, `angle`, `rotate_towards(from, to, max_degrees)`. Methods: `inverse`, `normalized`, `euler`, `approx`, `angle_to`, `rotate_towards`, `slerp`. Fields `x`, `y`, `z`, `w`. |
| `WorldPosition` | `origin`, `from_meters(x, y, z)` (for authoring), `lerp`. Methods: `lerp`, `to_meters` (for display). |
| `Time` | `delta` (the frame), `time` (world time), `real_time`, `frame`, `fixed_delta`, `alpha` (the interpolation fraction) |
| `Input` | `is_down(key)`, `was_pressed(key)`, `was_released(key)`, `mouse_position` and `mouse_delta` (vectors in pixels), `scroll` (wheel notches) |
| `Key` | `Key.A`, `Key.Num0`, `Key.Space`, `Key.LeftShift`, `Key.MouseLeft` and the other values of `core.Key` |
| `Debug` | `log`, `warn`, `error`. *`draw_line` waits for a debug renderer.* |

- **Angles are in degrees**, as in Unity. Euler angles apply z, then x, then y, as in Unity.
- `==` on quaternions is approximate, as in Unity's `==`. `==` on positions is exact.
- An arithmetic result outside the world (±2^38 m) raises an error.

## Behaviours

A behaviour is Unity's `MonoBehaviour`: a script class whose instances are attached to entities, receive events and own coroutines.

```luau
--!strict
local Door = Behaviour.define("Door", {
	open_angle = Field.number(90),
	speed = Field.number(2),
	open_sound = Field.asset("Sound"),
	trigger = Field.entity(),
})

function Door:start()
	self.closed_rotation = self.transform.rotation
end

function Door:on_trigger_enter(other: Entity)
	if other:has(Player) then
		self:start_coroutine(self.open)
	end
end

function Door:open()
	Audio.play(self.open_sound, self.transform.position)
	local target = self.closed_rotation * Quaternion.euler(vector.create(0, self.open_angle, 0))
	while not self.transform.rotation:approx(target) do
		self.transform.rotation = self.transform.rotation:rotate_towards(target, self.speed * Time.delta)
		wait_frames(1)
	end
end

return Door
```

- **A behaviour module returns its class.** `Behaviour.define` and `Field` are engine globals. `Behaviour.define` takes the class name and its fields. Fields are what Unity serializes: the editor shows them, scenes and prefabs store their values, and the instance gets them as plain table fields. Other table fields are runtime state.
- **Field kinds:** `Field.number(default?)`, `Field.boolean(default?)`, `Field.string(default?)`, `Field.vector(default?)` and `Field.entity()`. *`Field.asset(kind)` waits for asset references.* `entity`, `transform` and `enabled` are reserved names.
- **The cooker reads the fields.** For a script that calls `Behaviour.define`, it runs the top level in a sandboxed VM that has the Luau libraries and the prelude, but no engine, and stores the class name and the fields in the blob (see [Content pipeline](content-pipeline.md#scripts)). Such a top level must therefore only require modules and define classes. Reading an engine global, such as `World`, raises "World is not available when the cooker reads a behaviour's fields", and a top level that runs for more than 2 s is stopped. Both are cook errors. A script without `Behaviour.define`, such as a main script for `spawn_script`, is not run.
- **Attaching:** `entity:add(Door, values?)` from a script, a `behaviour` block in a scene, or `script.attach_script(r, entity, guid, fields)` from native code. The scene loader skips a field value that the class does not declare, or of the wrong kind, with a warning. `values` is a table of field values, and `enabled = false` starts the instance disabled. A value for a field that the class does not declare, or of the wrong kind, raises an error. `entity:get(Door)`, `entity:has(Door)` and `entity:remove(Door)` work as for components.
- **Storage:** an entity with behaviours has the native `Behaviours` component (ID 16, registered by `script.register_components`), which holds a `lua_ref` to the entity's record table. The record lists the instances in the order they were added, and maps each class to its instance. An entity has at most one instance of a class, so `entity:get(Door)` has one answer. The native side of each instance (its lifecycle flags) is a slot in the runtime, at most 4096.
- **Instance members:** `self.entity` (Unity's `gameObject`), `self.transform`, `self.enabled`, `self:start_coroutine(fn, ...)`, `self:stop_coroutine(co)` and `self:stop_all_coroutines()`.
- **Classes are metatables.** An instance is a table whose metatable is its class. The class's `__index` finds methods in the class first, so a method call never reaches the engine. `enabled` is never stored in the instance, so its reads and writes reach the engine through `__index` and `__newindex`. Luau's `class` syntax is experimental (behind `DebugLuauUserDefinedClasses`), so the engine does not use it, and the flag stays off in the cooker and in the VM.

### Lifecycle

| Callback | Unity | When |
|---|---|---|
| `awake()` | `Awake` | Once, the first time the entity is active after the instance is created. For a script spawn of an active entity, this is before `spawn` returns. For a native spawn or a scene load, it is in the next script phase. |
| `on_enable()` | `OnEnable` | Each time the instance becomes enabled and its entity becomes active in the hierarchy, starting just after `awake` |
| `start()` | `Start` | Once, at the start of the first script phase in which the instance is enabled and active, before its first `update` |
| `update(dt)` | `Update` | Every script phase while enabled and active, if the class defines it. Opt-in, see below. |
| `on_disable()` | `OnDisable` | Each time the instance stops being enabled or active, and before `on_destroy` if it was enabled and active |
| `on_destroy()` | `OnDestroy` | In the script phase after the despawn is applied, if `awake` ran. The instance's table fields are intact, but the entity's components are gone. |
| `on_reload()` | none | After a script hot reload patched the class (see [Script hot reload](#script-hot-reload)) |
| `on_<event>(...)` | `OnTriggerEnter` and similar | When the event is delivered (see [Events](#events)) |

- **`update` is opt-in.** The script phase calls `update` only on instances whose class defines it, in instance slot order. Calling into Luau for every entity every frame is expensive at scale. The profiler shows the cost of each class's `update`, and the API favors events and coroutines.
- **No `fixed_update`.** Scripts do not run in fixed ticks. Logic that must run every tick is a native `Fixed` system. A script influences the simulation by writing components, and the next tick reads them.
- **Despawn notification:** the world logs each removed `Behaviours` component with its record reference (see `ecs.watch` and `ecs.take_log`), from `ecs.apply` and from the immediate `despawn`. The script phase drains the log at its start, and again after it applies its own commands, so `on_destroy` runs in the same frame as a script's `destroy`.
- **Callbacks** run on the main thread in a protected call, under the watchdog. An error logs the message with a traceback, and the other callbacks still run. A callback cannot wait: it is not a coroutine.

### Enabled state

Unity has two switches, and so does cinnabar:

| Switch | Unity | cinnabar | Scope |
|---|---|---|---|
| Behaviour | `behaviour.enabled` | `self.enabled` | One instance |
| Entity | `SetActive`, `activeSelf`, `activeInHierarchy` | `entity:set_active(b)`, `entity.active_self`, `entity.active_in_hierarchy` | The entity and its descendants |

- **`enabled`** is a serialized field of every behaviour, `true` by default. A disabled instance gets no `update` and no events. Its coroutines keep running, as in Unity.
- **Inactive entities still move with their parents.** Transform propagation includes them, as in Unity, so an entity is in the right place when it becomes active.
- **Entity activity is native.** `set_active(false)` adds the `Disabled` tag to the entity. The world gives the `Inactive` tag to every entity that has `Disabled` or an inactive ancestor, so `active_in_hierarchy` is `not entity:has(Inactive)`. See [World](world.md#queries) for how native systems skip inactive entities.
- **Deactivating an entity** stops the coroutines of every behaviour on it and on its descendants, and calls `on_disable` on the enabled ones. `start_coroutine` on an inactive entity raises an error, as in Unity.
- `set_active` is a structural change. From a script it takes effect at once, and the callbacks run before `set_active` returns. Activity changes from native code take effect when their buffer is applied, and the callbacks run in the next script phase.
- Only one callback runs for each change of state. Setting `enabled` to its current value does nothing.

### Coroutines

- `self:start_coroutine(fn, ...)` starts a Luau thread that the instance owns, as in Unity's `StartCoroutine`. It runs until its first wait before `start_coroutine` returns the thread, which `self:stop_coroutine(co)` stops. A destroyed or deactivated entity stops its coroutines. A coroutine that was stopped does not start again when the entity comes back, as in Unity.
- Inside a coroutine: `wait(seconds)` (world time), `wait_realtime(seconds)`, `wait_frames(n)`, `wait_until(predicate)` (called each frame) and `wait_event(entity, name)`, which returns the event's arguments. A plain `coroutine.yield()` waits one frame. A wait outside of a coroutine that the engine runs raises an error.
- A script from `spawn_script` is a coroutine of the scheduler too, with no owner. `spawn_script` returns a `Main_Script`, which `script.stop` ends.
- The scheduler is native and lives in `Game_State`, at most 4096 threads. Each frame it resumes the threads that are due, ordered by wake time and then by start order, so resume order is deterministic. Each entry holds a `lua_ref` to its thread.
- An error in a coroutine logs the message with a traceback and stops only that coroutine.

### Events

- Native code queues an event with `script.send(r, entity, name, args...)`, whose arguments are numbers, booleans, strings, vectors or entities. Call it from the frame code: the queue is not safe for jobs. *Physics contacts will become `on_trigger_enter`, `on_collision_enter` and similar, through per-job event buffers.*
- `entity:send(name, ...)` queues a script event, like Unity's `SendMessage`. It is delivered in the same script phase: events are delivered before `update` and again after the coroutines. Events that handlers send are delivered in the next round, for up to 16 rounds.
- The script phase calls `on_<name>` on every enabled instance on the entity that defines it, in the order that the instances were added. An inactive entity gets no events.
- An error in a handler logs the message with a traceback. The other handlers still run.

## Frame

The game runs the script phase with one call, `script.run_phase(r, dt, platform.input())`, between the `Update` and `Late` stages. It covers phases 5 and 6 of [Frame](architecture.md#frame), in Unity's order:

1. Set `Time` and `Input`.
2. Drain the world's log: `on_disable` and `on_destroy` for despawned behaviours, and `awake`, `on_enable` or `on_disable` for activity changes from native code. While the runtime is quiet, as in the editor's edit mode, `script.settle` drains it instead, with none of these callbacks (see [Editor](editor.md#modes)).
3. `awake` and `on_enable` for instances that native code attached.
4. `start` for instances that are enabled and active and have not started.
5. Deliver the events that the fixed ticks and the `Update` systems queued.
6. `update` for the classes that define it.
7. Resume the coroutines that are due.
8. Deliver the events that `update` and the coroutines sent.
9. Apply the scripts' structural changes, such as `destroy`, drain the log again, and run the collector's step.

`begin_phase` and `end_phase` run steps 1 and 9 alone, for tests and tools.

## Modules and `require`

- A module is one script asset. `require` takes a path relative to the requiring file (`"./util"`), or an alias from `.luaurc` (`"@game/ai/brain"`, `"@engine/Behaviour"`). These are the conventions that `luau-lsp` understands.
- **The cooker resolves every `require`.** The blob stores a map from each require string to the target's GUID. The runtime never searches a path. A missing module or a require cycle is a cook error.
- **Luau's rules:** a file `a/b.luau` is the module `a/b`, and `a/init.luau` is the module `a`. `./` and `../` start at the module's parent, so in `a/init.luau`, `./x` is a sibling of `a`. `@self/` starts at the module itself. Any other `@alias/` starts at the directory that the nearest `.luaurc` names for the alias, relative to that `.luaurc`. Alias names are not case-sensitive.
- `script.spawn_script` runs a script asset on its own sandboxed thread. Its chunk name is `@` and its source path, such as `@game/scripts/hello.luau`.
- `require` is one global binding. It finds the calling module from the caller's chunk name, and looks the path up in that module's map, so a module's functions resolve requires against their own module, wherever they are called from.
- Each module runs once, on its first require, on the requiring thread, in its own environment that reads through to the shared globals. A module must not yield at its top level. Its result is cached by GUID, and a module that returns nothing gives `true`. A module that raises an error at its top level is not cached, so a later require runs it again.

## Types and tooling

- **Definitions come from the bindings.** Type info for game-side types exists only in the DLL (see [Editor](editor.md#editor-link)). `just script-types` runs `host.exe --emit-script-types <file>`, which calls `Game_API.script_types`. That procedure makes a world and a script runtime of its own, runs the game's registrations, and returns `script.definitions`, so it needs no game state and makes no GPU resources. The file goes to `build/script-types/cinnabar.d.luau`.
- **What the file holds:**
  - The engine's API from `lib/engine/script/engine.d.luau`, which is written by hand.
  - `Entity`, whose `get` and `add` are overloaded for each exposed component.
  - `Key`.
  - Each exposed component: `HealthType` for the global `Health`, and `HealthRef` with the fields' types. An enum field is a union of its value names, so a typo is a type error.
  - The game's bindings, with the signature that the game passes to `define`, such as `script.define(r, "Game.frame", procedure, "() -> number")`. A binding without a signature takes and returns `any`.
- **Behaviours are loosely typed for now.** `Behaviour.define` returns `{ [any]: any }`, so methods can be defined on the class, and `self` and instances are untyped.
- `luau-lsp` reads the definition file and `.luaurc`, so editors get completion and type errors. The repository does not keep editor settings, so set it up yourself. It needs the standard platform, the definition file, the old type solver (see below), and no Rojo sourcemap. In VS Code, add this to `.vscode/settings.json`:

  ```jsonc
  {
  	"luau-lsp.platform.type": "standard",
  	"luau-lsp.types.definitionFiles": {
  		"@cinnabar": "build/script-types/cinnabar.d.luau"
  	},
  	"luau-lsp.fflags.override": {
  		"LuauSolverV2": "false"
  	},
  	"luau-lsp.sourcemap.enabled": false
  }
  ```
- **`tools/cook` type checks** each script that it cooks against the same file (see [Content pipeline](content-pipeline.md#scripts)). A type error is a cook error, so the script keeps its old blob, and the running game keeps the previous version. Each file's `--!strict`, `--!nonstrict` or `--!nocheck` applies, and the nearest `.luaurc`'s `languageMode` sets the default, which is nonstrict without one. Without the definition file, as on the first build, the cooker warns and does not type check. The file's hash is in each script's cache key, so the scripts are checked once it exists.
- **The old type solver.** Under the new solver, `self` in `function Door:update()` gets a type inferred from the method's body, with read-only fields, so `self.phase += 1` is an error, and every behaviour would need annotations. The old solver gives `self` the class's type. The cooker uses the old solver, and the editor setting matches it. Revisit when behaviours get real class types.
- **The build order:** `just build` builds the host and the game DLL, writes the definitions from the DLL, and then cooks the scripts. The DLL embeds only committed `.meta` files, so it does not wait for the cook.

## Script hot reload

In development, a changed script reloads at the end of the frame in which the asset runtime swaps its blob. The game calls `script.reload_changed(r, asset.poll(assets))` there, when no script runs. Release builds read bundles and do not reload scripts.

1. The asset runtime swaps the blob behind the script's handle (see [Content pipeline](content-pipeline.md#loading)). A script with a type error keeps its old blob, so the game never sees it.
2. The script runtime runs the new version's top level in a fresh environment. If it fails, the old version stays and the error is logged.
3. If the old and the new results are both tables, the runtime **patches the old table in place**: it copies every key of the new table, and removes keys that the new table does not have. Modules that hold the old table see the new functions, and instances keep their metatable. If either result is not a table, the cache gets the new value, and modules that required the old one keep it, with a warning.
4. For a behaviour class, the class keeps its own `__index` and `__newindex`, which find the patched methods in it. Existing instances keep their state, get the default value of each new field, and start or stop getting `update` if the new version adds or removes it. Then each instance gets `on_reload`, if the class defines it.
5. **A main script restarts.** A script from `spawn_script` is one thread whose body is its top level, so nothing can be patched: its thread stops, and the new version runs from the top. Its `Main_Script` handle stays valid. Modules reload before main scripts restart, so a restarted script requires the new versions.
6. A module that no one has required yet loads the new version when it is first required.

Consequences for scripters:

- **Keep state on instances, not in module locals.** A module's locals are created again by the new version. Old closures keep the old locals.
- **A running coroutine finishes in its old code.** Its stack holds the old functions. New coroutines run the new code.
- **A main script's state resets.** Keep long-lived state in behaviours, or in a module's table, which survives the patch.

A code reload of the DLL does not touch scripts. The VM, the instances and the coroutines stay, and `on_reload` fills the binding tables again.

## Native code generation

A module that starts with `--!native`, or that has `native = true` in its `.meta`, is compiled to machine code. The cooker sets the blob's `Native` flag for either, and the runtime calls `luau_codegen_compile` on the module after it loads, after a script hot reload too, if `luau_codegen_supported` is true. Without a code generator, the module runs as bytecode, with the same results.

- `init` creates the code generator with `luau_codegen_create`. It is part of `luau.dll`, so its executable memory survives a code reload, and `lua_close` releases it.
- Luau compiles every function of the module except the ones that it considers cold, such as the top level, which runs once.
- The watchdog still works: native code calls the interrupt callback at the same safepoints.
- The whole module is native or not. Luau's `@native` attribute on one function needs the C++ code generation API, which the bindings do not have yet.
- *Not yet:* the cooker does not pass the engine's userdata type names in `userdataTypes`. Typed native code needs the runtime to map them to userdata tags with the C++ code generation API.

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
| `SendMessage` | `entity:send(name, ...)` |
| `behaviour.enabled`, `OnEnable`, `OnDisable` | `self.enabled`, `on_enable`, `on_disable` |
| `SetActive`, `activeSelf`, `activeInHierarchy` | `entity:set_active(b)`, `entity.active_self`, `entity.active_in_hierarchy` |
| `FixedUpdate` | A native `Fixed` system |
| `GameObject.Find` | Not provided. Use fields or a `Name` index. |
| `Resources.Load` | Not provided. Content refers to content by GUID, so use an asset field. |

## Implementation phases

1. **VM:** build Luau with the justfile, `lib/core/luau`, `script_open` with the host allocator and trampolines, and the binding registry. A test script survives a code reload with a suspended coroutine.
2. **Script assets:** GUIDs and `.meta` files, the `Loose_Cache` source, `cook scripts`, and `require`. The host polls the cache until the cook daemon exists.
3. **World view:** `Entity`, component references, `vector`, `Quaternion`, `WorldPosition`, `Time`, `Input`, `Debug`, and platform input in `core`.
4. **Behaviours:** the `Behaviours` component, the lifecycle, enabled state with `Disabled` and `Inactive`, events, the scheduler, the despawn log, and field schemas in the cooker.
5. **Tooling:** `--emit-script-types`, type checking in the cooker, `luau-lsp` configuration.
6. **Script hot reload:** module patching, behaviour classes and `on_reload`, main script restarts.
7. **Native code generation and direct field access.**
8. **Later:** editor inspector for fields, bundles.
