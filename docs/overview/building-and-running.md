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
| `just sdk` | `engine`, then writes the engine's package, `build/sdk/cinnabar-<version>/` and its zip (see [Releases of the engine](#releases-of-the-engine)). |
| `just engine-runtime` | Builds the standard game alone: `build/dev/standard.dll` and the release executable `build/runtime/runtime.exe`, which a project without Odin runs. |
| `just test` | Runs every Odin package's tests, the script tests with direct field access on and off, and the editor's .NET tests. It builds `null-host.exe` first, the host on the null GPU backend, on which the editor's host tests run without a GPU (see [Editor: Host tests](../editor/processes-and-projects.md#host-tests)). |
| `just check`, `vet`, `lint`, `fmt` | Type checks and lints every package, and formats the source. |
| `just script-types`, `link-schema`, `ltc-fit`, `stbn` | Regenerate derived files: the Luau definition file, the links' JSON schemas, the area lights' tables, and the blue noise of the ambient occlusion and the screen-space reflections. |
| `just screenshot`, `just gif` | With the editor open, write a screenshot or a GIF of its viewport, with a JSON sidecar, into `build/captures` and print the files; `just screenshot --view depth` adds a debug view (see [Editor: Capture](../editor/capture.md#automation)). |

The `VERSION` file is the engine's version. The justfile's variables are the single source of the other versions: the Agility SDK, DXC, the GPU backend collection, and the `LUAU_*` defines. A change there flows into the cache keys of the assets it affects, so the next cook rebuilds them.

## Build layout

Everything the justfile makes goes under `build/`, one folder per thing you run, and each folder holds what its executable needs beside it:

```
build/
├── dev/        host.exe, null-host.exe (for the editor's tests), <game>.dll or standard.dll (and the
│               <name>_<process>_<version>.dll copies the hosts load),
│               luau.dll, D3D12/ and the FSR libraries, content/        the development loose cache
├── release/    <game>.exe, D3D12/ and the FSR libraries, content/        the bundles, project.settings
├── runtime/    runtime.exe        the standard game's release executable
├── tools/      cook.exe, cinnabar.exe, viewer.exe, ltc_fit.exe, stbn.exe, editorctl.exe, flickerstat.exe
├── sdk/        cinnabar-<version>/ and cinnabar-<version>.zip        the engine's package (just sdk)
├── captures/   the editor's screenshots, GIFs and their sidecars
└── obj/        luau/, compressonator/, meshoptimizer/, clusterlod/, opus/, vorbis/, lz4/, recast/   the CMake builds the executables link
                pdb/, link/, script-types/, dotnet/, editor/autosave/, editor/automation.json,
                release-cache/<game>/   the game's release loose cache, which the package step packs into bundles
```

A game finds its files beside its executable, never through the working directory: `core.init` fills `Platform_API.content_dir` and `project_path` with `content` and `project.settings` in the executable's directory, as absolute paths, so `build/release` runs from Explorer or from any shell, and the folder can be copied or zipped as it is. The development host is the exception that takes `--content <dir>` and `--project <file>`, because the project's settings are in the source tree, where the editor edits them: `just dev` passes the sample's, and the editor passes its own (see [Editor](../editor/processes-and-projects.md#processes)). The cooker's `--cache` names a loose cache itself. `just build` cooks into `build/dev/content`, and `just release` cooks into `build/obj/release-cache/<game>`. `just release` then packs that cache into bundles in `build/release/content` (see [Content: Bundles](../content/blobs-and-loading.md#bundles)), so the release folder holds no loose blobs. The Agility SDK and FSR libraries are copied beside each executable that renders. `build/obj/luau` is where `lib/core/luau` links Luau from, so that path is fixed.

The host loads a copy of the game's DLL, `<name>_<process>_<version>.dll`, so that a build can overwrite the DLL while the host runs. The copies go beside the DLL, or in the folder that `--load-dir <dir>` names. `cinnabar.exe` and the editor give a project's `build/dev`, so the host writes nothing into the engine's folder, which can be read-only.

The player's data, such as records, options and key bindings, is in `Platform_API.save_dir`, which `core.init` creates (see [Scripting: Save](../scripting/api.md#save)). The development host puts it at `build/save` in the folder of the project's settings, which is `samples/mygame/build/save` for `just dev`, so a save stays out of the source tree. A release puts it at `%LOCALAPPDATA%\<game.name>`, beside the log (see [The game package: Releases](../world/game-package.md#releases)), so the install folder can stay read-only. `Render.save_quality` is the exception: in a release it writes `project.user.settings` beside the executable, which fails in a read-only install folder, such as `Program Files`, and returns false.

## Releases of the engine

`just sdk` builds the engine with `just engine`, and then writes the engine's package to `build/sdk/cinnabar-<version>/`, with `build/sdk/cinnabar-<version>.zip` beside it. The version is the one in `VERSION`. The package has the checkout's paths, so `cinnabar.exe` and the editor find its files in the same way (see [Getting started](getting-started.md#the-package)). The recipe copies each file by name:

- `build/dev`: `host.exe`, `standard.dll`, `luau.dll`, `physics_jolt.dll`, `D3D12/` and the FSR libraries.
- `build/runtime/runtime.exe`, and `build/tools`: `cook.exe` and `cinnabar.exe`.
- `build/editor`: the editor, published self-contained for `win-x64`, so it needs no .NET runtime. A checkout's editor is in `build/obj/dotnet/bin/Cinnabar.Editor/debug`. `cinnabar.exe` uses `build/editor/editor.exe` when it is there.
- `vendor/dxc/<version>`, and `vendor/smaa`: the shader and the tables that `lib/engine/render/spatial_aa.odin` loads.
- `lib/`: the files that git tracks, without the tests and their `testdata/`.
- `build/obj`: the Luau, Jolt, Opus and LZ4 libraries that the foreign imports in `lib/` link, at the paths that they name.
- `LICENSE`, `VERSION`, and in `licenses/`, the licences of the third-party parts that the package holds or that its programs link, with the editor's NuGet packages.

It does not copy the samples, the tests, the vendor sources, the CMake intermediates or the PDBs.

To publish a release, change `VERSION` on `main`. The [release workflow](../../.github/workflows/release.yml) then runs `just install` and `just sdk` on Windows, and publishes the zip as the GitHub release `v<version>`. If that release is already there, the workflow does nothing. A pull request that changes the workflow builds the package, but does not publish it. `just add-tag` tags `main` with the version by hand, and the workflow uses that tag.

## A frame in the sample

The standard game's frame is in [The game package](../world/game-package.md#the-frame). `samples/mygame/game/game.odin` adds the sample's own work through its hooks: before the world steps, F7 switches the scene and F8 the output mode; after it steps, the window's title reports the frame, a texture streams in and the axes of the spinning entities are drawn; and in the frame, the render hooks add its own draws in the world pass, its ray-traced shadows and its post pass. `samples/intel` has no Odin, and the standard game runs it as it is.

