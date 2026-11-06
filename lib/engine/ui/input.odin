package ui

import "core:slice"
import "core:strings"
import "core:unicode/utf8"

import "cinnabar:core"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

// Navigation repeats while its direction is held: once at once, again after NAV_DELAY seconds, and then every
// NAV_REPEAT. A held key in a field repeats every KEY_REPEAT after the same delay.
NAV_DELAY :: 0.4
NAV_REPEAT :: 0.1
KEY_REPEAT :: 0.033
// A stick points in a direction past STICK_ENGAGE on its axis, and stops past STICK_RELEASE back, so it does not chatter.
STICK_ENGAGE :: 0.5
STICK_RELEASE :: 0.35
// How many modal documents can open over each other, each keeping the focus that was before it.
MAX_FOCUS_STACK :: 8

// Node_Ref is a node of a document, good while the document has not been built again.
Node_Ref :: struct {
	document:   i32,
	node:       u32,
	generation: u32,
}

NO_NODE :: Node_Ref{-1, NONE, 0}

// Modality is how the player last moved: with the pointer, or with keys or a gamepad, which show the focus.
Modality :: enum u8 {
	Pointer,
	Keys,
}

// Pending_Event is an event for a document's entity's behaviours, sent by flush_events. Its strings are in frame memory.
Pending_Event :: struct {
	entity: ecs.Entity,
	name:   string,
	id:     string,
	text:   Maybe(string),
}

Input_State :: struct {
	focus:         Node_Ref,
	focus_stack:   [MAX_FOCUS_STACK]Node_Ref,
	focus_depth:   int,
	// The modal document that showed last frame, or -1.
	modal:         i32,
	hovered:       Node_Ref,
	pressed:       Node_Ref,
	// The focused node is held down by Enter, Space or A.
	key_pressing:  bool,
	modality:      Modality,
	last_mouse:    [2]f32,
	// The direction that navigation holds, and when it next repeats.
	nav_held:      Maybe(Direction),
	nav_next:      f64,
	stick:         Maybe(Direction),
	// The key that a field repeats, and when.
	key_held:      core.Key,
	key_next:      f64,
	// A field that is being edited: its caret and the other end of its selection, in bytes, and how far its text is
	// scrolled, in pixels.
	editing:       bool,
	caret, anchor: u32,
	scroll:        f32,
	// When the caret last moved, which its blink starts from.
	caret_time:    f64,
	// What the IME is composing, and its cursor, this frame, for the field to draw. It points into input.
	composition:   string,
	composition_cursor: int,
	events:        [dynamic]Pending_Event,
	wants_input:   bool,
}

@(private)
init_input :: proc(s: ^State) {
	s.input = {
		focus   = NO_NODE,
		hovered = NO_NODE,
		pressed = NO_NODE,
		modal   = -1,
		events  = make([dynamic]Pending_Event, s.allocator),
	}
}

@(private)
index_of :: proc(s: ^State, d: ^Document) -> i32 {
	return i32((uintptr(d) - uintptr(&s.documents[0])) / size_of(Document))
}

@(private)
ref :: proc(s: ^State, d: ^Document, n: u32) -> Node_Ref {
	return {index_of(s, d), n, d.generation}
}

// resolve gives the document and node of a reference, if it is still good.
@(private)
resolve :: proc(s: ^State, r: Node_Ref) -> (d: ^Document, n: u32, ok: bool) {
	if r.document < 0 || int(r.document) >= MAX_DOCUMENTS {
		return
	}
	d = &s.documents[r.document]
	if !d.used || d.generation != r.generation || int(r.node) >= len(d.nodes) {
		return nil, NONE, false
	}
	return d, r.node, true
}

// node_states are the states that a node is in, for its styles' variants. The focus shows only after keys or a
// gamepad moved it, but a field always shows it, as the player types into it.
@(private)
node_states :: proc(s: ^State, index: int, d: ^Document, n: u32) -> bit_set[format.Ui_State] {
	node := &d.nodes[n]
	disabled := node.style.disabled || (node.parent != NONE && d.nodes[node.parent].disabled)
	if disabled {
		return {.Disabled}
	}
	here := Node_Ref{i32(index), n, d.generation}
	states: bit_set[format.Ui_State]
	if s.input.hovered == here {
		states += {.Hover}
	}
	if s.input.focus == here && (s.input.modality == .Keys || node.element == .Field) {
		states += {.Focus}
	}
	if (s.input.pressed == here && s.input.hovered == here) || (s.input.focus == here && s.input.key_pressing) {
		states += {.Press}
	}
	return states
}

@(private)
focused_id_hash :: proc(s: ^State, d: ^Document) -> u64 {
	if fd, n, ok := resolve(s, s.input.focus); ok && fd == d {
		return d.nodes[n].id_hash
	}
	return 0
}

@(private)
restore_focus :: proc(s: ^State, d: ^Document, id_hash: u64) {
	if id_hash == 0 {
		return
	}
	if n, found := d.ids[id_hash]; found && .Removed not_in d.nodes[n].flags {
		s.input.focus = ref(s, d, n)
	}
}

// forget_document drops what the input holds of a document that goes away.
@(private)
forget_document :: proc(s: ^State, d: ^Document) {
	index := index_of(s, d)
	for r in ([]^Node_Ref{&s.input.focus, &s.input.hovered, &s.input.pressed}) {
		if r.document == index {
			r^ = NO_NODE
		}
	}
	if s.input.modal == index {
		s.input.modal = -1
	}
}

// interactive is whether a node takes the pointer: it clicks or takes focus, and is not disabled.
@(private)
interactive :: proc(node: ^Node) -> bool {
	return !node.disabled && (node.style.focusable || node.style.click != "" || node.element == .Button || node.element == .Field)
}

@(private)
inside :: proc(r: [4]f32, p: [2]f32) -> bool {
	return p.x >= r[0] && p.x < r[2] && p.y >= r[1] && p.y < r[3]
}

// hit is the topmost node under a point that takes the pointer, and whether a node with a fill is under it at all,
// which a modal document blocks with.
@(private)
hit :: proc(d: ^Document, n: u32, p: [2]f32) -> (found: u32, covered: bool) {
	node := &d.nodes[n]
	if !node.shown {
		return NONE, false
	}
	// The children draw over their parent, the last over the first, so they are tried last to first.
	children := make([dynamic]u32, 0, 8, context.temp_allocator)
	for c := node.first_child; c != NONE; c = d.nodes[c].next_sibling {
		append(&children, c)
	}
	for i := len(children) - 1; i >= 0; i -= 1 {
		f, cov := hit(d, children[i], p)
		if f != NONE {
			return f, true
		}
		covered ||= cov
	}
	within := inside(intersect(node.rect, node.clip), p)
	if within && interactive(node) {
		return n, true
	}
	return NONE, covered || (within && node.style.fill.colors[0].a + node.style.fill.colors[1].a > 0)
}

// scope is the documents that take input, the highest order first: a modal document that shows, alone, or every
// document that shows.
@(private)
scope :: proc(s: ^State) -> []i32 {
	// Each document's order and slot, the highest order first, and of one order the later slot, which draws later.
	ordered := make([dynamic][2]i32, 0, MAX_DOCUMENTS, context.temp_allocator)
	for &d, i in s.documents {
		if d.used && d.built && d.visible && len(d.nodes) > 0 && d.nodes[0].shown {
			append(&ordered, [2]i32{d.order, i32(i)})
		}
	}
	slice.sort_by(ordered[:], proc(a, b: [2]i32) -> bool {return a[0] > b[0] || (a[0] == b[0] && a[1] > b[1])})
	list := make([]i32, len(ordered), context.temp_allocator)
	for entry, i in ordered {
		list[i] = entry[1]
	}
	for i in list {
		if s.documents[i].nodes[0].style.modal {
			list[0] = i
			return list[:1]
		}
	}
	return list
}

// focusables are a document's nodes that take focus and show, in the order of the tree.
@(private)
focusables :: proc(d: ^Document, n: u32, out: ^[dynamic]u32) {
	node := &d.nodes[n]
	if !node.shown {
		return
	}
	if node.style.focusable && !node.disabled {
		append(out, n)
	}
	for c := node.first_child; c != NONE; c = d.nodes[c].next_sibling {
		focusables(d, c, out)
	}
}

// initial_focus is the node that a document focuses first: its focus attribute's, or its first that takes focus.
@(private)
initial_focus :: proc(s: ^State, d: ^Document) -> Node_Ref {
	if target := d.nodes[0].style.focus; target != "" {
		if n, found := find_node(d, target); found && d.nodes[n].shown && !d.nodes[n].disabled {
			return ref(s, d, n)
		}
	}
	list := make([dynamic]u32, context.temp_allocator)
	focusables(d, 0, &list)
	if len(list) > 0 {
		return ref(s, d, list[0])
	}
	return NO_NODE
}

@(private)
set_focus :: proc(s: ^State, r: Node_Ref) {
	if s.input.focus != r {
		s.input.editing = false
	}
	s.input.focus = r
}

@(private)
queue_event :: proc(s: ^State, d: ^Document, name: string, id: string, text: Maybe(string) = nil) {
	if name == "" {
		return
	}
	allocator := s.platform.frame_allocator
	e := Pending_Event{entity = d.entity, name = strings.clone(name, allocator), id = strings.clone(id, allocator)}
	if t, has := text.?; has {
		e.text = strings.clone(t, allocator)
	}
	append(&s.input.events, e)
}

// click sends a node's click event, and starts editing a field.
@(private)
click :: proc(s: ^State, d: ^Document, n: u32) {
	node := &d.nodes[n]
	if node.disabled {
		return
	}
	if node.element == .Field {
		s.input.editing = true
		value := node.style.text
		s.input.caret = u32(len(value))
		s.input.anchor = s.input.caret
	}
	queue_event(s, d, node.style.click, id_of(d, n))
}

// handle_input reads a frame's input against the last frame's layout, which is what the player saw: the pointer's
// hover and clicks, navigation by keys and gamepads, cancel, and the editing of fields (see
// docs/ui/design.md#input-and-focus). Its events go out with flush_events. now is the real time, in seconds.
handle_input :: proc(s: ^State, input: core.Input, now: f64) {
	// Temporary memory here is the frame's, which the platform frees each frame.
	context.temp_allocator = s.platform.frame_allocator
	input := input
	in_scope := scope(s)
	update_modal(s, in_scope)
	s.input.wants_input = s.input.modal >= 0 || s.input.editing
	// The composition draws after scripts run, so it is kept in frame memory.
	s.input.composition = strings.clone(core.input_text_string(&input.composition), s.platform.frame_allocator) if s.input.editing else ""
	s.input.composition_cursor = int(input.composition_cursor)

	// The pointer.
	mouse := input.mouse_position
	if mouse != s.input.last_mouse || .Mouse_Left in input.pressed {
		s.input.modality = .Pointer
	}
	s.input.last_mouse = mouse
	s.input.hovered = NO_NODE
	for i in in_scope {
		d := &s.documents[i]
		n, covered := hit(d, 0, mouse)
		if n != NONE {
			s.input.hovered = ref(s, d, n)
			break
		}
		if covered && d.nodes[0].style.modal {
			break
		}
	}
	if .Mouse_Left in input.pressed {
		s.input.pressed = s.input.hovered
		// A press anywhere but the field that is being edited stops its editing.
		if s.input.hovered != s.input.focus {
			s.input.editing = false
		}
		if d, n, ok := resolve(s, s.input.hovered); ok {
			if d.nodes[n].style.focusable {
				set_focus(s, s.input.hovered)
				if d.nodes[n].element == .Field {
					s.input.editing = true
					s.input.caret = caret_at(d, d.nodes[n].text, mouse.x - d.nodes[n].rect[0] - d.nodes[n].style.padding[3] * s.scale + s.input.scroll)
					s.input.anchor = s.input.caret
					s.input.caret_time = now
				}
			}
		}
	}
	if .Mouse_Left in input.released {
		if s.input.pressed == s.input.hovered {
			if d, n, ok := resolve(s, s.input.pressed); ok && d.nodes[n].element != .Field {
				click(s, d, n)
			}
		}
		s.input.pressed = NO_NODE
	}

	pad_pressed, pad_down: core.Gamepad_Buttons
	stick: [2]f32
	for p in input.gamepads {
		if p.connected {
			pad_pressed += p.pressed
			pad_down += p.down
			if abs(p.axes[.Left_X]) > abs(stick.x) {
				stick.x = p.axes[.Left_X]
			}
			if abs(p.axes[.Left_Y]) > abs(stick.y) {
				stick.y = p.axes[.Left_Y]
			}
		}
	}
	if pad_pressed != {} || input.pressed & ~{.Mouse_Left, .Mouse_Right, .Mouse_Middle, .Mouse_4, .Mouse_5} != {} {
		s.input.modality = .Keys
	}

	if s.input.editing {
		if d, n, ok := resolve(s, s.input.focus); ok && d.nodes[n].element == .Field && !d.nodes[n].disabled {
			edit_field(s, d, n, input, pad_pressed, now)
		} else {
			s.input.editing = false
		}
	} else {
		navigate(s, in_scope, input, pad_pressed, pad_down, stick, now)
	}
	if !s.input.editing && (.Escape in input.pressed || .B in pad_pressed) {
		for i in in_scope {
			d := &s.documents[i]
			if cancel := d.nodes[0].style.cancel; cancel != "" {
				queue_event(s, d, cancel, "")
				break
			}
		}
	}
	s.input.wants_input = s.input.modal >= 0 || s.input.editing
}

// update_modal moves the focus into a modal document that has come to show, and back out to where it was when one goes.
@(private)
update_modal :: proc(s: ^State, in_scope: []i32) {
	modal := i32(-1)
	if len(in_scope) == 1 && s.documents[in_scope[0]].nodes[0].style.modal {
		modal = in_scope[0]
	}
	if modal == s.input.modal {
		return
	}
	if modal >= 0 {
		if s.input.focus_depth < MAX_FOCUS_STACK {
			s.input.focus_stack[s.input.focus_depth] = s.input.focus
			s.input.focus_depth += 1
		}
		set_focus(s, initial_focus(s, &s.documents[modal]))
	} else if s.input.focus_depth > 0 {
		s.input.focus_depth -= 1
		set_focus(s, s.input.focus_stack[s.input.focus_depth])
	}
	s.input.modal = modal
}

// navigate moves the focus by arrows, Tab, the d-pad and the left stick, with repeat, and activates the focused node
// with Enter, Space or A.
@(private)
navigate :: proc(s: ^State, in_scope: []i32, input: core.Input, pad_pressed, pad_down: core.Gamepad_Buttons, stick: [2]f32, now: f64) {
	// The stick engages past STICK_ENGAGE on its larger axis, and lets go past STICK_RELEASE.
	if held, ok := s.input.stick.?; ok {
		v := held == .Left || held == .Right ? abs(stick.x) : abs(stick.y)
		if v < STICK_RELEASE {
			s.input.stick = nil
		}
	} else if abs(stick.x) > STICK_ENGAGE || abs(stick.y) > STICK_ENGAGE {
		if abs(stick.x) > abs(stick.y) {
			s.input.stick = stick.x > 0 ? Direction.Right : Direction.Left
		} else {
			s.input.stick = stick.y > 0 ? Direction.Up : Direction.Down
		}
	}
	held: Maybe(Direction)
	KEYS := [Direction]core.Key{.Up = .Up, .Down = .Down, .Left = .Left, .Right = .Right}
	PAD := [Direction]core.Gamepad_Button{.Up = .Dpad_Up, .Down = .Dpad_Down, .Left = .Dpad_Left, .Right = .Dpad_Right}
	for dir in Direction {
		if KEYS[dir] in input.down || KEYS[dir] in input.pressed || PAD[dir] in pad_down || PAD[dir] in pad_pressed {
			held = dir
		}
	}
	if held == nil {
		held = s.input.stick
	}
	step: Maybe(Direction)
	if dir, ok := held.?; ok {
		previous, was := s.input.nav_held.?
		if !was || previous != dir {
			step = dir
			s.input.nav_next = now + NAV_DELAY
		} else if now >= s.input.nav_next {
			step = dir
			s.input.nav_next = now + NAV_REPEAT
		}
	}
	s.input.nav_held = held
	tab := .Tab in input.pressed
	if dir, ok := step.?; ok || tab {
		s.input.modality = .Keys
		d, n, focused := resolve(s, s.input.focus)
		if !focused || !d.nodes[n].shown {
			for i in in_scope {
				if r := initial_focus(s, &s.documents[i]); r != NO_NODE {
					set_focus(s, r)
					break
				}
			}
		} else if tab {
			backwards := .Left_Shift in input.down || .Right_Shift in input.down
			list := make([dynamic]u32, context.temp_allocator)
			focusables(d, 0, &list)
			if at, found := slice.linear_search(list[:], n); found && len(list) > 0 {
				next := (at + (backwards ? len(list) - 1 : 1)) % len(list)
				set_focus(s, ref(s, d, list[next]))
			}
		} else {
			if target := nearest(s, d, n, dir); target != NONE {
				set_focus(s, ref(s, d, target))
			}
		}
	}
	activate := .Enter in input.pressed || .Space in input.pressed || .A in pad_pressed
	if activate {
		if d, n, ok := resolve(s, s.input.focus); ok && d.nodes[n].shown && !d.nodes[n].disabled {
			s.input.key_pressing = true
			click(s, d, n)
		}
	}
	if !(.Enter in input.down || .Space in input.down || .A in pad_down) {
		s.input.key_pressing = false
	}
}

// nearest is the node that focus goes to from a node in a direction: the one that its nav attribute names, or else the
// nearest that takes focus beyond its edge that way, by the gap along the direction plus twice the gap across it.
@(private)
nearest :: proc(s: ^State, d: ^Document, from: u32, dir: Direction) -> u32 {
	if target := d.nodes[from].style.nav[dir]; target != "" {
		if n, found := find_node(d, target); found && d.nodes[n].shown && !d.nodes[n].disabled {
			return n
		}
	}
	list := make([dynamic]u32, context.temp_allocator)
	focusables(d, 0, &list)
	a := d.nodes[from].rect
	best, best_score := NONE, f32(max(f32))
	for n in list {
		if n == from {
			continue
		}
		b := d.nodes[n].rect
		along, across: f32
		switch dir {
		case .Up:
			along = a[1] - b[3]
		case .Down:
			along = b[1] - a[3]
		case .Left:
			along = a[0] - b[2]
		case .Right:
			along = b[0] - a[2]
		}
		if along < -1 {
			continue
		}
		if dir == .Up || dir == .Down {
			across = max(b[0] - a[2], a[0] - b[2], 0)
		} else {
			across = max(b[1] - a[3], a[1] - b[3], 0)
		}
		if score := max(along, 0) + 2 * across; score < best_score {
			best, best_score = n, score
		}
	}
	return best
}

// repeat is whether a key acts this frame: when it goes down, and again after a delay while it is held.
@(private)
repeat :: proc(s: ^State, input: core.Input, key: core.Key, now: f64) -> bool {
	if key in input.pressed {
		s.input.key_held = key
		s.input.key_next = now + NAV_DELAY
		return true
	}
	if key in input.down && s.input.key_held == key && now >= s.input.key_next {
		s.input.key_next = now + KEY_REPEAT
		return true
	}
	return false
}

// edit_field types into the focused field: the committed text at the caret, over the selection, and its keys. The value
// is the field's text, which the edit sets as a script's Ui.set_text would, so it outlives a rebuild.
@(private)
edit_field :: proc(s: ^State, d: ^Document, n: u32, input: core.Input, pad_pressed: core.Gamepad_Buttons, now: f64) {
	input := input
	node := &d.nodes[n]
	value := strings.clone(node.style.text, s.platform.frame_allocator)
	caret, anchor := min(s.input.caret, u32(len(value))), min(s.input.anchor, u32(len(value)))
	changed := false
	shift := .Left_Shift in input.down || .Right_Shift in input.down
	ctrl := .Left_Control in input.down || .Right_Control in input.down
	replace :: proc(value: string, from, to: u32, with: string, allocator := context.allocator) -> string {
		return strings.concatenate({value[:from], with, value[to:]}, allocator)
	}
	low, high := min(caret, anchor), max(caret, anchor)
	typed := core.input_text_string(&input.text)
	if typed != "" {
		// Only what fits under max_length, a whole character at a time.
		if limit := node.style.max_length; limit > 0 {
			room := limit - (utf8.rune_count_in_string(value) - utf8.rune_count_in_string(value[low:high]))
			cut := 0
			for i := 0; i < len(typed) && room > 0; room -= 1 {
				_, size := utf8.decode_rune_in_string(typed[i:])
				i += size
				cut = i
			}
			typed = typed[:cut]
		}
		if typed != "" {
			value = replace(value, low, high, typed, s.platform.frame_allocator)
			caret = low + u32(len(typed))
			anchor = caret
			changed = true
		}
	}
	low, high = min(caret, anchor), max(caret, anchor)
	step_back :: proc(value: string, at: u32, word: bool) -> u32 {
		i := int(at)
		for i > 0 {
			_, size := utf8.decode_last_rune_in_string(value[:i])
			i -= size
			if !word || (i > 0 && value[i - 1] == ' ' && value[i] != ' ') {
				break
			}
		}
		return u32(i)
	}
	step_forward :: proc(value: string, at: u32, word: bool) -> u32 {
		i := int(at)
		for i < len(value) {
			_, size := utf8.decode_rune_in_string(value[i:])
			i += size
			if !word || (i < len(value) && value[i - 1] == ' ' && value[i] != ' ') {
				break
			}
		}
		return u32(i)
	}
	if repeat(s, input, .Backspace, now) {
		if low != high {
			value = replace(value, low, high, "", s.platform.frame_allocator)
			caret = low
		} else if caret > 0 {
			from := step_back(value, caret, ctrl)
			value = replace(value, from, caret, "", s.platform.frame_allocator)
			caret = from
		}
		anchor = caret
		changed = true
	} else if repeat(s, input, .Delete, now) {
		if low != high {
			value = replace(value, low, high, "", s.platform.frame_allocator)
			caret = low
		} else if int(caret) < len(value) {
			value = replace(value, caret, step_forward(value, caret, ctrl), "", s.platform.frame_allocator)
		}
		anchor = caret
		changed = true
	} else if repeat(s, input, .Left, now) {
		caret = !shift && low != high ? low : step_back(value, caret, ctrl)
	} else if repeat(s, input, .Right, now) {
		caret = !shift && low != high ? high : step_forward(value, caret, ctrl)
	} else if .Home in input.pressed {
		caret = 0
	} else if .End in input.pressed {
		caret = u32(len(value))
	}
	if !changed && !shift && (.Left in input.down || .Right in input.down || .Home in input.pressed || .End in input.pressed) {
		anchor = caret
	}
	if caret != s.input.caret || changed {
		s.input.caret_time = now
	}
	s.input.caret, s.input.anchor = caret, anchor
	if changed {
		set_override(s, d, id_of(d, n), node.id_hash, .Text, value)
		node.style.text = value
		queue_event(s, d, node.style.changed, id_of(d, n), value)
	}
	if .Enter in input.pressed {
		queue_event(s, d, node.style.submit, id_of(d, n), value)
		s.input.editing = false
	}
	if .Escape in input.pressed || .B in pad_pressed || .Tab in input.pressed {
		s.input.editing = false
	}
}

// flush_events sends the events that input queued to their documents' entities' behaviours: on_<event>(id), and
// on_<event>(id, text) for a field's. Call it after handle_input, before the script phase, which delivers them.
flush_events :: proc(s: ^State, r: ^script.Runtime) {
	for e in s.input.events {
		if text, has := e.text.?; has {
			script.send(r, e.entity, e.name, e.id, text)
		} else {
			script.send(r, e.entity, e.name, e.id)
		}
	}
	clear(&s.input.events)
}

// wants_input is whether the UI takes the player's input this frame: a modal document shows, or a field is being
// edited. A game's own controls check it.
wants_input :: proc(s: ^State) -> bool {
	return s.input.wants_input
}
