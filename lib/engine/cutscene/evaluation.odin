package cutscene

import "core:log"
import "core:mem"
import "core:slice"
import "core:time"

import "cinnabar:core"
import "cinnabar:engine/anim"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/audio"
import "cinnabar:engine/camera"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"
import "cinnabar:engine/ui"

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

// State is the cutscenes' part of the game: the kinds of track, and the players, whose evaluations the systems advance.
// The kinds hold procedures from the DLL image, so register clears them, and the kinds are registered again after it.
State :: struct {
	assets:        ^asset.Assets,
	// The input actions: their contexts, which a playing cutscene pushes its own on (see
	// docs/cinematics/possession.md), and the skip action, which the skip hold reads (see
	// docs/cinematics/skipping.md#input). Or nil.
	actions:       ^core.Input_Actions,
	// The skip action's name and hold time, and the hold in progress.
	skip:          Skip_Input,
	// The animation's state, which animation tracks drive Animators through (see
	// docs/cinematics/tracks.md#animation-tracks). Or nil, and animation tracks do nothing.
	animation:     ^anim.State,
	// The game's views, which camera cut tracks claim (see docs/cinematics/tracks.md#camera-cut-tracks). Or nil, and
	// camera cut tracks claim nothing.
	views:         ^camera.Views,
	// The game's audio, which audio tracks play their sounds through (see docs/cinematics/tracks.md#audio-tracks). Or
	// nil, and audio tracks play nothing.
	audio:         ^audio.State,
	// The game clock's rate against real time: its time scale, and 0 while the game is paused. set_rate sets it.
	rate:          f32,
	// How far an audio track's voice can drift from the cutscene's time before the track seeks it, in seconds.
	audio_drift:   f64,
	// The scripts that event tracks send their events to (see docs/cinematics/tracks.md#event-tracks). Or nil, and only
	// the native handlers get them.
	scripts:       ^script.Runtime,
	// The UI that the overlay's document shows in (see docs/cinematics/tracks.md#presentation-tracks). Or nil, and
	// nothing shows the presentation tracks.
	ui:            ^ui.State,
	// The overlay: its document, its settings and what it holds of a player that ended.
	overlay:       Overlay,
	kinds:         [format.Cutscene_Track_Kind]Track_Kind,
	// The event tracks' events that flush_events queued and send_events has not delivered yet, in order. Their names and
	// values are frame memory, so end_frame delivers what is left. Heap memory.
	outbox:        [dynamic]Sent,
	// The native handlers of events, by name, which register clears with the kinds.
	handlers:      [MAX_EVENT_HANDLERS]Event_Handler,
	handler_count: int,
	// The players, in fixed slots, so an evaluation does not move while it is evaluated (see
	// docs/cinematics/player.md#handles).
	players:       [MAX_PLAYERS]Player,
	// The start order that the next player gets.
	started:       u64,
	// The level generation that the players were made in. A new level resets them.
	level:         u64,
	// What happened to the players in this frame, in order. end_frame clears them. Heap memory.
	events:        [dynamic]Player_Event,
}

// Evaluation is what one cutscene needs to be evaluated: its blob, its bindings, its time and the snapshot of the
// fields that its tracks wrote. It holds no procedures, typeids or string literals, so it survives a code reload.
// Make it with init_evaluation, and free it with destroy_evaluation.
Evaluation :: struct {
	cutscene:     asset.Handle,
	bindings:     Bindings,
	// The cutscenes that its sub-sequence sections play, and theirs, in depth-first order (see
	// docs/cinematics/tracks.md#sub-sequence-tracks). The player loads them. Heap memory.
	children:     [dynamic]Child,
	// The key of the blobs of the tree that were last evaluated, the root's and its children's (see tree_key). A new key
	// is a hot reload. nil before the first evaluation.
	key:          Maybe(u64),
	// The time, in ticks, from range_start to range_end.
	time:         i32,
	// What the clock gave that is less than one tick, in nanoseconds × CUTSCENE_TICKS_PER_SECOND, so the conversion
	// never drifts.
	carry:        i64,
	// Where each phase's events have fired up to: its last evaluation's time, or a seek since it. nil before the first
	// evaluation, so the first fires the events at range_start.
	last:         [Phase]Phase_Mark,
	snapshot:     Snapshot,
	// The fields of the property tracks, by track ID, resolved once for the blob (see
	// docs/cinematics/tracks.md#property-tracks). A reload of the blob forgets them.
	targets:      map[Scoped]Property_Target,
	// What each transform track relative to another binding found at its first evaluation, by track ID: a cycle, or
	// where its binding starts in the other's space (see docs/cinematics/tracks.md#transform-tracks). A reload of the
	// blob keeps only the starts of the tracks that still join the same two bindings.
	spaces:       map[Scoped]Relative_Space,
	// The Animators that animation tracks drive, by entity, each through its driver's token (see
	// docs/cinematics/tracks.md#animation-tracks). restore, a reload and destroy_evaluation end them.
	drives:       map[ecs.Entity]anim.Drive_Token,
	// What the camera cut track shows, and the claim that it holds on the views for it. restore ends it.
	cut:          Cut,
	// Counts the seeks and the skips' jumps, so the camera cut track cuts after one, which an evaluation's range alone
	// cannot tell from a pause.
	jumps:        u32,
	// The voices of the audio tracks' sections, by section ID (see docs/cinematics/tracks.md#audio-tracks). end_holds
	// stops them.
	sounds:       map[Scoped]Sound_Voice,
	// What each audio track scrubbed last, by track ID, for an evaluation that scrubs.
	scrubs:       map[Scoped]Audio_Scrub,
	// How the audio tracks sound: a player's evaluation plays, and the editor sets the others' with set_audition. Only
	// an evaluation that plays sends events.
	audition:     Audition,
	// The player whose evaluation this is, which native event handlers get. The zero handle for an evaluation of no
	// player.
	player:       Player_Handle,
	// The event tracks' ranges that sent their begin and not yet their end, by event ID (see
	// docs/cinematics/tracks.md#event-tracks). change_range is its one writer.
	open_ranges:  map[Scoped]struct{},
	// The events that the event tracks recorded in this phase, which flush_events sends at its end.
	fired:        [dynamic]Fired,
	// The Animators that the animation tracks drive in this phase, and their clips, which drive_animators hands to the
	// driver at its end.
	driven:       [dynamic]Driven,
	driven_clips: [dynamic]Driven_Clip,
	// What the presentation tracks gave at the last Late phase, which the overlay shows (see present).
	presented:    Presentation,
}

// Phase_Mark is where a phase's events have fired up to.
Phase_Mark :: union {
	Evaluated,
	Sought,
}

// Evaluated is the time of a phase's last evaluation: its events have fired up to it.
Evaluated :: distinct i32

// Sought is a seek since a phase's last evaluation: its events fired up to origin, and the phase goes on from at.
// Several seeks before one evaluation are one move, from the first one's origin to the last one's time.
Sought :: struct {
	origin: i64,
	at:     i32,
}

// Seek_Range is a forward seek over (from, to] that a phase's evaluation follows.
Seek_Range :: struct {
	from, to: i64,
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
	field:  Field,
	bytes:  [MAX_FIELD_SIZE]byte,
	// Another player that held the field ended and wanted it put back, so this player puts it back when it ends, even
	// if only its tracks set to keep wrote it (see docs/cinematics/player.md#conflicts).
	handed: bool,
}

// Writer is a track, by its scope and its ID, that wrote a saved field.
@(private)
Writer :: struct {
	saved: int,
	track: Scoped,
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
	world:       ^ecs.World,
	// The state of the cutscenes, whose other players can hold a field's own value (see field_base).
	cutscenes:   ^State,
	evaluation:  ^Evaluation,
	data:        []byte,
	blob:        ^format.Cutscene_Blob,
	track:       format.Cutscene_Track,
	// The track's index in its blob.
	track_index: u32,
	// The cutscene of the tree that the track is in, and which: 0 for the root, and n for the evaluation's children[n - 1]
	// (see docs/cinematics/tracks.md#sub-sequence-tracks). data and blob are that cutscene's, and its bindings are found
	// through ctx_binding.
	scope:       Scope_Id,
	child:       int,
	// The track's place in the tree's order: the blob's order, with each child's tracks in its sub-sequence track's
	// place. Events at one time go in it.
	order:       u32,
	// The root's blob and clock, and the scope's range on its own time: the root's range, or a child's trim.
	root:        ^format.Cutscene_Blob,
	clock:       format.Cutscene_Clock,
	range_start: i32,
	range_end:   i32,
	// What the sub-sequence sections above the track give it: the product of their weights, which scales its sections'
	// weights, whether all of them cover the time, without which no section of the track covers it, and the scope's time
	// per the root's time.
	weight:      f32,
	covered:     bool,
	rate:        f64,
	// A loop of a sub-sequence above the track wrapped in (from, to], so the scope's time jumped back, as after a seek.
	wrapped:     bool,
	// The time on the root's time at which the scope's time is time, so root_time maps the scope's times back.
	anchor:      f64,
	// The evaluation crosses a cut of the camera cut tracks of the tree (see tree_cut_fires), on which transform tracks
	// teleport.
	cut:         bool,

	// The time to evaluate at, in ticks.
	time:        i32,
	// The events in (from, to] fire. The range is empty after a seek, a reload or the phase's last evaluation at the same
	// time. from is i64, so the first range can start before 0.
	from:        i64,
	to:          i64,
	// The evaluation is a skip's jump over (from, to] (see docs/cinematics/skipping.md#events): a kind fires only the
	// events that it marks to fire when skipped, and starts nothing that the jump passes, such as a sound.
	skipped:     bool,
	// A forward seek since the phase's last evaluation, before (from, to], which an event track follows: from is the
	// time that the phase's events had fired up to, and to is where the seek went.
	seek:        Maybe(Seek_Range),
	// The kind's data, from its Track_Kind.
	user:        rawptr,
}

// init sets the state's assets, its input actions, the animation's state and the level that its players begin in. Call
// register after it.
init :: proc(
	s: ^State,
	w: ^ecs.World,
	assets: ^asset.Assets,
	actions: ^core.Input_Actions = nil,
	animation: ^anim.State = nil,
	views: ^camera.Views = nil,
	sounds: ^audio.State = nil,
	scripts: ^script.Runtime = nil,
	interface: ^ui.State = nil,
) {
	s.assets = assets
	s.ui = interface
	s.overlay = {
		subtitles = DEFAULT_SUBTITLES,
	}
	s.audio = sounds
	s.scripts = scripts
	s.rate = 1
	s.audio_drift = AUDIO_DRIFT
	s.actions = actions
	s.animation = animation
	s.views = views
	set_skip_input(s, "", nil)
	s.events = make([dynamic]Player_Event, w.platform.heap_allocator)
	s.outbox = make([dynamic]Sent, w.platform.heap_allocator)
	s.level = level_of(w)
}

// destroy restores and frees every player, as reset does, and frees the events. Call it while the world and the
// assets are alive. It gives how many spawned roots it despawned.
destroy :: proc(s: ^State, w: ^ecs.World) -> (despawned: int) {
	despawned = reset(s, w)
	close_overlay(s)
	delete(s.events)
	s.events = nil
	delete(s.outbox)
	s.outbox = nil
	return
}

// register sets the engine's kinds of track, clearing any other, and makes the two systems. Call it with the world's
// registrations, before every other system's. A game can set a kind of its own with register_kind after it.
register :: proc(s: ^State, w: ^ecs.World) {
	s.kinds = {}
	s.handlers = {}
	s.handler_count = 0
	s.kinds[.Transform] = {
		phase    = .Fixed,
		evaluate = transform_track,
	}
	s.kinds[.Property] = {
		phase    = .Fixed,
		evaluate = property_track,
	}
	s.kinds[.Animation] = {
		phase    = .Fixed,
		evaluate = animation_track,
	}
	s.kinds[.Camera_Cut] = {
		phase    = .Late,
		evaluate = camera_cut_track,
	}
	s.kinds[.Audio] = {
		phase    = .Late,
		evaluate = audio_track,
	}
	s.kinds[.Presentation] = {
		phase    = .Late,
		evaluate = presentation_track,
	}
	// In the Fixed phase, so script.fixed_events delivers the events in the same tick, as animation markers are.
	s.kinds[.Event] = {
		phase    = .Fixed,
		evaluate = event_track,
	}
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
		targets = make(map[Scoped]Property_Target, w.platform.heap_allocator),
		spaces = make(map[Scoped]Relative_Space, w.platform.heap_allocator),
		drives = make(map[ecs.Entity]anim.Drive_Token, w.platform.heap_allocator),
		sounds = make(map[Scoped]Sound_Voice, w.platform.heap_allocator),
		scrubs = make(map[Scoped]Audio_Scrub, w.platform.heap_allocator),
		open_ranges = make(map[Scoped]struct{}, w.platform.heap_allocator),
		fired = make([dynamic]Fired, w.platform.heap_allocator),
		driven = make([dynamic]Driven, w.platform.heap_allocator),
		driven_clips = make([dynamic]Driven_Clip, w.platform.heap_allocator),
		children = make([dynamic]Child, w.platform.heap_allocator),
	}
}

// destroy_evaluation ends the drives of the Animators, destroys the bindings, which despawns what they spawned, and
// frees the snapshot. It gives how many spawned roots it despawned. It restores no field: call restore first for that.
destroy_evaluation :: proc(e: ^Evaluation, w: ^ecs.World) -> (despawned: int) {
	end_holds(e, w)
	delete(e.drives)
	e.drives = nil
	delete(e.sounds)
	e.sounds = nil
	delete(e.scrubs)
	e.scrubs = nil
	delete(e.open_ranges)
	e.open_ranges = nil
	delete(e.fired)
	e.fired = nil
	delete(e.driven)
	e.driven = nil
	delete(e.driven_clips)
	e.driven_clips = nil

	despawned = release_bindings(&e.bindings, w)
	destroy_bindings(&e.bindings, w)
	// The player loads the children, and close_children, their one teardown, unloads them before this.
	assert(len(e.children) == 0, "cutscene: close_children before destroy_evaluation")
	delete(e.children)

	e.children = nil
	delete(e.snapshot.saved)
	delete(e.snapshot.index)
	delete(e.snapshot.writers)
	e.snapshot = {}
	delete(e.targets)
	e.targets = nil
	delete(e.spaces)
	e.spaces = nil
	return
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
// new one fires, in either phase, but those that an event track marks to fire on seek, when the seek goes forward (see
// docs/cinematics/tracks.md#event-tracks).
seek :: proc(
	s: ^State,
	e: ^Evaluation,
	w: ^ecs.World,
	data: []byte,
	blob: ^format.Cutscene_Blob,
	t: i32,
) {
	follow_blob(s, e, w, data, blob)
	e.time = clamp(t, blob.range_start, blob.range_end)
	e.carry = 0
	e.jumps += 1
	for &mark in e.last {
		origin := i64(blob.range_start) - 1
		switch m in mark {
		case Evaluated:
			origin = i64(m)
		case Sought:
			origin = m.origin
		}
		mark = Sought{origin, e.time}
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
	run_phase(s, e, w, data, blob, phase, .Fire)
}

// skip_to jumps to a later time for a skip (see docs/cinematics/skipping.md#the-state): each phase evaluates once at the
// target, over the range from its last time, as skipped, so its kinds fire only the events marked to fire when
// skipped. The target is clamped into the range, and not before the time.
skip_to :: proc(
	s: ^State,
	e: ^Evaluation,
	w: ^ecs.World,
	data: []byte,
	blob: ^format.Cutscene_Blob,
	target: i32,
) {
	follow_blob(s, e, w, data, blob)
	e.time = clamp(target, e.time, blob.range_end)
	e.carry = 0
	e.jumps += 1
	for phase in Phase {
		run_phase(s, e, w, data, blob, phase, .Skip)
	}
}

// Events is what an evaluation does with the events since its phase's last time.
@(private)
Events :: enum u8 {
	// They fire, and the phase's last time moves to now.
	Fire,
	// They are skipped over: the kinds fire only those marked to fire when skipped, and the last time moves to now.
	Skip,
	// None fire, and the last time stays, for a skipping player that holds the world before its jump.
	Hold,
}

@(private)
run_phase :: proc(
	s: ^State,
	e: ^Evaluation,
	w: ^ecs.World,
	data: []byte,
	blob: ^format.Cutscene_Blob,
	phase: Phase,
	events: Events,
) {
	follow_blob(s, e, w, data, blob)
	if phase == .Late {
		// The presentation is a value of the time alone: the tracks of this phase make it again.
		e.presented = {
			key = e.key.? or_else 0,
		}
	}
	now := e.time
	from := i64(blob.range_start) - 1
	seek: Maybe(Seek_Range)
	switch m in e.last[phase] {
	case Evaluated:
		from = i64(m)
	case Sought:
		from = i64(m.at)
		if i64(m.at) > m.origin {
			seek = Seek_Range{m.origin, i64(m.at)}
		}
	}
	if events == .Hold {
		from = i64(now)
		seek = nil
	}
	ctx := Track_Context {
		world       = w,
		cutscenes   = s,
		evaluation  = e,
		data        = data,
		blob        = blob,
		root        = blob,
		clock       = blob.clock,
		range_start = blob.range_start,
		range_end   = blob.range_end,
		weight      = 1,
		covered     = true,
		rate        = 1,
		time        = now,
		from        = from,
		to          = max(i64(now), from),
		skipped     = events == .Skip,
		seek        = seek,
		anchor      = f64(now),
	}
	ctx.cut = tree_cut_fires(s, &ctx)
	// The children whose sections do not cover the time write their fields' own values first, so the root and the
	// children that cover the time win a field that both write (see docs/cinematics/tracks.md#sub-sequence-tracks).
	if len(e.children) > 0 {
		walk_scope(s, &ctx, phase, .Uncovered, 0)
	}
	walk_scope(s, &ctx, phase, .Covered, 0)
	if kind := s.kinds[.Camera_Cut];
	   kind.evaluate != nil && kind.phase == phase && tree_has_cuts(s, &ctx) {
		cut, _ := live_cut_track(data, blob)
		ctx.track = cut
		ctx.track_index, ctx.order = 0, 0
		ctx.user = kind.data
		kind.evaluate(&ctx)
	}
	if phase == .Fixed {
		drive_animators(s, e, w)
		constrain(&ctx)
		for i in 1 ..= len(e.children) {
			if inner, ok := scope_context(s, &ctx, i); ok && inner.covered {
				constrain(&inner)
			}
		}
	}
	if events != .Hold {
		e.last[phase] = Evaluated(now)
	}
	flush_events(s, e, w, data, blob)
}

// restore ends what the tracks did to the world: each saved field that a track set to restore wrote goes back to its
// value before the cutscene, and those that only tracks set to keep wrote stay. Every Animator that an animation track
// drives goes back to its graph, and the camera cut track gives the views back. A field that another player's snapshot
// also holds stays as it is: that player writes it while it plays, and gives it back when it ends (see
// docs/cinematics/player.md#conflicts). The snapshot is then empty. A field whose entity is gone, or no longer has the
// component, is skipped.
restore :: proc(
	s: ^State,
	e: ^Evaluation,
	w: ^ecs.World,
	data: []byte,
	blob: ^format.Cutscene_Blob,
) {
	follow_blob(s, e, w, data, blob)
	views := tree_views(s, e, w, data, blob)
	restores := make([]bool, len(e.snapshot.saved), w.platform.frame_allocator)
	for writer in e.snapshot.writers {
		if finish, found := writer_finish(views, writer.track); !found || finish == .Restore {
			restores[writer.saved] = true
		}
	}
	// Last saved first, so where two saved fields overlap, the one saved first, before any write, is what stays.
	#reverse for &saved, i in e.snapshot.saved {
		if restores[i] || saved.handed {
			put_back(s, e, w, &saved)
		}
	}
	forget(&e.snapshot)
	// At the end, the sounds that play through a skip, and past the end, go on; end_holds stops the others.
	release_sounds(e, w, blob)
	end_holds(e, w)
}

// restore_all puts back every saved field, and gives back every driven Animator, as restore does, for an evaluation
// whose blob is gone, so the tracks' settings are not known.
restore_all :: proc(s: ^State, e: ^Evaluation, w: ^ecs.World) {
	#reverse for &saved in e.snapshot.saved {
		put_back(s, e, w, &saved)
	}
	forget(&e.snapshot)
	end_holds(e, w)
}

// end_holds ends what the evaluation holds outside the snapshot: the drives of the Animators that its animation tracks
// drive, the camera cut track's claim on the views, and the audio tracks' voices. It is the one end of them, for
// restore, restore_all, a reload and destroy_evaluation, and it does nothing when the evaluation holds nothing.
@(private)
end_holds :: proc(e: ^Evaluation, w: ^ecs.World) {
	end_drives(e, w)
	end_cut(e)
	end_sounds(e, w)
}

// track_entity is the entity of the track's binding while it is alive, and false for a track without a binding, or
// whose binding is missing or gone.
track_entity :: proc(ctx: ^Track_Context) -> (ecs.Entity, bool) {
	if ctx.track.binding == format.CUTSCENE_NONE {
		return 0, false
	}
	return ctx_binding(ctx, ctx.track.binding)
}

// ctx_binding is the entity of a binding of the track's cutscene, by its index in the blob, while it is alive: in a
// child, a binding that its section maps is the parent's binding (see tree_binding).
ctx_binding :: proc(ctx: ^Track_Context, index: u32) -> (ecs.Entity, bool) {
	return tree_binding(ctx.evaluation, ctx.world, ctx.child, index)
}

// sample_section is section_at for a section of the track, at a time on the scope's time: in a child, no section covers the
// time while a sub-sequence section above it does not, and each weight is scaled by theirs.
sample_section :: proc(
	ctx: ^Track_Context,
	section: format.Cutscene_Section,
	t: i32,
) -> (
	at: Section_Sample,
	covers: bool,
) {
	if !ctx.covered {
		return {}, false
	}
	at = section_in(ctx.range_end, section, t) or_return
	at.weight *= ctx.weight
	return at, true
}

// root_time is a time on the scope's time as a time on the root's, through the sub-sequence sections above it at their
// loop now.
root_time :: proc(ctx: ^Track_Context, t: f64) -> f64 {
	if ctx.rate <= 0 {
		return ctx.anchor
	}
	return ctx.anchor + (t - f64(ctx.time)) / ctx.rate
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
	return section_in(blob.range_end, section, t)
}

// section_in is section_at in a range that ends at range_end.
@(private)
section_in :: proc(
	range_end: i32,
	section: format.Cutscene_Section,
	t: i32,
) -> (
	sample: Section_Sample,
	covers: bool,
) {
	lo := i64(section.start) - i64(section.pre_roll)
	hi := i64(section.end) + i64(section.post_roll)
	at := i64(t)
	if at < lo || at > hi || (at == hi && hi != i64(range_end)) {
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

// field_base reads a field's own value: as it was before any cutscene first wrote it, or as it is when no track has
// written it. A track blends over it, so the value at a time does not depend on what the track, or another player,
// wrote before. False when the entity is not alive or has no such component.
field_base :: proc(ctx: ^Track_Context, field: Field, out: []byte) -> bool {
	if int(field.size) != len(out) || field.size > MAX_FIELD_SIZE {
		return false
	}
	if i, saved := ctx.evaluation.snapshot.index[field]; saved {
		copy(out, ctx.evaluation.snapshot.saved[i].bytes[:field.size])
		return true
	}
	if other, held := held_elsewhere(ctx.cutscenes, ctx.evaluation, field); held {
		copy(out, other.bytes[:field.size])
		return true
	}
	p := field_pointer(ctx.world, field) or_return
	mem.copy(raw_data(out), p, int(field.size))
	return true
}

// write_field writes a field for the track. The first write of the field by any track saves it, and each track that
// writes it is remembered, so restore knows whether to put it back. When another player already holds the field, the
// value saved is that player's: the value before any cutscene wrote it. The component counts as changed. False when
// the entity is not alive, has no such component, or the field is larger than MAX_FIELD_SIZE.
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
		if other, held := held_elsewhere(ctx.cutscenes, ctx.evaluation, field); held {
			entry.bytes = other.bytes
		} else {
			mem.copy(&entry.bytes, p, int(field.size))
		}
		index = len(snapshot.saved)
		append(&snapshot.saved, entry)
		snapshot.index[field] = index
	}
	snapshot.writers[{index, {ctx.scope, ctx.track.id}}] = {}
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

// advance_real advances the playing cutscenes on the real clock by the frame's real duration, and evaluates their
// Fixed tracks, so the ticks that follow see them even while the game is paused. Call it in the frame code before the
// ticks.
advance_real :: proc(s: ^State, w: ^ecs.World, dt: time.Duration) {
	for p in in_order(s, w) {
		e := &live_of(&p.state).evaluation
		data, blob, ok := cutscene_data(s, e)
		if !ok || blob.clock != .Real || status_of(p.state) != .Playing {
			continue
		}
		advance(e, blob, dt)
		evaluate(s, e, w, data, blob, .Fixed)
	}
	send_events(s)
}

// fixed_system advances the playing cutscenes on the game's clock by the tick, and evaluates the Fixed tracks of every
// cutscene that plays, is paused or skips, in the players' order, so the player that wins a field writes it last. The
// tick's length is exact, from the world's clock, so the game's time scale and pause reach the cutscene through the
// ticks. A cutscene on the real clock moved in advance_real, so it evaluates again at the same time, and fires nothing.
@(private)
fixed_system :: proc(ctx: ^ecs.System_Context) {
	s := (^State)(ctx.data)
	w := ctx.world
	step := ecs.tick_time(w) - ecs.tick_start(&w.clock, w.clock.tick)
	for p in in_order(s, w) {
		e := &live_of(&p.state).evaluation
		data, blob, ok := cutscene_data(s, e)
		if !ok {
			continue
		}
		if blob.clock == .Game && status_of(p.state) == .Playing {
			advance(e, blob, step)
		}
		run_phase(s, e, w, data, blob, .Fixed, events_of(p))
	}
}

// late_system evaluates the Late tracks of every cutscene that plays, is paused or skips, in the players' order.
@(private)
late_system :: proc(ctx: ^ecs.System_Context) {
	s := (^State)(ctx.data)
	for p in in_order(s, ctx.world) {
		e := &live_of(&p.state).evaluation
		data, blob, ok := cutscene_data(s, e)
		if !ok {
			continue
		}
		run_phase(s, e, ctx.world, data, blob, .Late, events_of(p))
	}
}

// events_of is what the systems' evaluation of a player does with its events: a skipping player holds the world at its
// time and fires none, so its jump fires the range that it skips, as skipped.
@(private)
events_of :: proc(p: ^Player) -> Events {
	return .Hold if status_of(p.state) == .Skipping else .Fire
}

// in_order is the players that play, are paused or skip, in frame memory, by priority and then by start order, so the
// later of two players that write one field writes it last and wins (see docs/cinematics/player.md#conflicts).
@(private)
in_order :: proc(s: ^State, w: ^ecs.World) -> []^Player {
	found := make([dynamic]^Player, 0, MAX_PLAYERS, w.platform.frame_allocator)
	for &p in s.players {
		if status := status_of(p.state);
		   status == .Playing || status == .Paused || status == .Skipping {
			append(&found, &p)
		}
	}
	slice.sort_by(found[:], proc(a, b: ^Player) -> bool {
		if a.priority != b.priority {
			return a.priority < b.priority
		}
		return a.order < b.order
	})
	return found[:]
}

// held_elsewhere is another player's saved value of a field: the value before any cutscene wrote it, as the first
// player that wrote it saved it.
@(private)
held_elsewhere :: proc(s: ^State, e: ^Evaluation, field: Field) -> (^Saved, bool) {
	if s == nil {
		return nil, false
	}
	for &p in s.players {
		live := live_of(&p.state)
		if live == nil || &live.evaluation == e {
			continue
		}
		if i, saved := live.evaluation.snapshot.index[field]; saved {
			return &live.evaluation.snapshot.saved[i], true
		}
	}
	return nil, false
}

// follow_blob notices a new blob, by its key, and reloads. Every procedure that takes the evaluation's blob calls it
// first, so none of them acts on a blob that the evaluation has not followed.
@(private)
follow_blob :: proc(
	s: ^State,
	e: ^Evaluation,
	w: ^ecs.World,
	data: []byte,
	blob: ^format.Cutscene_Blob,
) {
	key := tree_key(s, e, blob)
	if seen, known := e.key.?; known && seen != key {
		reload(s, e, w, data, blob)
	}
	e.key = key
}

// reload follows a new blob: the time stays, within the new range, the fields that only removed tracks wrote are
// restored, the driven Animators are given back, and the next evaluation of each phase fires no events.
@(private)
reload :: proc(
	s: ^State,
	e: ^Evaluation,
	w: ^ecs.World,
	data: []byte,
	blob: ^format.Cutscene_Blob,
) {
	views := tree_views(s, e, w, data, blob)
	kept := make([]bool, len(e.snapshot.saved), w.platform.frame_allocator)
	gone := make([dynamic]Writer, w.platform.frame_allocator)
	for writer in e.snapshot.writers {
		if _, found := writer_finish(views, writer.track); found {
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
	#reverse for &saved, i in e.snapshot.saved {
		if !kept[i] {
			put_back(s, e, w, &saved)
		}
	}
	for saved, i in e.snapshot.saved {
		if kept[i] {
			moved[i] = len(kept_saved)
			append(&kept_saved, saved)
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
	clear(&e.targets)
	keep_spaces(e, w, views)
	// The tracks of the new blob take their Animators and claim the views again as they evaluate, so a track that the
	// reload removed or muted gives its back.
	end_holds(e, w)
	keep_ranges(e, w, views)
	e.time = clamp(e.time, blob.range_start, blob.range_end)
	for &mark in e.last {
		mark = Evaluated(e.time)
	}
}

// put_back writes a saved field's value back, when its entity is alive and still has the component. When another
// player holds the field, it hands the put-back to that player, which writes the field on until it ends.
@(private)
put_back :: proc(s: ^State, e: ^Evaluation, w: ^ecs.World, saved: ^Saved) {
	if other, held := held_elsewhere(s, e, saved.field); held {
		other.handed = true
		return
	}
	p, ok := field_pointer(w, saved.field)
	if !ok {
		return
	}
	ecs.mark_changed(w, saved.field.entity, saved.field.component)
	mem.copy(p, &saved.bytes, int(saved.field.size))
	// A pose that goes back moves at once, with what is under it, so presentation does not interpolate to it.
	if saved.field.component == ecs.TRANSFORM_ID ||
	   saved.field.component == ecs.LOCAL_TRANSFORM_ID {
		settle_pose(w, saved.field.entity, true)
	}
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
