package render

import "cinnabar:core"
import "cinnabar:core/gpu"

// The shading's measurements (see docs/rendering/lighting-and-shadows.md#quad-overdraw): how many 2x2 quads the
// forward pass shades, and how many of their lanes cover a pixel, which the Quad_Overdraw debug view shows at each quad
// and Shading_Stats counts for the frame.

// QUAD_COUNT_FORMAT is the format of Shading_Frame.quad_counts: a texel for each 2x2 quad of the scene, the quads that
// the forward pass shaded there.
QUAD_COUNT_FORMAT :: gpu.Format.R32_Uint

// Shading_Stats are what the forward pass shaded a frame or two ago, which the editor shows: its pixel shader's 2x2
// quads, and their lanes that cover a pixel. The pixels over four times the quads are the quads' efficiency, and the
// rest are helper lanes.
Shading_Stats :: struct {
	forward_quads:  u32,
	forward_pixels: u32,
}

// The words of the GPU's tally, in Shading_Stats' order, which the forward pass adds to. Match SHADING_STATS_* in
// material_common.hlsli.
SHADING_STATS_WORDS :: 2
#assert(size_of(Shading_Stats) == SHADING_STATS_WORDS * 4)

// Shading_State is one view's measurements' state between frames, in View_State: the tally, its copies, and the last that came back.
Shading_State :: struct {
	stats:      gpu.Buffer,
	stats_ring: Readback_Ring,
	last_stats: Shading_Stats,
}

// Shading_Frame is one frame's measurements, in Frame: nil when the frame measures nothing.
@(private)
Shading_Frame :: struct {
	// The tally, 0 without Frame_Desc.shading_stats.
	stats:       Buffer,
	// The quads at each quad of the scene, at half its size, 0 without the Quad_Overdraw view or the stats.
	quad_counts: Texture,
	zeros:       gpu.Upload,
}

// shading_stats is what the opaque surfaces' shading cost, a frame or two ago (see Shading_Stats). It is all 0 after a
// frame without Frame_Desc.shading_stats.
shading_stats :: proc(r: ^Renderer) -> Shading_Stats {
	return stats_state(r).shading.last_stats
}

@(private)
shading_state_destroy :: proc(s: ^Shading_State, platform: ^core.Platform_API) {
	platform.gpu_destroy_buffer(s.stats)
	destroy_readback_ring(&s.stats_ring, platform)
	s^ = {}
}

// read_shading_stats keeps the newest tally's copy that has come back. After a frame without Frame_Desc.shading_stats,
// or one that did not execute, the stats are empty.
@(private)
read_shading_stats :: proc(r: ^Renderer, v: ^View_State) {
	s := &v.shading
	data, take := take_readback(&s.stats_ring, r.platform, size_of(Shading_Stats))
	switch take {
	case .Fresh:
		s.last_stats = (^Shading_Stats)(raw_data(data))^
	case .Idle:
		s.last_stats = {}
	case .Waiting:
	}
}

// ensure_shading_stats creates the tally and its copies the first time.
@(private = "file")
ensure_shading_stats :: proc(r: ^Renderer, v: ^View_State) -> bool {
	s := &v.shading
	if s.stats == {} {
		s.stats = r.platform.gpu_create_buffer({size = SHADING_STATS_WORDS * 4, usage = {.Storage}, label = "shading stats"}, nil)
	}
	return s.stats != {} && ensure_readback_ring(&s.stats_ring, r.platform, SHADING_STATS_WORDS * 4, "shading stats readback")
}

// begin_shading gives the frame its measurements: the tally with stats, and the quads' counts with the Quad_Overdraw
// view or the stats, both cleared before the prepass. Without either, the forward pass counts nothing.
@(private)
begin_shading :: proc(f: ^Frame, stats: bool) {
	r := f.renderer
	if !stats && f.debug_view != .Quad_Overdraw {
		return
	}
	g := f.graph
	sf := new(Shading_Frame, r.platform.frame_allocator)
	if stats && ensure_shading_stats(r, f.state) {
		zeros: [SHADING_STATS_WORDS * 4]byte
		ok: bool
		if sf.zeros, ok = upload_bytes(r.platform, zeros[:]); ok {
			sf.stats = import_buffer(g, f.state.shading.stats)
			p := add_compute_pass(g, "shading stats clear", proc(ctx: ^Pass_Context) {
				f := (^Frame)(ctx.data)
				zeros := f.shading.zeros
				gpu.cmd_copy_buffer(ctx.cb, zeros.buffer, zeros.offset, gpu_buffer(ctx.graph, f.shading.stats), 0, SHADING_STATS_WORDS * 4)
			}, f)
			copy_dest(g, p, sf.stats)
		}
	}
	size := [2]u32{(f.size.x + 1) / 2, (f.size.y + 1) / 2}
	sf.quad_counts = create_texture(g, {size = size, format = QUAD_COUNT_FORMAT, label = "quad counts"})
	p := add_render_pass(g, "quad counts clear", proc(_: ^Pass_Context) {}, f)
	color(g, p, sf.quad_counts, .Clear)
	f.shading = sf
}

// declare_shading declares a pass that counts its quads into the frame's measurements.
@(private)
declare_shading :: proc(f: ^Frame, p: Pass) {
	if f.shading == nil {
		return
	}
	write(f.graph, p, f.shading.quad_counts)
	if f.shading.stats != 0 {
		write(f.graph, p, f.shading.stats)
	}
}

// shading_push sets the measurements' indices of a pass's push constants: each the bindless index plus 1, and 0
// without it, so the shaders count nothing.
@(private)
shading_push :: proc(f: ^Frame, quad_counts, stats: ^u32) {
	if f.shading == nil {
		return
	}
	g := f.graph
	quad_counts^ = gpu.write_index(gpu_texture(g, f.shading.quad_counts)) + 1
	if f.shading.stats != 0 {
		stats^ = gpu.write_index(gpu_buffer(g, f.shading.stats)) + 1
	}
}

// add_shading_stats_copy copies the tally to its ring after the world pass, for read_shading_stats to take once it is
// back.
@(private)
add_shading_stats_copy :: proc(f: ^Frame) {
	if f.shading == nil || f.shading.stats == 0 {
		return
	}
	r := f.renderer
	add_readback_copy(f.graph, r.platform, &f.state.shading.stats_ring, f.shading.stats, SHADING_STATS_WORDS * 4, "shading stats")
}

