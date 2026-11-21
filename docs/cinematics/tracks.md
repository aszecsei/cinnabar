# Tracks

A track acts on the world at the cutscene's time. Its kind says what it writes: a field, a pose, a camera, a sound. This document describes the kinds that the engine has, in `lib/engine/cutscene`, and the curve that every keyed track shares. Read [Evaluation](evaluation.md) first, for sections, blending and the restore snapshot.

**In this document:** [Curves](#curves) · [Property tracks](#property-tracks) · [Transform tracks](#transform-tracks) · [Animation tracks](#animation-tracks) · [Not built yet](#not-built-yet) · [Procedures](#procedures)

## Curves

A channel of a section is a **curve**: keys in rising time, each with a time in ticks from the section's start, a value and an interpolation to the next key. Every keyed track uses this one curve and its one evaluator, `curve_value` (`curve.odin`).

| Interpolation | From the key to the next |
|---|---|
| `Constant` | The key's value holds. |
| `Linear` | A straight line. |
| `Bezier` | A curve from the key's out tangent to the next key's in tangent. |
| `Auto` | A Bezier curve whose tangents the evaluator computes from the neighbouring keys. |

- **Holds.** Before the first key and after the last, the curve holds that key's value. At a key's time, the value is the key's value, exactly. Cycle and linear extrapolation can come later.
- **Tangents.** Only a `Bezier` key has tangents of its own. A tangent is a **slope**, in value per second, and a **weight**.
  - The key's out tangent shapes the segment after it, and its in tangent the segment before it.
  - A key that is not a `Bezier` key, next to a Bezier segment, gives that segment its automatic tangent.
- **Broken or unified.** A key's two slopes are one (unified) unless the key is **broken**. The editor moves unified handles together. The flag does not change the evaluation.
- **Weights.** The weight of a handle is the part of the segment's duration that it reaches, from 0 to 1.
  - A key that is not **weighted** has weights of 1/3 (`CUTSCENE_TANGENT_WEIGHT`). Then the segment is a cubic Hermite curve, and its time is linear in its parameter.
  - A weighted handle makes the evaluator solve the parameter at the time. Weights from 0 to 1 keep the handles in the segment, so the curve is a function of the time.
- **Auto tangents** do not overshoot:
  - The first and the last key are flat.
  - A key that is a peak or a trough, or level with a neighbour, is flat. So keys of one value hold that value between them.
  - Otherwise the slope is that of the line through the neighbours, limited to three times the gentler of the two segments' slopes. This is the condition of Fritsch and Carlson for a monotone cubic, so the curve stays between the keys' values.
- **Steps.** `curve_step` evaluates a curve as if each key were `Constant`. A field that cannot take a value between two keys, such as an integer, steps.
- **Vectors and colors** are one curve for each number, so the curve editor ([#553](https://github.com/aszecsei/cinnabar/issues/553)) edits them one at a time.

**Exact and shared.** The evaluator is a pure procedure of the keys and a time.
- It never bakes, so a value at any tick is exact.
- It finds the segment by halves. The `hint` from the last call finds it at once in playback, and never changes the value.
- Its arithmetic is `f64` `+ - * /` in a fixed order. A weighted segment's solve takes a fixed number of halvings (`CURVE_SOLVE_STEPS`, 48), not a tolerance.
- `lib/engine/cutscene/testdata/curve.txt` holds a shared test curve and its value at every 250 ticks, as `f32` bits. The runtime's test reads it, and the editor's evaluator must give the same bits ([#553](https://github.com/aszecsei/cinnabar/issues/553)). Run the cutscene tests with `CINNABAR_WRITE_CURVE_GOLDEN=1` to write it again after a deliberate change.

The text of a key is in [Content: Cutscenes](../content/kinds/cutscenes.md#channels-and-keys). The cooker checks that keys are in order, that numbers are finite, and that weights are from 0 to 1.

## Property tracks

A property track animates one field of one component on its binding, as the inspector edits it: a light's intensity, a material parameter, a volume's weight. It names the field by its component's **stable ID** and the `format.scene_field_hash` of its dotted name, as scenes and scene links do, so a cooked cutscene outlives any one build.

```
track 3 property "Lamp"
	binding = 1
	component = 9101
	field = "light.intensity"
	section 4 0 60000
		channel value
			key 0 0 auto
			key 30000 5 auto
```

**Resolving the field.** The first evaluation of the track resolves the field with `scene.component_fields`. The evaluation keeps the result, a `Property_Target` with the field's offset, size and kind, by the track's ID.
- A hot reload of the blob forgets the results.
- A new layout of the component, after a code reload, resolves the field again.
- A field that the track cannot animate is a **problem**. The track does nothing, and the player logs the problem once for the load.

The problems are:
- no component with the ID, or no field with the name that the inspector shows;
- a read-only field (`editor:"read"`) or a hidden one (`editor:"-"`);
- a field of a kind that cannot animate: `Entity`, `World_Position`, `f64`, or a `quaternion128`, which the transform track animates;
- a channel that the field does not take, or keys of assets for a field that is not an asset, or numbers for one that is;
- a bool's key that is not 0 or 1, an enum's key that is not one of its values, or an integer's key that is not a whole number;
- an additive section on a bool, an enum or an asset.

The cooker cannot see these, because native components exist only in the game's code. It checks only what the text says ([Content: Cutscenes](../content/kinds/cutscenes.md#tracks)).

**Kinds and channels:**

| Field | Channels | Evaluates |
|---|---|---|
| `f32` | `value` | The curve |
| `[2]f32` | `x` and `y`, or `r` and `g` | The curve, for each number |
| `[3]f32`, a color among them | `x`, `y` and `z`, or `r`, `g` and `b` | The curve, for each number |
| Integers | `value` | Steps. A value outside the integer's range is clamped. |
| `bool` | `value`, keys 0 or 1 | Steps |
| Enums | `value`, keys of the enum's values as numbers | Steps |
| Asset GUIDs | `value`, keys of `$<guid>` | Steps. Nothing checks the asset's kind against the field's `asset:` tag yet. |

A section keys any of a vector's numbers. A number that no section keys keeps its own value. Keys are `f32`, so integers are exact up to 2^24.

**Blending.** The track writes the whole field once in each evaluation, through `write_field`. So the snapshot saves the whole field, and a conflict between two players compares the same field ([Player: Conflicts](player.md#conflicts)).
- **Numbers and vectors** blend each number by the sections' weights over the field's own value, as [Sections and blending](evaluation.md#sections-and-blending) describes.
- **Additive sections** then add their values, by their weights. So a sway or a flicker layers over the sections below it, or over the value from before the cutscene.
- **Stepped fields** take the value of the absolute section with the most weight, the later one in the track among equals. The field's own value counts as one more contender, with the weight that the sections leave (1 − the sum of their weights). So an easing-in section takes a bool over halfway through its ease. Additive sections add their values to an integer, by their weights and rounded.
- **Where no section covers the time,** the track writes the field's own value.
- **A volume's setting** ([World: Volumes](../world/volumes.md#volumes)) also takes its override flag while a section covers the time, as a scene that sets the setting does. Otherwise the flag is its own value.

**Seek, skip and finish.**
- **Seek and scrub backwards.** The value is a function of the time, so a seek writes the value at the new time, whatever the path.
- **Skip.** A skip evaluates its target once ([Skipping](skipping.md#the-state)), so the field takes its value there.
- **When finished.** `restore` (the default) writes back the field's value from before the cutscene first wrote it. `keep` leaves the last value. The snapshot keeps only the fields that a track writes ([The restore snapshot](evaluation.md#the-restore-snapshot)).

`register` sets the property kind. A game can replace it with `register_kind` after `register`.

## Transform tracks

A transform track keys where its binding is, how it faces and its scale: a character that walks to a mark, a door that swings, a ship that flies past.

```
track 1 transform "Fox walks"
	binding = 1
	when_finished = keep
	section 1 0 120000
		ease_in = 15000
		channel position_z
			key 0 0 linear
			key 120000 4 linear
		channel rotation_y
			key 0 0 auto
			key 60000 90 auto teleport
```

**Channels.** A section keys any of nine channels, each a curve:

| Channels | Value |
|---|---|
| `position_x`, `position_y`, `position_z` | Meters from the track's space (see below), as `f32` |
| `rotation_x`, `rotation_y`, `rotation_z` | Euler angles in degrees, in the scripts' order: z, then x, then y (`script.quaternion_euler`). A key can spin past 180°. The track turns them into a `quaternion128` after it evaluates them. |
| `scale_x`, `scale_y`, `scale_z` | The scale of the field that the track writes |

- **Parts.** Position, rotation and scale are each one field of the pose. The track writes a part at every time when any of its sections keys one of the part's channels. It never writes the other parts, so the snapshot saves and restores only what the track moves.
- **A channel without keys** leaves its number of the pose: the binding's own value, in the track's space. So a section that keys only `rotation_y` takes x and z from the binding's own rotation.

**Spaces.** The track's `space` says what the position and the rotation are from:

| Space | From | For |
|---|---|---|
| `relative` (the default) | The binding's own pose, as it was before the cutscene first wrote it, which the [snapshot](evaluation.md#the-restore-snapshot) holds. Its rotation turns the keyed offsets. | A cutscene that plays wherever the player triggers it |
| `absolute` | The track's `origin`, a `World_Position`, with no rotation. The editor sets the origin where the designer first keys, so the keys stay small numbers far from the world's origin. | Marks in a level |
| `relative <binding>` | Another binding's `Transform` at each evaluation | An entity that rides a moving ship |

- **Precision.** The keys are `f32` offsets from the origin. The track adds them to the origin once, with `ecs.position_offset`, so 2^30 m from the world's origin a position is as exact as its offset. In an absolute space, an axis that no section covers keeps its own value to the unit.
- **Relative to another binding.** The channels without keys hold the binding's own pose in the other binding's space. The track's first evaluation takes it from both bindings' own poses, and `Evaluation.spaces` keeps it. A hot reload keeps it while the track still joins the same two bindings, by their IDs, because the snapshot still holds the own poses that it came from. So an entity that keys only its height rides the ship where it stood on it.
- **Order.** Before a track relative to another binding evaluates, it evaluates the transform tracks of that binding. So it sees the other binding's pose at this time, whatever the order of the tracks. A track that runs twice writes the same values.
- **The other binding's pose** is its `Transform`, not its presented pose: in the `Fixed` phase, `Transform` is the pose at this tick, so the two entities interpolate together.
- **Cycles.** A binding that is relative to itself, through the tracks relative to other bindings, is a problem. The cooker reports it with the path, such as `relative bindings form a cycle: Fox -> Ship -> Fox`. Two bindings that resolve to one entity can make a cycle that the cooker cannot see. The track's first evaluation finds it: the track does nothing, and the player logs it once for the blob.

**Roots and children.**
- For a root, the track writes `Transform`.
- For a child (an entity with a `Parent` and a `Local_Transform`), it writes `Local_Transform`, and propagation turns it into `Transform`.
  - In a relative space, the keys are in the parent's space, from the child's own `Local_Transform`.
  - In an absolute space, or relative to another binding, the track computes the pose in the world. It then turns the pose into the parent's space with the parent's `Transform`, the inverse of `ecs.compose`.
- After it writes a child, the track composes the child's `Transform` at once, so a track relative to the child sees it in the same tick.

**Blending.** Sections blend each channel by their weights over the binding's own pose in the track's space ([Sections and blending](evaluation.md#sections-and-blending)).
- **Positions and scales** blend linearly, each number on its own.
- **Rotations** blend as animation's poses do. Each section's rotation joins a sum, on the sum's side, by its weight. Below a weight of 1, the own rotation takes what the weights leave. The sum is then normalized.
- **Additive sections** then add their offsets and their rotations, by their weights, so a shake or a sway layers over a path. An additive scale multiplies, by `1 + (value − 1) × weight`.
- **Into and out of the cutscene.** The own pose is the base, so the first section's ease in blends from the pose before the cutscene, and the last section's ease out blends back to it.
- **Where no section covers the time,** the track writes the binding's own value of each part that it holds.
- Two transform tracks of one binding that key the same part both write it, and the later one in the cutscene wins. Layer motion with additive sections in one track.

**Interpolation and teleports.** Presentation interpolates from `Previous_Transform` to `Transform` by the clock's `alpha`, so continuous motion stays smooth at any frame rate. A **teleport** moves the entity at once: the track sets `Previous_Transform` to the new pose, for the entity and every entity under it, whose `Transform`s it composes. The track teleports when:
- the evaluation crosses a key marked `teleport`, of any channel of the track;
- the evaluation does not move forward from the phase's last one: a seek, a backwards scrub and a hot reload, and also a pause or a skip's fade, where it changes nothing;
- it is the phase's first evaluation, as the cutscene starts;
- it is a skip's jump;
- the cutscene is on the real clock ([The order in the frame](evaluation.md#the-order-in-the-frame)).

A camera cut will mark its frame as a cut, and transform tracks will teleport on it too ([#542](https://github.com/aszecsei/cinnabar/issues/542)).

**Seek, skip and finish.**
- **Seek and scrub backwards.** The pose is a function of the time, and the track teleports to it.
- **Skip.** The track teleports to the pose at the skip's target.
- **When finished.** `restore` (the default) teleports the binding back to its pose before the cutscene: a pose that the snapshot puts back moves at once, with what is under it. `keep` leaves it where the cutscene put it, which a character who walks into the next room needs.
- **Physics.** A possessed entity with a rigid body is kinematic while the cutscene holds it ([Possession](possession.md)). The track does not change bodies.

`register` sets the transform kind.

## Animation tracks

An animation track plays clips on its binding's `Animator`: a sit, a gesture, a line of dialogue's body language. It drives the `Animator` through its driver ([Animation: Driving an Animator](../animation/design.md#driving-an-animator)). So the clip's time comes from the cutscene's time, not from the `Animator`'s ticks, and scrubs, seeks and skips show the right pose at once.

```
track 2 animation "Fox acts"
	binding = 1
	section 1 0 120000
		asset = $dea303d3f0374a9e56b0bb58f4a85315
		ease_in = 15000
		ease_out = 15000
		loop = true
		root_motion = in_place
	section 2 90000 180000
		asset = $c51ce410c124a10e0db5e4b97fc2af39
		offset = 30000
		speed = 0.5
		ease_in = 30000
```

**Sections.** A section names a clip with `asset`. The clip's skin must be the skin of the `Animator`'s graph. The driver leaves out a clip of another skin.
- **Time in the clip.** At a time *t*, the clip's time is `offset + (t − start) × speed`, in seconds. `offset` is the ticks into the clip where the section starts. `speed` is the clip's time per the cutscene's time.
- **Past the clip's end.** A section with `loop = true` starts the clip again from its start. Otherwise it holds the clip's last pose.
- **Weight.** The section's weight, ease in and ease out set the clip's weight ([Sections and blending](evaluation.md#sections-and-blending)). Animation sections cannot be additive.
- **One track for each binding.** The cooker reports a second animation track on one binding. Put the clips of one binding in the sections of one track.

**What it writes.** The track writes only the driver's input: up to `MAX_DRIVEN` (2) clips, each with its time and its weight. It never writes joints. The driver presents the pose.
- **Overlaps.** Where sections overlap, the clips blend by their weights. Past two, the lightest clips drop. Among equals, the later section in the track drops.
- **Over the graph.** The clips' weights blend their pose over the pose of the `Animator`'s graph. Where no section covers the time, the weight is 0. So the first section's ease in blends from the gameplay animation, and the last section's ease out blends back to it.
- **A function of the time.** The pose at *t* depends only on *t*. Nothing depends on how the `Animator` ticked before.
- **Not loaded.** The track leaves out a clip that is not loaded. A player loads every clip that the cutscene names before it plays.

**The driver's hold.** The track takes the `Animator` with `begin_drive` when one of its sections first covers the time. It keeps the token in `Evaluation.drives`, by entity, until the cutscene ends.
- **`restore`** (the default) takes it with `hold`. The graph's time stops while the cutscene holds the `Animator`, so after the cutscene the graph resumes where it was. Before the first section, the graph plays, so an idle does not freeze before the track uses it.
- **`keep`** takes it without `hold`. The graph plays on under the clips, and the cutscene leaves the graph's state as it is.
- The graph keeps its parameters and triggers while the driver overrides it.
- **Another driver.** When another driver takes the `Animator`, such as a player that started later, the track takes it back at its next evaluation. So the later of two players wins it, as it wins a field ([Player: Conflicts](player.md#conflicts)).
- **The end.** `restore` and `restore_all` end every hold with `end_drive`, and the graph's pose shows again. A hot reload ends them too. The tracks of the new blob then take their `Animator`s again as they evaluate.

**Root motion.** Each section's `root_motion` says what it does with its clip's root motion:

| `root_motion` | The pose | The entity |
|---|---|---|
| `bake` (the default) | The root moves in the mesh. | A transform track places it. |
| `apply` | The clip plays in place. | The track moves it by the clip's root motion, from the section's start. |
| `in_place` | The clip plays in place. | The clip does not move it. A transform track can move it, as the sample's walking fox does. |

- **Apply** sums the root motion of every `apply` section, from the start of the first one to *t*, or to the end of the last one. It sums steps of `ROOT_MOTION_STEP` (1/60 s) on a grid from the cutscene's 0. The sections' weights at the middle of a step weight that step's motion. So a seek gives the same place as playback, and an ease out slows the walk to a stop.
- **The pose that it writes** is the binding's own pose, moved by the sum and turned about y by the sum of the turns. The own rotation turns the sum, and the own scale scales it, as gameplay applies `Root_Motion`. The track writes the position and the rotation of a root's `Transform` or a child's `Local_Transform` in every evaluation. It teleports as a transform track does ([Transform tracks](#transform-tracks)).
- **After the section**, the entity stays where the walk ended, because the sum keeps the section's whole motion. `restore` puts the entity back. `keep` leaves it there.
- **The root joint** is the graph's root motion joint. Without a graph, or without a root motion joint, `apply` moves nothing.
- A transform track that keys the position or the rotation of the same binding also writes them. The later track in the cutscene wins.

**Markers.** A clip's markers are those that the `Animator`'s graph puts on the clip: the markers of the first of the graph's clips that plays it. A clip that the graph does not play has no markers.
- Only one section raises markers, as the graph raises only its heaviest clip's: of the sections whose span meets the event range, the heaviest at the range's end, or at its own end when it ends first. So the tick that passes a section's end, and the tick at its start where its ease in weighs nothing, still raise its markers.
- A marker is raised when the evaluation's event range `(last, now]`, in the clip's time, holds it. When the section starts in the range, a marker at its offset is raised too. A looping clip raises its markers in each loop that the range passes, up to `MAX_MARKER_LOOPS` (16).
- `anim.raise_marker` puts each one before the tick's own events. It reaches the binding's behaviours as `on_animation_event`, in the same tick.
- A seek, a backwards scrub and a reload raise none, because their range is empty. A skip raises none ([Skipping: Events](skipping.md#events)). Outside a frame, as in the editor's Edit mode, the graph is not ready, and no marker is raised.

**Seek, skip and finish.**
- **Seek and scrub backwards.** The driver shows the pose at the new time at once.
- **Skip.** The pose at the skip's target.
- **When finished.** The driver gives the `Animator` back. With `restore`, the graph resumes where it was. With `keep`, the graph's state stays as it is. Neither holds the last pose after the cutscene. To hand the pose back without a pop, ease the last section out before the end.

`register` sets the animation kind. The game gives the cutscenes the animation's state in `init`. Without it, animation tracks do nothing.

## Not built yet

The other kinds of track are parts of [#526](https://github.com/aszecsei/cinnabar/issues/526): camera cuts ([#542](https://github.com/aszecsei/cinnabar/issues/542)), audio ([#543](https://github.com/aszecsei/cinnabar/issues/543)), events ([#544](https://github.com/aszecsei/cinnabar/issues/544)), sub-sequences ([#545](https://github.com/aszecsei/cinnabar/issues/545)) and presentation ([#546](https://github.com/aszecsei/cinnabar/issues/546)). Until they are built, a track of one of these kinds does nothing.

## Procedures

| Procedure | What it does |
|---|---|
| `curve_value(keys, t, hint)` | A curve's value at a time in ticks from its section's start |
| `curve_step(keys, t, hint)` | A curve's value as if every key were constant |
| `property_track(ctx)` | The property kind's evaluate procedure |
| `transform_track(ctx)` | The transform kind's evaluate procedure |
| `animation_track(ctx)` | The animation kind's evaluate procedure |
| `settle_pose(world, entity, teleport)` | Composes a child's `Transform` from what a track or a restore wrote. With `teleport`, also sets the `Previous_Transform` of the entity and of every entity under it. |
| `pose_channel(name)` | A transform channel's place in the pose |
