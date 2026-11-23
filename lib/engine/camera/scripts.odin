package camera

import "core:c"
import "core:fmt"

import "cinnabar:core/luau"
import "cinnabar:engine/ecs"
import "cinnabar:engine/render"
import "cinnabar:engine/script"

// The Views library that scripts see. Views are numbered from 1 in scripts, and a token is a number: its generation
// times 64, plus its slot, which a number holds exactly. The pusher of an entry gets on_camera_removed(token, reason) on
// the owner entity's behaviours when the entry was removed for it: reason is "despawned" when its camera was destroyed.
// The game package sends the event.

@(private = "file")
VIEWS_KEY :: "cinnabar.camera.views"
@(private = "file")
RENDERER_KEY :: "cinnabar.camera.renderer"

// The slots of a token that its number leaves to the slot.
@(private = "file")
TOKEN_SLOTS :: 64
#assert(MAX_ENTRIES <= TOKEN_SLOTS)

// register_scripts defines the Views library, which reaches v and, for set_layout, the renderer. A game's Register_Proc
// calls it, so init and every reload define them again.
register_scripts :: proc(r: ^script.Runtime, v: ^Views, renderer: ^render.Renderer) {
	script.set_registry_pointer(r, VIEWS_KEY, v)
	script.set_registry_pointer(r, RENDERER_KEY, renderer)

	BLEND :: "{ duration: number, curve: string?, clock: string?, out: number? }"
	script.define(
		r,
		"Views.push",
		push_binding,
		"(view: number, camera: Entity, priority: number, blend: " +
		BLEND +
		"?, owner: Entity?) -> number",
	)
	script.define(r, "Views.pop", pop_binding, "(token: number) -> ()")
	script.define(r, "Views.is_pushed", is_pushed_binding, "(token: number) -> boolean")
	script.define(
		r,
		"Views.claim",
		claim_binding,
		"(camera: Entity, priority: number?, blend: " + BLEND + "?, owner: Entity?) -> number",
	)
	script.define(r, "Views.release", release_binding, "(token: number) -> ()")
	script.define(r, "Views.is_claimed", is_claimed_binding, "(token: number) -> boolean")
	script.define(r, "Views.set_layout", set_layout_binding, "(layout: string) -> ()")
	script.define(r, "Views.count", count_binding, "() -> number")
	script.define(r, "Views.camera", camera_binding, "(view: number) -> Entity?")
}

@(private = "file")
views_of :: proc(L: ^luau.State) -> ^Views {
	return script.registry_pointer(L, VIEWS_KEY, Views)
}

@(private = "file")
renderer_of :: proc(L: ^luau.State) -> ^render.Renderer {
	return script.registry_pointer(L, RENDERER_KEY, render.Renderer)
}

// token_number is a token as scripts see it: a number, which the game also sends with on_camera_removed.
token_number :: proc(token: Camera_Token) -> f64 {
	return f64(u64(token.generation) * TOKEN_SLOTS + u64(token.slot))
}

// check_token reads a token's number. A number that no token has is the zero token, which is stale.
@(private = "file")
check_token :: proc(L: ^luau.State, idx: c.int) -> Camera_Token {
	n := luau.L_checknumber(L, idx)
	if !(n >= 0 && n < f64(max(u32)) * TOKEN_SLOTS) || n != f64(u64(n)) {
		return {}
	}
	whole := u64(n)
	return {slot = u16(whole % TOKEN_SLOTS), generation = u32(whole / TOKEN_SLOTS)}
}

// check_view reads a 1-based view number.
@(private = "file")
check_view :: proc(L: ^luau.State, idx: c.int) -> int {
	view := int(luau.L_checknumber(L, idx))
	if view < 1 || view > MAX_VIEWS {
		script.raise(L, fmt.tprintf("a view is 1 to %d, not %d", MAX_VIEWS, view))
	}
	return view - 1
}

// check_priority reads a priority, which a number holds and a stack keeps as an i32.
@(private = "file")
check_priority :: proc(L: ^luau.State, idx: c.int) -> i32 {
	return i32(clamp(luau.L_checknumber(L, idx), f64(min(i32)), f64(max(i32))))
}

// check_blend reads the blend table, or a cut for a missing one. out is the blend out: its duration, and the curve and
// the clock of the blend in.
@(private = "file")
check_blend :: proc(L: ^luau.State, idx: c.int) -> (blend, out: Blend) {
	if luau.isnoneornil(L, idx) {
		return
	}
	luau.L_checktype(L, idx, .TABLE)
	luau.rawgetfield(L, idx, "duration")
	blend.duration = f32(luau.L_checknumber(L, -1))
	luau.pop(L, 1)

	if luau.rawgetfield(L, idx, "curve") != .NIL {
		switch name := string(luau.L_checkstring(L, -1)); name {
		case "linear":
			blend.curve = .Linear
		case "smooth":
			blend.curve = .Smooth
		case "ease_in":
			blend.curve = .Ease_In
		case "ease_out":
			blend.curve = .Ease_Out
		case:
			script.raise(
				L,
				fmt.tprintf(
					"a curve is \"linear\", \"smooth\", \"ease_in\" or \"ease_out\", not %q",
					name,
				),
			)
		}
	}
	luau.pop(L, 1)

	if luau.rawgetfield(L, idx, "clock") != .NIL {
		switch name := string(luau.L_checkstring(L, -1)); name {
		case "game":
			blend.clock = .Game
		case "real":
			blend.clock = .Real
		case:
			script.raise(L, fmt.tprintf("a clock is \"game\" or \"real\", not %q", name))
		}
	}
	luau.pop(L, 1)

	out = blend
	out.duration = 0
	if luau.rawgetfield(L, idx, "out") != .NIL {
		out.duration = f32(luau.L_checknumber(L, -1))
	}
	luau.pop(L, 1)
	return
}

@(private = "file")
check_owner :: proc(L: ^luau.State, idx: c.int) -> ecs.Entity {
	return 0 if luau.isnoneornil(L, idx) else script.check_entity(L, idx)
}

@(private = "file")
push_binding :: proc(L: ^luau.State) -> c.int {
	v, w := views_of(L), script.runtime_of(L).world
	view := check_view(L, 1)
	camera := script.check_entity(L, 2)
	priority := check_priority(L, 3)
	blend, out := check_blend(L, 4)
	token, ok := push(v, w, view, camera, priority, blend, out, check_owner(L, 5))
	if !ok {
		script.raise(
			L,
			fmt.tprintf(
				"Views.push: %v is not a live Camera, or the camera stacks are full",
				camera,
			),
		)
	}
	luau.pushnumber(L, token_number(token))
	return 1
}

@(private = "file")
pop_binding :: proc(L: ^luau.State) -> c.int {
	pop(views_of(L), check_token(L, 1))
	return 0
}

@(private = "file")
is_pushed_binding :: proc(L: ^luau.State) -> c.int {
	luau.pushboolean(L, b32(is_pushed(views_of(L), check_token(L, 1))))
	return 1
}

@(private = "file")
claim_binding :: proc(L: ^luau.State) -> c.int {
	v, w := views_of(L), script.runtime_of(L).world
	camera := script.check_entity(L, 1)
	priority := check_priority(L, 2) if !luau.isnoneornil(L, 2) else 0
	blend, out := check_blend(L, 3)
	token, ok := claim(v, w, camera, priority, blend, out, check_owner(L, 4))
	if !ok {
		script.raise(
			L,
			fmt.tprintf(
				"Views.claim: %v is not a live Camera, or the camera stacks are full",
				camera,
			),
		)
	}
	luau.pushnumber(L, token_number(Camera_Token(token)))
	return 1
}

@(private = "file")
release_binding :: proc(L: ^luau.State) -> c.int {
	release(views_of(L), Claim_Token(check_token(L, 1)))
	return 0
}

@(private = "file")
is_claimed_binding :: proc(L: ^luau.State) -> c.int {
	luau.pushboolean(L, b32(is_claimed(views_of(L), Claim_Token(check_token(L, 1)))))
	return 1
}

@(private = "file")
set_layout_binding :: proc(L: ^luau.State) -> c.int {
	layout: Preset
	switch name := string(luau.L_checkstring(L, 1)); name {
	case "single":
		layout = .Single
	case "side_by_side":
		layout = .Side_By_Side
	case "over_under":
		layout = .Over_Under
	case "grid_4":
		layout = .Grid_4
	case:
		script.raise(
			L,
			fmt.tprintf(
				"a layout is \"single\", \"side_by_side\", \"over_under\" or \"grid_4\", not %q",
				name,
			),
		)
	}
	set_layout(views_of(L), renderer_of(L), layout)
	return 0
}

@(private = "file")
count_binding :: proc(L: ^luau.State) -> c.int {
	luau.pushnumber(L, f64(view_count(views_of(L))))
	return 1
}

@(private = "file")
camera_binding :: proc(L: ^luau.State) -> c.int {
	script.push_entity(L, chosen_camera(views_of(L), check_view(L, 1)))
	return 1
}
