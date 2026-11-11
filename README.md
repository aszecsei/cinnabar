# cinnabar

> a fiber-based game engine in Odin

cinnabar is a game engine written in [Odin](https://odin-lang.org), with:

- a **fiber-based job system** and a native **archetype ECS** with fixed-point world positions;
- a **hot-reloaded game DLL** in development, and one statically linked executable in release;
- a **bindless, render-graph-driven GPU layer** over D3D12, with mesh shaders and ray tracing where the hardware has them;
- a **clustered forward renderer** with node-graph materials, GTAO, screen-space radiance cascades, reflection probes with stochastic screen-space or ray-traced reflections, volumetric fog, temporal AA and HDR output;
- **sandboxed Luau scripting** with a Unity-style behaviour API that survives code reload;
- an **asset cooker** and cook daemon with GUID identity and hot reload of every asset kind;
- a **C# editor** built with Avalonia, which drives the game through a message link.

## Getting started

cinnabar runs on Windows with D3D12. You need Odin, the .NET 10 SDK, CMake with Visual Studio 2022's build tools, Git with its Bash, and [just](https://github.com/casey/just) (see [Getting started](docs/overview/getting-started.md#prerequisites)).

To make a game with the engine, build the engine once, then make a project anywhere:

```sh
just install                  # fetch the submodules, the D3D12 Agility SDK, DXC, FSR and Compressonator
just engine                   # build the host, the cooker, the standard game, the editor and build/tools/cinnabar.exe
cinnabar new ../my_game       # a project of your own, from a template
cinnabar edit ../my_game      # build it and open it in the editor; `cinnabar export` writes a release
```

[Getting started](docs/overview/getting-started.md) walks through it. To work on the engine itself, with the samples:

```sh
just dev        # build everything, cook the sample's content, and run it in the development host
just edit       # build everything and open the sample in the editor (just game=intel edit for the other)
just test       # run the engine's, the cooker's and the editor's tests
```

`just` with no arguments lists every recipe. The development host hot-reloads the game DLL whenever `just game-dll` builds it, and `just watch` runs the cook daemon so that changed content reloads too.

## Documentation

The documentation starts at [docs/README.md](docs/README.md), which gives a reading order from the engine as a whole down to each part. Each layer is a folder with a README that is its overview, and source comments link to sections as `docs/<layer>/<document>.md#<section>`.

| Layer | Scope |
|---|---|
| [Overview](docs/overview/README.md) | Architecture, hot reload, building and running, conventions |
| [Core](docs/core/README.md) | The platform layer: the frame, jobs, memory, input |
| [World](docs/world/README.md) | The ECS, positions and transforms, fixed ticks, render extraction, volumes |
| [GPU](docs/gpu/README.md) | The backend-agnostic GPU interface and the render graph |
| [Rendering](docs/rendering/README.md) | The built-in renderer |
| [Scripting](docs/scripting/README.md) | Luau embedding, the script API, behaviours and tooling |
| [Physics](docs/physics/README.md) | Physics on Jolt: rigid bodies, joints, queries and events behind a backend boundary |
| [Audio](docs/audio/README.md) | The mixer, spatial sound, occlusion, streaming and the script binding behind a backend boundary |
| [Content pipeline](docs/content/README.md) | The cooker, each asset kind, the cook daemon, blobs and loading |
| [Editor](docs/editor/README.md) | The Avalonia editor and the editor link |

## Layout

| Path | Contents |
|---|---|
| `lib/core` | The platform layer, which the host owns: window, input, jobs, memory, the GPU backend, the script VM's host side |
| `lib/engine` | Everything that is hot-reloaded: the ECS, the renderer, assets, scripting, scenes, the editor's game side |
| `src/host` | The development host, which loads and reloads the game DLL |
| `src/editor` | The C# editor |
| `tools/cook` | The asset cooker and cook daemon |
| `tools/cinnabar` | `cinnabar.exe`, which makes, builds, runs, edits and exports a project outside the repository |
| `lib/engine/templates` | The templates that new projects start from |
| `tools/viewer`, `tools/ltc_fit` | A viewer for a host's shared frames, and the area lights' table fitter |
| `lib/engine/game` | The standard game, which a project without Odin runs, and the hooks that a project's Odin adds to it |
| `samples/mygame` | The sample game, which exercises most features, with its own Odin in `game/` |
| `samples/intel` | Intel's USD scenes, with no Odin: the standard game runs it (see its README) |
| `vendor/` | Luau, Jolt Physics, Compressonator, meshoptimizer, Opus, libvorbis, libogg, the Agility SDK and DXC |

## License

See [LICENSE](LICENSE).
