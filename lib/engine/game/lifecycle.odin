package game

import "core:hash"
import "core:log"
import "core:mem"
import "core:slice"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/layout"
import "cinnabar:engine/ai"
import "cinnabar:engine/ai/behavior_tree"
import "cinnabar:engine/ai/goap"
import "cinnabar:engine/ai/htn"
import "cinnabar:engine/ai/utility"
import "cinnabar:engine/anim"
import "cinnabar:engine/asset"
import "cinnabar:engine/audio"
import "cinnabar:engine/camera"
import "cinnabar:engine/cutscene"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor"
import "cinnabar:engine/nav"
import "cinnabar:engine/physics"
import "cinnabar:engine/project"
import "cinnabar:engine/render"
import "cinnabar:engine/scene"
import "cinnabar:engine/script"
import "cinnabar:engine/sprite"
import "cinnabar:engine/streaming"
import "cinnabar:engine/ui"

@(private)
game_init :: proc(
	state: rawptr,
	platform: ^core.Platform_API,
	h: Hooks,
	register_scripts: script.Register_Proc,
) {
	// The state is too large for a temporary on the stack, so it is zeroed in place, the project's with it.
	mem.zero(state, state_bytes(h))
	g := (^Game)(state)
	g.platform = platform
	scene.init_scenes(&g.scenes, platform, &g.assets, &g.scripts)
	streaming.init(&g.streaming, platform, &g.assets)
	g.scene_requests = make([dynamic]Scene_Request, platform.heap_allocator)
	g.sublevels.events = make([dynamic]Sublevel_Event, platform.heap_allocator)
	editor.init(
		&g.editor,
		platform,
		&g.assets,
		&g.renderer.residency,
		&g.renderer,
		&g.nav,
		&g.ai,
		&g.scenes,
		&g.streaming,
		&g.views,
		&g.animation,
	)
	if !ecs.init(&g.world, platform) {
		log.panic("game: cannot create the world")
	}
	if !physics.init(&g.physics, platform, anchor = h.physics_anchor, assets = &g.assets) {
		log.panic("game: cannot create the physics world")
	}
	audio.init(&g.audio, platform, &g.assets)
	nav.init(&g.nav, platform, &g.assets, &g.physics)
	ai.init(&g.ai, platform, &g.assets, &g.scripts, &g.physics)
	cutscene.init(&g.cutscenes, &g.world, &g.assets, &g.scripts.input_actions)
	register_world(g, h)
	asset.init(&g.assets, platform, asset.content_source(platform.content_dir))
	render.renderer_init(&g.renderer, platform, &g.assets, &g.world)
	ui.init(&g.ui, platform, &g.assets, &g.renderer.residency)
	g.script_quality = project.script_quality(&g.renderer, platform.project_path)
	ui.sync_pipelines(&g.ui, false)
	if !script.init(&g.scripts, platform, &g.world, &g.assets, register_scripts) {
		log.panic("game: cannot open the script VM")
	}
	// The settings first, so the main scene loads with the project's quality, layers, buses and sublevels.
	update_project(g, h)
	reset_sublevels(&g.sublevels, g.project.settings.sublevels)
	g.sublevels.level = platform.level_generation()
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
		log.warnf(
			"game: %s names no %s, so no scene loads",
			g.platform.project_path,
			project.MAIN_SCENE_KEY,
		)
		return
	}
	if scene.load_asset(&g.world, &g.scripts, &g.assets, guid, &g.scenes) {
		scene.load_parts(&g.world, &g.scripts, &g.scenes, 0, active_sublevels(g))
	}
}

// register_world makes the world's registrations: the components, the engine's systems and queries, and then the
// project's.
@(private)
register_world :: proc(g: ^Game, h: Hooks) {
	w := &g.world
	register_components(&w.registry, h)
	// The cutscenes' systems come first in their stages, and run alone: their tracks write any component, so every
	// other system of the tick, the animator's and physics' among them, sees what they wrote.
	cutscene.register(&g.cutscenes, w)
	physics.register(&g.physics, w)
	anim.register(&g.animation, w, &g.assets)
	sprite.register(&g.sprites, w, &g.assets)
	// The agents think and act before the paths are found and the crowd moves, so a move that an action asks for applies
	// in the next tick, and the crowd takes the paths that the paths system solved in its own tick.
	ai.register(&g.ai, w)
	behavior_tree.register(&g.ai)
	utility.register(&g.ai)
	goap.register(&g.ai)
	htn.register(&g.ai)
	nav.register(&g.nav, w, &g.ai)
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
	// The scenes that scripts or begin_frame asked for, before the systems prepare for the world.
	scene.clear_part_events(&g.scenes)
	clear(&g.sublevels.events)
	apply_scene_requests(g)
	// The world's scenes that the camera and the sources are near, which load a few entities at a time, and the parts
	// of the active sublevels.
	stream_scenes(g)
	update_sublevels(g)
	send_sublevel_events(g)
	// A hold of the skip action skips before the players move on, so its skip fades from this frame (see
	// docs/cinematics/skipping.md#input).
	frame_input := g.platform.input()
	cutscene.update_skip(&g.cutscenes, &g.world, &frame_input, dt)
	// The players load, resolve their bindings and give the world back here, outside the systems and the script phase,
	// once the frame's scenes are in place (see docs/cinematics/player.md#the-frame).
	if cutscene.update(&g.cutscenes, {&g.world, &g.scenes, &g.scripts, dt}) > 0 {
		forget_despawned(g)
	}
	// In the editor's edit mode, and while it pauses, the world stands still and only its transforms propagate, so
	// edits show. No script code runs then but the edit phase's, for the behaviours that run in edit mode, whose writes
	// go to the editor's document (see docs/editor/document-and-scenes.md#modes).
	what, step := editor.simulation(&g.editor, &g.world, dt)
	run := what == .Run
	// The editor's own steps, a tick at a time while it pauses, take no scale.
	step = world_step(g, step, editor.mode(&g.editor) == .Play)
	script.set_frame_time(&g.scripts, dt, time_scale_of(g))
	script.set_callbacks(&g.scripts, editor.script_callbacks(&g.editor, what))
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
		input := frame_input
		// The cutscenes on the real clock move by the frame's real time, which the pause and the time scale do not change,
		// and write their Fixed tracks before the ticks (see docs/cinematics/evaluation.md#the-clock).
		cutscene.advance_real(&g.cutscenes, &g.world, dt)
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
		switch what {
		case .Edit:
			// The edit-mode behaviours run, and what they did goes to the editor, whose answer the next phase waits for.
			// They see and edit the document, without the editor's overrides over it (see editor.lift_overrides).
			if editor.lift_overrides(&g.editor, &g.world) {
				ecs.update_transforms(&g.world)
			}
			script.run_edit_phase(&g.scripts, dt)
			editor.send_behaviour_edits(&g.editor, &g.world, &g.scripts)
			if editor.lay_overrides(&g.editor, &g.world) {
				ecs.update_transforms(&g.world)
			}
		case .Hold:
			script.settle(&g.scripts)
		case .Wait, .Run:
		// While the editor's answer is due, the world's changes wait for the scripts, which see them in the next phase.
		}
	}

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
	// The views choose their cameras after every push of the frame, the project's too, and their blends step by the
	// world's time or the host's.
	shown := camera.advance(&g.views, &g.world, {g.frame_step, f32(time.duration_seconds(dt))})
	send_camera_events(g)
	// A minimized window has no size, and nothing is rendered.
	size := g.platform.window_size()
	if size.x <= 0 || size.y <= 0 {
		return g.run != .Quitting
	}
	render_frame(g, {u32(size.x), u32(size.y)}, shown, h)
	// The frame carried the views' cuts. A frame that is not drawn leaves them for the next.
	camera.drawn(&g.views)
	return g.run != .Quitting
}

// end_frame lets the frame's animation graphs, navmeshes, blackboards and decisions go, then swaps the blobs that the cooker rewrote, and
// reloads the scripts among them.
@(private)
end_frame :: proc(g: ^Game) {
	anim.end_frame(&g.animation)
	nav.end_frame(&g.nav)
	ai.end_frame(&g.ai)
	cutscene.end_frame(&g.cutscenes)
	// An edit-mode behaviour's on_reload can edit the editor's document, which it sees without the editor's overrides.
	editor.lift_overrides(&g.editor, &g.world)
	script.reload_changed(&g.scripts, asset.poll(&g.assets))
	editor.send_behaviour_edits(&g.editor, &g.world, &g.scripts)
	editor.lay_overrides(&g.editor, &g.world)
}

// send_camera_events tells each pusher whose camera's entry went this frame, for it, why: on_camera_removed, with the
// token's number and the reason (see docs/world/cameras.md#tokens).
@(private)
send_camera_events :: proc(g: ^Game) {
	for e in camera.ended(&g.views) {
		if e.owner == 0 || !ecs.is_alive(&g.world, e.owner) {
			continue
		}
		reason: string
		switch e.reason {
		case .Despawned:
			reason = "despawned"
		}
		script.send(&g.scripts, e.owner, "camera_removed", camera.token_number(e.token), reason)
	}
}

// camera_view is what a game view shows now, from its camera stack: by default the first view's, which the editor's
// Game view draws as the own view, and so does the game without an editor. The editor's scene views draw from the
// editor's cameras.
camera_view :: proc(g: ^Game, index := 0) -> render.View {
	return camera.view_of(&g.views, &g.world, index)
}

// render_frame lays the UI out in the window and the views' rects, describes the frame as the game draws it (see
// describe_frame), and gives it to the editor package to draw (see editor.draw_frame), which draws it in the views it
// shows.
@(private)
render_frame :: proc(g: ^Game, window: [2]u32, shown: camera.Frame_Views, h: Hooks) {
	shown := shown
	rects: [camera.MAX_VIEWS][4]f32
	for v, i in shown.views[:shown.count] {
		origin, extent := camera.pixel_rect(v.rect, window)
		rects[i] = {f32(origin.x), f32(origin.y), f32(extent.x), f32(extent.y)}
	}
	// While a claim shows, no player's view does, and neither do the documents of the players' views.
	ui.layout(
		&g.ui,
		{f32(window.x), f32(window.y)},
		rects[:0] if shown.claimed else rects[:shown.count],
	)
	// The skinned entities' poses, between the last two ticks.
	skins := anim.present(&g.animation, &g.world, g.platform.frame_allocator)
	desc := describe_frame(g, window, shown, skins, h)
	editor.draw_frame(&g.editor, &g.renderer, &g.world, desc)
}

// describe_frame is the game's frame: the first game view as the own view, the skinned poses given, the UI's documents in the
// UI layer, and the project's hooks, then each other game view as an extra view in its rect of the window, with the
// project's hooks and settings, before the project's own extra views. One full view draws as a game with one camera
// always did, with no rect (see docs/rendering/frame.md#views-in-rects).
@(private)
describe_frame :: proc(
	g: ^Game,
	window: [2]u32,
	shown: camera.Frame_Views,
	skins: []render.Skin_Pose,
	h: Hooks,
) -> (
	desc: render.Frame_Desc,
) {
	shown := shown
	first := shown.views[0]
	origin, extent := camera.pixel_rect(first.rect, window)
	desc = {
		view = first.view,
		size = extent,
		cut = first.cut,
		// The particles step by the time that the world stepped, so they stand still in the editor's Edit and Paused.
		delta = g.frame_step,
		skins = skins,
		hooks = {data = g, ui = draw_ui_layer},
	}
	if shown.count > 1 || extent != window {
		desc.rect = render.Target_Rect {
			target_size = window,
			origin      = origin,
		}
	}
	if h.frame != nil {
		h.frame(g, &desc)
	}
	if shown.count <= 1 {
		return
	}
	extras := make([dynamic]render.Extra_View, g.platform.frame_allocator)
	for v in shown.views[1:shown.count] {
		view_origin, view_extent := camera.pixel_rect(v.rect, window)
		append(
			&extras,
			render.Extra_View {
				view = v.view,
				size = view_extent,
				state = camera.view_state(&g.views, &g.renderer, v.index),
				quality = desc.quality,
				settings = desc.settings,
				keep_ids = desc.keep_ids,
				no_debug = desc.no_debug,
				debug_view = desc.debug_view,
				disable = desc.disable,
				exposure_offset = desc.exposure_offset,
				hooks = desc.hooks,
				rect = render.Target_Rect{target_size = window, origin = view_origin},
				cut = v.cut,
			},
		)
	}
	append(&extras, ..desc.extra_views)
	desc.extra_views = extras[:]
	return
}

// draw_ui_layer draws the UI's documents into the UI layer.
@(private)
draw_ui_layer :: proc(f: ^render.Frame) {
	ui.add_passes(&(^Game)(f.data).ui, f)
}

// update_project reads the project's settings when their files change, and gives them to the renderer, physics, audio,
// the AI, the UI and the display, which takes the window's mode and size, the output mode and the paper white if their
// keys changed, so the editor's change shows at once.
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
	cutscene.set_skip_input(
		&g.cutscenes,
		string(settings.skip_action[:settings.skip_action_length]),
		settings.skip_hold,
	)
	project.apply_display_settings(&g.display_applied, g.platform, &g.renderer, settings)
	if h.settings_changed != nil {
		h.settings_changed(g)
	}
}

@(private)
game_shutdown :: proc(g: ^Game, h: Hooks) {
	if h.shutdown != nil {
		h.shutdown(g)
	}
	// The players give the world back, and their assets, while the world, the scripts and the assets are alive.
	cutscene.destroy(&g.cutscenes, &g.world)
	editor.destroy(&g.editor)
	script.destroy(&g.scripts)
	// Before the assets, to which the streaming and the scenes give their blobs back.
	streaming.destroy(&g.streaming)
	scene.destroy_scenes(&g.scenes)
	delete(g.scene_requests)
	delete(g.sublevels.events)
	ui.destroy(&g.ui)
	// The game views' states are the renderer's objects.
	camera.destroy(&g.views, &g.renderer)
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
game_reload :: proc(
	g: ^Game,
	platform: ^core.Platform_API,
	h: Hooks,
	register_scripts: script.Register_Proc,
) {
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
	scene.reload_scenes(&g.scenes, platform)
	streaming.reload(&g.streaming, platform)
	ui.on_reload(&g.ui, platform)
	ui.sync_pipelines(&g.ui, true)
	if h.register != nil {
		h.register(g)
	}
	// The editor's overrides end with the world as the document has it, now that every component is registered again,
	// and before the project's on_reload sees the world.
	if editor.end_overrides(&g.editor, &g.world, .Code_Reloaded) {
		forget_despawned(g)
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
game_script_types :: proc(
	platform: ^core.Platform_API,
	h: Hooks,
	register_scripts: script.Register_Proc,
) -> string {
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
