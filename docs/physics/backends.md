# Physics backends

How a physics backend plugs into cinnabar, and what it must do: the library it is, how the host chooses and loads it, the contract of `Physics_API` and `Host`, and the conformance suite that every simulating backend passes. Read [Design](design.md#the-boundary) first for why the boundary is plain data and C. The Jolt backend, `lib/core/physics/jolt/jolt_backend.cpp`, is the reference, and the null backend, `lib/core/physics/null`, is the smallest one.

**In this document:** [Loading](#loading) · [Choosing](#choosing) · [The contract](#the-contract) · [Features](#features) · [Writing a backend](#writing-a-backend) · [Conformance](#conformance)

## Loading

- **A backend is a library** that exports one C procedure, `cinnabar_physics_api`, which takes the host's `Host` table and returns the backend's `Physics_API`. `lib/core/physics/physics.h` declares both, as `cn_physics_host` and `cn_physics_api`, with the same layouts as `lib/core/physics/physics.odin`; both sides assert every size. The first call sets the backend up; later calls return the same table. The backend keeps the `Host` pointer until `shutdown`.
- **In development, the host loads it as a plugin.** `host.exe` and the game DLL are built with the `physics_backend` collection at `lib/core/physics/plugin`, whose `load` opens `physics_<name>.dll` beside the executable with `core:dynlib` and calls its entry point. The library stays loaded for the life of the host, since its worlds and the code their objects point into are the host's; a changed backend needs a host restart, as `luau.dll` does. `none` is the null backend, built into the host, so a project without physics needs no library.
- **In release and in tests, the build links it.** The collection points at a backend's package, such as `lib/core/physics/jolt`, which links the backend's static library and whose `load` returns its table. It honors `none` too, and warns that it ignores any other name, since a shipped game loads nothing. The justfile's `physics_backend` names the package.
- **The host checks a backend** before it uses it: `info().api_version` must be `API_VERSION`, and `info().layout` must be `layout_signature()`, an FNV-1a hash of the size of every type that crosses the boundary, in a fixed order, which `cn_physics_layout()` in `physics.h` computes the same way. The Odin side's `format_hash` hashes type info, which a C backend cannot compute; the signature catches a backend built against other layouts under the same version. A backend that does not load or does not match is an error, and the game runs on the null backend instead, so it starts without physics rather than not at all.

## Choosing

| Where | Key or argument | Values |
|---|---|---|
| `project.settings`, or `project.user.settings` on one machine | `physics.backend` | `jolt` (the default), `none`, or another backend's name |
| The host's command line | `--physics <name>` | The same; it replaces the settings |

The host reads the key itself, from the user's file first, before the game starts (`physics_host.backend_setting`), since it loads the backend before it loads the game. The game's own settings parser knows the key only so it does not warn about it. `core.init` takes the name as `physics_backend_name`; empty, it reads the settings.

## The contract

**Threads.**

- `submit`, `step`, `create_mesh_shape`, `world_create` and `world_destroy` run from one job or the frame code at a time, never at once.
- Queries (`raycast`, `raycast_all`, `raycast_batch`, `shape_cast`, `overlap`) and `body_state` run from any number of jobs at once, between steps and submits, and must be safe for that.
- `step` may run its own work on the host's jobs: `Host.jobs_run` starts frame jobs, whose data the host gives back to `Physics_API.run_job`, and `Host.jobs_wait` waits for a counter from a job or the frame code. Every job the step starts must finish before `step` returns. A job must not wait inside itself unless it is the step's caller: a fiber that waits may resume on another thread.

**Memory.** All the backend's memory comes from `Host.allocate`, `reallocate` and `free`, the host's heap, so the backend's state is the host's and a code reload of the game keeps it. `world_destroy_all` destroys every world, for a soft restart, and `shutdown` releases the rest at the host's exit.

**Handles.** The engine allocates `Body`, `Shape` and `Joint` handles, an index and a generation, and names them in commands before the backend knows them. The backend keeps a table from index to its own object, checks the generation of every handle it is given, and rejects a stale one. Indices are below the world's `World_Desc` limits.

**Commands.** `submit` runs a chunk of packets in order: an 8-byte `Command_Header` (kind and size, which includes the padding), then the payload, 8-byte aligned. Each command's meaning is in its comment in `physics.odin`. A command that is invalid, such as one for a stale handle, is logged with `Host.log`, does nothing, and makes `submit` return false; the others still run. In particular:

- Shapes are reference-counted: a body holds its shape, so the engine releases a shape's handle right after the body that uses it.
- Destroying a body ends its contacts and removes its joints; the joint's handle stays valid until `Destroy_Joint`.
- `Set_Enabled` takes a body out of the simulation without destroying it, and ends its contacts.
- `Create_Compound` names its children after its payload.

**Results.** `results` points into the backend's memory, valid until the next `submit` or `step`, and a `submit` or `step` after a step starts them again. `moved` is every body that moved in the step, and those that fell asleep in it, once each, sorted by handle index. `contacts` are body pairs, not sub-shape pairs, that began or ended since the last step, sorted by `a`, `b` and kind, with `a`'s index below `b`'s; a pair whose bodies only fell asleep has not ended. `broken` are the joints that broke. The sorting makes results the same on every run.

**Queries** return hits in a defined order: by distance, then by body handle, or by body handle for an overlap. A filter is data: layers, sensors, and up to 8 bodies to ignore. A ray ignores the back faces of triangles.

**Positions** are `f64` offsets from the world's anchor, which only the engine knows; rotations are `f32` quaternions as x, y, z, w. A triangle's front face is the one that `(b - a) x (c - a)` points out of.

## Features

`info().features` says what a backend does. The engine reads it when it makes a world, and ignores a component that needs a feature the backend lacks, with one warning for each feature:

| Feature | Without it |
|---|---|
| `Rigid_Bodies` | The sync makes no body. |
| `Sensors` | A sensor collider makes no body. |
| `Joints` | Joint components are ignored. |
| `Queries` | Every query misses. |
| `Characters`, `Vehicles`, `Soft_Bodies`, `Cloth`, `Hair`, `Buoyancy`, `Save_State` | Reserved: no component needs them, and the Jolt backend reports none of them. |
| `Deterministic`, `Double_Precision` | Informative: the build's options. |

The null backend reports `Rigid_Bodies`, `Joints`, `Queries` and `Sensors`: it takes every command and simulates none.

## Writing a backend

1. Include `physics.h`, and implement every procedure of `cn_physics_api`. A procedure the backend cannot do still takes its arguments and does nothing, as the null backend's do.
2. Export `cinnabar_physics_api`; return `CN_PHYSICS_API_VERSION` and `cn_physics_layout()` in `info`.
3. Build it with the static CRT, as a DLL named `physics_<name>.dll` for development and a static library for release, as `lib/core/physics/jolt/CMakeLists.txt` builds Jolt's, and copy the DLL beside `host.exe`.
4. Add an Odin package beside `lib/core/physics/jolt`, with a `load(host, name)` that links the static library, for release builds that choose it with the justfile's `physics_backend`.
5. Pass the conformance suite.

## Conformance

`lib/core/physics/conformance` is the suite that every simulating backend passes, driven through `Physics_API` with no engine world: a falling box that rests and sleeps; rays with filters; stale handles; determinism to the bit; an offset shape and a disabled body; contacts that begin, last through sleep and end; a sensor; every query; joints, a break and a motor; and mesh and hull shapes. A backend's tests call each procedure with its table on the host's job system, as `lib/core/physics/jolt/jolt_test.odin` does, and `lib/core/physics/plugin/plugin_test.odin` runs a test through the DLL as the host loads it.
