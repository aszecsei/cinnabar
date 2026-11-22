# Tracks

A track acts on the world at the cutscene's time. Its kind says what it writes: a field, a pose, a camera, a sound, an event to the scripts, or the tracks of another cutscene. This document describes the kinds that the engine has, in `lib/engine/cutscene`, and the curve that every keyed track shares. Read [Evaluation](evaluation.md) first, for sections, blending and the restore snapshot.

**In this document:** [Curves](#curves) · [Property tracks](#property-tracks) · [Transform tracks](#transform-tracks) · [Animation tracks](#animation-tracks) · [Camera cut tracks](#camera-cut-tracks) · [Audio tracks](#audio-tracks) · [Event tracks](#event-tracks) · [Sub-sequence tracks](#sub-sequence-tracks) · [Presentation tracks](#presentation-tracks) · [Not built yet](#not-built-yet) · [Procedures](#procedures)

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

- the evaluation crosses a cut of the cutscene's camera cut track ([Camera cut tracks](#camera-cut-tracks)): a section's start that does not blend in from gameplay, or a section's end that cuts back to gameplay. A muted cut track cuts nothing.

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

**Markers.** These are a clip's markers, which raise events. A cutscene's own `marker` blocks are another thing: named points on its time for the editor, which raise nothing ([Content: Cutscenes](../content/kinds/cutscenes.md#markers)). A clip's markers are those that the `Animator`'s graph puts on the clip: the markers of the first of the graph's clips that plays it. A clip that the graph does not play has no markers.
- Only one section raises markers, as the graph raises only its heaviest clip's: of the sections whose span meets the event range, the heaviest at the range's end, or at its own end when it ends first. So the tick that passes a section's end, and the tick at its start where its ease in weighs nothing, still raise its markers.
- A marker is raised when the evaluation's event range `(last, now]`, in the clip's time, holds it. When the section starts in the range, a marker at its offset is raised too. A looping clip raises its markers in each loop that the range passes, up to `MAX_MARKER_LOOPS` (16).
- `anim.raise_marker` puts each one before the tick's own events. It reaches the binding's behaviours as `on_animation_event`, in the same tick.
- A seek, a backwards scrub and a reload raise none, because their range is empty. A skip raises none ([Skipping: Events](skipping.md#events)). Outside a frame, as in the editor's Edit mode, the graph is not ready, and no marker is raised.

**Seek, skip and finish.**
- **Seek and scrub backwards.** The driver shows the pose at the new time at once.
- **Skip.** The pose at the skip's target.
- **When finished.** The driver gives the `Animator` back. With `restore`, the graph resumes where it was. With `keep`, the graph's state stays as it is. Neither holds the last pose after the cutscene. To hand the pose back without a pop, ease the last section out before the end.

`register` sets the animation kind. The game gives the cutscenes the animation's state in `init`. Without it, animation tracks do nothing.

## Camera cut tracks

A camera cut track says which camera the frame is drawn from over each range of time. It cuts between cameras on exact frames, as a film editor does, and it can blend from the gameplay camera into the first shot and back out of the last one. Constraints keep a camera aimed at a binding, or following it, without a key on each frame.

```
binding 3 "Wide Shot"
	spawn = $7fb86acbe194450180b90ee9fb0ecf42
	position = [149999999998, 1.6, -5]
	look_at = 1
track 5 camera_cut "Cuts"
	section 5 0 200000
		camera = 3
		blend_in = 30000 smooth
		focus = 1
	section 6 200000 400000
		camera = 4
		look_at = 1
		look_at_offset = [0, 0.5, 0]
		look_at_damping = 12000
	section 7 400000 600000
		camera = 5
		follow = 1
		follow_offset = [1.5, 1.2, -3]
		blend_out = 60000 smooth
		blend_on_skip = true
```

**The cinematic camera.** A camera binding is an entity with a `Camera` ([Rendering: Components](../rendering/assets.md#components)). A `Cinematic_Camera` beside it gives it a lens in a camera's terms: a focal length, a sensor's width and height, a focus distance and an aperture.
- **The field of view** is `2 × atan(sensor_height / (2 × focal_length))`. While a `Cinematic_Camera` is there, the `cinematic lens` system is the one writer of `Camera.vertical_fov`. It runs in the `Late` stage, after the cutscene's systems and the scripts, so a property track or a script that sets the lens sets the frame's field of view. The views read the lens directly too, so the editor's Edit mode, which runs no systems, shows the same field of view.
- **The depth of field** takes the aperture and the focus ([Post-processing: Depth of field](../rendering/post-processing.md#depth-of-field)). A focus entity sets the focus to its distance along the camera's axis, each frame.
- **Each field** animates with a property track on component 160, as the sample's rack focus does.
- **The sensor's aspect** is the shot's aspect. The editor draws the camera's frustum with it. The presentation track's bars letterbox a frame of another aspect, and can take the aspect of the shot's camera ([Presentation tracks](#presentation-tracks)).

**Sections.** A cutscene has one camera cut track, and the track takes no binding. Each section shows the camera binding that `camera` names.
- **Order.** Sections are in time order and do not overlap. A gap between two sections has no cutscene camera: the view goes back to gameplay.
- **No blending between sections.** A section has a weight of 1, and no eases, rolls, channels or additive blend. Where two sections meet, the frame cuts.
- **Blends with gameplay.** `blend_in = <ticks> [curve]` blends from gameplay into a section that starts the track or follows a gap. `blend_out` blends from a section that ends the track or comes before a gap back to gameplay. The curve is `linear` (the default), `smooth`, `ease_in` or `ease_out`. The camera stack blends the poses and the lens ([World: Cameras](../world/cameras.md)). Without a blend, the frame cuts.

**What it does.** The track evaluates in the `Late` phase. It writes no field. It holds a claim on the game's views ([World: Cameras](../world/cameras.md)) for the section that covers the time:
- **A claim for each section.** When a section starts to show, the track claims the views for its camera, at the player's priority, and releases the claim of the section before. A new claim is a new entry, so the stack cuts, even when two sections show the same camera.
- **A cut** is a frame where the stack does not blend. Its view carries the cut to the renderer, which starts its temporal histories again: temporal AA, the upscaler, motion vectors, exposure and every pass that reprojects a history ([Rendering: Views](../rendering/frame.md#views)). Transform tracks and applied root motion teleport on the tick that crosses a cut ([Transform tracks](#transform-tracks)), so nothing interpolates across it.
- **Gameplay.** Where no section covers the time, the track holds no claim.
- **A camera that is not there.** A section whose binding is missing, or is not a live `Camera`, shows nothing. The player logs it once for the section.
- **No room.** When the views' `MAX_ENTRIES` entries are all taken, the claim fails, and the camera package warns once. The track shows gameplay and claims again at its next evaluation.
- **Several players.** The higher priority's claim shows. At the same priority, the later claim does.
- **Without views.** `init` takes the game's views. Without them, the track claims nothing.

**Constraints.** A section or a camera binding can constrain a camera:

| Setting | What it does |
|---|---|
| `look_at = <binding>`, `look_at_offset = [x, y, z]`, `look_at_damping = <ticks>` | The camera turns so its forward, +z, points at the offset in the target's space. Up stays +y. |
| `follow = <binding>`, `follow_offset = [x, y, z]`, `follow_damping = <ticks>` | The camera keeps the offset in the target's space. |
| `focus = <binding>` | The camera's `Cinematic_Camera` focuses on the target. |

- **Which applies.** A section's constraint applies to its camera while it shows. A binding's constraint applies to the binding as a camera, except where the section that shows it has one of the same kind.
- **Stateless.** Constraints read the time and the bindings' poses only. The damping weight is `1 − e^(−τ / damping)`, where τ is the time since the start of the section that shows the camera. It blends the camera's own pose into the constrained one, so the constraint takes hold over the damping time after a cut. While no section shows the camera, a binding's constraint applies in full. So a seek and playback give the same pose at the same time.
- **Order.** The constraints are a pass at the end of the `Fixed` phase, after every track. They see this tick's poses of their targets, from the targets' `Transform`s, so the camera and its target interpolate together. Follow moves the camera first, and look at aims from there. A look at overrides the rotation of a transform track of the camera, and a follow overrides its position; the other parts stay as the track keys them.
- **Every evaluation.** For each camera that a constraint of the blob names, the pass writes every part that a constraint can write: the constrained value while one applies, and the value that the camera's tracks wrote this tick, or its own value, otherwise. So a camera that a constraint aimed in one shot is at its own pose in a later shot that has no constraint.
- **The snapshot.** The pass writes as the cut track, so the track's `when_finished` restores or keeps the constrained parts.

**Seek, skip and finish.**
- **Seek and scrub backwards.** The section at the new time decides the camera, and the frame is a cut. A seek inside the same section cuts too.
- **Pause.** Nothing changes, and no frame cuts. A blend that runs goes on with the stack's clock.
- **Skip.** A skip to a later time cuts to the section there. A skip that ends the cutscene cuts back to gameplay, or, when the last section has `blend_on_skip = true`, blends out with that section's `blend_out` from whichever shot shows. The last shot is never shown: the skip and the end happen in one update.
- **Hot reload.** A reload releases the claim with a cut, as it ends every hold of the evaluation. The next `Late` evaluation claims the section at the time again, in the same frame, so the frame cuts. A reload that removes or mutes the cut track leaves the view to gameplay.
- **When finished.** The player releases its claim when it ends, so the stack hands the view back: with the last section's blend out when the cutscene ends in it, and with a cut when the player stops or fails. `restore` and `keep` do not apply to the view. The lens fields follow their property tracks' setting.
- **Spawned cameras.** A spawned camera goes as the player ends. A blend out then starts from the view that it showed last.

`register` sets the camera cut kind.

## Audio tracks

An audio track plays sounds on the cutscene's time: dialogue, music and effects that must stay on the frame that the picture is on. Each section plays one sound from a place in it. The track starts the sound at that place, keeps it there as the cutscene plays, and seeks it when the cutscene seeks. It is built on the voices that a caller owns ([Audio: Places and the clock](../audio/design.md#places-and-the-clock)).

```
track 3 audio "Bark"
	binding = 2
	section 3 360000 420000
		asset = $7ce894b4b95e68b918869459e5cd9c93
		bus = 2
		min_distance = 2
		max_distance = 30
track 7 audio "Music"
	section 9 0 720000
		asset = $ac87e25625175689bc0e47ad70107ebe
		bus = 1
		loop = true
		plays_through_skip = true
		ease_out = 120000
		channel gain
			key 0 0.6 auto
			key 200000 1 auto
```

**Sections.** A section names a sound with `asset`. It has a start and an end on the cutscene's time, and an `offset`: the ticks into the sound where the section starts.
- **The place in the sound** at a time *t* is `offset + ∫ pitch`, in seconds, from the section's start to *t*. Without a pitch channel, it is `offset + (t − start)`.
- **Past the sound's end,** a section with `loop = true` starts the sound again from its start. Otherwise the voice ends, and the section is silent to its end.
- **Gain** is the section's weight and its eases ([Sections and blending](evaluation.md#sections-and-blending)), times its `gain` curve, times the track's `gain`.
  - The sections of a track play together where they overlap.
  - Their gains add in the mix. They cross-fade only as their eases say.
- **Pitch** is a curve from `CUTSCENE_MIN_PITCH` (0.1) to `CUTSCENE_MAX_PITCH` (4), the range of `Audio_Source.pitch`. It is the sound's rate, so an audio section has no `speed`.
- **The bus.** `bus` is 0 for Master, and n for the nth of the project's `audio.buses`, as `Audio_Source.bus` is. The player's volume settings for the bus apply.
- **Flat or attached.** A track without a binding plays its sections flat.
  - A track with a binding plays them at the binding's presented pose, heard from the nearest listener.
  - Each section has its own `min_distance` and `max_distance`. They are 1 m and 50 m when the section does not set them.
  - An attached voice is not occluded.
  - A track whose binding is missing plays nothing.
- **Loading.** The player loads every section's sound while it loads, so no frame that starts a sound reads it. A sound that does not load logs once, and its sections play nothing.

**The integral of the pitch.** `curve_integral` integrates the pitch curve exactly, so a seek lands where playback has the voice:
- A constant or a linear segment integrates in closed form.
- A Bezier or an automatic segment integrates by three-point Gauss–Legendre over its parameter. That rule is exact for the segment's polynomial: of degree 3 without weights, and of degree 5, `y(u) × x'(u)`, with them.
- A part of a weighted segment integrates over `[0, u(t)]`, with `u(t)` solved as `curve_value` solves it.
- A Bezier segment whose handles leave the pitch's range can leave the range too. The voice plays the clamped pitch, so the integral clamps too, in `CURVE_CLAMPED_PIECES` (16) pieces. That is close, but not exact.

**The clock and sync.** The track evaluates in the `Late` phase, once a frame, at the time that the frame shows. On the game's clock, that time is the cutscene's time less the part of a tick that presentation is behind it (`1 − alpha` of a tick). So the sounds keep to the picture between ticks.
- **Starts on the frame.** A section that starts within `SEEK_LEAD` (50 ms of audio) of the frame's time starts its voice ahead, at its sound's `offset`, at the time on the audio's clock when the cutscene reaches the section's start. So nothing of the sound's attack is cut, whatever the frame rate. A seek before that time starts it again.
- **The drift check.** Each frame, the track sets each voice's gain and pitch. It then compares where the voice is with where the time puts it (`keep_to_clock`).
  - Past the project's `cutscene.audio_drift`, the track seeks the voice. The limit is 7.5 ms by default: one and a half of the mixer's blocks of 240 frames.
  - Below the limit, the track does nothing, so the normal jitter of a frame does not click.
- **A time scale.** The game gives the cutscenes the rate of its clock each frame: its time scale, or 0 while it is paused. A cutscene on the real clock has a rate of 1. The track's `time_scale` says what its sounds do under a rate other than 1:

| `time_scale` | The voice's rate | The drift check |
|---|---|---|
| `follow` (the default) | The pitch times the rate, so the sound stays on the cutscene's time. A rate under 1 lowers the sound, and a rate over 1 raises it. | Each frame |
| `free` | The pitch. The sound plays at its own rate, and drifts from the cutscene's time. | Not while the rate is not 1. The first frame at a rate of 1 again seeks the voice back, and the next section starts at its place. |

- **A voice that stops** before its section ends, as when the mixer drops it, starts again at its place in the next frame.
- **A rate of 0,** as while the game is paused, stops the voices of a cutscene on the game's clock. When the rate comes back, they start again at their places. A cutscene on the real clock plays on.
- **A pitch that the rate takes out of the range,** such as 0.15 at a rate of 0.5, plays at the clamped pitch. The voice is then faster than the cutscene, and the drift check seeks it often.

**Seek, pause, skip and finish.**
- **Seek and scrub backwards.** A section under the new time seeks its voice there, or starts it there. A section that is not under the new time stops.
- **Pause.** A paused player stops its voices over `STOP_FADE` (30 ms). When it resumes, each section under the time starts again from where it should be.
- **Skip.** As the skip begins, each voice fades out over what is left of the skip's fade out (`skip_fade`), and over at least `STOP_FADE`.
  - A section marked `plays_through_skip`, such as music that runs into gameplay, plays on to its end at its own rate. The track lets its voice go, so the gain and pitch curves no longer apply.
  - The jump starts no section that it passes.
  - After a jump to the end of a skip range, the sections under the time start when play goes on. A section that the track let go does not start again while the time is under it.
- **When finished.** The player stops its voices as it ends.
  - When the cutscene reaches its end, by playback or a skip, a section marked `plays_through_skip` whose end is after the end plays on to its own end. It fades out over its ease out, before that end. So music that runs past the cutscene's `range` plays into gameplay. A stop, a failure or a reset before the end stops it with the others.
  - `restore` and `keep` do not apply to sounds.
- **Hot reload.** A reload stops every voice. The next `Late` evaluation starts each section under the time at its place.

**Scrub.** An evaluation's `audition` says how its audio tracks sound. A player's evaluation is `.Play`. The editor sets the others with `set_audition`, which stops the voices that the tracks hold when the audition changes:

| `audition` | The sections |
|---|---|
| `.Play` | Play voices, which pause with the world, as in the game. |
| `.Preview` | Play voices that play while the world does not run, for the editor's playback in its edit mode. |
| `.Scrub` | Play no voices. After a seek, each section under the time plays a grain through `audio.scrub`: `SCRUB_GRAIN` (40 ms) with fades of `SCRUB_FADE` (5 ms). Each track scrubs at most once in `SCRUB_INTERVAL` (2400 frames, 50 ms). |

`register` sets the audio kind. The game gives the cutscenes its audio in `init`. Without it, audio tracks play nothing.

## Event tracks

An event track tells gameplay what happens in the cutscene: a gate opens, a quest starts, the player gets an item. It keys events on the cutscene's time. Each event has a name and up to four values. It goes to scripts as `script.send` and `script.broadcast` send their events ([Scripting: Events](../scripting/behaviours.md#events)). The track writes nothing to the world itself.

```
track 9 event "Story"
	range 2 360000 420000 guard_bark
	trigger 1 600000 intro_seen
		fire_when_skipped = true
		value = entity 1
```

**Triggers and ranges.**
- A **trigger** is `trigger <id> <time> <name>`. It sends `on_<name>` at its time.
- A **range** is `range <id> <start> <end> <name>`. It sends `on_<name>_begin` at its start and `on_<name>_end` at its end. It is open from its start to just before its end.
- **IDs** are unique among the cutscene's triggers and ranges. The evaluation keeps its open ranges by ID, so a range keeps its state across a reload.
- **Values.** A trigger or a range has up to `MAX_CUTSCENE_EVENT_VALUES` (4) `value` lines. Each value is one of the kinds that script events carry:

| Text | The handler gets |
|---|---|
| `value = number 2.5` | A number |
| `value = bool true` | A boolean |
| `value = string "red"` | A string |
| `value = vector [0, 1, 0]` | A vector |
| `value = entity 1` | The entity of the binding with that ID, or nil when the binding is missing |
| `value = position [1, 2, 3]` | A `WorldPosition`, from meters |
| `value = asset $<guid>` | An asset. The cutscene references it, so the player loads it. |

**The target.**
- A track **with a binding** sends its events to that binding's behaviours, as `script.send` does. The binding must not suspend `behaviours`. A suspended behaviour gets no events, so the cooker refuses this ([Possession: Behaviours](possession.md#behaviours)).
- A track **without a binding** sends its events to every behaviour with the handler, as `script.broadcast` does.
- **Native handlers.** `register_event_handler(state, name, procedure, data)` registers a procedure for one event name, such as `door_open` or `alarm_begin`. The procedure gets the player's handle, the name and the values, in frame memory, beside the behaviours. Call it in `register_world`, after `register`. `register` clears the handlers, so a code reload registers them again.
- **The player's own lifecycle** goes to the bindings' behaviours and the caller's as `on_cutscene_started`, `on_cutscene_finished` and `on_cutscene_failed`, with the cutscene's handle as their first value ([Scripts: Events](scripts.md#events)).

**When events fire.** The track evaluates in the `Fixed` phase. Each evaluation sends what the move from the phase's last time crosses. The tracks record their events, and at the end of the phase `run_phase` queues them on the state:
- In time order.
- At one time, in the tracks' order.
- On one track at one time, an end first, then a trigger, then a begin.

The cutscene fixed system can run in a job, so it calls no script and no handler. `send_events` delivers the queue from the frame code: at the end of `update` and of `advance_real`, in `end_frame`, and in the game after each tick, so `script.fixed_events` delivers the events in the same tick.


| The move | Triggers | Ranges |
|---|---|---|
| **Playback** over (last, now] | Each trigger in the range, once. A frame that crosses many triggers sends them all, so a hitch drops none. | A range that the move enters sends its begin, and a range that it leaves sends its end. A range that it crosses whole sends both. |
| **Seek backwards**, or no move | None | None. The open ranges stay open. The next forward move sends the ends and begins that the seek passed. |
| **Seek forward** | Only the triggers marked `fire_on_seek`, so a script can catch up on state | The ranges that the seek leaves send their ends, and the range that it lands in sends its begin. A range that it crosses whole sends both only when it is marked `fire_on_seek`. |
| **Skip** ([Skipping](skipping.md#events)) | Only the triggers marked `fire_when_skipped`, such as one that gives the player a key | The range that is open at the skip sends its end, and a range that the skip lands in sends its begin. A range that it crosses whole sends both only when it is marked `fire_when_skipped`. |

- **Several seeks** before one evaluation are one move: from the time that the events had fired up to, to the last seek's time.
- **Pairs.** A range sends its end only after it sent its begin. A range opens and closes as its begin and end are queued, and one procedure, `change_range`, changes the open ranges.
- **A handler that ends its player.** A native handler can `stop` its own player. The events queued after it are still delivered, and the ends of the open ranges follow them.
- **Finish.** When the cutscene finishes, each range that is still open sends its end. A cutscene finishes at its end, at a skip to its end, or at a `stop`. A spawned binding is despawned in the same update, before the scripts get the events. So its behaviours get none of the events of that last update, that end included. `restore` and `keep` do not apply: events change state through scripts, which own that state.
- **Failure.** A cutscene that fails sends no more events. Its open ranges do not send their ends.
- **Hot reload.** A reload forgets the open ranges whose IDs are no longer ranges, and sends nothing. The next playback sends the begins and ends that the new blob makes necessary, such as the end of a range that moved away from the time.
- **The editor.** An evaluation whose `audition` is `.Play` sends events, and one whose `audition` is `.Preview` sends them only when the editor's mix lets it ([Evaluation: The editor's mix](evaluation.md#the-editors-mix)). A scrub sends none. `set_audition` forgets the open ranges and does not send their ends, and so does a change of the mix's events.

`register` sets the event kind. The game gives the cutscenes its scripts in `init`. Without the scripts, only the native handlers get events.

## Sub-sequence tracks

A sub-sequence track plays other cutscenes inside this one. Long cinematics are made of shots that different people own: a master cutscene holds one sub-sequence section for each shot, and each shot is an asset of its own. A designer trims, slips and orders the shots in the master without opening them, and one shot plays again with other actors.

```
track 4 sub_sequence "Shots"
	section 4 0 300000
		asset = $497bcb7bb533b902877cd8d56fbf97cd
		bind 1 = 1
	section 5 300000 420000
		asset = $5a1c0f3e2b7d4c6a9e8f1d2c3b4a5968
		trim = 60000 180000
		scale = 1.5
		loop = true
		ease_in = 15000
		bind 1 = 2
```

**Sections.** Each section plays one cutscene, its **child**, over its span of the parent's time. The track takes no binding. Its sections do not overlap, but several sub-sequence tracks can.
- **The trim** is the span of the child's time that the section plays: `[start, end)`, on the child's time. Without it, the section plays the child's whole range. A trim is clamped into the child's range, so a child that a reload shortened still plays.
- **The scale** is the child's time per the parent's time.
- **Loop or hold.** Past the trim's end, the child's time starts the trim again when the section loops. Otherwise it holds at the trim's end.
- **The mapping** is `child_t = trim.start + (t − section.start) × scale`, in whole ticks, wrapped into the trim or held at its end. A time before the section maps to its start, and one after it to its end. `child_time` is the one place that maps a parent's time to a child's: every track of the child evaluates at its time.
- **Weight.** The section's weight, eases and rolls scale the weights of the child's sections, as `sample_section` gives them to every kind. So two shots that overlap on two tracks cross-fade.

**The child's tracks are the parent's.** A child has no lifecycle of its own. The parent's player loads it, and its tracks evaluate with the parent's, at the mapped time:
- **The order.** A child's tracks evaluate in its sub-sequence track's place in the parent's order. A later track wins a field that an earlier one also writes, as in one cutscene.
- **A child whose section does not cover the time** writes the own values of the fields that its tracks hold, as a track writes where no section covers the time. These children evaluate first, before the root's tracks and the children that cover the time, so a shot that plays wins a field over a shot that does not. An actor whose shot is over is at its own place again, until another shot or the parent moves it.
- **A kind** reads its sections with `sample_section(ctx, section, t)`, which gives no section while a sub-sequence section above the track does not cover the time, and scales the weights. It finds a binding's entity with `track_entity` or `ctx_binding`, which follow the child's maps. `section_at` reads a blob alone, without the tree.
- **Scopes.** Each child is a **scope**, named by a hash of the IDs of the sections on its path from the root. The state that an evaluation keeps for a track, a section or an event is keyed by its scope and its ID, so one shot that plays twice is two scopes, and a reload keeps a child's state while its path's IDs stay.
- **Nesting.** A child can play sub-sequences of its own, at most `CUTSCENE_MAX_DEPTH` (8) deep. The times and the weights compose down the path.

**Bindings.** Each section maps the child's bindings to the parent's with `bind <child id> = <parent id>`:
- **A mapped binding** is the parent's binding: its tracks act on the parent's entity, or on nothing when the parent's binding is missing. It suspends nothing of its own: the parent's binding holds the entity.
- **A binding that no line maps** resolves on its own, as at the top level: a possessed entity of a ready scene, or a spawned prefab.
- **Spawned entities** of a child spawn when the parent's player loads, hidden, as the parent's do. They show while the child's section covers the time, and are hidden again outside it, so a shot's prop is there only in its shot. A loop does not spawn them again. They go when the player ends.
- **Kinds.** The cooker refuses a map of a camera to an animated entity, or of an animated entity to a camera, where it can see both in the cutscenes' text ([Content: Cutscenes](../content/kinds/cutscenes.md#sections)).

**Camera cuts.**
- **Which shot shows.** At a time, the parent's camera cut section over the time shows. Where the parent has none, the shot of the last child, in the tree's order, whose section covers the time shows, found the same way in that child. A master without a cut track therefore shows each shot's own cuts, and a master's own section wins over its shots'.
- **Cuts.** A change of shot is a new claim on the views, so the frame cuts where one shot gives way to the next, unless the new section blends in from gameplay. A loop's wrap cuts.
- **Blends** take the parent's time that their ticks take at the scale.
- **Teleports.** Transform tracks teleport on the tick that crosses a cut of any cutscene of the tree, and on the start or end of a section whose child has a cut track.
- **Constraints** of a child apply while its section covers the time, after every track of the tree.
- **A skip to the end** blends out when the last section of the cut track that shows at the end is marked `blend_on_skip`.

**Events.** A child's event tracks send what the parent's move crosses, mapped to the child's time:
- **Order.** The events of the whole tree are sent in time order on the root's time, then in the tree's order.
- **Entering.** A move that enters a section starts just before the trim's start, so an event at the trim's start fires.
- **Loops.** A move that wraps a loop sends each loop's events: the end of one loop, then the start of the next. At most `MAX_WRAPS` (16) loops in one move do. Only the event tracks evaluate the loops before the last: the other tracks evaluate once, at the time.
- **Seek and skip.** A seek's and a skip's moves map the same way. The children's keys marked `fire_on_seek` or `fire_when_skipped` fire as the parent's do, and the open ranges of every child end when the cutscene finishes.

**Other tracks.**
- **Animation.** The animation tracks of the whole tree give each `Animator` their clips, and the evaluation drives it once at the end of the `Fixed` phase, with the heaviest `anim.MAX_DRIVEN` clips. So two shots that drive one actor cross-fade its pose by their sections' weights. The driver holds the graph when any of these tracks restores.
- **Audio.** A child's sounds play at the child's time. The pitch of a `follow` track follows the scale too, and a wrap seeks the voice.

**Loading, reload and the end.**
- **Loading.** The player loads every child, with the assets that it references, and resolves its bindings, before `Ready`. A child that does not load fails the player: `Asset_Failure` names it, and a child's `Binding_Failure` names its cutscene. A cycle, or a nesting past the limit, which the cooker refuses, fails as `Bad_Nesting`.
- **Hot reload.** A child's blob is a reference, not a copy. When a shot is cooked again, every master that plays it evaluates the new shot at its next tick, at the same time ([Evaluation: Hot reload](evaluation.md#hot-reload)). A reload that changes what the children load from, such as a section, a map, or a child's bindings or assets, loads the children again, and their spawned entities spawn again. A map of a binding that the child no longer has is left out, with a warning.
- **Skip.** The parent's skip covers its children: they evaluate at the target through the same jump.
- **When finished.** Each child track keeps its own `restore` or `keep`, and the player restores the fields of the whole tree when it ends.
- **A muted sub-sequence track** plays nothing, and the player does not load its children.

`register` does not set a kind for sub-sequence tracks: `run_phase` walks them.

## Presentation tracks

A presentation track puts what is not in the world over the frame: a fade, letterbox bars, a line of dialogue. It writes nothing to the world. It adds its sections to the evaluation's **presentation**, and the **overlay** shows that presentation.

The fade is from `fox_walk.cutscene`, and the letterbox and the subtitle are from `intro.cutscene`.

```
cutscene 1
length = 720000
skip_fade = 15000
skip_color = "#000000"

track 1 presentation "Fade in"
	section 1 0 60000
		kind = fade
		color = "#000000"
		channel opacity
			key 0 1 linear
			key 60000 0 linear
track 10 presentation "Presentation"
	section 12 0 600000
		kind = letterbox
		ease_in = 30000
		ease_out = 60000
		channel aspect
			key 0 2.39 constant
	section 13 30000 174000
		kind = subtitle
		speaker = "Narrator"
		text = "The fox walks this path every evening."
		key = "intro.narrator.path"
		audio = 10
```

**Sections.** Each section has a `kind`: `fade`, `letterbox` or `subtitle`. A track can hold sections of all three kinds, and takes no binding. Sections blend by their weights ([Sections and blending](evaluation.md#sections-and-blending)).

| Kind | Settings | Channels |
|---|---|---|
| `fade` | `color`: a quoted `"#rrggbb"` or `"#rgb"`, opaque | `opacity`, from 0 to 1 |
| `letterbox` | None | `aspect`, from 1 to 4, and `amount`, from 0 to 1 |
| `subtitle` | `speaker`, `text` (needed), `key` and `audio` | None |

- **Fades.** A fade covers the frame with its color. A section without an `opacity` channel has an opacity of 1. The fades of the sections that cover the time give one color and one opacity:
  - The opacity is the sections' opacities, blended by their weights over 0.
  - The color is the mean of the sections' colors in linear light, weighted by each section's weight times its opacity.
- **Letterbox.** The bars crop the frame to the `aspect`, width over height, 2.39 by default. `amount` is how far the bars are in: 1 by default, and 0 is no bars. The sections' aspects and amounts blend by their weights, so an ease slides the bars in and out.
  - An aspect wider than the window's gives bars at the top and the bottom. A narrower one gives bars at the sides.
  - The bars crop the frame in the overlay. They do not change the render's size.
  - The bars are black, or the project's `cutscene.letterbox_color` ([Overview: Project settings](../overview/architecture.md#project-settings)).
  - `letterbox_aspect = camera` on the track sets `Follow_Camera`. While the cut track shows a camera with a `Cinematic_Camera`, the bars take that camera's aspect (`render.camera_aspect`), so each shot fills its frame. While gameplay shows, they take the sections' aspect. `letterbox_aspect = sections` (the default) always takes the sections'.
- **Subtitles.** A subtitle section shows its `text` for its span, under its `speaker`.
  - `key` is the key of the line in a string table. The cook keeps it in the blob. The runtime shows `text` and does not read the key yet.
  - `audio` is the ID of a section of an audio track. It does not change the runtime. The editor moves the subtitle with that sound.
  - At most `MAX_SUBTITLES` (3) lines show: the newest that cover the time, with the newest at the bottom. A fourth newer line drops the oldest.
  - A line's text binds to its element as `Ui.bind` binds: with `set_binding`.

**The track's time.** The track evaluates in the `Late` phase, once a frame, at the time that the frame shows (`shown_time`), as an audio track does ([Audio tracks](#audio-tracks)). A pause or a time scale holds or moves the fade with the cutscene's time, and the UI runs on real time. `run_phase` clears `Evaluation.presented` before the `Late` phase, so each frame's presentation is a value of the time alone ([Evaluation: The evaluation](evaluation.md#the-evaluation)).

**Sub-sequences.** A presentation track of a child adds to the presentation by its section's weight, at the child's own time ([Sub-sequence tracks](#sub-sequence-tracks)).

**The overlay.** The overlay is a UI document that the cutscene state owns, with no entity ([UI: Owned documents](../ui/design.md#owned-documents)). The engine's is `cutscene_overlay.ui`, in the engine content root.
- **Order.** `OVERLAY_ORDER` is 8. The overlay draws over the gameplay documents (order 0, and 5 for the split-screen help) and under the sample's pause menu (order 10).
- **No input.** The overlay takes no input.
- **A project's own document.** The project setting `cutscene.overlay` names a UI document by its `$<guid>`. A zero, or no setting, means the engine's. The document needs elements with the ids below. `update` opens the new document when the setting changes.

| Element | What `present` sets |
|---|---|
| `fade` | `fill` to the fade's color, as a paint, and `opacity` |
| `bar_top`, `bar_bottom` | `height`, in percent of the window, and `fill` to the bars' color |
| `bar_left`, `bar_right` | `width`, in percent of the window, and `fill` to the bars' color |
| `subtitle_1` to `subtitle_3` | `visible`, true for a line that shows |
| `speaker_n` | `visible`, true when the speaker is not empty; `size`; and its binding `{speaker_n}` |
| `line_n` | `size`, and its binding `{line_n}` |
| `subtitle_back_n` | `opacity`, the player's `subtitles.background` |

- **The text's size.** `size` of `speaker_n` and `line_n` is the document's own size for the element times the player's `subtitles.size`. An element without a size of its own takes `DEFAULT_SPEAKER_SIZE` (22) or `DEFAULT_LINE_SIZE` (30).
- **The frame.** The game calls `cutscene.present(state, world, window)` in `render_frame`, after the `Late` stage and before `ui.layout`. It hides the document when nothing shows. `present` does nothing when the state has no UI or the document is not built.
- **The UI.** The game gives the cutscenes its UI in `init`, as the last, optional parameter, `interface: ^ui.State`. Without it, nothing shows the presentation tracks.

**Who drives the overlay.** The overlay shows one player's presentation. A player drives it when it is `Playing`, `Paused`, `Skipping` or `Finishing`, and has a presentation track, or a skip's fade that covers the frame.
- Of those players, the highest priority drives it, and of equal priority, the latest to start, as for a field ([Player: Conflicts](player.md#conflicts)).
- Only the values of that player show.
- A new driver ends what the overlay holds of an earlier one (see When finished, below).

**Seek, skip and finish.**
- **Seek and scrub backwards.** Each value is the value at the new time. Each line that covers the time shows under it.
- **Skip.** The skip's fade draws over the track's fade, in the blob's `skip_color` (the cutscene's `skip_color = "#rrggbb"`, black by default). The subtitles hide for the whole skip, its fade in included.
  - A skip to the end gives the world back while the fade covers the frame. The overlay then fades back from the skip's color, over `skip_fade`, on real time, over gameplay ([Skipping: The state](skipping.md#the-state)).
  - A `stop` during a skip's fade fades back from the coverage that the fade had (`Player_Finishing.cover`).
  - A cutscene without a presentation track still shows its skip's fade.
- **When finished.** When the player gives the world back, `hand_off_overlay` decides what the overlay holds, in this order:
  1. A fade whose track is `keep`, and that covers the frame, stays as `Overlay_Kept`. It stays across a level load (`reset`) too. A kept fade wins over the skip's fade back.
  2. Else, after a skip's fade that covered the frame, the overlay fades back from the skip's color (`Overlay_Fading`).
  3. Else the overlay hides. A track that restores (the default) leaves nothing. A player that fails hands off nothing.
- **Releasing a kept fade.** `release_fade(state, length)` fades a kept fade back, over a length of real time. A length of 0 clears it. Another cutscene that drives the overlay also ends it.
- **Destroy.** `destroy`, for a soft restart, closes the document.

**The player's settings.** The settings are in the user's file, by the player's choice. The game takes them when the files change, so `Subtitles.set` holds between changes.

| Setting | Values | Default | What it sets |
|---|---|---|---|
| `subtitles.enabled` | `true` or `false` | `true` | Whether subtitles show |
| `subtitles.size` | From 0.5 to 2 | 1 | A scale of the text's size |
| `subtitles.background` | From 0 to 1 | 0.5 | The opacity of the box behind each line |

Scripts read and change them with the `Subtitles` library ([Scripting: Subtitles](../scripting/api.md#subtitles)). `set_subtitles` clamps a value into its range.

**Hot reload.** `Presentation.key` holds the key of the evaluation's tree of blobs when the tracks made the presentation. After a reload of a blob of the tree, `presentation_values` does not read the subtitle rows, which moved, until the next `Late` phase makes the presentation again.

`register` sets the presentation kind. Without the cutscenes' UI, the tracks evaluate and nothing shows.

## Not built yet

- Fields blend track by track: each track blends its sections over the field's own value, and the later track wins. So two shots that overlap cross-fade an `Animator`'s pose, but a transform or a property that both write takes the later shot's value at its weight over the own value, not over the other shot's.
- The cutscene editor's preview sets `audition`: `.Preview` while it plays and `.Scrub` while it is scrubbed (see [Cutscene editor: Preview](../editor/cutscene-editor.md#preview)). Its waveforms are [#556](https://github.com/aszecsei/cinnabar/issues/556).
- In the editor, only the Game view follows the cut track. A viewport that pilots a camera waits for [#555](https://github.com/aszecsei/cinnabar/issues/555).

## Procedures

| Procedure | What it does |
|---|---|
| `sample_section(ctx, section, t)` | A section's local time and weight at a time on its track's cutscene's time, or false: none while a sub-sequence section above it does not cover the time, and each weight scaled by theirs |
| `ctx_binding(ctx, index)` | The entity of a binding of the track's cutscene, through a sub-sequence's maps |
| `child_time(section, trim, t)` | A parent's time on the child's time of a sub-sequence section, and how many loops it wrapped |
| `trim_of(section, child)` | A sub-sequence section's trim, clamped into its child's range |
| `child_range(section, trim, from, to)` | A parent's event range on a child's time, a segment for each loop |
| `curve_value(keys, t, hint)` | A curve's value at a time in ticks from its section's start |

| `curve_step(keys, t, hint)` | A curve's value as if every key were constant |
| `property_track(ctx)` | The property kind's evaluate procedure |
| `transform_track(ctx)` | The transform kind's evaluate procedure |
| `animation_track(ctx)` | The animation kind's evaluate procedure |
| `camera_cut_track(ctx)` | The camera cut kind's evaluate procedure |
| `audio_track(ctx)` | The audio kind's evaluate procedure |
| `presentation_track(ctx)` | The presentation kind's evaluate procedure |
| `present(state, world, window)` | Writes what the overlay shows into its document, for a window's size in pixels. The game calls it each frame, after the `Late` stage and before `ui.layout`. |
| `presentation_values(state, world, evaluation)` | What an evaluation's presentation shows: the fade's color and opacity, the letterbox's aspect and amount, and the subtitles' lines |
| `release_fade(state, length)` | Fades back a fade that a track kept over the frame, over a length of real time. 0 clears it. |
| `set_subtitles(state, settings)` | Sets the player's subtitle settings, clamped into their ranges |
| `subtitles(state)` | The player's subtitle settings |
| `set_overlay(state, document, letterbox)` | Sets the project's overlay document, zero for the engine's, and the bars' color, from `cutscene.overlay` and `cutscene.letterbox_color` |
| `overlay_frame(state, world)` | What the overlay shows now: the driver's presentation with its skip's fade over it, or what the overlay holds |
| `skip_fade(state, handle)` | How much a skipping player's fade covers the frame (see [Skipping](skipping.md#the-state)) |
| `register_event_handler(state, name, procedure, data)` | Registers a native handler of the events of one name, from every cutscene |
| `send_events(state)` | Delivers the queued events of the event tracks to the scripts and the native handlers. Call it from the frame code. |
| `curve_integral(keys, t)` | A curve's integral from 0 to a time in ticks, in value × seconds |
| `sound_place(data, blob, section, t, length)` | Where an audio section's sound is at a time, in seconds, and whether that is inside the sound |
| `set_audition(evaluation, audition)` | Sets how an evaluation's audio tracks sound, and whether its event tracks send events. A change stops the voices and forgets the open ranges. |
| `set_rate(state, rate)` | Sets the game clock's rate against real time. The game sets it each frame. |
| `set_audio_drift(state, seconds)` | Sets the drift limit, from the project's `cutscene.audio_drift` |
| `end_cut(evaluation)` | Releases the cut track's claim on the views, with the blend that its shot leaves with. `restore`, `restore_all`, a reload and `destroy_evaluation` call it, through the one `end_holds`. |
| `settle_pose(world, entity, teleport)` | Composes a child's `Transform` from what a track or a restore wrote. With `teleport`, also sets the `Previous_Transform` of the entity and of every entity under it. |
| `pose_channel(name)` | A transform channel's place in the pose |
