package ecs

import "core:unicode/utf8"

NAME_ID :: Component_Id(7)

// A longer name is cut at a character boundary.
MAX_NAME :: 63

// Name is an entity's name, for people: the outliner, logs and the editor in play mode. The text is in the
// component, because component storage holds no pointers. The editor shows and edits it as the entity's name, not
// as fields.
Name :: struct {
	length: u8 `editor:"-"`,
	text:   [MAX_NAME]u8 `editor:"-"`,
}

make_name :: proc "contextless" (text: string) -> Name {
	n: Name
	length := min(len(text), MAX_NAME)
	// Back off to the start of a character, so a cut never splits one.
	for length < len(text) && length > 0 && !utf8.rune_start(text[length]) {
		length -= 1
	}
	n.length = u8(copy(n.text[:], text[:length]))
	return n
}

name_text :: proc "contextless" (n: ^Name) -> string {
	return string(n.text[:n.length])
}

// name_of is an entity's name, or "" without one. It points into component storage, so it is valid until the next
// structural change.
name_of :: proc(w: ^World, e: Entity) -> string {
	n := (^Name)(get_raw(w, e, NAME_ID))
	return name_text(n) if n != nil else ""
}
