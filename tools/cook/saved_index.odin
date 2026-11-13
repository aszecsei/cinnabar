// The daemon's saved index: what each pass learnt of the content, in <cache>/.index, so that the daemon that starts
// next checks what changed instead of reading everything again. See docs/content/daemon-and-operations.md#saved-index.
package cook

import "core:encoding/endian"
import "core:fmt"
import "core:hash"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

import cook_link "cinnabar:engine/asset/cook_link"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/wire"

// Change it to drop every saved index, when what a pass learns of an asset changes.
SAVED_INDEX_VERSION :: 1
SAVED_INDEX_FILE :: ".index"

// Saved_Source is what a pass learnt of one source, a file of the content or a stage's generated text, which the next
// pass carries when nothing that it depends on changed.
Saved_Source :: struct {
	// Absolute, with forward slashes.
	path:         string,
	kind:         format.Asset_Kind,
	root:         int,
	name:         string,
	guid:         format.Guid,
	meta_text:    string,
	owner:        format.Guid,
	result:       Asset_Result,
	dependencies: []format.Guid,
	visual:       []format.Guid,
	behaviour:    string,
	action:       string,
	params:       []cook_link.Action_Param,
	subassets:    []Subasset,
	permutations: int,
	size:         [2]u32,
	tool_texture: format.Guid,
	hotspots:     [][4]u32,
	inputs:       []Input_Stamp,
	// The problems in its source and its .meta file.
	problems:     []Problem,
}

@(private = "file")
Saved_Message :: union {
	Saved_Index,
}

// Saved_Index is the file's one message. Its header covers what makes what a pass learnt stand: a file of another
// header is not loaded.
@(private = "file")
Saved_Index :: struct {
	header:   u64,
	files:    []File_Record,
	sources:  []Saved_Source,
	assets:   []cook_link.Asset,
	folders:  []cook_link.Folder,
	problems: []cook_link.Asset_Problems,
	shading:  []cook_link.Shading_Model_Info,
}

// index_keep_sources adds what the next pass carries to an index that index_build makes: every file that the pass saw,
// and every source with what its cook learnt and its problems.
@(private)
index_keep_sources :: proc(index: ^Index, pass: Pass) {
	allocator := virtual.arena_allocator(&index.arena)
	files := make([]File_Record, len(pass.files), allocator)
	for f, i in pass.files {
		files[i] = f
		files[i].path = strings.clone(f.path, allocator)
	}
	index.files = files
	by_file := make(map[string][dynamic]Problem, context.temp_allocator)
	for p in pass.problems.list {
		list := by_file[p.file] or_else make([dynamic]Problem, context.temp_allocator)
		append(&list, Problem{strings.clone(p.file, allocator), p.line, p.column, p.error, strings.clone(p.text, allocator)})
		by_file[p.file] = list
	}
	clone_guids :: proc(guids: []format.Guid, allocator := context.allocator) -> []format.Guid {
		return slice.clone(guids, allocator)
	}
	sources := make([]Saved_Source, len(pass.assets), allocator)
	index.source_at = make(map[string]int, len(pass.assets), allocator)
	for a, i in pass.assets {
		problems := make([dynamic]Problem, context.temp_allocator)
		append(&problems, ..by_file[a.path][:])
		append(&problems, ..by_file[fmt.tprintf("%s%s", a.path, format.META_EXTENSION)][:])
		subassets := make([]Subasset, len(a.subassets), allocator)
		for s, j in a.subassets {
			subassets[j] = {s.kind, strings.clone(s.name, allocator), s.guid}
		}
		inputs := make([]Input_Stamp, len(a.inputs), allocator)
		for input, j in a.inputs {
			inputs[j] = {strings.clone(input.path, allocator), input.size, input.modified}
		}
		sources[i] = {
			path         = strings.clone(a.path, allocator),
			kind         = a.kind,
			root         = a.root,
			name         = strings.clone(a.name, allocator),
			guid         = a.meta.guid,
			meta_text    = strings.clone(a.meta_text, allocator),
			owner        = a.owner,
			result       = a.result,
			dependencies = clone_guids(a.dependencies[:], allocator),
			visual       = clone_guids(a.visual[:], allocator),
			behaviour    = strings.clone(a.behaviour, allocator),
			action       = strings.clone(a.action, allocator),
			params       = clone_params(a.params, allocator),
			subassets    = subassets,
			permutations = a.permutations,
			size         = a.size,
			tool_texture = a.tool_texture,
			hotspots     = slice.clone(a.hotspots, allocator),
			inputs       = inputs,
			problems     = slice.clone(problems[:], allocator),
		}
		index.source_at[sources[i].path] = i
	}
	index.sources = sources
}

// index_write saves an index in the cache, through a temporary file.
index_write :: proc(index: ^Index, options: Cook_Options) -> bool {
	snapshot, problems := index_snapshot(index)
	message := Saved_Index {
		header   = saved_header(options, index.generation),
		files    = index.files,
		sources  = index.sources,
		assets   = snapshot.assets,
		folders  = snapshot.folders,
		problems = problems,
		shading  = index.shading.models,
	}
	buf := make([dynamic]byte, context.temp_allocator)
	wire.write_message(&buf, Saved_Message(message))
	return write_blob(saved_path(options), buf[:])
}

// index_load loads the saved index of the cache, into an empty index. A file that is missing, does not decode, or is of
// another header, as when the cooker or the options changed, loads nothing, so the pass after looks at everything.
index_load :: proc(index: ^Index, options: Cook_Options) -> bool {
	data, err := os.read_entire_file(saved_path(options), context.temp_allocator)
	if err != nil || len(data) < wire.HEADER_SIZE || int(endian.unchecked_get_u32le(data[0:])) != len(data) - wire.HEADER_SIZE {
		return false
	}
	_ = virtual.arena_init_growing(&index.arena)
	allocator := virtual.arena_allocator(&index.arena)
	message, decoded := wire.decode_message(Saved_Message, endian.unchecked_get_u16le(data[4:]), data[wire.HEADER_SIZE:], allocator)
	saved, is_saved := message.(Saved_Index)
	generation := read_generation(config_dir(options))
	if !decoded || !is_saved || saved.header != saved_header(options, generation) {
		index_destroy(index)
		return false
	}
	index.generation = generation
	index.assets = make(map[string]cook_link.Asset, len(saved.assets), allocator)
	for a in saved.assets {
		index.assets[a.guid] = a
	}
	index.folders = saved.folders
	index.problems = make(map[string][]cook_link.Problem, len(saved.problems), allocator)
	for p in saved.problems {
		index.problems[p.guid] = p.problems
	}
	index.shading = {saved.shading}
	index.files = saved.files
	index.sources = saved.sources
	index.source_at = make(map[string]int, len(saved.sources), allocator)
	for s, i in saved.sources {
		index.source_at[s.path] = i
	}
	return true
}

@(private = "file")
saved_path :: proc(options: Cook_Options) -> string {
	return fmt.tprintf("%s/%s", config_dir(options), SAVED_INDEX_FILE)
}

// saved_header covers what makes a saved index stand: its format, the options of the daemon, which decide what the
// roots hold and how it cooks, the cooker itself, as a new cooker may cook every asset differently, and the cache's
// generation, which another cook of the cache changes.
@(private = "file")
saved_header :: proc(options: Cook_Options, generation: u64) -> u64 {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%d\x00%016x\x00%v\x00%s\x00%s\x00%s\x00", SAVED_INDEX_VERSION, wire.protocol_version(Saved_Message), options.config, options.definitions, options.dxc, options.dxc_version)
	for r in options.roots {
		fmt.sbprintf(&b, "root %s=%s\x00", r.name, r.dir)
	}
	for include in options.includes {
		fmt.sbprintf(&b, "include %s\x00", include)
	}
	if exe, err := os.get_executable_path(context.temp_allocator); err == nil {
		if info, stat_err := os.stat(exe, context.temp_allocator); stat_err == nil {
			fmt.sbprintf(&b, "cooker %s %d %d\x00", exe, info.size, time.to_unix_nanoseconds(info.modification_time))
		}
	}
	fmt.sbprintf(&b, "generation %d", generation)
	return hash.fnv64a(transmute([]byte)strings.to_string(b))
}
