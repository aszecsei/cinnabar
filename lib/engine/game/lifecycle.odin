package game

import "core:hash"
import "core:log"
import "core:mem"
import "core:slice"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/layout"
import "cinnabar:engine/ai"
import "cinnabar:engine/anim"
import "cinnabar:engine/asset"
import "cinnabar:engine/audio"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor"
import "cinnabar:engine/nav"
import "cinnabar:engine/physics"
import "cinnabar:engine/project"
import "cinnabar:engine/render"
import "cinnabar:engine/scene"
import "cinnabar:engine/script"
import "cinnabar:engine/sprite"
import "cinnabar:engine/ui"

@(private)
game_init :: proc(state: rawptr, platform: ^core.Platform_API, h: Hooks, register_scripts: script.Register_Proc) {
	// The state is too large for a temporary on the stack, so it is zeroed in place, the project's with it.
	mem.zero(state, state_bytes(h))
	g := (^Game)(state)
	g.platform = platform
	editor.init(&g.editor, platform, &g.assets, &g.renderer.residency, &g.renderer, &g.nav, &g.ai)
	if !ecs.init(&g.world, platform) {
		log.panic("game: cannot create the world")
	}
	if !physics.init(&g.physics, platform, anchor = h.physics_anchor, assets = &g.assets) {
		log.panic("game: cannot create the physics world")
	}
	audio.init(&g.audio, platform, &g.assets)
	nav.init(&g.nav, platform, &g.assets)
	ai.init(&g.ai, platform, &g.assets, &g.scripts, &g.physics)
	register_world(g, h)
	asset.init(&g.assets, platform, asset.content_source(platform.content_dir))
	render.renderer_init(&g.renderer, platform, &g.assets, &g.world)
	ui.init(&g.ui, platform, &g.assets, &g.renderer.residency)
	g.script_quality = project.script_quality(&g.renderer, platform.project_path)
	ui.sync_pipelines(&g.ui, false)
	if !script.init(&g.scripts, platform, &g.world, &g.assets, register_scripts) {
		log.panic("game: cannot open the script VM")
	}
	// The settings first, so the main scene loads with the project's quality, layers and buses.
	update_project(g, h)
	if h.register != nil {
		h.register(g)
	}
	if h.init != nil {
		h.init(g)
	}
	load_main_scene(g)
	log.info("game: init")
}

// load_main_scene loads the scene that the settings' game.main_scene names. An editor replaces it with its own
// document when it links (see docs/editor/document-and-scenes.md#document-model).
@(private)
load_main_scene :: proc(g: ^Game) {
	guid := g.project.settings.main_scene
	if guid == {} {
		log.warnf("game: %s names no %s, so no scene loads", g.platform.project_path, project.MAIN_SCENE_KEY)
		return
	}
	scene.load_asset(&g.world, &g.scripts, &g.assets, guid)
}

// register_world makes the world's registrations: the components, the engine's systems and queries, and then the
// project's.
@(private)
register_world :: proc(g: ^Game, h: Hooks) {
	w := &g.world
	register_components(&w.registry, h)
	physics.register(&g.physics, w)
	anim.register(&g.animation, w, &g.assets)
	sprite.register(&g.sprites, w, &g.assets)
	// The agents think and act before the paths are found, so a path that an action asks for is solved in the tick.
	ai.register(&g.ai, w)
	nav.register(&g.nav, w)
	if h.register_world != nil {
		h.register_world(g)
	}
}

@(private)
game_update :: proc(g: ^Game, dt: time.Duration, h: Hooks) -> (keep_running: bool) {
	defer end_frame(g)
	g.frame_count += 1

	update_project(g, h)
	if h.begin_frame != nil {
		h.begin_frame(g)
	}
	// In the editor's edit mode, and while it pauses, the world stands still and only its transforms propagate, so
	// edits show. No script code runs then, not even on_disable and on_destroy for the behaviours that a new scene
	// despawns (see docs/editor/document-and-scenes.md#modes).
	run, step := editor.simulation(&g.editor, &g.world, dt)
	if g.paused {
		step = 0
	}
	script.set_quiet(&g.scripts, !run)
	// The documents follow the world in every mode, so the editor's viewport shows them as they are.
	ui.sync(&g.ui, &g.world)
	// The Animators' graphs and clips load before the ticks, so the animate system's jobs only read them.
	anim.prepare(&g.animation, &g.world)
	// The scene's navmeshes load with it, and the frame's queries and path requests read them, in every mode.
	nav.prepare(&g.nav, &g.world)
	// The agents' blackboards and decisions load before the ticks, so the think jobs only read them.
	ai.prepare(&g.ai, &g.world)
	g.frame_step = 0
	if run {
		g.elapsed += step
		g.frame_step = f32(time.duration_seconds(step))
		input := g.platform.input()
		// Each fixed tick runs the Fixed systems, the scripts' fixed step, the physics tick and the tick's events (see
		// docs/physics/design.md#scripts-in-fixed-ticks).
		ticks := ecs.begin_ticks(&g.world, step)
		physics.begin_frame(&g.physics)
		anim.begin_frame(&g.animation)
		for ecs.next_tick(&ticks) {
			ecs.run_tick_systems(&ticks, g)
			script.fixed_update(&g.scripts, &ticks, input)
			ecs.update_transforms(&g.world)
			physics.tick(&g.physics, &g.world)
			physics.send_events(&g.physics, &g.world, &g.scripts)
			anim.send_events(&g.animation, &g.world, &g.scripts)
			ai.send_events(&g.ai, &g.world, &g.scripts)
			script.fixed_events(&g.scripts)
			ecs.update_transforms(&g.world)
		}
		ecs.run_stage(&g.world, .Update, step, g)
		// The UI reads the input against what the player saw, and its events reach the behaviours in the script phase.
		ui.handle_input(&g.ui, input, g.platform.time_seconds())
		ui.flush_events(&g.ui, &g.scripts)
		// The script phase, with its structural changes.
		script.run_phase(&g.scripts, step, input)
		ecs.run_stage(&g.world, .Late, step, g)
	} else {
		ecs.update_transforms(&g.world)
		// The physics world follows the edits without stepping, so queries see the scene as it is.
		physics.sync(&g.physics, &g.world)
		script.settle(&g.scripts)
	}

	find_camera(g)
	// The device takes one writer, and the test tone is that writer when it asks to be.
	if g.platform.audio_test_tone {
		audio.tone_update(&g.tone, g.platform, h.tone_pan(g) if h.tone_pan != nil else 0)
	} else {
		audio.update(&g.audio, &g.world, &g.physics, run, dt)
	}
	ui.sync_pipelines(&g.ui, false)
	if h.update != nil {
		h.update(g, run)
	}
	// A minimized window has no size, and nothing is rendered.
	size := g.platform.window_size()
	if size.x <= 0 || size.y <= 0 {
		return true
	}
	render_frame(g, {u32(size.x), u32(size.y)}, h)
	return true
}

// end_frame lets the frame's animation graphs, navmeshes, blackboards and decisions go, then swaps the blobs that the cooker rewrote, and
// reloads the scripts among them.
@(private)
end_frame :: proc(g: ^Game) {
	anim.end_frame(&g.animation)
	nav.end_frame(&g.nav)
	ai.end_frame(&g.ai)
	script.reload_changed(&g.scripts, asset.poll(&g.assets))
}

// find_camera finds the scene's camera, after a scene load replaced the one that the game knew.
find_camera :: proc(g: ^Game) {
	if ecs.is_alive(&g.world, g.camera) {
		return
	}
	cameras := make([dynamic]ecs.Entity, g.platform.frame_allocator)
	ecs.collect(&g.world, {render.CAMERA_ID}, &cameras)
	g.camera = cameras[0] if len(cameras) > 0 else 0
}

// camera_view is the scene's camera, which the game draws from: the editor's Game view draws from it, and so does the
// game without an editor. The editor's scene views draw from the editor's cameras.
camera_view :: proc(g: ^Game) -> render.View {
	if view, ok := render.camera_view(&g.world, g.camera); ok {
		return view
	}
	return {rotation = 1, projection = render.Perspective{render.DEFAULT_VERTICAL_FOV, render.DEFAULT_NEAR}}
}

// render_frame describes the frame as the game draws it, with or without an editor, and gives it to the editor package
// to draw (see editor.draw_frame), which draws it in the views it shows: the scene's camera, the window's size, the
// skinned poses, the UI's documents in the UI layer, and the project's hooks.
@(private)
render_frame :: proc(g: ^Game, window: [2]u32, h: Hooks) {
	desc := render.Frame_Desc {
		view  = camera_view(g),
		size  = window,
		// The particles step by the time that the world stepped, so they stand still in the editor's Edit and Paused.
		delta = g.frame_step,
		// The skinned entities' poses, between the last two ticks.
		skins = anim.present(&g.animation, &g.world, g.platform.frame_allocator),
		hooks = {data = g, ui = draw_ui_layer},
	}
	if h.frame != nil {
		h.frame(g, &desc)
	}
	editor.draw_frame(&g.editor, &g.renderer, &g.world, desc)
}

// draw_ui_layer draws the UI's documents into the UI layer.
@(private)
draw_ui_layer :: proc(f: ^render.Frame) {
	ui.add_passes(&(^Game)(f.data).ui, f)
}

// update_project reads the project's settings when their files change, and gives them to the renderer, physics, audio,
// the AI and the UI and asks for the output mode, so the editor's change shows at once.
@(private)
update_project :: proc(g: ^Game, h: Hooks) {
	now := g.platform.time_seconds()
	if now < g.next_project_check {
		return
	}
	g.next_project_check = now + PROJECT_CHECK_INTERVAL
	if !project.refresh(&g.project, g.platform, g.platform.project_path) {
		return
	}
	settings := g.project.settings
	render.set_quality(&g.renderer, project.quality(settings, g.renderer.caps))
	physics.set_layers(&g.physics, project.physics_layers(settings))
	audio.set_buses(&g.audio, settings.audio_buses)
	ai.set_tags(&g.ai, settings.perception_tags)
	ui.set_scale_factor(&g.ui, settings.ui_scale)
	g.platform.gpu_request_output(settings.output)
	if h.settings_changed != nil {
		h.settings_changed(g)
	}
}

@(private)
game_shutdown :: proc(g: ^Game, h: Hooks) {
	if h.shutdown != nil {
		h.shutdown(g)
	}
	editor.destroy(&g.editor)
	script.destroy(&g.scripts)
	ui.destroy(&g.ui)
	render.renderer_destroy(&g.renderer)
	// The sprites give their sheets back to the assets.
	sprite.destroy(&g.sprites)
	nav.destroy(&g.nav)
	ai.destroy(&g.ai)
	asset.destroy(&g.assets)
	audio.destroy(&g.audio)
	physics.destroy(&g.physics)
	anim.destroy(&g.animation)
	ecs.destroy(&g.world)
	log.info("game: shutdown")
}

// game_reload makes the registrations again, because the new DLL's procedures and types are new.
@(private)
game_reload :: proc(g: ^Game, platform: ^core.Platform_API, h: Hooks, register_scripts: script.Register_Proc) {
	g.platform = platform
	ecs.reload(&g.world, platform)
	physics.reload(&g.physics, platform)
	audio.reload(&g.audio, platform)
	nav.reload(&g.nav, platform)
	ai.reload(&g.ai, platform)
	register_world(g, h)
	render.renderer_reload(&g.renderer, platform, &g.world)
	asset.reload(&g.assets, platform)
	script.reload(&g.scripts, platform, register_scripts)
	editor.reload(&g.editor, platform)
	ui.on_reload(&g.ui, platform)
	ui.sync_pipelines(&g.ui, true)
	if h.register != nil {
		h.register(g)
	}
	if h.on_reload != nil {
		h.on_reload(g)
	}
	log.infof("game: reloaded at frame %d", g.frame_count)
}

// game_layout_hash covers the project's state and every component's layout too: the world stores components as
// bytes, so Game's own layout does not show them.
@(private)
game_layout_hash :: proc(h: Hooks) -> u64 {
	components: ecs.Registry
	register_components(&components, h)
	user_hash: u64
	if h.State != nil {
		user_hash = layout.hash_typeid(h.State)
	}
	hashes := [3]u64{layout.hash(Game), user_hash, ecs.registry_layout_hash(&components)}
	return hash.fnv64a(slice.to_bytes(hashes[:]))
}

// game_script_types writes the scripts' definition file from a world and a script runtime of its own, so it makes no
// game state and no GPU resources.
@(private)
game_script_types :: proc(platform: ^core.Platform_API, h: Hooks, register_scripts: script.Register_Proc) -> string {
	world := new(ecs.World, platform.permanent_allocator)
	if !ecs.init(world, platform) {
		log.panic("game: cannot create a world for the script types")
	}
	defer ecs.destroy(world)
	register_components(&world.registry, h)
	r := new(script.Runtime, platform.permanent_allocator)
	if !script.init(r, platform, world, nil, register_scripts) {
		log.panic("game: cannot open a script VM for the script types")
	}
	defer script.destroy(r)
	return script.definitions(r, platform.permanent_allocator)
}
