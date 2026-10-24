# World

All world data lives in a native ECS in `lib/engine/ecs`. Scripts see an object-style API on top of it. See [Architecture](architecture.md#world-model) for the overview, and [Frame](architecture.md#frame) for where world updates happen in a frame.

## ECS

- **Entities** are generational handles: a 32-bit index and a 32-bit generation. A handle to a destroyed entity is detected; it is never reused silently. A slot whose generation would wrap is retired.
- **Component types have stable IDs.** The ID is a hash of the type's name, or an explicit value. It is never a `typeid` (see [Hot reload](hot-reload.md#rules), rule 3). Cooked scenes, the editor link and scripts all identify component types by this ID.
- **Native systems** run as jobs on the job system. Engine systems (transforms, physics, animation, render extraction) and performance-critical game logic are native.
- **Structural changes are deferred.** Spawning, destroying, and adding or removing components go into command buffers. The buffers are applied at fixed points in the frame. This applies to native systems and to scripts.
- **Resources are not entities.** World-wide state, such as the active camera or the physics settings, is a plain field in `Game_State`.

### Component registry

- `on_reload` rebuilds the registry, like every other registration. An entry holds the stable ID, the size, the alignment, the `typeid`, the name and the layout hash of the type. The `typeid` and the name point into the DLL image, so they are valid only in this table. Persistent world data refers to a component type only by its ID.
- The default ID is the hash of `package.Type`. Renaming a type or its package changes the ID, so give an explicit ID to a type that cooked content already uses.
- Component storage is untyped bytes, so the `Game_State` layout hash does not see component layouts. The game's `layout_hash` therefore mixes in `registry_layout_hash`. A changed component causes a soft restart (see [Hot reload](hot-reload.md#reload-sequence)). `layout_hash` has no state, so the game registers its components in one procedure. It calls this procedure on the world's registry in `init` and `on_reload`, and on a `Registry` on the stack in `layout_hash`.

### Storage

- Entities with the same set of component types share an **archetype**. An archetype stores its entities in **chunks** of 16 KiB. A chunk is struct-of-arrays: one column per component type.
- All world storage is in virtual memory that the game reserves through `Platform_API` (see [Core](core.md#memory)). The reservations never move, so world data holds no allocators and no pointers. Chunks come from a pool in one reservation, and a freed chunk goes back to the pool.
- Removing an entity moves the last row of its archetype into its place.
- Tags (zero-size components) select the archetype but take no column space.
- A chunk is the unit of work for a job.

### Queries

- A query is a set of terms. Each term names a component ID and an access: read, write, optional or excluded.
- A query caches the archetypes that match it, and the column of each term in each archetype. Archetypes are created only when command buffers are applied, so the cache is updated only then. Iteration only reads, so jobs can iterate at the same time.
- Iteration gives chunks. A system gets a typed slice of each column from the chunk. In debug builds, the column type is checked against the term.
- Iteration can start at a chunk index and stop after a number of chunks. This is how a system divides its work into jobs.
- Queries are registrations. `reload` clears them, and the game creates them again in `on_reload`.

### Systems

- A system is a procedure and its declared access: the components and resources that it reads and writes. `on_reload` registers systems.
- Each system has a **stage**:

  | Stage | Runs | Use for |
  |---|---|---|
  | `Fixed` | Once per fixed tick, zero or more times per frame | Physics, movement, gameplay that must be deterministic |
  | `Update` | Once per frame, before the script phase | Input response, UI, camera, effects |
  | `Late` | Once per frame, after the script phase | Work that must see the results of scripts |

- A system runs after the systems that it names in `after`. Otherwise registration order is kept. A system waits for every earlier system in its stage whose access conflicts with its own. Other systems run at the same time. A cycle of `after` names is an error, and the schedule then does not run.
- Access is the read and write terms of the system's query, and the extra `reads` and `writes` that it declares. A resource in `Game_State` is named with `component_id`, like a component.
- A system divides its chunks into batches (4 chunks by default) and starts one job per batch. A system without terms runs as one job.
- Each system gets a driver job. The driver waits for the systems before it, then starts the batches. All drivers start in run order, so a driver can wait for the counter of an earlier driver at once.
- Systems are registrations, like queries. Their procedures and names point into the DLL image, so `reload` clears them.
- The game drives the stages from its frame code:

  ```odin
  ecs.run_fixed(&s.world, dt, s)          // phase 2: the ticks that are due
  ecs.run_stage(&s.world, .Update, dt, s) // phases 3 and 4
  // phase 5: scripts, then ecs.apply with their buffers (phase 6)
  ecs.run_stage(&s.world, .Late, dt, s)   // phase 7, then transform propagation
  ```

### Command buffers

- Each job records into its own command buffer, in frame memory. The job gets the buffer through its data pointer, never through thread-local state (see [Core](core.md#job-system)).
- To spawn, a job calls `reserve`, which takes an entity index with one atomic. Later commands in the same buffer can use the new handle. `apply` creates every reserved entity first.
- A command for an entity that is no longer alive does nothing.
- The buffers are applied in system order and then job order, not in the order that jobs finish. This keeps the world deterministic.
- The slot index that a reservation gets depends on timing. Do not order or hash anything by entity handle value.

## Positions

World positions are fixed-point: `World_Position` holds three `i64` values in units of 2^-24 m (Q39.24).

- **Resolution:** 2^-24 m (about 60 nm), the same everywhere in the world. There is no loss of precision far from the origin, and no origin rebasing.
- **Range:** ±2^38 m (about 1.8 AU) on each axis. In this range, the difference of two positions always fits in an `i64`.
- **Two operations only.** `position_sub(a, b)` gives an `[3]f32` delta. `position_offset(p, delta)` adds an `[3]f32` delta. `World_Position` is a struct, so Odin does not allow other arithmetic on it. Use `position_lerp` for interpolation.
- **Rounding:** `position_sub` converts the difference to `f32` once, so the result is correctly rounded. `position_offset` rounds the delta to the nearest unit. Truncation would move every step toward zero.
- **Meters as `f64`** (`position_from_meters`, `position_to_meters`) are only for authoring, display and tests. Above 2^29 m from the origin, an `f64` cannot hold every position.
- **Spatial cells:** shift the raw value right to get an exact integer cell key.

### Where positions go

| Consumer | What it sees |
|---|---|
| Rendering | Render extraction computes `position_sub(entity, camera)`. The GPU sees only camera-relative `f32` matrices. |
| Physics | Simulates in `f32` relative to a `World_Position` anchor for each island, and writes back with `position_offset`. |
| Scripts | A `WorldPosition` userdata that supports only `-` (gives a `vector`) and `+ vector`. Entity helpers such as `entity:offset_to(other)` and `entity:move(v)` do not allocate. Scripts never see raw values: a Luau number is an `f64`. |
| Cooked scenes, editor link | Raw `i64` values. The editor shows meters, and sends a move as a delta or as raw values. |

## Transforms

- `Transform` is the world-space pose: a `World_Position`, a rotation and a scale. Every placed entity has one.
- For a root entity, `Transform` is the source of truth. A child has `Parent` and `Local_Transform`. Its `Local_Transform` holds an `f32` offset, a rotation and a scale relative to the parent, and it is the source of truth. Transform propagation writes the child's `Transform`.
- Engine components have small explicit IDs (`TRANSFORM_ID` and others). The game registers them with `register_engine_components` in its registration procedure.
- Change `Parent` only with `add` or `command_add`, so the world knows that the hierarchy changed. The world logs a cycle, or a hierarchy deeper than 64 levels, and does not propagate it.
- **Despawning a parent despawns its descendants.** To keep a child, remove its `Parent` first. Entities do not store their children, so finding them scans every child in the world. `apply` scans once, at the end, for every despawn in its buffers, and commands for the children in the same `apply` still run first. The immediate `despawn` scans at once, so use commands to despawn many entities.
- The world keeps every child sorted by depth, and sorts again only when the hierarchy changes. Propagation runs one level at a time. The entities in one level are processed in parallel.
- Propagation runs after each fixed tick and again after the `Late` stage.

## Fixed and variable rate

- The world has a tick rate in Hz (default 60). Tick `n` covers world time from `n * time.Second / tick_rate` to the start of tick `n + 1`, and runs when that interval has passed. The schedule is integer arithmetic on `time.Duration`, so it never drifts.
- Each frame runs every tick that is due, up to 4 ticks. If more ticks are due, the world drops the extra time, so the simulation runs slower, and logs a warning.
- A tick runs the `Fixed` systems, applies their command buffers and propagates transforms. The next tick sees the results of the previous one.
- `Fixed` systems get the tick duration as `dt`. `Update` and `Late` systems get the frame duration.
- **Input:** all ticks in a frame see the input state of that frame. An edge (pressed, released) goes to the first tick after it. If no tick runs in a frame, the edge waits for the next tick. `System_Context.first_tick` marks the first tick of a frame.
- **Interpolation:** an entity that moves in `Fixed` systems has a `Previous_Transform`, and so do its children. At the start of each tick, the world copies `Transform` to `Previous_Transform`. Presentation (render extraction, cameras, UI, audio) uses `presented`, or `interpolate` with the clock's `alpha`, the fraction of the current tick that has passed. Presentation is therefore up to one tick late.
- **Teleports:** to move an interpolated entity without a blend, use `teleport` or `command_teleport`. It sets both `Transform` and `Previous_Transform`.
- **Rate changes:** `set_tick_rate` takes effect from the next tick. The schedule stays exact across the change.

## The script view

- Scripts hold entity handles and access components through them, for example `entity:get(Transform)`. Scripts never hold pointers into component storage, because storage can move when components are added or removed.
- A `Behaviour` component holds a reference to a Luau object. Behaviours receive events (`on_spawn`, `on_hit`) and can start coroutines. This gives scripters a GameObject-like model.
- There is no per-entity `update` call by default. Calling into Luau for every entity every frame is too expensive at scale. The API favors events, coroutines and batch operations.
- Scripts run once per frame, between the `Update` and `Late` stages. A script that affects the simulation (for example, a force) records the change, and the next tick uses it.
- Scripts can define their own components. These are Luau tables in a side table keyed by entity. Native systems cannot query them efficiently, so components that need performance are defined in Odin.
