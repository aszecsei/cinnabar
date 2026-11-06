package ui

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import csync "core:sync"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/jobs"
import "cinnabar:core/luau"
import script_host "cinnabar:core/script"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

// The tests share the job system and the clock, so they run one at a time.
@(private = "file")
lock: csync.Mutex

// The time that the fixture's platform gives, which a test moves.
@(private)
test_now: f64

// The cooker's test font, a subset of Fira Sans (see tools/cook/testdata/fonts/OFL.txt).
@(private)
TEST_FONT_FILE :: #load("../../../tools/cook/testdata/fonts/FiraSans-Subset.ttf")
@(private)
TEST_FONT :: "f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0"

@(private)
Fixture :: struct {
	frame:    virtual.Arena,
	platform: core.Platform_API,
	world:    ecs.World,
	cache:    string,
	assets:   asset.Assets,
	ui:       State,
	scripts:  bool,
	runtime:  script.Runtime,
	reports:  [dynamic]string,
	// The entity that Test.entity gives.
	entity:   ecs.Entity,
	// The blobs' versions, which a rewrite moves on.
	generation: int,
}

@(private)
guid_of :: proc(text: string) -> format.Guid {
	g, _ := format.guid_parse(text)
	return g
}

@(private)
setup :: proc(t: ^testing.T, scripts := false) -> ^Fixture {
	csync.lock(&lock)
	testing.expect(t, jobs.init())
	test_now = 0
	f := new(Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator      = virtual.arena_allocator(&f.frame),
		heap_allocator       = runtime.heap_allocator(),
		asset_allocator      = runtime.heap_allocator(),
		jobs_run             = jobs.run,
		jobs_wait            = jobs.wait,
		memory_reserve       = proc(size: int) -> rawptr {
			data, err := virtual.reserve(uint(size))
			return err == nil ? raw_data(data) : nil
		},
		memory_commit        = proc(ptr: rawptr, size: int) -> bool {return virtual.commit(ptr, uint(size)) == nil},
		memory_release       = proc(ptr: rawptr, size: int) {virtual.release(ptr, uint(size))},
		file_read            = core.file_read,
		file_modified        = core.file_modified,
		time_seconds         = proc() -> f64 {return test_now},
		script_open          = script_host.open,
		script_close         = script_host.close,
		script_push_binding  = script_host.push_binding,
		script_atom          = script_host.atom,
		script_direct_access = script_host.direct_access,
	}
	testing.expect(t, ecs.init(&f.world, &f.platform))
	ecs.register_engine_components(&f.world.registry)
	register_components(&f.world.registry)
	cache, err := os.make_directory_temp("", "ui_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.cache = cache
	asset.init(&f.assets, &f.platform, asset.loose_cache(f.cache))
	init(&f.ui, &f.platform, &f.assets)
	write_font(t, f)
	if scripts {
		f.scripts = true
		f.reports = make([dynamic]string)
		script.register_components(&f.world.registry)
		context.user_ptr = f
		testing.expect(t, script.init(&f.runtime, &f.platform, &f.world, nil, register_test_scripts))
	}
	return f
}

// register_test_scripts defines the Ui library, Test.entity, and Test.report, which keeps its arguments.
@(private = "file")
register_test_scripts :: proc(r: ^script.Runtime) {
	f := (^Fixture)(context.user_ptr)
	register_scripts(r, &f.ui)
	script.define(r, "Test.entity", proc(L: ^luau.State) -> c.int {
		script.push_entity(L, (^Fixture)(context.user_ptr).entity)
		return 1
	})
	script.define(r, "Test.report", proc(L: ^luau.State) -> c.int {
		f := (^Fixture)(context.user_ptr)
		parts := make([dynamic]string, context.temp_allocator)
		for i in 1 ..= luau.gettop(L) {
			append(&parts, strings.clone(string(cstring(luau.L_tolstring(L, i, nil))), context.temp_allocator))
			luau.pop(L, 1)
		}
		append(&f.reports, strings.join(parts[:], " ", context.temp_allocator))
		return 0
	})
}

@(private)
teardown :: proc(t: ^testing.T, f: ^Fixture) {
	if f.scripts {
		script.destroy(&f.runtime)
		delete(f.reports)
	}
	destroy(&f.ui)
	asset.destroy(&f.assets)
	os.remove_all(f.cache)
	delete(f.cache)
	ecs.destroy(&f.world)
	virtual.arena_destroy(&f.frame)
	free(f)
	testing.expect(t, jobs.drain_frame())
	jobs.shutdown()
	csync.unlock(&lock)
}

@(private)
write_blob :: proc(t: ^testing.T, f: ^Fixture, guid: string, data: []byte) {
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s.blob", f.cache, guid), data) == nil)
}

// write_font writes the test font's blob, with every glyph a cell of no size, as no atlas draws in the tests.
@(private = "file")
write_font :: proc(t: ^testing.T, f: ^Fixture) {
	glyphs := make([]format.Font_Glyph, 108, context.temp_allocator)
	for &g, i in glyphs {
		g.id = u32(i)
	}
	write_blob(t, f, TEST_FONT, format.font_write({
		guid = guid_of(TEST_FONT),
		key = 1,
		atlas_size = {1, 1},
		units_per_em = 1000,
		em_size = 48,
		range = 8,
		ascender = 0.935,
		descender = -0.265,
		line_gap = 0,
		glyphs = glyphs,
		font_data = TEST_FONT_FILE,
		family = "Fira Sans",
	}, context.temp_allocator))
}

// write_document parses a document's text, which must have no errors, and writes its blob.
@(private)
write_document :: proc(t: ^testing.T, f: ^Fixture, guid: string, text: string, loc := #caller_location) {
	document, problems, ok := format.ui_parse(text)
	testing.expectf(t, ok, "%v", problems, loc = loc)
	f.generation += 1
	write_blob(t, f, guid, format.ui_write({guid = guid_of(guid), key = u64(f.generation), document = document}, context.temp_allocator))
}

// show puts a document on a new entity.
@(private)
show :: proc(t: ^testing.T, f: ^Fixture, guid: string, text: string, order: i32 = 0) -> ecs.Entity {
	write_document(t, f, guid, text)
	e := ecs.spawn(&f.world)
	ecs.add(&f.world, e, Ui_Document{document = guid_of(guid), order = order, visible = true})
	return e
}

// step runs the UI's part of a frame: the documents, then the input against the last layout, then the layout at a
// size, which sets the scale.
@(private)
step :: proc(f: ^Fixture, input: core.Input = {}, size := [2]f32{1920, 1080}) {
	free_all(f.platform.frame_allocator)
	sync(&f.ui, &f.world)
	handle_input(&f.ui, input, test_now)
	layout(&f.ui, size)
}

// node_rect is the rectangle of a document's element by its id.
@(private)
node_rect :: proc(t: ^testing.T, f: ^Fixture, e: ecs.Entity, id: string, loc := #caller_location) -> [4]f32 {
	d := document_of(&f.ui, e)
	testing.expect(t, d != nil, loc = loc)
	if d == nil {
		return {}
	}
	n, found := find_node(d, id)
	testing.expectf(t, found, "no element %s", id, loc = loc)
	return found ? d.nodes[n].rect : {}
}
