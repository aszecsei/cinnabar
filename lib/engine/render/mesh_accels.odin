// A mesh's bottom-level acceleration structure, from its creation through its build to its compaction (see
// docs/rendering/ray-scene.md#acceleration-structure).
package render

import "core:log"

import "cinnabar:core"
import "cinnabar:core/gpu"

// The most meshes whose compacted sizes a frame writes. The others wait for a later frame.
MAX_ACCEL_SIZES :: 256

// Mesh_Accel is where a mesh's bottom-level structure is in its life. nil is no structure. Resident_Mesh.accel is the
// structure that its instances use in every state. change_mesh_accel is its only writer.
Mesh_Accel :: union {
	Accel_Unbuilt,
	Accel_Built,
	Accel_Sizing,
	Accel_Compacting,
	Accel_Compacted,
}

// Accel_Unbuilt is a structure that no frame that executed has built.
Accel_Unbuilt :: struct {}

// Accel_Built is a built structure whose compacted size no frame that executed has written.
Accel_Built :: struct {}

// Accel_Sizing is a built structure whose compacted size a frame that executed copied into a readback slot of the
// ray scene's Accel_Compaction, at index.
Accel_Sizing :: struct {
	slot:  int,
	index: int,
}

// Accel_Compacting is a built structure and its compaction's destination, which each frame copies it into until one
// executes.
Accel_Compacting :: struct {
	compacted: gpu.Accel_Struct,
}

// Accel_Compacted is the structure as it stays: the compacted one, or the one that was built when it could not be
// compacted.
Accel_Compacted :: struct {}

// Accel_Event is what moves a mesh's structure on.
@(private)
Accel_Event :: union #no_nil {
	// The mesh is ready, and its structure was made.
	Accel_Created,
	// A frame that built the structure executed.
	Accel_Build_Ran,
	// A frame that wrote the structure's compacted size, and copied it into a readback slot, executed.
	Accel_Size_Copied,
	// The slot came back with the compacted size.
	Accel_Size_Read,
	// A frame that copied the structure into its compaction's destination executed.
	Accel_Compaction_Ran,
	// The mesh goes.
	Accel_Destroyed,
}

@(private)
Accel_Created :: struct {
	accel: gpu.Accel_Struct,
}

@(private)
Accel_Build_Ran :: struct {}

@(private)
Accel_Size_Copied :: struct {
	slot:  int,
	index: int,
}

@(private)
Accel_Size_Read :: struct {
	size: u64,
}

@(private)
Accel_Compaction_Ran :: struct {}

@(private)
Accel_Destroyed :: struct {}

// change_mesh_accel is the one writer of a mesh's structure (see docs/overview/conventions.md#state-with-a-lifecycle).
// It gives false for an event that does not follow from the state. A compacted size creates the compaction's
// destination; a size of 0, or a destination that cannot be made, keeps the built structure as it is. A compaction
// that executed swaps the structures and destroys the built one, which the backend releases once the GPU is done.
@(private)
change_mesh_accel :: proc(r: ^Residency, m: ^Resident_Mesh, event: Accel_Event) -> bool {
	switch e in event {
	case Accel_Created:
		if m.accel_state != nil || e.accel == {} {
			return false
		}
		m.accel, m.accel_state = e.accel, Accel_Unbuilt{}
	case Accel_Build_Ran:
		_ = m.accel_state.(Accel_Unbuilt) or_return
		m.accel_state = Accel_Built{}
	case Accel_Size_Copied:
		_ = m.accel_state.(Accel_Built) or_return
		m.accel_state = Accel_Sizing{e.slot, e.index}
	case Accel_Size_Read:
		_ = m.accel_state.(Accel_Sizing) or_return
		compacted: gpu.Accel_Struct
		if e.size > 0 {
			compacted = r.platform.gpu_create_accel({kind = .Bottom, compact = m.accel, compacted_size = e.size, label = "compacted mesh"})
		}
		if compacted != {} {
			m.accel_state = Accel_Compacting{compacted}
		} else {
			log.debugf("render: a mesh's acceleration structure is not compacted, at a compacted size of %d", e.size)
			m.accel_state = Accel_Compacted{}
		}
	case Accel_Compaction_Ran:
		c := m.accel_state.(Accel_Compacting) or_return
		r.platform.gpu_destroy_accel(m.accel)
		m.accel, m.accel_state = c.compacted, Accel_Compacted{}
	case Accel_Destroyed:
		if c, compacting := m.accel_state.(Accel_Compacting); compacting {
			r.platform.gpu_destroy_accel(c.compacted)
		}
		if m.accel != {} {
			r.platform.gpu_destroy_accel(m.accel)
		}
		m.accel, m.accel_state = {}, nil
	}
	return true
}

// Accel_Compaction reads the meshes' compacted sizes back: a Storage buffer that a frame writes them into, and
// READBACK_COPIES readback buffers, the slots that a frame copies them into. A slot is copied from the commit of the
// frame that copied into it until take_accel_sizes reads it, and only a slot that is not copied takes a frame's sizes.
// It is not a Readback_Ring, which gives only the newest copy, because each copy holds other meshes' sizes.
@(private)
Accel_Compaction :: struct {
	sizes:     gpu.Buffer,
	readbacks: [READBACK_COPIES]gpu.Buffer,
	copied:    bit_set[0 ..< READBACK_COPIES],
}

// ensure_accel_compaction creates the buffers the first time. It has all of them or none: when one cannot be made, the
// others go, and a later call tries again.
@(private = "file")
ensure_accel_compaction :: proc(c: ^Accel_Compaction, platform: ^core.Platform_API) -> bool {
	if c.sizes != {} {
		return true
	}
	c.sizes = platform.gpu_create_buffer({size = MAX_ACCEL_SIZES * size_of(u64), usage = {.Storage}, label = "accel sizes"}, nil)
	ok := c.sizes != {}
	for &b in c.readbacks {
		b = platform.gpu_create_buffer({size = MAX_ACCEL_SIZES * size_of(u64), usage = {.Readback}, label = "accel sizes readback"}, nil)
		ok &&= b != {}
	}
	if !ok {
		destroy_accel_compaction(c, platform)
	}
	return ok
}

@(private)
destroy_accel_compaction :: proc(c: ^Accel_Compaction, platform: ^core.Platform_API) {
	platform.gpu_destroy_buffer(c.sizes)
	for b in c.readbacks {
		platform.gpu_destroy_buffer(b)
	}
	c^ = {}
}

// take_accel_sizes reads each copied slot that has come back, gives each mesh whose size is in it the size, and frees
// the slot.
@(private)
take_accel_sizes :: proc(r: ^Renderer) {
	c := &r.ray_scene.compaction
	for slot in 0 ..< READBACK_COPIES {
		if slot not_in c.copied {
			continue
		}
		data, ok := r.platform.gpu_read_buffer(c.readbacks[slot])
		if !ok || len(data) < MAX_ACCEL_SIZES * size_of(u64) {
			continue
		}
		sizes := ([^]u64)(raw_data(data))[:MAX_ACCEL_SIZES]
		for &e in r.residency.entries[:r.residency.count] {
			if e.kind != .Mesh {
				continue
			}
			if s, sizing := e.current.mesh.accel_state.(Accel_Sizing); sizing && s.slot == slot {
				change_mesh_accel(&r.residency, &e.current.mesh, Accel_Size_Read{sizes[s.index]})
			}
		}
		c.copied -= {slot}
	}
}

// add_accel_size_passes writes the compacted sizes of at most MAX_ACCEL_SIZES built meshes' structures, and copies
// them into a slot that is not copied. The frame's commit puts the meshes in Accel_Sizing.
@(private)
add_accel_size_passes :: proc(f: ^Frame) {
	r, rf, g := f.renderer, f.ray_scene, f.graph
	c := &r.ray_scene.compaction
	slot := -1
	for i in 0 ..< READBACK_COPIES {
		if i not_in c.copied {
			slot = i
			break
		}
	}
	if slot < 0 {
		return
	}
	meshes := make([dynamic]^Resident_Mesh, r.platform.frame_allocator)
	for &e in r.residency.entries[:r.residency.count] {
		if _, built := e.current.mesh.accel_state.(Accel_Built); e.kind == .Mesh && e.ready && built {
			append(&meshes, &e.current.mesh)
			if len(meshes) == MAX_ACCEL_SIZES {
				break
			}
		}
	}
	if len(meshes) == 0 || !ensure_accel_compaction(c, r.platform) {
		return
	}
	rf.sized, rf.size_slot = meshes[:], slot
	sizes := import_buffer(g, c.sizes)
	p := add_compute_pass(g, "accel sizes", proc(ctx: ^Pass_Context) {
		f := (^Frame)(ctx.data)
		sizes := gpu_buffer(ctx.graph, f.ray_scene.sizes)
		for m, i in f.ray_scene.sized {
			gpu.cmd_write_accel_size(ctx.cb, m.accel, sizes, u32(i * size_of(u64)))
		}
	}, f)
	for m in meshes {
		accel_size_source(g, p, import_accel(g, m.accel))
	}
	accel_size_dest(g, p, sizes)
	rf.sizes, rf.sizes_readback = sizes, import_buffer(g, c.readbacks[slot])
	q := add_compute_pass(g, "copy accel sizes", proc(ctx: ^Pass_Context) {
		rf := (^Frame)(ctx.data).ray_scene
		size := u32(len(rf.sized) * size_of(u64))
		gpu.cmd_copy_buffer(ctx.cb, gpu_buffer(ctx.graph, rf.sizes), 0, gpu_buffer(ctx.graph, rf.sizes_readback), 0, size)
	}, f)
	copy_source(g, q, sizes)
	copy_dest(g, q, rf.sizes_readback)
}

// add_compaction_pass copies each mesh's structure into its compaction's destination. The frame's commit swaps them.
// Until then, the mesh's instances use the built structure, so tracing never waits for a compaction.
@(private)
add_compaction_pass :: proc(f: ^Frame) {
	r, rf, g := f.renderer, f.ray_scene, f.graph
	meshes := make([dynamic]^Resident_Mesh, r.platform.frame_allocator)
	for &e in r.residency.entries[:r.residency.count] {
		if _, compacting := e.current.mesh.accel_state.(Accel_Compacting); e.kind == .Mesh && e.ready && compacting {
			append(&meshes, &e.current.mesh)
		}
	}
	if len(meshes) == 0 {
		return
	}
	rf.compactions = meshes[:]
	p := add_compute_pass(g, "compact mesh accels", proc(ctx: ^Pass_Context) {
		for m in (^Frame)(ctx.data).ray_scene.compactions {
			gpu.cmd_compact_accel(ctx.cb, m.accel_state.(Accel_Compacting).compacted, m.accel)
		}
	}, f)
	for m in meshes {
		compact_source(g, p, import_accel(g, m.accel))
		compact_dest(g, p, import_accel(g, m.accel_state.(Accel_Compacting).compacted))
	}
}

// commit_mesh_accels moves on the structures of the meshes that the frame built, sized and compacted, once it executed.
// A frame that fails moves none, so the next frame does its work again.
@(private)
commit_mesh_accels :: proc(f: ^Frame) {
	r, rf := f.renderer, f.ray_scene
	for m in rf.builds {
		change_mesh_accel(&r.residency, m, Accel_Build_Ran{})
	}
	for m, i in rf.sized {
		change_mesh_accel(&r.residency, m, Accel_Size_Copied{rf.size_slot, i})
	}
	if len(rf.sized) > 0 {
		r.ray_scene.compaction.copied += {rf.size_slot}
	}
	for m in rf.compactions {
		change_mesh_accel(&r.residency, m, Accel_Compaction_Ran{})
	}
}
