package cook

import "core:slice"
import "core:strconv"
import "core:strings"

import format "cinnabar:engine/asset/format"

// What the planning techniques' readers share (see docs/content/kinds/decisions.md#tests-and-effects): the planning
// keys, the bool, int and enum keys whose values make the planner's world state, and the tests and effects on them,
// with each key's tests as one interval.

// Plan_Reader is what a planning technique's reader knows of the header: the planning keys' slots, by their index, and
// the technique's name for its problems.
Plan_Reader :: struct {
	p:         ^Decision_Parser,
	planning:  [dynamic]u32,
	technique: string,
}

// read_planning_keys reads `keys = <key>, <key>, ...`: distinct bool, int and enum keys of the blackboard, at most
// MAX_PLAN_KEYS.
read_planning_keys :: proc(r: ^Plan_Reader, s: Decision_Field) {
	p := r.p
	for part in strings.split(s.value, ",", context.temp_allocator) {
		name := strings.trim_space(part)
		slot, type, found := plan_board_key(p, name)
		switch {
		case !is_identifier(name):
			decision_problem(p, s.line, "keys are the blackboard's keys: `keys = <key>, <key>, ...`")
			return
		case !found:
			decision_problem(p, s.line, "the blackboard has no key named %s", name)
		case type != .Bool && type != .Int && type != .Enum:
			decision_problem(p, s.line, "%s is a %s, and a planning key is a bool, an int or an enum", name, type_name(type))
		case slice.contains(r.planning[:], u32(slot)):
			decision_problem(p, s.line, "%s is a planning key twice", name)
		case len(r.planning) == format.MAX_PLAN_KEYS:
			decision_problem(p, s.line, "a %s decision plans over at most %d keys", r.technique, format.MAX_PLAN_KEYS)
			return
		case:
			append(&r.planning, u32(slot))
		}
	}
}

// read_plan_tests reads tests joined by `and`, each `<key>`, `not <key>` or `<key> <op> <value>` of a planning key, into one
// interval for each key that they test, in the order that each key first appears. The operators are ==, <, <=, > and
// >= on an int, == on an enum, and == and != on a bool.
read_plan_tests :: proc(r: ^Plan_Reader, f: Decision_Field) -> []format.Plan_Test {
	p := r.p
	tests := make([dynamic]format.Plan_Test, context.temp_allocator)
	for raw in strings.split(f.value, " and ", context.temp_allocator) {
		term := strings.trim_space(raw)
		lo, hi := i32(min(i32)), i32(max(i32))
		name := term
		negated := false
		if strings.has_prefix(term, "not ") || strings.has_prefix(term, "!") {
			negated = true
			name = strings.trim_space(term[4:] if term[0] == 'n' else term[1:])
		}
		op, value := "", ""
		if !negated {
			for candidate in ([]string{"<=", ">=", "==", "!=", "<", ">"}) {
				if at := strings.index(term, candidate); at >= 0 {
					op = candidate
					name = strings.trim_space(term[:at])
					value = strings.trim_space(term[at + len(candidate):])
					break
				}
			}
		}
		index, key, ok := planning_key(r, name, f.line)
		if !ok {
			continue
		}
		switch {
		case op == "" && key.type != .Bool:
			decision_problem(p, f.line, "%s is a %s, so a test of it compares it: `%s <op> <value>`", name, type_name(key.type), name)
			continue
		case op == "":
			lo = 0 if negated else 1
			hi = lo
		case:
			v, value_ok := plan_value(p, key, value, f.line)
			if !value_ok {
				continue
			}
			ordered := op == "<" || op == "<=" || op == ">" || op == ">="
			if (op == "!=" && key.type != .Bool) || (ordered && key.type != .Int) {
				allowed := "=="
				#partial switch key.type {
				case .Int:
					allowed = "==, <, <=, > and >="
				case .Bool:
					allowed = "== and !="
				}
				decision_problem(p, f.line, "%s is a %s, which a test compares with %s", name, type_name(key.type), allowed)
				continue
			}
			if (op == "<" && v == min(i32)) || (op == ">" && v == max(i32)) {
				decision_problem(p, f.line, "%s %s %d can never hold", name, op, v)
				continue
			}
			switch op {
			case "==":
				lo, hi = v, v
			case "!=":
				lo, hi = 1 - v, 1 - v
			case "<":
				hi = v - 1
			case "<=":
				hi = v
			case ">":
				lo = v + 1
			case ">=":
				lo = v
			}
		}
		merged := false
		for &t in tests {
			if t.key == index {
				t.lo, t.hi = max(t.lo, lo), min(t.hi, hi)
				if t.lo > t.hi {
					decision_problem(p, f.line, "the tests of %s can never hold together", name)
				}
				merged = true
			}
		}
		if !merged {
			append(&tests, format.Plan_Test{key = index, lo = lo, hi = hi})
		}
	}
	return tests[:]
}

// read_plan_effects reads effects, each `<key> = <value>`, which sets a planning key, or `<key> += <n>` or `<key> -= <n>`,
// which adds to an int planning key. An action changes a key once.
read_plan_effects :: proc(r: ^Plan_Reader, f: Decision_Field) -> []format.Plan_Effect {
	p := r.p
	effects := make([dynamic]format.Plan_Effect, context.temp_allocator)
	for raw in strings.split(f.value, ",", context.temp_allocator) {
		term := strings.trim_space(raw)
		e: format.Plan_Effect
		name, value: string
		sign := i32(1)
		plus, minus, equals := strings.index(term, "+="), strings.index(term, "-="), strings.index_byte(term, '=')
		switch {
		case plus >= 0:
			e.op = .Add
			name, value = term[:plus], term[plus + 2:]
		case minus >= 0:
			e.op = .Add
			sign = -1
			name, value = term[:minus], term[minus + 2:]
		case equals >= 0:
			name, value = term[:equals], term[equals + 1:]
		case:
			decision_problem(p, f.line, "an effect is `<key> = <value>`, `<key> += <n>` or `<key> -= <n>`")
			continue
		}
		name, value = strings.trim_space(name), strings.trim_space(value)
		index, key, ok := planning_key(r, name, f.line)
		if !ok {
			continue
		}
		if e.op == .Add && key.type != .Int {
			decision_problem(p, f.line, "%s is a %s, and only an int is added to", name, type_name(key.type))
			continue
		}
		v, value_ok := plan_value(p, key, value, f.line)
		if !value_ok {
			continue
		}
		if e.op == .Add && sign < 0 {
			if v == min(i32) {
				decision_problem(p, f.line, "%s is not an int that can be taken away", value)
				continue
			}
			v = -v
		}
		e.key, e.value = index, v
		doubled := false
		for other in effects {
			doubled ||= other.key == index
		}
		if doubled {
			decision_problem(p, f.line, "the effects change %s twice", name)
			continue
		}
		append(&effects, e)
	}
	return effects[:]
}

// planning_key is the index among the planning keys of a key of a name, and the key.
@(private = "file")
planning_key :: proc(r: ^Plan_Reader, name: string, line: int) -> (index: u32, key: format.Blackboard_Key_Contents, ok: bool) {
	slot, _, found := plan_board_key(r.p, name)
	if !found {
		decision_problem(r.p, line, "the blackboard has no key named %s", name)
		return
	}
	for planning, i in r.planning {
		if planning == u32(slot) {
			return u32(i), r.p.keys[slot], true
		}
	}
	decision_problem(r.p, line, "%s is not a planning key: the header's keys name them", name)
	return
}

// plan_value is a value of a planning key in the planner's world state: true or false for a bool, as 1 or 0, an
// integer for an int, and one of its names for an enum, as its index.
@(private = "file")
plan_value :: proc(p: ^Decision_Parser, key: format.Blackboard_Key_Contents, value: string, line: int) -> (i32, bool) {
	#partial switch key.type {
	case .Bool:
		switch value {
		case "true":
			return 1, true
		case "false":
			return 0, true
		}
		decision_problem(p, line, "%s is a bool, which is true or false, not %s", key.name, value)
	case .Int:
		if v, ok := strconv.parse_i64(value); ok && v >= i64(min(i32)) && v <= i64(max(i32)) {
			return i32(v), true
		}
		decision_problem(p, line, "%s is an int, and %s is not one", key.name, value)
	case .Enum:
		for name, i in key.enum_names {
			if name == value {
				return i32(i), true
			}
		}
		decision_problem(p, line, "%s has no value %s: it is %s", key.name, value, strings.join(key.enum_names, ", ", context.temp_allocator))
	}
	return 0, false
}

// plan_board_key is the slot and type of the blackboard's key of a name.
plan_board_key :: proc(p: ^Decision_Parser, name: string) -> (slot: int, type: format.Blackboard_Type, found: bool) {
	for k, i in p.keys {
		if k.name == name {
			return i, k.type, true
		}
	}
	return -1, {}, false
}
