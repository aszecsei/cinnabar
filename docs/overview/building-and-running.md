# Building and running

Everything goes through the [justfile](../../justfile). This document lists the recipes that matter and the layout of what they build. The recipes build one game at a time, `samples/mygame` unless `game=` names another, as in `just game=intel dev`. The standard game's frame, which is the most concrete picture of how the parts fit, is in [The game package](../world/game-package.md#the-frame).

The recipes that matter most:

| Recipe | What it does |
|---|---|
| `just install` (or `just setup`) | Fetches the submodules, the D3D12 Agility SDK, DXC, FSR and Compressonator at the versions the justfile pins. |
| `just build` | Builds the host and the game's DLL, writes the scripts' type definitions from the DLL, and cooks every kind of content into `build/dev/content`. |
| `just dev` | `build`, then runs the game in the host's own window, with the sample's `project.settings`. |
| `just game-dll` | Builds only the game's DLL: `<game>.dll` from the project's `game/` folder, or the standard game's `standard.dll` for a project without one (see [The game package](../world/game-package.md#development)). A running host picks it up and hot-reloads it. |
| `just watch` | Runs the cook daemon, which cooks content as it changes. A running game swaps the new blobs in place. |
| `just edit` | Builds everything, including the editor, and opens the sample in it. The editor starts the host and the daemon itself. |
| `just release` | Cooks the `release` configuration and builds the statically linked `<game>.exe` into `build/release`, with its content and settings beside it. The executable has no console and logs to a file (see [The game package](../world/game-package.md#releases)). |
| `just engine` | Builds everything that a project outside the repository builds and runs with: the host, the cooker, the standard game, the editor and `cinnabar.exe` (see [Getting started](getting-started.md#the-engine)). |
| `just engine-runtime` | Builds the standard game alone: `build/dev/standard.dll` and the release executable `build/runtime/runtime.exe`, which a project without Odin runs. |
| `just test` | Runs every Odin package's tests, the script tests with direct field access on and off, and the editor's .NET tests. |
| `just check`, `vet`, `lint`, `fmt` | Type checks and lints every package, and formats the source. |
| `just script-types`, `link-schema`, `ltc-fit`, `stbn` | Regenerate derived files: the Luau definition file, the links' JSON schemas, the area lights' tables, and the blue noise of the ambient occlusion and the screen-space reflections. |
| `just screenshot`, `just gif` | With the editor open, write a screenshot or a GIF of its viewport, with a JSON sidecar, into `build/captures` and print the files; `just screenshot --view depth` adds a debug view (see [Editor: Capture](../editor/capture.md#automation)). |

The justfile's variables are the single source of versions: the Agility SDK, DXC, the GPU backend collection, and the `LUAU_*` defines. A change there flows into the cache keys of the assets it affects, so the next cook rebuilds them.

## Build layout

Everything the justfile makes goes under `build/`, one folder per thing you run, and each folder holds what its executable needs beside it:

```
build/
├── dev/        host.exe, <game>.dll or standard.dll (and the <name>_<process>_<version>.dll copies the hosts load),
│               luau.dll, D3D12/ and the FSR libraries, content/        the development loose cache
├── release/    <game>.exe, D3D12/ and the FSR libraries, content/        the bundles, project.settings
├── runtime/    runtime.exe        the standard game's release executable
├── tools/      cook.exe, cinnabar.exe, viewer.exe, ltc_fit.exe, stbn.exe, editorctl.exe, flickerstat.exe
├── captures/   the editor's screenshots, GIFs and their sidecars
└── obj/        luau/, compressonator/, meshoptimizer/, clusterlod/, opus/, vorbis/, lz4/   the CMake builds the executables link
                pdb/, link/, script-types/, dotnet/, editor/autosave/, editor/automation.json,
                release-cache/<game>/   the game's release loose cache, which the package step packs into bundles
```

A game finds its files beside its executable, never through the working directory: `core.init` fills `Platform_API.content_dir` and `project_path` with `content` and `project.settings` in the executable's directory, as absolute paths, so `build/release` runs from Explorer or from any shell, and the folder can be copied or zipped as it is. The development host is the exception that takes `--content <dir>` and `--project <file>`, because the project's settings are in the source tree, where the editor edits them: `just dev` passes the sample's, and the editor passes its own (see [Editor](../editor/processes-and-projects.md#processes)). The cooker's `--cache` names a loose cache itself. `just build` cooks into `build/dev/content`, and `just release` cooks into `build/obj/release-cache/<game>`. `just release` then packs that cache into bundles in `build/release/content` (see [Content: Bundles](../content/blobs-and-loading.md#bundles)), so the release folder holds no loose blobs. The Agility SDK and FSR libraries are copied beside each executable that renders. `build/obj/luau` is where `lib/core/luau` links Luau from, so that path is fixed.

## A frame in the sample

The standard game's frame is in [The game package](../world/game-package.md#the-frame). `samples/mygame/game/game.odin` adds the sample's own work through its hooks: before the world steps, F7 switches the scene and F8 the output mode; after it steps, the window's title reports the frame, a texture streams in and the axes of the spinning entities are drawn; and in the frame, the render hooks add its own draws in the world pass, its ray-traced shadows and its post pass. `samples/intel` has no Odin, and the standard game runs it as it is.

