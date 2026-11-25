# Evaluation

A cutscene's world is a function of its time. `evaluate` at a time *t* gives the same world for the same *t*, whatever came before. Play, seek, scrub, skip and render-out therefore use one path. Only events depend on the time before: they fire for the range `(last, now]`.

This document describes `lib/engine/cutscene/evaluation.odin`: the clock, the order in the frame, how sections blend, events, the restore snapshot and hot reload. The tracks of each kind are separate parts of [#526](https://github.com/aszecsei/cinnabar/issues/526). Read [Bindings](bindings.md), [World: Time](../world/time.md#fixed-and-variable-rate) and [World: ECS: Systems](../world/ecs.md#systems) first.

**In this document:** [The evaluation](#the-evaluation) · [The clock](#the-clock) · [The order in the frame](#the-order-in-the-frame) · [Kinds of track](#kinds-of-track) · [Sections and blending](#sections-and-blending) · [Events](#events) · [The restore snapshot](#the-restore-snapshot) · [Hot reload](#hot-reload) · [Determinism](#determinism) · [The editor's mix](#the-editors-mix) · [Procedures](#procedures)

## The evaluation

An `Evaluation` is what one cutscene needs to be evaluated:
- its blob, as an asset handle;
- its [bindings](bindings.md);
- its children: the cutscenes that its sub-sequence sections play, each with its blob, the assets that it references and its bindings, which the player loads ([Tracks: Sub-sequence tracks](tracks.md#sub-sequence-tracks));
- its time in ticks, from the range's start to the range's end;
- the time of each phase's last evaluation;
- the [snapshot](#the-restore-snapshot) of the fields that its tracks wrote;
- the fields of its property tracks, resolved once for the blob ([Tracks: Property tracks](tracks.md#property-tracks));
- for each transform track relative to another binding, a cycle or where its binding starts in the other's space, found once for the blob ([Tracks: Transform tracks](tracks.md#transform-tracks));
- the `Animator`s that its animation tracks drive, by entity, each with its driver's token ([Tracks: Animation tracks](tracks.md#animation-tracks));
- what its camera cut track shows, with its claim on the game's views, and a count of its seeks and skips, so the track cuts after one ([Tracks: Camera cut tracks](tracks.md#camera-cut-tracks));
- `presented`: what its presentation tracks gave at the last `Late` phase, which the overlay shows ([Tracks: Presentation tracks](tracks.md#presentation-tracks)).

It holds no procedures, `typeid`s or string literals, so it survives a code reload. `init_evaluation` starts it at the range's start, and `destroy_evaluation` frees it.

`State`, in `Game.cutscenes`, holds the kinds of track and the [players](player.md). Each player from `Ready` to `Finishing` holds its evaluation, so the evaluation's time is the player's time. The systems advance the evaluations of the players that are `Playing`, and evaluate those of the players that are `Playing`, `Paused` or `Skipping`. An evaluation can also stand alone, outside a player, as the tests' scrubs do.

## The clock

The blob's `clock` says which time the cutscene follows:

| Clock | Advances by | Pause and time scale |
|---|---|---|
| `game` (the default) | Each fixed tick's exact length, in the `cutscene fixed` system | The game's pause stops it. `Game.set_time_scale` scales it. Both act through the world's ticks. |
| `real` | The frame's real duration, in frame code before the ticks (`advance_real`) | Neither changes it. It plays on while the game is paused. |

- **No drift.** `advance` converts a duration to ticks with integer arithmetic. It keeps the part of a tick that is left over in `carry`, in nanoseconds × 60000, and adds it to the next duration. So 1000 steps of 7 ms are exactly 420000 ticks, and 8640 ticks at 144 Hz are exactly 60 s.
- **The game's clock moves by whole world ticks.** A frame that runs no tick does not move it, so it can be up to one world tick behind the frames.
- **The end.** The time stops at the range's end. The player then finishes ([Player: The frame](player.md#the-frame)).
- **Seeks.** `seek` sets the time, inside the range, for a debugger, a scrub or the editor. It marks each phase as sought to the new time, so no event that it jumps over fires, except the keys that an event track marks to fire on seek ([Events](#events)). It also counts the jump in `Evaluation.jumps`, as `skip_to` does: an empty event range alone does not tell a seek from a pause, and a seek cuts the camera.
- **A driven player** follows neither clock. A player loaded with `driven` set has a `Player_Driven` clock, which only `drive(state, world, handle, t)` moves, as a render out does (see [Cutscene editor: Render out](../editor/cutscene-editor.md#render-out)). `drive` sets the time that the next `advance_real` takes the player to. It refuses a time before the player's, a player that is not driven, and a player that is not `Playing`. Events fire over `(last, t]` as a play's do, and nothing jumps: a camera cut track does not cut.
- **The editor's Edit mode** runs no ticks and no frame code for the world, so no player advances a cutscene there. The cutscene editor's preview evaluates one itself with `seek` and `evaluate`, and moves it by the frame's real time while it plays. Its writes lay over the document as the editor's overrides do. `lift` puts them back and forgets them, and keeps the drives, the camera cut's claim and the voices (see [Cutscene editor: Preview](../editor/cutscene-editor.md#preview)).

## The order in the frame

Each kind of track has a **phase**:

| Phase | Where | For |
|---|---|---|
| `Fixed` | The `cutscene fixed` system, the first `Fixed` system of each tick. On the real clock, also `advance_real`, before the ticks. | Transforms, poses, property writes and events |
| `Late` | The `cutscene late` system, the first `Late` system, after the script phase | Camera cuts, sounds and presentation |

- **Same tick.** The `Fixed` phase writes before the animator, physics and the tick's propagation read. The animator, physics and propagation therefore see the cutscene's values in the same tick, and nothing lags by a frame.
- **Interpolation.** The tick's `Previous_Transform` copy runs before the systems. So presentation interpolates from the last tick's pose to the cutscene's pose, as for any entity that moves in `Fixed`.
- **Late phase.** The `Late` phase runs after scripts and before `camera.advance`, so the frame shows what it wrote.
- **Camera constraints.** After the `Fixed` phase's tracks, `run_phase` drives the `Animator`s with the clips of every animation track, and applies the camera constraints of the cut tracks, so they see every track's pose at the tick, whatever the tracks' order ([Tracks: Camera cut tracks](tracks.md#camera-cut-tracks)).
- **The presentation.** `run_phase` clears `Evaluation.presented` before the `Late` phase's tracks, and each presentation track adds its sections to it. So the presentation is a value of the time alone ([Tracks: Presentation tracks](tracks.md#presentation-tracks)).
- **The camera cut** evaluates once for the tree in the `Late` phase, after the other tracks: it shows the parent's shot or a child's ([Tracks: Sub-sequence tracks](tracks.md#sub-sequence-tracks)).
- **Exclusive.** Both systems are **exclusive** ([World: ECS: Systems](../world/ecs.md#systems)). A property track can write any component, so the systems cannot name their writes before they run. An exclusive system waits for every system before it, and every later system waits for it. `register` is the first registration in `register_world`, so in each stage the cutscene runs first and alone.
- **Real clock.** `advance_real` runs in `game_update` before the ticks, and only while the world runs. Its `Fixed` writes are therefore in place before the first tick. The game's pause does not stop them.
- **Real clock in a pause.** While the game is paused, no tick runs. So `Previous_Transform` is not copied, and the clock's `alpha` does not change. Presentation then shows only a part of a move that a real-clock track writes to `Transform`. A kind that moves an interpolated entity on the real clock must therefore teleport it. The transform track does ([Tracks: Transform tracks](tracks.md#transform-tracks)).

[Architecture: Frame](../overview/architecture.md#frame) has the whole frame.

## Kinds of track

`register_kind(state, kind, Track_Kind{phase, evaluate, data})` sets what a kind of track does.
- `register` sets the engine's kinds and clears the others, because their procedures are in the DLL image. A code reload therefore makes the kinds again. A game that sets a kind of its own calls `register_kind` after `register`, in `register_world`.
- The engine's kinds are in [Tracks](tracks.md). Their keyed channels are curves ([Tracks: Curves](tracks.md#curves)).
- A kind without a procedure does nothing. A muted track does nothing.

`evaluate` evaluates the tracks of one phase in the blob's order, with each child's tracks in its sub-sequence track's place. The children whose sections do not cover the time go first, so they write their fields' own values before the tracks that play win them ([Tracks: Sub-sequence tracks](tracks.md#sub-sequence-tracks)). For each track, it calls its kind's procedure with a `Track_Context`, which holds:
- the world, the evaluation, the blob and the track, and for a child's track, the child's blob;
- the time, on the track's cutscene's time;
- the event range, whether it is a skip's (`skipped`), and a forward seek since the phase's last evaluation (`seek`), on that time too;
- the track's scope, and what the sub-sequence sections above it give: their weight, whether they cover the time, and their scale;
- the kind's `data`.

A kind:
- gets its binding's entity with `track_entity`, and another binding's with `ctx_binding`;
- samples its sections with `sample_section` and blends them with `Blend`;
- reads a field's own value with `base`;
- writes the world **only** with `write` or `write_field`, and writes every field that it holds in each evaluation, at the field's own value where no section covers the time ([Player: Conflicts](player.md#conflicts)). There are three exceptions, outside the snapshot. The first is what follows from those fields each tick: `settle_pose` writes a child's `Transform` and a teleport's `Previous_Transform`. The second is an `Animator`'s driven clips, which only the animation's driver writes, through a token: an animation track holds the token in `Evaluation.drives`, and `restore` ends it. The third is the camera cut track's claim on the game's views, which it holds in `Evaluation.cut`, and which `restore` releases;
- tests a key against the event range with `fires`, and in a skip's range fires only the keys that it marks to fire when skipped ([Skipping: Events](skipping.md#events)).

## Sections and blending

`section_at(blob, section, t)` gives a section's local time (from its start) and its weight at *t*. It gives false when the section does not cover *t*.

- **Span.** A section covers `[start, end)`. A section whose span ends at the range's end also covers the end, so the last evaluation of a cutscene sees it.
- **Pre-roll and post-roll.** `pre_roll` and `post_roll` widen the span by their ticks. In the pre-roll, the section holds its value and weight at its start. In the post-roll, it holds them at its end.
- **Weight.** The weight is `weight × ease_in × ease_out`. The ease in rises over the first `ease_in` ticks, and the ease out falls over the last `ease_out` ticks.
- **The ease's shape** is smoothstep, 3x² − 2x³. It has no slope at either end, so a take-over and a give-back start and stop smoothly. Two sections that cross with equal eases have weights that sum to 1.

A track blends its sections with `Blend`: `blend_add(&b, value, weight)` for each section that covers *t*, then `blend_value(b, base)`:

| Sum of weights *W* | Value |
|---|---|
| *W* ≥ 1 | The weighted mean of the sections' values |
| *W* < 1 | `base × (1 − W)` + the weighted sum |

**The base** is the field's own value: its value before the cutscene first wrote it, from the snapshot, or its current value if no track has written it. It is never the value that the track wrote last. So the value at *t* does not depend on what came before *t*, and a cutscene takes a field over and gives it back as its weights rise and fall. When no section covers *t*, the track writes the base, so the field is its own value again.

## Events

Each phase keeps a mark of where its events have fired up to: the time of its last evaluation (`Evaluated`), or a seek since it (`Sought`). An evaluation's event range is `(last, now]`, and `fires(ctx, t)` is whether an event at *t* is in it. The event track sends what each kind of move crosses ([Tracks: Event tracks](tracks.md#event-tracks)).

- **The first evaluation** of a phase starts its range just before the range's start, so an event at the range's start fires.
- **Several ticks in a frame.** The `Fixed` phase evaluates once per tick, and the `Late` phase once per frame. The `Late` phase's range covers every tick since its last evaluation, so it loses no event.
- **Seeks.** A seek or a scrub marks the phase `Sought`, from the time that its events had fired up to, to the new time, and the range starts at the new time. So the events that it jumps over do not fire. A forward seek is in `Track_Context.seek` at the next evaluation, so an event track can send the keys marked to fire on seek. Several seeks before one evaluation are one seek, from the first one's origin.
- **Reloads.** A reload marks each phase `Evaluated` at the time. It is not a seek, and fires nothing.
- **Skips.** `skip_to` moves the time to a skip's target and evaluates each phase once over `(last, target]`, with `Track_Context.skipped` set, so a kind fires only the keys marked to fire when skipped ([Skipping: Events](skipping.md#events)). While a skipping player's fade runs, the systems evaluate it with an empty range and leave each phase's last time, so the jump covers what the fade held.
- **Backwards.** A time before the last time gives an empty range.

## The restore snapshot

`write_field(ctx, field, bytes)` and its typed form `write(ctx, entity, component, offset, value)` are the only way that a track writes. A `Field` is an entity, a component ID, and an offset and a size in the component, of at most `MAX_FIELD_SIZE` (64) bytes.

1. **Save.** Before the first write of a field by any track, the snapshot saves the field's bytes. It saves only the fields that tracks write, once each.
2. **Writers.** The snapshot also keeps each track, by its ID, that wrote the field.
3. **Write.** The write marks the component changed (`ecs.mark_changed`), so change versions and queries see it.

**Restore.** `restore` ends what the tracks did to the world:
- A field that a track set to `restore` wrote goes back to its saved value.
- A field that only tracks set to `keep` wrote stays as the cutscene left it.
- A field whose entity is gone, or no longer has the component, is skipped.
- The fields go back in the reverse of the order in which they were saved. Where a track wrote a whole field and another wrote a part of it, the value from before the first write is what stays.
- A field of a `Transform` or a `Local_Transform` that goes back teleports its entity, with what is under it (`settle_pose`), so presentation does not interpolate to it.

The snapshot is then empty. `restore` also ends the hold of every `Animator` that an animation track drives, so its graph's pose shows again ([Tracks: Animation tracks](tracks.md#animation-tracks)), and releases the camera cut track's claim, so the views show gameplay again ([Tracks: Camera cut tracks](tracks.md#camera-cut-tracks)). The player calls `restore` when it goes to `Restored` or `Failed`.

**Several players.** When two players write one field, the later one saves the value that the first one saved, and a player does not put back a field that another live player holds ([Player: Conflicts](player.md#conflicts)). `field_base` gives that value too, so neither player blends over what the other wrote.

A write fails, and saves nothing, when the entity is not alive, has no such component, or the field is outside the component.

## Hot reload

A blob with a new key is a hot reload, the blob of a child included: the evaluation keeps a key of all the blobs of its tree. The next `evaluate`, `seek` or `restore` notices it and:
1. Takes each removed track, by its scope and its ID, off the writers of its fields.
2. Restores each field that no remaining track wrote, and removes it from the snapshot. A track that the reload removes therefore restores its fields. It also forgets the property tracks' resolved fields, so the next evaluation resolves them again. It keeps the start of each transform track that is still relative to the same two bindings, and forgets the other spaces ([Tracks: Transform tracks](tracks.md#transform-tracks)). It ends the hold of every driven `Animator`, and the animation tracks of the new blob take theirs again as they evaluate. It releases the camera cut track's claim on the views too, and the track of the new blob claims them again with a cut. One `end_holds` ends both kinds of hold, for a reload, `restore`, `restore_all` and `destroy_evaluation`.
3. Keeps the time, clamped into the new range, and sets each phase's last time to it, so the reload fires no events. It forgets the event tracks' open ranges whose IDs are no longer ranges ([Tracks: Event tracks](tracks.md#event-tracks)).
4. Evaluates the new blob at the time.

The bindings are the player's: when a reload changes them, the player resolves them again ([Player: Hot reload](player.md#hot-reload)).

## Determinism

The same *t* gives the same values on one job or many:
- Each evaluation runs in one job of an exclusive system.
- The evaluations run in the players' order: by priority, and then by start order ([Player: Conflicts](player.md#conflicts)).
- Each evaluation's tracks run in the blob's order.

A test compares a play with one job and with eight workers.

## The editor's mix

The cutscene editor's preview sets three things on its evaluation with `set_mix`, which is their one writer. A player's evaluation leaves them at their zero values, so a game never sees them.
- **Silent tracks.** `Evaluation.silent` holds IDs of the root cutscene's tracks. `track_silent` makes each one evaluate as a track whose blob sets `muted`: every place that skips a muted track asks it, so a silenced camera cut track shows no shot, a silenced sub-sequence track plays no child, and a transform track relative to a silenced one does not follow it. The IDs name the root's tracks only, not a child's. The children stay loaded. A change of the set ends what the evaluation holds outside the snapshot (`end_holds`) and forgets the open ranges, as a reload does, so the next evaluation starts the drives, the claim and the voices again for the tracks that still play.
- **Grains.** `no_grains` stops a scrub's grains.
- **Events.** `preview_events` lets the event tracks send events under the `.Preview` audition, which a play in the editor has. A change forgets the open ranges without sending their ends.

The editor also lays its own values over a paused preview's evaluation, outside the cutscene package (see [Cutscene editor: The game's side](../editor/cutscene-editor.md#the-games-side)). They save what they write over after the evaluation does, so a lift gives back the evaluation's writes and then the snapshot's.

## Procedures

| Procedure | What it does |
|---|---|
| `init(state, world, assets, actions, animation, views, sounds)`, `register(state, world)`, `destroy(state, world)` | Set up the state, register the two systems and clear the kinds, and reset and free the players |
| `register_kind(state, kind, desc)` | Sets a kind's phase and evaluate procedure |
| `set_mix(e, world, silent, grains, events)` | Sets the editor's mix: the root's tracks that evaluate as muted ones, the scrub's grains, and events under `.Preview` |
| `init_evaluation(e, world, handle, data, blob)`, `destroy_evaluation(e, world)` | Start an evaluation at the range's start. Destroy its bindings and free its snapshot, without restoring. |
| `advance(e, blob, dt)` | Moves the time by a duration, without drift, up to the range's end |
| `seek(state, e, world, data, blob, t)` | Sets the time, so no event between fires, except the event tracks' keys marked to fire on seek when it goes forward |
| `skip_to(state, e, world, data, blob, target)` | Moves the time to a later target and evaluates each phase there as a skip |
| `evaluate(state, e, world, data, blob, phase)` | Evaluates one phase's tracks at the time, and follows a reload |
| `advance_real(state, world, dt)` | Advances the real-clock cutscenes, takes the driven ones to their targets, and evaluates their `Fixed` tracks |
| `restore(state, e, world, data, blob)`, `restore_all(state, e, world)` | Put back the fields of `restore` tracks, or every field when the blob is gone, empty the snapshot, give back the driven `Animator`s, and release the camera cut track's claim |
| `section_at(blob, section, t)`, `ease(x)` | A section's local time and weight at a time in a blob alone, and the ease's shape |
| `sample_section(ctx, section, t)` | A section's local time and weight at a time on its track's cutscene's time, through the sub-sequence sections above it |
| `blend_add`, `blend_value` | Blend sections' values over the base |
| `track_entity(ctx)`, `ctx_binding(ctx, index)`, `fires(ctx, t)` | A track's bound entity, another binding's entity through a sub-sequence's maps, and whether an event fires |

| `write`, `write_field`, `base`, `field_base` | Write a field through the snapshot, and read its own value |

