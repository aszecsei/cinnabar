package script

import "core:c"
import "core:fmt"
import "core:log"

import "cinnabar:core/luau"
import "cinnabar:core/profile"
import "cinnabar:engine/ecs"
import format "cinnabar:engine/asset/format"

MAX_INSTANCES :: 4096

// The prelude, which defines Behaviour and Field. tools/cook runs the same source.
PRELUDE :: #load("prelude.luau", string)

BEHAVIOURS_ID :: ecs.Component_Id(16)

// Behaviours marks an entity with behaviour instances. record is a registry reference to the entity's record table:
// its instances in the order they were added, and each class mapped to its instance.
Behaviours :: struct {
	// A Luau registry reference, which means nothing outside the VM. The editor reads behaviours with inspect.
	record: c.int `editor:"-"`,
}

// register_components registers the components that the script runtime uses. Call it from the game's component
// registration procedure, as with ecs.register_engine_components.
register_components :: proc(r: ^ecs.Registry) {
	ecs.register_component(r, Behaviours, BEHAVIOURS_ID)
}

@(private)
Instance_Flag :: enum u8 {
	Live,
	Awake,
	Started,
	// The behaviour's own switch, self.enabled.
	Enabled,
	// The entity is active in the hierarchy.
	Active,
	// The class has update, so the script phase calls it.
	Updates,
	// Created by native code: awake waits for the next script phase.
	Needs_Awake,
}

@(private)
Instance_Flags :: bit_set[Instance_Flag;u8]

// Instance is the native state of a behaviour instance. The instance's table holds its handle under a light
// userdata key, which scripts cannot make.
@(private)
Instance :: struct {
	table:      c.int,
	entity:     ecs.Entity,
	// The memory category of the class's module, which its callbacks allocate in (see memory.odin).
	category:   c.int,
	// Odd while the slot is live, so a stale handle never matches.
	generation: u32,
	flags:      Instance_Flags,
	// The class's name for the profiler.
	profile_class: profile.Name,
}

@(private)
Instance_Handle :: struct {
	index:      u32,
	generation: u32,
}

// effective is true when the instance gets update and events: enabled, active and awake.
@(private)
effective :: proc(i: ^Instance) -> bool {
	return i.flags >= {.Live, .Awake, .Enabled, .Active}
}

// run_prelude runs the prelude once, and sets Behaviour and Field. Its native procedures are dispatcher closures, so
// they reach the new DLL's bindings after a code reload.
@(private)
run_prelude :: proc(r: ^Runtime) {
	L := r.L
	bytecode := compile(PRELUDE)
	defer luau.free_bytecode(raw_data(bytecode))
	if luau.load(L, "=engine/prelude.luau", raw_data(bytecode), c.size_t(len(bytecode)), 0) != .OK {
		log.panicf("script: the prelude does not load: %s", luau.toodinstring(L, -1))
	}
	luau.newtable(L)
	for name in ([?]string{"get_enabled", "set_enabled", "start_coroutine", "stop_coroutine", "stop_all_coroutines"}) {
		r.platform.script_push_binding(L, fmt.aprintf("Behaviour.%s", name, allocator = frame(r)))
		luau.rawsetfield(L, -2, cstring_of(r, name))
	}
	if luau.pcall(L, 1, 2, 0) != .OK {
		log.panicf("script: the prelude fails: %s", luau.toodinstring(L, -1))
	}
	field := luau.gettop(L)
	luau.pushvalue(L, field - 1)
	set_path(r, "Behaviour")
	luau.pushvalue(L, field)
	set_path(r, "Field")
	luau.pop(L, 2)
}

@(private)
register_behaviours :: proc(r: ^Runtime) {
	bind :: register_binding
	bind(r, "Behaviour.get_enabled", proc(L: ^luau.State) -> c.int {
		r := runtime_of(L)
		i := check_instance(r, L, 1)
		luau.pushboolean(L, b32(.Enabled in i.flags))
		return 1
	})
	bind(r, "Behaviour.set_enabled", proc(L: ^luau.State) -> c.int {
		r := runtime_of(L)
		set_enabled(r, check_instance(r, L, 1), bool(luau.L_checkboolean(L, 2)))
		return 0
	})
	bind(r, "Behaviour.start_coroutine", start_coroutine_binding)
	bind(r, "Behaviour.stop_coroutine", stop_coroutine_binding)
	bind(r, "Behaviour.stop_all_coroutines", proc(L: ^luau.State) -> c.int {
		r := runtime_of(L)
		stop_owned(r, handle_of(r, check_instance(r, L, 1)))
		return 0
	})
}

// is_class is true for a table that Behaviour.define made.
@(private)
is_class :: proc(L: ^luau.State, idx: c.int) -> bool {
	if !luau.istable(L, idx) {
		return false
	}
	is := luau.rawgetfield(L, idx, "__behaviour") == .STRING
	luau.pop(L, 1)
	return is
}

@(private)
class_name :: proc(r: ^Runtime, L: ^luau.State, idx: c.int) -> string {
	luau.rawgetfield(L, idx, "__behaviour")
	defer luau.pop(L, 1)
	return fmt.aprintf("%s", luau.toodinstring(L, -1), allocator = frame(r))
}

@(private)
handle_of :: proc(r: ^Runtime, i: ^Instance) -> Instance_Handle {
	return {u32((uintptr(i) - uintptr(&r.instances[0])) / size_of(Instance)), i.generation}
}

@(private)
instance_at :: proc(r: ^Runtime, h: Instance_Handle) -> ^Instance {
	if int(h.index) >= r.instance_used {
		return nil
	}
	i := &r.instances[h.index]
	return i if i.generation == h.generation && .Live in i.flags else nil
}

@(private)
push_instance_key :: proc(L: ^luau.State) {
	luau.pushlightuserdatatagged(L, nil, c.int(Light_Tag.Instance_Key))
}

// instance_of is the instance whose table is at idx, or nil.
@(private)
instance_of :: proc(r: ^Runtime, L: ^luau.State, idx: c.int) -> ^Instance {
	if !luau.istable(L, idx) {
		return nil
	}
	t := luau.absindex(L, idx)
	push_instance_key(L)
	luau.rawget(L, t)
	defer luau.pop(L, 1)
	if !luau.isinteger64(L, -1) {
		return nil
	}
	packed := u64(luau.tointeger64(L, -1, nil))
	return instance_at(r, {u32(packed), u32(packed >> 32)})
}

@(private)
check_instance :: proc(r: ^Runtime, L: ^luau.State, idx: c.int) -> ^Instance {
	i := instance_of(r, L, idx)
	if i == nil {
		raise(L, "the behaviour is destroyed")
	}
	return i
}

// push_record pushes the record table of an entity, and creates it and the Behaviours component if create is set.
// It pushes nil for an entity without one.
@(private)
push_record :: proc(r: ^Runtime, L: ^luau.State, e: ecs.Entity, create: bool) {
	if b := ecs.get(r.world, e, Behaviours); b != nil {
		luau.getref(L, b.record)
		return
	}
	if !create {
		luau.pushnil(L)
		return
	}
	luau.newtable(L)
	luau.pushvalue(L, -1)
	ecs.add(r.world, e, Behaviours{luau.ref(L, -1)})
	luau.pop(L, 1)
}

// attach adds an instance of the class at class_idx to an entity, with the field values in the table at values_idx
// (0 for none), and pushes it. From a script, immediate is set, so awake and on_enable run before attach returns.
@(private)
attach :: proc(r: ^Runtime, L: ^luau.State, e: ecs.Entity, class_idx, values_idx: c.int, immediate: bool) {
	class := luau.absindex(L, class_idx)
	values := values_idx != 0 ? luau.absindex(L, values_idx) : 0
	push_record(r, L, e, true)
	record := luau.gettop(L)
	luau.pushvalue(L, class)
	if luau.rawget(L, record) != .NIL {
		raise(L, fmt.aprintf("the entity already has a %s", class_name(r, L, class), allocator = frame(r)))
	}
	luau.pop(L, 1)

	slot := -1
	for i in 0 ..< r.instance_used {
		if .Live not_in r.instances[i].flags {
			slot = i
			break
		}
	}
	if slot < 0 {
		if r.instance_used == MAX_INSTANCES {
			raise(L, fmt.aprintf("more than %d behaviour instances", MAX_INSTANCES, allocator = frame(r)))
		}
		slot = r.instance_used
		r.instance_used += 1
	}

	// The instance table, which counts toward the class's module: entity, transform, the fields' defaults, then the
	// given values.
	category := class_category(r, L, class)
	previous := set_category(r, L, category)
	defer set_category(r, L, previous)
	luau.newtable(L)
	t := luau.gettop(L)
	luau.pushvalue(L, class)
	luau.setmetatable(L, t)
	push_entity(L, e)
	luau.rawsetfield(L, t, "entity")
	if ecs.has_raw(r.world, e, ecs.TRANSFORM_ID) {
		push_userdata(L, .Component_Ref, Component_Ref{e, ecs.TRANSFORM_ID})
		luau.rawsetfield(L, t, "transform")
	}
	luau.rawgetfield(L, class, "__fields")
	fields := luau.gettop(L)
	luau.pushnil(L)
	for luau.next(L, fields) {
		luau.rawgetfield(L, -1, "default")
		luau.pushvalue(L, -3)
		luau.insert(L, -2)
		luau.rawset(L, t)
		luau.pop(L, 1)
	}
	enabled := true
	if values != 0 {
		luau.pushnil(L)
		for luau.next(L, values) {
			key, _ := key_atom(L, -2)
			if key == "enabled" {
				enabled = bool(luau.toboolean(L, -1))
			} else {
				check_field_value(r, L, class, fields, key, -1)
				luau.pushvalue(L, -2)
				luau.insert(L, -2)
				luau.rawset(L, t)
				continue
			}
			luau.pop(L, 1)
		}
	}
	luau.pop(L, 1)

	i := &r.instances[slot]
	i^ = {
		entity        = e,
		category      = category,
		generation    = i.generation + 1,
		flags         = {.Live},
		profile_class = profile.name(&r.platform.profile, class_name(r, L, class), .Script),
	}
	push_instance_key(L)
	luau.pushinteger64(L, i64(u64(i.generation) << 32 | u64(slot)))
	luau.rawset(L, t)
	if enabled {
		i.flags += {.Enabled}
	}
	if ecs.active_in_hierarchy(r.world, e) {
		i.flags += {.Active}
	}
	if luau.rawgetfield(L, class, "update") == .FUNCTION {
		i.flags += {.Updates}
	}
	luau.pop(L, 1)
	luau.pushvalue(L, t)
	i.table = luau.ref(L, -1)
	luau.pop(L, 1)

	// The record: the instance at the end of the list, and under its class.
	luau.pushvalue(L, t)
	luau.rawseti(L, record, luau.objlen(L, record) + 1)
	luau.pushvalue(L, class)
	luau.pushvalue(L, t)
	luau.rawset(L, record)
	luau.remove(L, record)

	if .Active in i.flags {
		if immediate {
			wake(r, handle_of(r, i))
		} else {
			i.flags += {.Needs_Awake}
		}
	}
}

// check_field_value raises an error for a value that the class does not declare, or that has the wrong type.
@(private = "file")
check_field_value :: proc(r: ^Runtime, L: ^luau.State, class, fields: c.int, key: string, value_idx: c.int) {
	if problem := field_problem(r, L, class, fields, key, value_idx); problem != "" {
		raise(L, problem)
	}
}

// field_problem describes why a value cannot set a field of the class, or is "" when it can.
@(private)
field_problem :: proc(r: ^Runtime, L: ^luau.State, class, fields: c.int, key: string, value_idx: c.int) -> string {
	value := luau.absindex(L, value_idx)
	top := luau.gettop(L)
	defer luau.settop(L, top)
	luau.pushodinstring(L, key)
	if luau.rawget(L, fields) != .TABLE {
		return fmt.aprintf("%s has no field %s", class_name(r, L, class), key, allocator = frame(r))
	}
	luau.rawgetfield(L, -1, "__field")
	kind := luau.toodinstring(L, -1)
	actual := luau.type(L, value)
	ok: bool
	switch kind {
	case "number":
		ok = actual == .NUMBER
	case "boolean":
		ok = actual == .BOOLEAN
	case "string":
		ok = actual == .STRING
	case "vector":
		ok = actual == .VECTOR
	case "entity":
		ok = actual == .NIL || to_entity(L, value) != 0
	}
	if !ok {
		return fmt.aprintf("%s.%s takes a %s", class_name(r, L, class), key, kind, allocator = frame(r))
	}
	return ""
}

// wake runs awake once, and then on_enable if the instance is enabled. Both run only while the entity is active.
@(private)
wake :: proc(r: ^Runtime, h: Instance_Handle) {
	i := instance_at(r, h)
	if i == nil || .Active not_in i.flags {
		return
	}
	// The next script phase wakes it.
	if r.quiet {
		if .Awake not_in i.flags {
			i.flags += {.Needs_Awake}
		}
		return
	}
	i.flags -= {.Needs_Awake}
	if .Awake not_in i.flags {
		i.flags += {.Awake}
		call_method(r, h, "awake")
	}
	if i = instance_at(r, h); i != nil && effective(i) {
		call_method(r, h, "on_enable")
	}
}

@(private)
set_enabled :: proc(r: ^Runtime, i: ^Instance, enabled: bool) {
	if (.Enabled in i.flags) == enabled {
		return
	}
	was := effective(i)
	if enabled {
		i.flags += {.Enabled}
	} else {
		i.flags -= {.Enabled}
	}
	h := handle_of(r, i)
	if !was && effective(i) {
		call_method(r, h, "on_enable")
	} else if was && !effective(i) {
		call_method(r, h, "on_disable")
	}
}

// set_entity_active updates the instances of an entity whose activity changed, like Unity: awake on the first
// activation, on_enable and on_disable for enabled instances, and deactivation stops their coroutines.
@(private)
set_entity_active :: proc(r: ^Runtime, e: ecs.Entity, active: bool) {
	for h in entity_instances(r, e) {
		i := instance_at(r, h)
		if i == nil || (.Active in i.flags) == active {
			continue
		}
		if active {
			i.flags += {.Active}
			wake(r, h)
		} else {
			was := effective(i)
			i.flags -= {.Active}
			stop_owned(r, h)
			if was {
				call_method(r, h, "on_disable")
			}
		}
	}
}

// entity_instances lists the handles of an entity's instances, in the order they were added, in frame memory.
@(private)
entity_instances :: proc(r: ^Runtime, e: ecs.Entity) -> []Instance_Handle {
	b := ecs.get(r.world, e, Behaviours)
	if b == nil {
		return nil
	}
	return record_instances(r, b.record)
}

@(private)
record_instances :: proc(r: ^Runtime, record: c.int) -> []Instance_Handle {
	L := r.L
	luau.getref(L, record)
	n := luau.objlen(L, -1)
	handles := make([]Instance_Handle, n, frame(r))
	for k in 1 ..= n {
		luau.rawgeti(L, -1, k)
		if i := instance_of(r, L, -1); i != nil {
			handles[k - 1] = handle_of(r, i)
		}
		luau.pop(L, 1)
	}
	luau.pop(L, 1)
	return handles
}

// destroy_instance ends an instance: on_disable if it was effective, on_destroy if it woke, and its coroutines stop.
@(private)
destroy_instance :: proc(r: ^Runtime, h: Instance_Handle) {
	i := instance_at(r, h)
	if i == nil {
		return
	}
	if effective(i) {
		call_method(r, h, "on_disable")
	}
	if i = instance_at(r, h); i != nil && .Awake in i.flags {
		call_method(r, h, "on_destroy")
	}
	if i = instance_at(r, h); i == nil {
		return
	}
	stop_owned(r, h)
	luau.unref(r.L, i.table)
	i.flags = {}
	i.generation += 1
}

// detach removes one behaviour from an entity, like Unity's Destroy on a component.
@(private)
detach :: proc(r: ^Runtime, L: ^luau.State, e: ecs.Entity, class_idx: c.int) -> bool {
	class := luau.absindex(L, class_idx)
	push_record(r, L, e, false)
	record := luau.gettop(L)
	defer luau.settop(L, record - 1)
	if luau.isnil(L, record) {
		return false
	}
	luau.pushvalue(L, class)
	luau.rawget(L, record)
	i := instance_of(r, L, -1)
	if i == nil {
		return false
	}
	h := handle_of(r, i)
	// The record loses the instance first, so callbacks no longer find it.
	n := luau.objlen(L, record)
	for k: c.int = 1; k <= n; k += 1 {
		luau.rawgeti(L, record, k)
		same := luau.rawequal(L, -1, -2)
		luau.pop(L, 1)
		if same {
			for j := k; j < n; j += 1 {
				luau.rawgeti(L, record, j + 1)
				luau.rawseti(L, record, j)
			}
			luau.pushnil(L)
			luau.rawseti(L, record, n)
			break
		}
	}
	luau.pushvalue(L, class)
	luau.pushnil(L)
	luau.rawset(L, record)
	destroy_instance(r, h)
	return true
}

// on_record_removed runs when the Behaviours component goes, usually because the entity was despawned.
@(private)
on_record_removed :: proc(r: ^Runtime, record: c.int) {
	for h in record_instances(r, record) {
		destroy_instance(r, h)
	}
	luau.unref(r.L, record)
}

// call_method calls a method of an instance, if its class has one, with the values on top of the stack as its
// arguments. An error is logged with a traceback, and the other callbacks still run.
@(private)
call_method :: proc(r: ^Runtime, h: Instance_Handle, name: cstring, nargs: c.int = 0) {
	L := r.L
	i := instance_at(r, h)
	if i == nil || r.quiet {
		luau.pop(L, nargs)
		return
	}
	luau.getref(L, i.table)
	luau.getmetatable(L, -1)
	if luau.rawgetfield(L, -1, name) != .FUNCTION {
		luau.pop(L, 3 + nargs)
		return
	}
	// function, instance, then the arguments.
	luau.remove(L, -2)
	luau.insert(L, -2 - nargs)
	luau.insert(L, -1 - nargs)
	previous := set_category(r, L, i.category)
	zone := begin_callback(r, i.profile_class, callback_kind(name))
	protected_call(r, L, nargs + 1, 0)
	end_callback(r, zone)
	set_category(r, L, previous)
}

// attach_script adds a behaviour from a script asset to an entity, with the given field values. Its awake runs in
// the next script phase. The script must return a Behaviour class. A field that the class does not declare, or a
// value of the wrong type, is skipped with a warning, so a scene that a script change left behind still loads.
attach_script :: proc(r: ^Runtime, e: ecs.Entity, guid: format.Guid, fields: []Behaviour_Field = nil) -> bool {
	Data :: struct {
		r:      ^Runtime,
		e:      ecs.Entity,
		guid:   format.Guid,
		fields: []Behaviour_Field,
	}
	data := Data{r, e, guid, fields}
	status := luau.cpcall(r.L, proc "c" (L: ^luau.State) -> c.int {
		d := (^Data)(luau.touserdata(L, 1))
		context = d.r.bindings.ctx
		push_module(d.r, L, d.guid)
		class := luau.gettop(L)
		if !is_class(L, class) {
			raise(L, fmt.aprintf("%s does not return a Behaviour class", guid_text(d.r, d.guid), allocator = frame(d.r)))
		}
		values: c.int
		if len(d.fields) > 0 {
			luau.rawgetfield(L, class, "__fields")
			schema := luau.gettop(L)
			luau.newtable(L)
			values = luau.gettop(L)
			for f in d.fields {
				push_behaviour_field(L, f)
				if problem := field_problem(d.r, L, class, schema, f.name, -1); problem != "" {
					log.warnf("script: Entity(%s): %s, so the value is not set", entity_text(d.r, d.e), problem)
					luau.pop(L, 1)
					continue
				}
				luau.pushodinstring(L, f.name)
				luau.insert(L, -2)
				luau.rawset(L, values)
			}
		}
		attach(d.r, L, d.e, class, values, immediate = false)
		return 0
	}, &data)
	if status != .OK {
		log.errorf("script: cannot attach %s: %s", guid_text(r, guid), luau.toodinstring(r.L, -1))
		luau.pop(r.L, 1)
		return false
	}
	return true
}

@(private)
push_behaviour_field :: proc(L: ^luau.State, f: Behaviour_Field) {
	switch f.kind {
	case .Nil:
		luau.pushnil(L)
	case .Number:
		luau.pushnumber(L, f.number)
	case .Boolean:
		luau.pushboolean(L, b32(f.boolean))
	case .String:
		luau.pushodinstring(L, f.text)
	case .Vector:
		luau.pushvector(L, f.vector.x, f.vector.y, f.vector.z)
	case .Entity:
		push_entity(L, f.entity)
	}
}
