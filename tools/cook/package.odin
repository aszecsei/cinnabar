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
	// An index into the levels, or GLOBAL_UNIT.
	unit:       int,
}

GLOBAL_UNIT :: -1

// package_content packs the cache's blobs into bundles in out, while it holds the cache's lock, so no cook writes a blob
// as it is read. It writes global.cbb and a <scene guid>.cbb for each level, and logs each one's size.
package_content :: proc(options: Package_Options) -> bool {
	lock, locked := lock_cache(options.cache)
	switch locked {
	case .Locked:
	case .Held:
		log.errorf("cook: another cook is using %s. Stop the cook daemon and package again.", options.cache)
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
	levels := assign_units(blobs, global_scenes)
	if err := os.make_directory_all(options.out); err != nil && err != .Exist {
		log.errorf("cook: %s: %v", options.out, err)
		return false
	}
	stored := encode_blobs(blobs)
	units := make([][dynamic]format.Bundle_Blob, len(levels) + 1, context.temp_allocator)
	sizes := make([]int, len(levels) + 1, context.temp_allocator)
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
			buffer := new([32]u8, context.temp_allocator)
			name = format.guid_format(levels[i - 1], buffer)
			dependencies = {format.GLOBAL_BUNDLE}
		}
		bundle := format.bundle_write(unit[:], dependencies, context.temp_allocator)
		path := fmt.tprintf("%s/%s%s", options.out, name, format.BUNDLE_EXTENSION)
		if !write_blob(path, bundle) {
			return false
		}
		log.infof("cook: %s%s: %d blobs, %d KiB from %d KiB", name, format.BUNDLE_EXTENSION, len(unit), len(bundle) / 1024, sizes[i] / 1024)
	}
	return true
}

// project_global_scenes reads the scenes that are not levels from a project's settings file.
project_global_scenes :: proc(path: string) -> (scenes: []format.Guid, ok: bool) {
	text, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		log.errorf("cook: %s: %v", path, err)
		return
	}
	rest := string(text)
	for line in strings.split_lines_iterator(&rest) {
		key, _, value := strings.partition(strings.trim_space(line), "=")
		if strings.trim_space(key) != format.BUNDLE_GLOBAL_SCENES_KEY {
			continue
		}
		if scenes, ok = format.bundle_parse_scenes(value, context.temp_allocator); !ok {
			log.errorf("cook: %s: %s takes scenes' GUIDs between commas, not %q", path, format.BUNDLE_GLOBAL_SCENES_KEY, strings.trim_space(value))
		}
		return
	}
	return nil, true
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
		data := mem.alloc_bytes_non_zeroed(len(text), format.BLOB_ALIGN, context.temp_allocator) or_else nil
		copy(data, text)
		header, valid := format.blob_header(data)
		references, references_ok := format.blob_references(data, context.temp_allocator)
		if !valid || header.guid != guid || !references_ok {
			log.errorf("cook: %s is not a blob of its GUID that this cooker reads. Cook the content again.", entry.fullpath)
			return
		}
		append(&list, Package_Blob{guid = guid, kind = header.kind, data = data, references = references, unit = GLOBAL_UNIT})
	}
	slice.sort_by(list[:], proc(a, b: Package_Blob) -> bool {
		return format.guid_less(a.guid, b.guid)
	})
	return list[:], true
}

// assign_units chooses each blob's load unit and returns the levels, by their scenes' GUIDs, in order. A level is a
// scene that global_scenes does not name, and its scene is in its own unit. Another blob is in a level's unit when that
// level is the only one that reaches it through the assets that blobs name; a walk does not go into another level's
// scene, which is that level's. Every other blob is global: what more than one level reaches, what none reaches, such
// as what code loads by GUID, and whatever a global blob reaches, so that a global blob never needs a level's bundle.
assign_units :: proc(blobs: []Package_Blob, global_scenes: []format.Guid) -> []format.Guid {
	index := make(map[format.Guid]int, len(blobs), context.temp_allocator)
	for b, i in blobs {
		index[b.guid] = i
	}
	levels := make([dynamic]format.Guid, context.temp_allocator)
	level_of := make([]int, len(blobs), context.temp_allocator)
	for b, i in blobs {
		level_of[i] = GLOBAL_UNIT
		if b.kind == .Scene && !slice.contains(global_scenes, b.guid) {
			level_of[i] = len(levels)
			append(&levels, b.guid)
		}
	}
	// What reaches each blob: no level, one level, or more than one.
	NONE :: -2
	MANY :: -3
	reached := make([]int, len(blobs), context.temp_allocator)
	slice.fill(reached, NONE)
	seen := make([]bool, len(blobs), context.temp_allocator)
	for level, i in level_of {
		if level == GLOBAL_UNIT {
			continue
		}
		for j in reach_from(blobs, index, level_of, {i}, seen) {
			if reached[j] == NONE {
				reached[j] = level
			} else if reached[j] != level {
				reached[j] = MANY
			}
		}
	}
	global := make([dynamic]int, context.temp_allocator)
	for &b, i in blobs {
		b.unit = level_of[i]
		if level_of[i] == GLOBAL_UNIT && reached[i] >= 0 {
			b.unit = reached[i]
		}
		if b.unit == GLOBAL_UNIT {
			append(&global, i)
		}
	}
	// What a global blob names is global too, whichever level reaches it.
	for j in reach_from(blobs, index, level_of, global[:], seen) {
		blobs[j].unit = GLOBAL_UNIT
	}
	return levels[:]
}

// reach_from is the blobs that the blobs at from reach through the assets that they name, from among them: a walk that
// does not go into a level's scene but from. seen is the walk's scratch, one for each blob.
@(private = "file")
reach_from :: proc(blobs: []Package_Blob, index: map[format.Guid]int, level_of: []int, from: []int, seen: []bool) -> []int {
	slice.fill(seen, false)
	reached := make([dynamic]int, context.temp_allocator)
	for i in from {
		seen[i] = true
		append(&reached, i)
	}
	for next := 0; next < len(reached); next += 1 {
		for r in blobs[reached[next]].references {
			j, found := index[r]
			if found && !seen[j] && level_of[j] == GLOBAL_UNIT {
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

// blob_is_ranged is whether something reads ranges of a blob from its file: a sound that streams, and a paged mesh's
// pages.
blob_is_ranged :: proc(b: Package_Blob) -> bool {
	#partial switch b.kind {
	case .Audio:
		blob, ok := format.audio_view(b.data)
		return ok && bool(blob.stream)
	case .Mesh:
		return format.mesh_head_size(b.data) != 0
	}
	return false
}
