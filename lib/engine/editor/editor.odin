// Package editor is the game's side of the editor link (see docs/editor/link.md#world): the component types, the entity
// list and its deltas, and the values of the entities that the editor watches. The game keeps an Editor in its
// Game_State and calls poll from Game_API.editor_poll.
package editor

import "base:runtime"
import "core:hash"
import "core:log"
import "core:strings"

import "cinnabar:core"
import "cinnabar:core/profile"
import "cinnabar:engine/ai"
import "cinnabar:engine/anim"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/camera"
import "cinnabar:engine/cutscene"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/nav"
import "cinnabar:engine/render"
import "cinnabar:engine/scene"
import "cinnabar:engine/script"
import "cinnabar:engine/streaming"
import "cinnabar:engine/ui"

// The entity list changes at most this often in the editor.
SCAN_INTERVAL :: 0.1
// Watched values change at most this often in the editor.
VALUES_INTERVAL :: 0.05
// Game_Stats go out this often.
STATS_INTERVAL :: 0.25
MAX_WATCHED :: 64

// Editor is the game's side of the editor link. It lives in Game_State. Its arrays use the host's heap, so they
// survive a code reload. What one editor connection has told the game, and has been told, is its session. A soft
// restart makes a new Editor, with a new session, which sends everything again.
Editor :: struct {
	platform:    ^core.Platform_API,
	// The game's asset runtime, in Game_State, which the viewport tools load their shaders from.
	assets:      ^asset.Assets,
	session:     Session,
	// The world's scenes, whose maps find the entity of each scene ID by the number of its scene for the editor's
	// operations (see scene.find): the game's, or the editor's own (owns_scenes) when init got none.
	scenes:      ^scene.Scenes,
	owns_scenes: bool,
	// The viewport tools' GPU objects (see viewport.odin).
	tools:       Viewport_Tools,
	// The game's commands (see commands.odin). Registrations: reload clears them.
	commands:    [dynamic]Command,
	// The UI documents that previews show, each in a slot of its own, apart from the game's UI (see ui_preview.odin).
	ui:          ui.State,
	// The renderer's residency, which draws the live meshes, in Game_State, or nil without a renderer.
	residency:   ^render.Residency,
	// The renderer, which answers where the texture sky's sun is.
	renderer:    ^render.Renderer,
	// The game's navigation, in Game_State, whose navmeshes the helpers draw, or nil without one.
	nav:         ^nav.State,
	// The game's AI, in Game_State, whose perceivers' memories the helpers draw, or nil without one.
	ai:          ^ai.State,
	// The game's scene streaming, in Game_State, whose work the stats report, or nil without one.
	streaming:   ^streaming.State,
	// The game's camera stacks and animation, in Game_State, which overrides push cameras on and drive Animators
	// through, or nil without them (see overrides.odin).
	views:       ^camera.Views,
	animation:   ^anim.State,
	// The game's cutscenes, which the cutscene preview loads and evaluates through, or nil without them (see
	// cutscene_preview.odin).
	cutscenes:   ^cutscene.State,
	// How many times the editor replaced the game's world with its scene (Load_Scene), in every session: the game
	// starts what it keeps for a world again when this changes (see world_loads).
	loads:       u64,
}

// Session is the state of one editor connection: what the editor has sent the game, and what the game has sent the
// editor. begin_session starts one and end_session ends it, for each connection and for none (connection 0), so state
// that a new editor must not inherit belongs here, and end_session frees it (see
// docs/overview/conventions.md#state-with-a-lifecycle).
Session :: struct {
	// The connection that this session is for. Another one means a new editor, which gets everything.
	connection:        u64,
	types_sent:        bool,
	// What the editor knows of each entity slot, by entity index.
	known:             [dynamic]Known,
	// The version that the last scan took, and how many entities the world had despawned at it.
	scan_version:      u64,
	despawned:         u64,
	watched:           [dynamic]Watched,
	// The editor's viewports, each with its camera and gizmo, its selection and its picks (see viewport.odin).
	view:              View,
	// The mode that the editor set (see modes.odin).
	mode:              link.Editor_Mode,
	// Step_Frame messages that wait for a paused frame.
	steps:             int,
	last_scan:         f64,
	last_values:       f64,
	last_stats:        f64,
	// The bytes of mesh pages that the renderer had streamed when the stats were last sent.
	pages_streamed:    u64,
	// The bytes of virtual texture pages that the renderer had streamed when the stats were last sent.
	texture_bytes:     u64,
	// The material editor's previews, by ID, and the one to draw next (see preview.odin).
	previews:          [MAX_PREVIEWS]Preview,
	next_preview:      int,
	thumbnail:         Thumbnail,
	// The meshes that the editor edits, drawn from memory in place of their assets (see live.odin).
	live_meshes:       map[format.Guid]Live_Mesh,
	// What mesh mode draws over the live meshes (see mesh_overlay.odin), in the host's heap.
	mesh_overlay:      link.Mesh_Overlay,
	// The textures that the landscape tools paint, drawn from memory in place of their assets (see live_texture.odin).
	live_textures:     map[format.Guid]Live_Texture,
	// The landscape brush that the helpers draw.
	brush:             link.Landscape_Overlay,
	// Set while the world is the editor's document in Edit: from the Load_Scene that made it, until the mode changes
	// (see behaviours.odin).
	mirror:            Maybe(Mirror),
	// The streaming policy's changes when the session last sent Streamed_Scenes (see world_view.odin).
	streamed_sent:     u64,
	// The last ticket that the behaviours' edits had, and the messages that wait for poll, in the host's heap.
	edit_tickets:      u64,
	outbox:            [dynamic]byte,
	// What the editor's owners write over the world in Edit (see overrides.odin).
	overrides:         Overrides,
	// The cutscene editor's preview, which lays over the world with the overrides (see cutscene_preview.odin).
	cutscene_previews: Cutscene_Previews,
}

// Mirror is the world as a copy of the editor's document: the ticket of the Load_Scene that made it, and the
// behaviours' last edits, while the editor has not answered them or for a second after it refused them.
Mirror :: struct {
	scene: u64,
	batch: Batch,
}

Batch :: union {
	Batch_Sent,
	Batch_Refused,
}

Batch_Sent :: struct {
	ticket: u64,
}

// Batch_Refused holds the edit phase until a time, by time_seconds, or the editor's next edit.
Batch_Refused :: struct {
	until: f64,
}

@(private)
Known :: struct {
	// 0 when the editor knows of no entity in this slot.
	entity:    ecs.Entity,
	archetype: u32,
	parent:    ecs.Entity,
	active:    bool,
	// A hash of the name, which scripts and systems can change.
	name:      u64,
}

@(private)
Watched :: struct {
	entity:        ecs.Entity,
	// The hash of the values that the editor last got, or 0 to send them at the next chance.
	sent:          u64,
	// The hash of its Animator's view that the editor last got, 0 for an empty one, or nil before the first, which then
	// goes out whatever it is, so a watch tells the editor even of no Animator (see animators.odin).
	animator_sent: Maybe(u64),
	// The same for its Agent's view (see agents.odin).
	agent_sent:    Maybe(u64),
	// The same for its reflection probe's view, 0 for None (see reflection_probes.odin).
	probe_sent:    Maybe(u64),
}

// init starts the editor's game side. The viewport tools load their shaders from assets, which must outlive the
// editor; without them (nil), the tools stay off. The live meshes draw through residency, the renderer's, which must
// outlive the editor too; without it (nil), they are kept and baked but not drawn. The renderer answers for the sky
// (see Sky_Sun_Request); without it (nil), the sky has no sun. scenes is the game's table of the world's scenes, which
// the editor's loads and operations use; without it (nil), the editor keeps its own.
init :: proc(
	e: ^Editor,
	platform: ^core.Platform_API,
	assets: ^asset.Assets,
	residency: ^render.Residency = nil,
	renderer: ^render.Renderer = nil,
	navigation: ^nav.State = nil,
	agents: ^ai.State = nil,
	scenes: ^scene.Scenes = nil,
	streaming_state: ^streaming.State = nil,
	views: ^camera.Views = nil,
	animation: ^anim.State = nil,
	cutscenes: ^cutscene.State = nil,
) {
	e^ = {
		platform  = platform,
		assets    = assets,
		residency = residency,
		renderer  = renderer,
		nav       = navigation,
		ai        = agents,
		scenes    = scenes,
		streaming = streaming_state,
		views     = views,
		animation = animation,
		cutscenes = cutscenes,
		commands  = make([dynamic]Command, platform.heap_allocator),
	}
	if e.scenes == nil {
		e.scenes = new(scene.Scenes, platform.heap_allocator)
		scene.init_scenes(e.scenes, platform, assets)
		e.owns_scenes = true
	}
	if assets != nil {
		ui.init(&e.ui, platform, assets, residency)
	}
	begin_session(e, 0)
}

// begin_session starts the session of a connection, or of none (0). The session before it must have ended.
@(private)
begin_session :: proc(e: ^Editor, connection: u64) {
	heap := e.platform.heap_allocator
	e.session = {
		connection = connection,
		known = make([dynamic]Known, heap),
		watched = make([dynamic]Watched, heap),
		live_meshes = make(map[format.Guid]Live_Mesh, heap),
		live_textures = make(map[format.Guid]Live_Texture, heap),
		outbox = make([dynamic]byte, heap),
		overrides = {live = make([dynamic]Override, heap)},
		view = {
			selection = make([dynamic]ecs.Entity, heap),
			hidden = make([dynamic]ecs.Entity, heap),
			picks = make([dynamic]link.Pick_Request, heap),
			nav_probe = make([dynamic]ecs.World_Position, heap),
			world_scenes = make([dynamic]link.World_View_Scene, heap),
		},
	}
	for &v in e.session.view.viewports {
		v.handles = make([dynamic]link.Box_Handle, heap)
	}
}

// end_session ends the session: it closes the previews, the thumbnail and the viewports, with their targets and view
// states, releases the live meshes and the mesh overlay, frees the session's arrays, and zeroes it. A pick that the GPU
// still runs comes back with an old ticket, so nothing reads it.
@(private)
end_session :: proc(e: ^Editor) {
	s := &e.session
	release_live_meshes(e)
	release_live_textures(e)
	close_previews(e)
	free_overrides(&s.overrides)
	free_cutscene_previews(&s.cutscene_previews)
	delete(s.live_meshes)
	delete(s.live_textures)
	delete(s.outbox)
	delete(s.known)
	delete(s.watched)
	for &v, i in s.view.viewports {
		close_viewport(e, i)
		delete(v.handles)
	}
	delete(s.view.selection)
	delete(s.view.hidden)
	delete(s.view.picks)
	delete(s.view.nav_probe)
	delete(s.view.world_scenes)
	s^ = {}
}

// reload sends the types again after a code reload: the new DLL may describe them differently. It forgets the commands,
// whose procedures are the old DLL's, so register them again after it.
reload :: proc(e: ^Editor, platform: ^core.Platform_API) {
	e.platform = platform
	if e.owns_scenes {
		scene.reload_scenes(e.scenes, platform)
	}
	e.session.types_sent = false
	clear(&e.commands)
	sync_viewport_pipelines(e, force = true)
	if e.ui.platform != nil {
		ui.on_reload(&e.ui, platform)
		if e.renderer != nil {
			ui.sync_pipelines(&e.ui, force = true)
		}
	}
}

destroy :: proc(e: ^Editor) {
	end_session(e)
	if e.owns_scenes {
		scene.destroy_scenes(e.scenes)
		free(e.scenes, e.platform.heap_allocator)
	}
	delete(e.commands)
	if e.ui.platform != nil {
		ui.destroy(&e.ui)
	}
	if e.tools.gpu_ready {
		destroy_viewport_gpu(e)
	}
	e^ = {}
}

// poll handles the editor's messages and appends the game's messages to out. Call it between frames, outside the
// script phase. user is the game's own data, which its commands get. despawned is whether a scene that the editor
// closed despawned entities, which the systems that keep data by entity must then forget (see game.forget_despawned).
poll :: proc(
	e: ^Editor,
	w: ^ecs.World,
	scripts: ^script.Runtime,
	connection: u64,
	incoming: []core.Editor_Message,
	out: ^[dynamic]byte,
	user: rawptr = nil,
) -> (
	despawned: bool,
) {
	profile.scope_text(&e.platform.profile, "Editor poll", .Editor)
	if e.scenes.scripts == nil {
		e.scenes.scripts = scripts
	}
	snapshot := false
	// A scene that opened or closed beside the others changes only its own entities, which a delta describes now.
	rescan := false
	if connection != e.session.connection {
		// The world outlives the editor that went, and shows the document as the editor left it.
		if end_overrides(e, w, nil) {
			despawned = true
		}
		end_session(e)
		begin_session(e, connection)
		// A new editor is in Edit, so its first scene replaces the world without the old behaviours' callbacks.
		if scripts != nil {
			script.set_callbacks(scripts, callbacks_between_frames(e))
		}
		snapshot = connection != 0
	}
	if connection == 0 {
		return
	}
	// The editor's messages edit the document, and what goes back describes it, so the overrides are off the world
	// until the poll ends (see overrides.odin). The frame propagates their transforms after the poll.
	frame := e.platform.frame_allocator
	now := e.platform.time_seconds()
	values_due := now - e.session.last_values >= VALUES_INTERVAL
	// What the world shows goes to the editor beside the document's values, so it is taken before the lift.
	shown: Shown
	if values_due {
		shown = capture_shown(e, w, frame)
	}
	looks := capture_looks(e, w)
	lift_overrides(e, w)
	defer lay_overrides(e, w)
	for m in incoming {
		message, ok := link.decode_message(m.kind, m.payload, frame)
		if !ok {
			log.warnf("editor: cannot decode a message of kind %d", m.kind)
			continue
		}
		#partial switch v in message {
		case link.Watch_Entity:
			watch(e, ecs.Entity(v.entity))
		case link.Unwatch_Entity:
			unwatch(e, ecs.Entity(v.entity))
		case link.Load_Scene:
			end_overrides(e, w, link.Override_End_Reason.Scene_Loaded)
			problems := make([dynamic]link.Edit_Problem, frame)
			load_scenes(e, w, scripts, v, &problems)
			e.loads += 1
			// The old world's behaviours end without callbacks, as the editor's scene replaces it, and in Edit, the world
			// is the editor's document, which the edit-mode behaviours edit from now on.
			if scripts != nil {
				script.settle(scripts)
			}
			e.session.mirror = nil
			if e.session.mode == .Edit {
				e.session.mirror = Mirror {
					scene = v.ticket,
				}
			}
			if scripts != nil {
				script.set_callbacks(scripts, callbacks_between_frames(e))
			}
			link.write_message(out, edit_problems(problems[:], true))
			// Every entity is new, so the editor gets a snapshot, and its watches, its selection and what it hides are
			// of entities that are gone.
			clear(&e.session.watched)
			clear(&e.session.view.selection)
			clear(&e.session.view.hidden)
			snapshot = true
		case link.Add_Scene:
			problems := make([dynamic]link.Edit_Problem, frame)
			add_editor_scene(e, w, scripts, v.scene, &problems)
			if scripts != nil {
				script.settle(scripts)
			}
			follow_scene_ticket(e, v.ticket)
			// The other scenes' problems stay, so these are not a snapshot.
			if len(problems) > 0 {
				link.write_message(out, edit_problems(problems[:], false))
			}
			rescan = true
		case link.Remove_Scene:
			// The game forgets the scene's entities after the poll, and their behaviours end as a game's own unload
			// ends them, with the callbacks of the mode.
			if remove_editor_scene(e, w, v.scene) {
				despawned = true
				forget_dead(w, &e.session.view.selection)
				forget_dead(w, &e.session.view.hidden)
			}
			follow_scene_ticket(e, v.ticket)
			rescan = true
		case link.Apply_Operations:
			problems := make([dynamic]link.Edit_Problem, frame)
			if apply_operations(e, w, scripts, v.operations, &problems) {
				// A part that Set_Sublevel emptied unloaded, with what its entities owned.
				despawned = true
				forget_dead(w, &e.session.view.selection)
				forget_dead(w, &e.session.view.hidden)
				rescan = true
			}
			// The editor edited, so behaviours whose edits it refused may try again.
			if m, mirrors := &e.session.mirror.?; mirrors {
				if _, refused := m.batch.(Batch_Refused); refused {
					m.batch = nil
				}
			}
			if len(problems) > 0 {
				link.write_message(out, edit_problems(problems[:], false))
			}
		case link.Set_Mode:
			started := e.session.mode == .Edit && v.mode == .Play
			// Play and Pause start from the document's world, and Edit waits for the editor's scene, which ends them too.
			if end_overrides(e, w, link.Override_End_Reason.Mode) {
				despawned = true
				forget_dead(w, &e.session.view.selection)
				forget_dead(w, &e.session.view.hidden)
			}
			e.session.mode = v.mode
			if v.mode != .Paused {
				e.session.steps = 0
			}
			// The world runs, or stops as it is, and the editor sends its scene again before Edit edits it. The edits that
			// follow in this poll run no script code outside Play, but the edit-mode behaviours' in Edit.
			e.session.mirror = nil
			if scripts != nil {
				script.set_callbacks(scripts, callbacks_between_frames(e))
				// Each Play from Edit draws the same numbers (see docs/scripting/api.md#random).
				if started {
					script.restart_random(scripts)
				}
			}
		case link.Run_Game_Command:
			run_command(e, w, scripts, user, v.id, out, frame)
		case link.Capture_Reflection_Probes:
			capture_probes(e, v.entities)
		case link.Sky_Sun_Request:
			answer := link.Sky_Sun {
				state = .No_Texture_Sky,
			}
			if e.renderer != nil {
				direction, state := render.sky_texture_sun(e.renderer)
				answer = {
					state     = link.Sky_Sun_State(state),
					direction = direction,
				}
			}
			link.write_message(out, answer)
		case link.Behaviour_Operations_Answer:
			answer_behaviour_operations(e, v)
		case link.Step_Frame:
			if e.session.mode == .Paused {
				e.session.steps += 1
			}
		case link.Begin_Override:
			begin_override(e, v.override)
		case link.Override_Frame:
			if write_override(e, w, scripts, v) {
				despawned = true
				forget_dead(w, &e.session.view.selection)
				forget_dead(w, &e.session.view.hidden)
			}
		case link.Release_Override:
			if release_override(e, w, v.override) {
				despawned = true
				forget_dead(w, &e.session.view.selection)
				forget_dead(w, &e.session.view.hidden)
			}
		case link.Cutscene_Preview_Open,
		     link.Cutscene_Preview_Time,
		     link.Cutscene_Preview_Play,
		     link.Cutscene_Preview_Settings,
		     link.Cutscene_Preview_Children,
		     link.Cutscene_Preview_Values,
		     link.Cutscene_Preview_Close:
			if _, gone := handle_cutscene_preview_message(e, w, scripts, message); gone {
				despawned = true
				forget_dead(w, &e.session.view.selection)
				forget_dead(w, &e.session.view.hidden)
			}
		case:
			if !handle_thumbnail_message(e, message) &&
			   !handle_preview_message(e, message) &&
			   !handle_viewport_message(e, message) &&
			   !handle_live_message(e, message) &&
			   !handle_live_texture_message(e, message) {
				log.warnf("editor: the game does not handle %v", message)
			}
		}
	}
	// What the edit-mode behaviours did in this poll's edits goes to the editor too, after what the frame sent.
	send_behaviour_edits(e, w, scripts)
	append(out, ..e.session.outbox[:])
	clear(&e.session.outbox)
	finish_pick(e, w, out, frame)
	send_preview_targets(e, out)
	send_viewport_targets(e, out)
	send_thumbnail_failed(e, out)
	s := &e.session
	if !s.types_sent {
		link.write_message(out, component_types(w, frame))
		link.write_message(out, command_infos(e, frame))
		link.write_message(out, agent_actions(e, frame))
		s.types_sent = true
	}
	// A snapshot makes the editor forget which entities overrides write, so it hears them again.
	if snapshot {
		s.overrides.entities_sent = 0
	}
	if snapshot || rescan || now - s.last_scan >= SCAN_INTERVAL {
		s.last_scan = now
		if message, changed := scan(e, w, snapshot, frame); changed {
			link.write_message(out, message)
		}
	}
	if values_due {
		s.last_values = now
		send_values(e, w, scripts, shown, out, frame)
		send_animators(e, w, out, frame)
		send_agents(e, out, frame)
		send_reflection_probes(e, w, out)
		send_preview_views(e, out, frame)
		send_ui_layouts(e, out, frame)
	}
	send_overridden_entities(e, w, out, frame)
	send_cutscene_preview_tick(e, out)
	send_viewport_looks(e, looks, out)
	send_streamed_scenes(e, out)
	if now - s.last_stats >= STATS_INTERVAL {
		stats_interval := now - s.last_stats
		s.last_stats = now
		stats := game_stats(w, scripts, frame)
		if e.views != nil {
			stats.camera_entries = u32(camera.held_count(e.views))
		}
		if e.streaming != nil {
			work := streaming.stats(e.streaming)
			stats.scenes_loading = u32(work.scenes_loading)
			stats.scene_entities_spawned = u32(work.entities_spawned)
			stats.scene_entities_filled = u32(work.entities_filled)
		}
		if e.renderer != nil {
			c := render.cull_stats(e.renderer)
			stats.early_items, stats.late_items, stats.hidden_items =
				c.early_items, c.late_items, c.hidden_items
			stats.early_instances, stats.late_instances, stats.hidden_instances =
				c.early_instances, c.late_instances, c.hidden_instances
			stats.hierarchy_meshlets, stats.selected_meshlets =
				c.hierarchy_meshlets, c.selected_meshlets
			sh := render.shading_stats(e.renderer)
			stats.forward_quads, stats.forward_pixels = sh.forward_quads, sh.forward_pixels
			vs := render.virtual_shadow_stats(e.renderer)
			stats.virtual_pages_requested, stats.virtual_pages_allocated =
				vs.requested, vs.allocated
			stats.virtual_pages_missed, stats.virtual_pages_capacity = vs.missed, vs.capacity
			stats.virtual_pages_cached, stats.virtual_pages_drawn = vs.cached, vs.drawn
			stats.virtual_pages_evicted, stats.virtual_pages_resident = vs.evicted, vs.resident
			streamed := render.virtual_stream_stats(e.renderer)
			stats.virtual_pages_streamed, stats.virtual_pages_waiting =
				streamed.dropped, streamed.waiting
			stats.virtual_pages_invalidated = vs.invalidated
			stats.virtual_levels_invalidated = render.virtual_drop_stats(e.renderer).levels
			ac := render.atlas_cache_stats(e.renderer)
			stats.atlas_cache_lights, stats.atlas_cache_copied = ac.lights, ac.copied
			stats.atlas_cache_drawn, stats.atlas_cache_refreshed = ac.drawn, ac.refreshed
			pages := render.mesh_stream_stats(&e.renderer.residency)
			stats.mesh_pages_resident, stats.mesh_pages_capacity =
				pages.resident_pages, pages.capacity_pages
			stats.mesh_pages_pending = pages.pending_requests
			// A rate over the interval, as a frame's bytes are 0 in most frames.
			if pages.streamed_total >= s.pages_streamed && stats_interval > 0 {
				stats.mesh_pages_streamed_bytes = u32(
					min(
						f64(pages.streamed_total - s.pages_streamed) / stats_interval,
						f64(max(u32)),
					),
				)
			}
			s.pages_streamed = pages.streamed_total
			textures := render.texture_stream_stats(&e.renderer.residency)
			stats.texture_pages_resident, stats.texture_pages_capacity =
				textures.resident_pages, textures.capacity_pages
			stats.texture_pages_pending = textures.pending_pages
			if textures.streamed_total >= s.texture_bytes && stats_interval > 0 {
				stats.texture_streamed_bytes = u32(
					min(
						f64(textures.streamed_total - s.texture_bytes) / stats_interval,
						f64(max(u32)),
					),
				)
			}
			s.texture_bytes = textures.streamed_total
			stats.texture_pool_bytes = textures.pool_bytes
			stats.video_memory_used, stats.video_memory_budget =
				textures.video_used, textures.video_budget
			residency := render.residency_stats(&e.renderer.residency)
			stats.assets_resident = u32(residency.entries)
			stats.assets_unloaded = u32(min(residency.evicted, u64(max(u32))))
			stats.texture_mips_streamed = u32(min(residency.mip_streams, u64(max(u32))))
			stats.resident_bytes = residency.resident_bytes
			gi := render.gi_split_stats(e.renderer)
			cascades := make([]link.Gi_Cascade_Stats, gi.count, frame)
			for &cascade, k in cascades {
				cascade = {
					active  = gi.cascades[k].active,
					slots   = gi.cascades[k].slots,
					dropped = gi.cascades[k].dropped,
				}
			}
			stats.gi_cascades = cascades
			rp := render.reflection_probe_stats(e.renderer)
			stats.reflection_probes, stats.reflection_probe_slots = rp.probes, rp.slots
			stats.reflection_probe_capacity, stats.reflection_probe_faces = rp.capacity, rp.faces
			stats.reflection_memory = render.reflection_memory(e.renderer)
		}
		link.write_message(out, stats)
	}
	return
}

@(private)
game_stats :: proc(
	w: ^ecs.World,
	scripts: ^script.Runtime,
	allocator: runtime.Allocator,
) -> link.Game_Stats {
	stats := link.Game_Stats {
		entities   = ecs.entity_count(w),
		archetypes = w.archetype_count,
	}
	if scripts != nil {
		total, modules := script.memory(scripts, allocator)
		stats.behaviours = u32(script.behaviour_count(scripts))
		stats.script_bytes = u64(total)
		list := make([]link.Script_Module_Memory, len(modules), allocator)
		for m, i in modules {
			list[i] = {
				name  = m.name,
				bytes = u64(m.bytes),
			}
		}
		stats.modules = list
		contexts := &scripts.input_actions.contexts
		pushes := make([]link.Input_Context_Stats, contexts.push_count, allocator)
		for i in 0 ..< contexts.push_count {
			p := &contexts.pushes[contexts.push_count - 1 - i]
			pushes[i] = {
				name    = core.input_context_name(contexts, int(p.ctx)),
				players = transmute(u8)p.players,
				pusher  = core.input_context_pusher(p),
			}
		}
		stats.input_contexts = pushes
	}
	return stats
}

@(private)
watch :: proc(e: ^Editor, entity: ecs.Entity) {
	for w in e.session.watched {
		if w.entity == entity {
			return
		}
	}
	if len(e.session.watched) == MAX_WATCHED {
		log.warnf(
			"editor: the editor watches more than %d entities, so %v is not watched",
			MAX_WATCHED,
			entity,
		)
		return
	}
	append(&e.session.watched, Watched{entity = entity})
}

@(private)
unwatch :: proc(e: ^Editor, entity: ecs.Entity) {
	for w, i in e.session.watched {
		if w.entity == entity {
			ordered_remove(&e.session.watched, i)
			return
		}
	}
}

// follow_scene_ticket gives the mirror of the edit-mode behaviours the ticket of the editor's world after a scene
// opened or closed beside the others. Their edits are of the same world still, so what the mirror waits for stays: an
// answer to a batch with the old ticket is a refusal, and the behaviours try again.
@(private)
follow_scene_ticket :: proc(e: ^Editor, ticket: u64) {
	if m, mirrors := &e.session.mirror.?; mirrors {
		m.scene = ticket
	}
}

// forget_dead drops the entities that are no longer alive from a list, in place, in order.
@(private)
forget_dead :: proc(w: ^ecs.World, entities: ^[dynamic]ecs.Entity) {
	kept := 0
	for entity in entities {
		if ecs.is_alive(w, entity) {
			entities[kept] = entity
			kept += 1
		}
	}
	resize(entities, kept)
}

// scan compares the world with what the editor knows. With full, it describes every entity in a snapshot. Otherwise
// it describes the changes in a delta, and reports whether there are any.
//
// What the editor knows of an entity changes only with its row, which moves with its archetype and its activity, or
// with its Parent or its Name, so a delta visits only the chunks where those changed since the last scan.
@(private)
scan :: proc(
	e: ^Editor,
	w: ^ecs.World,
	full: bool,
	allocator: runtime.Allocator,
) -> (
	message: link.Message,
	changed: bool,
) {
	profile.scope_text(&e.platform.profile, full ? "Editor snapshot" : "Editor delta", .Editor)
	since := full ? 0 : e.session.scan_version
	e.session.scan_version = ecs.take_version(w)
	infos := make([dynamic]link.Entity_Info, allocator)
	destroyed := make([dynamic]u64, allocator)
	// First, so that an entity in the slot of one that died finds the slot empty.
	if full || e.session.despawned != w.despawned {
		e.session.despawned = w.despawned
		for &k in e.session.known {
			if k.entity != 0 && !ecs.is_alive(w, k.entity) {
				append(&destroyed, u64(k.entity))
				k = {}
			}
		}
	}
	watched := [?]ecs.Component_Id{ecs.PARENT_ID, ecs.NAME_ID}
	it := ecs.world_iter_changed(w, since, watched[:])
	for entity, archetype, components in ecs.world_next(&it) {
		index := int(ecs.entity_index(entity))
		if index >= len(e.session.known) {
			resize(&e.session.known, index + 1)
		}
		parent: ecs.Entity
		if p := (^ecs.Parent)(ecs.get_raw(w, entity, ecs.PARENT_ID)); p != nil {
			parent = p.entity
		}
		_, inactive := find(components, ecs.INACTIVE_ID)
		name := ecs.name_of(w, entity, allocator)
		now := Known{entity, archetype, parent, !inactive, hash.fnv64a(transmute([]byte)name)}
		k := &e.session.known[index]
		if full ||
		   k.entity != now.entity ||
		   k.archetype != now.archetype ||
		   k.parent != now.parent ||
		   k.active != now.active ||
		   k.name != now.name {
			ids := make([]u64, len(components), allocator)
			for id, i in components {
				ids[i] = u64(id)
			}
			key := scene.key_of(w, entity)
			append(
				&infos,
				link.Entity_Info {
					entity = u64(entity),
					name = strings.clone(name, allocator),
					scene_id = key.id,
					scene = key.scene,
					parent = u64(parent),
					active = now.active,
					components = ids,
				},
			)
		}
		k^ = now
	}
	if full {
		return link.Entity_Snapshot{entities = infos[:]}, true
	}
	return link.Entity_Delta{changed = infos[:], destroyed = destroyed[:]},
		len(infos) > 0 || len(destroyed) > 0
}

// send_values sends the values of each watched entity whose values changed since the editor last got them. A watched
// entity that died is no longer watched; the delta tells the editor that it is gone.
@(private)
send_values :: proc(
	e: ^Editor,
	w: ^ecs.World,
	scripts: ^script.Runtime,
	shown: Shown,
	out: ^[dynamic]byte,
	allocator: runtime.Allocator,
) {
	for i := 0; i < len(e.session.watched); {
		watched := &e.session.watched[i]
		if !ecs.is_alive(w, watched.entity) {
			ordered_remove(&e.session.watched, i)
			continue
		}
		i += 1
		held := held_fields(e, w, watched.entity, allocator)
		message := link.Entity_Values {
			entity     = u64(watched.entity),
			components = component_values(w, watched.entity, allocator),
			behaviours = behaviour_values(scripts, watched.entity, allocator),
			held       = held,
		}
		if len(held) > 0 {
			for s in shown.entities {
				if s.entity == watched.entity {
					message.shown = s.values
					message.shown_preview = shown.preview
				}
			}
		}
		encoded := make([dynamic]byte, allocator)
		link.write_message(&encoded, message)
		// A hash of 0 means "never sent", so a real 0 counts as 1.
		h := max(hash.fnv64a(encoded[link.HEADER_SIZE:]), 1)
		if h != watched.sent {
			watched.sent = h
			append(out, ..encoded[:])
		}
	}
}

@(private)
behaviour_values :: proc(
	scripts: ^script.Runtime,
	entity: ecs.Entity,
	allocator: runtime.Allocator,
) -> []link.Behaviour_Value {
	if scripts == nil || scripts.L == nil {
		return nil
	}
	snapshots := script.inspect(scripts, entity, allocator)
	values := make([]link.Behaviour_Value, len(snapshots), allocator)
	for s, i in snapshots {
		fields := make([]link.Behaviour_Field, len(s.fields), allocator)
		for f, j in s.fields {
			fields[j] = {
				name       = f.name,
				kind       = link.Behaviour_Field_Kind(f.kind),
				number     = f.number,
				boolean    = f.boolean,
				text       = f.text,
				vector     = f.vector,
				entity     = u64(f.entity),
				asset      = ([16]u8)(f.asset),
				asset_kind = f.asset_kind,
			}
		}
		values[i] = {
			class   = s.class,
			script  = ([16]u8)(s.script),
			enabled = s.enabled,
			fields  = fields,
		}
	}
	return values
}

@(private)
find :: proc(ids: []ecs.Component_Id, id: ecs.Component_Id) -> (int, bool) {
	for x, i in ids {
		if x == id {
			return i, true
		}
	}
	return -1, false
}

#assert(int(script.Behaviour_Field_Kind.Entity) == int(link.Behaviour_Field_Kind.Entity))
#assert(int(script.Behaviour_Field_Kind.Asset) == int(link.Behaviour_Field_Kind.Asset))
#assert(
	len(render.Sky_Sun_State) == len(link.Sky_Sun_State) &&
	int(render.Sky_Sun_State.No_Sun) == int(link.Sky_Sun_State.No_Sun),
)
#assert(int(format.Scene_Value_Kind.Entity) == int(link.Scene_Value_Kind.Entity))
#assert(int(format.Scene_Value_Kind.Asset) == int(link.Scene_Value_Kind.Asset))
