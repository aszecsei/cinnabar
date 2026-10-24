package ecs

import "base:runtime"
import "core:mem"

// Commands records structural changes for apply. Each job records into its own buffer, in frame memory, so a buffer
// never outlives the frame. Recording is safe while jobs read the world in parallel. To spawn, get a handle from
// reserve and add components to it here: apply creates every reserved entity.
Commands :: struct {
	data: [dynamic]byte,
}

@(private)
Command_Op :: enum u8 {
	Despawn,
	Add,
	Remove,
	Teleport,
}

// A header is followed by size bytes of component data, padded to the header's alignment.
@(private)
Command_Header :: struct {
	entity: Entity,
	id:     Component_Id,
	size:   u32,
	op:     Command_Op,
}

commands :: proc(allocator: runtime.Allocator) -> Commands {
	return {data = make([dynamic]byte, allocator)}
}

command_despawn :: proc(cb: ^Commands, e: Entity) {
	push_command(cb, {entity = e, op = .Despawn}, nil)
}

command_add :: proc(cb: ^Commands, w: ^World, e: Entity, value: $T) {
	value := value
	if id := type_component(w, T); id != 0 {
		push_command(cb, {entity = e, id = id, size = size_of(T), op = .Add}, mem.ptr_to_bytes(&value))
	}
}

// command_add_raw adds a component from bytes. A nil data zeroes the component.
command_add_raw :: proc(cb: ^Commands, e: Entity, id: Component_Id, data: []byte) {
	push_command(cb, {entity = e, id = id, size = u32(len(data)), op = .Add}, data)
}

command_remove :: proc(cb: ^Commands, w: ^World, e: Entity, $T: typeid) {
	if id := type_component(w, T); id != 0 {
		command_remove_raw(cb, e, id)
	}
}

command_remove_raw :: proc(cb: ^Commands, e: Entity, id: Component_Id) {
	push_command(cb, {entity = e, id = id, op = .Remove}, nil)
}

// command_teleport records a teleport. See teleport.
command_teleport :: proc(cb: ^Commands, e: Entity, pose: Transform) {
	pose := pose
	push_command(cb, {entity = e, size = size_of(Transform), op = .Teleport}, mem.ptr_to_bytes(&pose))
}

// apply creates the reserved entities and applies the buffers in order. Run it only while no job uses the world.
// A command for an entity that is no longer alive does nothing. The descendants of despawned entities are despawned
// at the end, so commands for them in the same apply still run first.
apply :: proc(w: ^World, buffers: []Commands) {
	flush_reserved(w)
	for cb in buffers {
		offset := 0
		for offset < len(cb.data) {
			// The stream has byte alignment, so the header is copied out.
			header: Command_Header
			mem.copy(&header, &cb.data[offset], size_of(header))
			offset += size_of(Command_Header)
			switch header.op {
			case .Despawn:
				despawn_one(w, header.entity)
			case .Add:
				data := header.size > 0 ? cb.data[offset:][:header.size] : nil
				add_raw(w, header.entity, header.id, data)
				offset += mem.align_forward_int(int(header.size), align_of(Command_Header))
			case .Remove:
				remove_raw(w, header.entity, header.id)
			case .Teleport:
				pose: Transform
				mem.copy(&pose, &cb.data[offset], size_of(pose))
				teleport(w, header.entity, pose)
				offset += mem.align_forward_int(size_of(Transform), align_of(Command_Header))
			}
		}
	}
	despawn_orphans(w)
}

@(private = "file")
push_command :: proc(cb: ^Commands, header: Command_Header, data: []byte) {
	header := header
	append(&cb.data, ..mem.ptr_to_bytes(&header))
	if len(data) > 0 {
		append(&cb.data, ..data)
		resize(&cb.data, mem.align_forward_int(len(cb.data), align_of(Command_Header)))
	}
}
