// `cook daemon --cache <dir> [--definitions <file>] [--link <port>] --root <name>=<dir>...` cooks the dev
// configuration, and then cooks again each time the roots or the definition file change, until it is stopped. With
// --link, it serves the editor the index of the content over the cook link. See docs/content-pipeline.md#cook-daemon.
package cook

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

import cook_link "cinnabar:engine/asset/cook_link"
import format "cinnabar:engine/asset/format"

// After a change, the daemon waits until this many milliseconds pass without another, so a save of several files, or
// a program that writes a file in steps, makes one pass.
SETTLE_MS :: 100

@(private = "file")
Daemon :: struct {
	options:           Cook_Options,
	watcher:           Watcher,
	server:            Server,
	index:             Index,
	// The editor's connection once it said Hello, or 0.
	linked_connection: u64,
}

run_daemon :: proc(parsed: Cook_Options) -> bool {
	d: Daemon
	// Each pass frees the temporary allocator, so the options must live elsewhere.
	d.options = clone_options(parsed)
	lock, locked := lock_cache(d.options.cache)
	if locked == .Held {
		log.errorf("cook: another cook is using %s, such as the daemon of another editor or `just watch`. Stop it, and start this one again.", d.options.cache)
	}
	if locked != .Locked {
		return false
	}
	defer unlock_cache(&lock)

	dirs := make([dynamic]string)
	for root in d.options.roots {
		append(&dirs, root.dir)
	}
	if d.options.definitions != "" {
		// The definition file's directory is watched, so a definition file that `just script-types` writes later, or
		// writes again, cooks the scripts again.
		dir := filepath.dir(d.options.definitions)
		if err := os.make_directory_all(dir); err != nil && err != .Exist {
			log.errorf("cook: %s: %v", dir, err)
			return false
		}
		append(&dirs, dir)
	}
	// A change to an include cooks the shaders that include it again.
	for include in d.options.includes {
		append(&dirs, include)
	}
	watcher_open(&d.watcher, dirs[:]) or_return
	defer watcher_close(&d.watcher)
	if d.options.link != 0 {
		wake :: proc(data: rawptr) {
			watcher_wake((^Watcher)(data))
		}
		server_start(&d.server, d.options.link, wake, &d.watcher) or_return
		context.logger = server_logger(&d.server)
	}
	defer server_stop(&d.server)
	defer index_destroy(&d.index)
	log.infof("cook: watching %s", strings.join(dirs[:], ", ", context.temp_allocator))
	// Previews are of a running editor's unsaved materials, so an earlier editor's are stale.
	clear_previews(d.options)

	daemon_pass(&d)
	for {
		free_all(context.temp_allocator)
		switch watcher_wait(&d.watcher, WAIT_FOREVER) {
		case .Changed:
			settle: for {
				switch watcher_wait(&d.watcher, SETTLE_MS) {
				case .Changed:
				case .Woken:
					handle_messages(&d)
				case .Timeout:
					break settle
				case .Failed:
					return false
				}
			}
			daemon_pass(&d)
		case .Woken:
			handle_messages(&d)
		case .Timeout:
		case .Failed:
			return false
		}
	}
}

// daemon_pass cooks every kind of asset, and updates the index. It logs the problems that changed, says what it
// cooked, and sends the editor what changed. It cooks the assets in force whatever their keys.
@(private = "file")
daemon_pass :: proc(d: ^Daemon, force: map[format.Guid]bool = nil) {
	start := time.tick_now()
	pass := cook(d.options, ALL_KINDS, log_problems = false, force = force)
	next: Index
	index_build(&next, pass, d.options.roots[:])
	changes := index_diff(&d.index, &next)
	// What went away is in the old index, so it stays until the changes are sent.
	defer {
		index_destroy(&d.index)
		d.index = next
	}

	for p in changes.problems {
		for problem in p.problems {
			log_problem({problem.file, int(problem.line), int(problem.column), problem.error, problem.text})
		}
	}
	remove_blobs(d.options, changes.delta.removed, pass.shared)
	elapsed := time.tick_since(start)
	failed := 0
	for a in pass.assets {
		failed += int(a.failed)
	}
	cooked := make([dynamic]cook_link.Cooked_Count, context.temp_allocator)
	parts := make([dynamic]string, context.temp_allocator)
	for count, kind in pass.cooked {
		if count > 0 {
			append(&cooked, cook_link.Cooked_Count{link_kind(kind), u32(count)})
			append(&parts, fmt.tprintf("%d %s", count, kind_plural(kind)))
		}
	}
	if len(parts) > 0 {
		log.infof("cook: cooked %s in %v, generation %d", strings.join(parts[:], ", ", context.temp_allocator), elapsed, pass.generation)
	}
	if d.linked_connection == 0 {
		return
	}
	if index_changed(changes) {
		server_send(&d.server, d.linked_connection, changes.delta)
		for p in changes.problems {
			server_send(&d.server, d.linked_connection, p)
		}
	}
	if changes.shading {
		server_send(&d.server, d.linked_connection, next.shading)
	}
	server_send(
		&d.server,
		d.linked_connection,
		cook_link.Cook_Finished {
			generation = pass.generation,
			cooked = cooked[:],
			failed = u32(failed),
			milliseconds = f32(time.duration_milliseconds(elapsed)),
		},
	)
}

// remove_blobs deletes the blobs of the assets that left the content, so a game that starts later does not load them.
// A game that runs keeps what it has loaded. An asset that only shares its GUID with another keeps its blob, which
// comes back into use when the copy gets a GUID of its own.
@(private = "file")
remove_blobs :: proc(options: Cook_Options, removed: []string, shared: []format.Guid) {
	for guid_text in removed {
		guid, ok := format.guid_parse(guid_text)
		if !ok || slice.contains(shared, guid) {
			continue
		}
		path := fmt.tprintf("%s/%s.blob", config_dir(options), guid_text)
		if err := os.remove(path); err != nil && err != .Not_Exist {
			log.warnf("cook: cannot delete %s: %v", path, err)
		}
	}
}

// An operation's answer, which waits for the pass after the operations.
@(private = "file")
Answer :: struct {
	request: u32,
	result:  cook_link.Operation_Result,
}

// handle_messages handles what the editor sent, and notices when it leaves. After asset operations, it makes a pass,
// so the editor has the changes to the index before the answers.
@(private = "file")
handle_messages :: proc(d: ^Daemon) {
	answers := make([dynamic]Answer, context.temp_allocator)
	force := make(map[format.Guid]bool, context.temp_allocator)
	incoming, connection, dropped := server_take(&d.server)
	defer server_release(incoming)
	if d.linked_connection != 0 && connection != d.linked_connection {
		d.linked_connection = 0
		log.info("cook: the editor disconnected")
	}
	for m in incoming {
		if m.connection != connection {
			continue
		}
		message, ok := cook_link.decode_message(m.header.kind, m.payload, context.temp_allocator)
		if !ok {
			log.warnf("cook: cook link: cannot decode a message of kind %d", m.header.kind)
			continue
		}
		#partial switch msg in message {
		case cook_link.Hello:
			version := cook_link.protocol_version()
			if msg.protocol != version {
				reason := fmt.tprintf("the editor's protocol is %016x and the daemon's is %016x. Rebuild both with just cook editor.", msg.protocol, version)
				server_send(&d.server, connection, cook_link.Refused{reason = reason, protocol = version})
				log.errorf("cook: cook link: %s", reason)
				continue
			}
			roots := make([]cook_link.Root, len(d.options.roots), context.temp_allocator)
			for r, i in d.options.roots {
				roots[i] = {r.name, r.dir}
			}
			// The Welcome and the index go out before the first log line, so the editor has them first.
			server_send(&d.server, connection, cook_link.Welcome{protocol = version, config = "dev", roots = roots, importers = importers(), nodes = node_infos()})
			snapshot, problems := index_snapshot(&d.index)
			server_send(&d.server, connection, snapshot)
			for p in problems {
				server_send(&d.server, connection, p)
			}
			server_send(&d.server, connection, d.index.shading)
			d.linked_connection = connection
			server_log_to_editor(&d.server, true)
			log.infof("cook: linked to %s", msg.editor)
		case cook_link.Cook_Preview:
			if connection != d.linked_connection {
				continue
			}
			server_send(&d.server, connection, preview(d.options, msg), m.header.request)
		case:
			if connection != d.linked_connection {
				log.warnf("cook: cook link: the editor sent a message of kind %d before its Hello", m.header.kind)
				continue
			}
			result, is_operation := run_operation(d.options.roots[:], &d.index, message, &force)
			if !is_operation {
				log.warnf("cook: cook link: the editor sent a message that only the daemon sends: %v", m.header.kind)
				continue
			}
			if result.error != "" {
				log.warnf("cook: %s", result.error)
			}
			append(&answers, Answer{m.header.request, result})
		}
	}
	if dropped > 0 {
		log.warnf("cook: cook link: dropped %d log lines while the editor was slow to read", dropped)
	}
	if len(answers) == 0 {
		return
	}
	daemon_pass(d, force)
	for a in answers {
		server_send(&d.server, d.linked_connection, a.result, a.request)
	}
}

// preview cooks a material that the editor has not saved into the cache's preview area (see cook_preview). Its
// problems go to the editor in the answer, and not to the log: the material editor shows them on its nodes.
@(private = "file")
preview :: proc(options: Cook_Options, msg: cook_link.Cook_Preview) -> cook_link.Preview_Result {
	guid, guid_ok := format.guid_parse(msg.guid)
	if !guid_ok {
		return {error = fmt.tprintf("%q is not a GUID", msg.guid)}
	}
	problems, ok := cook_preview(options, guid, msg.text)
	result := cook_link.Preview_Result {
		problems = make([]cook_link.Problem, len(problems.list), context.temp_allocator),
	}
	for p, i in problems.list {
		result.problems[i] = {p.file, u32(p.line), u32(p.column), p.error, p.text}
	}
	if !ok {
		result.error = "the material did not cook"
		for p in problems.list {
			if p.error {
				result.error = p.text
				break
			}
		}
	}
	return result
}

// clear_previews deletes the preview area of the cache.
@(private = "file")
clear_previews :: proc(options: Cook_Options) {
	dir := fmt.tprintf("%s/preview", config_dir(options))
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return
	}
	for info in infos {
		os.remove(info.fullpath)
	}
}

// importers is what the daemon cooks, for the editor: each kind's extension and import settings.
@(private = "file")
importers :: proc() -> []cook_link.Importer {
	result := make([dynamic]cook_link.Importer, context.temp_allocator)
	for extensions, kind in IMPORTERS {
		settings := import_settings(kind)
		infos := make([]cook_link.Setting_Info, len(settings), context.temp_allocator)
		for s, i in settings {
			infos[i] = {s.key, s.values, s.default, s.description}
		}
		// An importer with several extensions is one entry for each, and the first is the one for new assets.
		for extension in extensions {
			append(&result, cook_link.Importer{kind = link_kind(kind), extension = extension, settings = infos})
		}
	}
	return result[:]
}

clone_options :: proc(options: Cook_Options, allocator := context.allocator) -> Cook_Options {
	result := Cook_Options {
		cache       = strings.clone(options.cache, allocator),
		config      = options.config,
		definitions = strings.clone(options.definitions, allocator),
		link        = options.link,
		dxc         = strings.clone(options.dxc, allocator),
		dxc_version = strings.clone(options.dxc_version, allocator),
		roots       = make([dynamic]Root, 0, len(options.roots), allocator),
		includes    = make([dynamic]string, 0, len(options.includes), allocator),
	}
	for root in options.roots {
		append(&result.roots, Root{strings.clone(root.name, allocator), strings.clone(root.dir, allocator)})
	}
	for include in options.includes {
		append(&result.includes, strings.clone(include, allocator))
	}
	return result
}
