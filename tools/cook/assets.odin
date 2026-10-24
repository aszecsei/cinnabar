package cook

import "core:crypto"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"

import format "cinnabar:engine/asset/format"

// Asset_Source is a source asset with its .meta file.
Asset_Source :: struct {
	root:      int,
	// Absolute, with forward slashes.
	path:      string,
	// The root's name and the path relative to the root, such as "game/scripts/hello.luau".
	name:      string,
	meta_text: string,
	meta:      format.Meta,
	source:    []byte,
}

// collect_assets reads every file with the extension in the roots, with its .meta file, in path order. An asset
// without a .meta file gets a new GUID, and the cooker writes its .meta file. Files and directories whose names
// start with a dot are skipped.
collect_assets :: proc(roots: []Root, extension: string) -> (assets: []Asset_Source, ok: bool) {
	found := make([dynamic]Asset_Source, context.temp_allocator)
	ok = true
	for root, root_index in roots {
		walker := os.walker_create(root.dir)
		defer os.walker_destroy(&walker)
		for info in os.walker_walk(&walker) {
			if strings.has_prefix(info.name, ".") {
				if info.type == .Directory {
					os.walker_skip_dir(&walker)
				}
				continue
			}
			if info.type != .Regular || !strings.has_suffix(info.name, extension) {
				continue
			}
			path := forward_slashes(strings.clone(info.fullpath, context.temp_allocator))
			a := Asset_Source {
				root = root_index,
				path = path,
				name = fmt.tprintf("%s/%s", root.name, strings.trim_prefix(path, fmt.tprintf("%s/", root.dir))),
			}
			if !read_asset(&a) {
				ok = false
				continue
			}
			append(&found, a)
		}
		if path, err := os.walker_error(&walker); err != nil {
			log.errorf("cook: %s: %v", path, err)
			ok = false
		}
	}
	slice.sort_by(found[:], proc(a, b: Asset_Source) -> bool {return a.path < b.path})
	for i in 1 ..< len(found) {
		for j in 0 ..< i {
			if found[i].meta.guid == found[j].meta.guid {
				log.errorf("cook: %s and %s have the same GUID. Delete the .meta file of the copy.", found[j].path, found[i].path)
				ok = false
			}
		}
	}
	return found[:], ok
}

@(private = "file")
read_asset :: proc(a: ^Asset_Source) -> bool {
	source, err := os.read_entire_file(a.path, context.temp_allocator)
	if err != nil {
		log.errorf("cook: %s: %v", a.path, err)
		return false
	}
	a.source = source
	meta_path := fmt.tprintf("%s%s", a.path, format.META_EXTENSION)
	meta_bytes, meta_err := os.read_entire_file(meta_path, context.temp_allocator)
	if meta_err == .Not_Exist {
		guid: format.Guid
		crypto.rand_bytes(guid[:])
		buffer: [32]u8
		text := fmt.tprintf("# cinnabar asset metadata. Keep this file next to its asset (see docs/content-pipeline.md#identity).\nguid = %s\n", format.guid_format(guid, &buffer))
		if write_err := os.write_entire_file(meta_path, transmute([]byte)text); write_err != nil {
			log.errorf("cook: %s: %v", meta_path, write_err)
			return false
		}
		log.infof("cook: assigned a GUID to %s", a.name)
		meta_bytes = transmute([]byte)text
	} else if meta_err != nil {
		log.errorf("cook: %s: %v", meta_path, meta_err)
		return false
	}
	a.meta_text = string(meta_bytes)
	meta, meta_ok := format.meta_parse(a.meta_text, context.temp_allocator)
	if !meta_ok {
		log.errorf("cook: %s: needs `guid = <32 hex digits>`, and `key = value` lines", meta_path)
		return false
	}
	a.meta = meta
	return true
}

// cooked_key reads the key of a cooked blob. It returns 0 if there is none, or if the blob is of another kind or from
// a cooker with other blob structures.
cooked_key :: proc(output: string, kind: format.Asset_Kind, layout: u64) -> u64 {
	data, err := os.read_entire_file(output, context.temp_allocator)
	if err != nil || len(data) < size_of(format.Blob_Header) {
		return 0
	}
	header: format.Blob_Header
	copy(([^]byte)(&header)[:size_of(header)], data)
	if header.magic != format.BLOB_MAGIC || header.kind != kind || header.layout != layout {
		return 0
	}
	return header.key
}

// write_blob writes a blob to a temporary file and renames it, so the running game never reads a partial blob.
write_blob :: proc(output: string, blob: []byte) -> bool {
	temporary := fmt.tprintf("%s.tmp", output)
	if err := os.write_entire_file(temporary, blob); err != nil {
		log.errorf("cook: %s: %v", temporary, err)
		return false
	}
	if err := os.rename(temporary, output); err != nil {
		log.errorf("cook: %s: %v", output, err)
		return false
	}
	return true
}
