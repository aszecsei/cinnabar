# Time

The fixed tick schedule, the frame-rate stages, interpolation of presented poses and teleports. Read [ECS](ecs.md#systems) first for the stages.

**In this document:** [Fixed and variable rate](#fixed-and-variable-rate) · [Time scale](#time-scale)

## Fixed and variable rate

- The world has a tick rate in Hz (default 60). Tick `n` covers world time from `n * time.Second / tick_rate` to the start of tick `n + 1`, and runs when that interval has passed. The schedule is integer arithmetic on `time.Duration`, so it never drifts.
- Each frame runs every tick that is due, up to 4 ticks. If more ticks are due, the world drops the extra time, so the simulation runs slower, and logs a warning.
- A tick runs the `Fixed` systems, applies their command buffers, runs the scripts' fixed step and propagates transforms. The next tick sees the results of the previous one. The game's frame code drives the ticks one at a time with `ecs.begin_ticks` and `ecs.next_tick` ([ECS](ecs.md#systems)).
- `Fixed` systems get the tick duration as `dt`. `Update` and `Late` systems get the frame duration.
- **Input:** all ticks in a frame see the input state of that frame. An edge (pressed, released, of a key, a gamepad button or a stick direction) and typed text go to the first tick after them. If no tick runs in a frame, they wait for the next tick. `System_Context.first_tick` marks the first tick of a frame, and the scripts' fixed step gives the edges and the text only to it, keeping a frame's when it ran no tick ([Fixed step](../scripting/behaviours.md#fixed-step)).
- **Interpolation:** an entity that moves in `Fixed` systems has a `Previous_Transform`, and so do its children. At the start of each tick, the world copies `Transform` to `Previous_Transform`. Presentation (render extraction, cameras, UI) uses `presented`, or `interpolate` with the clock's `alpha`, the fraction of the current tick that has passed. Presentation is therefore up to one tick late. Animation poses are presented the same way, from the samples of the last two ticks ([Animation: Ticks and presentation](../animation/design.md#ticks-and-presentation)).
- **Teleports:** to move an interpolated entity without a blend, use `teleport` or `command_teleport`. It sets both `Transform` and `Previous_Transform`.
- **Rate changes:** `set_tick_rate` takes effect from the next tick. The schedule stays exact across the change.
- **Aligning:** `ecs.align_clock` drops the part of a tick that has passed. The ticks then start again from the current one, so the next frame's ticks fall where a fresh clock's would. A render out calls it at its start, so each run has the same ticks (see [Cutscene editor: Render out](../editor/cutscene-editor.md#render-out)).

## Time scale

A game can run the world's time faster or slower, for hit-stop and slow motion. `Game.set_time_scale(scale)` sets the scale, which is kept between 0 and 4, and 1 when it is not a number. The game stores it in `Game.time_scale`, a `Maybe(f32)` whose nil is 1, so a game that never sets it is unscaled. `set_time_scale` in `game.odin` is its one writer.

- **The world's step** is the frame's duration times the scale, and 0 while the game is paused. The pause wins: `Game.set_paused` stops the world whatever the scale is, and a paused game keeps its scale for when it resumes. `Time.scale` is the scale that was set, and does not drop to 0 in a pause.
- **What the step drives:** the fixed ticks (`ecs.begin_ticks` adds the step to the clock, so the schedule stays exact integer arithmetic), the `Update` and `Late` stages, the script phase, the particles and `Time.delta` and `Time.time`. A scale of 0.5 runs half the ticks that the same real time would, and a scale above 1 is limited by the 4 ticks of a frame, so the world drops what it cannot catch up on, as it does at a low frame rate.
- **Input edges:** a scale of 0 is a frame without a tick, so it behaves as a pause does. Edges and typed text wait for the next tick that runs ([Fixed and variable rate](#fixed-and-variable-rate)); none is dropped or sent twice.
- **What stays in real time:** the UI (its input, focus and animations), the audio, `Time.real_time`, `Time.real_delta`, `wait_realtime` and the editor. In the editor's Paused mode, a single step is one tick, which the scale does not change.
- **`Time.real_delta`** is the frame's real duration in seconds, also while the game is paused. `Time.delta` is the world's step, so `Time.delta` is `Time.real_delta * Time.scale` outside a pause and 0 in one.
