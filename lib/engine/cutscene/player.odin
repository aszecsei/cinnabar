package cutscene

import "core:hash"
import "core:log"
import "core:mem"
import "core:strings"
import "core:time"

import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/scene"
import "cinnabar:engine/script"

// MAX_PLAYERS is how many players the state holds at once, whatever their state.
MAX_PLAYERS :: 32

// Player_Handle names a player: its slot and the slot's generation when it began. A handle whose slot holds another
// player, or none, is stale, and a call through it does nothing. The zero handle is always stale.
Player_Handle :: struct {
	slot:       u16,
	generation: u32,
}

// Player_Status is the kind of a player's state, which callers ask for. Gone is a stale handle's.
Player_Status :: enum u8 {
	Gone,
	Loading,
	Ready,
	Playing,
	Paused,
	Skipping,
	Finishing,
	Restored,
	Failed,
}

// Player_State is where a player is (see docs/cinematics/player.md#the-states), with the data of that state. nil is a
// free slot. Change it only with change_cutscene.
Player_State :: union {
	Player_Loading,
	Player_Ready,
	Player_Playing,
	Player_Paused,
	Player_Skipping,
	Player_Finishing,
	Player_Restored,
	Player_Failed,
}

// When_Ready is what a loading player does once it is ready, when it does not skip.
When_Ready :: enum u8 {
	// It waits in Ready for start.
	Hold,
	// It plays.
	Play,
}

// Player_Loading is a player whose cutscene, the assets that the cutscene references, and its bindings are not loaded
// yet. update loads them, outside the script phase.
Player_Loading :: struct {
	cutscene:   format.Guid,
	when_ready: When_Ready,
	// A skip came while it loaded: once ready, it skips from its start if the cutscene lets it, and does as when_ready
	// says if not.
	skip:       bool,
	// The caller's overrides. A binding named by its name has its own copy of the name on the heap.
	overrides:  [dynamic]Binding_Override,
}

// Player_Live is what a loaded player holds from Ready to Finishing: its evaluation, whose time is the player's time,
// the assets that it holds loaded, and the overrides, by binding ID, that its bindings resolve with again after a
// reload.
Player_Live :: struct {
	evaluation: Evaluation,
	// The assets that the cutscene references, loaded for it. The cutscene's own asset is the evaluation's.
	references: [dynamic]asset.Handle,
	overrides:  [dynamic]Binding_Override,
	// A hash of the blob's bindings when they resolved. A reload that changes them resolves them again.
	bindings:   u64,
	// The input context and the UI documents that the player holds from its first Playing or Skipping.
	hold:       Player_Hold,
}

// Player_Ready is a loaded player that has not begun: everything is loaded and resolved, the spawned entities are hidden,
// and the first frame can be evaluated at once.
Player_Ready :: struct {
	using live: Player_Live,
}

// Player_Playing is a player whose time moves on its clock.
Player_Playing :: struct {
	using live: Player_Live,
}

// Player_Paused is a player whose time stands still. Its tracks still hold the world at the time.
Player_Paused :: struct {
	using live: Player_Live,
}

// Skip_Fade is the part of a skip that runs (see docs/cinematics/skipping.md#the-state).
Skip_Fade :: enum u8 {
	// The fade out. At its end, the player jumps to the target.
	Out,
	// The jump is done, and play goes on after the fade in.
	In,
}

// Player_Skipping is a player that skips to a later time behind a fade: it fades out, evaluates the target with the
// events that fire when skipped, and then goes to Finishing at the end, or fades in and plays on. Its time stands still,
// as a paused player's does, and its tracks hold the world at it.
Player_Skipping :: struct {
	using live: Player_Live,
	// Where the skip goes: the end of the range, or the end of a skip range.
	target:     i32,
	fade:       Skip_Fade,
	// How long the fade has run, in real time.
	elapsed:    time.Duration,
}

// Player_Finishing is a player whose cutscene is over: its last evaluation is done, and the world is given back next.
Player_Finishing :: struct {
	using live: Player_Live,
}

// Player_Restored is a player that gave the world back: its fields are restored, its spawned entities are gone, and its
// assets are unloaded. The handle can be dropped.
Player_Restored :: struct {}

// Player_Failed is a player that could not go on. What it had changed is restored, as for Player_Restored.
Player_Failed :: struct {
	failure: Failure,
}

// Failure is why a player failed. It holds no strings, so a player keeps it across a code reload.
Failure :: union {
	Asset_Failure,
	Binding_Failure,
}

Asset_Failure_Reason :: enum u8 {
	// The cutscene's blob did not load.
	Missing,
	// The blob is not a cutscene, or does not check.
	Not_A_Cutscene,
	// An asset that the cutscene references, such as a clip, a sound or a prefab, did not load.
	Reference_Missing,
}

// Asset_Failure is an asset that did not load: the cutscene, or one that it references.
Asset_Failure :: struct {
	asset:  format.Guid,
	reason: Asset_Failure_Reason,
}

// Player is one slot of the players: the generation of the handles to it, and the player in it.
Player :: struct {
	generation: u32,
	// The higher priority wins a field that two players write; at the same priority, the later start does.
	priority:   i32,
	// When the player began, from State.started.
	order:      u64,
	state:      Player_State,
}

// Player_Event is a change of a player's state, which change_cutscene records.
Player_Event :: struct {
	player: Player_Handle,
	status: Player_Status,
}

// Play_Desc is what a player plays: the cutscene, its priority, and the entities that the caller gives for bindings.
Play_Desc :: struct {
	cutscene:  format.Guid,
	priority:  i32,
	overrides: []Binding_Override,
}

// Player_Context is what update needs to load cutscenes and resolve bindings: the world, its scenes, the scripts that
// a spawned prefab's behaviours attach to (or nil), and the frame's real duration, which a skip's fades run on.
Player_Context :: struct {
	world:   ^ecs.World,
	scenes:  ^scene.Scenes,
	scripts: ^script.Runtime,
	dt:      time.Duration,
}

// Command_Result is what a command did. Gone is a stale handle, or a player that is Restored or Failed: nothing
// happens. Refused is a command that the player's state does not take, which change_cutscene logs. Not_Skippable is a
// skip at a time that the cutscene's skip policy does not let a player skip: nothing happens, and nothing is logged.
Command_Result :: enum u8 {
	Done,
	Gone,
	Refused,
	Not_Skippable,
}

// load makes a player of a cutscene that waits in Ready once it has loaded, for start. It loads in the next update. It
// gives false when every slot holds a player that has not ended.
load :: proc(s: ^State, w: ^ecs.World, desc: Play_Desc) -> (Player_Handle, bool) {
	return begin(s, w, desc, .Hold)
}

// play makes a player of a cutscene that plays as soon as it has loaded, in the next update. See load.
play :: proc(s: ^State, w: ^ecs.World, desc: Play_Desc) -> (Player_Handle, bool) {
	return begin(s, w, desc, .Play)
}

// start plays a Ready player, and has a loading one play once it is ready.
start :: proc(s: ^State, w: ^ecs.World, h: Player_Handle) -> Command_Result {
	slot := command_slot(s, h) or_return
	p := &s.players[slot]
	switch &state in p.state {
	case Player_Loading:
		if state.when_ready == .Hold {
			state.when_ready = .Play
		}
		return .Done
	case Player_Ready:
		return change_or_refuse(s, w, slot, moved(p, .Playing))
	case Player_Playing:
		return .Done
	case Player_Paused, Player_Skipping, Player_Finishing, Player_Restored, Player_Failed:
	}
	return refuse(s, slot, .Playing)
}

// pause stops a playing player's time. Its tracks hold the world at the time.
pause :: proc(s: ^State, w: ^ecs.World, h: Player_Handle) -> Command_Result {
	slot := command_slot(s, h) or_return
	p := &s.players[slot]
	#partial switch status_of(p.state) {
	case .Playing:
		return change_or_refuse(s, w, slot, moved(p, .Paused))
	case .Paused:
		return .Done
	}
	return refuse(s, slot, .Paused)
}

// resume plays a paused player on from its time.
resume :: proc(s: ^State, w: ^ecs.World, h: Player_Handle) -> Command_Result {
	slot := command_slot(s, h) or_return
	p := &s.players[slot]
	#partial switch status_of(p.state) {
	case .Paused:
		return change_or_refuse(s, w, slot, moved(p, .Playing))
	case .Playing:
		return .Done
	}
	return refuse(s, slot, .Playing)
}

// stop ends a player without the rest of its cutscene: it goes to Finishing at its time, and the next update gives
// the world back. A loading player ends at once, as nothing has changed.
stop :: proc(s: ^State, w: ^ecs.World, h: Player_Handle) -> Command_Result {
	slot := command_slot(s, h) or_return
	p := &s.players[slot]
	switch status_of(p.state) {
	case .Loading:
		return change_or_refuse(s, w, slot, Player_Restored{})
	case .Ready, .Playing, .Paused, .Skipping:
		return change_or_refuse(s, w, slot, moved(p, .Finishing))
	case .Finishing:
		return .Done
	case .Gone, .Restored, .Failed:
	}
	return refuse(s, slot, .Finishing)
}

// skip has a player skip from its time, as its cutscene's skip policy says: to the end, or to the end of the skip range
// that holds the time (see docs/cinematics/skipping.md). The next updates fade out, evaluate the target, and give the
// world back or play on. A loading player skips from its start once it is ready. A skip at a time that cannot be
// skipped is Not_Skippable. A second skip does nothing.
skip :: proc(s: ^State, w: ^ecs.World, h: Player_Handle) -> Command_Result {
	slot := command_slot(s, h) or_return
	p := &s.players[slot]
	switch &state in p.state {
	case Player_Loading:
		state.skip = true
		return .Done
	case Player_Ready, Player_Playing, Player_Paused:
		target, ok := skip_target(s, &live_of(&p.state).evaluation)
		if !ok {
			return .Not_Skippable
		}
		return change_or_refuse(s, w, slot, skipping(p, target))
	case Player_Skipping, Player_Finishing:
		return .Done
	case Player_Restored, Player_Failed:
	}
	return refuse(s, slot, .Skipping)
}

// can_skip is whether a skip of the player would skip now: whether it is Ready, Playing or Paused at a time that its
// cutscene lets a player skip.
can_skip :: proc(s: ^State, h: Player_Handle) -> bool {
	slot := slot_of(s, h) or_return
	p := &s.players[slot]
	#partial switch status_of(p.state) {
	case .Ready, .Playing, .Paused:
		_, ok := skip_target(s, &live_of(&p.state).evaluation)
		return ok
	}
	return false
}

// skip_fade is how much a skipping player's fade covers the frame, from 0 to 1, and 0 for any other player. The
// presentation track (#546) draws it.
skip_fade :: proc(s: ^State, h: Player_Handle) -> f32 {
	slot, found := slot_of(s, h)
	if !found {
		return 0
	}
	state, is_skipping := s.players[slot].state.(Player_Skipping)
	if !is_skipping {
		return 0
	}
	length := skip_fade_length(s, &state.evaluation)
	if length <= 0 {
		return 1 if state.fade == .Out else 0
	}
	progress := f32(clamp(f64(state.elapsed) / f64(length), 0, 1))
	return progress if state.fade == .Out else 1 - progress
}

// set_time seeks a Ready, playing or paused player to a time on its cutscene's time, for a debugger and for the editor.
// No event between the old time and the new one fires (see seek).
set_time :: proc(s: ^State, w: ^ecs.World, h: Player_Handle, t: i32) -> Command_Result {
	slot := command_slot(s, h) or_return
	p := &s.players[slot]
	#partial switch status_of(p.state) {
	case .Ready, .Playing, .Paused:
		e := &live_of(&p.state).evaluation
		data, blob, ok := cutscene_data(s, e)
		if !ok {
			return .Refused
		}
		seek(s, e, w, data, blob, t)
		return .Done
	}
	log.errorf("cutscene: a %v player cannot seek", status_of(p.state))
	return .Refused
}

// release frees the slot of a player that is Restored or Failed, so its handle is stale. A player that has not ended
// is not released: stop it first. A stale handle is Gone.
release :: proc(s: ^State, w: ^ecs.World, h: Player_Handle) -> Command_Result {
	slot, found := slot_of(s, h)
	if !found {
		return .Gone
	}
	return change_or_refuse(s, w, slot, nil)
}

// status is the state of the player that a handle names, and Gone for a stale handle.
status :: proc(s: ^State, h: Player_Handle) -> Player_Status {
	slot, found := slot_of(s, h)
	if !found {
		return .Gone
	}
	return status_of(s.players[slot].state)
}

// player_time is the time of a player from Ready to Finishing, in ticks, and false for any other.
player_time :: proc(s: ^State, h: Player_Handle) -> (t: i32, ok: bool) {
	e := player_evaluation(s, h) or_return
	return e.time, true
}

// player_failure is why a Failed player failed, and false for any other.
player_failure :: proc(s: ^State, h: Player_Handle) -> (failure: Failure, ok: bool) {
	slot := slot_of(s, h) or_return
	failed, is_failed := s.players[slot].state.(Player_Failed)
	return failed.failure, is_failed
}

// player_evaluation is the evaluation of a player from Ready to Finishing, and false for any other. It moves when the
// player's state changes, so do not keep it.
player_evaluation :: proc(s: ^State, h: Player_Handle) -> (e: ^Evaluation, ok: bool) {
	slot := slot_of(s, h) or_return
	live := live_of(&s.players[slot].state)
	if live == nil {
		return nil, false
	}
	return &live.evaluation, true
}

// player_events is what happened to the players in this frame, in order, until end_frame.
player_events :: proc(s: ^State) -> []Player_Event {
	return s.events[:]
}

// update moves the players on in the frame code, outside the systems and the script phase (see
// docs/cinematics/player.md#the-frame). A new level resets every player first. A loading player loads its cutscene and
// what it references, and resolves its bindings: it is Ready, or Failed with the reason. A live player whose blob's
// bindings changed in a reload resolves them again. A skipping player runs its fade, and jumps to its target at the end
// of the fade out (see docs/cinematics/skipping.md#the-state). A playing player at its end
// has its last evaluation. A finishing player gives the world back and is Restored. It gives how many spawned roots it
// despawned, so the caller can have its systems forget them.
update :: proc(s: ^State, c: Player_Context) -> (despawned: int) {
	w := c.world
	despawned += follow_level(s, w)
	for slot in 0 ..< MAX_PLAYERS {
		p := &s.players[slot]
		if _, loading := p.state.(Player_Loading); loading {
			load_player(s, c, slot)
		}
		if live := live_of(&p.state); live != nil {
			despawned += follow_bindings(s, c, slot)
		}
		if live := live_of(&p.state); live != nil {
			e := &live.evaluation
			data, blob, ok := cutscene_data(s, e)
			if !ok {
				_, gave_back := fail(
					s,
					w,
					slot,
					Asset_Failure{asset.guid(s.assets, e.cutscene), .Missing},
				)
				despawned += gave_back
				continue
			}
			#partial switch status_of(p.state) {
			case .Skipping:
				run_skip(s, w, slot, c.dt, data, blob)
			case .Playing:
				if e.time == blob.range_end {
					// The events of the last range fire here when no tick or Late stage has reached the end yet.
					evaluate(s, e, w, data, blob, .Fixed)
					evaluate(s, e, w, data, blob, .Late)
					change_cutscene(s, w, slot, moved(p, .Finishing))
				}
			}
		}
		// The fades out (#546) will hold a player in Finishing. Until then, it gives the world back at once.
		if _, finishing := p.state.(Player_Finishing); finishing {
			_, gave_back := change_cutscene(s, w, slot, Player_Restored{})
			despawned += gave_back
		}
	}
	return
}

// reset restores and frees every player, whatever its state, so every handle is stale, and ends a hold of the skip
// action. A soft restart and a new level both go through it. It gives how many spawned roots it despawned.
reset :: proc(s: ^State, w: ^ecs.World) -> (despawned: int) {
	s.skip.state = nil
	for slot in 0 ..< MAX_PLAYERS {
		p := &s.players[slot]
		switch status_of(p.state) {
		case .Loading:
			change_cutscene(s, w, slot, Player_Restored{})
		case .Ready, .Playing, .Paused, .Skipping:
			change_cutscene(s, w, slot, moved(p, .Finishing))
		case .Gone, .Finishing, .Restored, .Failed:
		}
		if _, finishing := p.state.(Player_Finishing); finishing {
			_, gave_back := change_cutscene(s, w, slot, Player_Restored{})
			despawned += gave_back
		}
		if p.state != nil {
			change_cutscene(s, w, slot, nil)
		}
	}
	return
}

// end_frame forgets the frame's events.
end_frame :: proc(s: ^State) {
	clear(&s.events)
}

// change_cutscene is the one writer of a player's state (see docs/cinematics/player.md#the-states). It refuses, and logs,
// a change that the diagram does not allow. It frees the data of the state that the player leaves: a loading player's
// overrides, and a live player's evaluation when it goes to Restored or Failed, which restores what its tracks wrote,
// despawns what it spawned and unloads its assets. A Ready player that plays or skips shows its spawned entities. Each
// change is a Player_Event. It gives whether it changed, and how many spawned roots it despawned.
change_cutscene :: proc(
	s: ^State,
	w: ^ecs.World,
	slot: int,
	to: Player_State,
) -> (
	changed: bool,
	despawned: int,
) {
	p := &s.players[slot]
	from := status_of(p.state)
	next := status_of(to)
	if !allowed(from, next) {
		refuse(s, slot, next)
		return false, 0
	}
	switch &state in p.state {
	case Player_Loading:
		free_overrides(&state.overrides)
	case Player_Ready, Player_Playing, Player_Paused, Player_Skipping, Player_Finishing:
		if next == .Restored || next == .Failed {
			despawned = give_back(s, w, live_of(&p.state))
		}
	case Player_Restored, Player_Failed:
	}
	p.state = to
	if from == .Ready && (next == .Playing || next == .Skipping) {
		live := live_of(&p.state)
		reveal_bindings(&live.evaluation.bindings, w)
		take_hold(s, w, live)
	}
	append(&s.events, Player_Event{{u16(slot), p.generation}, next})
	return true, despawned
}

// status_of is the kind of a player's state.
status_of :: proc(state: Player_State) -> Player_Status {
	switch _ in state {
	case Player_Loading:
		return .Loading
	case Player_Ready:
		return .Ready
	case Player_Playing:
		return .Playing
	case Player_Paused:
		return .Paused
	case Player_Skipping:
		return .Skipping
	case Player_Finishing:
		return .Finishing
	case Player_Restored:
		return .Restored
	case Player_Failed:
		return .Failed
	}
	return .Gone
}

// live_of is the live data of a player from Ready to Finishing, and nil for any other.
live_of :: proc(state: ^Player_State) -> ^Player_Live {
	switch &s in state {
	case Player_Ready:
		return &s.live
	case Player_Playing:
		return &s.live
	case Player_Paused:
		return &s.live
	case Player_Skipping:
		return &s.live
	case Player_Finishing:
		return &s.live
	case Player_Loading, Player_Restored, Player_Failed:
	}
	return nil
}

// moved is a live state with the live data that a live player holds now, for a change from one live state to another.
// Build the change with it at the moment of the change, so the change carries what the last evaluation saved. A skip
// has data of its own: build it with skipping.
moved :: proc(p: ^Player, to: Player_Status) -> Player_State {
	live := live_of(&p.state)
	assert(live != nil, "cutscene: only a live player moves its data")
	#partial switch to {
	case .Ready:
		return Player_Ready{live^}
	case .Playing:
		return Player_Playing{live^}
	case .Paused:
		return Player_Paused{live^}
	case .Finishing:
		return Player_Finishing{live^}
	}
	panic("cutscene: moved takes a live state other than Skipping")
}

// skipping is the Skipping state of a live player that skips to a target, at the start of its fade out, as moved builds
// the other live states.
skipping :: proc(p: ^Player, target: i32) -> Player_State {
	live := live_of(&p.state)
	assert(live != nil, "cutscene: only a live player skips")
	return Player_Skipping{live = live^, target = target}
}

// allowed is whether the state diagram has a change (see docs/cinematics/player.md#the-states). Gone is a free slot.
allowed :: proc(from, to: Player_Status) -> bool {
	switch from {
	case .Gone:
		return to == .Loading
	case .Loading:
		return to == .Ready || to == .Restored || to == .Failed
	case .Ready:
		return to == .Playing || to == .Skipping || to == .Finishing || to == .Failed
	case .Playing:
		return to == .Paused || to == .Skipping || to == .Finishing || to == .Failed
	case .Paused:
		return to == .Playing || to == .Skipping || to == .Finishing || to == .Failed
	case .Skipping:
		return to == .Playing || to == .Finishing || to == .Failed
	case .Finishing:
		return to == .Restored || to == .Failed
	case .Restored, .Failed:
		return to == .Gone
	}
	return false
}

// begin takes a slot for a new player in Loading: a free one, or else the one of the earliest player that ended.
@(private = "file")
begin :: proc(
	s: ^State,
	w: ^ecs.World,
	desc: Play_Desc,
	when_ready: When_Ready,
) -> (
	h: Player_Handle,
	ok: bool,
) {
	// A player made after a level unloaded, before the next update, belongs to the new level: the old level's players
	// are reset first. Their entities went with the level, so nothing is left for the systems to forget.
	follow_level(s, w)
	slot := -1
	for p, i in s.players {
		if p.state == nil {
			slot = i
			break
		}
	}
	if slot < 0 {
		for p, i in s.players {
			if status := status_of(p.state); status == .Restored || status == .Failed {
				if slot < 0 || p.order < s.players[slot].order {
					slot = i
				}
			}
		}
		if slot < 0 {
			log.errorf("cutscene: %d cutscenes are playing, so no other can", MAX_PLAYERS)
			return {}, false
		}
		change_cutscene(s, w, slot, nil)
	}
	p := &s.players[slot]
	// A generation of 0 is no handle's, so the zero handle is always stale.
	p.generation += 1
	if p.generation == 0 {
		p.generation = 1
	}
	p.priority = desc.priority
	p.order = s.started
	s.started += 1
	overrides := make([dynamic]Binding_Override, 0, len(desc.overrides), w.platform.heap_allocator)
	for o in desc.overrides {
		o := o
		if name, by_name := o.binding.(string); by_name {
			o.binding = strings.clone(name, w.platform.heap_allocator)
		}
		append(&overrides, o)
	}
	change_cutscene(
		s,
		w,
		slot,
		Player_Loading{cutscene = desc.cutscene, when_ready = when_ready, overrides = overrides},
	)
	return {u16(slot), p.generation}, true
}

// load_player loads a loading player's cutscene, the assets that it references, and its bindings. The player is then
// Ready, and plays or skips as asked, or is Failed with the reason and nothing changed.
@(private = "file")
load_player :: proc(s: ^State, c: Player_Context, slot: int) {
	w := c.world
	p := &s.players[slot]
	loading := p.state.(Player_Loading)
	handle, loaded := asset.load(s.assets, loading.cutscene)
	if !loaded {
		fail(s, w, slot, Asset_Failure{loading.cutscene, .Missing})
		return
	}
	data, _ := asset.data(s.assets, handle)
	blob, is_cutscene := format.cutscene_view(data)
	references, checked := format.blob_references(data, w.platform.frame_allocator)
	if !is_cutscene || !checked {
		asset.unload(s.assets, handle)
		fail(s, w, slot, Asset_Failure{loading.cutscene, .Not_A_Cutscene})
		return
	}
	live := Player_Live {
		references = make([dynamic]asset.Handle, 0, len(references), w.platform.heap_allocator),
		overrides  = make(
			[dynamic]Binding_Override,
			0,
			len(loading.overrides),
			w.platform.heap_allocator,
		),
		bindings   = bindings_hash(data, blob),
	}
	init_evaluation(&live.evaluation, w, handle, data, blob)
	for guid in references {
		reference, ok := asset.load(s.assets, guid)
		if !ok {
			log.errorf(
				"cutscene: %s: an asset that it references did not load",
				format.blob_string(data, blob.source_path),
			)
			give_back(s, w, &live)
			fail(s, w, slot, Asset_Failure{guid, .Reference_Missing})
			return
		}
		append(&live.references, reference)
	}
	bindings := format.cutscene_bindings(data, blob)
	for o in loading.overrides {
		if index, found := binding_index(data, blob, o.binding); found {
			append(&live.overrides, Binding_Override{Binding_Id(bindings[index].id), o.entity})
		} else {
			log.warnf(
				"cutscene: %s: no binding %v to override",
				format.blob_string(data, blob.source_path),
				o.binding,
			)
		}
	}
	if failure, failed := resolve_bindings(
		   &live.evaluation.bindings,
		   resolve_of(s, c, data, blob),
		   live.overrides[:],
	   ).?; failed {
		give_back(s, w, &live)
		fail(s, w, slot, failure)
		return
	}
	when_ready, skips := loading.when_ready, loading.skip
	change_cutscene(s, w, slot, Player_Ready{live})
	if skips {
		if target, ok := skip_target(s, &live_of(&p.state).evaluation); ok {
			change_cutscene(s, w, slot, skipping(p, target))
			return
		}
		log.infof(
			"cutscene: %s: a skip came while it loaded, but its start cannot be skipped",
			format.blob_string(data, blob.source_path),
		)
	}
	switch when_ready {
	case .Hold:
	case .Play:
		change_cutscene(s, w, slot, moved(p, .Playing))
	}
}

// run_skip moves a skipping player's fade on by the frame's real duration. At the end of the fade out, the player jumps
// to its target (skip_to), and goes to Finishing at the range's end or fades in. At the end of the fade in, it plays
// on. A fade of 0 ticks does all of it in one update.
@(private = "file")
run_skip :: proc(
	s: ^State,
	w: ^ecs.World,
	slot: int,
	dt: time.Duration,
	data: []byte,
	blob: ^format.Cutscene_Blob,
) {
	p := &s.players[slot]
	state := &p.state.(Player_Skipping)
	length := skip_fade_length(s, &state.evaluation)
	state.elapsed += max(dt, 0)
	if state.fade == .Out {
		if state.elapsed < length {
			return
		}
		skip_to(s, &state.evaluation, w, data, blob, state.target)
		if state.evaluation.time >= blob.range_end {
			change_cutscene(s, w, slot, moved(p, .Finishing))
			return
		}
		state.fade = .In
		state.elapsed = 0
	}
	if state.elapsed >= length {
		change_cutscene(s, w, slot, moved(p, .Playing))
	}
}

// skip_target is where a skip of a live player goes from its time, and false when its cutscene does not let the time be
// skipped, or its blob is gone.
@(private = "file")
skip_target :: proc(s: ^State, e: ^Evaluation) -> (target: i32, ok: bool) {
	data, blob := cutscene_data(s, e) or_return
	return format.cutscene_skip_target(data, blob, e.time)
}

// skip_fade_length is the length of a skip's fade out, and of its fade in, from the blob's ticks.
@(private = "file")
skip_fade_length :: proc(s: ^State, e: ^Evaluation) -> time.Duration {
	_, blob, ok := cutscene_data(s, e)
	if !ok {
		return 0
	}
	return time.Duration(i64(blob.skip_fade) * i64(time.Second) / format.CUTSCENE_TICKS_PER_SECOND)
}

// follow_bindings resolves a live player's bindings again when a reload changed them. The spawned entities spawn
// again, and show at once unless the player is Ready. A binding that no longer resolves fails the player. It gives how
// many spawned roots it despawned.
@(private = "file")
follow_bindings :: proc(s: ^State, c: Player_Context, slot: int) -> (despawned: int) {
	w := c.world
	p := &s.players[slot]
	live := live_of(&p.state)
	data, blob, ok := cutscene_data(s, &live.evaluation)
	if !ok {
		return
	}
	current := bindings_hash(data, blob)
	if current == live.bindings {
		return
	}
	live.bindings = current
	for state in live.evaluation.bindings.states {
		if _, spawned := state.(Binding_Spawned); spawned {
			despawned += 1
		}
	}
	if failure, failed := resolve_bindings(
		   &live.evaluation.bindings,
		   resolve_of(s, c, data, blob),
		   live.overrides[:],
	   ).?; failed {
		_, gave_back := fail(s, w, slot, failure)
		return despawned + gave_back
	}
	if status_of(p.state) != .Ready {
		reveal_bindings(&live.evaluation.bindings, w)
	}
	return
}

// fail logs why a player failed, and changes it to Failed, which gives back what it changed.
@(private = "file")
fail :: proc(
	s: ^State,
	w: ^ecs.World,
	slot: int,
	failure: Failure,
) -> (
	changed: bool,
	despawned: int,
) {
	buffer: [32]u8
	switch f in failure {
	case Asset_Failure:
		log.errorf(
			"cutscene: a player failed: the asset %s: %v",
			format.guid_format(f.asset, &buffer),
			f.reason,
		)
	case Binding_Failure:
		log.errorf("cutscene: a player failed: the binding at %d: %v", f.index, f.reason)
	}
	return change_cutscene(s, w, slot, Player_Failed{failure})
}

// give_back ends what a live player did: it restores what its tracks wrote, despawns what it spawned, and unloads its
// assets. It gives how many spawned roots it despawned.
@(private = "file")
give_back :: proc(s: ^State, w: ^ecs.World, live: ^Player_Live) -> (despawned: int) {
	e := &live.evaluation
	if data, blob, ok := cutscene_data(s, e); ok {
		restore(s, e, w, data, blob)
	} else {
		restore_all(s, e, w)
	}
	release_hold(s, w, &live.hold)
	despawned = destroy_evaluation(e, w)
	asset.unload(s.assets, e.cutscene)
	for h in live.references {
		asset.unload(s.assets, h)
	}
	delete(live.references)
	free_overrides(&live.overrides)
	return
}

@(private = "file")
free_overrides :: proc(overrides: ^[dynamic]Binding_Override) {
	for o in overrides {
		if name, by_name := o.binding.(string); by_name {
			delete(name, overrides.allocator)
		}
	}
	delete(overrides^)
	overrides^ = nil
}

// slot_of is the slot of the player that a handle names, and false for a stale handle.
@(private = "file")
slot_of :: proc(s: ^State, h: Player_Handle) -> (int, bool) {
	slot := int(h.slot)
	if slot >= MAX_PLAYERS || h.generation == 0 {
		return 0, false
	}
	p := &s.players[slot]
	if p.generation != h.generation || p.state == nil {
		return 0, false
	}
	return slot, true
}

// command_slot is the slot of a player that takes commands, or Gone for a stale handle and for a player that ended.
@(private = "file")
command_slot :: proc(s: ^State, h: Player_Handle) -> (int, Command_Result) {
	slot, found := slot_of(s, h)
	if !found {
		return 0, .Gone
	}
	if status := status_of(s.players[slot].state); status == .Restored || status == .Failed {
		return 0, .Gone
	}
	return slot, .Done
}

@(private = "file")
change_or_refuse :: proc(s: ^State, w: ^ecs.World, slot: int, to: Player_State) -> Command_Result {
	changed, _ := change_cutscene(s, w, slot, to)
	return .Done if changed else .Refused
}

// refuse logs a change that the diagram does not allow.
@(private = "file")
refuse :: proc(s: ^State, slot: int, to: Player_Status) -> Command_Result {
	log.errorf("cutscene: a player cannot go from %v to %v", status_of(s.players[slot].state), to)
	return .Refused
}

@(private = "file")
resolve_of :: proc(
	s: ^State,
	c: Player_Context,
	data: []byte,
	blob: ^format.Cutscene_Blob,
) -> Resolve {
	return {
		world = c.world,
		scenes = c.scenes,
		scripts = c.scripts,
		assets = s.assets,
		data = data,
		blob = blob,
	}
}

// bindings_hash is a hash of what the bindings resolve from. A binding's name is left out, as its place in the blob's
// strings moves when another string changes; its name hash is kept.
@(private = "file")
bindings_hash :: proc(data: []byte, blob: ^format.Cutscene_Blob) -> u64 {
	h := hash.fnv64a(nil)
	for b in format.cutscene_bindings(data, blob) {
		b := b
		b.name = {}
		h = hash.fnv64a(mem.ptr_to_bytes(&b), h)
	}
	return h
}

// follow_level resets the players when a new level began since they were made. It gives how many spawned roots it
// despawned.
@(private = "file")
follow_level :: proc(s: ^State, w: ^ecs.World) -> (despawned: int) {
	if level := level_of(w); level != s.level {
		despawned = reset(s, w)
		s.level = level
	}
	return
}

// level_of is the platform's level generation, or 0 for a platform without levels.
@(private)
level_of :: proc(w: ^ecs.World) -> u64 {
	if w.platform.level_generation == nil {
		return 0
	}
	return w.platform.level_generation()
}
