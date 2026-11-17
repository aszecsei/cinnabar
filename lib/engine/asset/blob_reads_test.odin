package asset

import "core:fmt"
import "core:os"
import "core:slice"
import "core:testing"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/lz4"
import format "cinnabar:engine/asset/format"

// A fake of the host's reads across frames, one for each test thread: it reads a file's range when it begins, and holds
// the result as Pending while hold is set.
@(private = "file")
Reads_Fake :: struct {
	reads: [8]struct {
		open:    bool,
		pending: bool,
		data:    []byte,
		ok:      bool,
	},
	hold:  bool,
	open:  int,
}

@(private = "file")
@(thread_local)
fake: Reads_Fake

@(private = "file")
use_fake_reads :: proc(f: ^Fixture) {
	fake = {}
	f.platform.file_size = core.file_size
	f.platform.file_read_begin = proc(path: string, offset: i64, size: int) -> core.File_Read {
		for &read, i in fake.reads {
			if read.open {
				continue
			}
			data := make([]byte, size)
			ok := core.file_read_range(path, offset, data) == size
			read = {
				open    = true,
				pending = fake.hold,
				data    = data,
				ok      = ok,
			}
			fake.open += 1
			return core.File_Read(i + 1)
		}
		return 0
	}
	f.platform.file_read_result = proc(read: core.File_Read) -> ([]byte, core.File_Read_State) {
		if read == 0 || !fake.reads[read - 1].open {
			return nil, .Failed
		}
		r := &fake.reads[read - 1]
		if r.pending {
			return nil, .Pending
		}
		return r.data, r.ok ? .Done : .Failed
	}
	f.platform.file_read_end = proc(read: core.File_Read) {
		if read != 0 && fake.reads[read - 1].open {
			delete(fake.reads[read - 1].data)
			fake.reads[read - 1] = {}
			fake.open -= 1
		}
	}
}

@(private = "file")
reads_blob :: proc(guid: format.Guid, key: u64) -> []byte {
	return format.script_write(
		{
			guid = guid,
			key = key,
			bytecode = {1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8},
			source_path = "x.luau",
		},
		context.temp_allocator,
	)
}

@(private = "file")
reads_bundle :: proc(t: ^testing.T, f: ^Fixture, guid: format.Guid, key: u64, compress: bool) {
	blob := reads_blob(guid, key)
	entry := format.Bundle_Blob {
		guid   = guid,
		kind   = .Script,
		codec  = .None,
		size   = u32(len(blob)),
		stored = blob,
	}
	if compress {
		entry.codec = .Lz4
		entry.stored = lz4.compress(
			blob,
			make([]byte, lz4.bound(len(blob)), context.temp_allocator),
		)
	}
	path := fmt.tprintf("%s/%s%s", f.dir, format.GLOBAL_BUNDLE, format.BUNDLE_EXTENSION)
	testing.expect(
		t,
		os.write_entire_file(path, format.bundle_write({entry}, nil, context.temp_allocator)) ==
		nil,
	)
	destroy(&f.assets)
	init(&f.assets, &f.platform, bundle(f.dir))
}

@(private = "file")
expect_done :: proc(t: ^testing.T, f: ^Fixture, guid: format.Guid, key: u64) {
	read := blob_read_begin(&f.assets, guid)
	_, is_pending := read.(Blob_Read_Pending)
	testing.expect(t, is_pending)
	data, state := blob_read_poll(&f.assets, &read, context.allocator)
	defer delete(data)
	testing.expect_value(t, state, Blob_Read_State.Done)
	testing.expect(t, uintptr(raw_data(data)) % format.BLOB_ALIGN == 0)
	testing.expect(t, slice.equal(data, reads_blob(guid, key)))
	testing.expect_value(t, fake.open, 0)
	blob_read_end(&f.assets, &read)
	_, state = blob_read_poll(&f.assets, &read, context.allocator)
	testing.expect_value(t, state, Blob_Read_State.Failed)
}

@(test)
a_loose_blob_reads_across_polls :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	use_fake_reads(f)
	guid := test_guid(1)
	write_blob(t, f, guid, 7, time.now())
	fake.hold = true
	read := blob_read_begin(&f.assets, guid)
	_, state := blob_read_poll(&f.assets, &read, context.allocator)
	testing.expect_value(t, state, Blob_Read_State.Pending)
	fake.hold = false
	for &r in fake.reads {
		r.pending = false
	}
	data, done := blob_read_poll(&f.assets, &read, context.allocator)
	defer delete(data)
	testing.expect_value(t, done, Blob_Read_State.Done)
	header, _ := format.blob_header(data)
	testing.expect_value(t, header.key, 7)
	testing.expect_value(t, fake.open, 0)
}

@(test)
a_bundled_blob_stored_as_it_is_reads :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	use_fake_reads(f)
	reads_bundle(t, f, test_guid(2), 2, false)
	expect_done(t, f, test_guid(2), 2)
}

@(test)
a_bundled_blob_that_lz4_stores_decompresses :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	use_fake_reads(f)
	reads_bundle(t, f, test_guid(3), 3, true)
	expect_done(t, f, test_guid(3), 3)
}

@(test)
ending_a_pending_read_cancels_it_and_ending_again_does_nothing :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	use_fake_reads(f)
	write_blob(t, f, test_guid(4), 4, time.now())
	fake.hold = true
	read := blob_read_begin(&f.assets, test_guid(4))
	testing.expect_value(t, fake.open, 1)
	blob_read_end(&f.assets, &read)
	testing.expect_value(t, fake.open, 0)
	blob_read_end(&f.assets, &read)
	testing.expect_value(t, fake.open, 0)
	_, state := blob_read_poll(&f.assets, &read, context.allocator)
	testing.expect_value(t, state, Blob_Read_State.Failed)
	none: Blob_Read
	_, state = blob_read_poll(&f.assets, &none, context.allocator)
	testing.expect_value(t, state, Blob_Read_State.Failed)
}

@(test)
a_blob_with_a_bad_header_or_no_file_fails :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	context.logger = capture_errors(f)
	use_fake_reads(f)
	guid := test_guid(5)
	path := fmt.tprintf(
		"%s/%s.blob",
		f.dir,
		format.guid_format(guid, new([32]u8, context.temp_allocator)),
	)
	testing.expect(t, os.write_entire_file(path, make([]byte, 64, context.temp_allocator)) == nil)
	read := blob_read_begin(&f.assets, guid)
	data, state := blob_read_poll(&f.assets, &read, context.allocator)
	testing.expect_value(t, state, Blob_Read_State.Failed)
	testing.expect(t, data == nil)
	testing.expect_value(t, fake.open, 0)

	// A blob of another GUID fails the same way.
	write_blob(t, f, test_guid(6), 6, time.now(), test_guid(7))
	read = blob_read_begin(&f.assets, test_guid(6))
	_, state = blob_read_poll(&f.assets, &read, context.allocator)
	testing.expect_value(t, state, Blob_Read_State.Failed)
	testing.expect_value(t, fake.open, 0)

	read = blob_read_begin(&f.assets, test_guid(8))
	_, failed := read.(Blob_Read_Failed)
	testing.expect(t, failed)
}
