// Package editor is the game's side of the editor link (see docs/editor.md#world): the component types, the entity
// list and its deltas, and the values of the entities that the editor watches. The game keeps an Editor in its
// Game_State and calls poll from Game_API.editor_poll.
package editor

import "base:runtime"
import "core:hash"
import "core:log"
import "core:strings"

import "cinnabar:core"
import "cinnabar:engine/ecs"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/scene"
import "cinnabar:engine/script"

// The entity list changes at most this often in the editor.
SCAN_INTERVAL :: 0.1
// Watched values change at most this often in the editor.
VALUES_INTERVAL :: 0.05
// Game_Stats go out this often.
STATS_INTERVAL :: 0.25
MAX_WATCHED :: 64

// Editor is what the editor has been told. It lives in Game_State. Its arrays use the host's heap, so they survive
// a code reload, and a soft restart starts a new one, which sends everything again.
Editor :: struct {
	platform:    ^core.Platform_API,
	// The connection that this state is for. Another one means a new editor, which gets everything.
	connection:  u64,
	types_sent:  bool,
	// What the editor knows of each entity slot, by entity index.
	known:       [dynamic]Known,
	scan:        u32,
	watched:     [dynamic]Watched,
	// The entity of each scene ID, for the editor's operations (see find_scene_entity).
	by_scene_id: map[u64]ecs.Entity,
	viewport:    Viewport,
	// The mode that the editor set (see modes.odin).
	mode:        link.Editor_Mode,
	free_camera: bool,
	// Step_Frame messages that wait for a paused frame.
	steps:       int,
	last_scan:   f64,
	last_values: f64,
	last_stats:  f64,
	// The game's commands (see commands.odin). Registrations: reload clears them.
	commands:    [dynamic]Command,
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
	// The scan that last saw the entity.
	seen:      u32,
}

@(private)
Watched :: struct {
	entity: ecs.Entity,
	// The hash of the values that the editor last got, or 0 to send them at the next chance.
	sent:   u64,
}

init :: proc(e: ^Editor, platform: ^core.Platform_API) {
	e^ = {
		platform    = platform,
		known       = make([dynamic]Known, platform.heap_allocator),
		watched     = make([dynamic]Watched, platform.heap_allocator),
		by_scene_id = make(map[u64]ecs.Entity, platform.heap_allocator),
		commands = make([dynamic]Command, platform.heap_allocator),
		viewport = {
			selection = make([dynamic]ecs.Entity, platform.heap_allocator),
			hidden = make([dynamic]ecs.Entity, platform.heap_allocator),
			picks = make([dynamic]link.Pick_Request, platform.heap_allocator),
		},
	}
}

// reload sends the types again after a code reload: the new DLL may describe them differently. It forgets the commands,
// whose procedures are the old DLL's, so register them again after it.
reload :: proc(e: ^Editor, platform: ^core.Platform_API) {
	e.platform = platform
	e.types_sent = false
	clear(&e.commands)
	reload_viewport_gpu(e)
}

destroy :: proc(e: ^Editor) {
	delete(e.known)
	delete(e.watched)
	delete(e.by_scene_id)
	delete(e.commands)
	delete(e.viewport.selection)
	delete(e.viewport.hidden)
	delete(e.viewport.picks)
	if e.viewport.gpu_ready {
		destroy_viewport_gpu(e)
	}
	e^ = {}
}

// poll handles the editor's messages and appends the game's messages to out. Call it between frames, outside the
// script phase. user is the game's own data, which its commands get.
poll :: proc(e: ^Editor, w: ^ecs.World, scripts: ^script.Runtime, connection: u64, incoming: []core.Editor_Message, out: ^[dynamic]byte, user: rawptr = nil) {
	snapshot := false
	if connection != e.connection {
		e.connection = connection
		e.types_sent = false
		clear(&e.known)
		clear(&e.watched)
		reset_viewport(e)
		e.mode, e.free_camera, e.steps = .Edit, false, 0
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
			clear(&e.watched)
			clear(&e.viewport.selection)
			clear(&e.viewport.hidden)
			snapshot = true
		case link.Apply_Operations:
			problems := make([dynamic]scene.Problem, frame)
			apply_operations(e, w, scripts, v.operations, &problems)
			if len(problems) > 0 {
				link.write_message(out, edit_problems(problems[:], false, frame))
			}
		case link.Set_Mode:
			e.mode, e.free_camera = v.mode, v.free_camera
			if v.mode != .Paused {
				e.steps = 0
			}
			// The edits that follow in this poll run no script code outside Play.
			if scripts != nil {
				script.set_quiet(scripts, v.mode != .Play)
			}
		case link.Run_Game_Command:
			run_command(e, w, scripts, user, v.id, out, frame)
		case link.Step_Frame:
			if e.mode == .Paused {
				e.steps += 1
			}
		case:
			if !handle_viewport_message(e, message) {
				log.warnf("editor: the game does not handle %v", message)
			}
		}
	}
	finish_pick(e, w, out, frame)
	if !e.types_sent {
		link.write_message(out, component_types(w, frame))
		link.write_message(out, command_infos(e, frame))
		e.types_sent = true
	}
	now := e.platform.time_seconds()
	if snapshot || now - e.last_scan >= SCAN_INTERVAL {
		e.last_scan = now
		if message, changed := scan(e, w, snapshot, frame); changed {
			link.write_message(out, message)
		}
	}
	if now - e.last_values >= VALUES_INTERVAL {
		e.last_values = now
		send_values(e, w, scripts, out, frame)
	}
	if now - e.last_stats >= STATS_INTERVAL {
		e.last_stats = now
		link.write_message(out, game_stats(w, scripts, frame))
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
	for w in e.watched {
		if w.entity == entity {
			return
		}
	}
	if len(e.watched) == MAX_WATCHED {
		log.warnf("editor: the editor watches more than %d entities, so %v is not watched", MAX_WATCHED, entity)
		return
	}
	append(&e.watched, Watched{entity = entity})
}

@(private)
unwatch :: proc(e: ^Editor, entity: ecs.Entity) {
	for w, i in e.watched {
		if w.entity == entity {
			ordered_remove(&e.watched, i)
			return
		}
	}
}

// scan compares the world with what the editor knows. With full, it describes every entity in a snapshot. Otherwise
// it describes the changes in a delta, and reports whether there are any.
@(private)
scan :: proc(e: ^Editor, w: ^ecs.World, full: bool, allocator: runtime.Allocator) -> (message: link.Message, changed: bool) {
	e.scan += 1
	infos := make([dynamic]link.Entity_Info, allocator)
	destroyed := make([dynamic]u64, allocator)
	it := ecs.world_iter(w)
	for entity, archetype, components in ecs.world_next(&it) {
		index := int(ecs.entity_index(entity))
		if index >= len(e.known) {
			resize(&e.known, index + 1)
		}
		parent: ecs.Entity
		if p := (^ecs.Parent)(ecs.get_raw(w, entity, ecs.PARENT_ID)); p != nil {
			parent = p.entity
		}
		_, inactive := find(components, ecs.INACTIVE_ID)
		name := ecs.name_of(w, entity)
		now := Known{entity, archetype, parent, !inactive, hash.fnv64a(transmute([]byte)name), e.scan}
		k := &e.known[index]
		// A new entity in the slot of one that the editor knows: that one died between two scans.
		if k.entity != 0 && k.entity != entity && !full {
			append(&destroyed, u64(k.entity))
		}
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
	for &k in e.known {
		if k.entity != 0 && k.seen != e.scan {
			append(&destroyed, u64(k.entity))
			k = {}
		}
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
	for i := 0; i < len(e.watched); {
		watched := &e.watched[i]
		if !ecs.is_alive(w, watched.entity) {
			ordered_remove(&e.watched, i)
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
				name    = f.name,
				kind    = link.Behaviour_Field_Kind(f.kind),
				number  = f.number,
				boolean = f.boolean,
				text    = f.text,
				vector  = f.vector,
				entity  = u64(f.entity),
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
#assert(int(format.Scene_Value_Kind.Entity) == int(link.Scene_Value_Kind.Entity))
