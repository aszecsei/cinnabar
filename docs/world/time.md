# Time

The fixed tick schedule, the frame-rate stages, interpolation of presented poses and teleports. Read [ECS](ecs.md#systems) first for the stages.

**In this document:** [Fixed and variable rate](#fixed-and-variable-rate)

## Fixed and variable rate

- The world has a tick rate in Hz (default 60). Tick `n` covers world time from `n * time.Second / tick_rate` to the start of tick `n + 1`, and runs when that interval has passed. The schedule is integer arithmetic on `time.Duration`, so it never drifts.
- Each frame runs every tick that is due, up to 4 ticks. If more ticks are due, the world drops the extra time, so the simulation runs slower, and logs a warning.
- A tick runs the `Fixed` systems, applies their command buffers and propagates transforms. The next tick sees the results of the previous one.
- `Fixed` systems get the tick duration as `dt`. `Update` and `Late` systems get the frame duration.
- **Input:** all ticks in a frame see the input state of that frame. An edge (pressed, released) goes to the first tick after it. If no tick runs in a frame, the edge waits for the next tick. `System_Context.first_tick` marks the first tick of a frame.
- **Interpolation:** an entity that moves in `Fixed` systems has a `Previous_Transform`, and so do its children. At the start of each tick, the world copies `Transform` to `Previous_Transform`. Presentation (render extraction, cameras, UI, audio) uses `presented`, or `interpolate` with the clock's `alpha`, the fraction of the current tick that has passed. Presentation is therefore up to one tick late.
- **Teleports:** to move an interpolated entity without a blend, use `teleport` or `command_teleport`. It sets both `Transform` and `Previous_Transform`.
- **Rate changes:** `set_tick_rate` takes effect from the next tick. The schedule stays exact across the change.
