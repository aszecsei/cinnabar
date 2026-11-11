# Getting started

How to make a game with cinnabar, in a folder of its own, without changing the engine. The engine is a checkout that you build once. A game is a **project**: settings, content and, if it needs it, Odin. `cinnabar.exe` builds, runs, edits and exports a project with the engine, and the editor runs it for New Project and Export.

**In this document:** [Prerequisites](#prerequisites) · [The engine](#the-engine) · [A new project](#a-new-project) · [A project](#a-project) · [The loop](#the-loop) · [Odin in a project](#odin-in-a-project) · [Releases](#releases)

## Prerequisites

| What | Why |
|---|---|
| Windows 10 or 11 with a D3D12 GPU | The only platform and GPU backend. |
| [Odin](https://odin-lang.org), the `dev-2026-10` nightly or later, on the `PATH` | Builds the engine, and a project's `game/` folder. A project without Odin does not need it after the engine is built. |
| The .NET 10 SDK | Builds the editor. |
| Visual Studio 2022's C++ build tools and CMake | Build Luau, Jolt and the cooker's libraries. |
| Git, and Git for Windows' Bash at `C:/Program Files/Git/bin/bash.exe` | The justfile's recipes run in it, and `just install` uses its `curl` and `unzip`. |
| [just](https://github.com/casey/just) | Builds the engine. A project does not need it. |

## The engine

Clone the engine and build it once:

```sh
just install    # the submodules, the D3D12 Agility SDK, DXC, FSR and Compressonator, at the versions the justfile pins
just engine     # the host, the cooker, the standard game, the editor and cinnabar.exe
```

`just engine` writes `build/tools/cinnabar.exe`. Put `build/tools` on your `PATH`, or call the executable by its path. `cinnabar.exe` finds the engine in this order:

1. `--engine <dir>` on its command line.
2. The `CINNABAR_ROOT` variable.
3. `engine.path` in the project's `project.user.settings`, which is not committed, because it is a path on one machine.
4. The checkout that it was built in, two folders up from `build/tools`.

After a `git pull` of the engine, run `just engine` again. A project's next build cooks what the new engine changed.

## A new project

```sh
cinnabar new my_game                       # a project from the basic template
cinnabar new my_game --template odin       # the same, with a game/ folder of Odin hooks
cinnabar new my_game --name "My Game"      # a name other than the folder's
```

Or, in the editor: start it with no project, and choose **New Project** (see [Editor: Projects](../editor/processes-and-projects.md#projects)).

`new` makes the folder, which must be new or empty, from `lib/engine/templates`. Each content file gets a `.meta` file with a new GUID, so two projects never share a GUID. Commit everything that `new` writes. The basic template gives:

| File | What it is |
|---|---|
| `project.settings` | The name, the main scene's GUID, the icon and the output mode (see [Project settings](architecture.md#project-settings)). |
| `content/scenes/main.scene` | A camera, a sun, an atmosphere sky, a floor and a cube. |
| `content/scripts/spinner.luau` | A behaviour that turns the cube (see [Scripting: Behaviours](../scripting/behaviours.md)). |
| `content/.luaurc` | Strict mode for the scripts, and the `game` alias for `require`. |
| `icon.ico` | The release executable's icon. |
| `.gitignore` | Leaves out `build/` and `*.user.settings`. |

## A project

A project is a folder with `project.settings` and `content/`. It needs nothing else, and it can be anywhere. `cinnabar.exe` writes everything that it builds under the project's `build/`:

| Path | What it is |
|---|---|
| `build/cache/` | The development loose cache, which the host and the editor read. |
| `build/types/cinnabar.d.luau` | The scripts' type definitions, which the cooker checks the scripts against and luau-lsp reads (see [Scripting](../scripting/tooling-and-hot-reload.md#types-and-tooling)). |
| `build/dev/game.dll` | The project's own game DLL, when it has a `game/` folder. Without one, the host runs the engine's `standard.dll`. |
| `build/release-cache/`, `build/release/` | The release loose cache, and the release. |

The engine's samples are projects too: `samples/intel` has no Odin, and `samples/mygame` has its hooks in `game/`. The justfile builds them for engine work (see [Building and running](building-and-running.md)), and `cinnabar.exe` builds them as it builds any project.

## The loop

| Command | What it does |
|---|---|
| `cinnabar edit [<project>]` | Builds the project and opens it in the editor, which runs the game and the cook daemon. Edit scenes, play with F5, and open the game in its own window with Run Game. |
| `cinnabar run [<project>]` | Builds the project and runs it in the development host's window. |
| `cinnabar build [<project>]` | Builds the game DLL if the project has Odin, writes the scripts' types, and cooks the content. |
| `cinnabar export [<project>] [--out <dir>]` | Writes a release (see [Releases](#releases)). |

The project is the current folder unless the command names one. Content and scripts reload while the game runs: the editor's cook daemon cooks what changes, and the game takes the new blobs (see [Hot reload](hot-reload.md)).

## Odin in a project

A project needs Odin only for what scripts cannot do: components of its own, systems that run over many entities, script bindings, render passes. Its Odin is one package in `game/`, which gives the standard game its hooks (see [The game package](../world/game-package.md#hooks)). `cinnabar new --template odin` writes one with a component, its system and its binding. `cinnabar build` builds it into `build/dev/game.dll` against the engine's `lib/`, and a running host reloads it.

## Releases

`cinnabar export` writes `build/release`, or the folder that `--out` names:

1. It cooks every kind into `build/release-cache`, and deletes the blobs of assets that are no longer in the content.
2. It packs the cache into bundles in `content/` (see [Content: Bundles](../content/blobs-and-loading.md#bundles)).
3. It copies `project.settings`, but not the user's file, and the runtime libraries: `D3D12/D3D12Core.dll` and FSR's.
4. It writes `<game.name>.exe`: the engine's `runtime.exe` for a project without Odin, or the runtime entry point built with the project's `game/`.
5. It writes `game.icon` into the executable.

The folder runs anywhere as it is. Zip it, or give it to an installer. The game logs to `%LOCALAPPDATA%\<game.name>\log.txt`, because it has no console.
