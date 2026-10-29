// The Intel sample: a scene built from USD stages of Intel's Graphics Research Samples Library, Sponza with its
// curtains, which are not in the repository (see README.md). It is the renderer and the editor's link, with none of
// mygame's demonstrations: the stages' prefabs, placed in the scene, are the whole content.
package intel

import "core:hash"
import "core:log"
import "core:mem"
import "core:slice"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/layout"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor"
import "cinnabar:engine/physics"
import "cinnabar:engine/project"
import "cinnabar:engine/render"
import "cinnabar:engine/scene"
import "cinnabar:engine/script"
import "cinnabar:engine/volume"

// The game looks for a change to the project's settings' files this often, in seconds.
PROJECT_CHECK_INTERVAL :: 0.5
// The scene, by the GUID in its .meta file.
MAIN_SCENE_META :: #load("content/scenes/main.scene.meta", string)
// The stages whose prefabs the scene places. The game checks that their prefabs cooked, to say why the scene is empty.
STAGE_METAS :: [?]string {
	#load("content/sponza/sponza_main.usda.meta", string),
	#load("content/sponza/sponza_curtains.usda.meta", string),
}
STAGE_NAMES :: [?]string{"sponza/sponza_main.usda", "sponza/sponza_curtains.usda"}

Game_State :: struct {
	platform:           ^core.Platform_API,
	frame_count:        u64,
	// What the scripts' Render bindings reach: the renderer and the settings file.
	script_quality:     project.Script_Quality,
	// The project's settings, read again when their files change.
	project:            project.Watch,
	next_project_check: f64,
	// The time that the world stepped this frame, in seconds, which the particles step by.
	frame_step:         f32,
	world:              ecs.World,
	physics:            physics.State,
	// The scene's render.Camera entity. A new scene replaces it, so find_camera looks for it again.
	camera:             ecs.Entity,
	renderer:           render.Renderer,
	assets:             asset.Assets,
	scripts:            script.Runtime,
	editor:             editor.Editor,
}

init :: proc(state: rawptr, platform: ^core.Platform_API) {
	s := (^Game_State)(state)
	// Game_State is too large for a temporary on the stack, so it is zeroed in place.
	mem.zero_item(s)
	s.platform = platform
	editor.init(&s.editor, platform, &s.assets, &s.renderer.residency, &s.renderer)
	if !ecs.init(&s.world, platform) {
		log.panic("intel: cannot create the world")
	}
	if !physics.init(&s.physics, platform, assets = &s.assets) {
		log.panic("intel: cannot create the physics world")
	}
	register_world(s)
	asset.init(&s.assets, platform, asset.loose_cache(platform.content_dir))
	render.renderer_init(&s.renderer, platform, &s.assets, &s.world)
	s.script_quality = project.script_quality(&s.renderer, platform.project_path)
	if !script.init(&s.scripts, platform, &s.world, &s.assets, register_scripts) {
		log.panic("intel: cannot open the script VM")
	}
	report_missing_stages(s)
	// An editor replaces this scene with its own document when it links.
	if guid, ok := format.meta_guid(MAIN_SCENE_META); ok {
		scene.load_asset(&s.world, &s.scripts, &s.assets, guid)
	}
	log.info("intel: init")
}

// report_missing_stages logs each stage whose prefab has not cooked, which happens when its downloads are not
// unpacked: its scene then shows only what the scene itself places.
report_missing_stages :: proc(s: ^Game_State) {
	metas, names := STAGE_METAS, STAGE_NAMES
	for text, i in metas {
		meta, ok := format.meta_parse(text, s.platform.frame_allocator)
		if !ok {
			continue
		}
		prefab, found := format.meta_subasset(meta, format.PREFAB_KIND, "stage")
		if !found {
			continue
		}
		if h, loaded := asset.load(&s.assets, prefab); loaded {
			asset.unload(&s.assets, h)
			continue
		}
		log.warnf("intel: %s has not cooked. Put the downloads in samples/intel/downloads and run `just intel-unpack` (see samples/intel/README.md).", names[i])
	}
}

// register_components registers every component type. init and on_reload call it on the world's registry, and
// layout_hash on its own, so a component change restarts the game.
register_components :: proc(r: ^ecs.Registry) {
	ecs.register_engine_components(r)
	render.register_components(r)
	script.register_components(r)
	scene.register_components(r)
	volume.register_components(r)
	physics.register_components(r)
}

register_world :: proc(s: ^Game_State) {
	register_components(&s.world.registry)
	physics.register(&s.physics, &s.world)
}

register_scripts :: proc(r: ^script.Runtime) {
	scene.register_scripts(r)
	project.define_quality_bindings(r, &container_of(r, Game_State, "scripts").script_quality)
	physics.register_scripts(r, &container_of(r, Game_State, "scripts").physics)
}

find_camera :: proc(s: ^Game_State) {
	if ecs.is_alive(&s.world, s.camera) {
		return
	}
	cameras := make([dynamic]ecs.Entity, s.platform.frame_allocator)
	ecs.collect(&s.world, {render.CAMERA_ID}, &cameras)
	s.camera = cameras[0] if len(cameras) > 0 else 0
}

update :: proc(state: rawptr, dt: time.Duration) -> (keep_running: bool) {
	s := (^Game_State)(state)
	defer script.reload_changed(&s.scripts, asset.poll(&s.assets))
	s.frame_count += 1

	update_project(s)
	run, step := editor.simulation(&s.editor, &s.world, dt)
	script.set_quiet(&s.scripts, !run)
	s.frame_step = 0
	if run {
		s.frame_step = f32(time.duration_seconds(step))
		input := s.platform.input()
		ticks := ecs.begin_ticks(&s.world, step)
		physics.begin_frame(&s.physics)
		for ecs.next_tick(&ticks) {
			ecs.run_tick_systems(&ticks, s)
			script.fixed_update(&s.scripts, &ticks, input)
			ecs.update_transforms(&s.world)
			physics.tick(&s.physics, &s.world)
			physics.send_events(&s.physics, &s.world, &s.scripts)
			script.fixed_events(&s.scripts)
			ecs.update_transforms(&s.world)
		}
		ecs.run_stage(&s.world, .Update, step, s)
		script.run_phase(&s.scripts, step, input)
		ecs.run_stage(&s.world, .Late, step, s)
	} else {
		ecs.update_transforms(&s.world)
		physics.sync(&s.physics, &s.world)
		script.settle(&s.scripts)
	}

	find_camera(s)
	// A minimized window has no size, and nothing is rendered.
	size := s.platform.window_size()
	if size.x <= 0 || size.y <= 0 {
		return true
	}
	render_frame(s, {u32(size.x), u32(size.y)}, camera_view(s))
	return true
}

// camera_view is the editor's camera while an editor is linked, and the scene's camera otherwise.
camera_view :: proc(s: ^Game_State) -> render.View {
	if view, ok := editor.view(&s.editor); ok {
		return view
	}
	if view, ok := render.camera_view(&s.world, s.camera); ok {
		return view
	}
	return {rotation = 1, vertical_fov = render.DEFAULT_VERTICAL_FOV, near = render.DEFAULT_NEAR}
}

render_frame :: proc(s: ^Game_State, size: [2]u32, view: render.View) {
	editing := editor.active(&s.editor)
	overrides := editor.render_overrides(&s.editor)
	quality, viewport_quality := editor.viewport_quality(&s.editor, &s.renderer)
	editor.draw_helpers(&s.editor, &s.world, &s.renderer.debug)
	desc := render.Frame_Desc {
		view            = view,
		size            = size,
		keep_ids        = editing,
		no_debug        = !editor.debug_shown(&s.editor),
		hidden          = editor.visibility(&s.editor, &s.world).hidden,
		debug_view      = overrides.debug_view,
		disable         = overrides.disable,
		exposure_offset = overrides.exposure_offset,
		quality         = viewport_quality ? &quality : nil,
		previews        = editor.previews(&s.editor),
		delta           = s.frame_step,
		playing         = editor.playing(&s.editor),
		hooks           = {data = s, debug = editing ? draw_editor_tools : nil},
	}
	render.draw_frame(&s.renderer, &s.world, desc)
}

// draw_editor_tools adds the editor's pick, and in Edit its icons, outline and gizmo.
draw_editor_tools :: proc(f: ^render.Frame) {
	s := (^Game_State)(f.data)
	editor.add_viewport_passes(
		&s.editor,
		f.graph,
		&s.world,
		{view = f.view, size = f.size, output_size = f.output_size, target = f.debug, ids = f.ids, depth = f.depth},
	)
}

// update_project reads the project's settings again when their files change, so the editor's change shows at once.
update_project :: proc(s: ^Game_State) {
	now := s.platform.time_seconds()
	if now < s.next_project_check {
		return
	}
	s.next_project_check = now + PROJECT_CHECK_INTERVAL
	if project.refresh(&s.project, s.platform, s.platform.project_path) {
		render.set_quality(&s.renderer, project.quality(s.project.settings, s.renderer.caps))
		physics.set_layers(&s.physics, project.physics_layers(s.project.settings))
		s.platform.gpu_request_output(s.project.settings.output)
	}
}

shutdown :: proc(state: rawptr) {
	s := (^Game_State)(state)
	editor.destroy(&s.editor)
	script.destroy(&s.scripts)
	render.renderer_destroy(&s.renderer)
	asset.destroy(&s.assets)
	physics.destroy(&s.physics)
	ecs.destroy(&s.world)
	log.info("intel: shutdown")
}

on_reload :: proc(state: rawptr, platform: ^core.Platform_API) {
	s := (^Game_State)(state)
	s.platform = platform
	ecs.reload(&s.world, platform)
	physics.reload(&s.physics, platform)
	register_world(s)
	render.renderer_reload(&s.renderer, platform, &s.world)
	asset.reload(&s.assets, platform)
	script.reload(&s.scripts, platform, register_scripts)
	editor.reload(&s.editor, platform)
	log.infof("intel: reloaded at frame %d", s.frame_count)
}

state_size :: proc() -> int {
	return size_of(Game_State)
}

// layout_hash covers the component layouts too: the world stores components as bytes, so Game_State's own layout
// does not show them.
layout_hash :: proc() -> u64 {
	components: ecs.Registry
	register_components(&components)
	hashes := [2]u64{layout.hash(Game_State), ecs.registry_layout_hash(&components)}
	return hash.fnv64a(slice.to_bytes(hashes[:]))
}

// script_types writes the scripts' definition file from a world and a script runtime of its own.
script_types :: proc(platform: ^core.Platform_API) -> string {
	world := new(ecs.World, platform.permanent_allocator)
	if !ecs.init(world, platform) {
		log.panic("intel: cannot create a world for the script types")
	}
	defer ecs.destroy(world)
	register_components(&world.registry)
	r := new(script.Runtime, platform.permanent_allocator)
	if !script.init(r, platform, world, nil, register_scripts) {
		log.panic("intel: cannot open a script VM for the script types")
	}
	defer script.destroy(r)
	return script.definitions(r, platform.permanent_allocator)
}

editor_poll :: proc(state: rawptr, connection: u64, incoming: []core.Editor_Message, out: ^[dynamic]byte) {
	s := (^Game_State)(state)
	editor.poll(&s.editor, &s.world, &s.scripts, connection, incoming, out, s)
}

@(export)
cinnabar_game_api :: proc() -> core.Game_API {
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
