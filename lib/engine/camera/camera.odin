// Package camera is the game's views and the camera stack of each: systems push cameras onto a view's stack with a
// priority, the highest one shows, and a change of choice cuts or blends. A full-screen claim takes every view, for a
// cutscene, and its release gives the layout back. The package keeps the state and makes each frame's views; the game
// package draws them.
package camera

import "core:log"

import "cinnabar:engine/ecs"
import "cinnabar:engine/render"

// The game's views: the renderer's own view and its extra views.
MAX_VIEWS :: 1 + render.MAX_EXTRA_VIEWS
// The pushes and claims that are held at one time, in all the stacks together.
MAX_ENTRIES :: 64

// Stack_Index is a stack: a view's, from 0 to MAX_VIEWS - 1, or CLAIMS.
Stack_Index :: distinct u8

// CLAIMS is the stack of the full-screen claims.
CLAIMS :: Stack_Index(MAX_VIEWS)

@(private)
STACK_COUNT :: MAX_VIEWS + 1

// Camera_Token is a pusher's hold on its entry. A pop through a stale token does nothing: the entry's generation counts
// up each time that its slot is used, so a token never matches a later entry's.
Camera_Token :: struct {
	slot:       u16,
	generation: u32,
}

// Claim_Token is a claim's hold on its entry. It is a different type, so that a push's token does not release a claim.
Claim_Token :: distinct Camera_Token

// Entry is a slot of the pool that holds the pushes and claims.
Entry :: struct {
	generation: u32,
	state:      Maybe(Pushed),
}

// Pushed is a push or a claim while it is held.
Pushed :: struct {
	stack:     Stack_Index,
	camera:    ecs.Entity,
	priority:  i32,
	// Counts up with each push, so that on a tie the last push wins.
	order:     u64,
	// The blend when this entry becomes the choice, and when it was the choice and goes.
	blend_in:  Blend,
	blend_out: Blend,
	// The entity that learns when the entry was removed for it (see Ended). 0 for none.
	owner:     ecs.Entity,
}

// Fallback is a stack with no entries: it shows the world's first camera.
Fallback :: struct {}

// Chosen is the entry that a stack shows. It keeps the entry's blend out, which the entry's removal then cannot take;
// only a release that gives a blend replaces it.
Chosen :: struct {
	token:     Camera_Token,
	camera:    ecs.Entity,
	blend_out: Blend,
}

Choice :: union #no_nil {
	Fallback,
	Chosen,
}

// Settled is a stack that shows its choice's camera as it is.
Settled :: struct {}

// Live_Camera is the camera that a blend starts from while it still exists: it is read in each frame, so that a moving
// camera blends from where it is. last is the view of the last read, which stays if the camera goes.
Live_Camera :: struct {
	entity: ecs.Entity,
	last:   render.View,
}

// Blend_From is where a blend starts: a camera that is read in each frame, or a view that is frozen.
Blend_From :: union #no_nil {
	Live_Camera,
	render.View,
}

// Blending is a stack that moves from one view to its choice's camera.
Blending :: struct {
	from:    Blend_From,
	elapsed: f32,
	blend:   Blend,
}

Shot :: union #no_nil {
	Settled,
	Blending,
}

// Stack is one stack's choice, how the stack moves to it, and the view that it showed in the last advance.
Stack :: struct {
	choice: Choice,
	shot:   Shot,
	shown:  render.View,
}

// Game_View is a view of the game: its stack, and the renderer's state for it. The own view, 0, uses the renderer's
// own state, so only the others have one.
Game_View :: struct {
	stack: Stack,
	state: Maybe(render.View_State),
}

// Presentation is how the views were laid out in the last advance, to find the frame where their rects change: a view
// whose rect changes is a cut. A claim over one full view, as in the Single layout, changes no rect, so a blend into or
// out of it is not a cut.
Presentation :: struct {
	claimed: bool,
	rects:   [MAX_VIEWS]Rect,
	count:   int,
}

// Ended_Reason is why an entry was removed for its pusher.
Ended_Reason :: enum u8 {
	// Its camera entity does not exist, or has no Camera.
	Despawned,
}

// Ended is an entry that advance removed, which its owner learns of: the game package sends the owner on_camera_removed
// with the token and the reason.
Ended :: struct {
	token:  Camera_Token,
	stack:  Stack_Index,
	reason: Ended_Reason,
	owner:  ecs.Entity,
}

// Views is the game's views, their stacks and the pool of entries. Advance is the only writer of what the stacks
// choose and show; push, pop, claim and release only change the pool. It holds values only, so it lives in Game_State
// across a code reload.
Views :: struct {
	views:        [MAX_VIEWS]Game_View,
	claims:       Stack,
	layout:       Layout,
	entries:      [MAX_ENTRIES]Entry,
	next_order:   u64,
	// The camera that a stack with no entries shows, and that fallback blends start from.
	fallback:     ecs.Entity,
	// nil until the first advance, which is never a cut.
	presented:    Maybe(Presentation),
	ended:        [MAX_ENTRIES]Ended,
	ended_count:  int,
	// Whether the pool's being full is warned of already, so that a system that pushes each frame logs once.
	full_warned:  bool,
	// The renderer views whose cut no drawn frame has carried yet, by their index in Frame_Views. advance sets them, and
	// drawn clears them once the frame is drawn, so a frame that is not drawn, as with a minimized window, passes its
	// cuts on to the next.
	pending_cuts: [MAX_VIEWS]bool,
	// The count of the world's replacements that follow_world last saw.
	world:        u64,
}

// Steps are the time that a frame advances the blends by, on each clock. The game's is 0 while paused.
Steps :: struct {
	game, real: f32,
}

// Shown_View is a view of a frame: its renderer view's index, its rect, what it shows, and whether the renderer's
// temporal histories must start again for it, as after a camera cut or a change of the rect.
Shown_View :: struct {
	index: int,
	rect:  Rect,
	view:  render.View,
	cut:   bool,
}

Frame_Views :: struct {
	views:   [MAX_VIEWS]Shown_View,
	count:   int,
	// The one view is a claim's, not a player's: the players' views and what belongs to them, such as their HUDs, do
	// not show.
	claimed: bool,
}

// push puts a camera on a view's stack. blend is how the view moves to it when it becomes the choice, and blend_out how
// the view moves from it when it goes. The owner learns when the entry is removed for it (see ended). It fails for a
// view that does not exist, a camera that is not a live Camera, and a full pool.
push :: proc(
	v: ^Views,
	w: ^ecs.World,
	view: int,
	camera: ecs.Entity,
	priority: i32,
	blend := CUT,
	blend_out := CUT,
	owner: ecs.Entity = 0,
) -> (
	token: Camera_Token,
	ok: bool,
) {
	if view < 0 || view >= MAX_VIEWS {
		return
	}
	return add_entry(v, w, Stack_Index(view), camera, priority, blend, blend_out, owner)
}

// pop removes a push. Through a stale token, or a claim's, it does nothing.
pop :: proc(v: ^Views, token: Camera_Token) {
	if p := pushed_of(v, token); p != nil && p.stack != CLAIMS {
		v.entries[token.slot].state = nil
	}
}

// is_pushed reports whether a push is held.
is_pushed :: proc(v: ^Views, token: Camera_Token) -> bool {
	p := pushed_of(v, token)
	return p != nil && p.stack != CLAIMS
}

// claim takes every view for a camera, which the layout then shows full screen. The highest priority claim shows, as
// in a stack. It fails for a camera that is not a live Camera, and a full pool.
claim :: proc(
	v: ^Views,
	w: ^ecs.World,
	camera: ecs.Entity,
	priority: i32 = 0,
	blend := CUT,
	blend_out := CUT,
	owner: ecs.Entity = 0,
) -> (
	token: Claim_Token,
	ok: bool,
) {
	pushed: Camera_Token
	pushed, ok = add_entry(v, w, CLAIMS, camera, priority, blend, blend_out, owner)
	return Claim_Token(pushed), ok
}

// release ends a claim, and the layout shows again. Through a stale token, or a push's, it does nothing. A blend_out
// replaces the one that the claim was made with, for a claim that shows: a cutscene that is skipped or sought cuts away
// from a shot that would have blended out at its end. It is the one write to a stack's choice outside advance, and it
// changes only how the choice leaves, which advance reads only once the entry is gone.
release :: proc(v: ^Views, token: Claim_Token, blend_out: Maybe(Blend) = nil) {
	camera_token := Camera_Token(token)
	p := pushed_of(v, camera_token)
	if p == nil || p.stack != CLAIMS {
		return
	}
	if blend, given := blend_out.?; given {
		p.blend_out = blend
		if chosen, showing := &v.claims.choice.(Chosen); showing && chosen.token == camera_token {
			chosen.blend_out = blend
		}
	}
	v.entries[camera_token.slot].state = nil
}

// is_claimed reports whether a claim is held.
is_claimed :: proc(v: ^Views, token: Claim_Token) -> bool {
	p := pushed_of(v, Camera_Token(token))
	return p != nil && p.stack == CLAIMS
}

// claimed reports whether any claim is held, so that the views show one full-screen view.
claimed :: proc(v: ^Views) -> bool {
	for &entry in v.entries {
		if p, held := entry.state.?; held && p.stack == CLAIMS {
			return true
		}
	}
	return false
}

// held_count is how many pushes and claims are held, across every stack.
held_count :: proc(v: ^Views) -> int {
	count := 0
	for &entry in v.entries {
		if _, held := entry.state.?; held {
			count += 1
		}
	}
	return count
}

// set_layout lays the views out. A view that the layout drops gives its renderer state back. A custom layout's count
// is 1 to MAX_VIEWS, and its rects past the count are cleared.
set_layout :: proc(v: ^Views, r: ^render.Renderer, layout: Layout) {
	v.layout = layout
	if custom, is_custom := layout.(Custom); is_custom {
		custom.count = u8(clamp(int(custom.count), 1, MAX_VIEWS))
		for i in int(custom.count) ..< MAX_VIEWS {
			custom.rects[i] = {}
		}
		v.layout = custom
	}
	// Without a renderer, there is nothing to give back to: the state stays for the next call that has one.
	if r == nil {
		return
	}
	for i in view_count(v) ..< MAX_VIEWS {
		if state, made := &v.views[i].state.?; made {
			render.view_state_destroy(state, r)
			v.views[i].state = nil
		}
	}
}

// view_count is how many views the layout has: 1 to MAX_VIEWS.
view_count :: proc(v: ^Views) -> int {
	_, count := layout_rects(v.layout)
	return count
}

// view_state is the renderer's state for a view that is not the own view, made on first use. It is nil for the own
// view, whose state the renderer has, and for a view that does not exist.
view_state :: proc(v: ^Views, r: ^render.Renderer, index: int) -> ^render.View_State {
	if index < 1 || index >= MAX_VIEWS {
		return nil
	}
	view := &v.views[index]
	if _, made := view.state.?; !made {
		view.state = render.View_State{}
		render.view_state_init(&view.state.?, r)
	}
	return &view.state.?
}

// destroy gives every view's renderer state back, before the renderer goes.
destroy :: proc(v: ^Views, r: ^render.Renderer) {
	for &view in v.views {
		if state, made := &view.state.?; made {
			render.view_state_destroy(state, r)
			view.state = nil
		}
	}
}

// drawn tells the views that the frame that the last advance gave was drawn, with its cuts.
drawn :: proc(v: ^Views) {
	v.pending_cuts = {}
}

// reset starts the views again for a new world, as the editor's scene replaces the game's: one full-screen view, no
// pushes or claims, and nothing chosen or blending. The old entries' tokens stay stale, and their owners learn nothing,
// as the old world's behaviours end without callbacks. The first frame after it cuts every view, so no history of the
// old world shows.
reset :: proc(v: ^Views, r: ^render.Renderer) {
	set_layout(v, r, Preset.Single)
	for &entry in v.entries {
		entry.state = nil
	}
	for &view in v.views {
		view.stack = {}
	}
	v.claims = {}
	v.fallback = 0
	v.presented = nil
	v.ended_count = 0
	v.full_warned = false
	for &pending in v.pending_cuts {
		pending = true
	}
}

// follow_world resets the views when the world that they show was replaced: world counts the replacements, as
// editor.world_loads does, and a count that changed since the last call resets them.
follow_world :: proc(v: ^Views, r: ^render.Renderer, world: u64) {
	if v.world == world {
		return
	}
	v.world = world
	reset(v, r)
}

// ended is what advance removed for its owners in the frame, which the next advance clears.
ended :: proc(v: ^Views) -> []Ended {
	return v.ended[:v.ended_count]
}

// chosen_camera is the camera that a view shows when it has settled: its stack's choice, or the fallback. The first view
// of a claim shows the claim's.
chosen_camera :: proc(v: ^Views, index: int) -> ecs.Entity {
	stack := shown_stack(v, index)
	if stack == nil {
		return 0
	}
	return stack_camera(v, stack)
}

// view_of is what a view shows now, with this frame's poses. It reads and changes nothing, so a frame can use it before
// advance, for what advance has not made yet; a stack that advance has not chosen for yet shows its last choice.
view_of :: proc(v: ^Views, w: ^ecs.World, index: int) -> render.View {
	stack := shown_stack(v, index)
	if stack == nil {
		return default_view()
	}
	return stack_view(v, w, stack)
}

// append_positions adds the position of each camera that a view or a claim uses, whether it shows now or not, once for
// an entity, so that streaming loads around the cameras of every view.
append_positions :: proc(v: ^Views, w: ^ecs.World, out: ^[dynamic]ecs.World_Position) {
	seen: [STACK_COUNT]ecs.Entity
	count: int
	for i in 0 ..< STACK_COUNT {
		index := Stack_Index(i)
		if index == CLAIMS && !claimed(v) {
			continue
		}
		camera := stack_camera(v, stack_at(v, index))
		if camera == 0 {
			continue
		}
		duplicate := false
		for known in seen[:count] {
			duplicate ||= known == camera
		}
		if duplicate {
			continue
		}
		seen[count] = camera
		count += 1
		if pose, ok := ecs.presented(w, camera); ok {
			append(out, pose.position)
		}
	}
}

// advance runs a frame of the views: it removes the entries whose cameras are gone, chooses in each stack, starts and
// steps the blends, and gives the views to draw.
advance :: proc(v: ^Views, w: ^ecs.World, steps: Steps) -> Frame_Views {
	v.ended_count = 0
	first := v.presented == nil
	remove_despawned(v, w)
	find_fallback(v, w)
	if first {
		// A stack that has shown nothing yet has no view to blend from.
		for i in 0 ..< STACK_COUNT {
			stack := stack_at(v, Stack_Index(i))
			stack.shown = stack_view(v, w, stack)
		}
	}

	cut: [STACK_COUNT]bool
	for i in 0 ..< STACK_COUNT {
		index := Stack_Index(i)
		stack := stack_at(v, index)
		cut[i] = choose(v, w, stack, index) && !first
		step_blend(stack, steps)
		refresh_live(w, stack)
		stack.shown = stack_view(v, w, stack)
	}

	now := Presentation {
		claimed = showing_claim(v),
	}
	if now.claimed {
		now.rects[0], now.count = FULL, 1
	} else {
		now.rects, now.count = layout_rects(v.layout)
	}
	before, was := v.presented.?
	v.presented = now
	relaid := was && (before.count != now.count || before.rects != now.rects)
	// The first view that changes between the claims' stack and its own carries a cut of the claims' stack: a claim
	// that cuts in, and a release that cuts back.
	switched := was && before.claimed != now.claimed

	frame := Frame_Views {
		claimed = now.claimed,
		count   = now.count,
	}
	if now.claimed {
		frame.views[0] = {0, FULL, v.claims.shown, cut[CLAIMS] || relaid}
	} else {
		for i in 0 ..< now.count {
			cut_back := switched && i == 0 && cut[CLAIMS]
			frame.views[i] = {
				i,
				now.rects[i],
				v.views[i].stack.shown,
				cut[i] || relaid || cut_back,
			}
		}
	}
	for &view, i in frame.views[:frame.count] {
		view.cut ||= v.pending_cuts[i]
		v.pending_cuts[i] = view.cut
	}
	return frame
}

// add_entry takes a slot of the pool for a push or a claim.
@(private)
add_entry :: proc(
	v: ^Views,
	w: ^ecs.World,
	stack: Stack_Index,
	camera: ecs.Entity,
	priority: i32,
	blend_in, blend_out: Blend,
	owner: ecs.Entity,
) -> (
	token: Camera_Token,
	ok: bool,
) {
	if !is_camera(w, camera) {
		return
	}
	slot := -1
	for entry, i in v.entries {
		if entry.state == nil {
			slot = i
			break
		}
	}
	if slot < 0 {
		if !v.full_warned {
			v.full_warned = true
			log.warnf(
				"camera: all %d entries of the camera stacks are held; the push is refused",
				MAX_ENTRIES,
			)
		}
		return
	}
	v.full_warned = false
	entry := &v.entries[slot]
	// A generation of 0 is no token's, so a zero token is always stale.
	entry.generation += 1
	if entry.generation == 0 {
		entry.generation = 1
	}
	v.next_order += 1
	entry.state = Pushed {
		stack     = stack,
		camera    = camera,
		priority  = priority,
		order     = v.next_order,
		blend_in  = blend_in,
		blend_out = blend_out,
		owner     = owner,
	}
	return {u16(slot), entry.generation}, true
}

// is_camera reports whether an entity is alive and has a Camera.
@(private)
is_camera :: proc(w: ^ecs.World, camera: ecs.Entity) -> bool {
	return ecs.is_alive(w, camera) && ecs.has(w, camera, render.Camera)
}

// pushed_of is the entry that a token holds, or nil for a stale token.
@(private)
pushed_of :: proc(v: ^Views, token: Camera_Token) -> ^Pushed {
	if int(token.slot) >= MAX_ENTRIES || token.generation == 0 {
		return nil
	}
	entry := &v.entries[token.slot]
	if entry.generation != token.generation {
		return nil
	}
	if p, held := &entry.state.?; held {
		return p
	}
	return nil
}

@(private)
stack_at :: proc(v: ^Views, index: Stack_Index) -> ^Stack {
	return &v.claims if index == CLAIMS else &v.views[index].stack
}

// shown_stack is the stack that a view shows: the claims' for the first view while a claim is held.
@(private)
shown_stack :: proc(v: ^Views, index: int) -> ^Stack {
	if index < 0 || index >= MAX_VIEWS {
		return nil
	}
	if index == 0 && showing_claim(v) {
		return &v.claims
	}
	return &v.views[index].stack
}

// stack_camera is the camera that a stack's choice shows. The claims' stack with no claim shows the first view's, so
// that a claim blends in from what the first view shows, and its release blends back to it.
@(private)
stack_camera :: proc(v: ^Views, stack: ^Stack) -> ecs.Entity {
	if chosen, ok := stack.choice.(Chosen); ok {
		return chosen.camera
	}
	if stack == &v.claims {
		return stack_camera(v, &v.views[0].stack)
	}
	return v.fallback
}

// showing_claim reports whether the views show the claims' stack full screen: while a claim is held, and while the last
// one's blend out moves back to the first view's camera. The layout comes back when that blend ends.
@(private)
showing_claim :: proc(v: ^Views) -> bool {
	if claimed(v) {
		return true
	}
	_, blending := v.claims.shot.(Blending)
	return blending
}

@(private)
default_view :: proc() -> render.View {
	return {
		rotation = 1,
		projection = render.Perspective{render.DEFAULT_VERTICAL_FOV, render.DEFAULT_NEAR},
	}
}

// remove_despawned ends the entries whose cameras are gone, and records them for their owners.
@(private)
remove_despawned :: proc(v: ^Views, w: ^ecs.World) {
	for &entry, slot in v.entries {
		p, held := entry.state.?
		if !held || is_camera(w, p.camera) {
			continue
		}
		v.ended[v.ended_count] = {
			token  = {u16(slot), entry.generation},
			stack  = p.stack,
			reason = .Despawned,
			owner  = p.owner,
		}
		v.ended_count += 1
		entry.state = nil
	}
}

// find_fallback finds the world's first camera when the fallback is gone, and keeps it while it lives.
@(private)
find_fallback :: proc(v: ^Views, w: ^ecs.World) {
	if ecs.is_alive(w, v.fallback) {
		return
	}
	cameras := make([dynamic]ecs.Entity, w.platform.frame_allocator)
	ecs.collect(w, {render.CAMERA_ID}, &cameras)
	v.fallback = cameras[0] if len(cameras) > 0 else 0
}

// top_entry is the entry that a stack chooses: the highest priority, and on a tie the last push.
@(private)
top_entry :: proc(v: ^Views, stack: Stack_Index) -> (slot: int, found: bool) {
	for &entry, i in v.entries {
		p, held := entry.state.?
		if !held || p.stack != stack {
			continue
		}
		if !found {
			slot, found = i, true
			continue
		}
		best := entry_of(v, slot)
		if p.priority > best.priority || (p.priority == best.priority && p.order > best.order) {
			slot = i
		}
	}
	return
}

@(private)
entry_of :: proc(v: ^Views, slot: int) -> ^Pushed {
	return &v.entries[slot].state.?
}

// choose makes a stack choose its top entry, and starts the move to it when the choice changes. It reports a cut.
@(private)
choose :: proc(v: ^Views, w: ^ecs.World, stack: ^Stack, index: Stack_Index) -> (cut: bool) {
	next: Choice = Fallback{}
	blend_in: Blend
	if slot, found := top_entry(v, index); found {
		p := entry_of(v, slot)
		next = Chosen {
			token     = {u16(slot), v.entries[slot].generation},
			camera    = p.camera,
			blend_out = p.blend_out,
		}
		blend_in = p.blend_in
	}
	previous := stack.choice
	if previous == next {
		return false
	}

	blend := blend_in
	from_camera := stack_camera(v, stack)
	if old, was_chosen := previous.(Chosen); was_chosen {
		from_camera = old.camera
		// An entry that was outranked is still held, and the new top's blend in decides. One that is gone leaves with its
		// own blend out.
		if pushed_of(v, old.token) == nil {
			blend = old.blend_out
		}
	}
	stack.choice = next
	if blend.duration <= 0 {
		stack.shot = Settled{}
		return true
	}

	from: Blend_From = stack.shown
	// A blend that starts during another blend starts from the pose that is shown, and so does one from a camera that
	// is gone. Only a settled stack follows its old camera.
	if _, moving := stack.shot.(Blending); !moving {
		if view, ok := render.camera_view(w, from_camera); ok {
			from = Live_Camera{from_camera, view}
		}
	}
	stack.shot = Blending{from, 0, blend}
	return false
}

// step_blend moves a blend on by the time of its clock, and ends it when its time is up.
@(private)
step_blend :: proc(stack: ^Stack, steps: Steps) {
	blending, moving := &stack.shot.(Blending)
	if !moving {
		return
	}
	blending.elapsed += steps.game if blending.blend.clock == .Game else steps.real
	if blending.elapsed >= blending.blend.duration {
		stack.shot = Settled{}
	}
}

// refresh_live reads the camera that a blend starts from. If it cannot be read, the blend starts from the view of its
// last read from then on.
@(private)
refresh_live :: proc(w: ^ecs.World, stack: ^Stack) {
	blending, moving := &stack.shot.(Blending)
	if !moving {
		return
	}
	live, following := blending.from.(Live_Camera)
	if !following {
		return
	}
	if view, ok := render.camera_view(w, live.entity); ok {
		blending.from = Live_Camera{live.entity, view}
	} else {
		blending.from = live.last
	}
}

// stack_view is what a stack shows: its choice's camera, or the blend from where it came to it.
@(private)
stack_view :: proc(v: ^Views, w: ^ecs.World, stack: ^Stack) -> render.View {
	target := default_view()
	camera := stack_camera(v, stack)
	_, chosen := stack.choice.(Chosen)
	if !chosen && stack == &v.claims {
		// The first view's stack chose and stepped before the claims' in this advance, so this is what it shows now,
		// with its own blend.
		target = v.views[0].stack.shown
	} else if view, ok := render.camera_view(w, camera); ok {
		target = view
	} else if chosen {
		// A camera without a pose shows what the stack showed before, not the default.
		target = stack.shown
	}
	blending, moving := stack.shot.(Blending)
	if !moving {
		return target
	}
	from: render.View
	switch f in blending.from {
	case Live_Camera:
		from = f.last
		if view, ok := render.camera_view(w, f.entity); ok {
			from = view
		}
	case render.View:
		from = f
	}
	t := ease(blending.blend.curve, blending.elapsed / blending.blend.duration)
	return blend_views(from, target, t)
}
