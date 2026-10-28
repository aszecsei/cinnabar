# ECS

Entities, the component registry, archetype storage, queries, systems and their stages, and the command buffers that defer structural changes. The script view at the end is how [Scripting](../scripting/README.md) sees the same world.

**In this document:** [ECS](#ecs) · [The script view](#the-script-view)

## ECS

- **Entities** are generational handles: a 32-bit index and a 32-bit generation. A handle to a destroyed entity is detected; it is never reused silently. A slot whose generation would wrap is retired.
- **Component types have stable IDs.** The ID is a hash of the type's name, or an explicit value. It is never a `typeid` (see [Hot reload](../overview/hot-reload.md#rules), rule 3). Cooked scenes, the editor link and scripts all identify component types by this ID.
- **Native systems** run as jobs on the job system. Engine systems (transforms, physics, animation, render extraction) and performance-critical game logic are native.
- **Structural changes are deferred.** Spawning, destroying, and adding or removing components go into command buffers. The buffers are applied at fixed points in the frame. Scripts are the exception: the script phase is serial, so they change the structure at once, except for despawns (see [Scripting](../scripting/api.md#structural-changes)).
- **Resources are not entities.** World-wide state, such as the active camera or the physics settings, is a plain field in `Game_State`.

### Component registry

- `on_reload` rebuilds the registry, like every other registration. An entry holds the stable ID, the size, the alignment, the `typeid`, the name and the layout hash of the type. The `typeid` and the name point into the DLL image, so they are valid only in this table. Persistent world data refers to a component type only by its ID.
- The default ID is the hash of `package.Type`. Renaming a type or its package changes the ID, so give an explicit ID to a type that cooked content already uses.
- Component storage is untyped bytes, so the `Game_State` layout hash does not see component layouts. The game's `layout_hash` therefore mixes in `registry_layout_hash`. A changed component causes a soft restart (see [Hot reload](../overview/hot-reload.md#reload-sequence)). `layout_hash` has no state, so the game registers its components in one procedure. It calls this procedure on the world's registry in `init` and `on_reload`, and on a `Registry` on the stack in `layout_hash`.
- **Engine IDs** are small explicit numbers, registered by `register_engine_components` and the packages' own `register_components`: the transforms and activity tags, `Behaviours` (16), `Camera` (32), `Mesh_Renderer` (33), the lights (34 to 36, 39 to 41), `View_Model` (37), `Fog` (38), `Volume` (42) and the renderer's settings (43 to 50). The sample's components start at 1001. Pick explicit IDs for a game from a range of its own.

### Storage

- Entities with the same set of component types share an **archetype**. An archetype stores its entities in **chunks** of 16 KiB. A chunk is struct-of-arrays: one column per component type.
- All world storage is in virtual memory that the game reserves through `Platform_API` (see [Core](../core/jobs-and-memory.md#memory)). The reservations never move, so world data holds no allocators and no pointers. Chunks come from a pool in one reservation, and a freed chunk goes back to the pool.
- Removing an entity moves the last row of its archetype into its place.
- Tags (zero-size components) select the archetype but take no column space.
- A chunk is the unit of work for a job.

### Queries

- A query is a set of terms. Each term names a component ID and an access: read, write, optional or excluded.
- A query caches the archetypes that match it, and the column of each term in each archetype. Archetypes are created only when command buffers are applied, so the cache is updated only then. Iteration only reads, so jobs can iterate at the same time.
- Iteration gives chunks. A system gets a typed slice of each column from the chunk. In debug builds, the column type is checked against the term.
- Iteration can start at a chunk index and stop after a number of chunks. This is how a system divides its work into jobs.
- Queries are registrations. `reload` clears them, and the game creates them again in `on_reload`.
- **Inactive entities:** a query excludes the `Inactive` tag unless it names `Inactive` in a term. Render extraction, physics and game systems therefore skip inactive entities without extra terms. `ecs.collect` skips them the same way. `Disabled` marks an entity that was deactivated itself. The world adds `Inactive` to it and to its descendants. `ecs.set_active` updates them at once, and `apply` updates them for the changes in its buffers. Native code that adds or removes `Parent` or `Disabled` directly calls `update_activity` before the next query. Activity is the scripts' `set_active` (see [Scripting](../scripting/behaviours.md#enabled-state)).
- **The log:** `ecs.watch` makes the world log the removal of chosen components, with their first 8 bytes, and every change of `Inactive`. The script runtime watches `Behaviours`, and drains the log with `take_log` each script phase. A world that nothing watches logs nothing.

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
- Each batch is a profiler zone named after its system, so the editor's profiler shows each system's time ([Profiling](../core/profiling.md#zones)). `register_system` interns the name.
- The game drives the stages from its frame code:

  ```odin
  ticks := ecs.begin_ticks(&s.world, dt)  // phase 2: the ticks that are due
  for ecs.next_tick(&ticks) {
      ecs.run_tick_systems(&ticks, s)     // Previous_Transform, the Fixed systems, apply
      // the scripts' fixed step (see docs/scripting/behaviours.md#fixed-step)
      ecs.update_transforms(&s.world)
  }
  ecs.run_stage(&s.world, .Update, dt, s) // phases 3 and 4
  // phase 5: scripts, then ecs.apply with their buffers (phase 6)
  ecs.run_stage(&s.world, .Late, dt, s)   // phase 7, then transform propagation
  ```

  A game whose ticks run only the `Fixed` systems calls `ecs.run_fixed(&s.world, dt, s)` in place of the loop. While a tick runs, the clock's `tick` is its number, `ecs.tick_time` the world time at its end, and `ecs.first_tick` says whether it is the first of the frame.

### Command buffers

- Each job records into its own command buffer, in frame memory. The job gets the buffer through its data pointer, never through thread-local state (see [Core](../core/jobs-and-memory.md#job-system)).
- To spawn, a job calls `reserve`, which takes an entity index with one atomic. Later commands in the same buffer can use the new handle. `apply` creates every reserved entity first.
- A command for an entity that is no longer alive does nothing.
- The buffers are applied in system order and then job order, not in the order that jobs finish. This keeps the world deterministic.
- The slot index that a reservation gets depends on timing. Do not order or hash anything by entity handle value.

## The script view

Details: [Scripting](../scripting/api.md#the-entity-and-component-view).

- Scripts hold entity handles and access components through them, for example `entity:get(Health)`. An entity is a light userdata whose payload is the handle, so it does not allocate and works as a table key. Scripts never hold pointers into component storage, because storage can move when components are added or removed.
- A behaviour is a script class, like Unity's `MonoBehaviour`. The native `Behaviours` component holds a reference to the entity's record of behaviour instances. Behaviours receive events (`on_trigger_enter`), own coroutines and hold the script-side state of the entity. Native systems cannot query that state efficiently, so state that needs performance is a native component.
- Per-entity `update` is opt-in for each class. Calling into Luau for every entity every frame is too expensive at scale. The API favors events, coroutines and batch operations.
- Scripts run once per frame, between the `Update` and `Late` stages. A script that affects the simulation (for example, a force) writes a component, and the next tick uses it.
