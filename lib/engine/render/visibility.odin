package render

import "core:math/linalg"
import "core:slice"

import "cinnabar:core"
import "cinnabar:core/gpu"

// The shading's measurements (see docs/rendering/lighting-and-shadows.md#visibility-buffer): how many 2x2 quads the
// forward pass shades, and how many of their lanes cover a pixel, which the Quad_Overdraw debug view shows at each quad
// and Shading_Stats counts for the frame.

// QUAD_COUNT_FORMAT is the format of Shading_Frame.quad_counts: a texel for each 2x2 quad of the scene. Its low 16 bits
// are the quads that shaded there, and its high 16 bits those of the visibility buffer's that mixed two triangles.
QUAD_COUNT_FORMAT :: gpu.Format.R32_Uint

// Shading_Stats are what the opaque surfaces' shading cost a frame or two ago, which the editor shows. The forward
// pass's quads are its pixel shader's 2x2 quads and its pixels their lanes that cover a pixel, so the pixels over four
// times the quads are its quads' efficiency, and the rest are helper lanes. The visibility buffer's are its shading's,
// with its quads whose pixels have two triangles of one pipeline (see
// docs/rendering/lighting-and-shadows.md#visibility-buffer).
Shading_Stats :: struct {
	forward_quads:     u32,
	forward_pixels:    u32,
	visibility_quads:  u32,
	visibility_pixels: u32,
	visibility_mixed:  u32,
	padding:           [3]u32,
}

// The words of the GPU's tally, in Shading_Stats' order, which the forward and visibility passes add to. Match
// SHADING_STATS_* in material_common.hlsli.
SHADING_STATS_WORDS :: 8
#assert(size_of(Shading_Stats) == SHADING_STATS_WORDS * 4)
// The tally's copies that the CPU reads, a frame or more apart, so a read never waits for a frame in flight.
SHADING_STATS_COPIES :: 3

// Shading is the measurements' state between frames, in Renderer: the tally, its copies, the next copy to write, and
// the last that came back.
Shading :: struct {
	stats:         gpu.Buffer,
	stats_copies:  [SHADING_STATS_COPIES]gpu.Buffer,
	stats_written: [SHADING_STATS_COPIES]bool,
	stats_next:    int,
	last_stats:    Shading_Stats,
	// The last frame counted, so the next copy is the one that it wrote.
	counted:       bool,
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
	return r.shading.last_stats
}

@(private)
shading_destroy :: proc(s: ^Shading, platform: ^core.Platform_API) {
	platform.gpu_destroy_buffer(s.stats)
	for b in s.stats_copies {
		platform.gpu_destroy_buffer(b)
	}
	s^ = {}
}

// read_shading_stats takes each tally's copy that has come back, the newest last, and keeps it.
@(private)
read_shading_stats :: proc(r: ^Renderer) {
	s := &r.shading
	for k in 0 ..< SHADING_STATS_COPIES {
		i := (s.stats_next + k) % SHADING_STATS_COPIES
		if !s.stats_written[i] {
			continue
		}
		if data, ok := r.platform.gpu_read_buffer(s.stats_copies[i]); ok && len(data) >= size_of(Shading_Stats) {
			s.last_stats = (^Shading_Stats)(raw_data(data))^
			s.stats_written[i] = false
		}
	}
}

// ensure_shading_stats creates the tally and its copies the first time.
@(private = "file")
ensure_shading_stats :: proc(r: ^Renderer) -> bool {
	s := &r.shading
	if s.stats == {} {
		s.stats = r.platform.gpu_create_buffer({size = SHADING_STATS_WORDS * 4, usage = {.Storage}, label = "shading stats"}, nil)
		for &b in s.stats_copies {
			b = r.platform.gpu_create_buffer({size = SHADING_STATS_WORDS * 4, usage = {.Readback}, label = "shading stats readback"}, nil)
		}
	}
	return s.stats != {}
}

// begin_shading gives the frame its measurements: the tally with stats, and the quads' counts with the Quad_Overdraw
// view or the stats, both cleared before the prepass. Without either, the forward pass counts nothing.
@(private)
begin_shading :: proc(f: ^Frame, stats: bool) {
	r := f.renderer
	r.shading.counted = false
	// Without the stats, the copies in flight are dropped, so the editor sees none.
	if !stats {
		r.shading.stats_written = {}
		r.shading.last_stats = {}
	}
	if !stats && f.debug_view != .Quad_Overdraw {
		return
	}
	g := f.graph
	sf := new(Shading_Frame, r.platform.frame_allocator)
	if stats && ensure_shading_stats(r) {
		zeros: [SHADING_STATS_WORDS * 4]byte
		ok: bool
		if sf.zeros, ok = upload_bytes(r.platform, zeros[:]); ok {
			sf.stats = import_buffer(g, r.shading.stats)
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

// add_shading_stats_copy copies the tally to its next copy after the world pass, for read_shading_stats to take once
// it is back.
@(private)
add_shading_stats_copy :: proc(f: ^Frame) {
	if f.shading == nil || f.shading.stats == 0 {
		return
	}
	s := &f.renderer.shading
	g := f.graph
	copy := import_buffer(g, s.stats_copies[s.stats_next])
	p := add_compute_pass(g, "shading stats", proc(ctx: ^Pass_Context) {
		f := (^Frame)(ctx.data)
		s := &f.renderer.shading
		gpu.cmd_copy_buffer(ctx.cb, gpu_buffer(ctx.graph, f.shading.stats), 0, s.stats_copies[s.stats_next], 0, SHADING_STATS_WORDS * 4)
	}, f)
	copy_source(g, p, f.shading.stats)
	copy_dest(g, p, copy)
	s.counted = true
}

// finish_shading_stats moves on to the next copy, once the frame has copied into this one.
@(private)
finish_shading_stats :: proc(r: ^Renderer) {
	s := &r.shading
	if !s.counted {
		return
	}
	s.stats_written[s.stats_next] = true
	s.stats_next = (s.stats_next + 1) % SHADING_STATS_COPIES
	s.counted = false
}

// The visibility buffer (see docs/rendering/lighting-and-shadows.md#visibility-buffer), a prototype to measure against
// the forward pass, which Quality.visibility_buffer turns on. The camera's opaque bins on the mesh shader path draw in a
// visibility pass after the prepass in its place: the prepass's targets, and each pixel's triangle, where the stencil's
// VISIBILITY_STENCIL is set. Before the world pass, the screen's 2x2 quads are binned by the pipelines of their pixels, and each pipeline shades
// its bin in compute, writing the scene's colors and IDs. The forward pass then draws the rest, which the stencil keeps
// off the visibility buffer's pixels.

VISIBILITY_BIN_SHADER :: #load("../content/shaders/visibility_bin.hlsl.meta", string)
// A pixel's triangle: its draw's index plus 1, or 0 where the pass drew nothing, its instance ID, its meshlet, and its
// index in the meshlet with whether it is a front face and the pipeline that drew it (see material_visibility.hlsli).
VISIBILITY_FORMAT :: gpu.Format.RGBA32_Uint
// The stencil bit of the pixels that the visibility buffer shades, which the visibility pass sets and every other
// prepass clears.
VISIBILITY_STENCIL :: 2
// A bin for each material pipeline, of its quads, with their counts, cursors and first quads. Match
// visibility_bin.hlsl and material_shade.hlsli.
VISIBILITY_BINS :: MAX_MATERIAL_PIPELINES
#assert(VISIBILITY_BINS == 256)

// Visibility is the visibility buffer's state between frames, in Renderer: the binning's pipeline and its buffers, made
// the first time a frame draws it.
Visibility :: struct {
	bin_pipeline:   Shader_Pipeline,
	bins:           gpu.Buffer,
	arguments:      gpu.Buffer,
	order:          gpu.Buffer,
	// The order's room, in quads.
	order_capacity: u32,
}

// Visibility_Frame is one frame's visibility buffer, in Frame: nil when the frame draws none.
@(private)
Visibility_Frame :: struct {
	bins:       Buffer,
	arguments:  Buffer,
	order:      Buffer,
	visibility: Texture,
	// The camera's inverse projection, with its jitter, which the shading casts rays through its pixels with.
	inverse:    gpu.Upload,
	// The pipelines whose bins the visibility buffer draws this frame, each once.
	pipelines:  []int,
	// The scene's colors and IDs that the shading writes, which post-processing's passes replace in Frame later.
	scene:      Texture,
	ids:        Texture,
}

// Visibility_Bin_Push matches Push in visibility_bin.hlsl.
@(private = "file")
Visibility_Bin_Push :: struct {
	phase:      u32,
	visibility: u32,
	stencil:    u32,
	bins:       u32,
	order:      u32,
	arguments:  u32,
	size:       [2]u32,
}

// Shade_Push matches Shade_Push in material_common.hlsli: the forward pass's push constants, then the visibility
// buffer's.
@(private = "file")
Shade_Push :: struct {
	using material: Material_Push,
	visibility:     u32,
	depth:          u32,
	stencil:        u32,
	bins:           u32,
	order:          u32,
	scene:          u32,
	ids:            u32,
	inverse:        u32,
	inverse_offset: u32,
}

#assert(size_of(Shade_Push) <= gpu.MAX_PUSH_CONSTANTS_SIZE)

// The binning's phases, a pass each.
@(private = "file", rodata)
VISIBILITY_BIN_PHASES := [4]string{"visibility bin clear", "visibility bin count", "visibility bin offsets", "visibility bin scatter"}

@(private = "file")
Visibility_Bin_Step :: struct {
	frame: ^Frame,
	phase: u32,
}

@(private)
visibility_init :: proc(v: ^Visibility) {
	v.bin_pipeline = shader_pipeline(VISIBILITY_BIN_SHADER)
}

@(private)
visibility_destroy :: proc(v: ^Visibility, platform: ^core.Platform_API) {
	destroy_shader_pipeline(&v.bin_pipeline, platform)
	for b in ([]gpu.Buffer{v.bins, v.arguments, v.order}) {
		platform.gpu_destroy_buffer(b)
	}
	v^ = {bin_pipeline = v.bin_pipeline}
}

// sync_visibility_pipelines makes the binning's pipeline once a frame has asked for the visibility buffer.
@(private)
sync_visibility_pipelines :: proc(r: ^Renderer, wanted, force: bool) {
	request_visibility(r, wanted)
	if r.materials.visibility {
		sync_compute_pipeline(&r.visibility.bin_pipeline, r.platform, r.residency.assets, {label = "visibility bins"}, force)
	}
}

// request_visibility asks the materials for the visibility buffer's passes from the first frame that wants it on: each
// pipeline is made again with them.
@(private)
request_visibility :: proc(r: ^Renderer, wanted: bool) {
	if wanted && r.caps.mesh_shaders && !r.materials.visibility {
		r.materials.visibility = true
		materials_reload(&r.materials)
	}
}

// begin_visibility gives the frame its visibility buffer, after build_scene: each of the camera's opaque bins on the
// mesh shader path whose pipeline has the visibility buffer's passes compiled. Without one, or without the binning's
// pipeline or its buffers, every bin draws forward.
@(private)
begin_visibility :: proc(f: ^Frame, wanted: bool) {
	r := f.renderer
	sf := f.scene_frame
	if sf == nil || len(sf.items) == 0 {
		return
	}
	platform := r.platform
	sf.bin_visibility = make([]bool, len(sf.bin_pipelines), platform.frame_allocator)
	if !wanted || !r.caps.mesh_shaders || !pipeline_ready(platform, &r.visibility.bin_pipeline) {
		return
	}
	pipelines := make([dynamic]int, platform.frame_allocator)
	bins := sf.groups[.Opaque]
	for bin in bins[0] ..< bins[1] {
		// The same test as draw_scene_view's for the mesh shader path.
		if sf.bin_impostors[bin] || sf.bin_particles[bin] || !r.materials.pipelines[sf.bin_pipelines[bin]].mesh_path {
			continue
		}
		index := sf.bin_draws[bin]
		p := &r.materials.pipelines[index]
		if !p.mesh_path || !compiled(platform, p.meshes[.Visibility]) || !compiled(platform, p.shade) {
			continue
		}
		sf.bin_visibility[bin] = true
		if !slice.contains(pipelines[:], index) {
			append(&pipelines, index)
		}
	}
	vf := new(Visibility_Frame, platform.frame_allocator)
	ok := len(pipelines) > 0 && ensure_visibility_buffers(r, f.size)
	inverse := linalg.inverse(jitter_projection(f.view_projection, f.jitter))
	if ok {
		vf.inverse, ok = platform.gpu_upload(size_of(inverse), 16)
	}
	if !ok {
		slice.fill(sf.bin_visibility, false)
		return
	}
	(^matrix[4, 4]f32)(raw_data(vf.inverse.data))^ = inverse
	g := f.graph
	v := &r.visibility
	vf.pipelines = pipelines[:]
	vf.bins = import_buffer(g, v.bins)
	vf.arguments = import_buffer(g, v.arguments)
	vf.order = import_buffer(g, v.order)
	vf.visibility = create_texture(g, {size = f.size, format = VISIBILITY_FORMAT, label = "visibility"})
	f.visibility = vf
}

// compiled is whether a pipeline exists and is compiled.
@(private = "file")
compiled :: proc(platform: ^core.Platform_API, pipeline: gpu.Pipeline) -> bool {
	return pipeline != {} && (platform.gpu_pipeline_ready == nil || platform.gpu_pipeline_ready(pipeline))
}

// ensure_visibility_buffers makes the bins the first time, and the order for a frame's quads, each in up to four bins.
@(private = "file")
ensure_visibility_buffers :: proc(r: ^Renderer, size: [2]u32) -> bool {
	v := &r.visibility
	platform := r.platform
	if v.bins == {} {
		v.bins = platform.gpu_create_buffer({size = 3 * VISIBILITY_BINS * 4, usage = {.Storage}, label = "visibility bins"}, nil)
		v.arguments = platform.gpu_create_buffer({size = VISIBILITY_BINS * size_of(gpu.Dispatch_Indirect_Args), usage = {.Storage, .Indirect}, label = "visibility arguments"}, nil)
	}
	quads := ((size.x + 1) / 2) * ((size.y + 1) / 2) * 4
	if quads > v.order_capacity || v.order == {} {
		platform.gpu_destroy_buffer(v.order)
		v.order_capacity = max(quads, v.order_capacity)
		v.order = platform.gpu_create_buffer({size = v.order_capacity * 4, usage = {.Storage}, label = "visibility order"}, nil)
	}
	return v.bins != {} && v.arguments != {} && v.order != {}
}

// add_visibility_pass draws the camera's bins of the visibility buffer after its prepass, or the late view's after
// its late prepass. The early pass clears the visibility buffer.
@(private)
add_visibility_pass :: proc(f: ^Frame, late: bool) {
	vf := f.visibility
	if vf == nil {
		return
	}
	g := f.graph
	p := add_render_pass(g, late ? "late visibility" : "visibility", late ? draw_late_visibility : draw_visibility, f)
	color(g, p, f.normals, .Load)
	color(g, p, f.velocity, .Load)
	color(g, p, vf.visibility, late ? .Load : .Clear)
	depth(g, p, f.depth, .Load)
	declare_scene_draws(f, p)
}

@(private = "file")
draw_visibility :: proc(ctx: ^Pass_Context) {
	draw_scene_view((^Frame)(ctx.data), ctx.cb, VIEW_CAMERA, .Visibility)
}

@(private = "file")
draw_late_visibility :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	draw_scene_view(f, ctx.cb, f.scene_frame.late_view, .Visibility)
}

// add_visibility_shading shades the visibility buffer's pixels before the world pass, which then loads the scene's
// colors and IDs: a pass that clears them to the background, the binning's phases, and one dispatch for each
// pipeline.
@(private)
add_visibility_shading :: proc(f: ^Frame, background: [4]f32) {
	vf := f.visibility
	if vf == nil {
		return
	}
	g := f.graph
	r := f.renderer
	sf := f.scene_frame
	vf.scene, vf.ids = f.scene, f.ids
	p := add_render_pass(g, "clear scene", proc(_: ^Pass_Context) {}, f)
	color(g, p, f.scene, .Clear, background)
	color(g, p, f.ids, .Clear)
	for name, phase in VISIBILITY_BIN_PHASES {
		step := new_clone(Visibility_Bin_Step{f, u32(phase)}, r.platform.frame_allocator)
		p = add_compute_pass(g, name, run_visibility_bins, step)
		write(g, p, vf.bins)
		if phase == 1 || phase == 3 {
			read(g, p, vf.visibility)
			read(g, p, f.depth)
		}
		if phase == 2 {
			write(g, p, vf.arguments)
		}
		if phase == 3 {
			write(g, p, vf.order)
		}
	}
	p = add_compute_pass(g, "visibility shading", run_visibility_shading, f)
	read(g, p, vf.visibility)
	read(g, p, f.depth)
	read(g, p, vf.bins)
	read(g, p, vf.order)
	indirect_buffer(g, p, vf.arguments)
	read(g, p, sf.instances)
	read(g, p, sf.draws)
	if sf.visible_instances != 0 {
		read(g, p, sf.visible_instances)
	}
	declare_lighting(f, p, opaque = true)
	declare_shading(f, p)
	write(g, p, f.scene)
	write(g, p, f.ids)
}

// run_visibility_bins dispatches a phase of the binning: a thread for each bin, one thread, or a thread for each
// quad.
@(private = "file")
run_visibility_bins :: proc(ctx: ^Pass_Context) {
	step := (^Visibility_Bin_Step)(ctx.data)
	f := step.frame
	vf := f.visibility
	g := ctx.graph
	push := Visibility_Bin_Push {
		phase      = step.phase,
		visibility = gpu.read_index(gpu_texture(g, vf.visibility)),
		stencil    = gpu.stencil_index(gpu_texture(g, f.depth)),
		bins       = gpu.write_index(gpu_buffer(g, vf.bins)),
		order      = gpu.write_index(gpu_buffer(g, vf.order)),
		arguments  = gpu.write_index(gpu_buffer(g, vf.arguments)),
		size       = f.size,
	}
	group_count: [3]u32
	switch step.phase {
	case 0:
		group_count = {VISIBILITY_BINS / 8, 1, 1}
	case 2:
		group_count = {1, 1, 1}
	case:
		group_count = groups({(f.size.x + 1) / 2, (f.size.y + 1) / 2}, 8)
	}
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.visibility.bin_pipeline.pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, group_count)
}

// run_visibility_shading dispatches each pipeline's bin with its shading pipeline, over the camera's frame constants.
@(private = "file")
run_visibility_shading :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	vf := f.visibility
	r := f.renderer
	sf := f.scene_frame
	g := ctx.graph
	push := Shade_Push {
		material       = material_push(f, .Forward, .Opaque),
		visibility     = gpu.read_index(gpu_texture(g, vf.visibility)),
		depth          = gpu.read_index(gpu_texture(g, f.depth)),
		stencil        = gpu.stencil_index(gpu_texture(g, f.depth)),
		bins           = gpu.read_index(gpu_buffer(g, vf.bins)),
		order          = gpu.read_index(gpu_buffer(g, vf.order)),
		scene          = gpu.write_index(gpu_texture(g, vf.scene)),
		ids            = gpu.write_index(gpu_texture(g, vf.ids)),
		inverse        = gpu.read_index(vf.inverse.buffer),
		inverse_offset = vf.inverse.offset,
	}
	arguments := gpu_buffer(g, vf.arguments)
	for index in vf.pipelines {
		push.pipeline = u32(index)
		gpu.cmd_set_pipeline(ctx.cb, r.materials.pipelines[index].shade)
		gpu.cmd_set_pass_constants(ctx.cb, sf.view_constants[VIEW_CAMERA])
		gpu.cmd_push_constants(ctx.cb, &push)
		gpu.cmd_dispatch_indirect(ctx.cb, arguments, u32(index) * size_of(gpu.Dispatch_Indirect_Args))
	}
}
