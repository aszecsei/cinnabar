# Math

Curves and paths in `lib/core/math`: keyed curves, which are the format of a cutscene's channels, easing and tweens, and splines with their arc length and frames, for movement along a path and for procedural geometry.

**In this document:** [The package](#the-package) · [Keyed curves](#keyed-curves) · [Easing](#easing) · [Tweens](#tweens) · [Paths](#paths) · [Arc length](#arc-length) · [Frames](#frames) · [Procedures](#procedures) · [References](#references)

## The package

`lib/core/math` is a shared package, as `layout` is: it imports only `base:` and `core:`, so the host, the game DLL, the cooker and the shared formats all compile it. `format` imports it for the cutscene key.

- **Import it as `core_math`.** The package is `package core_math`, and every file imports it as `import core_math "cinnabar:core/math"`, so a file can also import `core:math`.
- **It allocates nothing.** Every procedure is `"contextless"`. A table or a run of frames goes into a slice that the caller gives, from the arena that fits its lifetime, such as the Level arena for a level's paths.
- **Its data holds no procedure.** An easing is an `Ease`, not a procedure pointer, and a tween is a description that a time is applied to. A `Spline` is a view of points that the caller owns, so its points must not be a literal in the DLL image if the spline is kept in `Game_State` ([Hot reload](../overview/hot-reload.md#rules)).
- **A value type is a float or an array of floats,** `f32` or `f64`: a scalar, a `[2]f32`, a `[3]f32` position, a `[4]f32` color. A parameter, a length and a distance are the element type, so `bezier_point(c, 0.5)` on `[4][3]f32` points takes the `0.5` as an `f32`.
- **Paths are in a local space.** A `[3]f32` path is in meters about an anchor. The caller places a point with `ecs.position_offset(anchor, local)` ([World: Positions](../world/positions-and-transforms.md#positions)).

**Exactness.** The kernels of `exact.odin` (`hermite`, `cubic`, `weighted_param`, `weighted_segment`, `auto_slope`, `floor_wrap`) and the keyed curve with `i32` times give the same bits as the editor's evaluator, `CutsceneCurve` ([Editor: Cutscene editor](../editor/cutscene-editor.md#the-evaluator)). Their arithmetic is `f64`, `+ - * /` only, in a fixed order, so do not reorder an expression there. `testdata/curve.txt` is a shared test curve and its value at every 250 ticks, as `f32` bits, which both test suites read. Run the package's tests with `CINNABAR_WRITE_CURVE_GOLDEN=1` to write it again after a deliberate change, and change `CutsceneCurve.cs` the same way. Everything else in the package is plain floating point with no such promise.

## Keyed curves

A keyed curve is a slice of `Key(Time)`: keys in rising time, each with a value and an interpolation to the next key (`Interp`: `Constant`, `Linear`, `Bezier` or `Auto`). It is the curve of an animator's tool: a designer places keys, and the value between them follows. The cutscene's channels are keyed curves ([Cinematics: Curves](../cinematics/tracks.md#curves)).

- **`Time` is `i32` or `f32`.** `Key(i32)` is in whole ticks of a rate, and wraps exactly; `format.Cutscene_Key` is `Key(i32)` at 60000 ticks a second. `Key(f32)` is in seconds, or in a part from 0 to 1, such as a particle's life or a distance's falloff.
- **`rate` is the time's units in a second.** A tangent's slope is in value per second, so `key_value(keys, t, rate)` takes 60000 for ticks and 1, the default, for seconds.
- **At a key's time, the value is the key's value, exactly.** An `Auto` key's tangents come from its neighbours and never overshoot (Fritsch and Carlson's condition): a key level with a neighbour, a peak or a trough is flat.
- **Extrapolation.** Before the first key `pre` decides, and after the last `post` does: `Constant` holds, `Linear` goes on along the end's slope, `Cycle` repeats, `Cycle_Offset` repeats moved by the change over the keys, and `Oscillate` repeats forward and back.
- **The hint.** `hint` is an `int` that the caller keeps between calls. Playback that moves forward a little each call then finds its segment at once. It never changes the value.
- **Flags.** `Broken` and `Teleport` are for the curve's owners: an editor's unified tangents, and a jump that a consumer which keeps state, such as a pose's history, does not smooth across. The value reads neither.
- **The types are a binary format.** `format.Cutscene_Key`, `Cutscene_Interp`, `Cutscene_Key_Flag` and `Cutscene_Infinity` are these types, and the editor mirrors the enums' values. A change to `Key` or to an enum's members changes `cutscene_layout()`, so every cutscene cooks again. Only append to an enum.

```odin
// A light that flickers up and settles, built in code, in seconds.
keys := [?]core_math.Key(f32) {
	core_math.key_auto(f32(0), 0),
	core_math.key_auto(f32(0.1), 1.4),
	core_math.key_auto(f32(0.4), 1),
}
light.intensity = core_math.key_value(keys[:], age)
```

`linear_value` and `linear_bake` are the simplest keyed curve, a `Linear_Key(T)` of any value type straight from key to key, held past the ends. The cooker bakes an effect's color and size curves with them into rows that the particle shaders read.

## Easing

`ease(e, x)` maps a part of a change, from 0 to 1, along an easing: exactly 0 at 0 and exactly 1 at 1, with `x` clamped. It works on `f32` and `f64`.

| `Ease` | Shape |
|---|---|
| `Linear` | No easing. |
| `Smoothstep`, `Smootherstep` | No slope at either end, and for `Smootherstep` no curvature either. A blend between two states. |
| `In_*`, `Out_*`, `In_Out_*` of `Quad`, `Cubic`, `Quart`, `Quint`, `Sine`, `Expo`, `Circ` | Robert Penner's easings: `In` starts at rest, `Out` ends at rest, and `In_Out` does both. The power sets how sharp. |
| `In_*`, `Out_*`, `In_Out_*` of `Back` | Overshoots, and comes back. |
| `In_*`, `Out_*`, `In_Out_*` of `Elastic`, `Bounce` | Swings or bounces about the end. |

- **An `Ease` is a stored number.** Its members are only appended, so a setting in a file or a component keeps its meaning.
- **A smaller stored set maps onto it.** `camera.Curve` and `format.Cutscene_Blend_Curve` keep their own four values and map them to `Linear`, `Smoothstep`, `In_Quad` and `Out_Quad` (`camera.CURVE_EASE`). A cutscene section's ease in and ease out is `Smoothstep` in `f64`.
- **`ease_bezier(x1, y1, x2, y2, x)`** is CSS's `cubic-bezier()`: the curve from (0, 0) to (1, 1) with two handles, which a tool can let a designer draw. It solves the handles' x as a weighted key does.

## Tweens

A `Tween(T)` is a change of a value from `from` to `to` over a `duration`, after a `delay`, along an `ease`, played `Once`, on `Repeat` or as a `Ping_Pong`. It is a description, not a running state. The caller keeps the time since it began and asks for the value at that time:

```odin
pop := core_math.Tween([3]f32){from = {1, 1, 1}, to = {1.2, 1.2, 1.2}, duration = 0.25, ease = .Out_Back}
transform.scale = core_math.tween_value(pop, elapsed)
if core_math.tween_done(pop, elapsed) {
	// ...
}
```

- **There is no tween manager.** Logic that spans frames is a script coroutine ([Conventions](../overview/conventions.md#rules-that-cut-across)): the coroutine keeps the time, and a component keeps a tween and the time it started. Many entities can share one tween.
- **`T` is a float or an array of floats.** A rotation takes `tween_progress`, the eased part, and slerps itself.

## Paths

A path is made of cubic Bezier segments, four control points `[4]T`. Every other kind of segment converts to one, so evaluation, derivatives, splitting, bounds, length, the nearest point and frames are written once, for the Bezier segment.

| Convert | From |
|---|---|
| `hermite_to_bezier(p0, m0, p1, m1)` | Two points and their tangents, in change per unit of the segment's parameter. |
| `catmull_rom_to_bezier(p0, p1, p2, p3, alpha)` | The curve through `p1` and `p2`, shaped by their neighbours. `alpha` 0 is uniform, 0.5 is centripetal, 1 is chordal. Centripetal makes no cusp and no loop inside a segment, so it is the one for paths through points that a designer places. |
| `bspline_to_bezier(p0, p1, p2, p3)` | A uniform cubic B-spline: near the points, not through them, and with no jump of curvature at a join. A camera rail or a smooth cable. |
| `line_to_bezier(p0, p1)` | A straight segment, so a polyline uses the same procedures. |

A `Spline(T)` is a path of many segments: `points`, a `kind`, whether it is `closed`, and the Catmull-Rom `alpha`.

| `Spline_Kind` | `points` | Segments, open and closed |
|---|---|---|
| `Linear` | The points | n − 1, n |
| `Bezier` | A point, its out handle, the next point's in handle, the next point, … | (n − 1) / 3, n / 3 |
| `Hermite` | Pairs of a point and its tangent | n / 2 − 1, n / 2 |
| `Catmull_Rom` | The points, which it passes through | n − 1, n |
| `B_Spline` | The control points | n − 3, n |

- **The parameter runs from 0 to the segment count,** a whole number at each join. `spline_point(s, t)` and `spline_tangent(s, t)` evaluate it. An open spline clamps it, and a closed one wraps it.
- **`spline_segment(s, i)`** is segment `i` as a Bezier segment, for the procedures of a single segment: `bezier_split`, `bezier_bounds`, `bezier_closest`.
- **`spline_closest(s, p)`** is the parameter nearest a point: how far along a track a racer is.
- **The parameter is not distance.** The tangent's length changes with the shape, so equal steps of `t` are not equal steps along the path. An `Arc_Length` table maps between them.

## Arc length

An `Arc_Length(F)` is a table of the length from a spline's start, at `per_segment` even steps of each segment's parameter. Build it once for a path that does not change:

```odin
cumulative := make([]f32, core_math.arc_length_count(spline, 8), level_allocator)
path.arc = core_math.arc_length_build(spline, 8, cumulative)
```

- **`arc_length_param(a, s, distance, hint)`** is the parameter at a distance: the step from the table, then Newton's method on the length. It is how a follower moves at a constant speed. An open spline clamps the distance; a closed one wraps it.
- **`arc_length_distance(a, s, t)`** is the distance at a parameter, its inverse.
- **`arc_length_spaced(a, s, out)`** fills `out` with parameters an even distance apart: both ends for an open spline, and around a closed one without repeating its start.

A follower at a constant speed, with its distance and hint in a component:

```odin
follow.distance += follow.speed * dt
t := core_math.arc_length_param(path.arc, path.spline, follow.distance, &follow.hint)
transform.position = ecs.position_offset(path.anchor, core_math.spline_point(path.spline, t))
```

## Frames

A `Frame(F)` is an orientation on a 3D path: its `position`, its `tangent`, its `normal` and its `binormal`. `binormal`, `normal` and `tangent` are the frame's x, y and z axes, right-handed, so a profile drawn in x and y sweeps along the path.

| Frame | Use |
|---|---|
| `frames_rotation_minimizing(s, params, up, out)` | Frames that turn about the tangent as little as the path lets them, carried from one to the next by two reflections (Wang et al.). A tube, a cable, a ribbon: nothing twists. A closed spline spreads its turn once around over its length, so the last frame joins the first. |
| `frame_up(s, t, up, bank)` | A frame whose normal is as close to `up` as the tangent lets it, turned by a bank angle. A road, a rail, a camera on a dolly. |
| `frame_frenet(s, t)` | The Frenet frame, whose normal points to the centre of the turn. It flips where the path bends the other way, so it measures a curve; it does not sweep one. |

`frame_point` places a point given in a frame's axes, `frame_matrix` is the frame as a transform, and `frame_rotation` is its orientation as a quaternion, for a prop placed along a path.

A tube: rings an even distance apart, frames that do not twist, and a circle swept along them.

```odin
params := make([]f32, rings, arena)
core_math.arc_length_spaced(arc, spline, params)
frames := make([]core_math.Frame(f32), rings, arena)
core_math.frames_rotation_minimizing(spline, params, {0, 1, 0}, frames)
positions := make([][3]f32, rings * len(circle), arena)
core_math.sweep_points(frames, circle[:], positions)
```

`sweep_points` writes ring `r`'s point `k` at `r * len(profile) + k`. The mesh code makes the triangles between rings, and the normals.

## Procedures

| Procedure | What it does |
|---|---|
| `key_value(keys, t, rate, pre, post, hint)` | A keyed curve's value at a time |
| `key_step(keys, t, pre, post, hint)` | A keyed curve's value as if every key were constant |
| `key_integral(keys, t, rate, lo, hi)` | A keyed curve's integral from 0 to a time, with the value clamped to `[lo, hi]` |
| `key_wrap(keys, t, pre, post)` | The time inside the keys that gives a time outside them, and the cycles of an offset |
| `key_segment(keys, t, hint)`, `find_segment(times, t, hint)` | The segment that holds a time, over keys or over plain times |
| `key_constant`, `key_linear`, `key_auto`, `key_bezier`, `key_weighted` | A key of each kind |
| `linear_value(keys, t)`, `linear_bake(keys, out, fallback)` | Linear keys at a part, and baked to a row |
| `ease(e, x)`, `ease_bezier(x1, y1, x2, y2, x)` | An easing at a part |
| `tween_progress`, `tween_value`, `tween_done` | A tween at a time since it began |
| `bezier_point`, `bezier_tangent`, `bezier_second` | A Bezier segment's point and derivatives |
| `bezier_split`, `bezier_sub`, `bezier_bounds`, `bezier_length`, `bezier_closest` | A Bezier segment cut, bounded, measured and searched |
| `hermite_to_bezier`, `catmull_rom_to_bezier`, `bspline_to_bezier`, `line_to_bezier` | Other segments as Bezier segments |
| `spline_segment_count`, `spline_segment`, `spline_locate` | A spline's segments, and the segment at a parameter |
| `spline_point`, `spline_tangent`, `spline_closest` | A spline's point and velocity at a parameter, and the parameter nearest a point |
| `arc_length_count`, `arc_length_build`, `arc_length_total` | An arc length table |
| `arc_length_param`, `arc_length_distance`, `arc_length_spaced` | Between distance and parameter |
| `frames_rotation_minimizing`, `frame_up`, `frame_frenet` | Frames along a 3D spline |
| `frame_point`, `frame_matrix`, `frame_rotation`, `sweep_points` | A frame used to place points and props |
| `hermite`, `cubic`, `weighted_param`, `weighted_segment`, `auto_slope`, `floor_wrap` | The exact `f64` kernels |

## References

- F. N. Fritsch and R. E. Carlson, *Monotone Piecewise Cubic Interpolation*, SIAM Journal on Numerical Analysis, 1980: the limit on an `Auto` key's slope.
- Wenping Wang, Bert Jüttler, Dayue Zheng and Yang Liu, *Computation of Rotation Minimizing Frames*, ACM Transactions on Graphics, 2008: the double reflection.
- Cem Yuksel, Scott Schaefer and John Keyser, *Parameterization and Applications of Catmull-Rom Curves*, Computer-Aided Design, 2011: the centripetal Catmull-Rom spline and why it makes no cusp.
- Robert Penner, *Robert Penner's Programming Macromedia Flash MX*, 2002, chapter 7: the easing equations.
