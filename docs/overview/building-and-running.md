# Building and running

Everything goes through the [justfile](../../justfile). This document lists the recipes that matter and walks through the sample game's frame, which is the most concrete picture of how the parts fit.

Everything goes through the [justfile](../../justfile). The recipes that matter most:

| Recipe | What it does |
|---|---|
| `just setup` | Fetches the submodules, the D3D12 Agility SDK and DXC at the versions the justfile pins. |
| `just build` | Builds the host and the game DLL, writes the scripts' type definitions from the DLL, and cooks every kind of content into `build/cache/dev`. |
| `just dev` | `build`, then runs the game in the host's own window. |
| `just game-dll` | Builds only the DLL. A running host picks it up and hot-reloads it. |
| `just watch` | Runs the cook daemon, which cooks content as it changes. A running game swaps the new blobs in place. |
| `just edit` | Builds everything, including the editor, and opens the sample in it. The editor starts the host and the daemon itself. |
| `just release` | Cooks the `release` configuration and builds the statically linked `mygame.exe`. |
| `just test` | Runs every Odin package's tests, the script tests with direct field access on and off, and the editor's .NET tests. |
| `just check`, `vet`, `lint`, `fmt` | Type checks and lints every package, and formats the source. |
| `just script-types`, `link-schema`, `ltc-fit` | Regenerate derived files: the Luau definition file, the links' JSON schemas, and the area lights' tables. |

The justfile's variables are the single source of versions: the Agility SDK, DXC, the GPU backend collection, and the `LUAU_*` defines. A change there flows into the cache keys of the assets it affects, so the next cook rebuilds them.

## A frame in the sample

`samples/mygame/game.odin` is the best concrete walkthrough of how the parts fit. Its `update` does, in order:

1. Reads the project settings and asks `core` for the output mode they name, and switches scenes if a key asked for it.
2. Asks the editor package whether the world runs this frame (`editor.simulation`): yes without an editor, and in play mode; no in edit mode, where only transforms propagate so that edits show.
3. If the world runs: the fixed ticks that are due, the `Update` systems, the script phase, and the `Late` systems, exactly the phases of [Frame](architecture.md#frame).
4. Picks the view: the editor's camera while an editor is linked, else the scene's `Camera` entity.
5. Fills a `Frame_Desc` and calls `render.draw_frame`, adding its own passes through the renderer's hooks: culling on the compute queue, its own draws in the world pass, a HUD in the UI layer, and the editor's tools in the debug layer.
6. At the end of the frame, polls the asset runtime for blobs that the cooker rewrote and reloads the scripts among them.

`init` builds the world, the asset runtime, the script runtime, the renderer and the editor package in that order, and `on_reload` runs the same registration procedure as `init` so that every registration points at the new code.
