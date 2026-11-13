package asset_format

// Plans are what the planning techniques, GOAP and HTN, share (see docs/ai/goap.md#the-plan-runner): the planning keys,
// a bool, int or enum key each, whose values make the planner's world state; actions with tests on those keys, effects
// on them and a cost; and the runner's state in the agent's module state. A world state is one i32 for each planning
// key, in the order that the decision names them: a bool is 0 or 1, an int is itself, and an enum is its index.

// A decision plans over at most this many keys, so a set of them is a u32.
MAX_PLAN_KEYS :: 32
// A plan is at most this many actions.
MAX_PLAN_LENGTH :: 32

// Plan_Test is a test of a planning key, by its index among the planning keys: the key's value is from lo to hi. The
// cook makes one interval of all the tests of one key in a text's tests.
Plan_Test :: struct {
	key: u32,
	lo:  i32,
	hi:  i32,
}
#assert(size_of(Plan_Test) == 12)

// Plan_Interval is what a planning key may be in a state that a search regressed to: from lo to hi.
Plan_Interval :: struct {
	lo: i32,
	hi: i32,
}
#assert(size_of(Plan_Interval) == 8)

// Plan_Effect_Op is what an effect does: Set sets the key to its value, and Add adds its value to an int key.
Plan_Effect_Op :: enum u8 {
	Set,
	Add,
}

// Plan_Effect is an effect of an action on a planning key, by its index among the planning keys.
Plan_Effect :: struct {
	key:     u32,
	op:      Plan_Effect_Op,
	padding: [3]u8,
	value:   i32,
}
#assert(size_of(Plan_Effect) == 12)

// Plan_Number_Source is where a number comes from: the record's constant, or a float or int key.
Plan_Number_Source :: enum u8 {
	Constant,
	Key,
}

// Plan_Number is a constant, or the value of the key at the slot key.
Plan_Number :: struct {
	value:   f32,
	key:     u32,
	source:  Plan_Number_Source,
	padding: [3]u8,
}
#assert(size_of(Plan_Number) == 12)

// Plan_Action is an action that a plan can hold: its decision node, whose guard, action and writes are the action's, its
// cost, and its preconditions and effects, ranges of the tests and the effects.
Plan_Action :: struct {
	node:         u32,
	cost:         Plan_Number,
	first_test:   u32,
	test_count:   u32,
	first_effect: u32,
	effect_count: u32,
}
#assert(size_of(Plan_Action) == 32)

// Plan_Run is the plan runner's state in the agent's module state, beside the plan's steps and its expected world state,
// whose offsets the technique's layout gives: the step that runs, the plan's length, and the planning keys that the rest
// of the plan depends on, as a set of their indices.
Plan_Run :: struct {
	step:    u32,
	length:  u32,
	depends: u32,
	padding: u32,
}
#assert(size_of(Plan_Run) == 16)

// plan_tests_ok is whether tests are of planning keys and not empty.
plan_tests_ok :: proc "contextless" (tests: []Plan_Test, key_count: u32) -> bool {
	for t in tests {
		if t.key >= key_count || t.lo > t.hi {
			return false
		}
	}
	return true
}

// plan_effects_ok is whether effects are of planning keys and their ops are known.
plan_effects_ok :: proc "contextless" (effects: []Plan_Effect, key_count: u32) -> bool {
	for e in effects {
		if e.key >= key_count || e.op > max(Plan_Effect_Op) {
			return false
		}
	}
	return true
}

// plan_keys_ok is whether planning keys are distinct bool, int or enum keys of a blackboard, and whether each effect
// fits its key: an add only on an int, a bool set to 0 or 1, and an enum set to one of its names.
plan_keys_ok :: proc(planning: []u32, effects: []Plan_Effect, keys: []Blackboard_Key) -> bool {
	for slot, i in planning {
		if int(slot) >= len(keys) || keys[slot].type not_in (bit_set[Blackboard_Type]{.Bool, .Int, .Enum}) {
			return false
		}
		for other in planning[:i] {
			if other == slot {
				return false
			}
		}
	}
	for e in effects {
		key := keys[planning[e.key]]
		switch e.op {
		case .Add:
			if key.type != .Int {
				return false
			}
		case .Set:
			if key.type == .Bool && (e.value < 0 || e.value > 1) {
				return false
			}
			if key.type == .Enum && (e.value < 0 || u32(e.value) >= key.enum_count) {
				return false
			}
		}
	}
	return true
}
