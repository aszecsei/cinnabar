package sprite

import "core:c"
import "core:fmt"

import "cinnabar:core/luau"
import "cinnabar:engine/ecs"
import "cinnabar:engine/render"
import "cinnabar:engine/script"

// The Sprites library that scripts see (see docs/rendering/2d.md#scripts): a Sprite_Renderer's animations and frames by
// their names in its sheet.

@(private = "file")
REGISTRY_KEY :: "cinnabar.sprite"

// register_scripts defines the Sprites library, which reaches s, and exposes Sprite_Renderer. A game's Register_Proc
// calls it, so init and every reload define them again.
register_scripts :: proc(r: ^script.Runtime, s: ^State) {
	luau.pushlightuserdata(r.L, s)
	luau.setfield(r.L, luau.REGISTRYINDEX, REGISTRY_KEY)
	script.expose(r, render.Sprite_Renderer, render.DEFAULT_SPRITE_RENDERER)

	script.define(r, "Sprites.play", proc(L: ^luau.State) -> c.int {
		sprite := sprite_arg(L, write = true)
		name := string(luau.L_checkstring(L, 2))
		restart := luau.gettop(L) >= 3 && bool(luau.toboolean(L, 3))
		if play(state_of(L), sprite, name, restart) == .No_Name {
			script.raise(L, fmt.tprintf("the entity's sprite sheet has no animation %s", name))
		}
		return 0
	}, "(entity: Entity, name: string, restart: boolean?) -> ()")
	script.define(r, "Sprites.stop", proc(L: ^luau.State) -> c.int {
		stop(sprite_arg(L, write = true))
		return 0
	}, "(entity: Entity) -> ()")
	script.define(r, "Sprites.set_frame", proc(L: ^luau.State) -> c.int {
		sprite := sprite_arg(L, write = true)
		name := string(luau.L_checkstring(L, 2))
		if set_frame(state_of(L), sprite, name) == .No_Name {
			script.raise(L, fmt.tprintf("the entity's sprite sheet has no frame %s", name))
		}
		return 0
	}, "(entity: Entity, name: string) -> ()")
	script.define(r, "Sprites.animation", proc(L: ^luau.State) -> c.int {
		name := animation_name(state_of(L), sprite_arg(L)^)
		if name == "" {
			luau.pushnil(L)
		} else {
			luau.pushodinstring(L, name)
		}
		return 1
	}, "(entity: Entity) -> string?")
	script.define(r, "Sprites.finished", proc(L: ^luau.State) -> c.int {
		luau.pushboolean(L, b32(finished(state_of(L), sprite_arg(L)^)))
		return 1
	}, "(entity: Entity) -> boolean")
}

@(private = "file")
state_of :: proc(L: ^luau.State) -> ^State {
	luau.getfield(L, luau.REGISTRYINDEX, REGISTRY_KEY)
	s := (^State)(luau.tolightuserdata(L, -1))
	luau.pop(L, 1)
	return s
}

// sprite_arg reads the entity in the first argument, and raises an error unless it has a Sprite_Renderer. With write,
// the Sprite_Renderer counts as changed.
@(private = "file")
sprite_arg :: proc(L: ^luau.State, write := false) -> ^render.Sprite_Renderer {
	w := script.runtime_of(L).world
	e := script.check_entity(L, 1)
	sprite := ecs.get(w, e, render.Sprite_Renderer) if w != nil && ecs.is_alive(w, e) else nil
	if sprite == nil {
		script.raise(L, fmt.tprintf("entity %v has no Sprite_Renderer", e))
	}
	if write {
		sprite = ecs.get_write(w, e, render.Sprite_Renderer)
	}
	return sprite
}
