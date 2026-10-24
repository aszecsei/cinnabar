// `cook daemon --cache <dir> [--definitions <file>] --root <name>=<dir>...` cooks the dev configuration, and then cooks
// again each time the roots or the definition file change, until it is stopped. See
// docs/content-pipeline.md#cook-daemon.
package cook

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

// After a change, the daemon waits until this many milliseconds pass without another, so a save of several files, or
// a program that writes a file in steps, makes one pass.
SETTLE_MS :: 100

run_daemon :: proc(parsed: Cook_Options) -> bool {
	// Each pass frees the temporary allocator, so the options must live elsewhere.
	options := clone_options(parsed)
	lock := lock_cache(options.cache) or_return
	defer unlock_cache(&lock)

	dirs := make([dynamic]string)
	for root in options.roots {
		append(&dirs, root.dir)
	}
	if options.definitions != "" {
		// The definition file's directory is watched, so a definition file that `just script-types` writes later, or
		// writes again, cooks the scripts again.
		dir := filepath.dir(options.definitions)
		if err := os.make_directory_all(dir); err != nil && err != .Exist {
			log.errorf("cook: %s: %v", dir, err)
			return false
		}
		append(&dirs, dir)
	}
	watcher: Watcher
	watcher_open(&watcher, dirs[:]) or_return
	defer watcher_close(&watcher)
	log.infof("cook: watching %s", strings.join(dirs[:], ", ", context.temp_allocator))

	for {
		daemon_pass(options)
		free_all(context.temp_allocator)
		if !watcher_wait(&watcher, WAIT_FOREVER) {
			return false
		}
		for watcher_wait(&watcher, SETTLE_MS) {
		}
	}
}

// daemon_pass cooks every kind of asset. It says what it cooked, and is quiet when everything was up to date. Its
// failures report themselves.
daemon_pass :: proc(options: Cook_Options) {
	start := time.tick_now()
	pass := cook(options, ALL_KINDS)
	if pass.cooked[.Script] + pass.cooked[.Scene] == 0 {
		return
	}
	log.infof(
		"cook: %d scripts compiled and %d scenes cooked in %v, generation %d",
		pass.cooked[.Script],
		pass.cooked[.Scene],
		time.tick_since(start),
		pass.generation,
	)
}

clone_options :: proc(options: Cook_Options, allocator := context.allocator) -> Cook_Options {
	result := Cook_Options {
		cache       = strings.clone(options.cache, allocator),
		config      = options.config,
		definitions = strings.clone(options.definitions, allocator),
		roots       = make([dynamic]Root, 0, len(options.roots), allocator),
	}
	for root in options.roots {
		append(&result.roots, Root{strings.clone(root.name, allocator), strings.clone(root.dir, allocator)})
	}
	return result
}
