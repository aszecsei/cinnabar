package script

import "core:testing"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

@(private = "file")
PREFAB :: format.Guid{0 = 0x9d, 1 = 0xb8, 15 = 0x01}

@(private = "file")
OTHER :: format.Guid{0 = 0x9d, 1 = 0xb8, 15 = 0x02}

// The script that the test spawner attaches to the prefab's child. Tests run on their own threads, and only one sets it.
@(private = "file")
spawned_script: format.Guid

// A spawner as lib/engine/scene's, without a blob: a root at the pose, and a child with the spawned script.
@(private = "file")
test_spawner :: proc(r: ^Runtime, guid: format.Guid, pose: ecs.Transform) -> (root: ecs.Entity, behaviours: []Pending_Behaviour, message: string, ok: bool) {
	if guid != PREFAB {
		return 0, nil, "not the test's prefab", false
	}
	root = ecs.spawn(r.world)
	ecs.add(r.world, root, pose)
	child := ecs.spawn(r.world)
	ecs.add(r.world, child, ecs.Parent{root})
	pending := make([]Pending_Behaviour, 1, r.world.platform.frame_allocator)
	pending[0] = {child, spawned_script, nil}
	return root, pending, "", true
}

@(test)
asset_fields_hold_references_that_compare_by_guid :: proc(t: ^testing.T) {
	f := setup_reload(t)
	defer teardown_reload(f)
	context.user_ptr = f.base
	context.logger = capture_world_errors(f.base)
	holder := write_script(t, &f, 5, 0, `
local Holder = Behaviour.define("Holder", {prefab = Field.asset("prefab"), same = Field.asset(), other = Field.asset(), none = Field.asset()})
function Holder:start()
	Test.report(self.prefab == self.same and 1 or 0)
	Test.report(self.prefab ~= self.other and 1 or 0)
	Test.report(self.none == nil and 1 or 0)
	Test.report(string.find(tostring(self.prefab), "Asset(9db8", 1, true) and 1 or 0)
	Test.report(#self.prefab.guid)
end
return Holder`)
	e := ecs.spawn(&f.world)
	fields := []Behaviour_Field {
		{name = "prefab", kind = .Asset, asset = PREFAB},
		{name = "same", kind = .Asset, asset = PREFAB},
		{name = "other", kind = .Asset, asset = OTHER},
		// A number does not go in an asset field.
		{name = "none", kind = .Number, number = 4},
	}
	testing.expect(t, attach_script(&f.runtime, e, holder, fields))
	phase(f.base)
	expect_reports(t, f, {1, 1, 1, 1, 32})

	// The editor sees an asset field as one, with its kind, even while it holds none.
	snapshots := inspect(&f.runtime, e, context.temp_allocator)
	testing.expect_value(t, len(snapshots), 1)
	for field in snapshots[0].fields {
		testing.expectf(t, field.kind == .Asset, "%s is %v", field.name, field.kind)
		switch field.name {
		case "prefab":
			testing.expect_value(t, field.asset, PREFAB)
			testing.expect_value(t, field.asset_kind, "prefab")
		case "none":
			testing.expect_value(t, field.asset, format.Guid{})
			testing.expect_value(t, field.asset_kind, "")
		}
	}
}

@(test)
world_spawn_of_a_prefab_wakes_its_behaviours_before_it_returns :: proc(t: ^testing.T) {
	f := setup_reload(t)
	defer teardown_reload(f)
	context.user_ptr = f.base
	context.logger = capture_world_errors(f.base)
	spawned_script = write_script(t, &f, 6, 0, `
local Turret = Behaviour.define("Turret")
function Turret:awake() Test.report(7) end
function Turret:on_enable() Test.report(8) end
return Turret`)
	spawner := write_script(t, &f, 7, 0, `
local Spawner = Behaviour.define("Spawner", {prefab = Field.asset("prefab")})
function Spawner:start()
	local root = World.spawn(self.prefab, WorldPosition.from_meters(3, 0, 0))
	Test.report(1)
	Test.report(select(1, root.transform.position:to_meters()))
	local ok, message = pcall(World.spawn, self.missing_prefab)
	Test.report(ok and 0 or 1)
end
return Spawner`)
	set_prefab_spawner(&f.runtime, test_spawner)
	e := ecs.spawn(&f.world)
	testing.expect(t, attach_script(&f.runtime, e, spawner, {{name = "prefab", kind = .Asset, asset = PREFAB}}))
	phase(f.base)
	// awake and on_enable run inside World.spawn, before the next line; a spawn without a prefab spawns an entity.
	expect_reports(t, f, {7, 8, 1, 3, 0})
}

@(test)
world_spawn_of_a_prefab_needs_the_scene_loader :: proc(t: ^testing.T) {
	f := setup_reload(t)
	defer teardown_reload(f)
	context.user_ptr = f.base
	context.logger = capture_world_errors(f.base)
	spawner := write_script(t, &f, 8, 0, `
local Spawner = Behaviour.define("Spawner", {prefab = Field.asset()})
function Spawner:start()
	local ok, message = pcall(World.spawn, self.prefab)
	Test.report(ok and 0 or 1)
	Test.report(string.find(message, "scene.register_scripts", 1, true) and 1 or 0)
end
return Spawner`)
	e := ecs.spawn(&f.world)
	testing.expect(t, attach_script(&f.runtime, e, spawner, {{name = "prefab", kind = .Asset, asset = PREFAB}}))
	phase(f.base)
	expect_reports(t, f, {1, 1})

}
