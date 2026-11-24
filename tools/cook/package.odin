// `cook package --cache <dir> --out <dir> [--project <file>]` packs a release cache's blobs into bundles, one for each
// load unit, which a release build reads in place of the loose cache. See docs/content/blobs-and-loading.md#bundles.
package cook

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"

import "cinnabar:core/lz4"
import format "cinnabar:engine/asset/format"

Package_Options :: struct {
	// The loose cache that a release cook wrote.
	cache:   string,
	// Where the bundles go: the release build's content directory.
	out:     string,
	// The project's settings, for the scenes that are not levels, or "" for none.
	project: string,
}

// parse_package_args reads `--cache <dir> --out <dir> [--project <file>]`.
parse_package_args :: proc(args: []string) -> (options: Package_Options, ok: bool) {
	for i := 0; i + 1 < len(args); i += 2 {
		switch args[i] {
		case "--cache":
			options.cache = args[i + 1]
		case "--out":
			options.out = args[i + 1]
		case "--project":
			options.project = args[i + 1]
		case:
			return
		}
	}
	return options, len(args) % 2 == 0 && options.cache != "" && options.out != ""
}

// Package_Blob is one blob of the cache, with the assets that it names and the load unit that it goes in.
Package_Blob :: struct {
	guid:       format.Guid,
	kind:       format.Asset_Kind,
	// At format.BLOB_ALIGN.
	data:       []byte,
	references: []format.Guid,
	// An index into the units that assign_units returns, or GLOBAL_UNIT.
	unit:       int,
}

GLOBAL_UNIT :: -1

// package_content packs the cache's blobs into bundles in out, while it holds the cache's lock, so no cook writes a blob
// as it is read. It writes global.cbb and a <scene guid>.cbb for each level and each streaming chunk, and logs each one's
// size.
package_content :: proc(options: Package_Options) -> bool {
	lock, locked := lock_cache(options.cache)
	switch locked {
	case .Locked:
	case .Held:
		log.errorf(
			"cook: another cook is using %s. Stop the cook daemon and package again.",
			options.cache,
		)
		return false
	case .Failed:
		return false
	}
	defer unlock(&lock)
	global_scenes: []format.Guid
	if options.project != "" {
		scenes, ok := project_global_scenes(options.project)
		if !ok {
			return false
		}
		global_scenes = scenes
	}
	blobs, read_ok := read_cache_blobs(options.cache)
	if !read_ok {
		return false
	}
	load_units := assign_units(blobs, global_scenes)
	if err := os.make_directory_all(options.out); err != nil && err != .Exist {
		log.errorf("cook: %s: %v", options.out, err)
		return false
	}
	stored := encode_blobs(blobs)
	units := make([][dynamic]format.Bundle_Blob, len(load_units) + 1, context.temp_allocator)
	sizes := make([]int, len(load_units) + 1, context.temp_allocator)
	for &b, i in blobs {
		unit := b.unit + 1
		if units[unit] == nil {
			units[unit] = make([dynamic]format.Bundle_Blob, context.temp_allocator)
		}
		append(&units[unit], stored[i])
		sizes[unit] += len(b.data)
	}
	for unit, i in units {
		name := format.GLOBAL_BUNDLE
		dependencies: []string
		if i > 0 {
			name = format.guid_format(load_units[i - 1].scene, new([32]u8, context.temp_allocator))
			dependencies = {format.GLOBAL_BUNDLE}
			if parent := load_units[i - 1].parent; parent != GLOBAL_UNIT {
				level := format.guid_format(
					load_units[parent].scene,
					new([32]u8, context.temp_allocator),
				)
				dependencies = slice.clone(
					[]string{level, format.GLOBAL_BUNDLE},
					context.temp_allocator,
				)
			}
		}
		bundle := format.bundle_write(unit[:], dependencies, context.temp_allocator)
		path := fmt.tprintf("%s/%s%s", options.out, name, format.BUNDLE_EXTENSION)
		if !write_blob(path, bundle) {
			return false
		}
		log.infof(
			"cook: %s%s: %d blobs, %d KiB from %d KiB",
			name,
			format.BUNDLE_EXTENSION,
			len(unit),
			len(bundle) / 1024,
			sizes[i] / 1024,
		)
	}
	return true
}

// project_global_scenes reads the scenes that are not levels from a project's settings file. As with every key, the
// last line that sets it wins.
project_global_scenes :: proc(path: string) -> (scenes: []format.Guid, ok: bool) {
	text, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		log.errorf("cook: %s: %v", path, err)
		return
	}
	value := format.settings_value(string(text), format.BUNDLE_GLOBAL_SCENES_KEY)
	if scenes, ok = format.bundle_parse_scenes(value, context.temp_allocator); !ok {
		log.errorf(
			"cook: %s: %s takes scenes' GUIDs between commas, not %q",
			path,
			format.BUNDLE_GLOBAL_SCENES_KEY,
			value,
		)
	}
	return
}

// read_cache_blobs reads every <guid>.blob of a cache, at format.BLOB_ALIGN, and the assets that each names. It fails
// on a blob that is not one of its GUID, which a cook of every kind would write again.
read_cache_blobs :: proc(cache: string) -> (blobs: []Package_Blob, ok: bool) {
	entries, err := os.read_all_directory_by_path(cache, context.temp_allocator)
	if err != nil {
		log.errorf("cook: %s: %v", cache, err)
		return
	}
	list := make([dynamic]Package_Blob, context.temp_allocator)
	for entry in entries {
		if entry.type != .Regular || !strings.has_suffix(entry.name, ".blob") {
			continue
		}
		guid, parsed := format.guid_parse(strings.trim_suffix(entry.name, ".blob"))
		if !parsed {
			continue
		}
		text, read_err := os.read_entire_file(entry.fullpath, context.temp_allocator)
		if read_err != nil {
			log.errorf("cook: %s: %v", entry.fullpath, read_err)
			return
		}
		data :=
			mem.alloc_bytes_non_zeroed(
				len(text),
				format.BLOB_ALIGN,
				context.temp_allocator,
			) or_else nil
		copy(data, text)
		header, valid := format.blob_header(data)
		references, references_ok := format.blob_references(data, context.temp_allocator)
		if !valid || header.guid != guid || !references_ok {
			log.errorf(
				"cook: %s is not a blob of its GUID that this cooker reads. Cook the content again.",
				entry.fullpath,
			)
			return
		}
		append(
			&list,
			Package_Blob {
				guid = guid,
				kind = header.kind,
				data = data,
				references = references,
				unit = GLOBAL_UNIT,
			},
		)
	}
	slice.sort_by(list[:], proc(a, b: Package_Blob) -> bool {
		return format.guid_less(a.guid, b.guid)
	})
	return list[:], true
}

// Package_Unit is a load unit other than the global one: a level, or a streaming chunk. scene is the scene that names
// it, and its bundle.
Package_Unit :: struct {
	scene:  format.Guid,
	// For a chunk, the unit of its level, or GLOBAL_UNIT for a chunk that has no level. GLOBAL_UNIT for a level.
	parent: int,
}

// assign_units chooses each blob's load unit and returns the units, levels first. A chunk is a scene that a world
// lists without Persistent; a level is any other scene that global_scenes does not name and that no world lists as
// Persistent. Each is in its own unit. A
// chunk's level is the one level that reaches the worlds that list it. Another blob is in the unit of what reaches it
// through the assets that blobs name, when one level or one chunk alone reaches it, and in a level's unit when only
// that level and its chunks reach it. A walk does not go into another level's or chunk's scene, which is that unit's.
// Every other blob is global: what more than one level reaches, what none reaches, such as what code loads by GUID,
// and whatever a global blob reaches, so that a global blob never needs another bundle.
assign_units :: proc(blobs: []Package_Blob, global_scenes: []format.Guid) -> []Package_Unit {
	index := make(map[format.Guid]int, len(blobs), context.temp_allocator)
	for b, i in blobs {
		index[b.guid] = i
	}
	// A world's persistent scene loads with the level that names the world, so it is not a level of its own.
	is_chunk := make([]bool, len(blobs), context.temp_allocator)
	is_persistent := make([]bool, len(blobs), context.temp_allocator)
	for _, i in blobs {
		for j in world_scenes_of(blobs, index, global_scenes, i, persistent = false) {
			is_chunk[j] = true
		}
		for j in world_scenes_of(blobs, index, global_scenes, i, persistent = true) {
			is_persistent[j] = true
		}
	}
	// A sublevel's blob is a scene, which loads in its scene's unit, so it is not a level of its own: the scene reaches it.
	is_sublevel := make([]bool, len(blobs), context.temp_allocator)
	for b in blobs {
		if b.kind != .Scene {
			continue
		}
		sublevels, _ := format.scene_sublevels(b.data, context.temp_allocator)
		for l in sublevels {
			if j, found := index[l.guid]; found {
				is_sublevel[j] = true
			}
		}
	}
	units := make([dynamic]Package_Unit, context.temp_allocator)
	unit_of := make([]int, len(blobs), context.temp_allocator)
	scene_of := make([dynamic]int, context.temp_allocator)
	for b, i in blobs {
		unit_of[i] = GLOBAL_UNIT
		if b.kind == .Scene &&
		   !slice.contains(global_scenes, b.guid) &&
		   !is_chunk[i] &&
		   !is_persistent[i] &&
		   !is_sublevel[i] {
			unit_of[i] = len(units)
			append(&units, Package_Unit{b.guid, GLOBAL_UNIT})
			append(&scene_of, i)
		}
	}
	level_count := len(units)
	for b, i in blobs {
		if is_chunk[i] {
			unit_of[i] = len(units)
			append(&units, Package_Unit{b.guid, GLOBAL_UNIT})
			append(&scene_of, i)
		}
	}
	// What reaches each blob: no unit, one unit, or more than one. group is the same for the levels that the reaching
	// units belong to, where a chunk without a level is a group of its own.
	NONE :: -2
	MANY :: -3
	mark :: proc(slot: ^int, unit: int) {
		if slot^ == NONE {
			slot^ = unit
		} else if slot^ != unit {
			slot^ = MANY
		}
	}
	reached := make([]int, len(blobs), context.temp_allocator)
	group := make([]int, len(blobs), context.temp_allocator)
	slice.fill(reached, NONE)
	slice.fill(group, NONE)
	seen := make([]bool, len(blobs), context.temp_allocator)
	for u in 0 ..< level_count {
		for j in reach_from(blobs, index, unit_of, {scene_of[u]}, seen) {
			mark(&reached[j], u)
			mark(&group[j], u)
		}
	}
	// A chunk's level is the level that reaches each world that lists it.
	parent := make([]int, len(blobs), context.temp_allocator)
	slice.fill(parent, NONE)
	for _, i in blobs {
		for j in world_scenes_of(blobs, index, global_scenes, i, persistent = false) {
			mark(&parent[j], reached[i])
		}
	}
	for u in level_count ..< len(units) {
		p := parent[scene_of[u]]
		if p >= 0 {
			units[u].parent = p
		}
		g := p >= 0 ? p : u
		for j in reach_from(blobs, index, unit_of, {scene_of[u]}, seen) {
			mark(&reached[j], u)
			mark(&group[j], g)
		}
	}
	global := make([dynamic]int, context.temp_allocator)
	for &b, i in blobs {
		b.unit = unit_of[i]
		if b.unit == GLOBAL_UNIT {
			if reached[i] >= 0 {
				b.unit = reached[i]
			} else if group[i] >= 0 {
				b.unit = group[i]
			}
		}
		if b.unit == GLOBAL_UNIT {
			append(&global, i)
		}
	}
	// What a global blob names is global too, whichever unit reaches it.
	for j in reach_from(blobs, index, unit_of, global[:], seen) {
		blobs[j].unit = GLOBAL_UNIT
	}
	return units[:]
}

// world_scenes_of is the blobs of the scenes that the blob at world lists, if it is a world, with Persistent or without
// it, that global_scenes does not name. Those without it are the world's chunks.
@(private = "file")
world_scenes_of :: proc(
	blobs: []Package_Blob,
	index: map[format.Guid]int,
	global_scenes: []format.Guid,
	world: int,
	persistent: bool,
) -> []int {
	b := blobs[world]
	if b.kind != .World {
		return nil
	}
	view, ok := format.world_view(b.data)
	if !ok {
		return nil
	}
	chunks := make([dynamic]int, context.temp_allocator)
	for s in format.world_scenes(b.data, view) {
		j, found := index[s.guid]
		if found &&
		   blobs[j].kind == .Scene &&
		   (.Persistent in s.flags) == persistent &&
		   !slice.contains(global_scenes, s.guid) {
			append(&chunks, j)
		}
	}
	return chunks[:]
}

// reach_from is the blobs that the blobs at from reach through the assets that they name, from among them: a walk that
// does not go into a level's or a chunk's scene but from. seen is the walk's scratch, one for each blob.
@(private = "file")
reach_from :: proc(
	blobs: []Package_Blob,
	index: map[format.Guid]int,
	unit_of: []int,
	from: []int,
	seen: []bool,
) -> []int {
	slice.fill(seen, false)
	reached := make([dynamic]int, context.temp_allocator)
	for i in from {
		seen[i] = true
		append(&reached, i)
	}
	for next := 0; next < len(reached); next += 1 {
		for r in blobs[reached[next]].references {
			j, found := index[r]
			if found && !seen[j] && unit_of[j] == GLOBAL_UNIT {
				seen[j] = true
				append(&reached, j)
			}
		}
	}
	return reached[:]
}

// encode_blobs stores each blob as its bundle holds it, on a thread for each of the CPU's. A blob that something reads a
// range of stays as it is: a sound that streams, and a paged mesh, whose pages are LZ4 blocks already. So does one that
// LZ4 does not make smaller. Every other blob is one LZ4 block.
encode_blobs :: proc(blobs: []Package_Blob) -> []format.Bundle_Blob {
	Work :: struct {
		blobs:  []Package_Blob,
		stored: []format.Bundle_Blob,
	}
	work := Work{blobs, make([]format.Bundle_Blob, len(blobs), context.temp_allocator)}
	for b, i in blobs {
		work.stored[i] = {
			guid   = b.guid,
			kind   = b.kind,
			codec  = .None,
			size   = u32(len(b.data)),
			stored = b.data,
		}
		if !blob_is_ranged(b) {
			// The block's room, which the thread fills.
			work.stored[i].stored = make([]byte, lz4.bound(len(b.data)), context.temp_allocator)
		}
	}
	parallel_for(len(blobs), &work, proc(data: rawptr, i: int) {
		work := (^Work)(data)
		b, s := work.blobs[i], &work.stored[i]
		if blob_is_ranged(b) {
			return
		}
		block := lz4.compress(b.data, s.stored)
		if block != nil && len(block) < len(b.data) {
			s.codec, s.stored = .Lz4, block
		} else {
			s.stored = b.data
		}
	})
	return work.stored
}

// blob_is_ranged is whether something reads ranges of a blob from its file: a sound that streams, a paged mesh's pages,
// and a virtual texture's.
blob_is_ranged :: proc(b: Package_Blob) -> bool {
	#partial switch b.kind {
	case .Audio:
		blob, ok := format.audio_view(b.data)
		return ok && bool(blob.stream)
	case .Mesh:
		return format.mesh_head_size(b.data) != 0
	case .Texture:
		_, virtual := format.texture_head_size(b.data)
		return virtual
	}
	return false
}
