# Editor

The Avalonia editor and the game-side package it drives through the editor link.

## Documents

Read them in this order the first time.

| Document | What it covers |
|---|---|
| [Processes and projects](processes-and-projects.md) | Processes, the UI framework, the C# projects and crash recovery. |
| [Document and scenes](document-and-scenes.md) | The document model, modes, and the scene format. |
| [Editor link](link.md) | The editor link and the game side that mirrors the world. |
| [Viewport](viewport.md) | Frames, the camera, picking, selection, gizmos and viewport settings. |
| [Shell and panels](shell-and-panels.md) | Docking, the ribbon, commands and every panel. |
| [Material editor](material-editor.md) | The node editor and its previews. |

## Overview

The editor has two halves. The C# application owns the user's state: the scene document, the selection, the camera, the panels and the settings. The game side, `lib/engine/editor`, owns nothing persistent: it answers the editor's messages with what the game knows, applies the editor's operations to the world, and draws the viewport's tools. Three flows connect them:

```mermaid
flowchart LR
    DOC["Scene document<br/>(Cinnabar.Editor.Document)"]
    LINK["editor link<br/>(TCP, lib/engine/wire)"]
    GAME["lib/engine/editor<br/>in the game DLL"]
    WORLD["ecs.World"]
    MIRROR["WorldModel<br/>(Cinnabar.Editor.Model)"]
    VIEW["Viewport<br/>(D3D11 copy)"]
    TEX["shared textures + fence<br/>(core, D3D12)"]

    DOC -->|"Load_Scene, Apply_Operations"| LINK --> GAME --> WORLD
    WORLD -->|"Entity_Delta, Entity_Values"| GAME --> LINK --> MIRROR
    WORLD -->|"draw_frame"| TEX --> VIEW
```

1. **Edits go down.** Every change is an operation on the document, which the editor applies at once and sends to the game. The game applies it to its world and reports what it could not apply. The document is never changed to match the host ([Document model](document-and-scenes.md#document-model)).
2. **The world comes up.** The game scans its world and sends deltas of the entity list, and the values of the entities the editor watches. The editor's mirror changes only from these messages ([World](link.md#world)).
3. **Frames come across.** The host renders into shared textures, and the viewport copies each finished frame into Avalonia's compositor ([Viewport](viewport.md#viewport)).

The game side is small and lives in `lib/engine/editor`:

| File | What it holds |
|---|---|
| `editor.odin` | `Editor` in `Game_State`, `poll`: the connection, the entity deltas, the watches, `Load_Scene` |
| `types.odin` | `component_types`: every registered component with the fields that scenes can set |
| `edit.odin` | `apply_operations`: the editor's edits applied to the world, with problems for what cannot be |
| `modes.odin` | Edit, Play and Paused: `simulation` tells the game's frame what to run |
| `viewport.odin` | The camera, the selection, hidden entities, the ID buffer's pick pass, the outline and the gizmo |
| `helpers.odin`, `icons.odin` | The shapes of lights, volumes and cameras as debug lines, and their clickable icons |
| `commands.odin` | Game commands: registered by the game, shown in the ribbon, run through `poll` |
| `preview.odin` | Material previews for the material editor (see [Rendering](../rendering/materials.md#material-previews)) |
| `link/link.odin` | The editor link's messages, shared with the host |

Everything in the game's `Editor` is a handle, an ID or a copy, so a code reload keeps it; the commands are registrations, made again in `on_reload` ([Game commands](shell-and-panels.md#game-commands)).

## Deferred

The three designs that the editor's model makes room for but does not contain. Each is in [Future work](#future-work) with the rest.

- **Large worlds:** positions reach ±2^38 m, and one scene file per world does not scale. Level and world streaming will split the world into scenes that load separately, and the editor will then edit several scenes at once.
- **Edit-mode scripts:** some tools need behaviours that run in edit mode, like Unity's `ExecuteInEditMode`. Edit mode runs no scripts until then.
- **More than one viewport:** each viewport has its own shared target and camera, so the host renders the scene once for each viewport.

## Future work

- **Edit-mode scripts.** Tools such as a procedural placer need behaviours that run in edit mode, like Unity's `ExecuteInEditMode`. The script runtime is quiet in Edit, so this needs a per-class opt-in, a script phase that runs only those classes, and a rule that their writes become operations on the document rather than raw world changes, as game commands' do (see [Game commands](shell-and-panels.md#game-commands)).
- **Change tracking for entity deltas.** The game scans every entity ten times a second to find what changed, which suits tens of thousands of entities. Per-chunk change versions in the ECS ([World](../world/README.md#future-work)) would let `poll` visit only the chunks that changed since its last delta. Do this when the scan shows in `Host_Stats`.
- **A remote host.** The editor link is TCP so that the same protocol can drive a host on another machine or a console. Over a network the viewport cannot read a shared texture, so the host would encode and send frames over the link, and `Frame_Acknowledged` already paces them. The editor's child-process management would become a launcher on the target.
- **More than one viewport.** Each viewport needs its own shared target, its own `Editor_Camera` and its own pick and outline passes, and the host renders the scene once for each. The shared-target code already supports named generations beside the frame target (previews use them, see [GPU](../gpu/presentation.md#presentation)).

## References

- Avalonia, [avaloniaui.net](https://avaloniaui.net) and the [composition GPU interop API](https://docs.avaloniaui.net/docs/guides/graphics-and-animation/graphics-and-animations) (`ICompositionGpuInterop`): the compositor that [Viewport](viewport.md#viewport) imports its D3D11 textures into.
- Wiesław Šoltés, [Dock](https://github.com/wieslawsoltes/Dock): the docking library behind [Shell](shell-and-panels.md#shell).
- Microsoft, [Fluent UI System Icons](https://github.com/microsoft/fluentui-system-icons): the icon set, embedded as path data.
- Microsoft, [Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects): how [Processes](processes-and-projects.md#processes) ties the host's and the daemon's lifetimes to the editor's.
- Microsoft, [Shared Surfaces (Direct3D 11)](https://learn.microsoft.com/en-us/windows/win32/direct3darticles/surface-sharing-between-windows-graphics-apis) and [`IDXGIKeyedMutex`](https://learn.microsoft.com/en-us/windows/win32/api/dxgi/nn-dxgi-idxgikeyedmutex): the keyed-mutex import and the typed-format rule that [Viewport](viewport.md#viewport) works within.
- Microsoft, [Ribbon design guidelines](https://learn.microsoft.com/en-us/windows/win32/uxguide/cmd-ribbons): the tabs, groups, item kinds, contextual tabs and collapse behaviour that [Ribbon](shell-and-panels.md#ribbon) follows.
- Unity, [Scene view navigation](https://docs.unity3d.com/Manual/SceneViewNavigation.html), and Epic, [Viewport controls](https://dev.epicgames.com/documentation/en-us/unreal-engine/viewport-controls-in-unreal-engine): the fly and orbit scheme that the editor camera takes.
- Unity, [`ExecuteInEditMode`](https://docs.unity3d.com/ScriptReference/ExecuteInEditMode.html) and [Prefabs](https://docs.unity3d.com/Manual/Prefabs.html): the behaviours that [Future work](#future-work) refers to.
