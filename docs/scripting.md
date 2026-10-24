# Scripting

All gameplay logic that spans frames (coroutines, timers, sequences, "wait two seconds") runs in sandboxed Luau, not in the job system. See [Architecture](architecture.md#scripting) for the overview, [World](world.md#the-script-view) for how scripts see entities and components, and [Content pipeline](content-pipeline.md#scripts) for how scripts are cooked and loaded.

The reference API is Unity's. A scripter who knows `GameObject`, `MonoBehaviour`, `GetComponent` and `StartCoroutine` must find the same concepts here, under the names in [Unity mapping](#unity-mapping). The design differs from Unity only where the ECS, fixed-point positions or hot reload require it.

## Packages

| Package | Side | Responsibility |
|---|---|---|
| `lib/core/luau` | Shared | Odin bindings to the Luau C API: VM, compiler and code generator. Its `CMakeLists.txt` builds Luau. The `LUAU_SHARED` config selects `luau.dll` or the static libraries. |
| `lib/core/script` | Host | Package `script_host`: the VM's heap, and every function pointer that Luau stores (see [Host trampolines](#host-trampolines)). The game uses its types, and calls it only through `Platform_API`. |
| `lib/engine/script` | Game | Binding registration, the entity and component view, behaviours, the scheduler, events, module loading and script hot reload. |
| `lib/engine/script/luau` | Content | The engine prelude: the parts of the API that are written in Luau, such as `Behaviour.define`. It is content with fixed GUIDs, and scripts reach it as `@engine/...`. |

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

Luau's experimental `lua_registeruserdatadirectaccess` lets the VM call a get, set or namecall callback for a tagged userdata without a Luau call frame. It is an optional feature, selected by the `LUAU_DIRECT_ACCESS` config in `lib/core/script`. It is off by default.

- **Same tables, different entry.** The direct access callbacks are host functions, like the dispatcher, and they look up the same per-type tables by tag and atom. Scripts see the same behaviour with the feature on or off. Tests run both ways.
- **The cached slot is a hint.** Luau gives the callback a `cachedslot` that it shares between all userdata tags. The callback stores the field's index in it, and checks that the field at that index has the same tag and atom before it uses it. Otherwise it looks up the field again.
- **Why optional:** the API is experimental and can change in a Luau update. With the feature off, nothing depends on it, so a Luau update never blocks on it.

### Watchdog

The `interrupt` callback checks a deadline at loop back edges and calls. A script that runs past its budget in one resume raises an error with a traceback, and only that coroutine or handler stops. The budget is generous in development (100 ms) and is a crash-report signal in release.

### Garbage collection

- The script phase runs an incremental GC step with a fixed budget each frame. It never runs a full collection during a frame.
- Each loaded module gets a Luau memory category (`lua_setmemcat`), up to 255 modules. Category 0 is the engine. The debug overlay and the editor show memory by module.

## Values

| Script type | Luau representation | Allocates | Notes |
|---|---|---|---|
| Number | `number` (`f64`) | No | |
| 64-bit ID | `integer64` | No | Component IDs, raw values for the editor link |
| `vector` | Built-in `vector`, 3 × `f32` | No | Unity's `Vector3`. Matches `[3]f32` exactly. |
| `Entity` | Tagged light userdata, payload = the 64-bit handle | No | Equality is by value, so entities work as table keys. |
| Component type | Tagged light userdata, payload = the component ID | No | The globals `Transform`, `Health` and so on |
| Asset reference | Tagged light userdata, payload = the generational asset handle | No | |
| `WorldPosition` | Tagged userdata, 24 bytes | Yes | Supports only `-` (gives a `vector`) and `+ vector`. See [World](world.md#where-positions-go). |
| `Quaternion` | Tagged userdata, 16 bytes | Yes | `q * q`, `q * v`, `Quaternion.euler`, `Quaternion.look_rotation` |
| Component reference | Tagged userdata: entity handle and component ID | Yes | The result of `entity:get(Health)` |
| Behaviour instance | Table with the class as its metatable | Yes | The result of `entity:get(Door)` |

- All light userdata share one metatable in Luau. Its trampolines dispatch on the light userdata tag. Full userdata get one metatable per tag with `lua_setuserdatametatable`.
- Userdata tags and light userdata tags are engine constants. They never depend on registration order.
- Entity handles are value types, so a script never sees a stale object. `entity:is_alive()` checks the generation. Any other use of a dead entity raises an error, like Unity's `MissingReferenceException`.

## The entity and component view

- `entity:get(T)` returns a component reference for a native component type, or the instance for a behaviour class. It returns `nil` if the entity does not have it. `entity:has(T)` does not allocate.
- **A component reference holds no pointer.** Each field access looks up the entity's row again, because storage moves when components are added or removed. A reference to a removed component raises an error.
- **Fields come from Odin type info.** The game exposes a native component with `script.expose(bindings, Health)`. Registration walks the struct's fields and maps each supported field type: numbers, `bool`, enums (as strings), `[3]f32` (as `vector`), `quaternion128`, `World_Position`, `Entity` and asset handles. Other fields are hidden from scripts. The struct tag `script:"read"` makes a field read-only, and `script:"-"` hides it.
- **Names:** the script name of a type is its Odin name without underscores (`Local_Transform` becomes `LocalTransform`). Field and method names are snake_case, the same as the Odin fields that they come from.
- **Writes are immediate.** The script phase is serial, so a field write goes straight to storage. A write that affects the simulation takes effect at the next fixed tick.
- **`entity.transform`** is a reference with Unity's properties: `position` (`WorldPosition`), `rotation`, `scale`, and `local_position`, `local_rotation` and `local_scale` for children. Setting `position` on a child computes its `Local_Transform` from the parent. `teleport` sets the pose without interpolation (see [World](world.md#fixed-and-variable-rate)).

### Structural changes

Scripts change the world structure **immediately**, except for despawns. The script phase is serial, and no job reads the world while it runs.

- `World.spawn(prefab, position?, rotation?)` creates the entity and its components at once and returns its handle. Its behaviours get `awake` before `spawn` returns, as in Unity's `Instantiate`.
- `entity:add(T, value?)` and `entity:remove(T)` take effect at once.
- `entity:destroy()` is deferred to the end of the script phase, as in Unity's `Destroy`. It goes into the script command buffer, which phase 6 of the frame applies.
- `World.query(T, ...)` collects the matching entity handles before the loop starts. Structural changes inside the loop are therefore safe. A query from a script costs a full scan, so performance-critical work belongs in a native system.

## Behaviours

A behaviour is Unity's `MonoBehaviour`: a script class whose instances are attached to entities, receive events and own coroutines.

```luau
--!strict
local Behaviour = require("@engine/Behaviour")
local Field = require("@engine/Field")

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

- **A behaviour module returns its class.** `Behaviour.define` takes the class name and its fields. Fields are what Unity serializes: the editor shows them, scenes and prefabs store their values, and the instance gets them as plain table fields. Other table fields are runtime state.
- **The cooker reads the fields.** It runs the module's top level in a sandboxed VM that has the prelude but no native bindings, and stores the field schema in the blob (see [Content pipeline](content-pipeline.md#scripts)). A module's top level must therefore only require modules and define classes. A call to a native binding at the top level is a cook error.
- **Storage:** an entity with behaviours has the native `Behaviours` component, which holds a `lua_ref` to the entity's record table. The record holds one instance per class. An entity has at most one instance of a class, so `entity:get(Door)` has one answer.
- **Instance members:** `self.entity` (Unity's `gameObject`), `self.transform`, `self.enabled`, `self:start_coroutine(fn, ...)`, `self:stop_coroutine(co)` and `self:stop_all_coroutines()`.
- **Classes are metatables.** An instance is a table whose metatable is its class. Luau's `class` syntax is experimental (behind `DebugLuauUserDefinedClasses`), so the engine does not use it, and the flag stays off in the cooker and in the VM.

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

- **`update` is opt-in.** A class that defines `update` puts its instances in an update list, and the script phase calls them in spawn order. Calling into Luau for every entity every frame is expensive at scale. The profiler shows the cost of each class's `update`, and the API favors events and coroutines.
- **No `fixed_update`.** Scripts do not run in fixed ticks. Logic that must run every tick is a native `Fixed` system. A script influences the simulation by writing components, and the next tick reads them.
- **Despawn notification:** `ecs.apply` and the immediate `despawn` log each removed `Behaviours` component with its record reference. The script phase drains the log at its start, and again after phase 6, so `on_destroy` runs in the same frame as a script's `destroy`.

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

- `self:start_coroutine(fn, ...)` starts a Luau thread that the instance owns, as in Unity's `StartCoroutine`. A destroyed or deactivated entity stops its coroutines.
- Inside a coroutine: `wait(seconds)` (game time), `wait_realtime(seconds)`, `wait_frames(n)`, `wait_until(predicate)` and `wait_event(entity, name)`.
- The scheduler is native and lives in `Game_State`. It keeps waiting threads in a heap ordered by wake time and then by start order, so resume order is deterministic. Each entry holds a `lua_ref` to its thread.
- An error in a coroutine logs the message with a traceback and stops only that coroutine.

### Events

- Native systems push events into the event queue in frame memory: an entity, an event name (an atom) and a payload. Physics contacts become `on_trigger_enter`, `on_collision_enter` and similar.
- `entity:send(name, ...)` queues a script event, like Unity's `SendMessage`. It is delivered in the same script phase.
- The script phase calls `on_<name>` on every enabled instance on the entity that defines it, in the order that the instances were added. An inactive entity gets no events.
- An error in a handler logs the message with a traceback. The other handlers still run.

## Frame

The script phase (phase 5 in [Frame](architecture.md#frame)) runs in Unity's order:

1. Drain the despawn log: `on_disable`, then `on_destroy`.
2. Drain the activity log of native changes: `awake` and `on_enable`, or `on_disable`.
3. `start` for instances that became enabled and active since the last script phase and have not started.
4. Deliver the events that the fixed ticks and the `Update` systems queued.
5. `update` for the classes that opt in.
6. Resume the coroutines that are due.
7. After phase 6 applies the script command buffer: drain the despawn log again.

## Modules and `require`

- A module is one script asset. `require` takes a path relative to the requiring file (`"./util"`), or an alias from `.luaurc` (`"@game/ai/brain"`, `"@engine/Behaviour"`). These are the conventions that `luau-lsp` understands.
- **The cooker resolves every `require`.** The blob stores a map from each require string to the target's GUID. The runtime never searches a path. A missing module or a require cycle is a cook error.
- **Luau's rules:** a file `a/b.luau` is the module `a/b`, and `a/init.luau` is the module `a`. `./` and `../` start at the module's parent, so in `a/init.luau`, `./x` is a sibling of `a`. `@self/` starts at the module itself. Any other `@alias/` starts at the directory that the nearest `.luaurc` names for the alias, relative to that `.luaurc`. Alias names are not case-sensitive.
- `script.spawn_script` runs a script asset on its own sandboxed thread. Its chunk name is `@` and its source path, such as `@game/scripts/hello.luau`.
- `require` is one global binding. It finds the calling module from the caller's chunk name, and looks the path up in that module's map, so a module's functions resolve requires against their own module, wherever they are called from.
- Each module runs once, on its first require, on the requiring thread, in its own environment that reads through to the shared globals. A module must not yield at its top level. Its result is cached by GUID, and a module that returns nothing gives `true`. A module that raises an error at its top level is not cached, so a later require runs it again.

## Types and tooling

- **Definitions come from the bindings.** Type info for game-side types exists only in the DLL (see [Editor](editor.md#editor-link)). `host.exe --emit-script-types <file>` writes a Luau definition file for every binding, global and exposed component. The prelude modules carry their own types.
- `luau-lsp` reads the definition file and `.luaurc`, so editors get completion and type errors.
- `tools/cook` type checks every script against the same file. A type error is a cook error. The running game then keeps the previous version of the script. Each file's mode (`--!strict`, `--!nonstrict`) applies, and `.luaurc` sets the default.

## Script hot reload

In development, a changed script reloads at the start of the next script phase. Release builds do not reload scripts.

1. The asset runtime swaps the blob behind the script's handle (see [Content pipeline](content-pipeline.md#loading)).
2. The script runtime runs the new bytecode in a fresh module thread. If it fails, the old version stays and the error is logged.
3. If the old and the new results are both tables, the runtime **patches the old table in place**: it copies every key of the new table, and removes keys that the new table does not have. Modules that hold the old table see the new functions, and instances keep their metatable.
4. For a behaviour class, existing instances get the default value of each new field. Then each instance gets `on_reload`, if the class defines it.

Consequences for scripters:

- **Keep state on instances, not in module locals.** A module's locals are created again by the new version. Old closures keep the old locals.
- **A running coroutine finishes in its old code.** Its stack holds the old functions. New coroutines run the new code.

A code reload of the DLL does not touch scripts. The VM, the instances and the coroutines stay, and `on_reload` fills the binding tables again.

## Native code generation

A module marked `--!native`, or with `native = true` in its `.meta`, is compiled to machine code with `luau_codegen_compile` after it loads, if `luau_codegen_supported` is true. The code generator is part of `luau.dll`, so its executable memory survives a code reload. The cooker passes the engine's userdata type names in `userdataTypes`, so typed native code can use them.

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
| `Input.GetKey`, `GetKeyDown` | `Input.is_down`, `Input.was_pressed` |
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
3. **World view:** `Entity`, component references, `vector`, `Quaternion`, `WorldPosition`, `Time`, `Input`, `Debug`.
4. **Behaviours:** the `Behaviours` component, the lifecycle, enabled state with `Disabled` and `Inactive`, events, the scheduler and the despawn log.
5. **Tooling:** `--emit-script-types`, type checking in the cooker, `luau-lsp` configuration.
6. **Script hot reload.**
7. **Later:** editor inspector for fields, native code generation, direct field access, bundles.
