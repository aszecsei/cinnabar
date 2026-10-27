# Building and running

Everything goes through the [justfile](../../justfile). This document lists the recipes that matter and walks through the sample game's frame, which is the most concrete picture of how the parts fit.

Everything goes through the [justfile](../../justfile). The recipes that matter most:

| Recipe | What it does |
|---|---|
| `just setup` | Fetches the submodules, the D3D12 Agility SDK and DXC at the versions the justfile pins. |
| `just build` | Builds the host and the game DLL, writes the scripts' type definitions from the DLL, and cooks every kind of content into `build/dev/content`. |
| `just dev` | `build`, then runs the game in the host's own window, with the sample's `project.settings`. |
| `just game-dll` | Builds only the DLL. A running host picks it up and hot-reloads it. |
| `just watch` | Runs the cook daemon, which cooks content as it changes. A running game swaps the new blobs in place. |
| `just edit` | Builds everything, including the editor, and opens the sample in it. The editor starts the host and the daemon itself. |
| `just release` | Cooks the `release` configuration and builds the statically linked `mygame.exe` into `build/release`, with its content and settings beside it. |
| `just test` | Runs every Odin package's tests, the script tests with direct field access on and off, and the editor's .NET tests. |
| `just check`, `vet`, `lint`, `fmt` | Type checks and lints every package, and formats the source. |
| `just script-types`, `link-schema`, `ltc-fit` | Regenerate derived files: the Luau definition file, the links' JSON schemas, and the area lights' tables. |
| `just screenshot`, `just gif` | With the editor open, write a screenshot or a GIF of its viewport, with a JSON sidecar, into `build/captures` and print the files; `just screenshot --view depth` adds a debug view (see [Editor: Capture](../editor/capture.md#automation)). |

The justfile's variables are the single source of versions: the Agility SDK, DXC, the GPU backend collection, and the `LUAU_*` defines. A change there flows into the cache keys of the assets it affects, so the next cook rebuilds them.

## Build layout

Everything the justfile makes goes under `build/`, one folder per thing you run, and each folder holds what its executable needs beside it:

```
build/
├── dev/        host.exe, mygame.dll (and the mygame_N.dll copies the host loads), luau.dll,
│               D3D12/ and the FSR libraries, content/        the development loose cache
├── release/    mygame.exe, D3D12/ and the FSR libraries, content/, project.settings
├── tools/      cook.exe, viewer.exe, ltc_fit.exe, editorctl.exe
├── captures/   the editor's screenshots, GIFs and their sidecars
└── obj/        luau/, compressonator/, meshoptimizer/, clusterlod/   the CMake builds the executables link
                pdb/, link/, script-types/, dotnet/, editor/autosave/, editor/automation.json
```

A game finds its files beside its executable, never through the working directory: `core.init` fills `Platform_API.content_dir` and `project_path` with `content` and `project.settings` in the executable's directory, as absolute paths, so `build/release` runs from Explorer or from any shell, and the folder can be copied or zipped as it is. The development host is the exception that takes `--content <dir>` and `--project <file>`, because the project's settings are in the source tree, where the editor edits them: `just dev` passes the sample's, and the editor passes its own (see [Editor](../editor/processes-and-projects.md#processes)). The cooker's `--cache` names a loose cache itself, so `just build` cooks into `build/dev/content` and `just release` into `build/release/content`, and the Agility SDK and FSR libraries are copied beside each executable that renders. `build/obj/luau` is where `lib/core/luau` links Luau from, so that path is fixed.

## A frame in the sample

`samples/mygame/game.odin` is the best concrete walkthrough of how the parts fit. Its `update` does, in order:

1. Reads the project settings and asks `core` for the output mode they name, and switches scenes if a key asked for it.
2. Asks the editor package whether the world runs this frame (`editor.simulation`): yes without an editor, and in play mode; no in edit mode, where only transforms propagate so that edits show.
3. If the world runs: the fixed ticks that are due, the `Update` systems, the script phase, and the `Late` systems, exactly the phases of [Frame](architecture.md#frame).
4. Picks the view: the editor's camera while an editor is linked, else the scene's `Camera` entity.
5. Fills a `Frame_Desc` and calls `render.draw_frame`, adding its own passes through the renderer's hooks: culling on the compute queue, its own draws in the world pass, a HUD in the UI layer, and the editor's tools in the debug layer.
6. At the end of the frame, polls the asset runtime for blobs that the cooker rewrote and reloads the scripts among them.

`init` builds the world, the asset runtime, the script runtime, the renderer and the editor package in that order, and `on_reload` runs the same registration procedure as `init` so that every registration points at the new code.
