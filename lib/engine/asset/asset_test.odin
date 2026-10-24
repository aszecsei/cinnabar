package asset

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "cinnabar:core"
import format "cinnabar:engine/asset/format"

@(private)
Fixture :: struct {
	platform: core.Platform_API,
	frame:    virtual.Arena,
	dir:      string,
	assets:   Assets,
	errors:   [dynamic]string,
}

@(private)
setup :: proc(t: ^testing.T) -> ^Fixture {
	f := new(Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
		asset_allocator = runtime.heap_allocator(),
		file_read       = core.file_read,
		file_modified   = core.file_modified,
		// poll compares this with last_poll, which the tests set.
		time_seconds    = proc() -> f64 {return 1000},
	}
	temp, err := os.make_directory_temp("", "asset_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.dir = temp
	f.errors = make([dynamic]string)
	init(&f.assets, &f.platform, loose_cache(f.dir))
	return f
}

@(private)
teardown :: proc(f: ^Fixture) {
	destroy(&f.assets)
	os.remove_all(f.dir)
	delete(f.dir)
	for e in f.errors {
		delete(e)
	}
	delete(f.errors)
	virtual.arena_destroy(&f.frame)
	free(f)
}

// capture_errors records errors in the fixture instead of failing the test.
@(private)
capture_errors :: proc(f: ^Fixture) -> log.Logger {
	return {
		procedure = proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
			f := (^Fixture)(data)
			append(&f.errors, strings.clone(text))
		},
		data = f,
		lowest_level = .Error,
	}
}

@(private)
test_guid :: proc(n: u8) -> format.Guid {
	return {0 = n, 15 = 0xaa}
}

// write_blob cooks a script blob into the loose cache, for the given GUID and key. modified sets its modification
// time, so a rewrite within the clock's resolution still looks new.
@(private)
write_blob :: proc(t: ^testing.T, f: ^Fixture, guid: format.Guid, key: u64, modified: time.Time, blob_guid := format.Guid{}) {
	blob := format.script_write({guid = blob_guid == {} ? guid : blob_guid, key = key, bytecode = {1}, source_path = "x.luau"}, context.temp_allocator)
	buffer: [32]u8
	path := fmt.tprintf("%s/%s.blob", f.dir, format.guid_format(guid, &buffer))
	testing.expect(t, os.write_entire_file(path, blob) == nil)
	testing.expect(t, os.change_times(path, modified, modified) == nil)
}

@(private)
blob_key :: proc(f: ^Fixture, h: Handle) -> u64 {
	data, ok := data(&f.assets, h)
	if !ok {
		return 0
	}
	header, _ := format.blob_header(data)
	return header.key
}

@(test)
loading_twice_gives_the_same_handle :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	write_blob(t, f, test_guid(1), 7, time.now())
	a, ok := load(&f.assets, test_guid(1))
	testing.expect(t, ok)
	b, _ := load(&f.assets, test_guid(1))
	testing.expect_value(t, a, b)
	testing.expect_value(t, blob_key(f, a), 7)
	testing.expect_value(t, guid(&f.assets, a), test_guid(1))
}

@(test)
an_unloaded_handle_is_detected :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	write_blob(t, f, test_guid(1), 7, time.now())
	old, _ := load(&f.assets, test_guid(1))
	unload(&f.assets, old)
	_, ok := data(&f.assets, old)
	testing.expect(t, !ok)
	// The record is used again, with another generation.
	again, _ := load(&f.assets, test_guid(1))
	testing.expect_value(t, again.index, old.index)
	testing.expect(t, again != old)
	_, ok = data(&f.assets, Handle{})
	testing.expect(t, !ok)
}

@(test)
missing_and_mismatched_blobs_do_not_load :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	context.logger = capture_errors(f)
	_, ok := load(&f.assets, test_guid(9))
	testing.expect(t, !ok)
	// A blob under another asset's name.
	write_blob(t, f, test_guid(2), 7, time.now(), blob_guid = test_guid(3))
	_, ok = load(&f.assets, test_guid(2))
	testing.expect(t, !ok)
	testing.expect_value(t, len(f.errors), 2)
}

@(test)
poll_swaps_a_rewritten_blob :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	start := time.now()
	write_blob(t, f, test_guid(1), 7, start)
	write_blob(t, f, test_guid(2), 8, start)
	h, _ := load(&f.assets, test_guid(1))
	other, _ := load(&f.assets, test_guid(2))

	f.assets.last_poll = 0
	testing.expect_value(t, len(poll(&f.assets)), 0)

	write_blob(t, f, test_guid(1), 9, time.time_add(start, time.Second))
	// poll waits for its interval.
	testing.expect_value(t, len(poll(&f.assets)), 0)
	f.assets.last_poll = 0
	changed := poll(&f.assets)
	testing.expect_value(t, len(changed), 1)
	if len(changed) == 1 {
		testing.expect_value(t, changed[0], h)
	}
	testing.expect_value(t, blob_key(f, h), 9)
	testing.expect_value(t, version(&f.assets, h), 1)
	testing.expect_value(t, version(&f.assets, other), 0)
}
