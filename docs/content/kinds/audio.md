# Audio

Sounds are `.wav`, `.ogg`, `.flac` and `.mp3` files in the content roots, which an `Audio_Source` or a script plays (see [Audio: Design](../../audio/design.md#sources-and-the-listener)). `just audio` runs `cook audio --cache build/<target>/content --config dev|release --root game=<content root> --root engine=lib/engine/content`, and the daemon cooks them like any other kind (`tools/cook/audio.odin`).

**The cook.** `vendor:miniaudio` decodes the file, in the cooker only, and converts it to 16-bit PCM at `AUDIO_SAMPLE_RATE` (48 kHz), which is what the device and the boundary take. The runtime links no decoder, and has no rate to convert at playback but a voice's own pitch.

**The blob.** `Audio_Blob` holds the frames, the channels, whether it streams, and the samples, interleaved and not compressed, so a [stream](../../audio/design.md#streaming) reads any part of them straight from the file. PCM takes room: 96 KB a second for mono, and 192 KB for stereo. A sound's samples fit in 4 GiB, past which the cook fails, with about 6 hours of stereo.

**Import settings**, in the sound's `.meta` file:

| Setting | Values | Default | Meaning |
|---|---|---|---|
| `stream` | `auto`, `true`, `false` | `auto` | Read the sound from its blob as it plays, rather than load it. `auto` streams a sound longer than `AUDIO_STREAM_SECONDS` (10). |
| `channels` | `auto`, `mono`, `stereo` | `auto` | The channels of the cooked sound. `auto` keeps the source's, and more than two become stereo. A sound placed in the world plays as mono either way, so `mono` takes half the space. |

**The cache key** covers the cooker version, the miniaudio version, the layout, the source path, the source, the `.meta` file and the GUID. A sound that fails to decode keeps its old blob, so the running game keeps the last good version.

**A big source costs every pass.** The scan reads each asset's source to key it, on every pass of the daemon ([Daemon and operations](../daemon-and-operations.md#cook-daemon)). A very long `.wav` adds that read to each one, and a compressed source costs less.

**Referring to a sound.** A component's field is a tagged GUID, as `Audio_Source.sound` is:

```odin
sound: format.Guid `asset:"audio"`,
```

A behaviour's field is `Field.asset("audio")`. Both show a picker of sounds in the editor. A scene writes the GUID as `$` and its 32 hex digits.

## The sample's sounds

`samples/mygame/content/audio` holds three sounds that a formula makes, so the repository holds no recorded audio. `just sample-audio` writes them again, with `tools/audio_samples.py`, and always the same bytes.

| Sound | What it is |
|---|---|
| `hum.wav` | A machine's drone, 2 seconds that loop without a seam, with high harmonics that make it easy to hear a wall take them away. |
| `thud.wav` | A short knock for a box that lands. |
| `ambience.wav` | A slow pad, 20 seconds that loop. It streams, as it is over 10 seconds, and it is at 24 kHz, so its cook converts its rate too. |
