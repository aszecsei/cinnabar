package game

import "core:c"

import "cinnabar:core/luau"
import "cinnabar:engine/ai"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/nav"
import "cinnabar:engine/physics"
import "cinnabar:engine/scene"
import "cinnabar:engine/script"

// Scene_Request is a scene to load beside the others with the number that load_scene gave it, or one to unload.
Scene_Request :: union {
	Scene_Load,
	Scene_Unload,
}

Scene_Load :: struct {
	guid:   format.Guid,
	number: u32,
}

Scene_Unload :: struct {
	number: u32,
}

// load_scene asks for a cooked scene to load beside the scenes that are loaded, and gives the number that it will have.
// It loads at the start of the next frame, or of this one from begin_frame, outside the script phase (see
// docs/world/scenes.md#streaming).
load_scene :: proc(g: ^Game, guid: format.Guid) -> u32 {
	number := scene.reserve_number(&g.scenes)
	append(&g.scene_requests, Scene_Load{guid, number})
	return number
}

// unload_scene asks for the scene with the number to unload, with what it owns, when load_scene's requests apply. The
// systems that keep data by entity drop its entities in that frame.
unload_scene :: proc(g: ^Game, number: u32) {
	append(&g.scene_requests, Scene_Unload{number})
}

// apply_scene_requests loads and unloads the scenes that were asked for, in order, and has the systems that keep data
// by entity drop the entities that went. The audio, the renderer and the UI drop them in their own sweeps of this
// frame.
@(private)
apply_scene_requests :: proc(g: ^Game) {
	if len(g.scene_requests) == 0 {
		return
	}
	unloaded := false
	for request in g.scene_requests {
		switch r in request {
		case Scene_Load:
			scene.add_scene_asset(&g.world, &g.scripts, &g.scenes, r.guid, r.number)
		case Scene_Unload:
			scene.unload_scene(&g.world, &g.scenes, r.number)
			unloaded = true
		}
	}
	clear(&g.scene_requests)
	if unloaded {
		forget_despawned(g)
	}
	find_camera(g)
}

// forget_despawned has the systems that keep data by entity outside the world drop the entities that are gone at
// once, rather than at their next tick or step.
forget_despawned :: proc(g: ^Game) {
	physics.forget_despawned(&g.physics, &g.world)
	nav.forget_despawned(&g.nav, &g.world)
	ai.forget_despawned(&g.ai, &g.world)
	script.forget_despawned(&g.scripts)
}

// define_scene_bindings defines Scene.load, Scene.unload and Scene.of.
@(private)
define_scene_bindings :: proc(r: ^script.Runtime) {
	script.define(r, "Scene.load", proc(L: ^luau.State) -> c.int {
			g := game_of(L)
			guid := script.to_asset(&g.scripts, L, 1)
			if guid == {} {
				script.raise(L, "Scene.load takes a scene asset")
			}
			luau.pushnumber(L, f64(load_scene(g, guid)))
			return 1
		}, "(scene: Asset) -> number")
	script.define(r, "Scene.unload", proc(L: ^luau.State) -> c.int {
			number := luau.L_checknumber(L, 1)
			if number < 0 || number > f64(max(u32)) || number != f64(u32(number)) {
				script.raise(L, "Scene.unload takes a scene's number")
			}
			unload_scene(game_of(L), u32(number))
			return 0
		}, "(scene: number) -> ()")
	script.define(r, "Scene.of", proc(L: ^luau.State) -> c.int {
			g := game_of(L)
			number, ok := scene.scene_of(&g.world, script.check_entity(L, 1))
			if !ok {
				luau.pushnil(L)
			} else {
				luau.pushnumber(L, f64(number))
			}
			return 1
		}, "(entity: Entity) -> number?")
}
