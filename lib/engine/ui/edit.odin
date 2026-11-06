package ui

import "core:fmt"
import "core:log"
import "core:strings"

import format "cinnabar:engine/asset/format"

// What scripts do to a document, through the Ui library or directly: set attributes, bind values, copy templates and
// take elements out (see docs/ui/design.md#scripts). Each change is kept apart from the nodes, so a rebuild for a new
// version of the document's asset applies it again.

// set_override sets an attribute of the element of an id, over what its document and styles say. It replaces what was
// set on the same attribute before. A string in the value is copied.
set_override :: proc(s: ^State, d: ^Document, id: string, id_hash: u64, attr: format.Ui_Attr, value: format.Ui_Value) {
	// Temporary memory here is the frame's, which the platform frees each frame.
	context.temp_allocator = s.platform.frame_allocator
	if _, found := find_node(d, id); !found && !d.warned_ids[id_hash] {
		log.warnf("ui: %v has no element %s now; what is set on it applies if one comes", d.guid, id)
		d.warned_ids[id_hash] = true
	}
	owned := own_value(s, value)
	for &o in d.overrides {
		if o.id_hash == id_hash && o.attr == attr {
			free_value(s, o.value)
			o.value = owned
			return
		}
	}
	append(&d.overrides, Override{id_hash, attr, owned})
}

// set_attribute parses an attribute's value from text, as a document gives it, and sets it on an element. It gives a
// message of what is wrong, or "".
set_attribute :: proc(s: ^State, d: ^Document, id: string, name: string, text: string) -> string {
	// Temporary memory here is the frame's, which the platform frees each frame.
	context.temp_allocator = s.platform.frame_allocator
	attr, known := format.ui_attr_of(name)
	if !known {
		return fmt.tprintf("%s is not an attribute", name)
	}
	value, message := format.ui_parse_value(attr, text)
	if message != "" {
		return fmt.tprintf("%s %s", name, message)
	}
	set_override(s, d, id, hash_id(id), attr, value)
	return ""
}

// set_binding sets the value of {name} in the document's text.
set_binding :: proc(s: ^State, d: ^Document, name, value: string) {
	for &b in d.bindings {
		if b.name == name {
			if b.value != value {
				delete(b.value, s.allocator)
				b.value = strings.clone(value, s.allocator)
			}
			return
		}
	}
	append(&d.bindings, Binding{strings.clone(name, s.allocator), strings.clone(value, s.allocator)})
}

// add_clone copies a template under an element, as its last child, and gives the copy's id, <template>#<n>, whose
// inner elements' ids are <template>#<n>.<id>. A document that is not built yet copies it when it is. It gives a
// message of what is wrong, or "".
add_clone :: proc(s: ^State, d: ^Document, parent, template: string) -> (id: string, message: string) {
	// Temporary memory here is the frame's, which the platform frees each frame.
	context.temp_allocator = s.platform.frame_allocator
	if !format.ui_valid_id(template) {
		return "", fmt.tprintf("%q is not a template's id", template)
	}
	d.next_clone += 1
	op := Structure_Op {
		kind     = .Add,
		target   = strings.clone(parent, s.allocator),
		template = strings.clone(template, s.allocator),
		id       = fmt.aprintf("%s#%d", template, d.next_clone, allocator = s.allocator),
	}
	if d.built && !instantiate(s, d, op) {
		free_op(s, op)
		if _, found := find_node(d, parent); !found {
			return "", fmt.tprintf("the document has no element %s to add to", parent)
		}
		return "", fmt.tprintf("the document has no template %s", template)
	}
	append(&d.structure, op)
	return op.id, ""
}

// remove_element takes an element out of the document. A template's copy goes, with what was set on it and in it; an
// element of the document stays out until the document is built again from a new version, which a script then
// removes it from again. It gives a message of what is wrong, or "".
remove_element :: proc(s: ^State, d: ^Document, id: string) -> string {
	// Temporary memory here is the frame's, which the platform frees each frame.
	context.temp_allocator = s.platform.frame_allocator
	for op, i in d.structure {
		if op.kind == .Add && op.id == id {
			prefix := fmt.tprintf("%s.", id)
			if n, found := find_node(d, id); found {
				unlink(d, n)
			}
			// What was set on the copy and in it goes with it.
			for j := len(d.overrides) - 1; j >= 0; j -= 1 {
				o := d.overrides[j]
				if n, found := d.ids[o.id_hash]; found && (id_of(d, n) == id || strings.has_prefix(id_of(d, n), prefix)) {
					free_value(s, o.value)
					unordered_remove(&d.overrides, j)
				}
			}
			free_op(s, op)
			ordered_remove(&d.structure, i)
			return ""
		}
	}
	n, found := find_node(d, id)
	if !found {
		return fmt.tprintf("the document has no element %s", id)
	}
	if n == 0 {
		return "the root cannot be removed: set the Ui_Document's visible instead"
	}
	unlink(d, n)
	append(&d.structure, Structure_Op{kind = .Remove, target = strings.clone(id, s.allocator)})
	return ""
}

// text_of is an element's text as it shows: a field's value, or a text's with its bindings' values.
text_of :: proc(s: ^State, d: ^Document, id: string) -> (text: string, ok: bool) {
	// Temporary memory here is the frame's, which the platform frees each frame.
	context.temp_allocator = s.platform.frame_allocator
	n := find_node(d, id) or_return
	node := &d.nodes[n]
	st := cascade(d, n, nil, {})
	// The text that the node inherits nothing of: only its own and what scripts set.
	if node.element == .Field {
		return st.text, true
	}
	if node.element == .Text {
		return expand(d, st.text, s.platform.frame_allocator), true
	}
	if node.element == .Button && node.first_child != NONE && d.nodes[node.first_child].element == .Text {
		return expand(d, cascade(d, node.first_child, nil, {}).text, s.platform.frame_allocator), true
	}
	return "", false
}

// focus_element moves the focus to an element of the document, or takes it away with "".
focus_element :: proc(s: ^State, d: ^Document, id: string) -> string {
	// Temporary memory here is the frame's, which the platform frees each frame.
	context.temp_allocator = s.platform.frame_allocator
	if id == "" {
		set_focus(s, NO_NODE)
		return ""
	}
	n, found := find_node(d, id)
	if !found {
		return fmt.tprintf("the document has no element %s", id)
	}
	set_focus(s, ref(s, d, n))
	s.input.modality = .Keys
	return ""
}
