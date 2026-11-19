package ecs

// Child_Link is an entity's place in the hierarchy's lists: the head of its own children, and its place in its
// parent's children. Links are slot indices plus one, and 0 is none. list is the list that the entity is in: 0 for
// none, its parent's slot plus one, or ORPHANS.
@(private)
Child_Link :: struct {
	list, first, prev, next: u32,
}

// ORPHANS is the list of the children whose parent is not alive. It is never a slot plus one, because slots are below
// MAX_ENTITIES.
@(private)
ORPHANS :: max(u32)

// Children_Iterator walks an entity's children, the most recently parented first. Make no structural change while it
// runs.
Children_Iterator :: struct {
	world: ^World,
	next:  u32,
}

// children_iter walks the children of an entity. An entity that is not alive has none.
children_iter :: proc(w: ^World, e: Entity) -> Children_Iterator {
	if live_record(w, e) == nil {
		return {world = w}
	}
	link := child_link(w, entity_index(e))
	return {world = w, next = link.first if link != nil else 0}
}

// children_next gives the next child.
children_next :: proc(it: ^Children_Iterator) -> (child: Entity, ok: bool) {
	if it.next == 0 {
		return 0, false
	}
	index := it.next - 1
	it.next = child_links(it.world)[index].next
	return make_entity(index, records(it.world)[index].generation), true
}

// link_child adds a child to the front of its parent's list, or to the orphans if the parent is not alive. The child
// must not be in a list.
@(private)
link_child :: proc(w: ^World, e: Entity, parent: Entity) {
	index := entity_index(e)
	list := u32(ORPHANS)
	top := index
	if live_record(w, parent) != nil {
		list = entity_index(parent) + 1
		top = max(top, entity_index(parent))
	}
	if !region_commit(&w.child_links, w.platform, int(top + 1) * size_of(Child_Link)) {
		panic("ecs: cannot commit the child lists")
	}
	links := child_links(w)
	head := list_head(w, list)
	links[index].list = list
	links[index].prev = 0
	links[index].next = head^
	if head^ != 0 {
		links[head^ - 1].prev = index + 1
	}
	head^ = index + 1
}

// unlink_child takes a child out of its list, if it is in one.
@(private)
unlink_child :: proc(w: ^World, e: Entity) {
	index := entity_index(e)
	link := child_link(w, index)
	if link == nil || link.list == 0 {
		return
	}
	links := child_links(w)
	if link.prev != 0 {
		links[link.prev - 1].next = link.next
	} else {
		list_head(w, link.list)^ = link.next
	}
	if link.next != 0 {
		links[link.next - 1].prev = link.prev
	}
	link.list = 0
	link.prev = 0
	link.next = 0
}

// orphan_children moves an entity's children to the front of the orphans, so despawn_orphans despawns them. The
// entity is left with none.
@(private)
orphan_children :: proc(w: ^World, e: Entity) {
	link := child_link(w, entity_index(e))
	if link == nil || link.first == 0 {
		return
	}
	links := child_links(w)
	last := link.first
	for child := link.first; child != 0; child = links[child - 1].next {
		links[child - 1].list = ORPHANS
		last = child
	}
	links[last - 1].next = w.orphans
	if w.orphans != 0 {
		links[w.orphans - 1].prev = last
	}
	w.orphans = link.first
	link.first = 0
}

// child_link is the link of a slot, or nil if no link was ever written that far.
@(private = "file")
child_link :: proc "contextless" (w: ^World, index: u32) -> ^Child_Link {
	if int(index + 1) * size_of(Child_Link) > w.child_links.committed {
		return nil
	}
	return &child_links(w)[index]
}

@(private = "file")
child_links :: proc "contextless" (w: ^World) -> [^]Child_Link {
	return ([^]Child_Link)(w.child_links.base)
}

// list_head is the head of a list: a parent's first child, or the first orphan.
@(private = "file")
list_head :: proc "contextless" (w: ^World, list: u32) -> ^u32 {
	if list == ORPHANS {
		return &w.orphans
	}
	return &child_links(w)[list - 1].first
}
