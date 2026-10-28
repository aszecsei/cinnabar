package asset_format

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"

// The most levels of prefabs inside prefabs that expansion goes through, a guard behind its check for cycles.
SCENE_EXPAND_DEPTH :: 8

// Prefab_Resolver finds a prefab's scene by GUID, as its file has it, with its instances and overrides. ok is false
// when the prefab is missing or does not parse.
Prefab_Resolver :: struct {
	data: rawptr,
	find: proc(data: rawptr, prefab: Guid) -> (scene: Scene, ok: bool),
}

// scene_expand turns a scene's instances into plain entities, with no instance blocks, no override blocks and no
// paths (see docs/editor/prefabs.md#expansion). The editor's PrefabExpansion gives the same result. Each instance is
// its prefab's flat entities, the root first, then the others in the prefab's order: the root takes the instance's ID
// and every other entity scene_path_id of the instance and its ID in the prefab. The instance block and the override
// blocks apply over them, the outermost scene last. A prefab that is missing or broken expands to the instance's root
// alone, with a warning. A cycle of prefabs, a nesting deeper than SCENE_EXPAND_DEPTH and two entities with one ID
// are errors, and ok is false. self is the prefab being expanded, if the scene is one, so that one containing itself
// is a cycle. The scene and the messages are in allocator.
scene_expand :: proc(scene: Scene, resolver: Prefab_Resolver, self: Guid = {}, allocator := context.allocator) -> (flat: Scene, problems: []Scene_Problem, ok: bool) {
	chain: []Guid
	if self != {} {
		chain = []Guid{self}
	}
	x := Expander {
		resolver  = resolver,
		allocator = allocator,
		problems  = make([dynamic]Scene_Problem, allocator),
		outermost = len(chain),
	}
	entities := expand_entities(&x, scene, chain)
	seen := make(map[u64]bool, len(entities), context.temp_allocator)
	for e in entities {
		if seen[e.id] {
			expand_problem(&x, true, "two entities have the scene ID %016x after expanding the prefabs", e.id)
		}
		seen[e.id] = true
	}
	ok = true
	for p in x.problems {
		ok &&= !p.error
	}
	return {entities = entities}, x.problems[:], ok
}

// prefab_root is a prefab's root, the one block that is neither an override nor a child, and how many such blocks it
// has. A prefab has exactly one.
prefab_root :: proc(scene: Scene) -> (root: ^Scene_Entity, roots: int) {
	for &e in scene.entities {
		if e.path == nil && e.parent == 0 {
			if roots == 0 {
				root = &e
			}
			roots += 1
		}
	}
	return
}

@(private = "file")
Expander :: struct {
	resolver:  Prefab_Resolver,
	allocator: mem.Allocator,
	problems:  [dynamic]Scene_Problem,
	// The length of the chain at the scene that scene_expand was given, and the instance in it that is expanding, which
	// the messages name.
	outermost: int,
	instance:  u64,
}

@(private = "file")
expand_problem :: proc(x: ^Expander, error: bool, format: string, args: ..any) {
	append(&x.problems, Scene_Problem{message = fmt.aprintf(format, ..args, allocator = x.allocator), error = error})
}

// expand_entities expands a scene inside the prefabs of chain, outermost first. Only the outermost scene's warnings
// are reported: a prefab's own are its own cook's.
@(private = "file")
expand_entities :: proc(x: ^Expander, scene: Scene, chain: []Guid) -> []Scene_Entity {
	outermost := len(chain) == x.outermost
	out := make([dynamic]Scene_Entity, x.allocator)
	Range :: struct {
		start, end: int,
	}
	instances := make(map[u64]Range, context.temp_allocator)
	for e in scene.entities {
		if e.path != nil {
			continue
		}
		start := len(out)
		if e.prefab == {} {
			append(&out, copy_entity(x, e))
		} else {
			if outermost {
				x.instance = e.id
			}
			place_instance(x, &out, e, chain, outermost)
		}
		instances[e.id] = {start, len(out)}
	}
	for e in scene.entities {
		if e.path == nil {
			continue
		}
		target := -1
		if r, found := instances[e.path[0]]; found {
			// The root's overrides are the instance block's, so an override block names one of the others.
			for i in r.start + 1 ..< r.end {
				if out[i].id == e.id {
					target = i
					break
				}
			}
		}
		if target < 0 {
			if outermost {
				expand_problem(x, false, "the override %s names an entity that the instance does not have, so it is kept and does nothing", path_text(e.path))
			}
			continue
		}
		apply_override(x, &out[target], e)
		if .Parent in e.keys {
			out[target].parent = e.parent
		}
		out[target].removed = e.removed
	}
	return drop_removed(x, out[:])
}

// place_instance appends an instance's entities: its prefab's flat entities with their IDs on the instance's paths,
// and the instance block over the root.
@(private = "file")
place_instance :: proc(x: ^Expander, out: ^[dynamic]Scene_Entity, block: Scene_Entity, chain: []Guid, outermost: bool) {
	prefab, root, found := flat_prefab(x, block, chain, outermost)
	if !found {
		e := copy_entity(x, block)
		e.prefab = {}
		e.removed_components = nil
		e.removed_behaviours = nil
		append(out, e)
		return
	}
	ids := make(map[u64]bool, len(prefab), context.temp_allocator)
	for e in prefab {
		ids[e.id] = true
	}
	remap := proc(id, root, instance: u64) -> u64 {
		return id == root ? instance : scene_path_id(instance, id)
	}
	start := len(out)
	for e in prefab {
		if e.id == root {
			inject_at(out, start, e)
		} else {
			append(out, e)
		}
	}
	for &e in out[start:] {
		e.id = remap(e.id, root, block.id)
		if e.parent != 0 && ids[e.parent] {
			e.parent = remap(e.parent, root, block.id)
		}
		for c in e.components {
			remap_fields(x, c.fields, ids, root, block.id, outermost)
		}
		for b in e.behaviours {
			remap_fields(x, b.fields, ids, root, block.id, outermost)
		}
	}
	// The instance's pose and parent are the scene's.
	r := &out[start]
	r.parent = block.parent
	components := make([dynamic]Scene_Component, x.allocator)
	for c in r.components {
		if c.id != SCENE_TRANSFORM_ID && c.id != SCENE_LOCAL_TRANSFORM_ID {
			append(&components, c)
		}
	}
	r.components = components[:]
	apply_override(x, r, block)
}

// flat_prefab is the prefab's flat entities and its root's ID, inside chain. A cycle and a nesting beyond the depth
// are errors at every level, since every scene that reaches one cannot cook.
@(private = "file")
flat_prefab :: proc(x: ^Expander, block: Scene_Entity, chain: []Guid, outermost: bool) -> (entities: []Scene_Entity, root: u64, ok: bool) {
	buffer: [32]u8
	name := strings.clone(guid_format(block.prefab, &buffer), context.temp_allocator)
	for g in chain {
		if g == block.prefab {
			b := strings.builder_make(context.temp_allocator)
			for c in chain {
				fmt.sbprintf(&b, "%s contains ", guid_format(c, &buffer))
			}
			expand_problem(x, true, "instance %016x: the prefab %s contains itself: %s%s", x.instance, name, strings.to_string(b), name)
			return
		}
	}
	if len(chain) >= SCENE_EXPAND_DEPTH {
		expand_problem(x, true, "instance %016x: the prefab %s is more than %d prefabs deep", x.instance, name, SCENE_EXPAND_DEPTH)
		return
	}
	scene, found := x.resolver.find(x.resolver.data, block.prefab)
	if !found {
		if outermost {
			expand_problem(x, false, "instance %016x: the prefab %s is missing or does not parse, so the instance is its root alone", block.id, name)
		}
		return
	}
	r, roots := prefab_root(scene)
	if roots != 1 {
		if outermost {
			expand_problem(x, false, "instance %016x: the prefab %s has %d roots, not one, so the instance is its root alone", block.id, name, roots)
		}
		return
	}
	inner := make([]Guid, len(chain) + 1, context.temp_allocator)
	copy(inner, chain)
	inner[len(chain)] = block.prefab
	return expand_entities(x, scene, inner), r.id, true
}

// remap_fields gives the references of a prefab's entity the IDs of the instance's entities. A reference to an entity
// that the prefab does not have becomes none.
@(private = "file")
remap_fields :: proc(x: ^Expander, fields: []Scene_Field, ids: map[u64]bool, root, instance: u64, outermost: bool) {
	for &f in fields {
		if f.value.kind != .Entity || f.value.entity == 0 {
			continue
		}
		if !ids[f.value.entity] {
			if outermost {
				expand_problem(x, false, "instance %016x: the field %s refers to %016x, which its prefab does not have, so it is none", instance, f.name, f.value.entity)
			}
			f.value.entity = 0
			continue
		}
		f.value.entity = f.value.entity == root ? instance : scene_path_id(instance, f.value.entity)
	}
}

// apply_override applies a block's keys, removals, components and behaviours over an entity of an instance: the keys
// that it writes, the fields that it lists over the entity's, and the components and behaviours that the entity lacks
// added.
@(private = "file")
apply_override :: proc(x: ^Expander, e: ^Scene_Entity, block: Scene_Entity) {
	if .Name in block.keys {
		e.name = block.name
	}
	if .Active in block.keys {
		e.active = block.active
	}
	components := make([dynamic]Scene_Component, 0, len(e.components) + len(block.components), x.allocator)
	for c in e.components {
		if !slice.contains(block.removed_components, c.id) {
			append(&components, c)
		}
	}
	for c in block.components {
		at := len(components)
		for existing, i in components {
			if existing.id >= c.id {
				at = i
				break
			}
		}
		if at < len(components) && components[at].id == c.id {
			components[at].fields = merge_fields(x, components[at].fields, c.fields)
		} else {
			inject_at(&components, at, Scene_Component{id = c.id, name = c.name, fields = merge_fields(x, nil, c.fields)})
		}
	}
	e.components = components[:]
	behaviours := make([dynamic]Scene_Behaviour, 0, len(e.behaviours) + len(block.behaviours), x.allocator)
	for b in e.behaviours {
		if !slice.contains(block.removed_behaviours, b.script) {
			append(&behaviours, b)
		}
	}
	outer: for b in block.behaviours {
		for &existing in behaviours {
			if existing.script == b.script {
				existing.fields = merge_fields(x, existing.fields, b.fields)
				continue outer
			}
		}
		append(&behaviours, Scene_Behaviour{script = b.script, fields = merge_fields(x, nil, b.fields)})
	}
	e.behaviours = behaviours[:]
}

// merge_fields is fields with each of over set: in its place if fields has it, and after them if not.
@(private = "file")
merge_fields :: proc(x: ^Expander, fields, over: []Scene_Field) -> []Scene_Field {
	result := make([dynamic]Scene_Field, 0, len(fields) + len(over), x.allocator)
	append(&result, ..fields)
	outer: for f in over {
		for &existing in result {
			if existing.hash == f.hash {
				existing.value = f.value
				continue outer
			}
		}
		append(&result, f)
	}
	return result[:]
}

// drop_removed takes out the entities that an override removed, and their descendants.
@(private = "file")
drop_removed :: proc(x: ^Expander, entities: []Scene_Entity) -> []Scene_Entity {
	parents := make(map[u64]^Scene_Entity, len(entities), context.temp_allocator)
	any_removed := false
	for &e in entities {
		parents[e.id] = &e
		any_removed ||= e.removed
	}
	if !any_removed {
		return entities
	}
	kept := make([dynamic]Scene_Entity, 0, len(entities), x.allocator)
	for e in entities {
		removed := e.removed
		// The bound stops a cycle of parents, which the loader reports.
		at := e.parent
		for steps := 0; !removed && at != 0 && steps < len(entities); steps += 1 {
			parent, found := parents[at]
			if !found {
				break
			}
			removed = parent.removed
			at = parent.parent
		}
		if !removed {
			append(&kept, e)
		}
	}
	return kept[:]
}

// copy_entity copies an entity's components, behaviours and fields, so that expansion can change them.
@(private = "file")
copy_entity :: proc(x: ^Expander, e: Scene_Entity) -> Scene_Entity {
	result := e
	result.components = make([]Scene_Component, len(e.components), x.allocator)
	for c, i in e.components {
		result.components[i] = {id = c.id, name = c.name, fields = slice.clone(c.fields, x.allocator)}
	}
	result.behaviours = make([]Scene_Behaviour, len(e.behaviours), x.allocator)
	for b, i in e.behaviours {
		result.behaviours[i] = {script = b.script, fields = slice.clone(b.fields, x.allocator)}
	}
	result.keys = {}
	result.path = nil
	return result
}

@(private = "file")
path_text :: proc(path: []u64) -> string {
	b := strings.builder_make(context.temp_allocator)
	for id, i in path {
		fmt.sbprintf(&b, "%s%016x", i > 0 ? "#" : "", id)
	}
	return strings.to_string(b)
}
