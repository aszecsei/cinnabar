package asset_format

import "core:fmt"
import "core:strings"
import "core:testing"

// testdata/prefabs is shared with the editor's PrefabExpansion tests, so the two expansions agree.
@(private = "file")
FIXTURE := #load_directory("testdata/prefabs")

@(private = "file")
Fixture :: struct {
	prefabs:  map[Guid]Scene,
	level:    Scene,
	expected: Scene,
}

@(private = "file")
load_fixture :: proc(t: ^testing.T) -> (f: Fixture) {
	f.prefabs = make(map[Guid]Scene, context.temp_allocator)
	for file in FIXTURE {
		text := string(file.data)
		switch {
		case strings.has_suffix(file.name, PREFAB_EXTENSION):
			meta_text := ""
			for m in FIXTURE {
				if m.name == fmt.tprintf("%s%s", file.name, META_EXTENSION) {
					meta_text = string(m.data)
				}
			}
			meta, meta_ok := meta_parse(meta_text, context.temp_allocator)
			scene, problems, ok := scene_parse(text, context.temp_allocator)
			testing.expectf(t, meta_ok && ok, "%s: %v", file.name, problems)
			f.prefabs[meta.guid] = scene
		case file.name == "level.scene":
			scene, problems, ok := scene_parse(text, context.temp_allocator)
			testing.expectf(t, ok, "level.scene: %v", problems)
			f.level = scene
		case file.name == "expected.scene":
			scene, problems, ok := scene_parse(text, context.temp_allocator)
			testing.expectf(t, ok, "expected.scene: %v", problems)
			f.expected = scene
		}
	}
	return
}

@(private = "file")
resolver_of :: proc(prefabs: ^map[Guid]Scene) -> Prefab_Resolver {
	return {data = prefabs, find = proc(data: rawptr, prefab: Guid) -> (Scene, bool) {
			scene, found := (^map[Guid]Scene)(data)[prefab]
			return scene, found
		}}
}

@(test)
path_ids_are_pinned :: proc(t: ^testing.T) {
	// The editor's ScenePath tests pin the same values.
	testing.expect_value(t, scene_path_id(1, 2), 0x7717980363c8e066)
	testing.expect_value(t, scene_path_id(0x5f3a9c01e2b47d10, 0xa90b3e7f15c4d2e8), 0x68bd608f979f4aa6)
	testing.expect_value(t, scene_path_id_of({0x5000000000000001, 0x2000000000000005, 0x1000000000000002}), 0x3fd7ace1e2ddd054)
	testing.expect_value(t, scene_path_id_of({0x5000000000000001, 0x2000000000000005, 0x1000000000000002}), scene_path_id(0x5000000000000001, scene_path_id(0x2000000000000005, 0x1000000000000002)))
	testing.expect_value(t, scene_path_id_of({42}), 42)
}

@(test)
the_fixture_expands_to_its_expected_scene :: proc(t: ^testing.T) {
	f := load_fixture(t)
	flat, problems, ok := scene_expand(f.level, resolver_of(&f.prefabs), allocator = context.temp_allocator)
	testing.expectf(t, ok, "problems: %v", problems)
	expect_scene(t, flat, f.expected)

	// The warnings are the missing prefab, the override whose entity is gone, and door.prefab's reference to an entity
	// that it does not have, for the scene's own instance of the door. The variant's instance is the variant's
	// warning, at its own cook.
	warnings := [?]string{"44444444444444444444444444444444 is missing", "5000000000000001#2000000000000009", "instance 5000000000000001: the field bell refers to 20000000000000ff"}
	testing.expectf(t, len(problems) == len(warnings), "problems: %v", problems)
	for w in warnings {
		found := false
		for p in problems {
			found ||= !p.error && strings.contains(p.message, w)
		}
		testing.expectf(t, found, "no warning with %q: %v", w, problems)
	}
}

@(private = "file")
expect_scene :: proc(t: ^testing.T, got, want: Scene) {
	testing.expect_value(t, len(got.entities), len(want.entities))
	for w, i in want.entities[:min(len(want.entities), len(got.entities))] {
		g := got.entities[i]
		testing.expectf(t, g.id == w.id && g.name == w.name && g.parent == w.parent && g.active == w.active, "entity %d: %016x %q parent %016x active %v, not %016x %q parent %016x active %v", i, g.id, g.name, g.parent, g.active, w.id, w.name, w.parent, w.active)
		testing.expectf(t, len(g.components) == len(w.components), "%q has %d components, not %d", w.name, len(g.components), len(w.components))
		for wc, j in w.components[:min(len(w.components), len(g.components))] {
			gc := g.components[j]
			testing.expectf(t, gc.id == wc.id, "%q: component %d, not %d", w.name, gc.id, wc.id)
			expect_fields(t, w.name, gc.fields, wc.fields)
		}
		testing.expectf(t, len(g.behaviours) == len(w.behaviours), "%q has %d behaviours, not %d", w.name, len(g.behaviours), len(w.behaviours))
		for wb, j in w.behaviours[:min(len(w.behaviours), len(g.behaviours))] {
			testing.expect(t, g.behaviours[j].script == wb.script)
			expect_fields(t, w.name, g.behaviours[j].fields, wb.fields)
		}
		testing.expect(t, g.prefab == {} && g.path == nil)
	}
}

@(private = "file")
expect_fields :: proc(t: ^testing.T, entity: string, got, want: []Scene_Field) {
	testing.expectf(t, len(got) == len(want), "%q: %d fields, not %d", entity, len(got), len(want))
	for w, i in want[:min(len(want), len(got))] {
		testing.expectf(t, got[i].name == w.name && got[i].value == w.value, "%q: field %s = %v, not %s = %v", entity, got[i].name, got[i].value, w.name, w.value)
	}
}

@(test)
a_cycle_of_prefabs_is_an_error :: proc(t: ^testing.T) {
	a := guid_parse("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") or_else {}
	b := guid_parse("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb") or_else {}
	c := guid_parse("cccccccccccccccccccccccccccccccc") or_else {}
	parse :: proc(t: ^testing.T, text: string) -> Scene {
		scene, problems, ok := scene_parse(text, context.temp_allocator)
		testing.expectf(t, ok, "problems: %v", problems)
		return scene
	}
	prefabs := make(map[Guid]Scene, context.temp_allocator)
	// A contains B, which contains C, which contains A.
	prefabs[a] = parse(t, "scene 2\nentity 0000000000000001\nname = \"A\"\nentity 0000000000000002\nparent = @0000000000000001\nprefab = $bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n")
	prefabs[b] = parse(t, "scene 2\nentity 0000000000000001\nname = \"B\"\nentity 0000000000000002\nparent = @0000000000000001\nprefab = $cccccccccccccccccccccccccccccccc\n")
	prefabs[c] = parse(t, "scene 2\nentity 0000000000000001\nprefab = $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n")
	resolver := resolver_of(&prefabs)

	flat, problems, ok := scene_expand(prefabs[a], resolver, self = a, allocator = context.temp_allocator)
	testing.expect(t, !ok)
	testing.expectf(t, len(problems) == 1 && problems[0].error && strings.contains(problems[0].message, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa contains bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb contains cccccccccccccccccccccccccccccccc contains aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), "problems: %v", problems)
	// The instance that closes the cycle is its root alone, so A is A, B and C's root.
	testing.expect_value(t, len(flat.entities), 3)

	// A scene that names one of them cannot cook either.
	scene := parse(t, "scene 2\nentity 0000000000000009\nprefab = $bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n")
	_, problems, ok = scene_expand(scene, resolver, allocator = context.temp_allocator)
	testing.expect(t, !ok)

	// A prefab that contains itself directly.
	prefabs[c] = parse(t, "scene 2\nentity 0000000000000001\nentity 0000000000000002\nparent = @0000000000000001\nprefab = $cccccccccccccccccccccccccccccccc\n")
	_, problems, ok = scene_expand(prefabs[c], resolver, self = c, allocator = context.temp_allocator)
	testing.expect(t, !ok)
}

@(test)
nesting_beyond_the_depth_is_an_error :: proc(t: ^testing.T) {
	// Prefab n contains prefab n + 1, for more levels than the limit.
	prefabs := make(map[Guid]Scene, context.temp_allocator)
	for n in 0 ..= SCENE_EXPAND_DEPTH + 1 {
		guid: Guid
		guid[0] = u8(n + 1)
		text := "scene 2\nentity 0000000000000001\n"
		if n <= SCENE_EXPAND_DEPTH {
			inner: Guid
			inner[0] = u8(n + 2)
			buffer: [32]u8
			text = fmt.tprintf("%sentity 0000000000000002\nparent = @0000000000000001\nprefab = $%s\n", text, guid_format(inner, &buffer))
		}
		scene, _, ok := scene_parse(text, context.temp_allocator)
		testing.expect(t, ok)
		prefabs[guid] = scene
	}
	top: Guid
	top[0] = 1
	_, problems, ok := scene_expand(prefabs[top], resolver_of(&prefabs), self = top, allocator = context.temp_allocator)
	testing.expect(t, !ok)
	testing.expectf(t, len(problems) == 1 && strings.contains(problems[0].message, "more than 8 prefabs deep"), "problems: %v", problems)

	// The deepest nesting within the limit expands.
	within: Guid
	within[0] = 3
	_, problems, ok = scene_expand(prefabs[within], resolver_of(&prefabs), self = within, allocator = context.temp_allocator)
	testing.expectf(t, ok, "problems: %v", problems)
}

@(test)
version_2_keys_parse :: proc(t: ^testing.T) {
	text := `scene 2

entity 5f3a9c01e2b47d10
prefab = $9db8150cc7215ffc2708d20d77cf60bf
remove component 10
remove behaviour $9d2e41c0b7a35f6e81c4d2a90b3e7f15

entity 5f3a9c01e2b47d10#a90b3e7f15c4d2e8
name = ""
removed = true

entity 8c2e7b19d4f0a3c5
parent = @5f3a9c01e2b47d10#a90b3e7f15c4d2e8
`
	scene, problems, ok := scene_parse(text, context.temp_allocator)
	testing.expectf(t, ok, "problems: %v", problems)
	if len(scene.entities) != 3 {
		testing.fail(t)
		return
	}
	instance := scene.entities[0]
	testing.expect_value(t, instance.prefab, guid_parse("9db8150cc7215ffc2708d20d77cf60bf") or_else {})
	testing.expect_value(t, len(instance.removed_components), 1)
	testing.expect_value(t, instance.removed_components[0], 10)
	testing.expect_value(t, instance.removed_behaviours[0], guid_parse("9d2e41c0b7a35f6e81c4d2a90b3e7f15") or_else {})
	testing.expect_value(t, instance.keys, Scene_Keys{})
	override := scene.entities[1]
	testing.expect_value(t, len(override.path), 2)
	testing.expect_value(t, override.id, scene_path_id(0x5f3a9c01e2b47d10, 0xa90b3e7f15c4d2e8))
	testing.expect(t, override.removed)
	// An override that writes an empty name renames the entity to "".
	testing.expect_value(t, override.keys, Scene_Keys{.Name})
	testing.expect_value(t, scene.entities[2].parent, override.id)

	// Version 1 still reads.
	_, _, ok = scene_parse("scene 1\nentity 0000000000000001\n", context.temp_allocator)
	testing.expect(t, ok)

	cases := [?]struct {
		text, fragment: string,
	} {
		{"scene 2\nentity 0000000000000001\nremove component 3\n", "only an instance or an override block"},
		{"scene 2\nentity 0000000000000001\nremoved = true\n", "only an override block"},
		{"scene 2\nentity 0000000000000001#0000000000000002\nprefab = $9db8150cc7215ffc2708d20d77cf60bf\n", "cannot change which prefab"},
		{"scene 2\nentity 0000000000000001#00000002\n", "joined by #"},
		{"scene 2\nentity 0000000000000001\nprefab = $0\n", "prefab takes"},
		{"scene 2\nentity 0000000000000001\nprefab = $9db8150cc7215ffc2708d20d77cf60bf\nremove widget 3\n", "remove takes"},
		{"scene 2\nentity 0000000000000001\ncomponent 1 T\n\tx = @0000000000000001#\n", "joined by #"},
		{"scene 3\n", "starts with `scene 2`"},
	}
	for c in cases {
		_, problems, ok = scene_parse(c.text, context.temp_allocator)
		found := false
		for p in problems {
			found ||= p.error && strings.contains(p.message, c.fragment)
		}
		testing.expectf(t, !ok && found, "%q: no error with %q: %v", c.text, c.fragment, problems)
	}
}
