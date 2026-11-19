package ecs

import "core:fmt"
import "core:hash"
import "core:log"
import "core:unicode/utf8"

NAME_ID :: Component_Id(7)

// A longer name is cut at a character boundary.
MAX_NAME_LENGTH :: 255
// The most distinct base texts that a world interns. Names that differ only in their _N suffix share one.
MAX_NAMES :: 1 << 16
// The bytes of base text that a world interns.
MAX_NAME_TEXT :: 16 * 1024 * 1024

// A power of two, at most half full.
@(private)
NAME_TABLE_SIZE :: 2 * MAX_NAMES
#assert(NAME_TABLE_SIZE & (NAME_TABLE_SIZE - 1) == 0)
// The index's hash buckets. A power of two.
@(private)
NAME_BUCKETS :: 1 << 17
#assert(NAME_BUCKETS & (NAME_BUCKETS - 1) == 0)

// Name is an entity's name, for people and for find: the outliner, logs, the editor in play mode and scripts. As in
// Unreal's FName, id is an index into the world's table of interned text and number is a suffix, plus one: 0 is no
// suffix, so "Door_12" is {id("Door"), 13}. Component storage holds no pointers, and comparing two names compares
// two integers. Make one with intern, and change an entity's Name only with add and remove, so the index sees it.
Name :: struct {
	id:     u32 `editor:"-"`,
	number: u32 `editor:"-"`,
}

// Default_Name is the names that every world interns first, in this order, so their ids are constants, as Unreal's
// EName. Add a name only at the end: a hot reload cannot renumber the ids that a world already holds.
Default_Name :: enum u32 {
	None = 0,
}

@(rodata)
DEFAULT_NAMES := [Default_Name]string {
	.None = "None",
}

// NAME_NONE is no name. intern gives it for "", and the index never holds it.
NAME_NONE :: Name{}

@(private)
Name_Entry :: struct {
	hash:   u64,
	offset: u32,
	length: u32,
}

// Name_Link is an entity's place in its index bucket's list. Links are slot indices plus one, and 0 is none. bucket is
// the bucket's index plus one, or 0 for an entity that is not in the index, so unlinking does not depend on the Name.
@(private)
Name_Link :: struct {
	prev, next, bucket: u32,
}

@(private)
Name_Bucket :: struct {
	head, tail: u32,
}

// Names is the world's interned text and its index from Name to entities. The text is never freed, so a name's text
// stays valid until destroy, and its id until destroy too, across code reloads. The index chains the named entities
// in NAME_BUCKETS lists, each in the order that they were named.
@(private)
Names :: struct {
	text:      Region,
	text_used: int,
	entries:   Region,
	count:     u32,
	// Open addressing from a base text's hash to its id plus one. Zero is an empty slot.
	table:     Region,
	buckets:   Region,
	// One Name_Link for each entity slot.
	links:     Region,
	// Set when the table is full, so the error is logged once.
	full:      bool,
}

@(private)
names_init :: proc(w: ^World) -> bool {
	n := &w.names
	ok :=
		region_init(&n.text, w.platform, MAX_NAME_TEXT) &&
		region_init(&n.entries, w.platform, MAX_NAMES * size_of(Name_Entry)) &&
		region_init(&n.table, w.platform, NAME_TABLE_SIZE * size_of(u32)) &&
		region_commit(&n.table, w.platform, NAME_TABLE_SIZE * size_of(u32)) &&
		region_init(&n.buckets, w.platform, NAME_BUCKETS * size_of(Name_Bucket)) &&
		region_commit(&n.buckets, w.platform, NAME_BUCKETS * size_of(Name_Bucket)) &&
		region_init(&n.links, w.platform, MAX_ENTITIES * size_of(Name_Link))
	return ok && intern_default_names(w)
}

@(private)
names_regions :: proc(w: ^World) -> [5]^Region {
	n := &w.names
	return {&n.text, &n.entries, &n.table, &n.buckets, &n.links}
}

// intern_default_names interns each Default_Name at its id. After a code reload it checks the ones that the world
// has, and interns new ones at the end if no other name came after the old list.
@(private)
intern_default_names :: proc(w: ^World) -> bool {
	for text, name in DEFAULT_NAMES {
		id := u32(name)
		switch {
		case id < w.names.count:
			if base_text(w, id) != text {
				log.errorf(
					"ecs: the default name %d is %q, but the world has %q there",
					id,
					text,
					base_text(w, id),
				)
				return false
			}
		case id == w.names.count:
			if made, made_ok := intern_base(w, text, true); !made_ok || made != id {
				return false
			}
		case:
			log.errorf(
				"ecs: the default name %q is new, and the world has other names where it goes. Restart to use it.",
				text,
			)
			return false
		}
	}
	return true
}

// intern gives the Name of text, and adds its base to the table if it is new. "" is NAME_NONE. A text longer than
// MAX_NAME_LENGTH is cut at a character boundary, and then a final _N with no leading zero becomes the number. When
// the table is full, it logs an error and gives NAME_NONE.
intern :: proc(w: ^World, text: string) -> Name {
	base, number := split_name(cut_name(text))
	if base == "" {
		return NAME_NONE
	}
	id, ok := intern_base(w, base, true)
	return {id, number} if ok else NAME_NONE
}

// lookup is intern without adding to the table. It gives false for a text that no name has.
lookup :: proc(w: ^World, text: string) -> (Name, bool) {
	base, number := split_name(cut_name(text))
	if base == "" {
		return NAME_NONE, false
	}
	id, ok := intern_base(w, base, false)
	return {id, number}, ok
}

// name_base is the text of a name without its suffix. It points into the table, so it is valid until destroy.
name_base :: proc(w: ^World, n: Name) -> string {
	return base_text(w, n.id)
}

// name_text is the text of a name: its base, and _N for a number. A name without a number points into the table;
// one with a number is made in allocator.
name_text :: proc(w: ^World, n: Name, allocator := context.temp_allocator) -> string {
	base := base_text(w, n.id)
	if n.number == 0 {
		return base
	}
	return fmt.aprintf("%s_%d", base, n.number - 1, allocator = allocator)
}

// name_of is an entity's name, or "" without one or with NAME_NONE. See name_text for where it is.
name_of :: proc(w: ^World, e: Entity, allocator := context.temp_allocator) -> string {
	n := (^Name)(get_raw(w, e, NAME_ID))
	if n == nil || n^ == NAME_NONE {
		return ""
	}
	return name_text(w, n^, allocator)
}

// find gives the active entity that was named text first, or 0. It never adds to the table, and it does not scan:
// it walks the entities whose names share a bucket of the index.
find :: proc(w: ^World, text: string) -> Entity {
	n, ok := lookup(w, text)
	if !ok {
		return 0
	}
	for slot := buckets(w)[name_bucket(n)].head; slot != 0; slot = links(w)[slot - 1].next {
		if e, found := named_entity(w, slot - 1, n); found {
			return e
		}
	}
	return 0
}

// find_all appends the active entities named text to out, in the order that they were named.
find_all :: proc(w: ^World, text: string, out: ^[dynamic]Entity) {
	n, ok := lookup(w, text)
	if !ok {
		return
	}
	for slot := buckets(w)[name_bucket(n)].head; slot != 0; slot = links(w)[slot - 1].next {
		if e, found := named_entity(w, slot - 1, n); found {
			append(out, e)
		}
	}
}

// split_name splits a final _N off a text, where N has digits with no leading zero and is below max(u32). The base
// must not be empty. It gives the number plus one, or 0 when nothing splits off.
split_name :: proc "contextless" (text: string) -> (base: string, number: u32) {
	i := len(text)
	for i > 0 && text[i - 1] >= '0' && text[i - 1] <= '9' {
		i -= 1
	}
	digits := text[i:]
	if len(digits) == 0 || len(digits) > 10 || i < 2 || text[i - 1] != '_' {
		return text, 0
	}
	if len(digits) > 1 && digits[0] == '0' {
		return text, 0
	}
	value: u64
	for c in transmute([]byte)digits {
		value = value * 10 + u64(c - '0')
	}
	if value >= u64(max(u32)) {
		return text, 0
	}
	return text[:i - 1], u32(value + 1)
}

// cut_name cuts a text to MAX_NAME_LENGTH, as intern does, backing off to the start of a character so a cut never
// splits one.
cut_name :: proc "contextless" (text: string) -> string {
	length := min(len(text), MAX_NAME_LENGTH)
	for length < len(text) && length > 0 && !utf8.rune_start(text[length]) {
		length -= 1
	}
	return text[:length]
}

// intern_base finds a base text's id, and adds it if insert is set.
@(private)
intern_base :: proc(w: ^World, base: string, insert: bool) -> (u32, bool) {
	n := &w.names
	h := hash.fnv64a(transmute([]byte)base)
	table := ([^]u32)(n.table.base)
	entries := ([^]Name_Entry)(n.entries.base)
	slot := h & (NAME_TABLE_SIZE - 1)
	for table[slot] != 0 {
		id := table[slot] - 1
		if entries[id].hash == h && base_text(w, id) == base {
			return id, true
		}
		slot = (slot + 1) & (NAME_TABLE_SIZE - 1)
	}
	if !insert {
		return 0, false
	}
	if n.count == MAX_NAMES ||
	   n.text_used + len(base) > MAX_NAME_TEXT ||
	   !region_commit(&n.entries, w.platform, int(n.count + 1) * size_of(Name_Entry)) ||
	   !region_commit(&n.text, w.platform, n.text_used + len(base)) {
		if !n.full {
			log.errorf(
				"ecs: the world has more than %d names or %d bytes of them, so new names are None. Names are never freed.",
				MAX_NAMES,
				MAX_NAME_TEXT,
			)
			n.full = true
		}
		return 0, false
	}
	copy(n.text.base[n.text_used:][:len(base)], base)
	entries[n.count] = {
		hash   = h,
		offset = u32(n.text_used),
		length = u32(len(base)),
	}
	n.text_used += len(base)
	table[slot] = n.count + 1
	n.count += 1
	return n.count - 1, true
}

@(private)
base_text :: proc "contextless" (w: ^World, id: u32) -> string {
	if id >= w.names.count {
		return ""
	}
	e := ([^]Name_Entry)(w.names.entries.base)[id]
	return string(w.names.text.base[e.offset:][:e.length])
}

// check_name makes a Name that raw bytes wrote safe for the index: an id that the table does not have becomes
// NAME_NONE.
@(private)
check_name :: proc(w: ^World, n: ^Name) {
	if n.id >= w.names.count {
		log.errorf("ecs: a Name has the id %d, which the world does not have, so it is None", n.id)
		n^ = NAME_NONE
	}
}

// link_name adds an entity to the end of its name's bucket.
@(private)
link_name :: proc(w: ^World, e: Entity, n: Name) {
	if n == NAME_NONE {
		return
	}
	index := entity_index(e)
	if !region_commit(&w.names.links, w.platform, int(index + 1) * size_of(Name_Link)) {
		panic("ecs: cannot commit the name index")
	}
	which := name_bucket(n)
	bucket := &buckets(w)[which]
	links(w)[index] = {
		prev   = bucket.tail,
		bucket = which + 1,
	}
	if bucket.tail != 0 {
		links(w)[bucket.tail - 1].next = index + 1
	} else {
		bucket.head = index + 1
	}
	bucket.tail = index + 1
}

// unlink_name takes an entity out of its name's bucket, if it is in one.
@(private)
unlink_name :: proc(w: ^World, e: Entity) {
	index := entity_index(e)
	if int(index + 1) * size_of(Name_Link) > w.names.links.committed {
		return
	}
	link := links(w)[index]
	if link.bucket == 0 {
		return
	}
	bucket := &buckets(w)[link.bucket - 1]
	if link.prev != 0 {
		links(w)[link.prev - 1].next = link.next
	} else {
		bucket.head = link.next
	}
	if link.next != 0 {
		links(w)[link.next - 1].prev = link.prev
	} else {
		bucket.tail = link.prev
	}
	links(w)[index] = {}
}

// named_entity is the entity in a linked slot, if it has the name n and is active.
@(private = "file")
named_entity :: proc(w: ^World, index: u32, n: Name) -> (e: Entity, ok: bool) {
	e = slot_entity(w, index) or_return
	if name := (^Name)(get_raw(w, e, NAME_ID)); name == nil || name^ != n {
		return 0, false
	}
	return e, !has_raw(w, e, INACTIVE_ID)
}

@(private = "file")
name_bucket :: proc "contextless" (n: Name) -> u32 {
	key := [2]u32{n.id, n.number}
	return u32(hash.fnv64a(([^]byte)(&key)[:size_of(key)]) & (NAME_BUCKETS - 1))
}

@(private = "file")
buckets :: proc "contextless" (w: ^World) -> [^]Name_Bucket {
	return ([^]Name_Bucket)(w.names.buckets.base)
}

@(private = "file")
links :: proc "contextless" (w: ^World) -> [^]Name_Link {
	return ([^]Name_Link)(w.names.links.base)
}
