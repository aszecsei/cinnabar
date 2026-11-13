# cinnabar documentation

cinnabar is a fiber-based game engine in Odin, with a C# editor, a Luau scripting runtime, a D3D12 backend and an asset cooker. These documents describe how it is built and why. They are arranged in layers, from the whole engine down to each part, and each layer is a folder with a README that is its overview and reading order. Source comments link to sections as `docs/<layer>/<document>.md#<section>`, and `just docs-check` verifies every such link.

## Reading order

Read the layers in this order the first time. Each one assumes the ones before it.

| Step | Layer | Scope | Read it to learn |
|---|---|---|---|
| 1 | [Overview](overview/README.md) | The whole engine | What runs where (host, game DLL, editor, cooker), how the repository is laid out, the rules of [hot reload](overview/hot-reload.md) that shape every design, how to [build and run](overview/building-and-running.md), and the [conventions](overview/conventions.md) every layer follows. |
| 2 | [Core](core/README.md) | `lib/core` | The platform layer: the frame bracket and `Platform_API`, the fiber job system, memory arenas, input, and the porting surface. |
| 3 | [World](world/README.md) | `lib/engine/ecs`, `volume` | The ECS, fixed-point positions and transforms, fixed ticks, render extraction and volumes. |
| 4 | [GPU](gpu/README.md) | `lib/core/gpu` | The backend-agnostic GPU interface: the hardware floor, bindless binding, command buffers, the render graph, queues, streaming, mesh shaders, ray tracing and presentation. |
| 5 | [Rendering](rendering/README.md) | `lib/engine/render` | The built-in renderer: the frame, the GPU scene, layers, lighting, transparency, materials, ambient occlusion, global illumination, fog and post-processing. |
| 6 | [Scripting](scripting/README.md) | `lib/core/script`, `lib/engine/script` | Luau embedding across the reload boundary, the API scripts see, behaviours, and the tooling. |
| 7 | [Physics](physics/README.md) | `lib/core/physics`, `lib/engine/physics` | Physics on Jolt: the boundary a backend implements, plugins, the components, the physics tick, joints, queries and events. |
| 8 | [Animation](animation/README.md) | `lib/engine/anim` | The animation graph: states, fades and blends of clips, events, root motion, and the poses presented between ticks. |
| 9 | [Audio](audio/README.md) | `lib/core/audio`, `lib/engine/audio` | Sound in the world: the mixer on its own thread, the boundary a backend implements, spatial sound, occlusion, streaming and the script binding. |
| 10 | [UI](ui/README.md) | `lib/engine/ui` | Menus and HUDs: documents on entities, the cascade of styles, layout and the UI scale, MSDF text, the one batch, focus and gamepad navigation, and the `Ui` library. |
| 11 | [Content pipeline](content/README.md) | `tools/cook`, `lib/engine/asset` | Identity and cooking, each asset kind, the cook daemon and its operations, blobs and loading. |
| 12 | [AI](ai/README.md) | `lib/engine/ai`, `lib/engine/nav`, `lib/engine/random` | Agents: blackboards, decisions run on jobs within a budget, native and script actions, and sight and hearing that fill the blackboard. Navigation: a scene's navmeshes loaded with it, queries for points and paths on them, path requests solved on jobs within a budget, and crowds that follow their paths and avoid each other. |
| 13 | [Editor](editor/README.md) | `src/editor`, `lib/engine/editor` | Processes and projects, the document model and scenes, the editor link, the viewport, the shell and panels, and the material editor. |

[History](history.md) keeps the implementation phases of each layer, in the order they were built.

## By audience

Not everyone needs every layer.

| You are… | Read |
|---|---|
| Writing gameplay in Luau | [Scripting: API](scripting/api.md), [Behaviours](scripting/behaviours.md), [Tooling](scripting/tooling-and-hot-reload.md); then [World: ECS](world/ecs.md) for what is underneath |
| Making agents find their way | [Content: Navmeshes](content/kinds/nav-meshes.md), [AI: Navigation](ai/navigation.md) |
| Making agents decide and act | [Content: Blackboards](content/kinds/blackboards.md), [Content: Decisions](content/kinds/decisions.md), [AI: Agents](ai/agents.md) |
| Making agents see and hear | [Content: Perceptions](content/kinds/perceptions.md), [AI: Perception](ai/perception.md) |
| Making menus and HUDs | [Content: UI documents](content/kinds/ui-documents.md), [Content: Fonts](content/kinds/fonts.md), [UI: Design](ui/design.md) |
| Making content: materials, textures, meshes, scenes | [Content: kinds](content/README.md#documents), [Rendering: Materials](rendering/materials.md), [Editor: Material editor](editor/material-editor.md), [Editor: Shell and panels](editor/shell-and-panels.md) |
| Writing native game code | Everything in order; [Overview: Conventions](overview/conventions.md) and [Hot reload](overview/hot-reload.md) first |
| Working on the renderer | [GPU](gpu/README.md), then [Rendering](rendering/README.md) in order |
| Working on the editor or the cooker | [Editor](editor/README.md) and [Content pipeline](content/README.md); [Editor: Editor link](editor/link.md) for the protocol they share |
| Porting | [Core: Platform](core/platform.md) and [GPU: Interface](gpu/interface.md) |

## What each document contains

Every document has the same shape:

1. **An introduction** that says what the document covers and what to read first.
2. **The design**, section by section. Heading names are stable, because source comments link to them.

A document describes the code as it is. Plans for what is not built, such as missing features and optimizations known to pay off, are issues in the [backlog](https://github.com/aszecsei/cinnabar/issues), each with the condition under which it is worth doing.

Each layer's README also has an **Overview** of its packages and data flow, and a **References** section with the papers, specifications and reference implementations that its documents follow, such as [XeGTAO](https://github.com/GameTechDev/XeGTAO) for the ambient occlusion.

## Finding things

| If you want to… | Start at |
|---|---|
| Build and run anything | [Overview: Building and running](overview/building-and-running.md) |
| Know which package owns something | [Overview: Modules](overview/README.md#modules) and [Repository layout](overview/README.md#repository-layout) |
| Add a component, system or resource | [World: ECS](world/ecs.md) |
| Add a render pass | [GPU: Render graph](gpu/render-graph.md), then [Rendering: Frame](rendering/frame.md) for the hooks |
| Add a shading model or material | [Rendering: Materials](rendering/materials.md) and [Content: Materials](content/kinds/materials.md) |
| Add a renderer setting | [World: Volumes](world/volumes.md) and [Rendering: Frame](rendering/frame.md#settings) |
| Add water or terrain | [Rendering: Surfaces](rendering/surfaces.md) and [Materials: Vertex displacement](rendering/materials.md#vertex-displacement) |
| Write a behaviour | [Scripting: Behaviours](scripting/behaviours.md) and [Unity mapping](scripting/api.md#unity-mapping) |
| Expose a native type or function to scripts | [Scripting: API](scripting/api.md#the-entity-and-component-view) |
| Add an asset kind | [Content: Identity and cooking](content/identity-and-cooking.md) and [Blobs and loading](content/blobs-and-loading.md) |
| Add an editor panel or command | [Editor: Shell and panels](editor/shell-and-panels.md) |
| Write a physics backend | [Physics: Backends](physics/backends.md) |
| Play a sound, or write an audio backend | [Audio: Design](audio/design.md) and [Audio: Backends](audio/backends.md) |
| Add a message to the editor or cook link | [Editor: Editor link](editor/link.md) and [Content: Cook daemon](content/daemon-and-operations.md#cook-link) |
| Port to another platform or GPU API | [Core: Platform](core/platform.md#platform-and-backend-abstraction) and [GPU: Interface](gpu/interface.md#hardware-floor) |
| Understand a crash after a code reload | [Hot reload: Rules](overview/hot-reload.md#rules) |

## Conventions in these documents

- `lib/core` is "core" and `lib/engine` is "engine". "Host side" and "game side" are defined in [Overview: Modules](overview/README.md#modules).
- A name in code style, such as `Game_State` or `ecs.apply`, is a type or procedure in the source. Odin's `Snake_Case` types become `PascalCase` in the editor's C#.
- Numbers in parentheses after a constant are its current value, such as `MAX_LIGHTS` (1024). The constant is the truth; the number is a guide.
- The sample game, `samples/mygame`, is used as the example throughout. It is also the test bed for most features.
- Adding a document: put it in its layer's folder, add it to the layer README's Documents table, and run `just docs-check`. Renaming a heading that a source comment links to breaks that link, and the check reports it.
