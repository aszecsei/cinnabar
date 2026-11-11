# The game package

`lib/engine/game` is the standard game: the world, the renderer, the assets, the scripts, physics, audio, animation, sprites, the UI and the editor's link, started, stepped, reloaded and drawn in the engine's order. A project without Odin runs it as it is. A project with Odin adds to it through `Hooks`, and does not write the frame itself.

**In this document:** [Projects](#projects) · [The frame](#the-frame) · [Hooks](#hooks) · [The project's state](#the-projects-state) · [Settings](#settings) · [Development](#development) · [Releases](#releases)

## Projects

A project is a folder with a `project.settings` file and a `content/` folder. A project that adds Odin has a `game/` folder too, with one Odin package.

| Project | Its game package | What runs it in development | What runs it in a release |
|---|---|---|---|
| No `game/` folder, such as `samples/intel` | The standard game's, `lib/engine/game/standard/game` | `standard.dll` | `runtime.exe` under the game's name |
| A `game/` folder, such as `samples/mygame` | `game/`, which exports `game.api(its hooks)` | `<game>.dll`, built from `game/` | `lib/engine/game/runtime`, built with `game/` |

A project's scripts reach every engine binding in both cases: the standard game registers all of them, and all the engine's components. Before this package, each game's Odin chose its bindings, and a game that left out the audio's had no `Audio` in Luau.

## The frame

`game_update` in `lifecycle.odin` does, in order:

1. Reads the project's settings again if their files changed, and gives them to the renderer, physics, audio and the UI. Then `Hooks.begin_frame`.
2. Asks the editor package whether the world runs this frame (`editor.simulation`): yes without an editor, and in play mode; no in edit mode, where only transforms propagate so that edits show. While the game is paused (`Game.paused`, which `Game.set_paused` sets from a script), the world takes no time, but the script phase still runs.
3. Matches the UI's documents to the world's `Ui_Document`s, and if the world runs: the fixed ticks that are due, the `Update` systems, the UI's input and its events (see [UI: Input and focus](../ui/design.md#input-and-focus)), the script phase, and the `Late` systems, exactly the phases of [Frame](../overview/architecture.md#frame).
4. Picks the camera, the scene's `Camera` entity, whether or not an editor is linked. Plays the world's sounds, or the test tone (see [Core: Test tone](../core/audio.md#test-tone)). Then `Hooks.update`.
5. Fills one `Frame_Desc` with that camera, the window's size, the time that the particles step and the skinned poses, and the UI's documents in the UI layer. `Hooks.frame` adds the project's render hooks. It calls `editor.draw_frame`, which is `render.draw_frame` without an editor. With one, the editor package draws that frame in the views that the editor has open (see [Rendering: Views](../rendering/frame.md#views)). The hooks run once for each view and keep their data for it in `Frame.user`, so the game never knows how many views there are.
6. At the end of the frame, polls the asset runtime for blobs that the cooker rewrote and reloads the scripts among them.

`game_init` builds the editor package, the world, physics, audio, the asset runtime, the renderer, the UI and the script runtime in that order, reads the settings, and loads the main scene. `game_reload` makes the same registrations again, so that each points at the new code.

## Hooks

A project gives its hooks from a procedure, and exports the standard game's `Game_API` made with it:

```odin
hooks :: proc() -> game.Hooks {
	return {State = State, register_components = register_components, update = update}
}

@(export)
cinnabar_game_api :: proc() -> core.Game_API {
	return game.api(hooks)
}
```

`api` takes the procedure as a constant (`$hooks`), so each procedure of the `Game_API` that it makes calls `hooks()` when it runs. Nothing of the hooks is kept in the state: a reload loads a new DLL, whose `Game_API` calls its own `hooks`. This follows the [hot reload rules](../overview/hot-reload.md#rules): no procedure pointers or `typeid`s in persistent state, and no mutable globals. Every field may be left out.

| Hook | When it runs | What a project does in it |
|---|---|---|
| `State` | — | The project's state type (see [The project's state](#the-projects-state)). |
| `physics_anchor` | `init` | The physics world's anchor, for a world far from the origin (see [Physics](../physics/design.md#positions-and-precision)). |
| `register_components` | `init`, `on_reload`, `layout_hash`, `script_types` | Registers its components, after the engine's. |
| `register_world` | `init`, `on_reload` | Registers its systems, queries and extractors. |
| `register_scripts` | `init`, `on_reload`, `script_types` | Exposes its components and defines its bindings, after the engine's. It runs for `script_types` without a `Game`, so a binding finds its `Game` with `game.game_of` only when a script calls it. |
| `register` | `init`, `on_reload` | Registers what needs the renderer and the editor: post effects and editor commands. |
| `init`, `shutdown` | The end of `init`, before the main scene loads; the start of `shutdown` | Makes and destroys its own resources. |
| `on_reload` | The end of `on_reload` | Updates what the new code describes differently, such as pipelines. |
| `settings_changed` | When the settings' files changed | Applies its own reading of the settings. |
| `begin_frame` | Each frame, before the world steps | Reads keys that change the world, such as a scene switch. |
| `update` | Each frame, after the world stepped and before it is drawn | Its own work: debug drawing, pipelines, streaming. |
| `frame` | Each frame, before the frame is drawn | Sets the render hooks in `Frame_Desc.hooks`, other than `data` and `ui`. |
| `tone_pan` | Each frame, with `CINNABAR_TEST_TONE` | The test tone's pan. |

Systems, editor commands and render hooks get the `Game` as their user data (`System_Context`'s, `Command_Context.user`, `Frame.data`).

## The project's state

The host allocates one block for `Game` and the project's `State`. `State` begins at `USER_OFFSET`, after `Game`, at the 64-byte alignment that the host gives the block, and `game.user(g, State)` gives it. The whole block is zero when `init` runs. `layout_hash` covers `Game`, `State` and every component's layout, so a change of any of them is a soft restart (see [Hot reload](../overview/hot-reload.md#reload-sequence)).

## Settings

The standard game reads these keys of `project.settings` (see [Project settings](../overview/architecture.md#project-settings)):

| Key | What it sets |
|---|---|
| `game.main_scene` | The scene that the game loads when it starts, by GUID. An editor replaces it with its own document when it links. |
| `game.name` | The window's title and the executable's name in a release. The game only knows the key. |
| `game.icon` | The release executable's icon, a `.ico` file relative to the settings file. The game only knows the key. |
| `engine.path` | The engine checkout that builds the project, in `project.user.settings` only, because it is a path on one machine. The game only knows the key. |

## Development

`just game-dll` builds `<game>/game` into `build/dev/<game>.dll` when the project has a `game/` folder, and the standard game into `build/dev/standard.dll` when it does not. `just dev`, `just edit` and `just script-types` run that DLL. `just engine-runtime` builds `standard.dll` and `runtime.exe` without a project.

The host copies the DLL that it loads to `<name>_<process>_<version>.dll` beside it, so two hosts can run one DLL, as the editor's host and its Run Game do. A host that starts removes the copies that earlier hosts left, and Windows keeps those that a running host has loaded.

## Releases

`lib/engine/game/runtime` is the one release entry point. It imports the project's game package as `project:game`, so the build names the project with the `project` collection: `-collection:project=samples/mygame` links `samples/mygame/game`, and `-collection:project=lib/engine/game/standard` links the standard game. `just release` picks the one that the project has.

The executable is a Windows application (`-subsystem:windows`), with no console. It takes its window's title from `game.name` in the `project.settings` beside it, and logs to `%LOCALAPPDATA%\<game.name>\log.txt`. The release folder has `D3D12Core.dll` and not the debug layer's library, because a release build has no debug layer.
