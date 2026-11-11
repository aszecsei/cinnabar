// Package game is the standard game: the world, the renderer, the assets, the scripts, physics, audio, animation,
// sprites, the UI and the editor's link, started, stepped, reloaded and drawn in the engine's order. A project without
// Odin runs it as it is, from standard.dll in development and runtime.exe in a release. A project with Odin gives it
// Hooks, for its own components, systems, bindings, state and passes, and exports api(its hooks) as its Game_API (see
// docs/world/game-package.md).
package game

import "core:c"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/luau"
import "cinnabar:engine/anim"
import "cinnabar:engine/asset"
import "cinnabar:engine/audio"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor"
import "cinnabar:engine/physics"
import "cinnabar:engine/project"
import "cinnabar:engine/render"
import "cinnabar:engine/scene"
import "cinnabar:engine/script"
import "cinnabar:engine/sprite"
import "cinnabar:engine/ui"
import "cinnabar:engine/volume"

// The game looks for a change to the project's settings' files this often, in seconds.
PROJECT_CHECK_INTERVAL :: 0.5

// Game is the root of the standard game's persistent state. The host owns its memory. The project's own state, its
// Hooks.State, follows it at USER_OFFSET (see user).
Game :: struct {
	platform:           ^core.Platform_API,
	frame_count:        u64,
	// What the scripts' Render bindings reach: the renderer and the settings file.
	script_quality:     project.Script_Quality,
	// The project's settings, read again when their files change.
	project:            project.Watch,
	next_project_check: f64,
	// The world's time, which stops in the editor's Edit and Paused and while the game is paused.
	elapsed:            time.Duration,
	// The time that the world stepped this frame, in seconds, which the particles step by.
	frame_step:         f32,
	// A paused game's world takes no time: no ticks and no particles, while the scripts and the UI run on, as a pause
	// menu needs. Scripts set it with Game.set_paused.
	paused:             bool,
	// The audio device's test tone, which CINNABAR_TEST_TONE plays in place of the game's sounds.
	tone:               audio.Tone,
	world:              ecs.World,
	// The physics world, which the fixed ticks step (see docs/physics/design.md#the-physics-tick).
	physics:            physics.State,
	// The sounds that the world and the scripts play (see docs/audio/design.md#the-game-side).
	audio:              audio.State,
	// The Animators' queries, which the fixed ticks advance (see docs/content/kinds/skins-and-animations.md#playback).
	animation:          anim.State,
	// The Sprite_Renderers' animations (see docs/rendering/2d.md#animation).
	sprites:            sprite.State,
	// The UI's documents (see docs/ui/design.md#the-frame).
	ui:                 ui.State,
	// The scene's render.Camera entity. A new scene replaces it, so find_camera looks for it again.
	camera:             ecs.Entity,
	// The built-in renderer, which draws the frame (see docs/rendering/frame.md#frame).
	renderer:           render.Renderer,
	assets:             asset.Assets,
	scripts:            script.Runtime,
	// What the editor knows of the world (see docs/editor/link.md#world).
	editor:             editor.Editor,
}

// USER_OFFSET is where the project's state begins, after Game, at the alignment that the host gives the whole state.
USER_OFFSET :: (size_of(Game) + core.GAME_STATE_ALIGN - 1) / core.GAME_STATE_ALIGN * core.GAME_STATE_ALIGN

// Hooks are what a project with Odin adds to the standard game. Every field may be left out. A project gives them from
// a procedure, which api calls each time it needs them, so nothing of them is kept in the state: a reload gives the new
// DLL's.
Hooks :: struct {
	// The project's own state, which the host keeps with Game across code reloads (see user). Its layout is in
	// layout_hash, so a change restarts the game. nil for none.
	State:               typeid,
	// The physics world's anchor, for a world far from the origin (see docs/physics/design.md#positions-and-precision).
	physics_anchor:      ecs.World_Position,
	// Registers the project's components after the engine's.
	register_components: proc(r: ^ecs.Registry),
	// Makes the project's registrations in the world: systems, queries and extractors. init and on_reload call it after
	// the engine's.
	register_world:      proc(g: ^Game),
	// Defines the project's script bindings and exposes its components. It also runs for script_types, without a Game:
	// a binding finds its Game with game_of only when a script calls it.
	register_scripts:    proc(r: ^script.Runtime),
	// Makes the registrations that need the renderer and the editor: post effects and editor commands. init and
	// on_reload call it once everything is up.
	register:            proc(g: ^Game),
	// Runs at the end of init, before the main scene loads, and at the start of shutdown.
	init:                proc(g: ^Game),
	shutdown:            proc(g: ^Game),
	// Runs at the end of on_reload, after register.
	on_reload:           proc(g: ^Game),
	// Runs when the project's settings' files changed and the engine took them.
	settings_changed:    proc(g: ^Game),
	// Runs at the start of each frame, before the world steps.
	begin_frame:         proc(g: ^Game),
	// Runs each frame after the world stepped and before it is drawn. run is whether it stepped.
	update:              proc(g: ^Game, run: bool),
	// Adds the project's render hooks to the frame. Frame_Hooks.data is the Game, and the UI hook is the engine's.
	frame:               proc(g: ^Game, desc: ^render.Frame_Desc),
	// The test tone's pan, from -1 to 1. Without it the tone is centered.
	tone_pan:            proc(g: ^Game) -> f32,
}

// no_hooks are the standard game's: none.
no_hooks :: proc() -> Hooks {
	return {}
}

// user is the project's state, its Hooks.State, which follows Game.
user :: proc(g: ^Game, $T: typeid) -> ^T where align_of(T) <= core.GAME_STATE_ALIGN {
	return (^T)(uintptr(g) + USER_OFFSET)
}

// game_of is the Game of a script binding.
game_of :: proc "contextless" (L: ^luau.State) -> ^Game {
	return container_of(script.runtime_of(L), Game, "scripts")
}

// api is the Game_API of the standard game with a project's hooks. The project exports it:
//
//	@(export)
//	cinnabar_game_api :: proc() -> core.Game_API { return game.api(hooks) }
api :: proc($hooks: proc() -> Hooks) -> core.Game_API {
	init :: proc(state: rawptr, platform: ^core.Platform_API) {
		game_init(state, platform, hooks(), register)
	}
	update :: proc(state: rawptr, dt: time.Duration) -> bool {
		return game_update((^Game)(state), dt, hooks())
	}
	shutdown :: proc(state: rawptr) {
		game_shutdown((^Game)(state), hooks())
	}
	on_reload :: proc(state: rawptr, platform: ^core.Platform_API) {
		game_reload((^Game)(state), platform, hooks(), register)
	}
	state_size :: proc() -> int {
		return state_bytes(hooks())
	}
	layout_hash :: proc() -> u64 {
		return game_layout_hash(hooks())
	}
	script_types :: proc(platform: ^core.Platform_API) -> string {
		return game_script_types(platform, hooks(), register)
	}
	editor_poll :: proc(state: rawptr, connection: u64, incoming: []core.Editor_Message, out: ^[dynamic]byte) {
		g := (^Game)(state)
		editor.poll(&g.editor, &g.world, &g.scripts, connection, incoming, out, g)
	}
	// The engine's bindings and then the project's. A Register_Proc takes only the runtime, so each image makes its own
	// from its hooks.
	register :: proc(r: ^script.Runtime) {
		register_scripts(r)
		if h := hooks(); h.register_scripts != nil {
			h.register_scripts(r)
		}
	}
	return {
		init = init,
		update = update,
		shutdown = shutdown,
		on_reload = on_reload,
		state_size = state_size,
		layout_hash = layout_hash,
		abi_hash = core.abi_hash,
		script_types = script_types,
		editor_poll = editor_poll,
	}
}

// state_bytes is the size of Game and the project's state after it.
@(private)
state_bytes :: proc(h: Hooks) -> int {
	if h.State == nil {
		return size_of(Game)
	}
	return USER_OFFSET + type_info_of(h.State).size
}

// register_components registers the engine's components and then the project's. init and on_reload call it on the
// world's registry, and layout_hash on its own, so a component change restarts the game.
register_components :: proc(r: ^ecs.Registry, h: Hooks) {
	ecs.register_engine_components(r)
	render.register_components(r)
	script.register_components(r)
	scene.register_components(r)
	volume.register_components(r)
	physics.register_components(r)
	audio.register_components(r)
	anim.register_components(r)
	ui.register_components(r)
	if h.register_components != nil {
		h.register_components(r)
	}
}

// register_scripts defines the engine's script bindings. The project's follow them, in api's register.
register_scripts :: proc(r: ^script.Runtime) {
	scene.register_scripts(r)
	// The bindings read the Game only when a script calls them, which the runtime of script_types, outside any Game,
	// never does.
	g := container_of(r, Game, "scripts")
	project.define_quality_bindings(r, &g.script_quality)
	physics.register_scripts(r, &g.physics)
	audio.register_scripts(r, &g.audio)
	anim.register_scripts(r, &g.animation)
	sprite.register_scripts(r, &g.sprites)
	ui.register_scripts(r, &g.ui)
	script.define(r, "Game.set_paused", proc(L: ^luau.State) -> c.int {
		luau.L_checktype(L, 1, .BOOLEAN)
		game_of(L).paused = bool(luau.toboolean(L, 1))
		return 0
	}, "(paused: boolean) -> ()")
}
