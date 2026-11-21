# Tracks

A track acts on the world at the cutscene's time. Its kind says what it writes: a field, a pose, a camera, a sound, or an event to the scripts. This document describes the kinds that the engine has, in `lib/engine/cutscene`, and the curve that every keyed track shares. Read [Evaluation](evaluation.md) first, for sections, blending and the restore snapshot.

**In this document:** [Curves](#curves) · [Property tracks](#property-tracks) · [Transform tracks](#transform-tracks) · [Animation tracks](#animation-tracks) · [Camera cut tracks](#camera-cut-tracks) · [Audio tracks](#audio-tracks) · [Event tracks](#event-tracks) · [Not built yet](#not-built-yet) · [Procedures](#procedures)

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
- **The sensor's aspect** is the shot's aspect. The editor draws the camera's frustum with it. The presentation track's bars will letterbox a frame of another aspect ([#546](https://github.com/aszecsei/cinnabar/issues/546)).

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
- The cutscene's own script handlers, with the cutscene's handle as their first value, come with the scripting library ([#547](https://github.com/aszecsei/cinnabar/issues/547)).

**When events fire.** The track evaluates in the `Fixed` phase, so `script.fixed_events` delivers its events in the same tick. Each evaluation sends what the move from the phase's last time crosses. The tracks record their events, and `run_phase` sends them at the end of the phase:
- In time order.
- At one time, in the tracks' order.
- On one track at one time, an end first, then a trigger, then a begin.

| The move | Triggers | Ranges |
|---|---|---|
| **Playback** over (last, now] | Each trigger in the range, once. A frame that crosses many triggers sends them all, so a hitch drops none. | A range that the move enters sends its begin, and a range that it leaves sends its end. A range that it crosses whole sends both. |
| **Seek backwards**, or no move | None | None. The open ranges stay open. The next forward move sends the ends and begins that the seek passed. |
| **Seek forward** | Only the triggers marked `fire_on_seek`, so a script can catch up on state | The ranges that the seek leaves send their ends, and the range that it lands in sends its begin. A range that it crosses whole sends both only when it is marked `fire_on_seek`. |
| **Skip** ([Skipping](skipping.md#events)) | Only the triggers marked `fire_when_skipped`, such as one that gives the player a key | The range that is open at the skip sends its end, and a range that the skip lands in sends its begin. A range that it crosses whole sends both only when it is marked `fire_when_skipped`. |

- **Several seeks** before one evaluation are one move: from the time that the events had fired up to, to the last seek's time.
- **Pairs.** A range sends its end only after it sent its begin. One procedure, `change_range`, changes the open ranges.
- **Finish.** When the cutscene finishes, each range that is still open sends its end. A cutscene finishes at its end, at a skip to its end, or at a `stop`. A spawned binding is despawned before the next script phase, so its behaviours do not get that end. `restore` and `keep` do not apply: events change state through scripts, which own that state.
- **Failure.** A cutscene that fails sends no more events. Its open ranges do not send their ends.
- **Hot reload.** A reload forgets the open ranges whose IDs are no longer ranges, and sends nothing. The next playback sends the begins and ends that the new blob makes necessary, such as the end of a range that moved away from the time.
- **The editor.** Only an evaluation whose `audition` is `.Play` sends events. A scrub and the editor's preview send none, so a preview never runs gameplay. `set_audition` forgets the open ranges and does not send their ends.

`register` sets the event kind. The game gives the cutscenes its scripts in `init`. Without the scripts, only the native handlers get events.

## Not built yet

- The other kinds of track are parts of [#526](https://github.com/aszecsei/cinnabar/issues/526): sub-sequences ([#545](https://github.com/aszecsei/cinnabar/issues/545)) and presentation ([#546](https://github.com/aszecsei/cinnabar/issues/546)). Until they are built, a track of one of these kinds does nothing.
- A sub-sequence's own camera cut, audio and event tracks wait for [#545](https://github.com/aszecsei/cinnabar/issues/545). A sub-sequence will map the parent's move into its own time. A loop's wrap will send the loop's end and then its start, as animation markers do.
- No editor sets an evaluation's `audition` yet. The cutscene editor's scrub and playback ([#548](https://github.com/aszecsei/cinnabar/issues/548)) will, and its waveforms are [#556](https://github.com/aszecsei/cinnabar/issues/556). The transport's option to send events to edit-mode behaviours waits for the editor too.
- In the editor, only the Game view follows the cut track. A viewport that pilots a camera waits for [#555](https://github.com/aszecsei/cinnabar/issues/555).

## Procedures

| Procedure | What it does |
|---|---|
| `curve_value(keys, t, hint)` | A curve's value at a time in ticks from its section's start |
| `curve_step(keys, t, hint)` | A curve's value as if every key were constant |
| `property_track(ctx)` | The property kind's evaluate procedure |
| `transform_track(ctx)` | The transform kind's evaluate procedure |
| `animation_track(ctx)` | The animation kind's evaluate procedure |
| `camera_cut_track(ctx)` | The camera cut kind's evaluate procedure |
| `audio_track(ctx)` | The audio kind's evaluate procedure |
| `register_event_handler(state, name, procedure, data)` | Registers a native handler of the events of one name, from every cutscene |
| `curve_integral(keys, t)` | A curve's integral from 0 to a time in ticks, in value × seconds |
| `sound_place(data, blob, section, t, length)` | Where an audio section's sound is at a time, in seconds, and whether that is inside the sound |
| `set_audition(evaluation, audition)` | Sets how an evaluation's audio tracks sound, and whether its event tracks send events. A change stops the voices and forgets the open ranges. |
| `set_rate(state, rate)` | Sets the game clock's rate against real time. The game sets it each frame. |
| `set_audio_drift(state, seconds)` | Sets the drift limit, from the project's `cutscene.audio_drift` |
| `end_cut(evaluation)` | Releases the cut track's claim on the views, with the blend that its shot leaves with. `restore`, `restore_all`, a reload and `destroy_evaluation` call it, through the one `end_holds`. |
| `settle_pose(world, entity, teleport)` | Composes a child's `Transform` from what a track or a restore wrote. With `teleport`, also sets the `Previous_Transform` of the entity and of every entity under it. |
| `pose_channel(name)` | A transform channel's place in the pose |
