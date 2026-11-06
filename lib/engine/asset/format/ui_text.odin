package asset_format

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// The text of a UI document (see docs/content/kinds/ui-documents.md#the-format): a first line of `ui 1`, then one <ui>
// element in a pseudo-XML. It is XML's elements, attributes, comments and five entities, without a prolog, namespaces,
// CDATA or a DTD, and an attribute's value may go without quotes when it has no space or >, as $<guid> does.

// Ui_Problem is a problem in a UI document's text, at a line and column from 1. A warning does not stop the cook.
Ui_Problem :: struct {
	line, column: int,
	message:      string,
	error:        bool,
}

// Ui_Raw_Attr and Ui_Raw_Element are the text's elements before ui_parse checks what they mean.
@(private = "file")
Ui_Raw_Attr :: struct {
	name, value:  string,
	line, column: int,
}

@(private = "file")
Ui_Raw_Element :: struct {
	name:         string,
	line, column: int,
	attrs:        [dynamic]Ui_Raw_Attr,
	children:     [dynamic]^Ui_Raw_Element,
	// The text in the element, its whitespace collapsed, and where it starts.
	text:         string,
	text_line:    int,
	text_column:  int,
}

@(private = "file")
Ui_Scanner :: struct {
	text:         string,
	pos:          int,
	line, column: int,
	problems:     ^[dynamic]Ui_Problem,
}

@(private = "file")
scan_error :: proc(s: ^Ui_Scanner, line, column: int, format_string: string, args: ..any) {
	append(s.problems, Ui_Problem{line, column, fmt.tprintf(format_string, ..args), true})
}

@(private = "file")
scan_at :: proc(s: ^Ui_Scanner, prefix: string) -> bool {
	return strings.has_prefix(s.text[s.pos:], prefix)
}

@(private = "file")
scan_done :: proc(s: ^Ui_Scanner) -> bool {
	return s.pos >= len(s.text)
}

// scan_advance moves past n bytes, counting lines and columns in characters.
@(private = "file")
scan_advance :: proc(s: ^Ui_Scanner, n: int) {
	end := min(s.pos + n, len(s.text))
	for s.pos < end {
		r, size := utf8.decode_rune_in_string(s.text[s.pos:])
		s.pos += size
		if r == '\n' {
			s.line += 1
			s.column = 1
		} else {
			s.column += 1
		}
	}
}

@(private = "file")
scan_space :: proc(s: ^Ui_Scanner) {
	for !scan_done(s) && strings.is_space(rune(s.text[s.pos])) {
		scan_advance(s, 1)
	}
}

@(private = "file")
is_name_byte :: proc(c: u8) -> bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-' || c == ':'
}

@(private = "file")
scan_name :: proc(s: ^Ui_Scanner) -> string {
	start := s.pos
	for !scan_done(s) && is_name_byte(s.text[s.pos]) {
		scan_advance(s, 1)
	}
	return s.text[start:s.pos]
}

// scan_comment skips a comment at the scanner, which it reports if it is not closed.
@(private = "file")
scan_comment :: proc(s: ^Ui_Scanner) {
	line, column := s.line, s.column
	end := strings.index(s.text[s.pos + 4:], "-->")
	if end < 0 {
		scan_error(s, line, column, "a comment that no --> closes")
		scan_advance(s, len(s.text))
		return
	}
	scan_advance(s, 4 + end + 3)
}

// decode_entities replaces &lt; &gt; &amp; &quot; &apos; and &#<decimal>; and &#x<hex>; in text. It gives what is
// wrong with an entity, or "".
@(private = "file")
decode_entities :: proc(text: string) -> (decoded: string, problem: string) {
	if strings.index_byte(text, '&') < 0 {
		return text, ""
	}
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(text); i += 1 {
		if text[i] != '&' {
			strings.write_byte(&b, text[i])
			continue
		}
		end := strings.index_byte(text[i:], ';')
		if end < 0 {
			return text, "has an & that is not an entity such as &amp;"
		}
		entity := text[i + 1:][:end - 1]
		switch entity {
		case "lt":
			strings.write_byte(&b, '<')
		case "gt":
			strings.write_byte(&b, '>')
		case "amp":
			strings.write_byte(&b, '&')
		case "quot":
			strings.write_byte(&b, '"')
		case "apos":
			strings.write_byte(&b, '\'')
		case:
			code: u64
			ok: bool
			if strings.has_prefix(entity, "#x") {
				code, ok = strconv.parse_u64_of_base(entity[2:], 16)
			} else if strings.has_prefix(entity, "#") {
				code, ok = strconv.parse_u64_of_base(entity[1:], 10)
			}
			if !ok || code == 0 || code > 0x10ffff {
				return text, fmt.tprintf("has &%s;, which is not an entity", entity)
			}
			strings.write_rune(&b, rune(code))
		}
		i += end
	}
	return strings.to_string(b), ""
}

// collapse_space makes each run of whitespace one space, and trims the ends.
@(private = "file")
collapse_space :: proc(text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	rest := text
	first := true
	for word in strings.fields_iterator(&rest) {
		if !first {
			strings.write_byte(&b, ' ')
		}
		strings.write_string(&b, word)
		first = false
	}
	return strings.to_string(b)
}

// scan_element reads an element at a <, with its attributes, its text and its children, up to its closing tag.
@(private = "file")
scan_element :: proc(s: ^Ui_Scanner) -> ^Ui_Raw_Element {
	e := new(Ui_Raw_Element, context.temp_allocator)
	e.line, e.column = s.line, s.column
	e.attrs = make([dynamic]Ui_Raw_Attr, context.temp_allocator)
	e.children = make([dynamic]^Ui_Raw_Element, context.temp_allocator)
	scan_advance(s, 1)
	e.name = scan_name(s)
	if e.name == "" {
		scan_error(s, e.line, e.column, "a < that does not start an element. Write &lt; for the character.")
	}
	for {
		scan_space(s)
		if scan_done(s) {
			scan_error(s, e.line, e.column, "<%s> is not closed", e.name)
			return e
		}
		if scan_at(s, "/>") {
			scan_advance(s, 2)
			return e
		}
		if scan_at(s, ">") {
			scan_advance(s, 1)
			break
		}
		line, column := s.line, s.column
		name := scan_name(s)
		if name == "" {
			scan_error(s, line, column, "%q in <%s> is not an attribute", s.text[s.pos:][:1], e.name)
			scan_advance(s, 1)
			continue
		}
		scan_space(s)
		if !scan_at(s, "=") {
			scan_error(s, line, column, "%s has no value: write %s=\"...\"", name, name)
			continue
		}
		scan_advance(s, 1)
		scan_space(s)
		value: string
		if !scan_done(s) && (s.text[s.pos] == '"' || s.text[s.pos] == '\'') {
			quote := s.text[s.pos : s.pos + 1]
			end := strings.index(s.text[s.pos + 1:], quote)
			if end < 0 {
				scan_error(s, line, column, "%s's value has no closing %s", name, quote)
				scan_advance(s, len(s.text))
				return e
			}
			raw := s.text[s.pos + 1:][:end]
			scan_advance(s, end + 2)
			problem: string
			value, problem = decode_entities(raw)
			if problem != "" {
				scan_error(s, line, column, "%s %s", name, problem)
			}
		} else {
			start := s.pos
			for !scan_done(s) && !strings.is_space(rune(s.text[s.pos])) && s.text[s.pos] != '>' && !scan_at(s, "/>") {
				scan_advance(s, 1)
			}
			value = s.text[start:s.pos]
		}
		append(&e.attrs, Ui_Raw_Attr{name, value, line, column})
	}
	// The element's content, up to its closing tag.
	text := strings.builder_make(context.temp_allocator)
	for {
		if scan_done(s) {
			scan_error(s, e.line, e.column, "<%s> has no </%s>", e.name, e.name)
			break
		}
		if scan_at(s, "<!--") {
			scan_comment(s)
			continue
		}
		if scan_at(s, "</") {
			line, column := s.line, s.column
			scan_advance(s, 2)
			name := scan_name(s)
			scan_space(s)
			if scan_at(s, ">") {
				scan_advance(s, 1)
			} else {
				scan_error(s, line, column, "</%s has no >", name)
			}
			if name != e.name {
				scan_error(s, line, column, "</%s> closes <%s> from line %d", name, e.name, e.line)
			}
			break
		}
		if scan_at(s, "<") {
			append(&e.children, scan_element(s))
			continue
		}
		start := s.pos
		line, column := s.line, s.column
		for !scan_done(s) && s.text[s.pos] != '<' {
			scan_advance(s, 1)
		}
		run := s.text[start:s.pos]
		if strings.trim_space(run) != "" && e.text_line == 0 {
			e.text_line, e.text_column = line, column
			// The text's position is its first character's, past the whitespace that it starts with.
			for c in run {
				if !strings.is_space(c) {
					break
				}
				if c == '\n' {
					e.text_line += 1
					e.text_column = 1
				} else {
					e.text_column += 1
				}
			}
		}
		strings.write_string(&text, run)
		strings.write_byte(&text, ' ')
	}
	decoded, problem := decode_entities(collapse_space(strings.to_string(text)))
	if problem != "" {
		scan_error(s, e.text_line, e.text_column, "the text %s", problem)
	}
	e.text = decoded
	return e
}

// Ui_Compiler checks a document's raw elements and gives its nodes and styles.
@(private = "file")
Ui_Compiler :: struct {
	problems: ^[dynamic]Ui_Problem,
	nodes:    [dynamic]Ui_Node_Contents,
	styles:   [dynamic]Ui_Style_Contents,
	// Each node's raw element, for its references' positions.
	raw:      [dynamic]^Ui_Raw_Element,
	// The ids of the document, and of each template, by name, to their nodes.
	ids:      map[string]int,
	scope:    ^map[string]int,
	// The document has more than MAX_UI_NODES elements, which is reported once.
	too_many: bool,
}

@(private = "file")
compile_error :: proc(c: ^Ui_Compiler, line, column: int, format_string: string, args: ..any) {
	append(c.problems, Ui_Problem{line, column, fmt.tprintf(format_string, ..args), true})
}

@(private = "file")
compile_warning :: proc(c: ^Ui_Compiler, line, column: int, format_string: string, args: ..any) {
	append(c.problems, Ui_Problem{line, column, fmt.tprintf(format_string, ..args), false})
}

// compile_props checks the attributes that are not id, style or name, and parses each value.
@(private = "file")
compile_props :: proc(c: ^Ui_Compiler, e: ^Ui_Raw_Element, element: Maybe(Ui_Element), skip: []string) -> []Ui_Prop_Contents {
	props := make([dynamic]Ui_Prop_Contents, context.temp_allocator)
	seen: bit_set[Ui_Attr]
	attrs: for a in e.attrs {
		for name in skip {
			if a.name == name {
				continue attrs
			}
		}
		attr, known := ui_attr_of(a.name)
		if !known {
			compile_error(c, a.line, a.column, "%s is not an attribute", a.name)
			continue
		}
		if attr in seen {
			compile_error(c, a.line, a.column, "%s is given twice", a.name)
			continue
		}
		seen += {attr}
		if el, is_element := element.?; is_element && el not_in UI_ATTRS[attr].on {
			compile_warning(c, a.line, a.column, "%s means nothing on <%s>", a.name, UI_ELEMENT_NAMES[el])
		}
		if _, message := ui_parse_value(attr, a.value); message != "" {
			compile_error(c, a.line, a.column, "%s %s", a.name, message)
			continue
		}
		append(&props, Ui_Prop_Contents{attr, a.value, a.line, a.column})
	}
	return props[:]
}

@(private = "file")
attr_of :: proc(e: ^Ui_Raw_Element, name: string) -> (attr: Ui_Raw_Attr, ok: bool) {
	for a in e.attrs {
		if a.name == name {
			return a, true
		}
	}
	return
}

// compile_styles reads the <style> elements of the root, and links each base style to its variants.
@(private = "file")
compile_styles :: proc(c: ^Ui_Compiler, root: ^Ui_Raw_Element) {
	by_name := make(map[string]int, context.temp_allocator)
	for e in root.children {
		if e.name != UI_STYLE_ELEMENT {
			continue
		}
		if len(e.children) > 0 || e.text != "" {
			compile_error(c, e.line, e.column, "a <style> holds attributes, not elements or text")
		}
		for name in ([]string{"id", "style"}) {
			if a, has := attr_of(e, name); has {
				compile_error(c, a.line, a.column, "a <style> has no %s: an element takes it", name)
			}
		}
		name_attr, named := attr_of(e, "name")
		if !named || name_attr.value == "" {
			compile_error(c, e.line, e.column, "a <style> needs a name")
			continue
		}
		name := name_attr.value
		base, _, state := strings.partition(name, ":")
		if !ui_valid_id(base) {
			compile_error(c, name_attr.line, name_attr.column, "%q is not a style's name of lowercase letters, digits, _ and -", name)
			continue
		}
		if state != "" {
			known := false
			for n in UI_STATE_NAMES {
				known ||= n == state
			}
			if !known {
				compile_error(c, name_attr.line, name_attr.column, "%q is not a state: a variant is :hover, :focus, :press or :disabled", state)
				continue
			}
		}
		if previous, twice := by_name[name]; twice {
			compile_error(c, name_attr.line, name_attr.column, "the style %s is also on line %d", name, c.styles[previous].line)
			continue
		}
		by_name[name] = len(c.styles)
		append(&c.styles, Ui_Style_Contents{name = name, line = e.line, props = compile_props(c, e, nil, {"name"}), variants = UI_NO_VARIANTS})
	}
	for &s, i in c.styles {
		base, _, state := strings.partition(s.name, ":")
		if state == "" {
			continue
		}
		b, has_base := by_name[base]
		if !has_base {
			compile_warning(c, s.line, 1, "the variant %s has no style %s, so nothing takes it", s.name, base)
			continue
		}
		for n, st in UI_STATE_NAMES {
			if n == state {
				c.styles[b].variants[st] = u32(i)
			}
		}
	}
}

@(private = "file")
find_style :: proc(c: ^Ui_Compiler, name: string) -> (index: u32, ok: bool) {
	for s, i in c.styles {
		if s.name == name {
			return u32(i), true
		}
	}
	return
}

@(private = "file")
direction_of :: proc(element: Ui_Element, props: []Ui_Prop_Contents) -> Ui_Direction {
	#partial switch element {
	case .Row, .Button:
		for p in props {
			if p.attr == .Direction {
				v, _ := ui_parse_value(.Direction, p.value)
				return v.(Ui_Direction)
			}
		}
		return .Row
	case .Column:
		return .Column
	case .Box:
		for p in props {
			if p.attr == .Direction {
				v, _ := ui_parse_value(.Direction, p.value)
				return v.(Ui_Direction)
			}
		}
		return .Column
	}
	return .Stack
}

// compile_node adds an element and its subtree to the nodes.
@(private = "file")
compile_node :: proc(c: ^Ui_Compiler, e: ^Ui_Raw_Element, parent: int, depth: int, flags: Ui_Node_Flags) {
	element, known := ui_element_of(e.name)
	if !known {
		if e.name == UI_STYLE_ELEMENT {
			compile_error(c, e.line, e.column, "a <style> is a child of <ui> itself")
		} else {
			compile_error(c, e.line, e.column, "<%s> is not an element", e.name)
		}
		return
	}
	if element == .Ui {
		compile_error(c, e.line, e.column, "<ui> is only the root")
		return
	}
	if element == .Template && (parent != 0 || .Template in flags) {
		compile_error(c, e.line, e.column, "a <template> is a child of <ui> itself")
		return
	}
	if depth > MAX_UI_DEPTH {
		compile_error(c, e.line, e.column, "elements nest more than %d deep", MAX_UI_DEPTH)
		return
	}
	if len(c.nodes) >= MAX_UI_NODES {
		if !c.too_many {
			compile_error(c, e.line, e.column, "a document has at most %d elements", MAX_UI_NODES)
		}
		c.too_many = true
		return
	}
	compile_one(c, e, element, parent, depth, flags)
}

@(private = "file")
compile_one :: proc(c: ^Ui_Compiler, e: ^Ui_Raw_Element, element: Ui_Element, parent: int, depth: int, flags: Ui_Node_Flags) {
	flags := flags
	if element == .Template {
		flags += {.Template}
	}
	// A template's ids are its own, as each copy of it has its own.
	template_ids: map[string]int
	if element == .Template {
		template_ids = make(map[string]int, context.temp_allocator)
	}
	node := Ui_Node_Contents {
		element = element,
		flags   = flags,
		parent  = parent < 0 ? UI_NONE : u32(parent),
		line    = e.line,
	}
	if a, has := attr_of(e, "name"); has {
		compile_error(c, a.line, a.column, "an element has no name: a <style> takes it")
	}
	if a, has := attr_of(e, "id"); has {
		if !ui_valid_id(a.value) {
			compile_error(c, a.line, a.column, "id %q is not lowercase letters, digits, _ and -", a.value)
		} else if other, twice := c.scope[a.value]; twice {
			compile_error(c, a.line, a.column, "id %s is also on line %d", a.value, c.nodes[other].line)
		} else {
			node.id = a.value
			c.scope[a.value] = len(c.nodes)
		}
	} else if element == .Template {
		compile_error(c, e.line, e.column, "a <template> needs an id, which Ui.add names it by")
	}
	if element == .Template {
		for a in e.attrs {
			if a.name != "id" {
				compile_error(c, a.line, a.column, "a <template> takes only an id: put %s on its element", a.name)
			}
		}
	} else {
		node.props = compile_props(c, e, element, {"id", "style", "name"})
	}
	styles := make([dynamic]u32, context.temp_allocator)
	if kind_style, has := find_style(c, UI_ELEMENT_NAMES[element]); has {
		append(&styles, kind_style)
	}
	if a, has := attr_of(e, "style"); has {
		rest := a.value
		for name in strings.fields_iterator(&rest) {
			if base, _, state := strings.partition(name, ":"); state != "" {
				compile_error(c, a.line, a.column, "style %s is a variant, which applies with its style: name %s", name, base)
				continue
			}
			index, found := find_style(c, name)
			if !found {
				compile_error(c, a.line, a.column, "there is no style %s", name)
				continue
			}
			already := false
			for s in styles {
				already ||= s == index
			}
			if !already {
				append(&styles, index)
			}
		}
	}
	node.styles = styles[:]
	if parent >= 0 {
		parent_node := c.nodes[parent]
		if dir := direction_of(parent_node.element, parent_node.props); dir != .Stack && parent_node.element != .Ui {
			for p in node.props {
				if p.attr == .Anchor {
					compile_warning(c, p.line, p.column, "anchor places an element in a stack, and <%s> on line %d lays its children out in a %v", UI_ELEMENT_NAMES[parent_node.element], parent_node.line, dir)
				}
			}
		}
	}
	// Text in an element: the text of a <text> or a <field>, and a <text> of its own in a <button>.
	button_text := false
	if e.text != "" {
		#partial switch element {
		case .Text, .Field:
			for p in node.props {
				if p.attr == .Text {
					compile_error(c, e.text_line, e.text_column, "<%s> has both a text attribute and text", e.name)
				}
			}
			if _, message := ui_parse_value(.Text, e.text); message != "" {
				compile_error(c, e.text_line, e.text_column, "the text %s", message)
			} else {
				props := make([dynamic]Ui_Prop_Contents, 0, len(node.props) + 1, context.temp_allocator)
				append(&props, ..node.props)
				append(&props, Ui_Prop_Contents{.Text, e.text, e.text_line, e.text_column})
				node.props = props[:]
			}
		case .Button:
			button_text = true
		case:
			compile_error(c, e.text_line, e.text_column, "<%s> holds no text: put it in a <text>", e.name)
		}
	}
	index := len(c.nodes)
	append(&c.nodes, node)
	append(&c.raw, e)
	scope := c.scope
	if element == .Template {
		c.scope = &template_ids
	}
	if element in (Ui_Elements{.Text, .Image, .Field}) && len(e.children) > 0 {
		compile_error(c, e.children[0].line, e.children[0].column, "<%s> holds no elements", e.name)
	} else if element == .Template && len(e.children) != 1 {
		compile_error(c, e.line, e.column, "a <template> holds one element, which Ui.add copies")
	} else {
		if button_text {
			if len(e.children) > 0 {
				compile_error(c, e.text_line, e.text_column, "a <button> holds text or elements, not both: put the text in a <text>")
			} else if _, message := ui_parse_value(.Text, e.text); message != "" {
				compile_error(c, e.text_line, e.text_column, "the text %s", message)
			} else {
				props := make([]Ui_Prop_Contents, 1, context.temp_allocator)
				props[0] = {.Text, e.text, e.text_line, e.text_column}
				text_styles := make([dynamic]u32, context.temp_allocator)
				if s, has := find_style(c, UI_ELEMENT_NAMES[.Text]); has {
					append(&text_styles, s)
				}
				append(&c.nodes, Ui_Node_Contents{element = .Text, flags = flags, parent = u32(index), end = u32(len(c.nodes) + 1), line = e.text_line, props = props, styles = text_styles[:]})
				append(&c.raw, e)
			}
		}
		for child in e.children {
			compile_node(c, child, index, depth + 1, flags)
		}
	}
	c.scope = scope
	if element == .Template {
		check_references(c, index + 1, len(c.nodes), &template_ids)
	}
	c.nodes[index].end = u32(len(c.nodes))
}

// check_references checks that the ids that the nodes from first to last name are in their scope.
@(private = "file")
check_references :: proc(c: ^Ui_Compiler, first, last: int, ids: ^map[string]int) {
	for i in first ..< last {
		for p in c.nodes[i].props {
			#partial switch p.attr {
			case .Nav_Up, .Nav_Down, .Nav_Left, .Nav_Right, .Focus:
				target := strings.trim_space(p.value)
				t, found := ids[target]
				if !found {
					compile_error(c, p.line, p.column, "%s names %s, which no element here has as its id", UI_ATTRS[p.attr].name, target)
				} else if p.attr == .Focus && !ui_focusable_node(c.nodes[t]) {
					compile_error(c, p.line, p.column, "focus names %s, which does not take focus: it is a <button>, a <field> or focusable", target)
				}
			}
		}
	}
}

// ui_focusable_node is whether an element takes focus by its kind and its own attributes.
@(private = "file")
ui_focusable_node :: proc(n: Ui_Node_Contents) -> bool {
	for p in n.props {
		if p.attr == .Focusable {
			v, _ := ui_parse_value(.Focusable, p.value)
			return v.(bool)
		}
	}
	return n.element == .Button || n.element == .Field
}

// ui_parse parses and checks a UI document's text. It gives every problem that it finds, warnings too, and ok is
// whether none is an error. The contents' strings point into text or the temp allocator.
ui_parse :: proc(text: string) -> (document: Ui_Document_Contents, problems: []Ui_Problem, ok: bool) {
	list := make([dynamic]Ui_Problem, context.temp_allocator)
	document = ui_parse_into(text, &list)
	ok = true
	for p in list {
		ok &&= !p.error
	}
	return document, list[:], ok
}

@(private = "file")
ui_parse_into :: proc(text: string, list: ^[dynamic]Ui_Problem) -> (document: Ui_Document_Contents) {
	// The header: the first line that is not blank.
	rest := text
	line_number := 0
	header := ""
	for line in strings.split_lines_iterator(&rest) {
		line_number += 1
		if strings.trim_space(line) != "" {
			header = strings.trim_space(line)
			break
		}
	}
	words := strings.fields(header, context.temp_allocator)
	if len(words) != 2 || words[0] != "ui" {
		append(list, Ui_Problem{max(line_number, 1), 1, fmt.tprintf("the first line is `ui %d`", UI_TEXT_VERSION), true})
		return
	}
	if version, version_ok := strconv.parse_int(words[1]); !version_ok || version != UI_TEXT_VERSION {
		append(list, Ui_Problem{line_number, 1, fmt.tprintf("version %s is not %d, which this build reads", words[1], UI_TEXT_VERSION), true})
		return
	}
	s := Ui_Scanner {
		text     = text,
		pos      = len(text) - len(rest),
		line     = line_number + 1,
		column   = 1,
		problems = list,
	}
	root: ^Ui_Raw_Element
	for {
		scan_space(&s)
		if scan_done(&s) {
			break
		}
		if scan_at(&s, "<!--") {
			scan_comment(&s)
			continue
		}
		if !scan_at(&s, "<") {
			scan_error(&s, s.line, s.column, "text outside <ui>")
			for !scan_done(&s) && s.text[s.pos] != '<' {
				scan_advance(&s, 1)
			}
			continue
		}
		e := scan_element(&s)
		if root != nil {
			scan_error(&s, e.line, e.column, "a document has one <ui>, which every element is in")
		} else if e.name != "ui" {
			scan_error(&s, e.line, e.column, "the document's element is <ui>, not <%s>", e.name)
		} else {
			root = e
		}
	}
	if root == nil {
		if len(list) == 0 {
			append(list, Ui_Problem{line_number + 1, 1, "the document has no <ui>", true})
		}
		return
	}
	if root.text != "" {
		scan_error(&s, root.text_line, root.text_column, "<ui> holds no text: put it in a <text>")
	}
	c := Ui_Compiler {
		problems = list,
		nodes    = make([dynamic]Ui_Node_Contents, context.temp_allocator),
		styles   = make([dynamic]Ui_Style_Contents, context.temp_allocator),
		raw      = make([dynamic]^Ui_Raw_Element, context.temp_allocator),
		ids      = make(map[string]int, context.temp_allocator),
	}
	c.scope = &c.ids
	compile_styles(&c, root)
	root_styles := make([dynamic]u32, context.temp_allocator)
	if s, has := find_style(&c, UI_ELEMENT_NAMES[.Ui]); has {
		append(&root_styles, s)
	}
	for name in ([]string{"id", "style", "name"}) {
		if a, has := attr_of(root, name); has {
			compile_error(&c, a.line, a.column, "<ui> has no %s", name)
		}
	}
	append(&c.nodes, Ui_Node_Contents{element = .Ui, parent = UI_NONE, line = root.line, props = compile_props(&c, root, Ui_Element.Ui, {"id", "style", "name"}), styles = root_styles[:]})
	append(&c.raw, root)
	for child in root.children {
		if child.name != UI_STYLE_ELEMENT {
			compile_node(&c, child, 0, 1, {})
		}
	}
	c.nodes[0].end = u32(len(c.nodes))
	// The document's references, outside its templates, which check their own.
	for n, i in c.nodes {
		if .Template not_in n.flags {
			check_references(&c, i, i + 1, &c.ids)
		}
	}
	document = {c.nodes[:], c.styles[:]}
	return
}
