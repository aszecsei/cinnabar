package cook

import "core:os"
import "core:path/filepath"
import "core:testing"

import format "cinnabar:engine/asset/format"

@(test)
pruning_deletes_only_the_blobs_that_no_asset_has :: proc(t: ^testing.T) {
	dir, _ := filepath.join({os.get_env("TEMP", context.temp_allocator), "cinnabar_prune_test"}, context.temp_allocator)
	os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)
	defer os.remove_all(dir)
	kept, _ := format.guid_parse("047ea7c35e4dbfb73d2dac450b79b9a8")
	names := []string{"047ea7c35e4dbfb73d2dac450b79b9a8.blob", "f4fce3144b0e4e5a83a740c243e31011.blob", "generation", "notes.blob"}
	for name in names {
		path, _ := filepath.join({dir, name}, context.temp_allocator)
		testing.expect(t, os.write_entire_file(path, transmute([]byte)string("blob")) == nil)
	}
	live := make(map[format.Guid]bool, context.temp_allocator)
	live[kept] = true
	removed, ok := prune_cache(dir, live)
	testing.expect(t, ok)
	testing.expect_value(t, removed, 1)
	for name, i in names {
		path, _ := filepath.join({dir, name}, context.temp_allocator)
		testing.expectf(t, os.exists(path) == (i != 1), "%s", name)
	}
}
