package cutscene

import "core:log"
import "core:mem"
import "core:time"

import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// MAX_FIELD_SIZE is the most bytes of one field that a track writes, and so that the snapshot saves.
MAX_FIELD_SIZE :: 64

// Phase is when a kind of track evaluates (see docs/cinematics/evaluation.md#the-order-in-the-frame).
Phase :: enum u8 {
	// In the cutscene fixed system, the first Fixed system of a tick, so the animator, physics and the propagation see
	// what the tracks wrote in the same tick: transforms, poses and properties.
	Fixed,
	// In the cutscene late system, the first Late system, after the scripts, so the frame shows what the tracks wrote:
	// cameras and presentation.
	Late,
}

// Evaluate_Proc evaluates one track at the context's time. It writes the world only through write_field and its typed
// form write, so the snapshot saves each field before the first write.
Evaluate_Proc :: #type proc(ctx: ^Track_Context)

// Track_Kind is what a kind of track registers: its phase, its evaluate procedure, and data that the procedure gets.
Track_Kind :: struct {
	phase:    Phase,
	evaluate: Evaluate_Proc,
	data:     rawptr,
}

// State is the cutscenes' part of the game: the kinds of track, and the evaluations that the systems advance. The kinds
// hold procedures from the DLL image, so register clears them, and the kinds are registered again after it.
State :: struct {
	assets:      ^asset.Assets,
	kinds:       [format.Cutscene_Track_Kind]Track_Kind,
	// The evaluations that the systems advance and evaluate, in the order that they were added. Their owners add them
	// and remove them. Heap memory.
	evaluations: [dynamic]^Evaluation,
}

// Evaluation is what one cutscene needs to be evaluated: its blob, its bindings, its time and the snapshot of the
// fields that its tracks wrote. It holds no procedures, typeids or string literals, so it survives a code reload.
// Make it with init_evaluation, and free it with destroy_evaluation.
Evaluation :: struct {
	cutscene: asset.Handle,
	bindings: Bindings,
	// The key of the blob that was last evaluated. A new key is a hot reload. nil before the first evaluation.
	key:      Maybe(u64),
	// The time, in ticks, from range_start to range_end.
	time:     i32,
	// What the clock gave that is less than one tick, in nanoseconds × CUTSCENE_TICKS_PER_SECOND, so the conversion
	// never drifts.
	carry:    i64,
	// The time of each phase's last evaluation. Its events have fired up to it. nil before the first, so the first fires
	// the events at range_start.
	last:     [Phase]Maybe(i32),
	snapshot: Snapshot,
}

// Field is a field of a component of an entity: its component, and its offset and size in the component.
Field :: struct {
	entity:    ecs.Entity,
	component: ecs.Component_Id,
	offset:    u32,
	size:      u32,
}

// Saved is a field's value before the first track wrote it.
@(private)
Saved :: struct {
	field: Field,
	bytes: [MAX_FIELD_SIZE]byte,
}

// Writer is a track, by its ID, that wrote a saved field.
@(private)
Writer :: struct {
	saved: int,
	track: u32,
}

// Snapshot holds each field that tracks wrote, as it was before the first write, and the tracks that wrote it (see
// docs/cinematics/evaluation.md#the-restore-snapshot).
Snapshot :: struct {
	saved:   [dynamic]Saved,
	index:   map[Field]int,
	writers: map[Writer]struct{},
}

// Track_Context is what a kind's evaluate procedure gets for one track.
Track_Context :: struct {
	world:      ^ecs.World,
	evaluation: ^Evaluation,
	data:       []byte,
	blob:       ^format.Cutscene_Blob,
	track:      format.Cutscene_Track,
	// The time to evaluate at, in ticks.
	time:       i32,
	// The events in (from, to] fire. The range is empty after a seek, a reload or the phase's last evaluation at the same
	// time. from is i64, so the first range can start before 0.
	from:       i64,
	to:         i64,
	// The kind's data, from its Track_Kind.
	user:       rawptr,
}

// init sets the state's assets and its list. Call register after it.
init :: proc(s: ^State, w: ^ecs.World, assets: ^asset.Assets) {
	s.assets = assets
	s.evaluations = make([dynamic]^Evaluation, w.platform.heap_allocator)
}

// destroy frees the list. The evaluations belong to their owners, who destroy them.
destroy :: proc(s: ^State) {
	delete(s.evaluations)
	s.evaluations = nil
}

// register clears the kinds and makes the two systems. Call it with the world's registrations, before every other
// system's, and register the kinds after it.
register :: proc(s: ^State, w: ^ecs.World) {
	s.kinds = {}
	ecs.register_system(
		w,
		{
			name = "cutscene fixed",
			stage = .Fixed,
			procedure = fixed_system,
			data = s,
			exclusive = true,
		},
	)
	ecs.register_system(
		w,
		{
			name = "cutscene late",
			stage = .Late,
			procedure = late_system,
			data = s,
			exclusive = true,
		},
	)
}

// register_kind sets the evaluate procedure of a kind of track. A kind without one does nothing.
register_kind :: proc(s: ^State, kind: format.Cutscene_Track_Kind, desc: Track_Kind) {
	s.kinds[kind] = desc
}

// add_evaluation makes the systems advance and evaluate an evaluation, until remove_evaluation.
add_evaluation :: proc(s: ^State, e: ^Evaluation) {
	for other in s.evaluations {
		if other == e {
			return
		}
	}
	append(&s.evaluations, e)
}

remove_evaluation :: proc(s: ^State, e: ^Evaluation) {
	for other, i in s.evaluations {
		if other == e {
			ordered_remove(&s.evaluations, i)
			return
		}
	}
}

// init_evaluation starts an evaluation of a cutscene at its range's start. Resolve its bindings with resolve_bindings.
init_evaluation :: proc(
	e: ^Evaluation,
	w: ^ecs.World,
	cutscene: asset.Handle,
	data: []byte,
	blob: ^format.Cutscene_Blob,
) {
	e^ = {
		cutscene = cutscene,
		time = blob.range_start,
		snapshot = {
			saved = make([dynamic]Saved, w.platform.heap_allocator),
			index = make(map[Field]int, w.platform.heap_allocator),
			writers = make(map[Writer]struct{}, w.platform.heap_allocator),
		},
	}
}

// destroy_evaluation destroys the bindings, which despawns what they spawned, and frees the snapshot. It restores
// nothing: call restore first for that.
destroy_evaluation :: proc(e: ^Evaluation, w: ^ecs.World) {
	destroy_bindings(&e.bindings, w)
	delete(e.snapshot.saved)
	delete(e.snapshot.index)
	delete(e.snapshot.writers)
	e.snapshot = {}
}

// cutscene_data is the blob of an evaluation's cutscene, checked, or false when it is not loaded or not valid.
cutscene_data :: proc(
	s: ^State,
	e: ^Evaluation,
) -> (
	data: []byte,
	blob: ^format.Cutscene_Blob,
	ok: bool,
) {
	data = asset.data(s.assets, e.cutscene) or_return
	blob = format.cutscene_view(data) or_return
	return data, blob, true
}

// advance moves the time by a duration of the cutscene's clock, converted to ticks with integer arithmetic so it never
// drifts. The time stops at the range's end. It gives the new time.
advance :: proc(e: ^Evaluation, blob: ^format.Cutscene_Blob, dt: time.Duration) -> i32 {
	if dt <= 0 {
		return e.time
	}
	n := e.carry + i64(dt) * format.CUTSCENE_TICKS_PER_SECOND
	ticks := n / i64(time.Second)
	e.carry = n % i64(time.Second)
	e.time = i32(min(i64(e.time) + ticks, i64(blob.range_end)))
	if e.time == blob.range_end {
		e.carry = 0
	}
	return e.time
}

// seek sets the time, within the range, for a debugger, a scrub or the editor. No event between the old time and the
// new one fires, in either phase.
seek :: proc(e: ^Evaluation, blob: ^format.Cutscene_Blob, t: i32) {
	e.time = clamp(t, blob.range_start, blob.range_end)
	e.carry = 0
	for &last in e.last {
		last = e.time
	}
}

// evaluate evaluates the tracks of one phase at the evaluation's time, in the blob's order. Their events fire for
// (the phase's last time, now]. A blob with a new key is a hot reload: the fields of the tracks that it removed are
// restored, and the reload fires no events.
evaluate :: proc(
	s: ^State,
	e: ^Evaluation,
	w: ^ecs.World,
	data: []byte,
	blob: ^format.Cutscene_Blob,
	phase: Phase,
) {
	if key, seen := e.key.?; seen && key != blob.header.key {
		reload(e, w, data, blob)
	}
	e.key = blob.header.key
	now := e.time
	from := i64(blob.range_start) - 1
	if last, ok := e.last[phase].?; ok {
		from = i64(last)
	}
	ctx := Track_Context {
		world      = w,
		evaluation = e,
		data       = data,
		blob       = blob,
		time       = now,
		from       = from,
		to         = max(i64(now), from),
	}
	for track in format.cutscene_tracks(data, blob) {
		kind := s.kinds[track.kind]
		if .Muted in track.flags || kind.evaluate == nil || kind.phase != phase {
			continue
		}
		ctx.track = track
		ctx.user = kind.data
		kind.evaluate(&ctx)
	}
	e.last[phase] = now
}

// restore ends what the tracks did to the world: each saved field that a track set to restore wrote goes back to its
// value before the cutscene, and those that only tracks set to keep wrote stay. The snapshot is then empty. A field
// whose entity is gone, or no longer has the component, is skipped.
restore :: proc(e: ^Evaluation, w: ^ecs.World, data: []byte, blob: ^format.Cutscene_Blob) {
	tracks := format.cutscene_tracks(data, blob)
	restores := make([]bool, len(e.snapshot.saved), w.platform.frame_allocator)
	for writer in e.snapshot.writers {
		for track in tracks {
			if track.id == writer.track && track.finish == .Restore {
				restores[writer.saved] = true
			}
		}
	}
	for &saved, i in e.snapshot.saved {
		if restores[i] {
			put_back(w, &saved)
		}
	}
	forget(&e.snapshot)
}

// track_entity is the entity of the track's binding while it is alive, and false for a track without a binding, or
// whose binding is missing or gone.
track_entity :: proc(ctx: ^Track_Context) -> (ecs.Entity, bool) {
	if ctx.track.binding == format.CUTSCENE_NONE {
		return 0, false
	}
	return binding_entity(&ctx.evaluation.bindings, ctx.world, int(ctx.track.binding))
}

// fires is whether an event at a time on the cutscene's time fires in this evaluation: whether it is in (from, to].
fires :: proc(ctx: ^Track_Context, t: i32) -> bool {
	return i64(t) > ctx.from && i64(t) <= ctx.to
}

// Section_Sample is a section at a time: the time in the section, from its start, that its curves are sampled at, and
// its weight.
Section_Sample :: struct {
	local:  i32,
	weight: f32,
}

// section_at samples a section at a time on the cutscene's time, and gives false when the section does not cover the
// time (see docs/cinematics/evaluation.md#sections-and-blending). A section covers [start, end), and its end too when
// its end is the range's end, so the last evaluation of a cutscene sees it. Its pre-roll and post-roll widen the span:
// in them, it holds its value and its weight at its start or at its end.
section_at :: proc(
	blob: ^format.Cutscene_Blob,
	section: format.Cutscene_Section,
	t: i32,
) -> (
	sample: Section_Sample,
	covers: bool,
) {
	lo := i64(section.start) - i64(section.pre_roll)
	hi := i64(section.end) + i64(section.post_roll)
	at := i64(t)
	if at < lo || at > hi || (at == hi && hi != i64(blob.range_end)) {
		return {}, false
	}
	duration := section.end - section.start
	local := i32(clamp(at, i64(section.start), i64(section.end)) - i64(section.start))
	weight := section.weight
	if section.ease_in > 0 {
		weight *= ease(f64(local) / f64(section.ease_in))
	}
	if section.ease_out > 0 {
		weight *= ease(f64(duration - local) / f64(section.ease_out))
	}
	return {local, weight}, true
}

// ease is the shape of a section's ease in and ease out: smoothstep, 3x² − 2x³, from 0 to 1 with no slope at either
// end.
ease :: proc "contextless" (progress: f64) -> f32 {
	x := clamp(progress, 0, 1)
	return f32(x * x * (3 - 2 * x))
}

// Blend sums the values of a track's sections at a time, each by its weight. T is f32 or an array of f32.
Blend :: struct($T: typeid) {
	weight: f32,
	sum:    T,
}

blend_add :: proc(b: ^Blend($T), value: T, weight: f32) {
	if weight <= 0 {
		return
	}
	b.weight += weight
	b.sum += value * weight
}

// blend_value is the track's value: the sections' values by their weights, over the base when the weights sum to less
// than 1. The base is the field's own value (see field_base), so a track takes the field over and gives it back as its
// weights rise and fall. Weights that sum to more than 1 are normalized.
blend_value :: proc(b: Blend($T), base: T) -> T {
	if b.weight >= 1 {
		return b.sum / b.weight
	}
	return base * (1 - b.weight) + b.sum
}

// field_base reads a field's own value: as it was before the cutscene first wrote it, or as it is when no track has
// written it. A track blends over it, so the value at a time does not depend on what the track wrote before. False
// when the entity is not alive or has no such component.
field_base :: proc(ctx: ^Track_Context, field: Field, out: []byte) -> bool {
	if int(field.size) != len(out) || field.size > MAX_FIELD_SIZE {
		return false
	}
	if i, saved := ctx.evaluation.snapshot.index[field]; saved {
		copy(out, ctx.evaluation.snapshot.saved[i].bytes[:field.size])
		return true
	}
	p := field_pointer(ctx.world, field) or_return
	mem.copy(raw_data(out), p, int(field.size))
	return true
}

// write_field writes a field for the track. The first write of the field by any track saves it, and each track that
// writes it is remembered, so restore knows whether to put it back. The component counts as changed. False when the
// entity is not alive, has no such component, or the field is larger than MAX_FIELD_SIZE.
write_field :: proc(ctx: ^Track_Context, field: Field, value: []byte) -> bool {
	if int(field.size) != len(value) {
		return false
	}
	if field.size > MAX_FIELD_SIZE {
		log.errorf("cutscene: a field of %d bytes is larger than %d", field.size, MAX_FIELD_SIZE)
		return false
	}
	p := field_pointer(ctx.world, field) or_return
	snapshot := &ctx.evaluation.snapshot
	index, saved := snapshot.index[field]
	if !saved {
		entry := Saved {
			field = field,
		}
		mem.copy(&entry.bytes, p, int(field.size))
		index = len(snapshot.saved)
		append(&snapshot.saved, entry)
		snapshot.index[field] = index
	}
	snapshot.writers[{index, ctx.track.id}] = {}
	ecs.mark_changed(ctx.world, field.entity, field.component)
	mem.copy(p, raw_data(value), int(field.size))
	return true
}

// write writes a typed field: a component's field at an offset, for the track. See write_field.
write :: proc(
	ctx: ^Track_Context,
	entity: ecs.Entity,
	component: ecs.Component_Id,
	offset: uintptr,
	value: $T,
) -> bool {
	value := value
	return write_field(ctx, {entity, component, u32(offset), size_of(T)}, mem.ptr_to_bytes(&value))
}

// base reads a typed field's own value. See field_base.
base :: proc(
	ctx: ^Track_Context,
	entity: ecs.Entity,
	component: ecs.Component_Id,
	offset: uintptr,
	$T: typeid,
) -> (
	value: T,
	ok: bool,
) {
	ok = field_base(ctx, {entity, component, u32(offset), size_of(T)}, mem.ptr_to_bytes(&value))
	return
}

// advance_real advances the cutscenes on the real clock by the frame's real duration, and evaluates their Fixed
// tracks, so the ticks that follow see them even while the game is paused. Call it in the frame code before the ticks.
advance_real :: proc(s: ^State, w: ^ecs.World, dt: time.Duration) {
	for e in s.evaluations {
		data, blob, ok := cutscene_data(s, e)
		if !ok || blob.clock != .Real {
			continue
		}
		advance(e, blob, dt)
		evaluate(s, e, w, data, blob, .Fixed)
	}
}

// fixed_system advances the cutscenes on the game's clock by the tick, and evaluates their Fixed tracks. The tick's
// length is exact, from the world's clock, so the game's time scale and pause reach the cutscene through the ticks.
@(private)
fixed_system :: proc(ctx: ^ecs.System_Context) {
	s := (^State)(ctx.data)
	w := ctx.world
	step := ecs.tick_time(w) - ecs.tick_start(&w.clock, w.clock.tick)
	for e in s.evaluations {
		data, blob, ok := cutscene_data(s, e)
		if !ok || blob.clock != .Game {
			continue
		}
		advance(e, blob, step)
		evaluate(s, e, w, data, blob, .Fixed)
	}
}

// late_system evaluates every cutscene's Late tracks.
@(private)
late_system :: proc(ctx: ^ecs.System_Context) {
	s := (^State)(ctx.data)
	for e in s.evaluations {
		data, blob, ok := cutscene_data(s, e)
		if !ok {
			continue
		}
		evaluate(s, e, ctx.world, data, blob, .Late)
	}
}

// reload follows a new blob: the time stays, within the new range, the fields that only removed tracks wrote are
// restored, and the next evaluation of each phase fires no events.
@(private)
reload :: proc(e: ^Evaluation, w: ^ecs.World, data: []byte, blob: ^format.Cutscene_Blob) {
	tracks := format.cutscene_tracks(data, blob)
	kept := make([]bool, len(e.snapshot.saved), w.platform.frame_allocator)
	gone := make([dynamic]Writer, w.platform.frame_allocator)
	for writer in e.snapshot.writers {
		found := false
		for track in tracks {
			if track.id == writer.track {
				found = true
				break
			}
		}
		if found {
			kept[writer.saved] = true
		} else {
			append(&gone, writer)
		}
	}
	for writer in gone {
		delete_key(&e.snapshot.writers, writer)
	}
	// The fields that no remaining track wrote go back, and leave the snapshot. The others keep their places.
	kept_saved := make([dynamic]Saved, 0, len(e.snapshot.saved), w.platform.heap_allocator)
	moved := make([]int, len(e.snapshot.saved), w.platform.frame_allocator)
	for &saved, i in e.snapshot.saved {
		if kept[i] {
			moved[i] = len(kept_saved)
			append(&kept_saved, saved)
		} else {
			put_back(w, &saved)
		}
	}
	writers := make(map[Writer]struct{}, w.platform.heap_allocator)
	for writer in e.snapshot.writers {
		writers[{moved[writer.saved], writer.track}] = {}
	}
	delete(e.snapshot.saved)
	delete(e.snapshot.writers)
	e.snapshot.saved = kept_saved
	e.snapshot.writers = writers
	clear(&e.snapshot.index)
	for saved, i in e.snapshot.saved {
		e.snapshot.index[saved.field] = i
	}
	e.time = clamp(e.time, blob.range_start, blob.range_end)
	for &last in e.last {
		last = e.time
	}
}

// put_back writes a saved field's value back, when its entity is alive and still has the component.
@(private)
put_back :: proc(w: ^ecs.World, saved: ^Saved) {
	p, ok := field_pointer(w, saved.field)
	if !ok {
		return
	}
	ecs.mark_changed(w, saved.field.entity, saved.field.component)
	mem.copy(p, &saved.bytes, int(saved.field.size))
}

@(private)
forget :: proc(s: ^Snapshot) {
	clear(&s.saved)
	clear(&s.index)
	clear(&s.writers)
}

// field_pointer is where a field is, and false when its entity is not alive, has no such component, or the field is
// outside the component.
@(private)
field_pointer :: proc(w: ^ecs.World, field: Field) -> (rawptr, bool) {
	if !ecs.is_alive(w, field.entity) {
		return nil, false
	}
	info := ecs.registry_find(&w.registry, field.component)
	if info == nil || int(field.offset) + int(field.size) > info.size {
		return nil, false
	}
	p := ecs.get_raw(w, field.entity, field.component)
	if p == nil {
		return nil, false
	}
	return rawptr(uintptr(p) + uintptr(field.offset)), true
}
