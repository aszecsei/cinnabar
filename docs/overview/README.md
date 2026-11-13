# Overview

The whole engine: what runs where, the boundary that hot reload imposes, how to build, and the rules every part follows.

## Documents

Read them in this order the first time.

| Document | What it covers |
|---|---|
| [Architecture](architecture.md) | The frame's phases and each part's role, with pointers into the layers. |
| [Hot reload](hot-reload.md) | The rules game-side code follows, what survives a reload, and the reload sequence. |
| [Getting started](getting-started.md) | Making a game with the engine: building the engine once, a new project, the loop, Odin in a project, and releases. |
| [Building and running](building-and-running.md) | The `just` recipes, and a walkthrough of the sample game's frame. |
| [Conventions](conventions.md) | The rules that cut across every layer. |

## Overview

A shipped game is one executable and a folder of cooked content.

- The **executable** contains the engine and the game code, compiled together. In release builds they are statically linked. In development, they are built as a DLL that a host process loads and hot-reloads.
- The **content folder** is a loose cache of blobs, one per asset, which the asset pipeline compiles from source assets.

```mermaid
flowchart TB
    subgraph DEV["Development"]
        direction TB
        EDITOR["editor.exe (C#, optional)"]
        subgraph HOSTEXE["host.exe"]
            HOST["src/host<br/>(reload loop, editor link)"]
            DEVCORE["lib/core<br/>(platform)"]
        end
        subgraph DLL["mygame_N.dll"]
            DEVENGINE["lib/engine"]
            DEVGAME["samples/mygame"]
        end
        EDITOR <-->|"editor link"| HOSTEXE
        HOSTEXE <-->|"Game_API / Platform_API"| DLL
        LUAU["luau.dll"]
        HOSTEXE --> LUAU
        DLL --> LUAU
        CACHE[("cache/<br/>loose cooked assets")]
        DLL --> CACHE
    end

    subgraph REL["Release"]
        direction TB
        subgraph EXE["mygame.exe (direct calls)"]
            RELCORE["lib/core"]
            RELENGINE["lib/engine"]
            RELGAME["samples/mygame"]
            RELLUAU["Luau (static)"]
        end
        RELCACHE[("content/<br/>loose cooked assets")]
        EXE --> RELCACHE
    end
```

Four programs take part in development, and only the first survives into release:

| Program | Language | Role | Document |
|---|---|---|---|
| `host.exe` + `mygame_N.dll` | Odin | The game. The host owns the window, the GPU device, memory and the job system, and reloads the DLL, which holds the engine and the game code. | This one, then [Hot reload](hot-reload.md) and [Core](../core/README.md) |
| `cook.exe` | Odin | The asset cooker: a batch compiler of source assets into blobs, and a daemon that keeps the cache current and does the editor's asset operations. | [Content pipeline](../content/README.md) |
| `editor.exe` | C# | The editor. It starts the host and the daemon as child processes, owns the scene being edited, and shows the host's frames in its viewport. | [Editor](../editor/README.md) |
| `luau.dll` | C++ | One copy of the Luau VM that the host and the game DLL share, so that script state survives a code reload. | [Scripting](../scripting/README.md) |

The engine is about 50 000 lines of Odin, 22 000 lines of C# and 4 500 lines of HLSL.

## Repository layout

```
cinnabar/
├── justfile                 Every build, cook, run and test recipe (see Building and running)
├── docs/                    These documents
├── lib/
│   ├── core/                Host side: the platform layer
│   │   ├── api.odin         Platform_API and Game_API, the two structs that cross the boundary
│   │   ├── platform.odin    Frame begin/end, memory arenas, the DLL loader
│   │   ├── input.odin, window_windows.odin, file.odin
│   │   ├── jobs/            The fiber job system
│   │   ├── layout/          Type layout hashing, for reload checks
│   │   ├── gpu/             The GPU interface, the null backend, the D3D12 backend, and cinnabar.hlsli
│   │   ├── luau/            Odin bindings to Luau, and the CMake project that builds it
│   │   └── script/          The script VM's heap and host trampolines
│   └── engine/              Game side: everything hot-reloaded
│       ├── ecs/             Entities, archetypes, queries, systems, transforms, positions
│       ├── render/          The render graph, extraction, and the built-in renderer
│       ├── asset/           The asset runtime; format/ (shared with the cooker) and cook_link/
│       ├── script/          Luau bindings, behaviours, the scheduler, prelude.luau, engine.d.luau
│       ├── scene/           The scene loader and the component field walker
│       ├── editor/          The game side of the editor link; link/ holds the messages
│       ├── volume/          Volumes: settings that depend on where a point is
│       ├── project/         The project settings file
│       ├── debug/           The immediate-mode debug drawing API
│       ├── ui/              The UI: documents, layout, MSDF text, the batch, focus and navigation, the Ui library
│       ├── ai/              Agents, blackboards, actions, perception, and a decision module for each technique
│       ├── nav/             Navmeshes at runtime: queries, path requests, the crowd and its actions
│       ├── random/          The engine's generator, which scripts' Random shares
│       ├── wire/            Framing, wire format and schema writer, shared by both links
│       └── content/         Engine content: shaders, shading models, the default and placeholder materials, the preview meshes
├── src/
│   ├── host/                The development host: main.odin (the reload loop), link.odin (the editor link server)
│   └── editor/              The C# editor solution, one project per concern
├── tools/
│   ├── cook/                The cooker: one file per asset kind, the daemon, the index, operations, the cook link
│   ├── viewer/              Shows a host's shared frames without the editor
│   ├── editorctl/           Drives a running editor from a terminal: screenshots and GIFs
│   ├── ltc_fit/             Fits the area lights' lookup tables
│   └── stbn/                Makes the ambient occlusion's and the reflections' blue noise
├── samples/mygame/          The sample that exercises most of the engine: game/ (its hooks), content/, project.settings
├── samples/intel/           Intel's USD scenes, with no Odin: content/, project.settings
└── vendor/                  luau, compressonator, meshoptimizer, jolt, opus, vorbis, ogg, msdfgen, lz4, recastnavigation (submodules); agility, dxc (downloaded)
```

Packages are small and single-purpose. A package's tests are beside it as `*_test.odin`, and the justfile's `test` recipe lists every package with tests.

## Modules

| Module | Side | Responsibility |
|---|---|---|
| `lib/core` | Host | Platform services and every OS or device resource: window, input, GPU device, worker threads, fiber scheduler, virtual memory, file I/O, file watching, dynamic library loading. |
| `lib/core/gpu` | Shared | Backend-agnostic GPU interface: handles and the command list format. Backends execute the command lists that the engine records. |
| `lib/core/luau` | Shared | Odin bindings to the Luau C API. |
| `lib/core/script` | Host | The script VM's allocator, and every function pointer that Luau stores. |
| `lib/core/layout` | Shared | Type layout hashing, used to detect `Game_State` and command format changes across a reload. |
| `lib/core/gpu/d3d12` | Host | The D3D12 backend. |
| `lib/core/gpu/null` | Host | A backend that validates command lists and executes nothing. Used for headless tests. |
| `lib/engine` | Game | Everything that does not own an OS resource: world, render frontend, asset runtime, script bindings, gameplay systems. |
| `lib/engine/script` | Game | Script bindings, behaviours, the coroutine scheduler and script hot reload. |
| `lib/engine/asset` | Game | The asset runtime: loading by GUID, handles and the sources of blobs. |
| `lib/engine/scene` | Game | The scene loader, which replaces the world with a cooked scene or the editor's snapshot, and the walk over a component's fields that scenes and the editor share. |
| `lib/engine/render` | Game | The render graph, render extraction, and the built-in renderer: views, layers, materials and the frame's passes. |
| `lib/engine/editor` | Game | The game side of the editor link: component types, the entity list and its deltas, watched values, scene snapshots and edit operations, and the viewport tools' passes: picking from the entity ID buffer, the selection outline and the gizmo. |
| `lib/engine/wire` | Shared | The transport of the editor link and the cook link: framing, the wire format and the schema writer, for any union of messages. |
| `lib/engine/wire/serve` | Host | The server side of both links, for the host and the cook daemon: one editor at a time, the reader and writer threads, the outbox, the logger, and which connection is linked. `lib/engine/wire/servetest` is its tests' editor end. |
| `lib/engine/volume` | Game | Volumes: settings components that change with where a point is, such as the post-processing at the camera (see [World](../world/volumes.md#volumes)). |
| `lib/engine/project` | Game | The project's settings file and the user's file beside it, which the game reads again when they change (see [Project settings](architecture.md#project-settings)). |
| `lib/core/audio` | Host | The boundary to an audio backend, and the mixer behind it, whose threads run through a code reload (see [Audio](../audio/README.md#overview)). |
| `lib/engine/audio` | Game | `Audio_Source` and `Audio_Listener`, spatial sound from presented poses, occlusion by physics rays, and the `Audio` script binding (see [Audio](../audio/design.md#the-game-side)). It also holds the audio device's test tone (see [Core](../core/audio.md#test-tone)). |
| `lib/engine/ui` | Game | The UI: `Ui_Document`, documents built from UI document assets, the cascade of styles, layout, text shaped with kb_text_shape and drawn from fonts' distance fields, one batch into the UI layer, focus and gamepad navigation, and the `Ui` script library (see [UI](../ui/README.md)). |
| `lib/engine/debug` | Game | Immediate-mode debug drawing: lines, boxes, spheres, arrows and axes, in world positions (see [Rendering](../rendering/layers-and-output.md#debug)). |
| `lib/engine/anim` | Game | Animation on skinned meshes: `Animator` and `Root_Motion`, the `animate` system in fixed ticks, animation events, and the poses that the renderer skins with (see [Animation](../animation/design.md#the-ecs)). |
| `lib/engine/ai` | Game | Agents: `Agent` and `Agent_State`, their blackboards' values, running actions and memories in a pool, the `ai perceive`, `ai think` and `ai actions` `Fixed` systems, native and script actions, sight and hearing for `Perceiver`s, and the `Blackboard`, `Agent` and `Perception` script libraries (see [AI: Agents](../ai/agents.md) and [AI: Perception](../ai/perception.md)). |
| `lib/engine/ai/behavior_tree` | Game | The decision module of behavior trees: sequences, selectors, parallels, actions, waits, sets and conditions, with guards that abort and other decorators, and each node's state in the agent's module state (see [AI: Behavior trees](../ai/behavior-trees.md)). |
| `lib/engine/ai/utility` | Game | The decision module of utility: options scored from blackboard inputs through response curves, the best or a weighted pick by the agent's generator, momentum and cooldowns, scoring for each perceived target, and the last scores for debuggers and scripts (see [AI: Utility](../ai/utility.md)). |
| `lib/engine/ai/goap` | Game | The decision module of GOAP: goals scored by priority and considerations, a regressive A* for the cheapest plan of actions, spread over ticks within a node budget shared among agents, the plan runner that writes the actions' effects and replans, and the plan for debuggers and scripts (see [AI: GOAP](../ai/goap.md)). |
| `lib/engine/ai/goap/search` | Shared | GOAP's regressive A*, over the technique's data alone, which the GOAP module and the cook daemon's plan preview both run (see [AI: GOAP: The search](../ai/goap.md#the-search)). It imports only `format`. |
| `lib/engine/ai/htn` | Game | The decision module of HTN: a root task decomposed by methods in order of preference, with backtracking, spread over ticks within a budget of steps shared among agents, a better method that cuts in by the method traversal record, the plans run by GOAP's runner, and the plan and its methods for debuggers and scripts (see [AI: HTN](../ai/htn.md)). |
| `lib/engine/nav` | Game | Navigation: `Nav_Mesh_Volume`, `Nav_Path`, `Nav_Agent` and `Nav_Agent_State`, a scene's navmeshes loaded with it, the queries on them, the path requests and their `Fixed` system, the crowd, which walks agents along their paths around each other through their characters, the `move_to` and `stop` actions, the `Navigation` script library and drawing (see [AI: Navigation](../ai/navigation.md)). |
| `lib/engine/random` | Game | The engine's generator, xoshiro256\*\*, plain data that a code reload keeps. Scripts' `Random` and `nav.random_point` draw from it (see [Scripting: Random](../scripting/api.md#random)). |
| `lib/engine/anim/graph` | Game | The animation graph: states, fades and blends of clips, events, root motion, and poses sampled, blended and composed into a palette. It imports nothing from the world, scripts or the renderer, so what it gives depends on its inputs alone (see [Animation](../animation/design.md#design)). |
| `lib/engine/editor/link` | Shared | The editor link's messages, and the schema that the editor's C# is generated from. The host and the game both import it. |
| `lib/engine/asset/format` | Shared | GUIDs, `.meta` files and blob layouts. `tools/cook` and the runtime both import it. |
| `lib/engine/asset/cook_link` | Shared | The cook link's messages, between the editor and the cook daemon, and the schema that the editor's C# is generated from. `tools/cook` imports it. |
| `lib/engine/game` | Game | The standard game: every engine package started, stepped, reloaded and drawn in order, with `Hooks` for a project's own Odin. `standard/game` is the standard game as a project's game package, and `runtime` is the one release entry point (see [The game package](../world/game-package.md)). |
| `samples/<game>` | Game | A project: `project.settings`, `content/`, and a `game/` package of hooks when it has Odin. |
| `src/host` | Host | The generic development host. It loads the game DLL, runs the frame loop, drives hot reload and serves the editor link. One host serves every game. |
| `src/editor` | — | The C# editor application. It runs `host.exe` and the cook daemon as child processes. |
| `tools/cook` | — | The asset compiler and the cook daemon, which watches the content roots and does the editor's asset operations. |
| `vendor/luau` | Shared | The Luau VM and compiler. |
| `vendor/jolt` | Host | Jolt Physics, which the physics backend in `lib/core/physics/jolt` builds into (see [Physics](../physics/design.md#where-jolt-lives)). |
| `vendor/dxc` | Tools | The DXC shader compiler. Only `tools/cook` uses it. |
| `vendor/` | — | Other third-party code. |

"Host side" code is in the executable during development and is not hot-reloaded. Changing it means restarting. "Game side" code is in the DLL during development and is hot-reloaded. "Shared" packages are compiled into both, so they import nothing that is only on one side, and a change to their layouts is checked at reload. In release builds both sides are in one executable and the distinction disappears.

### The boundary

The two sides communicate only through two structs of procedures, both in `lib/core/api.odin`:

- **`Platform_API`** (host → game): what `core` provides to the engine. Its fields are the complete list of what a game may ask of the platform: allocators and virtual memory, time, input, files, the window, jobs, every `gpu_*` procedure, and the script VM's `script_*` procedures.
- **`Game_API`** (game → host): `init`, `update`, `shutdown`, `on_reload`, `state_size`, `layout_hash`, `abi_hash` (the GPU command format and `Platform_API`), `script_types` (see [Scripting](../scripting/tooling-and-hot-reload.md#types-and-tooling)), and `editor_poll`, the game's side of the editor link (see [Editor](../editor/link.md#world)).

In development, the host gets `Game_API` from the DLL's exported `cinnabar_game_api` procedure. In release, `lib/engine/game/runtime` calls the same procedure of the game package that it links, and fills `Platform_API` with direct procedure references, so the code paths are the same in both configurations. Code must not branch on `HOT_RELOAD` outside `src/host` and `lib/engine/game/runtime`.

## References

- **Odin:** [odin-lang.org](https://odin-lang.org) and the [overview](https://odin-lang.org/docs/overview/). The engine relies on Odin's file-suffix platform selection, collections for backend selection, `context` allocators, and runtime type info for the field walkers.
- **Hot reload with one state struct:** Casey Muratori's Handmade Hero (days 21–22) established the pattern of a host that owns memory and a game DLL that owns only code. Our Machinery's blog post [*DLL Hot Reloading in Theory and Practice*](https://ruby0x1.github.io/machinery_blog_archive/post/dll-hot-reloading-in-theory-and-practice/index.html) covers the pitfalls that [Hot reload](hot-reload.md) rules out.
- **Fiber job systems:** Christian Gyrling, [*Parallelizing the Naughty Dog Engine Using Fibers*](https://www.gdcvault.com/play/1022186/Parallelizing-the-Naughty-Dog-Engine), GDC 2015. The job system in `lib/core/jobs` follows its shape: a fiber pool, atomic counters, and no OS locks across a yield.
- **A host process that owns the device and a tool that mirrors the world:** the editor–host split is the one Unity, Unreal and most in-house engines use between an editor and a play-in-editor runtime, taken one step further by putting them in separate processes, so a game crash cannot take the editor down.
- **Luau:** [luau.org](https://luau.org) and the [repository](https://github.com/luau-lang/luau).
- **just:** [github.com/casey/just](https://github.com/casey/just).

- Casey Muratori, Handmade Hero, days 21 (*Loading Game Code Dynamically*) and 22 (*Instantaneous Live Code Editing*): the origin of the host-owned-memory, code-only-DLL pattern.
- Our Machinery, [*DLL Hot Reloading in Theory and Practice*](https://ruby0x1.github.io/machinery_blog_archive/post/dll-hot-reloading-in-theory-and-practice/index.html): the catalogue of things that point into a DLL's image, and the "reload callbacks" pattern that `on_reload` is.
- Odin's [runtime type info](https://odin-lang.org/docs/overview/#type-info) and `reflect` package, which the layout hash and the field walkers use.
