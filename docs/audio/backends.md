# Audio backends

How an audio backend plugs into cinnabar, and what it must do: the library it is, how the host chooses and loads it, the contract of `Audio_API` and `Host`, and the conformance suite that every backend passes. The mixer, `lib/core/audio/mixer`, is the reference, and the null backend, `lib/core/audio/null`, is the smallest one. The boundary has the shape of [Physics: Backends](../physics/backends.md).

**In this document:** [Loading](#loading) · [Choosing](#choosing) · [The contract](#the-contract) · [Features](#features) · [The null backend](#the-null-backend) · [Writing a backend](#writing-a-backend) · [Conformance](#conformance)

## Loading

- **The mixer and the null backend are built in.** They are Odin, and the host links them, in development and in release alike. Unlike physics, no collection chooses between them.
- **Any other backend is a library** that exports one C procedure, `cinnabar_audio_api`, which takes the host's `Host` table and returns the backend's `Audio_API`. `lib/core/audio/audio.h` declares both, as `cn_audio_host` and `cn_audio_api`, with the same layouts as `lib/core/audio/audio.odin`; both sides assert every size. The first call sets the backend up; later calls return the same table. The backend keeps the `Host` pointer until `shutdown`.
- **`audio_plugin.load` opens `audio_<name>.dll`** beside the executable with `core:dynlib`, in release builds too. The library stays loaded for the life of the host, as its threads are the host's; a changed backend needs a host restart.
- **The host checks a backend** before it uses it: `info().api_version` must be `API_VERSION`, and `info().layout` must be `layout_signature()`, an FNV-1a hash of the size of every type that crosses the boundary, which `cn_audio_layout()` in `audio.h` computes the same way. A backend that does not load or does not match is an error, and the game runs on the null backend instead, so it starts without sound rather than not at all.
- **`just audio-plugin` builds the mixer as a library,** `audio_cinnabar.dll`, from `lib/core/audio/dll`. It proves that nothing but the two tables crosses the boundary: run it with `--audio cinnabar`.

## Choosing

| Where | Key or argument | Values |
|---|---|---|
| `project.settings`, or `project.user.settings` on one machine | `audio.backend` | `mixer` (the default), `none`, or another backend's name |
| The host's command line | `--audio <name>` | The same; it replaces the settings |

The host reads the key itself, from the user's file first, before the game starts (`audio_host.backend_setting`), since it loads the backend before it loads the game. The game's own settings parser knows the key only so it does not warn about it. `core.init` takes the name as `audio_backend_name`; empty, it reads the settings.

## The contract

**Threads.** The game calls `Audio_API` from one thread at a time, its frame code, and never from a job. The backend's own threads keep playing between calls, and through a code reload, so a thread that it starts must run the backend's code, never the game's.

**Output.** A backend may mix to the core device, with `Host.device_write` and `Host.device_status`, from one thread at a time. The device takes 48 kHz stereo `f32`, and opens on its first frames. A backend with its own output, as FMOD and Wwise have, never calls them, so the device never opens.

**Memory.** Memory for the backend's own use comes from `Host.allocate` and `free`, the host's heap, so a code reload keeps it. `allocate` gives zeroed memory. `reset` frees what the game left, for a soft restart, and `shutdown` releases the rest at the host's exit, including the backend's threads. A backend may be loaded again after `shutdown`.

**Handles.** The backend allocates `Sound`, `Voice` and `Bus` handles, an index and a generation. A call with a stale or nil handle does nothing, which the backend may log. A nil `Bus` means `MASTER_BUS`, which always exists.

**Sounds.** A `Sound_Desc` is 16-bit PCM at `SAMPLE_RATE` (48 kHz), mono or stereo, interleaved. A sound with `samples` is in memory, and the backend copies them before `sound_create` returns. A sound with `path` has them in that file, from `offset` in bytes, and the backend reads them as it plays. The cooker can replace the file while it plays, so the backend must not hold it open between reads ([Streaming](design.md#streaming)): `Host.file_open`, `file_read_at`, `file_modified` and `file_close` are for this, and a voice ends when its file changes. A backend without `Streaming` gets every sound with `samples`.

`sound_destroy` makes the handle stale at once, and the sound's voices go on until they end.

**Voices.** `voice_play` starts one, or returns the nil voice when it cannot, such as with a full pool, which it logs once and counts in `stats`. `voice_set` gives it new values, which it moves to without a click. `voice_stop` fades it over `fade` seconds, and makes the handle stale at once. `voice_playing` is false once it has ended or its handle is stale.

**`Voice_Params`.**

- `position` is in the listener's axes, in meters: the listener is at the origin, X is to its right and Y is up. No listener crosses the boundary. For FMOD, leave the listener at the origin, and set each channel's 3D attributes from this.
- `occlusion` goes from 0, nothing, to 1, a wall. How it sounds is the backend's choice.
- `min_distance` and `max_distance` are full volume and silence.
- Without `spatial`, the position, the distances and the occlusion do nothing.

**`update`** runs once a frame, on the game's thread. It is the place for FMOD's `System::update` or Wwise's `RenderAudio`, and for freeing what the backend's threads have finished with.

**`set_paused`.** While paused, no voice advances and the output is silent.

**`reset`** stops every voice without a fade, destroys every sound and every bus but Master, and returns how many voices it stopped. The device stays open and the backend stays usable, as the next game starts at once. It belongs to the host, and so does `shutdown`: the game never calls them.

## Features

`info().features` says what a backend does. The engine reads it at `audio.init`:

| Feature | Without it |
|---|---|
| `Streaming` | Sounds that ask to stream are loaded. |
| `Spatial` | The backend may ignore positions, distances and occlusion. |
| `Buses` | `bus_create` may return the nil bus, whose voices go to Master. |
| `Effects` | `bus_set_effect` may do nothing. |

## The null backend

`lib/core/audio/null` makes no sound and starts no thread. It checks every handle as a real backend does, and reports every feature, so the engine's tests of the boundary run on it headless. A voice plays until it is stopped, as nothing ever ends it. `audio.backend = none` makes it the game's backend, and `lib/engine/audio/audio_test.odin` runs on it with a table that records what the game side asks.

## Writing a backend

1. Include `audio.h`, and implement every procedure of `cn_audio_api`. A procedure the backend cannot do still takes its arguments and does nothing.
2. Export `cinnabar_audio_api`; return `CN_AUDIO_API_VERSION` and `cn_audio_layout()` in `info`.
3. Build it with the static CRT, as a DLL named `audio_<name>.dll`, and copy it beside `host.exe` and the release executable.
4. Pass the conformance suite.

## Conformance

`lib/core/audio/conformance` is the suite that every backend passes, driven through `Audio_API` with no engine world: `info`, a looping voice until it stops, stale handles, a sound that outlives its handle, nested buses and effect slots, `reset`, and a full pool. `conformance.run` runs them all, and a backend's tests call it with its table, as `lib/core/audio/null/null_test.odin` and `lib/core/audio/mixer/mixer_test.odin` do. `lib/core/audio/plugin/plugin_test.odin` runs it through the DLL as the host loads it.
