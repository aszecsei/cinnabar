package cutscene

import "core:hash"
import "core:log"
import "core:math"
import "core:mem"
import "core:slice"

import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// Scope_Id names one cutscene of the tree that an evaluation plays (see docs/cinematics/tracks.md#sub-sequence-tracks):
// 0 for the root, and for a child, a hash of the IDs of the sub-sequence sections on the path to it from the root. So
// a reload that keeps those IDs keeps the child's scope, and one shot that two sections play is two scopes.
Scope_Id :: distinct u64

// Scoped is the ID of a track, a section or an event in one scope of the tree. The state that an evaluation keeps for
// each track, section or event is keyed by it.
Scoped :: struct {
	scope: Scope_Id,
	id:    u32,
}

// Child is a cutscene that a sub-sequence section plays, in the tree under an evaluation. It has no lifecycle of its
// own: its tracks are tracks of the evaluation, at the time that its section maps the parent's time to. The player loads
// it, the assets that it references, and its bindings with its parent's. children is in depth-first order, so a child's
// parent comes before it.
Child :: struct {
	scope:      Scope_Id,
	// Its parent: 0 for the root, and n for children[n - 1].
	parent:     int,
	// The sub-sequence track and section that play it, by their indexes in the parent's blob.
	track:      u32,
	section:    u32,
	cutscene:   asset.Handle,
	// The assets that its blob references, loaded for it.
	references: [dynamic]asset.Handle,
	// Its bindings. One that its section maps to a binding of the parent is Binding_Mapped.
	bindings:   Bindings,
	// Whether its spawned bindings show: while its section covers the time.
	shown:      bool,
}

// tree_binding is the entity of a binding of one cutscene of the tree, by its index in that cutscene's blob, while it
// is alive. A child's binding that its section maps is its parent's binding. child is 0 for the root, and n for
// children[n - 1].
tree_binding :: proc(e: ^Evaluation, w: ^ecs.World, child: int, index: u32) -> (ecs.Entity, bool) {
	at, binding := child, index
	for _ in 0 ..= format.CUTSCENE_MAX_DEPTH {
		if at <= 0 || at > len(e.children) {
			return binding_entity(&e.bindings, w, int(binding))
		}
		c := &e.children[at - 1]
		if int(binding) >= len(c.bindings.states) {
			return 0, false
		}
		mapped, is_mapped := c.bindings.states[binding].(Binding_Mapped)
		if !is_mapped {
			return binding_entity(&c.bindings, w, int(binding))
		}
		at, binding = c.parent, mapped.parent
	}
	return 0, false
}

// Scope_View is one cutscene of the tree with its blob: child is 0 for the root, and n for children[n - 1].
Scope_View :: struct {
	child: int,
	scope: Scope_Id,
	data:  []byte,
	blob:  ^format.Cutscene_Blob,
}

// tree_views is the root, with its blob, and each child whose blob is loaded and checks, parents before their children,
// in frame memory.
tree_views :: proc(
	s: ^State,
	e: ^Evaluation,
	w: ^ecs.World,
	data: []byte,
	blob: ^format.Cutscene_Blob,
) -> []Scope_View {
	views := make([dynamic]Scope_View, 0, 1 + len(e.children), w.platform.frame_allocator)
	append(&views, Scope_View{0, 0, data, blob})
	for c, i in e.children {
		if d, b, ok := child_blob(s, e, i + 1); ok {
			append(&views, Scope_View{i + 1, c.scope, d, b})
		}
	}
	return views[:]
}

// child_blob is the checked blob of children[child - 1], and false when it is not loaded or does not check.
child_blob :: proc(
	s: ^State,
	e: ^Evaluation,
	child: int,
) -> (
	data: []byte,
	blob: ^format.Cutscene_Blob,
	ok: bool,
) {
	if child <= 0 || child > len(e.children) || s == nil {
		return
	}
	data = asset.data(s.assets, e.children[child - 1].cutscene) or_return
	blob = format.cutscene_view(data) or_return
	return data, blob, true
}

// scope_blob is the blob of one cutscene of the tree: the root's, given, for 0, and a child's for n.
scope_blob :: proc(
	s: ^State,
	e: ^Evaluation,
	child: int,
	root_data: []byte,
	root: ^format.Cutscene_Blob,
) -> (
	data: []byte,
	blob: ^format.Cutscene_Blob,
	ok: bool,
) {
	if child == 0 {
		return root_data, root, true
	}
	return child_blob(s, e, child)
}

// writer_finish is the when_finished setting of a track of the tree, by its scope and ID, and false when no view's
// blob has it.
@(private)
writer_finish :: proc(
	views: []Scope_View,
	track: Scoped,
) -> (
	finish: format.Cutscene_Finish,
	found: bool,
) {
	for view in views {
		if view.scope != track.scope {
			continue
		}
		for tr in format.cutscene_tracks(view.data, view.blob) {
			if tr.id == track.id {
				return tr.finish, true
			}
		}
	}
	return
}

// tree_key is a key of the blobs of the tree: the root's key, folded with each child's while it is loaded. A reload of
// any of them changes it.
@(private)
tree_key :: proc(s: ^State, e: ^Evaluation, blob: ^format.Cutscene_Blob) -> u64 {
	key := blob.header.key
	for i in 1 ..= len(e.children) {
		_, child, ok := child_blob(s, e, i)
		fold := child.header.key if ok else 0
		key = (key ~ fold) * 0x100000001b3 + u64(i)
	}
	return key
}

// tree_orders is the order in the tree of each track of one cutscene of it, by the track's index in its blob: the
// blobs' orders, with each child's tracks in its sub-sequence track's place, depth first. In frame memory.
@(private)
tree_orders :: proc(
	s: ^State,
	e: ^Evaluation,
	w: ^ecs.World,
	data: []byte,
	blob: ^format.Cutscene_Blob,
	child: int,
) -> []u32 {
	Walk :: struct {
		s:      ^State,
		e:      ^Evaluation,
		want:   int,
		next:   u32,
		orders: []u32,
	}
	visit :: proc(walk: ^Walk, at: int, data: []byte, blob: ^format.Cutscene_Blob, depth: int) {
		tracks := format.cutscene_tracks(data, blob)
		if at == walk.want {
			walk.orders = make([]u32, len(tracks), context.temp_allocator)
		}
		for track, i in tracks {
			if at == walk.want {
				walk.orders[i] = walk.next
			}
			walk.next += 1
			if track.kind != .Sub_Sequence || depth >= format.CUTSCENE_MAX_DEPTH {
				continue
			}
			for c, j in walk.e.children {
				if c.parent != at || c.track != u32(i) {
					continue
				}
				if d, b, ok := child_blob(walk.s, walk.e, j + 1); ok {
					visit(walk, j + 1, d, b, depth + 1)
				}
			}
		}
	}
	context.temp_allocator = w.platform.frame_allocator
	walk := Walk {
		s    = s,
		e    = e,
		want = child,
	}
	visit(&walk, 0, data, blob, 0)
	return walk.orders
}

// open_children loads the cutscenes that the blob's sub-sequence sections play, and theirs, depth first, into the
// evaluation's children: each one's blob, the assets that it references, its sounds, and its bindings, with those that
// its section maps given to the parent's. A muted sub-sequence track plays nothing. A cycle, or a nesting deeper than
// CUTSCENE_MAX_DEPTH, which the cook refuses, fails here too. On a failure, what it loaded stays in the children for
// close_children.
@(private)
open_children :: proc(
	s: ^State,
	c: Player_Context,
	e: ^Evaluation,
	data: []byte,
	blob: ^format.Cutscene_Blob,
) -> Maybe(Failure) {
	path: [format.CUTSCENE_MAX_DEPTH + 1]format.Guid
	path[0] = asset.guid(s.assets, e.cutscene)
	return open_level(s, c, e, 0, 0, data, blob, &path, 1)
}

@(private = "file")
open_level :: proc(
	s: ^State,
	c: Player_Context,
	e: ^Evaluation,
	parent: int,
	parent_scope: Scope_Id,
	data: []byte,
	blob: ^format.Cutscene_Blob,
	path: ^[format.CUTSCENE_MAX_DEPTH + 1]format.Guid,
	depth: int,
) -> Maybe(Failure) {
	w := c.world
	sections := format.cutscene_sections(data, blob)
	for track, i in format.cutscene_tracks(data, blob) {
		if track.kind != .Sub_Sequence || .Muted in track.flags {
			continue
		}
		for j in 0 ..< track.section_count {
			index := track.first_section + j
			section := sections[index]
			guid := section.asset
			if depth > format.CUTSCENE_MAX_DEPTH || slice.contains(path[:depth], guid) {
				log.errorf(
					"cutscene: %s: its sub-sequences nest past %d, or reach a cutscene that plays them",
					format.blob_string(data, blob.source_path),
					format.CUTSCENE_MAX_DEPTH,
				)
				return Asset_Failure{guid, .Bad_Nesting}
			}
			handle, loaded := asset.load(s.assets, guid)
			if !loaded {
				return Asset_Failure{guid, .Reference_Missing}
			}
			append(
				&e.children,
				Child {
					scope = scope_of(parent_scope, section.id),
					parent = parent,
					track = u32(i),
					section = index,
					cutscene = handle,
					references = make([dynamic]asset.Handle, w.platform.heap_allocator),
				},
			)
			at := len(e.children)
			child_data, _ := asset.data(s.assets, handle)
			child, is_cutscene := format.cutscene_view(child_data)
			references, checked := format.blob_references(child_data, w.platform.frame_allocator)
			if !is_cutscene || !checked {
				return Asset_Failure{guid, .Not_A_Cutscene}
			}
			for r in references {
				reference, ok := asset.load(s.assets, r)
				if !ok {
					return Asset_Failure{r, .Reference_Missing}
				}
				append(&e.children[at - 1].references, reference)
			}
			prepare_sounds(s, child_data, child)
			r := Resolve {
				world   = w,
				scenes  = c.scenes,
				scripts = c.scripts,
				assets  = s.assets,
				data    = child_data,
				blob    = child,
				mapped  = mappings_of(e, w, parent, data, blob, index, child_data, child),
			}
			if failure, failed := resolve_bindings(&e.children[at - 1].bindings, r).?; failed {
				failure.cutscene = guid
				return failure
			}
			path[depth] = guid
			scope := e.children[at - 1].scope
			if failure := open_level(s, c, e, at, scope, child_data, child, path, depth + 1);
			   failure != nil {
				return failure
			}
		}
	}
	return nil
}

// mappings_of is, for each binding of a child, the parent's binding that the child's section maps it to, in frame
// memory. A map of a binding that the child no longer has, after a reload of the child alone, is left out, with a
// warning, and the binding resolves on its own.
@(private = "file")
mappings_of :: proc(
	e: ^Evaluation,
	w: ^ecs.World,
	parent: int,
	data: []byte,
	blob: ^format.Cutscene_Blob,
	section: u32,
	child_data: []byte,
	child: ^format.Cutscene_Blob,
) -> []Maybe(Mapping) {
	bindings := format.cutscene_bindings(child_data, child)
	mapped := make([]Maybe(Mapping), len(bindings), w.platform.frame_allocator)
	for m in format.cutscene_section_maps(data, blob, section) {
		index, found := binding_index(child_data, child, Binding_Id(m.child))
		if !found {
			log.warnf(
				"cutscene: %s: its sub-sequence %s has no binding %d to map",
				format.blob_string(data, blob.source_path),
				format.blob_string(child_data, child.source_path),
				m.child,
			)
			continue
		}
		entity, _ := tree_binding(e, w, parent, m.parent)
		mapped[index] = Mapping{m.parent, entity}
	}
	return mapped
}

// scope_of is the scope of a child that a section of a parent's scope plays: a hash of the parent's scope and the
// section's ID, never 0, which is the root's.
@(private)
scope_of :: proc(parent: Scope_Id, section: u32) -> Scope_Id {
	h := u64(parent) ~ 0xcbf29ce484222325
	for b in transmute([4]u8)section {
		h = (h ~ u64(b)) * 0x100000001b3
	}
	h = (h ~ (h >> 29)) * 0xbf58476d1ce4e5b9
	return Scope_Id(h) if h != 0 else 1
}

// close_children releases the children's bindings, which despawns what they spawned, unloads their blobs and the
// assets that they reference, and forgets them. It gives how many spawned roots it despawned.
@(private)
close_children :: proc(s: ^State, w: ^ecs.World, e: ^Evaluation) -> (despawned: int) {
	for &c in e.children {
		despawned += release_bindings(&c.bindings, w)
		destroy_bindings(&c.bindings, w)
		asset.unload(s.assets, c.cutscene)
		for h in c.references {
			asset.unload(s.assets, h)
		}
		delete(c.references)
	}
	clear(&e.children)
	return
}

// children_shape is a hash of what the tree's children are loaded and resolved from: each blob's bindings and the
// assets that it plays, and each sub-sequence section that plays a child, with its cutscene and its maps. A reload that
// changes it loads the children again. A reload that changes only tracks keeps them.
@(private)
children_shape :: proc(
	s: ^State,
	e: ^Evaluation,
	data: []byte,
	blob: ^format.Cutscene_Blob,
) -> u64 {
	Walk :: struct {
		s: ^State,
		e: ^Evaluation,
		h: u64,
	}
	fold :: proc(walk: ^Walk, bytes: []byte) {
		walk.h = hash.fnv64a(bytes, walk.h)
	}
	visit :: proc(walk: ^Walk, at: int, data: []byte, blob: ^format.Cutscene_Blob, depth: int) {
		for b in format.cutscene_bindings(data, blob) {
			b := b
			b.name = {}
			fold(walk, mem.ptr_to_bytes(&b))
		}
		fold(walk, format.blob_bytes(data, blob.guids))
		sections := format.cutscene_sections(data, blob)
		for track, i in format.cutscene_tracks(data, blob) {
			if format.cutscene_track_asset(track.kind) != .None {
				for section in sections[track.first_section:][:track.section_count] {
					guid := section.asset
					fold(walk, mem.ptr_to_bytes(&guid))
				}
			}
			if track.kind != .Sub_Sequence || depth >= format.CUTSCENE_MAX_DEPTH {
				continue
			}
			muted := .Muted in track.flags
			fold(walk, mem.ptr_to_bytes(&muted))
			for j in 0 ..< track.section_count {
				index := track.first_section + j
				id := sections[index].id
				fold(walk, mem.ptr_to_bytes(&id))
				fold(walk, mem.slice_to_bytes(format.cutscene_section_maps(data, blob, index)))
				for c, k in walk.e.children {
					if c.parent == at && c.track == u32(i) && c.section == index {
						if d, b, ok := child_blob(walk.s, walk.e, k + 1); ok {
							visit(walk, k + 1, d, b, depth + 1)
						}
					}
				}
			}
		}
	}
	walk := Walk {
		s = s,
		e = e,
		h = hash.fnv64a(nil),
	}
	visit(&walk, 0, data, blob, 0)
	return walk.h
}

// MAX_WRAPS is the most loops of a sub-sequence whose events one evaluation sends, so a long frame of a short loop
// sends each event a bounded number of times, as MAX_MARKER_LOOPS bounds a clip's markers.
MAX_WRAPS :: 16

// Trim is the span of its child's time that a sub-sequence section plays: [start, end), which it loops or holds at its
// end. trim_of finds it in the child's range.
Trim :: struct {
	start, end: i32,
}

// trim_of is a sub-sequence section's trim in its child: from its offset, clamped into the child's range, to its
// trim_end, or to the end of the child's range when trim_end is 0. A child that a reload shortened still plays inside
// its range.
trim_of :: proc(section: format.Cutscene_Section, child: ^format.Cutscene_Blob) -> Trim {
	start := clamp(section.offset, child.range_start, child.range_end)
	end := section.trim_end if section.trim_end != 0 else child.range_end
	return {start, clamp(end, start, child.range_end)}
}

// child_time maps a time on a parent's time to the time of the child that a sub-sequence section plays (see
// docs/cinematics/tracks.md#sub-sequence-tracks): child_t = trim.start + (t - section.start) × scale, in whole ticks,
// wrapped into the trim when the section loops, and held at the trim's end when it does not. A time before the section
// maps to its start, and one after it to its end. loops is how many times the trim wrapped before the time. It is the
// one place that maps a parent's time to a child's: every track of the child evaluates at it.
child_time :: proc(
	section: format.Cutscene_Section,
	trim: Trim,
	t: i64,
) -> (
	child: i64,
	loops: i64,
) {
	local := clamp(t, i64(section.start), i64(section.end)) - i64(section.start)
	span := i64(math.floor(f64(local) * f64(section.speed)))
	length := i64(trim.end) - i64(trim.start)
	if length <= 0 {
		return i64(trim.start), 0
	}
	if .Loop not_in section.flags {
		return min(i64(trim.start) + span, i64(trim.end)), 0
	}
	loops = span / length
	child = i64(trim.start) + span % length
	// At the section's end, a loop that ends there shows the trim's end, not its start.
	if loops > 0 && span % length == 0 && t >= i64(section.end) {
		return i64(trim.end), loops - 1
	}
	return
}

// Child_Range is a parent's event range (from, to] on a child's time: the segment of each loop that it crosses, in
// order. A range that wraps has more than one, and the child's time jumped back in it.
Child_Range :: struct {
	segments: [MAX_WRAPS + 1][2]i64,
	count:    int,
}

// child_range maps a parent's event range (from, to] to the child's time. A range that does not meet the section's span
// [start, end] maps to none. One that enters the section starts just before the trim's start, so an event there fires.
// A loop's wrap ends a segment at the trim's end and starts the next just before the trim's start, as a clip's markers
// do. Past MAX_WRAPS wraps, the loops between are left out.
child_range :: proc(
	section: format.Cutscene_Section,
	trim: Trim,
	from, to: i64,
) -> (
	r: Child_Range,
) {
	if to <= from || to < i64(section.start) || from >= i64(section.end) {
		return
	}
	cf, kf := child_time(section, trim, from)
	if from < i64(section.start) {
		cf, kf = i64(trim.start) - 1, 0
	}
	ct, kt := child_time(section, trim, to)
	if kt <= kf {
		r.segments[0] = {cf, max(ct, cf)}
		r.count = 1
		return
	}
	r.segments[0] = {cf, i64(trim.end)}
	r.count = 1
	for k := kf + 1; k < kt && r.count < MAX_WRAPS; k += 1 {
		r.segments[r.count] = {i64(trim.start) - 1, i64(trim.end)}
		r.count += 1
	}
	r.segments[r.count] = {i64(trim.start) - 1, ct}
	r.count += 1
	return
}

// child_context is the context of a child's tracks under a parent's context: the child's blob, scope and bindings, the
// parent's time and event range mapped to the child's, its trim as its range, and what the section gives: its weight
// over the parent's, whether it covers the time, and its scale over the parent's rate. The event range is the last
// segment of the parent's, and wraps says how many segments came before it. False when the child's blob is not loaded.
child_context :: proc(
	s: ^State,
	parent: ^Track_Context,
	child: int,
) -> (
	ctx: Track_Context,
	segments: Child_Range,
	ok: bool,
) {
	e := parent.evaluation
	c := e.children[child - 1]
	data, blob := child_blob(s, e, child) or_return
	section := format.cutscene_sections(parent.data, parent.blob)[c.section]
	trim := trim_of(section, blob)
	t, _ := child_time(section, trim, i64(parent.time))
	at, covers := sample_section(parent, section, parent.time)
	segments = child_range(section, trim, parent.from, parent.to)
	ctx = parent^
	ctx.data, ctx.blob = data, blob
	ctx.scope, ctx.child = c.scope, child
	ctx.range_start, ctx.range_end = trim.start, trim.end
	ctx.time = i32(t)
	ctx.covered = covers
	ctx.weight = at.weight if covers else 0
	ctx.rate = parent.rate * f64(section.speed)
	ctx.from, ctx.to = i64(ctx.time), i64(ctx.time)
	if segments.count > 0 {
		last := segments.segments[segments.count - 1]
		ctx.from, ctx.to = last[0], last[1]
	}
	ctx.wrapped = parent.wrapped || segments.count > 1
	// The child's time is the parent's time in the section, which is the section's end once the child holds there.
	ctx.anchor = root_time(parent, f64(clamp(parent.time, section.start, section.end)))
	ctx.seek = nil
	if seek, sought := parent.seek.?; sought {
		mapped := child_range(section, trim, seek.from, seek.to)
		if mapped.count > 0 {
			ctx.seek = Seek_Range{mapped.segments[0][0], mapped.segments[mapped.count - 1][1]}
		}
	}
	return ctx, segments, true
}

// scope_context is the context of one cutscene of the tree under the root's context, mapped through each sub-sequence
// section on the path to it. False when a blob on the path is not loaded.
scope_context :: proc(
	s: ^State,
	root: ^Track_Context,
	child: int,
) -> (
	ctx: Track_Context,
	ok: bool,
) {
	if child == 0 {
		return root^, true
	}
	if child < 0 || child > len(root.evaluation.children) {
		return
	}
	parent := scope_context(s, root, root.evaluation.children[child - 1].parent) or_return
	ctx, _ = child_context(s, &parent, child) or_return
	return ctx, true
}

// Walk_Pass is which tracks of the tree a pass of run_phase evaluates.
@(private)
Walk_Pass :: enum u8 {
	// The tracks of children whose sub-sequence sections do not cover the time, which write their fields' own values.
	Uncovered,
	// The root's tracks, and those of children whose sections cover the time, in the tree's order, so they win a field
	// that an uncovered child also writes.
	Covered,
	// Only event tracks, over a segment of a loop that wrapped before the range's last.
	Events,
}

// walk_scope evaluates the tracks of one cutscene of the tree in a phase, in its blob's order, with each child's tracks
// in its sub-sequence track's place, and gives the order that the next track takes. A pass evaluates only its tracks,
// but every pass counts every track, so a track's order is the same in each.
@(private)
walk_scope :: proc(
	s: ^State,
	ctx: ^Track_Context,
	phase: Phase,
	pass: Walk_Pass,
	order: u32,
) -> u32 {
	e := ctx.evaluation
	next := order
	for track, i in format.cutscene_tracks(ctx.data, ctx.blob) {
		ctx.track = track
		ctx.track_index = u32(i)
		ctx.order = next
		next += 1
		if track.kind == .Sub_Sequence {
			for c, k in e.children {
				if c.parent != ctx.child || c.track != u32(i) {
					continue
				}
				inner, segments, ok := child_context(s, ctx, k + 1)
				if !ok {
					continue
				}
				// The segments of the loops before the last send their events, and nothing else evaluates there.
				if pass != .Uncovered {
					length := f64(inner.range_end - inner.range_start)
					for segment, j in segments.segments[:max(segments.count - 1, 0)] {
						early := inner
						early.from, early.to = segment[0], segment[1]
						early.seek = nil
						if inner.rate > 0 {
							early.anchor -= f64(segments.count - 1 - j) * length / inner.rate
						}
						walk_scope(s, &early, phase, .Events, next)
					}
				}
				next = walk_scope(s, &inner, phase, pass, next)
			}
			continue
		}
		kind := s.kinds[track.kind]
		if .Muted in track.flags || kind.evaluate == nil || kind.phase != phase {
			continue
		}
		evaluates: bool
		switch pass {
		case .Uncovered:
			evaluates = ctx.child != 0 && !ctx.covered
		case .Covered:
			evaluates = ctx.child == 0 || ctx.covered
		case .Events:
			evaluates = track.kind == .Event
		}
		if evaluates && track.kind != .Camera_Cut {
			ctx.user = kind.data
			kind.evaluate(ctx)
		}
	}
	return next
}

// show_children shows the spawned entities of each child whose sub-sequence section covers the evaluation's time, and
// hides those of the others, so a shot's spawned entities are there while its section is, and not between. They spawn
// once, when the player loads, and stay through the loops of a section. The player calls it in its update, outside the
// systems, and as it begins to play.
@(private)
show_children :: proc(s: ^State, w: ^ecs.World, e: ^Evaluation) {
	if len(e.children) == 0 {
		return
	}
	data, blob, ok := cutscene_data(s, e)
	if !ok {
		return
	}
	root := root_context(s, e, w, data, blob)
	for &c, k in e.children {
		inner, found := scope_context(s, &root, k + 1)
		shown := found && inner.covered
		if shown == c.shown {
			continue
		}
		if shown {
			reveal_bindings(&c.bindings, w)
		} else {
			conceal_bindings(&c.bindings, w)
		}
		c.shown = shown
	}
}

// root_context is a context of the root at the evaluation's time with an empty event range, for what reads the tree at
// a time outside the phases.
@(private)
root_context :: proc(
	s: ^State,
	e: ^Evaluation,
	w: ^ecs.World,
	data: []byte,
	blob: ^format.Cutscene_Blob,
) -> Track_Context {
	return {
		world = w,
		cutscenes = s,
		evaluation = e,
		data = data,
		blob = blob,
		root = blob,
		clock = blob.clock,
		range_start = blob.range_start,
		range_end = blob.range_end,
		weight = 1,
		covered = true,
		rate = 1,
		time = e.time,
		from = i64(e.time),
		to = i64(e.time),
		anchor = f64(e.time),
	}
}
