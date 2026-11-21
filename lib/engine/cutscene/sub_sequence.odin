package cutscene

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
