package ui

import "core:c"
import "core:fmt"

import "cinnabar:core/luau"
import "cinnabar:engine/script"

// The Ui library that scripts see (see docs/ui/design.md#scripts): a document's elements by its entity and their ids.
// A behaviour on the entity gets the document's events, such as on_resume(id) for click="resume".

@(private = "file")
REGISTRY_KEY :: "cinnabar.ui"

@(private = "file")
state_of :: proc(L: ^luau.State) -> ^State {
	luau.getfield(L, luau.REGISTRYINDEX, REGISTRY_KEY)
	s := (^State)(luau.touserdata(L, -1))
	luau.pop(L, 1)
	return s
}

@(private = "file")
check_text :: proc(L: ^luau.State, n: c.int) -> string {
	size: c.size_t
	text := luau.L_checklstring(L, n, &size)
	return string(text[:size])
}

// document_arg is the document of the entity that a binding's first argument is, which raises an error if it has none.
@(private = "file")
document_arg :: proc(L: ^luau.State) -> (^State, ^Document) {
	s := state_of(L)
	e := script.check_entity(L, 1)
	d := document_of(s, e)
	if d == nil {
		script.raise(L, fmt.tprintf("entity %v has no Ui_Document that shows", e))
	}
	return s, d
}

// register_scripts defines the Ui library, which reaches s, and exposes Ui_Document. A game's Register_Proc calls it,
// so init and every reload define them again.
register_scripts :: proc(r: ^script.Runtime, s: ^State) {
	luau.pushlightuserdata(r.L, s)
	luau.setfield(r.L, luau.REGISTRYINDEX, REGISTRY_KEY)
	script.expose(r, Ui_Document, DEFAULT_UI_DOCUMENT)

	script.define(r, "Ui.set", proc(L: ^luau.State) -> c.int {
		s, d := document_arg(L)
		if message := set_attribute(s, d, check_text(L, 2), check_text(L, 3), check_text(L, 4)); message != "" {
			script.raise(L, message)
		}
		return 0
	}, "(entity: Entity, id: string, attribute: string, value: string) -> ()")
	script.define(r, "Ui.set_text", proc(L: ^luau.State) -> c.int {
		s, d := document_arg(L)
		id, text := check_text(L, 2), check_text(L, 3)
		if message := set_attribute(s, d, id, "text", text); message != "" {
			script.raise(L, message)
		}
		return 0
	}, "(entity: Entity, id: string, text: string) -> ()")
	script.define(r, "Ui.set_visible", proc(L: ^luau.State) -> c.int {
		s, d := document_arg(L)
		id := check_text(L, 2)
		luau.L_checktype(L, 3, .BOOLEAN)
		set_override(s, d, id, hash_id(id), .Visible, bool(luau.toboolean(L, 3)))
		return 0
	}, "(entity: Entity, id: string, visible: boolean) -> ()")
	script.define(r, "Ui.focus", proc(L: ^luau.State) -> c.int {
		s, d := document_arg(L)
		id := luau.isnoneornil(L, 2) ? "" : check_text(L, 2)
		if message := focus_element(s, d, id); message != "" {
			script.raise(L, message)
		}
		return 0
	}, "(entity: Entity, id: string?) -> ()")
	script.define(r, "Ui.get_text", proc(L: ^luau.State) -> c.int {
		s, d := document_arg(L)
		if text, ok := text_of(s, d, check_text(L, 2)); ok {
			luau.pushodinstring(L, text)
		} else {
			luau.pushnil(L)
		}
		return 1
	}, "(entity: Entity, id: string) -> string?")
	script.define(r, "Ui.bind", proc(L: ^luau.State) -> c.int {
		s, d := document_arg(L)
		name := check_text(L, 2)
		value: string
		switch {
		case luau.isboolean(L, 3):
			value = luau.toboolean(L, 3) ? "true" : "false"
		case luau.type(L, 3) == .NUMBER:
			value = fmt.tprintf("%v", luau.tonumber(L, 3))
		case:
			value = check_text(L, 3)
		}
		set_binding(s, d, name, value)
		return 0
	}, "(entity: Entity, name: string, value: string | number | boolean) -> ()")
	script.define(r, "Ui.add", proc(L: ^luau.State) -> c.int {
		s, d := document_arg(L)
		id, message := add_clone(s, d, check_text(L, 2), check_text(L, 3))
		if message != "" {
			script.raise(L, message)
		}
		luau.pushodinstring(L, id)
		return 1
	}, "(entity: Entity, parent: string, template: string) -> string")
	script.define(r, "Ui.remove", proc(L: ^luau.State) -> c.int {
		s, d := document_arg(L)
		if message := remove_element(s, d, check_text(L, 2)); message != "" {
			script.raise(L, message)
		}
		return 0
	}, "(entity: Entity, id: string) -> ()")
	script.define(r, "Ui.wants_input", proc(L: ^luau.State) -> c.int {
		luau.pushboolean(L, b32(wants_input(state_of(L))))
		return 1
	}, "() -> boolean")
}
