package asset_format

import "core:strings"
import "core:testing"

// A room with a lamp in the night sublevel, the lamp's bulb, which inherits it, a crate in the base, and an instance in
// the night sublevel with an override block and a child of one of its entities.
@(private = "file")
ROOM :: `scene 4

entity 0000000000000001
name = "Lamp"
sublevel = "night"

entity 0000000000000002
name = "Bulb"
parent = @0000000000000001

entity 0000000000000003
name = "Crate"

entity 0000000000000004
name = "Shade"
parent = @0000000000000001
sublevel = "night"

entity 5000000000000001
prefab = $9db8150cc7215ffc2708d20d77cf60bf
sublevel = "night"

entity 5000000000000001#2000000000000002
name = "Handle"

entity 0000000000000005
parent = @5000000000000001#2000000000000002
`

@(private = "file")
find_entity :: proc(scene: Scene, id: u64) -> Scene_Entity {
	for e in scene.entities {
		if e.id == id {
			return e
		}
	}
	return {}
}

@(private = "file")
has_problem :: proc(problems: []Scene_Problem, error: bool, fragment: string) -> bool {
	for p in problems {
		if p.error == error && strings.contains(p.message, fragment) {
			return true
		}
	}
	return false
}

@(test)
entities_inherit_their_parents_sublevel :: proc(t: ^testing.T) {
	scene, problems, ok := scene_parse(ROOM, context.temp_allocator)
	testing.expectf(t, ok && len(problems) == 0, "problems: %v", problems)
	testing.expect_value(t, find_entity(scene, 1).sublevel, "night")
	testing.expect_value(t, find_entity(scene, 2).sublevel, "night")
	testing.expect_value(t, find_entity(scene, 3).sublevel, "")
	// A key that is the parent's own is not an error.
	testing.expect_value(t, find_entity(scene, 4).sublevel, "night")
	testing.expect_value(t, find_entity(scene, 0x5000000000000001).sublevel, "night")
	override := scene_path_id_of({0x5000000000000001, 0x2000000000000002})
	testing.expect_value(t, find_entity(scene, override).sublevel, "night")
	// A parent on a path is in its instance's sublevel.
	testing.expect_value(t, find_entity(scene, 5).sublevel, "night")
}

@(test)
a_sublevel_other_than_the_parents_is_an_error :: proc(t: ^testing.T) {
	cases := [?]struct {
		text: string,
		line: int,
	} {
		{
			"scene 4\nentity 0000000000000001\nsublevel = \"night\"\n\nentity 0000000000000002\nparent = @0000000000000001\nsublevel = \"day\"\n",
			7,
		},
		{
			"scene 4\nentity 0000000000000002\nparent = @0000000000000001\nsublevel = \"day\"\n\nentity 0000000000000001\n",
			4,
		},
		{
			"scene 4\nentity 5000000000000001\nprefab = $9db8150cc7215ffc2708d20d77cf60bf\n\nentity 5000000000000001#2000000000000002\nsublevel = \"night\"\n",
			6,
		},
		{
			"scene 4\nentity 5000000000000001\nprefab = $9db8150cc7215ffc2708d20d77cf60bf\nsublevel = \"night\"\n\nentity 0000000000000005\nparent = @5000000000000001#2000000000000002\nsublevel = \"day\"\n",
			8,
		},
	}
	for c in cases {
		_, problems, ok := scene_parse(c.text, context.temp_allocator)
		testing.expectf(t, !ok, "%q parsed", c.text)
		found := false
		for p in problems {
			found ||=
				p.error &&
				p.line == c.line &&
				p.message == "an entity cannot be in a sublevel other than its parent's"
		}
		testing.expectf(t, found, "%q: no error at line %d: %v", c.text, c.line, problems)
	}
}

@(test)
a_sublevel_takes_a_quoted_name :: proc(t: ^testing.T) {
	for value in ([]string{"night", "\"\"", "\"two words\"", "true", "\"a-b\""}) {
		text := strings.concatenate(
			{"scene 4\nentity 0000000000000001\nsublevel = ", value, "\n"},
			context.temp_allocator,
		)
		_, problems, ok := scene_parse(text, context.temp_allocator)
		testing.expectf(
			t,
			!ok && has_problem(problems, true, "sublevel takes a quoted name"),
			"%s: %v",
			value,
			problems,
		)
	}
}

@(test)
a_prefabs_sublevel_is_ignored :: proc(t: ^testing.T) {
	text := "scene 4\nentity 0000000000000001\nsublevel = \"night\"\n"
	scene, problems, ok := scene_parse(text, context.temp_allocator, {prefab = true})
	testing.expect(t, ok)
	testing.expectf(
		t,
		len(problems) == 1 && has_problem(problems, false, "the prefab's sublevel is ignored"),
		"problems: %v",
		problems,
	)
	testing.expect_value(t, scene.entities[0].sublevel, "")
}

@(test)
an_undeclared_sublevel_is_a_warning :: proc(t: ^testing.T) {
	declared := []Sublevel{{name = "night"}}
	text := "scene 4\nentity 0000000000000001\nsublevel = \"dusk\"\n\nentity 0000000000000002\nsublevel = \"night\"\n"
	scene, problems, ok := scene_parse(text, context.temp_allocator, {sublevels = declared})
	testing.expect(t, ok)
	testing.expectf(
		t,
		len(problems) == 1 && problems[0].line == 3 && has_problem(problems, false, "dusk"),
		"problems: %v",
		problems,
	)
	// The entity stays in it.
	testing.expect_value(t, scene.entities[0].sublevel, "dusk")

	// Without the project's declaration, no name is checked.
	_, problems, ok = scene_parse(text, context.temp_allocator)
	testing.expect(t, ok && len(problems) == 0)
	// A project that declares none warns about every name.
	_, problems, ok = scene_parse(text, context.temp_allocator, {sublevels = []Sublevel{}})
	testing.expect(t, ok && len(problems) == 2)
}

@(test)
an_instances_entities_are_in_its_sublevel :: proc(t: ^testing.T) {
	prefab_text := "scene 4\nentity 2000000000000001\nname = \"Door\"\n\nentity 2000000000000002\nparent = @2000000000000001\n"
	prefab, prefab_problems, prefab_ok := scene_parse(
		prefab_text,
		context.temp_allocator,
		{prefab = true},
	)
	testing.expectf(t, prefab_ok, "problems: %v", prefab_problems)
	prefabs := make(map[Guid]Scene, context.temp_allocator)
	guid, _ := guid_parse("9db8150cc7215ffc2708d20d77cf60bf")
	prefabs[guid] = prefab
	resolver := Prefab_Resolver {
		data = &prefabs,
		find = proc(data: rawptr, prefab: Guid) -> (Scene, bool) {
			scene, found := (^map[Guid]Scene)(data)[prefab]
			return scene, found
		},
	}
	level, problems, ok := scene_parse(ROOM, context.temp_allocator)
	testing.expectf(t, ok, "problems: %v", problems)
	flat, expand_problems, expand_ok := scene_expand(
		level,
		resolver,
		allocator = context.temp_allocator,
	)
	testing.expectf(t, expand_ok, "problems: %v", expand_problems)
	testing.expect_value(t, find_entity(flat, 0x5000000000000001).sublevel, "night")
	handle := scene_path_id(0x5000000000000001, 0x2000000000000002)
	testing.expect_value(t, find_entity(flat, handle).name, "Handle")
	testing.expect_value(t, find_entity(flat, handle).sublevel, "night")
	testing.expect_value(t, find_entity(flat, 3).sublevel, "")
}

@(test)
project_settings_declare_sublevels :: proc(t: ^testing.T) {
	text := "# Sublevels.\nsublevel.night = inactive\nsublevel.day = active\nsublevel.bad-name = active\nsublevel.dusk = maybe\nsublevel.night = active\n"
	sublevels, problems := sublevels_parse(text, context.temp_allocator)
	testing.expect_value(t, len(sublevels), 2)
	testing.expect_value(t, sublevels[0], Sublevel{"night", true})
	testing.expect_value(t, sublevels[1], Sublevel{"day", true})
	testing.expectf(t, len(problems) == 2, "problems: %v", problems)
	testing.expect_value(t, problems[0].line, 4)
	testing.expect_value(t, problems[1].line, 5)
	testing.expect(t, strings.contains(problems[1].text, "active or inactive"))
	testing.expect_value(t, sublevel_check_setting("sublevel.night", "inactive"), "")
	testing.expect(t, sublevel_check_setting("sublevel.", "active") != "")
	testing.expect(t, sublevel_is_setting("sublevel.night"))
	testing.expect(t, !sublevel_is_setting("sublevels"))
}
