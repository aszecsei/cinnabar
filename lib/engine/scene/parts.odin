package scene

import "core:log"
import "core:slice"
import "core:strings"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

// A scene with sublevels loads as its base and a part for each of its active sublevels. Each part is a row of the table
// with its own number, memory, ID map and links (see docs/world/sublevels.md#parts-are-scenes). The base's blob lists
// its sublevels. A part's blob does not know its base, so the part's row names it.

// Scene_Part is what a row is in its scene. The zero value is a base whose blob is still reading, so its sublevels are
// not known yet. Change it only with set_part.
Scene_Part :: union {
	Part_Base,
	Part_Of,
}

// Part_Base is a scene's base, or a scene without sublevels, with the sublevels that its blob lists, in its memory.
// failed has the sublevels whose part did not load. They are not tried again while they stay wanted.
Part_Base :: struct {
	sublevels: []format.Scene_Sublevel,
	failed:    bit_set[0 ..< format.MAX_SUBLEVELS],
}

// Part_Of is a sublevel's part of the base with the number.
Part_Of :: struct {
	base:     u32,
	sublevel: format.Sublevel_Name,
}

// Part_Event_Kind is what happened to a part.
Part_Event_Kind :: enum u8 {
	// The part began to load.
	Loading,
	// The part is ready.
	Ready,
	// The part left the table: it was unloaded, it failed, or its base unloaded.
	Unloaded,
	// The part did not load. When it was in the table, Unloaded follows.
	Failed,
}

// Part_Event is something that happened to a part of a base's sublevel. part is the part's number, or 0 for a part
// that did not begin to load.
Part_Event :: struct {
	kind:     Part_Event_Kind,
	base:     u32,
	part:     u32,
	sublevel: format.Sublevel_Name,
}

// part_events is what happened to the parts since clear_part_events, in order.
part_events :: proc(s: ^Scenes) -> []Part_Event {
	follow_level(s)
	return s.part_events[:]
}

// clear_part_events forgets the parts' events. The game calls it once a frame, before it changes the scenes.
clear_part_events :: proc(s: ^Scenes) {
	clear(&s.part_events)
}

// set_part is the one writer of a row's part. A row gets its part once, when it is added or when its blob is read,
// and keeps it. It gives false, and changes nothing, for any other change.
@(private)
set_part :: proc(row: ^Loaded_Scene, part: Scene_Part) -> bool {
	if row.part != nil || part == nil {
		log.errorf(
			"scene: the scene %d cannot change its part from %v to %v",
			row.number,
			row.part,
			part,
		)
		return false
	}
	row.part = part
	return true
}

// set_base makes the row with the number a base with the sublevels, which it copies into the scene's memory. A list
// longer than format.MAX_SUBLEVELS is cut.
@(private)
set_base :: proc(s: ^Scenes, number: u32, sublevels: []format.Scene_Sublevel) {
	index, found := find_loaded(s, number)
	if !found {
		return
	}
	list := sublevels
	if len(list) > format.MAX_SUBLEVELS {
		log.warnf(
			"scene: the scene %d has %d sublevels, and only the first %d load",
			number,
			len(list),
			format.MAX_SUBLEVELS,
		)
		list = list[:format.MAX_SUBLEVELS]
	}
	allocator := allocator_of(s, number)
	kept := make([]format.Scene_Sublevel, len(list), allocator)
	for sublevel, i in list {
		kept[i] = {
			name = strings.clone(sublevel.name, allocator),
			guid = sublevel.guid,
		}
	}
	set_part(&s.loaded[index], Part_Base{sublevels = kept})
}

// base_of is the base of the loaded scene with the number: the base that a part names, and the scene itself for any
// other scene. It is false for a scene that is not loaded.
base_of :: proc(s: ^Scenes, number: u32) -> (base: u32, ok: bool) {
	index := find_loaded(s, number) or_return
	if part, is_part := s.loaded[index].part.(Part_Of); is_part {
		return part.base, true
	}
	return number, true
}

// sublevel_of is the sublevel of a loaded part. It is false for any other scene.
sublevel_of :: proc(s: ^Scenes, number: u32) -> (sublevel: format.Sublevel_Name, ok: bool) {
	index := find_loaded(s, number) or_return
	part := s.loaded[index].part.(Part_Of) or_return
	return part.sublevel, true
}

// sublevels_of is the sublevels of a loaded base. It is false for a part, and for a base whose blob is still reading.
sublevels_of :: proc(s: ^Scenes, base: u32) -> (sublevels: []format.Scene_Sublevel, ok: bool) {
	index := find_loaded(s, base) or_return
	b := s.loaded[index].part.(Part_Base) or_return
	return b.sublevels, true
}

// part_number is the number of a base's part of a sublevel. It is false when that part is not loaded.
part_number :: proc(s: ^Scenes, base: u32, sublevel: string) -> (number: u32, ok: bool) {
	follow_level(s)
	for &row in s.loaded {
		if part, is_part := &row.part.(Part_Of); is_part && part.base == base {
			if format.sublevel_name_text(&part.sublevel) == sublevel {
				return row.number, true
			}
		}
	}
	return
}

// loading_with_parts is whether a base, or any of its parts, is not ready: whether the scene is still loading as one.
loading_with_parts :: proc(s: ^Scenes, base: u32) -> bool {
	follow_level(s)
	for row in s.loaded {
		owner := row.number
		if part, is_part := row.part.(Part_Of); is_part {
			owner = part.base
		}
		if _, ready := row.stage.(Scene_Ready); owner == base && !ready {
			return true
		}
	}
	return false
}

// part_count is how many parts of a base are in the table.
part_count :: proc(s: ^Scenes, base: u32) -> int {
	follow_level(s)
	count := 0
	for row in s.loaded {
		if part, is_part := row.part.(Part_Of); is_part && part.base == base {
			count += 1
		}
	}
	return count
}

// load_parts loads the parts of a base's sublevels that are in wanted, at once, as add_scene_asset does. So a scene
// that loaded at once arrives whole. A part that does not load is logged and skipped. It gives how many loaded.
load_parts :: proc(
	w: ^ecs.World,
	scripts: ^script.Runtime,
	s: ^Scenes,
	base: u32,
	wanted: []string,
) -> int {
	sublevels, known := sublevels_of(s, base)
	if !known {
		return 0
	}
	count := 0
	for sublevel, i in sublevels {
		if !slice.contains(wanted, sublevel.name) {
			continue
		}
		if _, loaded := part_number(s, base, sublevel.name); loaded {
			continue
		}
		of := Part_Of{base, format.sublevel_name(sublevel.name)}
		if number, ok := add_scene_asset_as(w, scripts, s, sublevel.guid, nil, of); ok {
			part_event(s, .Loading, of, number)
			part_event(s, .Ready, of, number)
			count += 1
		} else {
			mark_failed(s, base, i)
			part_event(s, .Failed, of, 0)
		}
	}
	return count
}

// update_parts makes the parts in the table the wanted ones. A part is wanted when its sublevel is in wanted and its
// base is in, and in no other case (see docs/world/sublevels.md#activation). It unloads the parts that are not wanted.
// It begins to load the wanted parts that are missing, which advance_loads moves on. It gives how many entities it
// despawned, so the caller has the systems that keep data by entity forget them. Call it between frames, outside the
// script phase.
update_parts :: proc(w: ^ecs.World, s: ^Scenes, wanted: []string) -> (despawned: int) {
	follow_level(s)
	for {
		doomed, found := u32(0), false
		for &row in s.loaded {
			part, is_part := &row.part.(Part_Of)
			if !is_part {
				continue
			}
			if !slice.contains(wanted, format.sublevel_name_text(&part.sublevel)) ||
			   !is_loaded(s, part.base) {
				doomed, found = row.number, true
				break
			}
		}
		if !found {
			break
		}
		despawned += unload_scene(w, s, doomed)
	}
	begin_parts(w, s, wanted)
	return
}

// begin_parts begins to load the parts of the known bases' sublevels that are in wanted, are not loaded, and have not
// failed. A failed sublevel that is not wanted is tried again when it is wanted again.
@(private)
begin_parts :: proc(w: ^ecs.World, s: ^Scenes, wanted: []string) {
	bases := make([dynamic]u32, w.platform.frame_allocator)
	for row in s.loaded {
		if _, is_base := row.part.(Part_Base); is_base {
			append(&bases, row.number)
		}
	}
	for base in bases {
		sublevels, known := sublevels_of(s, base)
		if !known {
			continue
		}
		for sublevel, i in sublevels {
			if !slice.contains(wanted, sublevel.name) {
				clear_failed(s, base, i)
				continue
			}
			if has_failed(s, base, i) {
				continue
			}
			if _, loaded := part_number(s, base, sublevel.name); loaded {
				continue
			}
			of := Part_Of{base, format.sublevel_name(sublevel.name)}
			if number, ok := begin_load_as(w, s, sublevel.guid, nil, of); ok {
				part_event(s, .Loading, of, number)
			} else {
				mark_failed(s, base, i)
				part_event(s, .Failed, of, 0)
			}
		}
	}
}

// unload_parts_of unloads every part of a base, and gives how many entities went.
@(private)
unload_parts_of :: proc(w: ^ecs.World, s: ^Scenes, base: u32) -> (despawned: int) {
	for {
		doomed, found := u32(0), false
		for row in s.loaded {
			if part, is_part := row.part.(Part_Of); is_part && part.base == base {
				doomed, found = row.number, true
				break
			}
		}
		if !found {
			return
		}
		despawned += unload_scene(w, s, doomed)
	}
}

// sublevel_failed is whether a part of the sublevel did not load, of any loaded base.
sublevel_failed :: proc(s: ^Scenes, sublevel: string) -> bool {
	follow_level(s)
	for row in s.loaded {
		b, is_base := row.part.(Part_Base)
		if !is_base {
			continue
		}
		for candidate, i in b.sublevels {
			if candidate.name == sublevel && i in b.failed {
				return true
			}
		}
	}
	return false
}

// retry_sublevel forgets that the sublevel's parts did not load, so update_parts tries them again. The game calls it
// when the sublevel is deactivated.
retry_sublevel :: proc(s: ^Scenes, sublevel: string) {
	follow_level(s)
	for &row in s.loaded {
		b, is_base := &row.part.(Part_Base)
		if !is_base {
			continue
		}
		for candidate, i in b.sublevels {
			if candidate.name == sublevel {
				b.failed -= {i}
			}
		}
	}
}

// note_part_failed notes that a loaded part did not load, so its base does not try it again while it stays wanted.
@(private)
note_part_failed :: proc(s: ^Scenes, number: u32) {
	index, found := find_loaded(s, number)
	if !found {
		return
	}
	part, is_part := s.loaded[index].part.(Part_Of)
	if !is_part {
		return
	}
	if sublevels, known := sublevels_of(s, part.base); known {
		for sublevel, i in sublevels {
			if sublevel.name == format.sublevel_name_text(&part.sublevel) {
				mark_failed(s, part.base, i)
			}
		}
	}
	part_event(s, .Failed, part, number)
}

@(private = "file")
base_row :: proc(s: ^Scenes, base: u32) -> ^Part_Base {
	if index, found := find_loaded(s, base); found {
		if b, is_base := &s.loaded[index].part.(Part_Base); is_base {
			return b
		}
	}
	return nil
}

@(private = "file")
mark_failed :: proc(s: ^Scenes, base: u32, sublevel: int) {
	if b := base_row(s, base); b != nil {
		b.failed += {sublevel}
	}
}

@(private = "file")
clear_failed :: proc(s: ^Scenes, base: u32, sublevel: int) {
	if b := base_row(s, base); b != nil {
		b.failed -= {sublevel}
	}
}

@(private = "file")
has_failed :: proc(s: ^Scenes, base: u32, sublevel: int) -> bool {
	b := base_row(s, base)
	return b != nil && sublevel in b.failed
}

@(private)
part_event :: proc(s: ^Scenes, kind: Part_Event_Kind, part: Part_Of, number: u32) {
	append(&s.part_events, Part_Event{kind, part.base, number, part.sublevel})
}
