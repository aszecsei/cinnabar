# Animation design

The animation graph poses a skeleton from clips. It takes at most one transition between states each tick, fades between them, and blends clips by a parameter. It also raises events at clips' times and as states change, and reports the root joint's motion. This document covers:
- what the graph does and does not do;
- the instance that it keeps for each entity;
- how it ticks and how a pose is presented between ticks;
- transitions and fades, blends, events and root motion;
- the components and systems that run graphs on entities.

Read [World: Time](../world/time.md#fixed-and-variable-rate) and [Content: Animation graphs](../content/kinds/animation-graphs.md#animation-graphs) first.

**In this document:** [Design](#design) · [The instance](#the-instance) · [Ticks and presentation](#ticks-and-presentation) · [Transitions and fades](#transitions-and-fades) · [Blends](#blends) · [Events](#events) · [Root motion](#root-motion) · [The ECS](#the-ecs) · [Events in the world](#events-in-the-world)

## Design

1. **The graph reads only what it is given.** `lib/engine/anim/graph` imports `core:math`, `core:math/linalg` and `asset/format`, and nothing from the world, scripts or the renderer. Its inputs are:
   - the graph blob and its clips' blobs;
   - an instance;
   - a tick's seconds.

   Its outputs are the instance's next state, a `Tick_Output` with the tick's events and root motion, and the pose that `present` writes. It does not read gameplay state, and it does not move an entity. Gameplay sets parameters, reads the outputs, and acts on them. The package cannot name `ecs.World` or `Transform`, so the compiler keeps this rule.
2. **A tick makes samples, and presentation poses them.** A tick does not pose the skeleton. It keeps up to `MAX_SAMPLES` (8) samples: each is a clip, its time, the last tick's step, and its weight after the tick and before it. `present` samples each clip between the last two ticks and blends them, so a pose is posed once a presented frame, not once a tick, and only for what is drawn. A fixed tick's pose would not fit in a component: a skeleton of 24 joints is about 1 KiB a pose, and interpolating needs two.
3. **The instance is plain data of a fixed size.** `Instance` (at most 512 bytes) has the parameters, the state, the fade and the samples. It holds no pointer and no allocation, so it can live in a component, survive a code reload, and be copied.
4. **A trigger is seen by one tick.** A tick tests its transitions with the triggers that are set and then clears them all, whether a transition took them or not. A trigger does not wait in a state where nothing takes it.
5. **Root motion is reported, never applied.** A tick gives the root's move and turn. `remove_root_motion` takes them out of a pose. What moves the entity is gameplay's.

## The instance

| Field | What it holds |
|---|---|
| `key` | The graph blob's key that the instance was made for. A new blob makes the instance again, and `keep_parameters` keeps the values of the parameters whose names the new graph still has. |
| `parameters`, `triggers` | Each parameter's value: a float, or 1 and 0 for a bool. Each trigger is a bit. |
| `state`, `progress` | The current state, and its plays from its entry: 2.5 is halfway through the third. |
| `source`, `source_progress` | The state that the current one fades from, or `NONE`. |
| `fade`, `fade_duration` | Seconds into the fade, and its length. |
| `samples` | Up to `MAX_SAMPLES` (8) samples. |

`init` starts an instance in the entry state, with the parameters at their defaults, and makes its samples, so it presents before its first tick. A graph without a blob plays one clip, looping or held: an `Animator`'s clip without a graph.

## Ticks and presentation

`advance(g, inst, dt, out)` moves an instance by a tick of `dt` seconds, which the caller has scaled by its speed:

1. **The first tick** raises the entry state's enter event.
2. **Transitions:** it takes at most one, from the parameters, the triggers, and the progress after the last tick (see [Transitions and fades](#transitions-and-fades)).
3. **Triggers:** it clears them.
4. **Progress:** the current state, and the source if there is one, move by `dt` times the state's speed, over the duration of one play. A motion without a duration counts its plays in seconds.
5. **The fade** moves by `dt`. When it reaches its length, the source stops.
6. **Samples:** it makes them (below).
7. **Events and root motion:** it gives the tick's events and root motion.

**Samples.** The current state's clips weigh their blend weight times the fade's fraction, `fade / fade_duration`, or 1 with no fade. The source's clips weigh their blend weight times the rest, and frozen samples weigh their weight when they froze times the rest. A clip's time is the motion's phase times its duration. Its step is how far the phase moved times its duration: the whole distance when it loops, so a step can cross the wrap, and up to the end when it holds.

A sample is named from tick to tick by its state and its point in the state's motion, and whether it is frozen:
- **A sample that was there** keeps its old weight as its weight before the tick.
- **A new one** starts from 0.
- **One that is gone** stays a tick at weight 0, with its old weight before it, so presentation fades it out over the tick rather than cutting.
- **Past `MAX_SAMPLES`,** the samples that weigh least, before and after the tick, are dropped, a later one before an earlier.

**Presentation.** `present(g, inst, alpha, rest, scratch, locals)` takes each sample:
- at its time less its step times `1 - alpha`, wrapped when it loops and held when it does not;
- at its weight between its two, by `alpha`.

It samples the clip over the rest pose and adds the pose by its weight. A rotation joins the sum on the sum's side, so a rotation and its negation do not cancel. The sum divides by its total weight, with its rotations normalized. With no weight, the rest pose holds. A pose is up to one tick late, as every presented pose is.

## Transitions and fades

- **Order.** A tick tries the current state's own transitions in their order, then those from any state, and takes the first whose conditions all hold. A transition from any state to the current state is skipped.
- **Exit time.** With an exit time, a transition can also be taken only once the state's progress reaches it: 1 is the end of its first play.
- **Events.** Taking a transition raises the old state's exit event, then the new state's enter event.
- **Progress.** The new state starts at progress 0 and moves by the tick that entered it.

What happens to the old state depends on the fade:

| Fade | What plays |
|---|---|
| No `duration` | The old state stops at once. Its samples fade out over the tick, as any sample that is gone does. |
| A `duration`, with no fade under way | The old state becomes the source and plays on as it fades out. |
| A `duration`, while a fade is under way | Every sample that weighs anything freezes where it is, at its weight then, and fades out by what is left of the new fade. There is no source. A frozen sample does not move and raises no event. |

## Blends

A `Blend_1D` state weighs its clips by a float parameter:
- **Between two thresholds**, the two clips blend by how near the parameter is to each.
- **Beyond the first or the last threshold**, that clip plays alone.

The clips stay in step. A play of the blend lasts its clips' durations by their weights, and each clip is at the same share of its own duration. A walk of a second and a run of half a second, halfway between, last 0.75 s, and their feet fall together.

## Events

A tick's events are in `Tick_Output.events`, in the order that they happened, up to `MAX_TICK_EVENTS` (16); past it, `dropped` counts them. Each is a `Fired`: its kind (`Exit`, `Enter` or `Marker`), the state that raised it, and its index into the graph blob's events, with their names and arguments.

**Markers.** Only the current state's heaviest clip raises its markers, the first among equals. A marker is raised in the tick whose interval holds it. The interval runs from after the clip's time before the tick, up to and at its time after:
- **A state that began in the tick** starts its interval at the clip's start, so a marker at 0 is raised.
- **Across a loop's wrap,** the end of the clip and then its start. A tick wraps once at most, so a marker is raised once a tick at most.
- **A clip that holds** reaches its end once, so a marker at its end is raised once.

So a step that two blended clips both mark is raised once. When the heaviest clip changes, a marker near the change can be missed or raised twice. A state that fades out raises nothing after its transition.

## Root motion

With a root joint, which the graph's `root_motion` names, each tick reports:
- **`translation`**: the root's move over the tick, in the model's space turned to the root's heading at the tick's start, along x and z only;
- **`yaw`**: its turn about y, in radians.

Each sample that moved adds its clip's root motion over its step by its share of the weight. Across a wrap, the end of the move and then its start count, turned by the first part's turn, so the root never jumps back. Frozen samples and samples that are gone move nothing.

`remove_root_motion` takes the motion out of a pose before it is composed. The root keeps its rest place along x and z in the model's space, and its rest heading, but keeps its height and tilt. The entity moves instead, if gameplay moves it, so the mesh does not walk away from its entity.

## The ECS

`lib/engine/anim` runs graphs on entities. It copies parameters in and outputs out, and it is the only part that touches the world.

| Component | ID | Fields |
|---|---|---|
| `Animator` | 80 | `graph`, an animation graph; `clip`, a clip that plays without a graph; `speed`, which scales each tick; `loop`, for the clip without a graph; `playing`. The editor shows `state` and `time`, the current state's index and its clip's time. The instance is a field that scenes do not save and the inspector does not show. |
| `Root_Motion` | 81 | Written only by `animate`. `translation` and `yaw` are the last tick's; `frame_translation` and `frame_yaw` are the frame's ticks one after another. An entity with it has the root motion taken out of its pose; one without it keeps the motion in the pose. |

The frame code calls the package around the ticks:

| Call | When | What it does |
|---|---|---|
| `prepare` | Before the ticks | Loads each Animator's graph, its clips and their skin into a table in frame memory, so the system's jobs read no assets. An Animator whose graph's key differs from its instance's starts again in the entry state, with `keep_parameters`, and the warnings the cooker could not give: a root motion joint the skin does not have, and markers past their clips' ends. It starts each `Root_Motion`'s frame from nothing. |
| `begin_frame` | Before the ticks | Clears the frame's events. |
| `animate` | The `Fixed` system | Moves each playing Animator whose graph is ready by `dt` times `speed`, writes its `Root_Motion`, and records its events in its job's buffer. A stopped Animator holds its pose and keeps its triggers. An Animator spawned during the ticks waits for the next `prepare`. |
| `send_events` | After each tick's physics events | Sends the tick's events to behaviours (see [Events in the world](#events-in-the-world)). |
| `present` | At render, after `asset.poll` | Loads the blobs again, since `poll` may have changed them. It poses each Animator whose instance fits its graph's key into a `render.Skin_Pose` for `Frame_Desc.skins`. |

**Gameplay sets parameters, and reads outputs.**
- A `Fixed` system finds a parameter with `parameter(s, animator, name)` and sets it with `set_parameter` or `fire`. It writes `Animator`, so it does not run beside `animate`, and its registration order or `after` says which tick reads the value. The two systems never run at once.
- Scripts' `fixed_update` runs after the `Fixed` systems, so what a script sets is read by the next tick. The root motion of a tick is in `Root_Motion` for that tick's `fixed_update`.
- `root_motion_world(w, e)` turns an entity's last tick of root motion into the world, by the entity's `Transform`. Applying it is gameplay's: move a kinematic body, or a character, by it.

**Hot reload.** The instance is plain data in the component, and the table is remade each frame, so a code reload keeps every Animator's state. A graph's new blob has a new key, so its Animators start again with the parameters that it still has. The system and the job buffer are registrations, made again by `register` in `on_reload`; the system finds the package's state through its `data` (see [World: ECS](../world/ecs.md#systems)).

## Events in the world

- **Recording.** A job of `animate` records its Animators' events in a job buffer. After the tick's `Fixed` systems, the flush takes the buffers in system order, then job order. Within a job, entities are in chunk order. So events never depend on the jobs' timing, and are never ordered by entity handle.
- **Lists.** The flush turns each event into an `Event`: the entity, the kind, the event's name, the state that raised it, and its arguments. Each `Event` owns its strings, which outlive `asset.poll`.
  - `tick_events` are the last tick's, which the next tick's `Fixed` systems see.
  - `frame_events` are every tick's since `begin_frame`, which `Update` and `Late` systems see.
  - A tick that raised nothing makes `tick_events` empty.
- **Scripts.** `send_events` sends each event to its entity's behaviours as `on_animation_event(name, ...)`, with the event's arguments. `script.fixed_events` delivers them in the same tick, after physics's. Each event goes through one handler, so an authored name never meets an engine event's, such as `collision_enter`. `wait_event(entity, "animation_event")` resumes on them too.

