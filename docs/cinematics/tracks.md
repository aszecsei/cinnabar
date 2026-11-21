# Tracks

A track acts on the world at the cutscene's time. Its kind says what it writes: a field, a pose, a camera, a sound. This document describes the kinds that the engine has, in `lib/engine/cutscene`, and the curve that every keyed track shares. Read [Evaluation](evaluation.md) first, for sections, blending and the restore snapshot.

**In this document:** [Curves](#curves) · [Property tracks](#property-tracks) · [Not built yet](#not-built-yet) · [Procedures](#procedures)

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

## Not built yet

The other kinds of track are parts of [#526](https://github.com/aszecsei/cinnabar/issues/526): transform ([#539](https://github.com/aszecsei/cinnabar/issues/539)), animation ([#541](https://github.com/aszecsei/cinnabar/issues/541)), camera cuts ([#542](https://github.com/aszecsei/cinnabar/issues/542)), audio ([#543](https://github.com/aszecsei/cinnabar/issues/543)), events ([#544](https://github.com/aszecsei/cinnabar/issues/544)), sub-sequences ([#545](https://github.com/aszecsei/cinnabar/issues/545)) and presentation ([#546](https://github.com/aszecsei/cinnabar/issues/546)). Until they are built, a track of one of these kinds does nothing.

## Procedures

| Procedure | What it does |
|---|---|
| `curve_value(keys, t, hint)` | A curve's value at a time in ticks from its section's start |
| `curve_step(keys, t, hint)` | A curve's value as if every key were constant |
| `property_track(ctx)` | The property kind's evaluate procedure |
