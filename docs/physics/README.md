# Physics

Rigid bodies, constraints, collision queries and sensors: the boundary between the engine and a physics backend in `lib/core/physics`, the Jolt backend, and the components and systems in `lib/engine/physics`. The boundary, the Jolt backend, scripts in fixed ticks, rigid bodies in the world, queries, sensors and events, constraints, mesh colliders, and plugins are built (every phase); the rest of the design and its phases are in [Design](design.md).

## Documents

| Document | What it covers |
|---|---|
| [Design](design.md) | Where Jolt lives, the command-list boundary, positions and precision, the components, the physics tick, layers, shapes, constraints, queries, events, scripts, the editor, determinism, 2D physics, plugins, and the phases. |
| [Backends](backends.md) | How a backend plugs in: loading as a plugin or linked, choosing with `physics.backend`, the contract of `Physics_API` and `Host`, features, and the conformance suite. |

## Overview

| Package | Side | Responsibility |
|---|---|---|
| `lib/core/physics` | Shared | The boundary: handles, descriptions, the command format, `Physics_API` and `Host`, and `physics.h`, the same in C. |
| `lib/core/physics/host` | Host | The `Host` table: the heap, the job system and the log for a backend. |
| `lib/core/physics/conformance` | Shared | The tests that every simulating backend passes. |
| `lib/core/physics/jolt` | Host | The Jolt backend, built as `physics_jolt.dll` in development and statically in release. |
| `lib/core/physics/null` | Host | A backend that simulates nothing, for tests and for games without physics. |
| `lib/core/physics/plugin` | Host | The development host's loader of a backend as a plugin. |
| `lib/engine/physics` | Game | Components, the sync between the world and the backend, the physics tick, queries, events and script bindings. |

The data flow in a fixed tick: the `Fixed` systems run; the physics tick compares the world's components with what the backend has, records command lists, submits them and steps; and the sync writes the bodies that moved back to their `Transform`s and keeps the tick's contact events for native systems and scripts.

## Future work

See [Design: Future work](design.md#future-work): a character controller, vehicles, buoyancy, soft bodies and cloth, hair, ragdolls, and the precision and loading work that large worlds and large levels need.

## References

- Jorrit Rouwé, [Jolt Physics](https://github.com/jrouwe/JoltPhysics) and its [architecture document](https://jrouwe.github.io/JoltPhysics/): the threading rules, double precision, determinism and the job system interface that [Design](design.md) builds on.
- Erin Catto, [Box2D](https://box2d.org) v3: the expected 2D backend.
- Godot's `PhysicsServer3D` and `PhysicsServer2D`: a physics interface by handles and plain descriptions, separate for each dimension, that a different implementation can fill.
- Unity, [*Rigidbody*](https://docs.unity3d.com/Manual/rigidbody-physics-section.html) and the collision messages: the component model and script events that the Unity mapping follows.
- Glenn Fiedler, [*Fix Your Timestep!*](https://gafferongames.com/post/fix_your_timestep/): stepping physics in fixed ticks and presenting interpolated poses.
