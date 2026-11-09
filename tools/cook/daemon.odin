// `cook daemon --cache <dir> [--definitions <file>] [--link <port>] --root <name>=<dir>...` cooks the dev
// configuration, and then cooks again each time the roots or the definition file change, until it is stopped. With
// --link, it serves the editor the index of the content over the cook link. See docs/content/daemon-and-operations.md#cook-daemon.
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
import "cinnabar:engine/wire/serve"

// After a change, the daemon waits until this many milliseconds pass without another, so a save of several files, or
// a program that writes a file in steps, makes one pass.
SETTLE_MS :: 100

@(private)
Daemon :: struct {
	options: Cook_Options,
	watcher: Watcher,
	// It owns which editor is linked; the main thread asks it.
	server:  serve.Server,
	index:   Index,
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
	defer unlock(&lock)

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
		serve.start(&d.server, "cook: cook link", d.options.link, write_log, wake, &d.watcher) or_return
		context.logger = serve.logger(&d.server)
	}
	defer serve.stop(&d.server)
	defer index_destroy(&d.index)
	log.infof("cook: watching %s", strings.join(dirs[:], ", ", context.temp_allocator))
	// Previews are of a running editor's unsaved materials, so an earlier editor's are stale.
	clear_previews(d.options)

	// With the last daemon's index, the first pass checks every file's stamp, and reads only what changed meanwhile.
	if index_load(&d.index, d.options) {
		log.infof("cook: loaded the saved index of %d sources", len(d.index.sources))
	}
	daemon_pass(&d, Changed_Everything{})
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
			daemon_pass(&d, watcher_take(&d.watcher, context.temp_allocator))
		case .Woken:
			handle_messages(&d)
		case .Timeout:
		case .Failed:
			return false
		}
	}
}

// daemon_pass cooks every kind of asset, and updates the index. It scans what changed, and carries the rest from the
// last pass's index (see docs/content/daemon-and-operations.md#saved-index). It sends the editor its progress while it
// cooks, logs the problems that changed, says what it cooked, sends the editor what changed, and saves the index when
// it changed. It cooks the assets in force whatever their keys.
@(private)
daemon_pass :: proc(d: ^Daemon, watched: Watch_Changes, force: map[format.Guid]bool = nil) -> (report: Pass_Report) {
	start := time.tick_now()
	progress := Progress {
		data     = d,
		delay    = PROGRESS_DELAY,
		interval = PROGRESS_INTERVAL,
	}
	if serve.linked(&d.server) != 0 {
		// Only the main thread links, so no editor links during the pass. One that leaves gets nothing more.
		progress.report = proc(data: rawptr, p: cook_link.Cook_Progress) {
			d := (^Daemon)(data)
			server_send_linked(&d.server, p)
		}
	}
	pass := cook(d.options, ALL_KINDS, log_problems = false, force = force, progress = progress, saved = &d.index, changes = watched)
	report = pass_report(pass)
	next: Index
	index_build(&next, pass, d.options.roots[:])
	thumbnails_update(&next, &pass, d.options)
	changes := index_diff(&d.index, &next)
	// What went away is in the old index, so it stays until the changes are sent.
	defer {
		index_destroy(&d.index)
		d.index = next
	}
	if index_changed(changes) || changes.shading || len(pass.read) > 0 || next.generation != d.index.generation || !slice.equal(next.files, d.index.files) {
		if !index_write(&next, d.options) {
			log.warnf("cook: cannot save the index in %s, so the next daemon reads every source again", config_dir(d.options))
		}
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
		failed += int(asset_failed(a.result))
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
	if serve.linked(&d.server) == 0 {
		return
	}
	if index_changed(changes) {
		server_send_linked(&d.server, changes.delta)
		for p in changes.problems {
			server_send_linked(&d.server, p)
		}
	}
	if changes.shading {
		server_send_linked(&d.server, next.shading)
	}
	server_send_linked(
		&d.server,
		cook_link.Cook_Finished {
			generation = pass.generation,
			cooked = cooked[:],
			failed = u32(failed),
			milliseconds = f32(time.duration_milliseconds(elapsed)),
		},
	)
	return
}

// Pass_Report is what a daemon's pass did, in the temporary allocator: the sources that it read and the assets that it
// looked at, by path, and what it cooked. The pass itself points into the last index, which the pass frees.
Pass_Report :: struct {
	ok:      bool,
	read:    []string,
	checked: []string,
	cooked:  [format.Asset_Kind]int,
	current: [format.Asset_Kind]int,
}

@(private = "file")
pass_report :: proc(pass: Pass) -> Pass_Report {
	read := make([]string, len(pass.read), context.temp_allocator)
	for path, i in pass.read {
		read[i] = strings.clone(path, context.temp_allocator)
	}
	checked := make([dynamic]string, context.temp_allocator)
	for a in pass.assets {
		if a.carried == nil {
			append(&checked, strings.clone(a.path, context.temp_allocator))
		}
	}
	return {pass.ok, read, checked[:], pass.cooked, pass.current}
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

// handle_messages handles what the editor sent, and notices when it leaves.
@(private)
handle_messages :: proc(d: ^Daemon) {
	taken := serve.take(&d.server)
	defer serve.release(taken)
	handle_taken(d, taken)
}

// handle_taken handles what one take gave. After asset operations, it makes a pass, so the editor has the changes to
// the index before the answers. The connection can close while it runs: the server then drops what goes to it, and
// does not link it.
@(private)
handle_taken :: proc(d: ^Daemon, taken: serve.Taken) {
	answers := make([dynamic]Answer, context.temp_allocator)
	force := make(map[format.Guid]bool, context.temp_allocator)
	connection := taken.connection
	if taken.unlinked {
		log.info("cook: the editor disconnected")
	}
	for m in taken.incoming {
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
			server_send(&d.server, connection, cook_link.Welcome{protocol = version, config = "dev", roots = roots, importers = importers(), nodes = node_infos(), ui_attributes = ui_attribute_infos()})
			snapshot, problems := index_snapshot(&d.index)
			server_send(&d.server, connection, snapshot)
			for p in problems {
				server_send(&d.server, connection, p)
			}
			server_send(&d.server, connection, d.index.shading)
			if !serve.link(&d.server, connection) {
				log.infof("cook: cook link: %s disconnected before it was linked", msg.editor)
				continue
			}
			log.infof("cook: linked to %s", msg.editor)
		case cook_link.Cook_Preview:
			if serve.linked(&d.server) != connection {
				continue
			}
			server_send(&d.server, connection, preview(d, msg), m.header.request)
		case:
			if serve.linked(&d.server) != connection {
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
	if taken.dropped_logs > 0 {
		log.warnf("cook: cook link: dropped %d log lines while the editor was slow to read", taken.dropped_logs)
	}
	if len(answers) == 0 {
		return
	}
	// An operation can move, delete or write anything in the roots, so the pass checks every file's stamp.
	daemon_pass(d, Changed_Everything{}, force)
	for a in answers {
		server_send_linked(&d.server, a.result, a.request)
	}
}

// preview cooks a material, an animation graph or a UI document that the editor has not saved into the cache's preview
// area (see cook_preview, animation_graph_check and ui_check). Its problems go to the editor in the answer, and not to
// the log: the asset's editor shows them on its nodes or elements.
@(private = "file")
preview :: proc(d: ^Daemon, msg: cook_link.Cook_Preview) -> cook_link.Preview_Result {
	guid, guid_ok := format.guid_parse(msg.guid)
	if !guid_ok {
		return {error = fmt.tprintf("%q is not a GUID", msg.guid)}
	}
	problems: Problems
	ok: bool
	failed := "the graph did not cook"
	a, known := d.index.assets[msg.guid]
	path := a.path
	for r in d.options.roots {
		if known && r.name == a.root {
			path = fmt.tprintf("%s/%s", r.dir, a.path)
		}
	}
	name := fmt.tprintf("%s/%s", a.root, a.path)
	switch {
	case known && a.kind == .Animation_Graph:
		problems = animation_graph_check(d.options, guid, msg.text, path, name)
		ok = len(problems.list) == 0
	case known && a.kind == .Ui:
		problems, ok = ui_check(d.options, guid, msg.text, path, name, index_kinds(&d.index))
		failed = "the document did not cook"
	case:
		problems, ok = cook_preview(d.options, guid, msg.text)
	}
	result := cook_link.Preview_Result {
		problems = make([]cook_link.Problem, len(problems.list), context.temp_allocator),
	}
	for p, i in problems.list {
		result.problems[i] = {p.file, u32(p.line), u32(p.column), p.error, p.text}
	}
	if !ok {
		result.error = failed
		for p in problems.list {
			if p.error {
				result.error = p.text
				break
			}
		}
	}
	return result
}

// index_kinds is the kind of each asset in the index by its GUID, in the temporary allocator.
@(private = "file")
index_kinds :: proc(index: ^Index) -> map[format.Guid]format.Asset_Kind {
	kinds := make(map[format.Guid]format.Asset_Kind, len(index.assets), context.temp_allocator)
	for text, a in index.assets {
		guid, valid := format.guid_parse(text)
		if !valid {
			continue
		}
		for k in format.Asset_Kind {
			if k != .None && link_kind(k) == a.kind {
				kinds[guid] = k
				break
			}
		}
	}
	return kinds
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
