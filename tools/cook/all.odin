package cook

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"

import format "cinnabar:engine/asset/format"

// cook_all cooks every kind of asset in one pass, with one scan of the roots, for a project's build (see
// docs/content/identity-and-cooking.md#cooking). With prune, it then deletes the blobs in the cache that no asset in the
// roots has, so a package step after it packs only the content's (see prune_cache).
cook_all :: proc(options: Cook_Options, prune: bool) -> bool {
	lock, locked := lock_cache(options.cache)
	switch locked {
	case .Locked:
	case .Held:
		if options.config == .Dev && !prune {
			log.infof("cook: the cook daemon is running, and keeps %s up to date", config_dir(options))
			return true
		}
		log.errorf("cook: another cook is using %s. Stop the cook daemon (`just watch` or the editor) and cook again.", options.cache)
		return false
	case .Failed:
		return false
	}
	defer unlock(&lock)
	pass := cook(options, ALL_KINDS)
	cooked, current := 0, 0
	for kind in format.Asset_Kind {
		cooked += pass.cooked[kind]
		current += pass.current[kind]
	}
	log.infof("cook: %d assets cooked, %d up to date", cooked, current)
	if !pass.ok {
		return false
	}
	if prune {
		removed, ok := prune_cache(config_dir(options), live_guids(pass))
		log.infof("cook: %d blobs of assets that left the content deleted", removed)
		return ok
	}
	return true
}

// live_guids are the GUIDs that the pass's assets have: each asset's, each sub-asset's that its .meta file or its cook
// names, and those that several assets share, whose blobs come back into use when a copy gets a GUID of its own.
live_guids :: proc(pass: Pass) -> map[format.Guid]bool {
	live := make(map[format.Guid]bool, context.temp_allocator)
	for a in pass.assets {
		live[a.meta.guid] = true
		for sub in a.meta.subassets {
			live[sub.guid] = true
		}
		for sub in a.subassets {
			live[sub.guid] = true
		}
	}
	for guid in pass.shared {
		live[guid] = true
	}
	return live
}

// prune_cache deletes each blob in a loose cache, <guid>.blob, whose GUID is not live. It leaves other files alone.
prune_cache :: proc(cache: string, live: map[format.Guid]bool) -> (removed: int, ok: bool) {
	entries, err := os.read_all_directory_by_path(cache, context.temp_allocator)
	if err != nil {
		log.errorf("cook: %s: %v", cache, err)
		return 0, false
	}
	ok = true
	for entry in entries {
		if entry.type != .Regular || !strings.has_suffix(entry.name, ".blob") {
			continue
		}
		guid, is_guid := format.guid_parse(strings.trim_suffix(entry.name, ".blob"))
		if !is_guid || live[guid] {
			continue
		}
		if remove_err := os.remove(entry.fullpath); remove_err != nil {
			log.errorf("cook: cannot delete %s: %v", entry.fullpath, remove_err)
			ok = false
			continue
		}
		log.debugf("cook: deleted %s", fmt.tprintf("%s/%s", cache, entry.name))
		removed += 1
	}
	return
}
