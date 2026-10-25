package asset_format

import "core:strings"
import "core:testing"

@(private = "file")
DOOR :: `# A door and its trigger.
scene 1

entity 5f3a9c01e2b47d10
name = "Door \"A\""
parent = @1b04c7e95a2f3d88
component 1 Transform
	position = [2516582400000000000, 0, -754974720]
	rotation = [0, 0.7071068, 0, 0.7071068]
	scale = [1, 1, 1]
behaviour 9d2e41c0b7a35f6e81c4d2a90b3e7f15
	open_angle = 90.5
	trigger = @7a11e0c3d94b2f56
	mode = Swing

entity 1b04c7e95a2f3d88
active = false
component 5 Disabled
`

@(test)
scene_files_parse :: proc(t: ^testing.T) {
	scene, problems, ok := scene_parse(DOOR, context.temp_allocator)
	testing.expectf(t, ok, "problems: %v", problems)
	testing.expect_value(t, len(scene.entities), 2)
	door := scene.entities[0]
	testing.expect_value(t, door.id, 0x5f3a9c01e2b47d10)
	testing.expect_value(t, door.name, `Door "A"`)
	testing.expect_value(t, door.parent, 0x1b04c7e95a2f3d88)
	testing.expect(t, door.active)
	testing.expect_value(t, len(door.components), 1)
	transform := door.components[0]
	testing.expect_value(t, transform.id, 1)
	testing.expect_value(t, transform.name, "Transform")
	position := transform.fields[0]
	testing.expect_value(t, position.name, "position")
	testing.expect_value(t, position.hash, scene_field_hash("position"))
	testing.expect_value(t, position.value.kind, Scene_Value_Kind.Number)
	testing.expect_value(t, position.value.count, 3)
	testing.expect_value(t, position.value.integer, 0b111)
	// Raw positions are beyond an f64's exact range, so the integers are kept as written.
	testing.expect_value(t, position.value.ints[0], 2516582400000000000)
	testing.expect_value(t, position.value.ints[2], -754974720)
	rotation := transform.fields[1].value
	testing.expect_value(t, rotation.integer, 0b0101)
	testing.expect_value(t, rotation.floats[3], 0.7071068)

	behaviour := door.behaviours[0]
	testing.expect_value(t, behaviour.script, guid_parse("9d2e41c0b7a35f6e81c4d2a90b3e7f15") or_else {})
	testing.expect_value(t, behaviour.fields[0].value.floats[0], 90.5)
	testing.expect_value(t, behaviour.fields[0].value.integer, 0)
	testing.expect_value(t, behaviour.fields[1].value.kind, Scene_Value_Kind.Entity)
	testing.expect_value(t, behaviour.fields[1].value.entity, 0x7a11e0c3d94b2f56)
	testing.expect_value(t, behaviour.fields[2].value.kind, Scene_Value_Kind.Name)
	testing.expect_value(t, behaviour.fields[2].value.text, "Swing")

	testing.expect(t, !scene.entities[1].active)
}

@(test)
scene_blobs_round_trip :: proc(t: ^testing.T) {
	scene, _, ok := scene_parse(DOOR, context.temp_allocator)
	testing.expect(t, ok)
	guid := guid_parse(TEST_GUID) or_else {}
	blob := aligned(scene_write(scene, guid, 42, context.temp_allocator))
	header, header_ok := blob_header(blob)
	testing.expect(t, header_ok && header.kind == .Scene && header.key == 42 && header.guid == guid)

	read, read_ok := scene_read(blob, context.temp_allocator)
	testing.expect(t, read_ok)
	testing.expect_value(t, len(read.entities), 2)
	door := read.entities[0]
	testing.expect_value(t, door.name, `Door "A"`)
	testing.expect_value(t, door.parent, scene.entities[0].parent)
	testing.expect_value(t, door.components[0].fields[0].value, scene.entities[0].components[0].fields[0].value)
	testing.expect_value(t, door.behaviours[0].fields[2].value.text, "Swing")
	testing.expect(t, !read.entities[1].active)

	// A slice that leaves the blob is refused.
	(^Scene_Blob)(raw_data(blob)).entities.size = u32(len(blob))
	_, read_ok = scene_read(blob, context.temp_allocator)
	testing.expect(t, !read_ok)
}

@(test)
asset_values_are_guids :: proc(t: ^testing.T) {
	text := "scene 1\nentity 0000000000000001\ncomponent 1 T\n\tmesh = $9db8150cc7215ffc2708d20d77cf60bf\n\tnone = $0\n"
	scene, _, ok := scene_parse(text, context.temp_allocator)
	testing.expect(t, ok)
	fields := scene.entities[0].components[0].fields
	testing.expect_value(t, fields[0].value.kind, Scene_Value_Kind.Asset)
	testing.expect_value(t, fields[0].value.asset, guid_parse("9db8150cc7215ffc2708d20d77cf60bf") or_else {})
	testing.expect_value(t, fields[1].value, Scene_Value{kind = .Asset})

	// The GUID survives the blob.
	data := aligned(scene_write(scene, {}, 0, context.temp_allocator))
	read, read_ok := scene_read(data, context.temp_allocator)
	testing.expect(t, read_ok)
	testing.expect_value(t, read.entities[0].components[0].fields[0].value.asset, fields[0].value.asset)
}

@(test)
scene_errors_name_their_line :: proc(t: ^testing.T) {
	cases := [?]struct {
		text, fragment: string,
		line:           int,
	} {
		{"entity 0000000000000001\n", "starts with `scene 1`", 1},
		{"scene 1\nentity 12\n", "16 hex digits", 2},
		{"scene 1\ncomponent 1 Transform\n", "needs an entity", 2},
		{"scene 1\nentity 0000000000000001\n\tx = 1\n", "no component or behaviour is open", 3},
		{"scene 1\nentity 0000000000000001\ncomponent 1 T\n\tx = [1, 2\n", "ends with ]", 4},
		{"scene 1\nentity 0000000000000001\ncomponent 1 T\n\tx = 1\n\tx = 2\n", "set twice", 5},
		{"scene 1\nentity 0000000000000001\ncomponent 1 T\n\tx = \"a\\q\"\n", "not an escape", 4},
		{"scene 1\nentity 0000000000000001\ncomponent 1 T\ncomponent 1 T\n", "twice", 4},
		{"scene 1\nentity 0000000000000001\ncomponent 1 T\n\tx = 1.2.3\n", "not a number", 4},
		{"scene 1\nentity 0000000000000001\ncomponent 1 T\n\tx = $12\n", "32 hex digits after $", 4},
	}
	for c in cases {
		_, problems, ok := scene_parse(c.text, context.temp_allocator)
		testing.expectf(t, !ok, "%q parsed", c.text)
		found := false
		for p in problems {
			found ||= p.error && p.line == c.line && strings.contains(p.message, c.fragment)
		}
		testing.expectf(t, found, "%q: no error at line %d with %q: %v", c.text, c.line, c.fragment, problems)
	}

	_, problems, ok := scene_parse("scene 1\nentity 0000000000000001\ncolor = 3\n", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect(t, len(problems) == 1 && !problems[0].error && problems[0].line == 3)

	_, problems, ok = scene_parse("scene 1\nentity 0000000000000001\nentity 0000000000000001\n", context.temp_allocator)
	testing.expect(t, !ok)
}
