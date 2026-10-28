# Behaviours

A behaviour is Unity's `MonoBehaviour`: a script class whose instances are attached to entities, receive events and own coroutines. This document covers the class, its lifecycle, enabled state, coroutines and events, and the script phase that runs them.

**In this document:** [Behaviours](#behaviours) · [Frame](#frame)

## Behaviours

A behaviour is Unity's `MonoBehaviour`: a script class whose instances are attached to entities, receive events and own coroutines.

```luau
--!strict
local Door = Behaviour.define("Door", {
	open_angle = Field.number(90),
	speed = Field.number(2),
	open_effect = Field.asset("prefab"),
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
	World.spawn(self.open_effect, self.transform.position)
	local target = self.closed_rotation * Quaternion.euler(vector.create(0, self.open_angle, 0))
	while not self.transform.rotation:approx(target) do
		self.transform.rotation = self.transform.rotation:rotate_towards(target, self.speed * Time.delta)
		wait_frames(1)
	end
end

return Door
```

- **A behaviour module returns its class.** `Behaviour.define` and `Field` are engine globals. `Behaviour.define` takes the class name and its fields. Fields are what Unity serializes: the editor shows them, scenes and prefabs store their values, and the instance gets them as plain table fields. Other table fields are runtime state.
- **Field kinds:** `Field.number(default?)`, `Field.boolean(default?)`, `Field.string(default?)`, `Field.vector(default?)`, `Field.entity()` and `Field.asset(kind?)`, an `Asset` reference, such as a prefab for `World.spawn`. The properties panel's picker offers assets of the kind, such as `"prefab"`, or any without one, and a scene writes the value as `$` and the GUID. `entity`, `transform` and `enabled` are reserved names.
- **The cooker reads the fields.** For a script that calls `Behaviour.define`, it runs the top level in a sandboxed VM that has the Luau libraries and the prelude, but no engine, and stores the class name and the fields in the blob (see [Content pipeline](../content/kinds/scripts.md#scripts)). Such a top level must therefore only require modules and define classes. Reading an engine global, such as `World`, raises "World is not available when the cooker reads a behaviour's fields", and a top level that runs for more than 2 s is stopped. Both are cook errors. A script without `Behaviour.define`, such as a main script for `spawn_script`, is not run.
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
| `fixed_update(dt)` | `FixedUpdate` | Every fixed tick while enabled and active, after the `Fixed` systems, if the class defines it. Opt-in, as `update` is. See [Fixed step](#fixed-step). |
| `on_disable()` | `OnDisable` | Each time the instance stops being enabled or active, and before `on_destroy` if it was enabled and active |
| `on_destroy()` | `OnDestroy` | In the script phase after the despawn is applied, if `awake` ran. The instance's table fields are intact, but the entity's components are gone. |
| `on_reload()` | none | After a script hot reload patched the class (see [Script hot reload](tooling-and-hot-reload.md#script-hot-reload)) |
| `on_<event>(...)` | `OnTriggerEnter` and similar | When the event is delivered (see [Events](#events)) |

- **`update` is opt-in.** The script phase calls `update` only on instances whose class defines it, in instance slot order. Calling into Luau for every entity every frame is expensive at scale. The profiler shows the cost of each class's `update`, and of its other callbacks and coroutines ([Profiling](../core/profiling.md#frames-and-costs)), and the API favors events and coroutines.
- **`fixed_update` is opt-in too,** and a frame can run up to four ticks, so the profiler shows its cost per class as `fixed_update`. Use it for what must happen once per tick: moving something that is interpolated, or a force that must not depend on the frame rate. Logic that is heavy and runs every tick is a native `Fixed` system.
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
- **Entity activity is native.** `set_active(false)` adds the `Disabled` tag to the entity. The world gives the `Inactive` tag to every entity that has `Disabled` or an inactive ancestor, so `active_in_hierarchy` is `not entity:has(Inactive)`. See [World](../world/ecs.md#queries) for how native systems skip inactive entities.
- **Deactivating an entity** stops the coroutines of every behaviour on it and on its descendants, and calls `on_disable` on the enabled ones. `start_coroutine` on an inactive entity raises an error, as in Unity.
- `set_active` is a structural change. From a script it takes effect at once, and the callbacks run before `set_active` returns. Activity changes from native code take effect when their buffer is applied, and the callbacks run in the next script phase.
- Only one callback runs for each change of state. Setting `enabled` to its current value does nothing.

### Coroutines

- `self:start_coroutine(fn, ...)` starts a Luau thread that the instance owns, as in Unity's `StartCoroutine`. It runs until its first wait before `start_coroutine` returns the thread, which `self:stop_coroutine(co)` stops. A destroyed or deactivated entity stops its coroutines. A coroutine that was stopped does not start again when the entity comes back, as in Unity.
- Inside a coroutine: `wait(seconds)` (world time), `wait_realtime(seconds)`, `wait_frames(n)`, `wait_until(predicate)` (called each frame), `wait_event(entity, name)`, which returns the event's arguments, and `wait_fixed()`, Unity's `WaitForFixedUpdate`, which resumes at the end of the next fixed tick ([Fixed step](#fixed-step)). A plain `coroutine.yield()` waits one frame. A wait outside of a coroutine that the engine runs raises an error.
- A script from `spawn_script` is a coroutine of the scheduler too, with no owner. `spawn_script` returns a `Main_Script`, which `script.stop` ends.
- The scheduler is native and lives in `Game_State`, at most 4096 threads. Each frame it resumes the threads that are due, ordered by wake time and then by start order, so resume order is deterministic. Each entry holds a `lua_ref` to its thread.
- An error in a coroutine logs the message with a traceback and stops only that coroutine.

### Events

- Native code queues an event with `script.send(r, entity, name, args...)`, whose arguments are numbers, booleans, strings, vectors, entities or world positions. Call it from the frame code: the queue is not safe for jobs. Physics contacts arrive this way as `on_collision_enter`, `on_trigger_enter` and the rest, sent by `physics.send_events` in each tick ([Physics: Events](../physics/design.md#events)).
- `entity:send(name, ...)` queues a script event, like Unity's `SendMessage`. It is delivered in the same script phase: events are delivered before `update` and again after the coroutines. Events that handlers send are delivered in the next round, for up to 16 rounds.
- The script phase calls `on_<name>` on every enabled instance on the entity that defines it, in the order that the instances were added. An inactive entity gets no events.
- An error in a handler logs the message with a traceback. The other handlers still run.

## Frame

The game runs the script phase with one call, `script.run_phase(r, dt, platform.input())`, between the `Update` and `Late` stages. It covers phases 5 and 6 of [Frame](../overview/architecture.md#frame), in Unity's order:

1. Set `Time` and `Input`.
2. Drain the world's log: `on_disable` and `on_destroy` for despawned behaviours, and `awake`, `on_enable` or `on_disable` for activity changes from native code. While the runtime is quiet, as in the editor's edit mode, `script.settle` drains it instead, with none of these callbacks (see [Editor](../editor/document-and-scenes.md#modes)).
3. `awake` and `on_enable` for instances that native code attached.
4. `start` for instances that are enabled and active and have not started.
5. Deliver the events that the fixed ticks and the `Update` systems queued.
6. `update` for the classes that define it.
7. Resume the coroutines that are due.
8. Deliver the events that `update` and the coroutines sent.
9. Apply the scripts' structural changes, such as `destroy`, drain the log again, and run the collector's step.

`begin_phase` and `end_phase` run steps 1 and 9 alone, for tests and tools.

### Fixed step

Scripts also run in each fixed tick, in two calls that the game's frame code makes in its tick loop (see [Physics: Scripts in fixed ticks](../physics/design.md#scripts-in-fixed-ticks)):

```odin
ticks := ecs.begin_ticks(&s.world, dt)
for ecs.next_tick(&ticks) {
	ecs.run_tick_systems(&ticks, s)
	script.fixed_update(&s.scripts, &ticks, input)
	ecs.update_transforms(&s.world)
	physics.tick(&s.physics, &s.world)
	physics.send_events(&s.physics, &s.world, &s.scripts)
	script.fixed_events(&s.scripts)
	ecs.update_transforms(&s.world)
}
```

`script.fixed_update`, after the tick's `Fixed` systems:

1. Set `Time` for the tick: `delta` is the tick's duration, `time` the world time at its end, and `in_fixed` is true.
2. Set `Input` for the tick. The first tick of a frame gets the frame's edges, with those of earlier frames that ran no tick; the others get none, so `Input.was_pressed` in `fixed_update` sees each press exactly once ([Time](../world/time.md#fixed-and-variable-rate)).
3. Drain the world's log, then `awake`, `on_enable` and `start` as in the script phase, so an instance's `start` comes before its first `fixed_update`.
4. `fixed_update` for the classes that define it, in instance slot order.
5. Deliver the events that it sent, and apply its structural changes.

`script.fixed_events`, at the end of the tick: deliver the tick's events, resume the coroutines that wait in `wait_fixed`, in the order they started, deliver what they sent, and apply their structural changes. The tick's physics contacts are delivered here, after `physics.send_events` queues them ([Physics: Events](../physics/design.md#events)).

What stays per frame: `update`, the other waits, events that `Update` systems queue, and the collector's step. The editor's edit mode runs no ticks, so no `fixed_update`, and a paused step runs one.
