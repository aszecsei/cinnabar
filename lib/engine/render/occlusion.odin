package render

import "core:slice"

import "cinnabar:core"
import "cinnabar:core/gpu"

// Two-phase occlusion culling (see docs/rendering/gpu-scene.md#occlusion-culling), for the camera's opaque items and
// the instance sets whose items are all opaque. The camera's view is early: it draws only what was visible last frame.
// The prepass draws it, a depth pyramid is built from its depth, and the late view, one more view after the shadow
// views, tests the rest of what is in the frustum against the pyramid and draws what it shows: a late prepass, then
// the forward pass with both views. The late view also keeps what is visible for next frame's early view: a bit for
// each slot, and for each of an instance set's cells a bit for each of its instances.

// HZB_SHADER builds a level of the depth pyramid (lib/engine/content/shaders/hzb.hlsl).
HZB_SHADER :: #load("../content/shaders/hzb.hlsl.meta", string)
// Matches MAX_HZB_LEVELS in occlusion.hlsli: a pyramid from half of 65536 texels.
MAX_HZB_LEVELS :: 16
HZB_FORMAT :: gpu.Format.R32_Float
// Cull_View's flags: the camera's view when it culls by occlusion, which draws only what was visible last frame, and the
// late view, which draws what the pyramid shows. Match occlusion.hlsli.
VIEW_EARLY :: 4
VIEW_LATE :: 8

// Occlusion_Constants matches Occlusion_Constants in occlusion.hlsli: what cull_draws.hlsl and cull_instances.hlsl
// test with, in the upload ring.
Occlusion_Constants :: struct {
	view_projection: matrix[4, 4]f32,
	hzb:             [MAX_HZB_LEVELS]u32,
	hzb_size:        [2]u32,
	hzb_levels:      u32,
	opaque_bins:     u32,
	slot_seen:       u32,
	slot_seen_next:  u32,
	cell_seen:       u32,
	near:            f32,
}

// Hzb_Push matches Hzb_Push in hzb.hlsl.
@(private = "file")
Hzb_Push :: struct {
	source:      u32,
	output:      u32,
	source_size: [2]u32,
	size:        [2]u32,
	padding:     [2]u32,
}

#assert(size_of(Occlusion_Constants) == 160)

// Cull_Stats are what the camera drew in a frame, which the editor shows: its items, as indirect draws, and its
// instance sets' instances, each drawn in the early view or the late one, and those that the depth pyramid hid. Without
// occlusion culling, everything is early. Of the items whose submeshes have a hierarchy over their meshlets, it has
// their meshlets of every level, and those that select meshlets picked, which each view that draws them tests in their
// place: an item that tests all of its meshlets counts them all (see meshlet_select.odin).
Cull_Stats :: struct {
	early_items:        u32,
	late_items:         u32,
	hidden_items:       u32,
	early_instances:    u32,
	late_instances:     u32,
	hidden_instances:   u32,
	hierarchy_meshlets: u32,
	selected_meshlets:  u32,
}

// The words of the GPU's tally, which cull_draws.hlsl, cull_instances.hlsl and select_meshlets.hlsl add to, in
// Cull_Stats' order.
CULL_STATS_WORDS :: 8
#assert(size_of(Cull_Stats) == CULL_STATS_WORDS * 4)
// The tally's copies that the CPU reads, a frame or more apart, so a read never waits for a frame in flight.
CULL_STATS_COPIES :: 3

// Occlusion is occlusion culling's state between frames, in Gpu_Scene: the pyramid's levels, made again when the
// frame's size changes, each slot's bit of last frame and of this one, which alternate, and each cell's bits.
Occlusion :: struct {
	pipeline:   Shader_Pipeline,
	hzb:        [MAX_HZB_LEVELS]gpu.Texture,
	hzb_levels: int,
	hzb_size:   [2]u32,
	slot_seen:  [2]gpu.Buffer,
	cell_seen:  gpu.Buffer,
	cell_seen_capacity: u32,
	// The camera's tally of this frame, its copies, the next copy to write, and the last that came back.
	stats:          gpu.Buffer,
	stats_copies:   [CULL_STATS_COPIES]gpu.Buffer,
	stats_written:  [CULL_STATS_COPIES]bool,
	stats_next:     int,
	last_stats:     Cull_Stats,
}

// cull_stats is what the camera drew, a frame or two ago (see Cull_Stats).
cull_stats :: proc(r: ^Renderer) -> Cull_Stats {
	return r.scene.occlusion.last_stats
}

// read_cull_stats takes each tally's copy that has come back, the newest last, and keeps it.
@(private)
read_cull_stats :: proc(r: ^Renderer) {
	o := &r.scene.occlusion
	for k in 0 ..< CULL_STATS_COPIES {
		i := (o.stats_next + k) % CULL_STATS_COPIES
		if !o.stats_written[i] {
			continue
		}
		if data, ok := r.platform.gpu_read_buffer(o.stats_copies[i]); ok && len(data) >= size_of(Cull_Stats) {
			o.last_stats = (^Cull_Stats)(raw_data(data))^
			o.stats_written[i] = false
		}
	}
}

// add_cull_stats_copy copies the camera's tally to its next copy, after the late view's culling, for read_cull_stats
// to take once it is back.
@(private)
add_cull_stats_copy :: proc(f: ^Frame) {
	sf := f.scene_frame
	if sf == nil || sf.stats == 0 {
		return
	}
	o := &f.renderer.scene.occlusion
	g := f.graph
	copy := import_buffer(g, o.stats_copies[o.stats_next])
	p := add_compute_pass(g, "cull stats", proc(ctx: ^Pass_Context) {
		f := (^Frame)(ctx.data)
		o := &f.renderer.scene.occlusion
		gpu.cmd_copy_buffer(ctx.cb, gpu_buffer(ctx.graph, f.scene_frame.stats), 0, o.stats_copies[o.stats_next], 0, CULL_STATS_WORDS * 4)
	}, f)
	copy_source(g, p, sf.stats)
	copy_dest(g, p, copy)
}

// finish_cull_stats moves on to the next copy, once the frame has copied into this one.
@(private)
finish_cull_stats :: proc(f: ^Frame) {
	sf := f.scene_frame
	if sf == nil || sf.stats == 0 {
		return
	}
	o := &f.renderer.scene.occlusion
	o.stats_written[o.stats_next] = true
	o.stats_next = (o.stats_next + 1) % CULL_STATS_COPIES
}

// ensure_cull_stats creates the tally and its copies the first time.
@(private)
ensure_cull_stats :: proc(r: ^Renderer) -> bool {
	o := &r.scene.occlusion
	if o.stats == {} {
		o.stats = r.platform.gpu_create_buffer({size = CULL_STATS_WORDS * 4, usage = {.Storage}, label = "cull stats"}, nil)
		for &b in o.stats_copies {
			b = r.platform.gpu_create_buffer({size = CULL_STATS_WORDS * 4, usage = {.Readback}, label = "cull stats readback"}, nil)
		}
	}
	return o.stats != {}
}

// Occlusion_Frame is one frame's occlusion culling, in Scene_Frame.
@(private)
Occlusion_Frame :: struct {
	constants:     gpu.Upload,
	late_cull:     gpu.Upload,
	hzb:           [MAX_HZB_LEVELS]Texture,
	slot_seen:     Buffer,
	slot_seen_next: Buffer,
	cell_seen:     Buffer,
}

@(private)
occlusion_init :: proc(o: ^Occlusion) {
	o.pipeline = shader_pipeline(HZB_SHADER)
}

@(private)
occlusion_destroy :: proc(o: ^Occlusion, platform: ^core.Platform_API) {
	destroy_shader_pipeline(&o.pipeline, platform)
	for t in o.hzb[:o.hzb_levels] {
		platform.gpu_destroy_texture(t)
	}
	for b in ([]gpu.Buffer{o.slot_seen[0], o.slot_seen[1], o.cell_seen, o.stats}) {
		platform.gpu_destroy_buffer(b)
	}
	for b in o.stats_copies {
		platform.gpu_destroy_buffer(b)
	}
	o^ = {pipeline = o.pipeline}
}

// occlusion_ready is whether a frame culls by occlusion: the editor has not turned it off, its pyramid's shader is
// compiled, and its buffers exist for its size and its cells.
@(private)
occlusion_ready :: proc(f: ^Frame, disabled: bool) -> bool {
	r := f.renderer
	o := &r.scene.occlusion
	if disabled || !pipeline_ready(r.platform, &o.pipeline) || f.size.x < 2 || f.size.y < 2 {
		return false
	}
	platform := r.platform
	size := [2]u32{f.size.x / 2, f.size.y / 2}
	if size != o.hzb_size || o.hzb_levels == 0 {
		for t in o.hzb[:o.hzb_levels] {
			platform.gpu_destroy_texture(t)
		}
		o.hzb_size, o.hzb_levels = size, 0
		level_size := size
		for o.hzb_levels < MAX_HZB_LEVELS {
			o.hzb[o.hzb_levels] = platform.gpu_create_texture({size = level_size, format = HZB_FORMAT, usage = {.Sampled, .Storage}, label = "depth pyramid"}, nil)
			o.hzb_levels += 1
			if level_size == {1, 1} {
				break
			}
			level_size = {max(level_size.x / 2, 1), max(level_size.y / 2, 1)}
		}
	}
	if o.slot_seen[0] == {} {
		for &b in o.slot_seen {
			b = platform.gpu_create_buffer({size = MAX_INSTANCES / 8, usage = {.Storage}, label = "seen slots"}, nil)
		}
	}
	cells := max(r.scene.cell_high, 1)
	if cells > o.cell_seen_capacity || o.cell_seen == {} {
		platform.gpu_destroy_buffer(o.cell_seen)
		o.cell_seen_capacity = min(max(cells, o.cell_seen_capacity * 2, 1024), MAX_INSTANCE_CELLS)
		o.cell_seen = platform.gpu_create_buffer({size = o.cell_seen_capacity * 32, usage = {.Storage}, label = "seen cells"}, nil)
	}
	return true
}

// occlusion_constants uploads the frame's Occlusion_Constants and imports its buffers and pyramid into the graph.
@(private)
occlusion_constants :: proc(f: ^Frame) -> bool {
	r := f.renderer
	s := &r.scene
	o := &s.occlusion
	sf := f.scene_frame
	of := &sf.occlusion
	g := f.graph
	// Last frame wrote one of the slots' bits; this frame reads it and writes the other.
	this := s.frame & 1
	c := Occlusion_Constants {
		view_projection = f.view_projection,
		hzb_size        = o.hzb_size,
		hzb_levels      = u32(o.hzb_levels),
		opaque_bins     = u32(sf.groups[.Opaque][1]),
		slot_seen       = gpu.read_index(o.slot_seen[1 - this]),
		slot_seen_next  = gpu.write_index(o.slot_seen[this]),
		cell_seen       = gpu.write_index(o.cell_seen),
		near            = f.view.near * 0.5,
	}
	for t, i in o.hzb[:o.hzb_levels] {
		c.hzb[i] = gpu.read_index(t)
		of.hzb[i] = import_texture(g, t, .Storage)
	}
	upload, ok := upload_bytes(r.platform, slice.bytes_from_ptr(&c, size_of(c)))
	if !ok {
		return false
	}
	of.constants = upload
	of.slot_seen = import_buffer(g, o.slot_seen[1 - this])
	of.slot_seen_next = import_buffer(g, o.slot_seen[this])
	of.cell_seen = import_buffer(g, o.cell_seen)
	return true
}

// add_occlusion_passes adds what follows the early prepass: the depth pyramid from its depth, the instance sets'
// late phases, the late view's culling, and the late prepass, which draws the late view into the depth, the normals and
// the velocity.
@(private)
add_occlusion_passes :: proc(f: ^Frame) {
	sf := f.scene_frame
	if sf == nil || !sf.occluding {
		return
	}
	g := f.graph
	of := &sf.occlusion
	o := &f.renderer.scene.occlusion
	for level in 0 ..< o.hzb_levels {
		p := add_compute_pass(g, "depth pyramid", run_hzb_level, new_clone(Hzb_Step{f, level}, f.renderer.platform.frame_allocator))
		read(g, p, level == 0 ? f.depth : of.hzb[level - 1])
		write(g, p, of.hzb[level])
	}
	add_late_instance_passes(f)
	p := add_compute_pass(g, "cull late draws", cull_late_draws, f)
	read(g, p, sf.instances)
	for t in of.hzb[:o.hzb_levels] {
		read(g, p, t)
	}
	read(g, p, of.slot_seen)
	write(g, p, of.slot_seen_next)
	if len(sf.sets) > 0 {
		read(g, p, sf.instance_counters)
	}
	if sf.meshlet_select.selections != 0 {
		read(g, p, sf.meshlet_select.selections)
	}
	write(g, p, sf.arguments)
	write(g, p, sf.mesh_arguments)
	write(g, p, sf.draws)
	write(g, p, sf.counts)
	if sf.stats != 0 {
		write(g, p, sf.stats)
	}
	p = add_render_pass(g, "late prepass", proc(ctx: ^Pass_Context) {
		f := (^Frame)(ctx.data)
		draw_scene_view(f, ctx.cb, f.scene_frame.late_view, .Prepass, filter = .No_Particles)
	}, f)
	color(g, p, f.normals, .Load)
	color(g, p, f.velocity, .Load)
	depth(g, p, f.depth, .Load)
	declare_scene_draws(f, p)
}

// Hzb_Step is a pyramid level's pass's data, in frame memory.
@(private = "file")
Hzb_Step :: struct {
	frame: ^Frame,
	level: int,
}

@(private = "file")
run_hzb_level :: proc(ctx: ^Pass_Context) {
	step := (^Hzb_Step)(ctx.data)
	f, level := step.frame, step.level
	g := ctx.graph
	o := &f.renderer.scene.occlusion
	push := Hzb_Push {
		output = gpu.write_index(o.hzb[level]),
		size   = level_size(o.hzb_size, level),
	}
	if level == 0 {
		push.source, push.source_size = gpu.read_index(gpu_texture(g, f.depth)), f.size
	} else {
		push.source, push.source_size = gpu.read_index(o.hzb[level - 1]), level_size(o.hzb_size, level - 1)
	}
	gpu.cmd_set_pipeline(ctx.cb, o.pipeline.pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, groups(push.size, 8))
}

// level_size is the size of a level of the pyramid: half of the one below it, at least one texel.
@(private = "file")
level_size :: proc(size: [2]u32, level: int) -> [2]u32 {
	return {max(size.x >> u32(level), 1), max(size.y >> u32(level), 1)}
}

@(private = "file")
cull_late_draws :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	sf := f.scene_frame
	pipeline := f.renderer.scene.cull_pipeline.pipeline
	if len(sf.items) == 0 || pipeline == {} {
		return
	}
	gpu.cmd_set_pipeline(ctx.cb, pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, sf.occlusion.late_cull)
	gpu.cmd_dispatch(ctx.cb, {u32(len(sf.items) + CULL_GROUP_SIZE - 1) / CULL_GROUP_SIZE, 1, 1})
}
