package cook

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

import format "cinnabar:engine/asset/format"

// The parts that every technique of a decision shares (see docs/content/kinds/decisions.md#shared-parts): conditions
// over the blackboard's keys, action references and blackboard writes. Each is parsed against the blackboard's keys
// into the decision's records, so the runtime finds a key by its slot and never by its name.

@(private = "file")
Token_Kind :: enum {
	End,
	Word,
	Number,
	Text,
	Punct,
}

@(private = "file")
Token :: struct {
	kind:   Token_Kind,
	// The token as it is written: a Word's name, a Number's digits, a Text's quoted string, a Punct's characters.
	text:   string,
	number: f64,
}

// tokenize splits a condition or an action reference into words, numbers, quoted strings and punctuation. A - starts
// a number only where a value is expected, after an operator or at the start.
@(private = "file")
tokenize :: proc(text: string) -> (tokens: []Token, message: string) {
	result := make([dynamic]Token, context.temp_allocator)
	value_ends := proc(result: []Token) -> bool {
		if len(result) == 0 {
			return false
		}
		last := result[len(result) - 1]
		return last.kind == .Word || last.kind == .Number || last.kind == .Text || last.text == ")" || last.text == "]"
	}
	for i := 0; i < len(text); {
		c := text[i]
		switch {
		case c == ' ' || c == '\t':
			i += 1
		case c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'):
			start := i
			for i < len(text) && (text[i] == '_' || (text[i] >= 'a' && text[i] <= 'z') || (text[i] >= 'A' && text[i] <= 'Z') || (text[i] >= '0' && text[i] <= '9')) {
				i += 1
			}
			append(&result, Token{kind = .Word, text = text[start:i]})
		case (c >= '0' && c <= '9') || c == '.' || (c == '-' && !value_ends(result[:])):
			start := i
			i += 1
			for i < len(text) && ((text[i] >= '0' && text[i] <= '9') || text[i] == '.' || text[i] == 'e' || text[i] == 'E' ||
				    ((text[i] == '-' || text[i] == '+') && (text[i - 1] == 'e' || text[i - 1] == 'E'))) {
				i += 1
			}
			number, ok := strconv.parse_f64(text[start:i])
			if !ok {
				return nil, fmt.tprintf("%q is not a number", text[start:i])
			}
			append(&result, Token{kind = .Number, text = text[start:i], number = number})
		case c == '"':
			start := i
			i += 1
			for i < len(text) && text[i] != '"' {
				if text[i] == '\\' {
					i += 1
				}
				i += 1
			}
			if i >= len(text) {
				return nil, "a string ends with a \""
			}
			i += 1
			append(&result, Token{kind = .Text, text = text[start:i]})
		case:
			two := text[i:min(i + 2, len(text))]
			if two == "<=" || two == ">=" || two == "==" || two == "!=" {
				append(&result, Token{kind = .Punct, text = two})
				i += 2
			} else if strings.index_byte("()[],=<>!", c) >= 0 {
				append(&result, Token{kind = .Punct, text = text[i:i + 1]})
				i += 1
			} else {
				return nil, fmt.tprintf("%q is not part of a condition or an action", text[i:i + 1])
			}
		}
	}
	append(&result, Token{kind = .End})
	return result[:], ""
}

// Decision_Parser holds a decision's shared records as the text adds them, and the blackboard's keys that they name.
// A technique's reader adds conditions, actions and writes of its own fields with decision_condition, decision_action
// and decision_write, and reports problems with decision_problem.
Decision_Parser :: struct {
	found:      ^[dynamic]Blackboard_Problem,
	keys:       []format.Blackboard_Key_Contents,
	conditions: [dynamic]format.Decision_Condition,
	ops:        [dynamic]format.Decision_Op,
	constants:  [dynamic]format.Decision_Constant_Contents,
	actions:    [dynamic]format.Decision_Action_Contents,
	args:       [dynamic]format.Decision_Arg_Contents,
	writes:     [dynamic]format.Decision_Write,
}

decision_problem :: proc(p: ^Decision_Parser, line: int, f: string, args: ..any) {
	append(p.found, Blackboard_Problem{line, fmt.aprintf(f, ..args)})
}

// key_slot is the slot of the blackboard's key of a name.
@(private = "file")
key_slot :: proc(p: ^Decision_Parser, name: string) -> (int, bool) {
	for k, i in p.keys {
		if k.name == name {
			return i, true
		}
	}
	return -1, false
}

@(private = "file")
add_constant :: proc(p: ^Decision_Parser, c: format.Decision_Constant_Contents) -> u32 {
	for other, i in p.constants {
		if other == c {
			return u32(i)
		}
	}
	append(&p.constants, c)
	return u32(len(p.constants) - 1)
}

@(private = "file")
Expr_Kind :: enum {
	Or,
	And,
	Not,
	Compare,
	Key,
	Number,
	Bool,
	None,
	Self,
	// A word that is not a key, which only an enum's comparison takes, as one of its names.
	Word,
	Distance,
}

@(private = "file")
Expr :: struct {
	kind:        Expr_Kind,
	// Or, And, Compare and Distance: their two operands; Not: its one, in a.
	a, b:        int,
	op:          format.Decision_Op_Code,
	slot:        int,
	number:      f64,
	text:        string,
}

@(private = "file")
Condition_Parse :: struct {
	tokens: []Token,
	at:     int,
	exprs:  [dynamic]Expr,
	failed: string,
}

@(private = "file")
peek :: proc(c: ^Condition_Parse) -> Token {
	return c.tokens[c.at]
}

@(private = "file")
fail :: proc(c: ^Condition_Parse, f: string, args: ..any) -> int {
	if c.failed == "" {
		c.failed = fmt.tprintf(f, ..args)
	}
	return -1
}

@(private = "file")
add_expr :: proc(c: ^Condition_Parse, e: Expr) -> int {
	append(&c.exprs, e)
	return len(c.exprs) - 1
}

@(private = "file")
parse_or :: proc(p: ^Decision_Parser, c: ^Condition_Parse) -> int {
	left := parse_and(p, c)
	for c.failed == "" && peek(c).kind == .Word && peek(c).text == "or" {
		c.at += 1
		right := parse_and(p, c)
		left = add_expr(c, {kind = .Or, a = left, b = right})
	}
	return left
}

@(private = "file")
parse_and :: proc(p: ^Decision_Parser, c: ^Condition_Parse) -> int {
	left := parse_not(p, c)
	for c.failed == "" && peek(c).kind == .Word && peek(c).text == "and" {
		c.at += 1
		right := parse_not(p, c)
		left = add_expr(c, {kind = .And, a = left, b = right})
	}
	return left
}

@(private = "file")
parse_not :: proc(p: ^Decision_Parser, c: ^Condition_Parse) -> int {
	if t := peek(c); (t.kind == .Word && t.text == "not") || (t.kind == .Punct && t.text == "!") {
		c.at += 1
		return add_expr(c, {kind = .Not, a = parse_not(p, c)})
	}
	return parse_compare(p, c)
}

@(private = "file")
parse_compare :: proc(p: ^Decision_Parser, c: ^Condition_Parse) -> int {
	left := parse_operand(p, c)
	if c.failed != "" || peek(c).kind != .Punct {
		return left
	}
	Comparison :: struct {
		text: string,
		op:   format.Decision_Op_Code,
	}
	comparisons := [?]Comparison{{"<", .Less}, {"<=", .Less_Equal}, {">", .Greater}, {">=", .Greater_Equal}, {"==", .Equal}, {"!=", .Not_Equal}}
	for comparison in comparisons {
		if peek(c).text == comparison.text {
			c.at += 1
			right := parse_operand(p, c)
			return add_expr(c, {kind = .Compare, a = left, b = right, op = comparison.op})
		}
	}
	return left
}

@(private = "file")
parse_operand :: proc(p: ^Decision_Parser, c: ^Condition_Parse) -> int {
	t := peek(c)
	c.at += 1
	switch t.kind {
	case .End:
		c.at -= 1
		return fail(c, "the condition ends where a value is expected")
	case .Number:
		return add_expr(c, {kind = .Number, number = t.number})
	case .Text:
		return fail(c, "a condition does not compare strings")
	case .Punct:
		if t.text == "(" {
			inner := parse_or(p, c)
			if c.failed == "" && peek(c).text != ")" {
				return fail(c, "a ( has no )")
			}
			c.at += 1
			return inner
		}
		return fail(c, "%q is not a value", t.text)
	case .Word:
		switch t.text {
		case "true", "false":
			return add_expr(c, {kind = .Bool, number = 1 if t.text == "true" else 0})
		case "none":
			return add_expr(c, {kind = .None})
		case "self":
			return add_expr(c, {kind = .Self})
		case "and", "or", "not":
			return fail(c, "%s is not a value", t.text)
		case "distance":
			if peek(c).text != "(" {
				break
			}
			c.at += 1
			a := parse_operand(p, c)
			if c.failed == "" && peek(c).text != "," {
				return fail(c, "distance takes two places: distance(<a>, <b>)")
			}
			c.at += 1
			b := parse_operand(p, c)
			if c.failed == "" && peek(c).text != ")" {
				return fail(c, "distance takes two places: distance(<a>, <b>)")
			}
			c.at += 1
			return add_expr(c, {kind = .Distance, a = a, b = b})
		}
		if slot, found := key_slot(p, t.text); found {
			return add_expr(c, {kind = .Key, slot = slot})
		}
		return add_expr(c, {kind = .Word, text = t.text})
	}
	return -1
}

// Value_Type is a condition's value's type as the cook checks it: a Number is a float or an int, and an Enum's names
// are its key's.
@(private = "file")
Value_Type :: enum {
	Invalid,
	Number,
	Bool,
	Enum,
	Entity,
	Position,
	Vector,
	Word,
}

@(private = "file")
key_value_type :: proc(t: format.Blackboard_Type) -> Value_Type {
	switch t {
	case .Float, .Int:
		return .Number
	case .Bool:
		return .Bool
	case .Enum:
		return .Enum
	case .Entity:
		return .Entity
	case .Position:
		return .Position
	case .Vector:
		return .Vector
	case .String:
	}
	return .Invalid
}

// type_of is an expression's type, without emitting it. enum_slot is an Enum's key.
@(private = "file")
type_of :: proc(p: ^Decision_Parser, c: ^Condition_Parse, index: int) -> (t: Value_Type, enum_slot: int) {
	e := c.exprs[index]
	switch e.kind {
	case .Or, .And, .Not, .Compare:
		return .Bool, -1
	case .Key:
		return key_value_type(p.keys[e.slot].type), e.slot
	case .Number, .Distance:
		return .Number, -1
	case .Bool:
		return .Bool, -1
	case .None, .Self:
		return .Entity, -1
	case .Word:
		return .Word, -1
	}
	return .Invalid, -1
}

// emit writes an expression's ops in postfix order, checking its operands' types, and gives a message for the first
// that does not fit.
@(private = "file")
emit :: proc(p: ^Decision_Parser, c: ^Condition_Parse, index: int) -> string {
	e := c.exprs[index]
	push :: proc(p: ^Decision_Parser, code: format.Decision_Op_Code, operand: int = 0, type: format.Blackboard_Type = .Float) {
		append(&p.ops, format.Decision_Op{code = code, type = u8(type), operand = u32(operand)})
	}
	bool_operand :: proc(p: ^Decision_Parser, c: ^Condition_Parse, index: int, word: string) -> string {
		if t, _ := type_of(p, c, index); t != .Bool {
			return fmt.tprintf("%s takes conditions, which are true or false", word)
		}
		return emit(p, c, index)
	}
	switch e.kind {
	case .Or, .And:
		word := "or" if e.kind == .Or else "and"
		if message := bool_operand(p, c, e.a, word); message != "" {
			return message
		}
		if message := bool_operand(p, c, e.b, word); message != "" {
			return message
		}
		push(p, .Or if e.kind == .Or else .And)
	case .Not:
		if message := bool_operand(p, c, e.a, "not"); message != "" {
			return message
		}
		push(p, .Not)
	case .Key:
		t := p.keys[e.slot].type
		if t == .Position || t == .Vector {
			return fmt.tprintf("%s is a %s, which a condition reads only in distance", p.keys[e.slot].name, type_name(t))
		}
		push(p, .Key, e.slot)
	case .Number:
		value: [format.BLACKBOARD_VALUE_SIZE]byte
		(^f32)(&value)^ = f32(e.number)
		push(p, .Constant, int(add_constant(p, {type = .Float, value = value})))
	case .Bool:
		value: [format.BLACKBOARD_VALUE_SIZE]byte
		value[0] = u8(e.number)
		push(p, .Constant, int(add_constant(p, {type = .Bool, value = value})))
	case .None:
		push(p, .Constant, int(add_constant(p, {type = .Entity})))
	case .Self:
		push(p, .Self)
	case .Word:
		return fmt.tprintf("the blackboard has no key named %s", e.text)
	case .Distance:
		for operand in ([2]int{e.a, e.b}) {
			t, _ := type_of(p, c, operand)
			if t != .Entity && t != .Position {
				return "distance takes two places, each self, an entity key or a position key"
			}
			if c.exprs[operand].kind == .None {
				return "distance takes places, and none is not one"
			}
			if c.exprs[operand].kind == .Key {
				push(p, .Key, c.exprs[operand].slot)
			} else if message := emit(p, c, operand); message != "" {
				return message
			}
		}
		push(p, .Distance)
	case .Compare:
		a, a_slot := type_of(p, c, e.a)
		b, b_slot := type_of(p, c, e.b)
		ordered := e.op == .Less || e.op == .Less_Equal || e.op == .Greater || e.op == .Greater_Equal
		// A word beside an enum is one of its names.
		if (a == .Enum && b == .Word) || (a == .Word && b == .Enum) {
			slot := a_slot if a == .Enum else b_slot
			word := c.exprs[e.b if a == .Enum else e.a].text
			names := p.keys[slot].enum_names
			name_index, found := slice.linear_search(names, word)
			if !found {
				return fmt.tprintf("%s is not one of %s's values, %s", word, p.keys[slot].name, strings.join(names, ", ", context.temp_allocator))
			}
			if ordered {
				return "enums compare only with == and !="
			}
			value: [format.BLACKBOARD_VALUE_SIZE]byte
			(^u32)(&value)^ = u32(name_index)
			constant := add_constant(p, {type = .Enum, value = value})
			if a == .Enum {
				push(p, .Key, slot)
				push(p, .Constant, int(constant))
			} else {
				push(p, .Constant, int(constant))
				push(p, .Key, slot)
			}
			push(p, e.op, 0, .Enum)
			return ""
		}
		if a == .Word || b == .Word {
			return fmt.tprintf("the blackboard has no key named %s", c.exprs[e.a if a == .Word else e.b].text)
		}
		if a != b {
			return "a comparison compares two values of one type"
		}
		type: format.Blackboard_Type
		switch a {
		case .Number:
			type = .Float
		case .Bool:
			type = .Bool
		case .Enum:
			if !slice.equal(p.keys[a_slot].enum_names, p.keys[b_slot].enum_names) {
				return "two enums compare only when they have the same values"
			}
			type = .Enum
		case .Entity:
			type = .Entity
		case .Position, .Vector:
			return "positions and vectors compare only by distance"
		case .Invalid, .Word:
			return "a comparison compares two values of one type"
		}
		if ordered && type != .Float {
			return "only numbers compare with <, <=, > and >="
		}
		if message := emit(p, c, e.a); message != "" {
			return message
		}
		if message := emit(p, c, e.b); message != "" {
			return message
		}
		push(p, e.op, 0, type)
	}
	return ""
}

// decision_condition parses a condition, such as `health < 0.3 and (has_target or mood == alert)`, and adds it,
// giving its index. A problem is reported at the line, and gives DECISION_NONE.
decision_condition :: proc(p: ^Decision_Parser, text: string, line: int) -> u32 {
	tokens, message := tokenize(text)
	if message != "" {
		decision_problem(p, line, "%s", message)
		return format.DECISION_NONE
	}
	c := Condition_Parse {
		tokens = tokens,
		exprs  = make([dynamic]Expr, context.temp_allocator),
	}
	root := parse_or(p, &c)
	if c.failed == "" && peek(&c).kind != .End {
		fail(&c, "%q does not belong after the condition", peek(&c).text)
	}
	if c.failed != "" {
		decision_problem(p, line, "%s", c.failed)
		return format.DECISION_NONE
	}
	if t, _ := type_of(p, &c, root); t != .Bool {
		decision_problem(p, line, "a condition is true or false, such as health < 0.3 or has_target")
		return format.DECISION_NONE
	}
	first := len(p.ops)
	if problem := emit(p, &c, root); problem != "" {
		resize(&p.ops, first)
		decision_problem(p, line, "%s", problem)
		return format.DECISION_NONE
	}
	if depth := stack_depth(p.ops[first:]); depth > format.MAX_DECISION_STACK {
		resize(&p.ops, first)
		decision_problem(p, line, "the condition is too deep: split it")
		return format.DECISION_NONE
	}
	append(&p.conditions, format.Decision_Condition{first_op = u32(first), op_count = u32(len(p.ops) - first)})
	return u32(len(p.conditions) - 1)
}

// stack_depth is the deepest that ops' stack gets.
@(private = "file")
stack_depth :: proc(ops: []format.Decision_Op) -> int {
	depth, deepest := 0, 0
	for o in ops {
		switch o.code {
		case .Key, .Constant, .Self:
			depth += 1
		case .Distance, .Less, .Less_Equal, .Greater, .Greater_Equal, .Equal, .Not_Equal, .And, .Or:
			depth -= 1
		case .Not:
		}
		deepest = max(deepest, depth)
	}
	return deepest
}

// argument_value reads an argument's or a write's value from its tokens: a key's name, self, or a constant. type is
// the key's type for a write, which a constant is read as; an argument's constant gives its own type: a number is a
// Float, [x, y, z] a Vector, a quoted string a String, true or false a Bool, and none an Entity.
@(private = "file")
argument_value :: proc(p: ^Decision_Parser, text: string, type: Maybe(format.Blackboard_Type), enum_names: []string) -> (arg: format.Decision_Arg_Contents, message: string) {
	// A write to an enum takes one of its names before a key of that name.
	if slot, found := key_slot(p, text); found && !(type != nil && slice.contains(enum_names, text)) {
		return {source = .Key, index = u32(slot), type = p.keys[slot].type}, ""
	}
	if text == "self" {
		if t, typed := type.?; typed && t != .Entity {
			return {}, "self is an entity"
		}
		return {source = .Self, type = .Entity}, ""
	}
	t, typed := type.?
	if !typed {
		switch {
		case text == "true" || text == "false":
			t = .Bool
		case text == "none":
			t = .Entity
		case strings.has_prefix(text, "\""):
			t = .String
		case strings.has_prefix(text, "["):
			t = .Vector
		case is_identifier(text):
			return {}, fmt.tprintf("the blackboard has no key named %s", text)
		case:
			t = .Float
		}
	}
	value, problem := parse_board_value(t, text, enum_names)
	if problem != "" {
		if is_identifier(text) && t != .Enum && t != .Bool && t != .Entity {
			return {}, fmt.tprintf("the blackboard has no key named %s", text)
		}
		return {}, problem
	}
	constant := format.Decision_Constant_Contents {
		type  = t,
		value = value,
	}
	if t == .String {
		v, _ := parse_graph_value(text)
		constant.text = v.text
	}
	return {source = .Constant, index = add_constant(p, constant), type = t}, ""
}

// split_arguments splits a list at its top-level commas, keeping [x, y, z] and quoted strings whole.
@(private = "file")
split_arguments :: proc(text: string) -> (parts: []string, ok: bool) {
	result := make([dynamic]string, context.temp_allocator)
	depth, start := 0, 0
	quoted := false
	for i := 0; i < len(text); i += 1 {
		c := text[i]
		switch {
		case quoted && c == '\\':
			i += 1
		case c == '"':
			quoted = !quoted
		case quoted:
		case c == '[':
			depth += 1
		case c == ']':
			depth -= 1
		case c == ',' && depth == 0:
			append(&result, strings.trim_space(text[start:i]))
			start = i + 1
		}
	}
	if quoted || depth != 0 {
		return
	}
	if last := strings.trim_space(text[start:]); last != "" || len(result) > 0 {
		append(&result, last)
	}
	return result[:], true
}

// decision_action parses an action reference, such as `flee(from = target, speed = 4)`, and adds it, giving its
// index. Each argument is a constant, a key or self. The name is not checked here: the runtime finds the action when
// the decision loads. A problem is reported at the line, and gives DECISION_NONE.
decision_action :: proc(p: ^Decision_Parser, text: string, line: int) -> u32 {
	open := strings.index_byte(text, '(')
	name := strings.trim_space(text if open < 0 else text[:open])
	if !is_identifier(name) || (open >= 0 && !strings.has_suffix(text, ")")) {
		decision_problem(p, line, "an action is `<name>(<argument> = <value>, ...)`")
		return format.DECISION_NONE
	}
	first := len(p.args)
	if open >= 0 {
		parts, ok := split_arguments(text[open + 1:len(text) - 1])
		if !ok {
			decision_problem(p, line, "an action's arguments are `<argument> = <value>`, split by commas")
			return format.DECISION_NONE
		}
		for part in parts {
			arg_name, has_value, value := strings.partition(part, "=")
			arg_name, value = strings.trim_space(arg_name), strings.trim_space(value)
			if !is_identifier(arg_name) || has_value == "" || value == "" {
				resize(&p.args, first)
				decision_problem(p, line, "an action's arguments are `<argument> = <value>`, split by commas")
				return format.DECISION_NONE
			}
			for a in p.args[first:] {
				if a.name == arg_name {
					resize(&p.args, first)
					decision_problem(p, line, "the action %s has the argument %s twice", name, arg_name)
					return format.DECISION_NONE
				}
			}
			arg, message := argument_value(p, value, nil, nil)
			if message != "" {
				resize(&p.args, first)
				decision_problem(p, line, "%s", message)
				return format.DECISION_NONE
			}
			arg.name = arg_name
			append(&p.args, arg)
		}
	}
	append(&p.actions, format.Decision_Action_Contents{name = name, first_arg = u32(first), arg_count = u32(len(p.args) - first)})
	return u32(len(p.actions) - 1)
}

// decision_write parses a blackboard write's `<key> = <value>`, the text after `set`, and adds it, giving its index.
// The value is a constant of the key's type, another key of its type, or self for an entity. A problem is reported at
// the line, and gives DECISION_NONE.
decision_write :: proc(p: ^Decision_Parser, text: string, line: int) -> u32 {
	key_name, has_value, value := strings.partition(text, "=")
	key_name, value = strings.trim_space(key_name), strings.trim_space(value)
	if !is_identifier(key_name) || has_value == "" || value == "" {
		decision_problem(p, line, "a write is `set <key> = <value>`")
		return format.DECISION_NONE
	}
	slot, found := key_slot(p, key_name)
	if !found {
		decision_problem(p, line, "the blackboard has no key named %s", key_name)
		return format.DECISION_NONE
	}
	key := p.keys[slot]
	arg, message := argument_value(p, value, key.type, key.enum_names)
	if message == "" && arg.source == .Key &&
	   (arg.type != key.type || (key.type == .Enum && !slice.equal(key.enum_names, p.keys[arg.index].enum_names))) {
		message = fmt.tprintf("%s is a %s, and %s a %s", value, type_name(arg.type), key_name, type_name(key.type))
	}
	if message != "" {
		decision_problem(p, line, "%s", message)
		return format.DECISION_NONE
	}
	append(&p.writes, format.Decision_Write{key = u32(slot), source = arg.source, index = arg.index})
	return u32(len(p.writes) - 1)
}
