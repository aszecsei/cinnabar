package script

import "core:strings"
import "core:testing"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// The recorder's fixture: the world's entities with a Score are the document's, and the runtime is in Edit mode.
@(private = "file")
setup_document :: proc(t: ^testing.T) -> ^World_Fixture {
	f := setup_world(t)
	context.user_ptr = f
	set_document_component(&f.runtime, ecs.registry_find_type(&f.world.registry, Score).id)
	set_callbacks(&f.runtime, .Edit_Mode)
	return f
}

// document_entity spawns an entity of the document, at the origin, with a Health.
@(private = "file")
document_entity :: proc(f: ^World_Fixture, value: i32 = 1) -> ecs.Entity {
	e := ecs.spawn(&f.world)
	ecs.add(&f.world, e, ecs.TRANSFORM_IDENTITY)
	ecs.add(&f.world, e, Score{})
	ecs.add(&f.world, e, Health{value = value})
	return e
}

// tool runs a main script that defines Tool, an edit-mode class with the update given, and adds it to a new entity of
// the game's own.
@(private = "file")
tool :: proc(t: ^testing.T, f: ^World_Fixture, update: string, loc := #caller_location) {
	source := strings.concatenate(
		{
			`
Tool = Behaviour.define("Tool", {}, {edit_mode = true})
function Tool:update()
	local doc = World.query(Score)[1]
`,
			update,
			`
end
World.spawn():add(Tool)
`,
		},
		context.temp_allocator,
	)
	testing.expect(t, run(t, f, source), loc = loc)
}

@(test)
a_field_write_in_edit_is_recorded_and_the_world_keeps_its_value :: proc(t: ^testing.T) {
	f := setup_document(t)
	defer teardown_world(f)
	context.user_ptr = f
	e := document_entity(f)
	// The script reads back what it wrote, and the world keeps its value.
	tool(t, f, "local h = doc:get(Health) h.value = 5 h.value = h.value + 1 Test.report(h.value)")
	run_edit_phase(&f.runtime, FRAME)
	expect_reports(t, f, {6})
	testing.expect_value(t, ecs.get(&f.world, e, Health).value, 1)

	edits := take_edits(&f.runtime)
	testing.expect_value(t, edits.class, "Tool")
	testing.expect_value(t, len(edits.list), 1)
	testing.expect_value(t, len(edits.components), 1)
	if len(edits.components) == 1 {
		c := edits.components[0]
		testing.expect_value(t, c.entity, e)
		testing.expect_value(t, (^Health)(raw_data(c.before)).value, 1)
		testing.expect_value(t, (^Health)(raw_data(c.after)).value, 6)
	}
	// Taken edits are gone, and the next phase writes from the world's value again.
	testing.expect_value(t, len(take_edits(&f.runtime).list), 0)
}

@(test)
a_childs_pose_records_its_local_transform :: proc(t: ^testing.T) {
	f := setup_document(t)
	defer teardown_world(f)
	context.user_ptr = f
	parent := document_entity(f)
	child := ecs.spawn(&f.world)
	ecs.add(&f.world, child, Score{})
	ecs.add(&f.world, child, ecs.TRANSFORM_IDENTITY)
	ecs.add(&f.world, child, ecs.Parent{parent})
	ecs.add(&f.world, child, ecs.LOCAL_TRANSFORM_IDENTITY)
	testing.expect(
		t,
		run(
			t,
			f,
			`
Tool = Behaviour.define("Tool", {}, {edit_mode = true})
function Tool:update()
	for _, e in World.query(Score) do
		if e.parent ~= nil then
			e:move(vector.create(0, 2, 0))
			Test.report(e.transform.local_position.y)
		end
	end
end
World.spawn():add(Tool)
`,
		),
	)
	run_edit_phase(&f.runtime, FRAME)
	expect_reports(t, f, {2})
	edits := take_edits(&f.runtime)
	local := edited_in(edits, child, ecs.LOCAL_TRANSFORM_ID)
	testing.expect(t, local != nil)
	if local != nil {
		testing.expect_value(
			t,
			(^ecs.Local_Transform)(raw_data(local.after)).offset,
			[3]f32{0, 2, 0},
		)
	}
	testing.expect_value(t, ecs.get(&f.world, child, ecs.Local_Transform).offset, [3]f32{})
}

@(test)
structural_changes_in_edit_are_recorded :: proc(t: ^testing.T) {
	f := setup_document(t)
	defer teardown_world(f)
	context.user_ptr = f
	e := document_entity(f)
	other := document_entity(f)
	tool(
		t,
		f,
		`
	local other = World.query(Score)[2]
	doc:remove(Health)
	doc:set_active(false)
	doc:set_parent(other)
	other:destroy()
	local added = other:add(Score, {})
	Test.report(if other:has(Score) then 1 else 0)
	Test.report(if doc:is_alive() and other:is_alive() then 1 else 0)
`,
	)
	run_edit_phase(&f.runtime, FRAME)
	expect_reports(t, f, {1, 1})
	// The world has none of it.
	testing.expect(t, ecs.has(&f.world, e, Health))
	testing.expect(t, ecs.active_self(&f.world, e))
	testing.expect(t, !ecs.has(&f.world, e, ecs.Parent))
	testing.expect(t, ecs.is_alive(&f.world, other))

	edits := take_edits(&f.runtime)
	testing.expect_value(t, len(edits.list), 5)
	if len(edits.list) == 5 {
		testing.expect_value(t, edits.list[0].(Edit_Remove).entity, e)
		testing.expect_value(t, edits.list[1].(Edit_Active), Edit_Active{e, false})
		testing.expect_value(t, edits.list[2].(Edit_Parent), Edit_Parent{e, other})
		testing.expect_value(t, edits.list[3].(Edit_Destroy).entity, other)
		added := edits.components[edits.list[4].(Edit_Component).index]
		testing.expect(t, added.before == nil)
	}
}

@(test)
a_spawn_in_edit_is_a_draft :: proc(t: ^testing.T) {
	f := setup_document(t)
	defer teardown_world(f)
	context.user_ptr = f
	tool(
		t,
		f,
		`
	if Time.frame > 2 then return end
	local draft = World.spawn(doc.transform.position)
	draft:add(Health, {value = 7})
	draft:set_parent(doc)
`,
	)
	document_entity(f)
	run_edit_phase(&f.runtime, FRAME)
	edits := take_edits(&f.runtime)
	testing.expect_value(t, len(edits.list), 1)
	if len(edits.list) == 1 {
		spawn := edits.list[0].(Edit_Spawn)
		testing.expect_value(t, spawn.prefab, format.Guid{})
		// A draft is the world's until the game takes it: its writes apply.
		testing.expect_value(t, ecs.get(&f.world, spawn.entity, Health).value, 7)
		testing.expect(t, ecs.has(&f.world, spawn.entity, ecs.Parent))
	}
}

@(test)
writes_outside_the_documents_entities_and_its_behaviours_stay_raw :: proc(t: ^testing.T) {
	f := setup_document(t)
	defer teardown_world(f)
	context.user_ptr = f
	e := document_entity(f)
	game := ecs.spawn(&f.world)
	ecs.add(&f.world, game, Health{value = 1})
	tool(
		t,
		f,
		`
	for _, g in World.query(Health) do
		if not g:has(Score) then g:get(Health).value = 3 end
	end
`,
	)
	run_edit_phase(&f.runtime, FRAME)
	testing.expect_value(t, ecs.get(&f.world, game, Health).value, 3)
	testing.expect_value(t, len(take_edits(&f.runtime).list), 0)

	// A main script is no behaviour, so it writes to the world, as it does in Play.
	testing.expect(t, run(t, f, "World.query(Score)[1]:get(Health).value = 9"))
	testing.expect_value(t, ecs.get(&f.world, e, Health).value, 9)
	testing.expect_value(t, len(take_edits(&f.runtime).list), 0)
}

@(test)
on_destroy_outside_the_phase_records_too :: proc(t: ^testing.T) {
	f := setup_document(t)
	defer teardown_world(f)
	context.user_ptr = f
	document_entity(f)
	testing.expect(
		t,
		run(
			t,
			f,
			`
Tool = Behaviour.define("Tool", {}, {edit_mode = true})
function Tool:on_destroy() World.query(Score)[1]:get(Health).value = 4 end
local holder = World.spawn()
holder:add(Tool)
holder:remove(Tool)
`,
		),
	)
	edits := take_edits(&f.runtime)
	testing.expect_value(t, len(edits.components), 1)
}

@(test)
leaving_edit_mode_drops_the_edits :: proc(t: ^testing.T) {
	f := setup_document(t)
	defer teardown_world(f)
	context.user_ptr = f
	document_entity(f)
	tool(t, f, "doc:get(Health).value = 2")
	run_edit_phase(&f.runtime, FRAME)
	set_callbacks(&f.runtime, .All)
	testing.expect_value(t, len(take_edits(&f.runtime).list), 0)
}

@(private = "file")
edited_in :: proc(edits: Edits, e: ecs.Entity, id: ecs.Component_Id) -> ^Edited_Component {
	for &c in edits.components {
		if c.entity == e && c.id == id {
			return &c
		}
	}
	return nil
}
