# Audio

Sounds are `.wav`, `.ogg`, `.flac` and `.mp3` files in the content roots, which an `Audio_Source` or a script plays (see [Audio: Design](../../audio/design.md#sources-and-the-listener)). `just audio` runs `cook audio --cache build/<target>/content --config dev|release --root game=<content root> --root engine=lib/engine/content`, and the daemon cooks them like any other kind (`tools/cook/audio.odin`).

**The cook.** `vendor:miniaudio` decodes the file, in the cooker only, to 16-bit PCM. A source at another rate is then converted to `AUDIO_SAMPLE_RATE` (48 kHz), which is what the device and the boundary take, so the runtime has no rate to convert at playback but a voice's own pitch. Last, the sound is coded in its `format`.

**A rate conversion keeps a loop whole.** The cooker converts with its own windowed sinc, which reads around the sound's ends and has no latency, so a frame of the result reads the source at a place in proportion, and the last frame continues into the first at any rate. miniaudio's resampler, which starts and stops on the sound alone, ended a seamless 24 kHz source at -2483 where the next frame was 0, a step of about 8% of full scale at each loop.

**The blob.** `Audio_Blob` holds the frames, the channels, whether it streams, its format, how many frames a pass skips, and its data. A sound's data fits in 4 GiB, past which the cook fails, with about 6 hours of stereo PCM.

**Formats.** `format` chooses for each sound. The cooker encodes all of them from the 48 kHz PCM, so any source can be any format, and a compressed source is not passed through.

| Format | Bytes a second, stereo | Smaller than PCM | Decoder | For |
|---|---|---|---|---|
| `pcm` | 192 KB | 1 time | None | Exact sound, and what costs nothing to play. |
| `adpcm` | about 48 KB | about 4 times | `lib/core/audio/adpcm`, in Odin | Footsteps, gunshots and UI: short sounds that play often. |
| `vorbis` | about 20 KB | about 10 times | `vendor:stb/vorbis` | Music and other long sounds. |
| `opus` | about 16 KB | about 12 times | libopus | Music and other long sounds. It holds up better at low rates, and decodes about 2.5 times slower than Vorbis. |

These are for music. A smooth sound does better: the sample's `ambience.wav`, mono and slow, is 1.92 MB as PCM, 483 KB as ADPCM, 165 KB as Opus and 67 KB as Vorbis. Vorbis is at libvorbis's quality 5, and Opus at 64 kbps for each channel, which no setting changes yet.

**A sound that does not stream decodes when it loads,** so its format saves disk and not memory, and the mix thread only ever sees PCM. A sound that streams stays compressed on disk, and the [stream thread](../../audio/design.md#streaming) decodes it into its ring as it plays.

**A compressed sound is coded as a loop.** A Vorbis or Opus blob holds `AUDIO_ROLL_FRAMES` (4096, about 85 ms) of the sound's end before it, and as much of its start after it, wrapping as often as a short sound needs. `skip` says how much to throw away at the start of a pass, which includes Opus's encoder delay. So the decoder is settled on continuous sound at both ends of a pass, and a pass gives exactly `frames`. ADPCM needs none of this: its blocks are a fixed size, and each starts on an exact sample.

**Import settings**, in the sound's `.meta` file:

| Setting | Values | Default | Meaning |
|---|---|---|---|
| `stream` | `auto`, `true`, `false` | `auto` | Read the sound from its blob as it plays, rather than load it. `auto` streams a sound longer than `AUDIO_STREAM_SECONDS` (10). |
| `channels` | `auto`, `mono`, `stereo` | `auto` | The channels of the cooked sound. `auto` keeps the source's, and more than two become stereo. A sound placed in the world plays as mono either way, so `mono` takes half the space. |
| `format` | `pcm`, `adpcm`, `vorbis`, `opus` | `pcm` | How the blob stores the sound. |

**The cache key** covers the cooker version, the miniaudio, Opus and Vorbis versions, the layout, the source path, the source, the `.meta` file and the GUID. A sound that fails to decode keeps its old blob, so the running game keeps the last good version.

**A big source costs every pass.** The scan reads each asset's source to key it, on every pass of the daemon ([Daemon and operations](../daemon-and-operations.md#cook-daemon)). A very long `.wav` adds that read to each one, and a compressed source costs less.

**Referring to a sound.** A component's field is a tagged GUID, as `Audio_Source.sound` is:

```odin
sound: format.Guid `asset:"audio"`,
```

A behaviour's field is `Field.asset("audio")`. Both show a picker of sounds in the editor. A scene writes the GUID as `$` and its 32 hex digits.

## The sample's sounds

`samples/mygame/content/audio` holds four sounds that a formula makes, so the repository holds no recorded audio. `just sample-audio` writes them again, with `tools/audio_samples.py`, and always the same bytes.

| Sound | What it is |
|---|---|
| `hum.wav` | A machine's drone, 2 seconds that loop without a seam, with high harmonics that make it easy to hear a wall take them away. |
| `thud.wav` | A short knock for a box that lands. `format = adpcm`. |
| `bark.wav` | Two short barks for the guard scene's agents, each a pitch that falls fast with its harmonics loudest near 1 kHz (see [AI: The sample](../../ai/README.md#the-sample)). `format = adpcm`. |
| `ambience.wav` | A slow pad, 20 seconds that loop. It streams, as it is over 10 seconds, and it is at 24 kHz, so its cook converts its rate too. `format = vorbis`, which makes it 29 times smaller. |
