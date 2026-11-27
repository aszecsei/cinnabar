package render

import "cinnabar:core/gpu"

// What the GI's rays and its hits' shadow rays pass through glass by (see gi_translucency.hlsli and
// docs/rendering/global-illumination.md#many-lights): the frame's hit table, which says which triangles are a
// translucent submesh's, and the GI's emitters' table and pool, which give each such triangle's transmittance.

// Translucency matches Translucency in gi_translucency.hlsli. valid is 1 when the table and the pool are the frame's.
Translucency :: struct {
	hit_instances:        u32,
	hit_instances_offset: u32,
	hit_submeshes:        u32,
	hit_submeshes_offset: u32,
	table:                u32,
	table_offset:         u32,
	pool:                 u32,
	valid:                u32,
}

#assert(size_of(Translucency) == 32)

// translucency_constants are a pass's Translucency: the frame's hit table, and the emitters' table and pool when the
// frame has its emitters. Without them, every translucent triangle lets all the light through.
@(private)
translucency_constants :: proc(f: ^Frame, g: ^Graph) -> (t: Translucency) {
	sf := f.scene_frame
	t.hit_instances = gpu.read_index(sf.hit_instances.buffer)
	t.hit_instances_offset = sf.hit_instances.offset
	t.hit_submeshes = gpu.read_index(sf.hit_submeshes.buffer)
	t.hit_submeshes_offset = sf.hit_submeshes.offset
	if f.emitters != nil {
		t.table = gpu.read_index(f.emitters.table.buffer)
		t.table_offset = f.emitters.table.offset
		t.pool = gpu.read_index(gpu_buffer(g, f.emitters.pool))
		t.valid = 1
	}
	return
}

// declare_translucency_reads declares that a pass reads the emitters' pool for its Translucency, when the frame has it.
@(private)
declare_translucency_reads :: proc(f: ^Frame, pass: Pass) {
	if f.emitters != nil {
		read(f.graph, pass, f.emitters.pool)
	}
}
