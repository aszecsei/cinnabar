# World

All world data lives in a native ECS in `lib/engine`. Scripts see an object-style API on top of it. See [Architecture](architecture.md#world-model) for the overview, and [Frame](architecture.md#frame) for where world updates happen in a frame.

## ECS

- **Entities** are generational handles. A handle to a destroyed entity is detected; it is never reused silently.
- **Component types have stable IDs.** The ID is a hash of the type's name, or an explicit value. It is never a `typeid` (see [Hot reload](hot-reload.md#rules), rule 3). Cooked scenes, the editor link and scripts all identify component types by this ID.
- **Native systems** run as jobs on the job system. Engine systems (transforms, physics, animation, render extraction) and performance-critical game logic are native.
- **Structural changes are deferred.** Spawning, destroying, and adding or removing components go into command buffers. The buffers are applied at fixed points in the frame. This applies to native systems and to scripts.

## The script view

- Scripts hold entity handles and access components through them, for example `entity:get(Transform)`. Scripts never hold pointers into component storage, because storage can move when components are added or removed.
- A `Behaviour` component holds a reference to a Luau object. Behaviours receive events (`on_spawn`, `on_hit`) and can start coroutines. This gives scripters a GameObject-like model.
- There is no per-entity `update` call by default. Calling into Luau for every entity every frame is too expensive at scale. The API favors events, coroutines and batch operations.
- Scripts can define their own components. These are Luau tables in a side table keyed by entity. Native systems cannot query them efficiently, so components that need performance are defined in Odin.
