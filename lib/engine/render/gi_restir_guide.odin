package render

import "cinnabar:core"
import "cinnabar:core/gpu"

// ReSTIR GI's ray guide (see docs/rendering/global-illumination.md#ray-guiding): for each cell of the world probes'
// first levels, the light that reaches it from each of 8 x 8 octahedral leaves, with a quadtree of their sums, which a
// share of ReSTIR GI's rays walk to draw their directions. A cell is the space nearest one probe, at the probe's
// storage, so it follows the camera as the probe does. Each frame, the build pass turns last frame's rays' sums into
// the cells' learned light, blends in the world probes' radiance where a cell has learned little, and builds each
// cell's quadtree; the trace walks it; and the temporal pass adds each ray's light over its pdf to its cell's sums. The
// guide changes only how the rays are drawn: the mixture's pdf weighs each sample, so the light is the same in
// expectation, and only its noise changes.

// The engine's ray guide shaders, by their .meta files.
GI_RESTIR_GUIDE_SHADER :: #load("../content/shaders/gi_restir_guide.hlsl.meta", string)
GI_RESTIR_GUIDE_VIEW_SHADER :: #load("../content/shaders/gi_restir_guide_view.hlsl.meta", string)

// Match gi_restir_guide.hlsli: a cell's leaves along each side of the octahedron, its floats in the guide's buffer, and
// its words in the sums: one for each leaf and their count.
GUIDE_SIDE :: 8
GUIDE_LEAVES :: GUIDE_SIDE * GUIDE_SIDE
GUIDE_STRIDE :: 160
GUIDE_ACCUM_STRIDE :: GUIDE_LEAVES + 4
// How many rays the world probes' radiance counts as in a cell's leaves: a cell that has learned from this many rays
// takes half of each.
GUIDE_PRIOR_RAYS :: 32
// The share of a cell's light that its leaves take evenly, so the walk reaches every leaf.
GUIDE_FLOOR :: 0.1
// The debug view's blocks, in pixels. Matches gi_restir_guide_view.hlsl.
GUIDE_VIEW_BLOCK :: 64

#assert(GUIDE_STRIDE >= GUIDE_LEAVES + 85 + 5)

// Restir_Guide matches Restir_Guide in gi_restir_guide.hlsli: a frame's ray guide, in the upload ring. keys are each
// level's first world cell, of which a cell's key is the low 32 bits on each axis.
Restir_Guide :: struct {
	keys:        [MAX_PROBE_LEVELS][4]i32,
	level_count: u32,
	mix:         f32,
	guide:       u32,
	guide_out:   u32,
	accum:       u32,
	accum_out:   u32,
	prior_rays:  f32,
	floor_share: f32,
}

#assert(size_of(Restir_Guide) == 96)

// Gi_Restir_Guide_State is one view's ray guide between frames, in Gi_Restir_State: the cells' learned light and
// quadtrees, and the sums of the rays since the last build, made for a count of levels.
Gi_Restir_Guide_State :: struct {
	guide:  gpu.Buffer,
	accum:  gpu.Buffer,
	levels: u32,
}

// Gi_Restir_Guide_Frame is one frame's ray guide, in Gi_Restir_Frame.
@(private)
Gi_Restir_Guide_Frame :: struct {
	grid:   Restir_Guide,
	upload: gpu.Upload,
	guide:  Buffer,
	accum:  Buffer,
}

// restir_guide_bytes is the ray guide's memory for a count of levels: each cell's floats and its sums.
restir_guide_bytes :: proc(levels: u32) -> int {
	return int(levels) * GI_PROBE_COUNT * (GUIDE_STRIDE + GUIDE_ACCUM_STRIDE) * 4
}

@(private)
destroy_restir_guide :: proc(s: ^Gi_Restir_Guide_State, platform: ^core.Platform_API) {
	platform.gpu_destroy_buffer(s.guide)
	platform.gpu_destroy_buffer(s.accum)
	s^ = {}
}

// ensure_restir_guide makes a view's guide for a count of levels. New buffers hold no cell's key, so the build starts
// every cell again, and drops what the sums held.
@(private = "file")
ensure_restir_guide :: proc(r: ^Renderer, s: ^Gi_Restir_Guide_State, levels: u32) {
	if s.guide != {} && s.levels == levels {
		return
	}
	platform := r.platform
	destroy_restir_guide(s, platform)
	cells := levels * GI_PROBE_COUNT
	s.guide = platform.gpu_create_buffer(
		{size = cells * GUIDE_STRIDE * 4, usage = {.Storage}, label = "gi restir guide"},
		nil,
	)
	s.accum = platform.gpu_create_buffer(
		{
			size = cells * GUIDE_ACCUM_STRIDE * 4,
			usage = {.Storage},
			label = "gi restir guide sums",
		},
		nil,
	)
	s.levels = levels
}

// restir_guide_levels is how many of the world probes' levels have a guide at a level of ReSTIR GI.
@(private)
restir_guide_levels :: proc(f: ^Frame, params: Gi_Restir_Params) -> u32 {
	pf := f.gi.probes
	if pf == nil {
		return 0
	}
	return min(params.guide_levels, pf.grid.level_count)
}

// add_restir_guide adds the guide's build, after the world probes' update, whose radiance it reads, and before the
// rays' trace, and fills the frame's Restir_Guide in its upload. Without a guide at the level, its grid has no levels,
// and the rays are all cosine-weighted.
@(private)
add_restir_guide :: proc(rf: ^Gi_Restir_Frame, upload: gpu.Upload, run: Pass_Proc, step: rawptr) {
	f := rf.frame
	r := f.renderer
	gf := &rf.guide
	gf.upload = upload
	levels := restir_guide_levels(f, rf.params)
	if levels == 0 {
		(^Restir_Guide)(raw_data(upload.data))^ = gf.grid
		return
	}
	s := &f.state.gi.restir.guide
	ensure_restir_guide(r, s, levels)
	g := f.graph
	gf.guide = import_buffer(g, s.guide)
	gf.accum = import_buffer(g, s.accum)
	probes := &f.state.gi.probes
	grid := &gf.grid
	for l in 0 ..< int(levels) {
		cell := probes.levels[l].min_cell
		grid.keys[l] = {i32(cell.x), i32(cell.y), i32(cell.z), 0}
	}
	grid.level_count = levels
	grid.mix = rf.params.guide_mix
	grid.guide = gpu.read_index(s.guide)
	grid.guide_out = gpu.write_index(s.guide)
	grid.accum = gpu.read_index(s.accum)
	grid.accum_out = gpu.write_index(s.accum)
	grid.prior_rays = GUIDE_PRIOR_RAYS
	grid.floor_share = GUIDE_FLOOR
	(^Restir_Guide)(raw_data(upload.data))^ = grid^

	p := add_compute_pass(g, "gi restir guide", run, step, queue = .Compute)
	read(g, p, f.exposure)
	declare_probe_reads(f, p)
	write(g, p, gf.guide)
	write(g, p, gf.accum)
}

// restir_guide_groups is the build's dispatch: a group for each cell of its levels, in rows of at most 65535 groups.
@(private)
restir_guide_groups :: proc(levels: u32) -> [3]u32 {
	n := levels * GI_PROBE_COUNT
	return {min(n, 65535), (n + 65534) / 65535, 1}
}
