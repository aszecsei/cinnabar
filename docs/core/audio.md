# Audio

The audio device in `core`: what the `audio_*` group of `Platform_API` does, how a writer keeps playback going across a code reload, and what happens when the device goes away. Read [Platform](platform.md#platform_api) first for the group's place.

**In this document:** [The device](#the-device) · [Format](#format) · [Status](#status) · [Queue depth and code reload](#queue-depth-and-code-reload) · [Device loss](#device-loss) · [Test tone](#test-tone)

## The device

The host owns the whole device, so a code reload does not touch it.

- **The queue** is a ring of about 2.7 seconds (`AUDIO_RING_FRAMES`) on the host's heap, not in the permanent arena, so a soft restart keeps it too.
- **The device thread** moves frames from the queue to the default output endpoint through WASAPI, in shared mode. The endpoint's event wakes it about every 10 ms. It runs at the Pro Audio multimedia priority.
- **`audio_write`** copies frames into the queue and returns how many fit. It needs no lock, and it takes one writer at a time. Its first frames start the thread. A game that writes nothing has no thread, no stream and no entry in the Volume Mixer.

`core.shutdown` stops the thread first, so what is still queued does not play. A soft restart does nothing to the device: what the old game queued plays out, and the stream stays open for the new game.

## Format

`AUDIO_SAMPLE_RATE` is 48 kHz, and an `Audio_Frame` is a left and a right `f32`. That is the only format. Windows converts it to the endpoint's format (`AUTOCONVERTPCM`), so nothing on the game side follows the device.

## Status

`audio_status` can be called from any thread, and gives:

| Field | Meaning |
|---|---|
| `queued` | Frames written that the device has not taken. |
| `played` | Frames that the device has taken since the first write, including those it drained without an endpoint. |
| `starved` | Frames of silence that the endpoint took after the first frame, because the queue was empty. A writer that stops on purpose counts here too. |
| `open` | Whether an endpoint is open. |

At exit, the host logs the `played` and `starved` totals of a run that wrote audio. After each reload, it logs at debug level how long the reload took, what was queued before and after it, and how many frames starved during it.

## Queue depth and code reload

A writer chooses its own queue depth by writing until `queued` reaches it. The depth is a trade between how late the audio is and how long the writer can stop.

A writer in the game's frame code stops whenever the frames stop, so it must queue enough to outlast them. A code reload is one such stop: the host loads the new DLL between frames, and the device thread keeps playing the queue. In `mygame` a reload takes about 17 ms. A stall that is longer than the queue starves, such as the first frames of a run, or dragging the window, because the window's message loop holds the main thread.

A writer on its own host-side thread does not stop for any of these, so it can keep a much shorter queue. Its code must be host code, because a thread cannot run in a DLL that a reload replaces ([Hot reload](../overview/hot-reload.md#rules)).

## Device loss

Once a second, the thread compares the default endpoint with the one it has open, and opens the new one if they differ. A failed call on the stream, such as `AUDCLNT_E_DEVICE_INVALIDATED` for a device that was unplugged, closes the stream, and the thread tries to open the default endpoint once a second until it succeeds.

Without an endpoint, the thread drains the queue at the sample rate, and logs one warning. So a writer keeps its pace, and old audio does not play when a device comes back.

## Test tone

Set `CINNABAR_TEST_TONE=1` to make `Platform_API.audio_test_tone` true. `mygame` then plays a quiet 440 Hz sine with `audio.Tone` in `lib/engine/audio`, which keeps 250 ms queued.

The tone writes after the world's `Late` stage, where [render extraction](../world/render-extraction.md#render-extraction) reads the world, and its pan comes from the `ecs.presented` pose of the first entity with a `Spin`: `Tone Source` in the main scene. So its pan is a tick behind and interpolated, as a drawn pose is, and it moves from one frame's value to the next over the frames it writes. The phase and the pan are in `Game_State`, so a code reload continues the sine exactly, and a soft restart starts it again.
