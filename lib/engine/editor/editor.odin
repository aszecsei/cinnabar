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
import "cinnabar:engine/asset"
import "cinnabar:engine/ecs"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/render"
import "cinnabar:engine/scene"
import "cinnabar:engine/script"
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
	// The entity of each scene ID, for the editor's operations (see find_scene_entity). It follows the world, not the
	// session.
	by_scene_id: map[u64]ecs.Entity,
	// The viewport tools' GPU objects (see viewport.odin).
	viewport:    Viewport,
	// The game's commands (see commands.odin). Registrations: reload clears them.
	commands:    [dynamic]Command,
	// The UI documents that previews show, each in a slot of its own, apart from the game's UI (see ui_preview.odin).
	ui:          ui.State,
	// The renderer's residency, which draws the live meshes, in Game_State, or nil without a renderer.
	residency:   ^render.Residency,
	// The renderer, which answers where the texture sky's sun is.
	renderer:    ^render.Renderer,
}

// Session is the state of one editor connection: what the editor has sent the game, and what the game has sent the
// editor. begin_session starts one and end_session ends it, for each connection and for none (connection 0), so state
// that a new editor must not inherit belongs here, and end_session frees it (see
// docs/overview/conventions.md#state-with-a-lifecycle).
Session :: struct {
	// The connection that this session is for. Another one means a new editor, which gets everything.
	connection:   u64,
	types_sent:   bool,
	// What the editor knows of each entity slot, by entity index.
	known:        [dynamic]Known,
	// The version that the last scan took, and how many entities the world had despawned at it.
	scan_version: u64,
	despawned:    u64,
	watched:      [dynamic]Watched,
	// The editor's camera, selection and gizmo, and its picks (see viewport.odin).
	view:         View,
	// The mode that the editor set (see modes.odin).
	mode:         link.Editor_Mode,
	free_camera:  bool,
	// Step_Frame messages that wait for a paused frame.
	steps:        int,
	last_scan:    f64,
	last_values:  f64,
	last_stats:   f64,
	// The material editor's previews, by ID, and the one to draw next (see preview.odin).
	previews:     [MAX_PREVIEWS]Preview,
	next_preview: int,
	thumbnail:    Thumbnail,
	// The meshes that the editor edits, drawn from memory in place of their assets (see live.odin).
	live_meshes:  map[format.Guid]Live_Mesh,
	// What mesh mode draws over the live meshes (see mesh_overlay.odin), in the host's heap.
	mesh_overlay: link.Mesh_Overlay,
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
	// The same for its reflection probe's view, 0 for None (see reflection_probes.odin).
	probe_sent:    Maybe(u64),
}

// init starts the editor's game side. The viewport tools load their shaders from assets, which must outlive the
// editor; without them (nil), the tools stay off. The live meshes draw through residency, the renderer's, which must
// outlive the editor too; without it (nil), they are kept and baked but not drawn. The renderer answers for the sky
// (see Sky_Sun_Request); without it (nil), the sky has no sun.
init :: proc(e: ^Editor, platform: ^core.Platform_API, assets: ^asset.Assets, residency: ^render.Residency = nil, renderer: ^render.Renderer = nil) {
	e^ = {
		platform    = platform,
		assets      = assets,
		residency   = residency,
		renderer    = renderer,
		by_scene_id = make(map[u64]ecs.Entity, platform.heap_allocator),
		commands    = make([dynamic]Command, platform.heap_allocator),
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
		connection  = connection,
		known       = make([dynamic]Known, heap),
		watched     = make([dynamic]Watched, heap),
		live_meshes = make(map[format.Guid]Live_Mesh, heap),
		view = {
			selection = make([dynamic]ecs.Entity, heap),
			hidden    = make([dynamic]ecs.Entity, heap),
			picks     = make([dynamic]link.Pick_Request, heap),
		},
	}
}

// end_session ends the session: it closes the previews and the thumbnail, releases the live meshes and the mesh
// overlay, frees the session's arrays, and zeroes it. A pick that the GPU still runs comes back with an old ticket, so
// nothing reads it.
@(private)
end_session :: proc(e: ^Editor) {
	s := &e.session
	release_live_meshes(e)
	close_previews(e)
	delete(s.live_meshes)
	delete(s.known)
	delete(s.watched)
	delete(s.view.selection)
	delete(s.view.hidden)
	delete(s.view.handles)
	delete(s.view.picks)
	s^ = {}
}

// reload sends the types again after a code reload: the new DLL may describe them differently. It forgets the commands,
// whose procedures are the old DLL's, so register them again after it.
reload :: proc(e: ^Editor, platform: ^core.Platform_API) {
	e.platform = platform
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
	delete(e.by_scene_id)
	delete(e.commands)
	if e.ui.platform != nil {
		ui.destroy(&e.ui)
	}
	if e.viewport.gpu_ready {
		destroy_viewport_gpu(e)
	}
	e^ = {}
}

// poll handles the editor's messages and appends the game's messages to out. Call it between frames, outside the
// script phase. user is the game's own data, which its commands get.
poll :: proc(e: ^Editor, w: ^ecs.World, scripts: ^script.Runtime, connection: u64, incoming: []core.Editor_Message, out: ^[dynamic]byte, user: rawptr = nil) {
	profile.scope_text(&e.platform.profile, "Editor poll", .Editor)
	snapshot := false
	if connection != e.session.connection {
		end_session(e)
		begin_session(e, connection)
		// A new editor is in Edit, so its first scene replaces the world without the old behaviours' callbacks.
		if scripts != nil {
			script.set_quiet(scripts, connection != 0)
		}
		snapshot = connection != 0
	}
	if connection == 0 {
		return
	}
	frame := e.platform.frame_allocator
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
			problems := make([dynamic]scene.Problem, frame)
			scene.load(w, scripts, scene_of(v, frame), &e.by_scene_id, &problems)
			link.write_message(out, edit_problems(problems[:], true, frame))
			// Every entity is new, so the editor gets a snapshot, and its watches, its selection and what it hides are
			// of entities that are gone.
			clear(&e.session.watched)
			clear(&e.session.view.selection)
			clear(&e.session.view.hidden)
			snapshot = true
		case link.Apply_Operations:
			problems := make([dynamic]scene.Problem, frame)
			apply_operations(e, w, scripts, v.operations, &problems)
			if len(problems) > 0 {
				link.write_message(out, edit_problems(problems[:], false, frame))
			}
		case link.Set_Mode:
			e.session.mode, e.session.free_camera = v.mode, v.free_camera
			if v.mode != .Paused {
				e.session.steps = 0
			}
			// The edits that follow in this poll run no script code outside Play.
			if scripts != nil {
				script.set_quiet(scripts, v.mode != .Play)
			}
		case link.Run_Game_Command:
			run_command(e, w, scripts, user, v.id, out, frame)
		case link.Capture_Reflection_Probes:
			capture_probes(e, v.entities)
		case link.Sky_Sun_Request:
			answer := link.Sky_Sun{state = .No_Texture_Sky}
			if e.renderer != nil {
				direction, state := render.sky_texture_sun(e.renderer)
				answer = {state = link.Sky_Sun_State(state), direction = direction}
			}
			link.write_message(out, answer)
		case link.Step_Frame:
			if e.session.mode == .Paused {
				e.session.steps += 1
			}
		case:
			if !handle_thumbnail_message(e, message) && !handle_preview_message(e, message) && !handle_viewport_message(e, message) && !handle_live_message(e, message) {
				log.warnf("editor: the game does not handle %v", message)
			}
		}
	}
	finish_pick(e, w, out, frame)
	send_preview_targets(e, out)
	send_thumbnail_failed(e, out)
	s := &e.session
	if !s.types_sent {
		link.write_message(out, component_types(w, frame))
		link.write_message(out, command_infos(e, frame))
		s.types_sent = true
	}
	now := e.platform.time_seconds()
	if snapshot || now - s.last_scan >= SCAN_INTERVAL {
		s.last_scan = now
		if message, changed := scan(e, w, snapshot, frame); changed {
			link.write_message(out, message)
		}
	}
	if now - s.last_values >= VALUES_INTERVAL {
		s.last_values = now
		send_values(e, w, scripts, out, frame)
		send_animators(e, w, out, frame)
		send_reflection_probes(e, w, out)
		send_preview_views(e, out, frame)
		send_ui_layouts(e, out, frame)
	}
	if now - s.last_stats >= STATS_INTERVAL {
		s.last_stats = now
		stats := game_stats(w, scripts, frame)
		if e.renderer != nil {
			c := render.cull_stats(e.renderer)
			stats.early_items, stats.late_items, stats.hidden_items = c.early_items, c.late_items, c.hidden_items
			stats.early_instances, stats.late_instances, stats.hidden_instances = c.early_instances, c.late_instances, c.hidden_instances
			stats.hierarchy_meshlets, stats.selected_meshlets = c.hierarchy_meshlets, c.selected_meshlets
			sh := render.shading_stats(e.renderer)
			stats.forward_quads, stats.forward_pixels = sh.forward_quads, sh.forward_pixels
			vs := render.virtual_shadow_stats(e.renderer)
			stats.virtual_pages_requested, stats.virtual_pages_allocated = vs.requested, vs.allocated
			stats.virtual_pages_missed, stats.virtual_pages_capacity = vs.missed, vs.capacity
			gi := render.gi_split_stats(e.renderer)
			cascades := make([]link.Gi_Cascade_Stats, gi.count, frame)
			for &cascade, k in cascades {
				cascade = {active = gi.cascades[k].active, slots = gi.cascades[k].slots, dropped = gi.cascades[k].dropped}
			}
			stats.gi_cascades = cascades
			rp := render.reflection_probe_stats(e.renderer)
			stats.reflection_probes, stats.reflection_probe_slots = rp.probes, rp.slots
			stats.reflection_probe_capacity, stats.reflection_probe_faces = rp.capacity, rp.faces
			stats.reflection_memory = render.reflection_memory(e.renderer)
		}
		link.write_message(out, stats)
	}
}

@(private)
game_stats :: proc(w: ^ecs.World, scripts: ^script.Runtime, allocator: runtime.Allocator) -> link.Game_Stats {
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
			list[i] = {name = m.name, bytes = u64(m.bytes)}
		}
		stats.modules = list
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
		log.warnf("editor: the editor watches more than %d entities, so %v is not watched", MAX_WATCHED, entity)
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

// scan compares the world with what the editor knows. With full, it describes every entity in a snapshot. Otherwise
// it describes the changes in a delta, and reports whether there are any.
//
// What the editor knows of an entity changes only with its row, which moves with its archetype and its activity, or
// with its Parent or its Name, so a delta visits only the chunks where those changed since the last scan.
@(private)
scan :: proc(e: ^Editor, w: ^ecs.World, full: bool, allocator: runtime.Allocator) -> (message: link.Message, changed: bool) {
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
		name := ecs.name_of(w, entity)
		now := Known{entity, archetype, parent, !inactive, hash.fnv64a(transmute([]byte)name)}
		k := &e.session.known[index]
		if full || k.entity != now.entity || k.archetype != now.archetype || k.parent != now.parent || k.active != now.active || k.name != now.name {
			ids := make([]u64, len(components), allocator)
			for id, i in components {
				ids[i] = u64(id)
			}
			scene_id: u64
			if s := (^scene.Scene_Entity)(ecs.get_raw(w, entity, scene.SCENE_ENTITY_ID)); s != nil {
				scene_id = s.id
			}
			append(
				&infos,
				link.Entity_Info {
					entity = u64(entity),
					name = strings.clone(name, allocator),
					scene_id = scene_id,
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
	return link.Entity_Delta{changed = infos[:], destroyed = destroyed[:]}, len(infos) > 0 || len(destroyed) > 0
}

// send_values sends the values of each watched entity whose values changed since the editor last got them. A watched
// entity that died is no longer watched; the delta tells the editor that it is gone.
@(private)
send_values :: proc(e: ^Editor, w: ^ecs.World, scripts: ^script.Runtime, out: ^[dynamic]byte, allocator: runtime.Allocator) {
	for i := 0; i < len(e.session.watched); {
		watched := &e.session.watched[i]
		if !ecs.is_alive(w, watched.entity) {
			ordered_remove(&e.session.watched, i)
			continue
		}
		i += 1
		components := ecs.entity_components(w, watched.entity)
		values := make([]link.Component_Value, len(components), allocator)
		for id, j in components {
			values[j].id = u64(id)
			info := ecs.registry_find(&w.registry, id)
			data := ecs.get_raw(w, watched.entity, id)
			if info != nil && data != nil {
				values[j].data = ([^]u8)(data)[:info.size]
			}
		}
		message := link.Entity_Values {
			entity     = u64(watched.entity),
			components = values,
			behaviours = behaviour_values(scripts, watched.entity, allocator),
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
behaviour_values :: proc(scripts: ^script.Runtime, entity: ecs.Entity, allocator: runtime.Allocator) -> []link.Behaviour_Value {
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
		values[i] = {class = s.class, script = ([16]u8)(s.script), enabled = s.enabled, fields = fields}
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
#assert(len(render.Sky_Sun_State) == len(link.Sky_Sun_State) && int(render.Sky_Sun_State.No_Sun) == int(link.Sky_Sun_State.No_Sun))
#assert(int(format.Scene_Value_Kind.Entity) == int(link.Scene_Value_Kind.Entity))
#assert(int(format.Scene_Value_Kind.Asset) == int(link.Scene_Value_Kind.Asset))
