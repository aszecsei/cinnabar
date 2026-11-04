# Audio design

How sound gets from a component or a script to the speakers. Read [Hot reload](../overview/hot-reload.md#rules) first for why a thread must be host code, [Core: Audio](../core/audio.md#audio) for the device, and [World: Render extraction](../world/render-extraction.md#render-extraction) for presented poses.

**In this document:** [The game side](#the-game-side) · [Sources and the listener](#sources-and-the-listener) · [Occlusion](#occlusion) · [The mixer](#the-mixer) · [Buses and effects](#buses-and-effects) · [Streaming](#streaming) · [Lifetimes](#lifetimes) · [Scripts](#scripts) · [The sample](#the-sample)

## The game side

`lib/engine/audio` holds no audio. Its `State` is in `Game_State`, and holds handles to what the backend owns. The game calls it at four points, as it does physics:

| Call | When |
|---|---|
| `init` | Once. It starts nothing: the backend's threads wait for the first voice. |
| `register_components`, `register_scripts` | With the game's other registrations, at `init` and at each code reload. |
| `update` | Once per frame, after the world's `Late` stage, whether the world runs or not. |
| `reload`, `destroy` | At a code reload, which only takes the new `Platform_API`, and at shutdown. |

`update` takes `run`, whether the world runs this frame. While it does not, as in the editor's edit mode or while paused, the backend is paused: voices hold their place, and no new one starts.

A game plays the [test tone](../core/audio.md#test-tone) or calls `update`, not both, because the device takes one writer. `mygame` chooses with `audio_test_tone`.

## Sources and the listener

**`Audio_Source`** (96) plays a sound at its entity's presented pose while the entity is active. A despawned or disabled entity, or a removed component, stops its voice with a short fade (`STOP_FADE`, 30 ms).

| Field | Meaning |
|---|---|
| `sound` | The sound, an `audio` asset. |
| `bus` | 0 is Master, and n is the nth of the project's `audio.buses`. One that the project does not name is Master. |
| `playing` | Plays while this is set. A sound that does not loop clears it when it ends, and setting it again plays it again. |
| `loop` | Plays until `playing` is cleared. |
| `spatial` | Placed in the world and heard from the listener. Otherwise it plays as it is. |
| `occluded` | [Occlusion](#occlusion) applies. |
| `gain`, `pitch` | The level, and the playback rate: 1 is the sound's own. |
| `min_distance`, `max_distance` | Full volume at `min_distance` and nearer, and silence at `max_distance` and farther. |

**`Audio_Listener`** (97) marks where the world is heard from: its entity's presented pose. The first one in the world counts. Without one, a spatial source plays centred at full gain, with one warning.

**Spatial sound comes from presented poses.** `update` runs where render extraction reads the world, and uses `ecs.presented`, so a source sounds where it is drawn, between ticks. An entity that moves in `Fixed` systems needs a `Previous_Transform` for this, as it does to be drawn smoothly.

**The boundary takes positions in the listener's axes**, as `[3]f32`: the listener is at the origin, X is to its right and Y is up. A difference of `World_Position`s is exact, so sound is as good 1.5e11 m from the origin as at it, and no backend ever sees a large-world coordinate.

**The mixer's laws**, in `voice_gains`: inverse distance, shifted to reach 0 at `max_distance`, and equal-power pan from how far the source is to the side, so moving does not change the loudness. A stereo sound that is spatial is mixed down to one point. One that is not keeps its sides.

## Occlusion

A wall between a source and the listener muffles the source: `update` casts rays with `physics.raycast`, from the listener to the source, and a hit is an occlusion of 1.

- **Rays are budgeted.** Up to `OCCLUSION_RAYS` (8) a frame, in turn over the sources, so many sources cost no more than a few.
- **It is smoothed.** A voice moves toward what its last ray found over `OCCLUSION_SMOOTHING` (0.1 s), so a source does not jump behind a wall. A voice that starts behind a wall starts muffled.
- **The source's and the listener's own bodies do not count**, nor do sensors. A collider on a child of the source does count.
- **A ray ignores the back faces of triangles** ([Physics: Queries](../physics/design.md#queries)), so a mesh wall occludes from its front only. A box collider occludes from both sides.
- **A sound from `Audio.play` casts one ray**, when it starts. It is short, and does not earn more.
- **The null physics backend's rays all miss**, so nothing occludes on it. `update` also takes a nil physics state, for a game without physics.

The mixer turns occlusion into a gain, down to `OCCLUSION_GAIN` (0.35), and a one-pole low-pass, whose cutoff falls from `OCCLUSION_OPEN_HZ` (20 kHz) to `OCCLUSION_CLOSED_HZ` (800 Hz). A wall takes the highs first, so the source sounds behind something, not only far away. In the sample, it takes about 20 dB from what is above 1.5 kHz.

## The mixer

`lib/core/audio/mixer` is the backend that a project gets by default. It is host code, linked into the host, so it runs through a code reload.

**Two threads, and neither starts until a voice plays,** so a game without sound has no thread, and the device never opens.

- **The mix thread** keeps `QUEUE_TARGET` (40 ms) queued at the device, in blocks of `BLOCK_FRAMES` (240, or 5 ms). It paces itself with a high-resolution waitable timer, because `time.sleep` has the system tick's 15.6 ms. It takes no lock, allocates nothing, frees nothing, logs nothing and reads no file, so nothing it does can make it late.
- **The stream thread** reads files. See [Streaming](#streaming).

**The game's thread and the mix thread share only a queue and atomics.** The game's thread owns the handle tables. It allocates what a command needs, such as an effect's delay lines, and pushes a command to a queue of `COMMAND_CAPACITY` (4096). The mix thread takes the queue at each block. Going the other way, it sets a voice's `finished` flag, lowers a sound's count of users, and puts an effect it has finished with in a list. `update`, on the game's thread, frees what they release.

A voice's handle goes stale as soon as it stops, while its slot stays busy until the voice has faded on the mix thread. A sound lasts as long as its last voice, however early `sound_destroy` comes.

**`render` is a plain procedure**: it takes commands, mixes frames, and needs no thread or device. The tests call it, and read the samples.

**A voice's path,** in `mix_voice`: read its PCM, from memory or a stream's ring, through a two-frame window, interpolated by `pitch`; apply the occlusion's low-pass; apply its gains, moved from last block's across this block, so a change never clicks; and add it to its bus.

**Limits.** `MAX_VOICES` (128) and `MAX_STREAMS` (16). Past them a voice is refused, with one warning, and `stats` counts it. There are no virtual voices and no priorities yet.

## Buses and effects

Master is always there. `audio.buses` names the others in the project's settings, all children of Master:

```
audio.buses = Music, Sfx
```

`bus_create` takes any parent, so a game can nest them through the table. A bus's parent is always older, so the mix thread mixes from the last bus to the first. `audio.set_bus_gain` and `audio.set_bus_effect` take a bus by name.

Each bus has `MAX_BUS_EFFECTS` (4) slots, which the sound passes in order:

| Effect | Parameters |
|---|---|
| `Low_Pass`, `High_Pass` | Cutoff in Hz, resonance Q. Biquads from the Audio EQ Cookbook. |
| `Delay` | Time in seconds, up to 2; feedback, below 1; wet level. |
| `Reverb` | Decay in seconds; damping from 0 to 1; wet level. A feedback delay network of four lines. |

Setting new parameters on a slot of the same kind keeps its memory, so a delay's tail goes on.

**Nothing may feed back more than it takes.** The reverb's damping filter must take all of what leaves its matrix: on only part of it, high frequencies return at up to twice their level, the tail grows without end, and the limiter holds it at full scale. `effects_stay_bounded` drives every effect with loud noise at its worst parameters.

**Master protects the output.** A soft limiter passes samples below `LIMITER_THRESHOLD` (0.9) unchanged, and bends the rest toward 1. A mix past `FAULT_LEVEL` (1024), or one that is not a number, is a fault and not a loud sound, which the limiter would play at full scale: the block goes silent instead, every effect's memory is cleared, and `update` logs an error.

## Streaming

A sound whose blob says `stream` is not loaded. `sound_create` takes its blob's path, where its data starts, its size and its format, and each voice of it reads them as it plays.

- **Each playing voice has a stream**: a ring of `STREAM_RING_FRAMES` (about 1.4 s), and a place in the file. The stream thread tops the ring up when a `STREAM_CHUNK_FRAMES` (about 0.7 s) of it is free, so a slow disk has a long time to catch up.
- **A voice waits for its first read,** so it does not start with a gap.
- **A reader that falls behind** plays silence, and `stats` counts it in `stream_starved`, which `destroy` logs.
- **A blob's data is in a format** that its `.meta` file chose ([Content: Audio](../content/kinds/audio.md#audio)). A place in PCM or ADPCM is one multiplication. A place in Vorbis or Opus is not, and nothing asks for one but the start, so there is no seek table: a later seek needs one, or a decode from the start.

**Decoding is the stream thread's, never the mix thread's.** The mix thread reads only the ring, which holds PCM whatever the format, so it takes no lock, allocates nothing and reads no file, as before. `lib/core/audio/codec` is the decoder:

- **Each playing voice has its own decoder state,** as each has its own place in the file. Its memory is allocated once for the stream, on the game's thread, as the ring is: about 660 KB for Vorbis, which is the most, 160 KB for Opus, and 10 KB for ADPCM. stb_vorbis takes all of its memory from this, and libopus's state is in it.
- **A block that does not fit in the ring waits** for the next fill, since a block is the codec's size and not the ring's.
- **It costs little.** On the sample's 20-second sound, a pass decodes in 3 ms for ADPCM, 7 ms for Vorbis and 18 ms for Opus. This is on one thread for 16 streams at most, so the decoder is not what a reader falls behind on.

**A loop's seam is crossed, not cut.** A pass of a Vorbis or Opus sound ends with `frames` given, and the cook has coded the sound's start again after its end. So the decoder goes on for `SEAM_FRAMES` (512, about 11 ms) past the end, and the next pass fades from these into its own start. Both are the same sound with different coding noise, so their levels add to the sound's. Without this, the two sides meet with a step the size of that noise: on the sample's slow pad, a second difference of about 40 for Vorbis and 86 for Opus, against about 22 anywhere else in the sound, and with it about 1. `a_loop_has_no_step_at_its_seam` holds this to account. ADPCM has no such step to hide: its noise is as large as a step everywhere.

**A loop starts its decoder again.** libopus resets its state. stb_vorbis reads its headers again, which takes about 0.2 ms, because `stb_vorbis_flush_pushdata` drops a frame and looks for a page, and so is not a return to the start. Each pass then throws away `skip` frames.

**A stream closes its file after every read.** The cooker writes a blob by renaming a new file over it, and Windows refuses that while the file is open, even one opened with `FILE_SHARE_DELETE`; `a_file_that_is_open_cannot_be_replaced` holds this to account. So a long-held handle would make a re-cook of a playing sound fail. The other side of the bargain:

- A read can still meet the cooker's rename, for the moment that it takes, so `write_blob` tries the rename again for a short while.
- A stream looks at the file's time at each read. If the file changed, what follows may not line up with what played, so the voice ends, and `update` starts its source again from the new sound.

`update` also looks at one sound's blob each frame, in turn, and makes a new sound of a changed one. Memory sounds use this too, and stay out of the asset system: the backend holds their samples, so the blob is read, decoded if it is compressed, copied and freed. A compressed memory sound gives what a later pass of a stream gives, crossed over, so its loop has no seam either.

## Lifetimes

| | Code reload | Soft restart | Host exit |
|---|---|---|---|
| The backend, its threads, voices, sounds and buses | Kept, and it keeps playing | `core.soft_restart` calls `reset`: voices stop at once, and sounds and buses but Master go. The threads stay. | `shutdown`, before the device's |
| `audio.State` and its handles | Kept, and they stay good | Fresh | Gone |
| What is in the device's queue | Plays | Plays out | Does not play |

In `mygame`, a code reload takes about 15 ms with no gap and no frame starved, as the mix thread does not notice it. A soft restart leaves about 50 ms of silence, then the new game's sources start again.

A voice's commands wait while the frames stop, so a voice goes on with its last position and gain through a stall. A source that moves stops moving in the mix until the frames come back.

## Scripts

`audio.register_scripts` defines the `Audio` library, and exposes `Audio_Source` and `Audio_Listener`. A script reaches a sound through a `Field.asset("audio")` field, as there is no way to load an asset by path. `script.expose` leaves out a component's asset fields, so a script cannot change `Audio_Source.sound`, though it can set `playing`, `gain` and the rest.

```luau
local Thud = Behaviour.define("Thud", { sound = Field.asset("audio") })

function Thud:on_collision_enter(other: Entity, point: WorldPosition, normal: vector, velocity: vector, impulse: number)
	Audio.play(self.sound, point, math.clamp(impulse / 4, 0.1, 1), "Sfx")
end
```

| Binding | What it does |
|---|---|
| `Audio.play(sound, position?, gain?, bus?)` | Plays a sound once, to its end. With a position, it is placed in the world, between `ONE_SHOT_MIN_DISTANCE` (1 m) and `ONE_SHOT_MAX_DISTANCE` (50 m). `bus` is a bus's name. |
| `Audio.set_bus_gain(bus, gain)` | Sets a bus's gain by name. |

A value that is not a sound, or a name that is not a bus, raises an error in the script. Sounds start at `update`, after the frame's scripts, so they are heard from the frame's listener.

`Audio.play` loads a sound the first time, on the frame's thread, so the first play of a long memory sound can take a moment. Up to `MAX_ONE_SHOTS` (64) play at once.

## The sample

`samples/mygame` shows all of it. F7 cycles to the audio scene, `content/scenes/audio.scene`, where the camera has an `Audio_Listener`, and `Hum`, an `Audio_Source` with a looping sound on the `Sfx` bus, moves from side to side behind a wall by `orbit.luau`. The hum crosses the stereo image, and the wall muffles it while it is between the two. `Ambience`, a 20-second sound on the `Music` bus that is not spatial, streams beneath it. `Sfx` has a reverb, which `apply_audio_settings` gives it.

In the main scene, `thud.luau` plays a knock through `Audio` when a box lands on the short box.
