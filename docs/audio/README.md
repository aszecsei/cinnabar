# Audio

Sound in the world: the boundary between the engine and an audio backend in `lib/core/audio`, the mixer behind it, and the components, spatial sound, occlusion and script bindings in `lib/engine/audio`. The device that the mixer writes to is in [Core: Audio](../core/audio.md#audio), and the sound asset is in [Content: Audio](../content/kinds/audio.md#audio).

## Documents

| Document | What it covers |
|---|---|
| [Design](design.md) | The game side, sources and the listener, occlusion, the mixer, buses and effects, streaming, lifetimes, scripts and the sample. |
| [Backends](backends.md) | How a backend plugs in: loading, choosing with `audio.backend`, the contract of `Audio_API` and `Host`, features, the null backend, and the conformance suite. |

## Overview

| Package | Side | Responsibility |
|---|---|---|
| `lib/core/audio` | Shared | The boundary: handles, descriptions, `Audio_API` and `Host`, and `audio.h`, the same in C. |
| `lib/core/audio/host` | Host | The `Host` table: the heap, the log and files for a backend, and the `audio.backend` setting. |
| `lib/core/audio/plugin` | Host | Finds the backend that a project chose, and checks it. |
| `lib/core/audio/mixer` | Host | The engine's own backend: voices, buses and effects on a mix thread, and streams on a thread of their own. |
| `lib/core/audio/codec` | Host and game | Decodes compressed sounds a block at a time, for the mixer's stream thread and the engine's load of a sound. |
| `lib/core/audio/adpcm`, `lib/core/audio/opus` | Host, game and cooker | IMA ADPCM in Odin, and the bindings to libopus. |
| `lib/core/audio/null` | Host | A backend that makes no sound, for tests and for games without sound. |
| `lib/core/audio/dll` | Host | The mixer as a library, `audio_cinnabar.dll`, which proves the boundary. |
| `lib/core/audio/conformance` | Shared | The tests that every backend passes. |
| `lib/engine/audio` | Game | The components, spatial sound from presented poses, occlusion by physics rays, sounds by asset, and script bindings. |

The data flow in a frame: scripts and game code ask for sounds with `audio.play`. After the world's `Late` stage, `audio.update` reads the presented poses of the listener and the sources, casts a few occlusion rays, and sends each voice its position in the listener's axes. The mix thread takes those commands at its next block, mixes the voices through the buses into the device's queue, and goes on through anything that stops the frames.

## References

- Ross Bencina, [*Real-time audio programming 101*](http://www.rossbencina.com/code/real-time-audio-programming-101-time-waits-for-nothing): why the mix thread takes no lock, allocates nothing and reads no file.
- Robert Bristow-Johnson, [*Audio EQ Cookbook*](https://www.w3.org/TR/audio-eq-cookbook/): the coefficients of the low-pass and high-pass.
- Jot and Chaigne, *Digital delay networks for designing artificial reverberators* (AES, 1991): the feedback delay network of the reverb.
- [FMOD Core API](https://www.fmod.com/docs/2.03/api/core-api.html) and [Wwise SDK](https://www.audiokinetic.com/library/edge/?source=SDK&id=index.html): the voice-level interfaces that the boundary has to map onto.
- Unity, [*Audio Source*](https://docs.unity3d.com/Manual/class-AudioSource.html) and [*Audio Listener*](https://docs.unity3d.com/Manual/class-AudioListener.html): the component model.
