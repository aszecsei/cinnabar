# {{name}}

A game made with cinnabar (see the engine's docs/overview/getting-started.md).

| Command | What it does |
|---|---|
| `cinnabar edit` | Builds the game and opens it in the editor. |
| `cinnabar run` | Builds the game and runs it in its own window. |
| `cinnabar build` | Builds the game and cooks its content into `build/cache`. |
| `cinnabar export` | Writes a release into `build/release`: `{{name}}.exe`, its content's bundles and its settings. Copy or zip the folder as it is. |

| Path | What it is |
|---|---|
| `project.settings` | The game's settings: its name, its main scene, its icon, its output and its quality. |
| `icon.ico` | The icon of the release's executable and window. |
| `content/` | Scenes, scripts, models, textures, sounds and the rest, each with a `.meta` file that gives it a GUID. Commit the `.meta` files. |
| `game/` | The game's own Odin, if it has any: hooks that add components, systems and script bindings to the standard game. |
| `build/` | What cinnabar builds. It is not committed. |
