package render

import "core:math"
import "core:math/bits"
import "core:math/linalg"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/ecs"

// The world probes (see docs/rendering/global-illumination.md#world-probes): with Gi_Technique.World_Probes and
// Ray_Query, camera-following clipmap levels of probes in world space, which trace the ray scene for the light that
// the screen does not see. Each frame updates a budget of probes, on the compute queue after the prepass: their rays
// trace the scene, hit shading evaluates the materials at the hits, the hits are lit, the hits that the screen shows
// take last frame's lit scene there, and the probes blend the rays into their tiles. The cascades' trace, merge and gather then take the probes' light where they took the
// ambient light. A probe's storage is its world cell modulo the grid, so a level that follows the camera keeps every
// probe where it was, and only the probes that its box moved over reset. A render-origin rebase moves nothing: the
// levels' cells are of World_Position, and each frame gives their places relative to the camera.

// Each level's box of probes, along x, y and z. Match gi_probes.hlsli.
GI_PROBE_GRID :: [3]u32{32, 16, 32}
GI_PROBE_COUNT :: 32 * 16 * 32
// A probe's tile: its interior's texels along each side, and with its border.
GI_PROBE_INTERIOR :: 6
GI_PROBE_TILE :: GI_PROBE_INTERIOR + 2
MAX_PROBE_LEVELS :: 4
GI_PROBE_FORMAT :: gpu.Format.RGBA16_Float
// How much of its light a probe keeps at each update, once it has had many.
GI_PROBE_HYSTERESIS :: 0.97
// A level's box moves when the camera is more than this many probes from its middle, so a camera on a probe's edge
// does not move it back and forth.
GI_PROBE_RECENTER :: 2
// The punctual lights that the hits see, after every directional light.
GI_MAX_PROBE_LIGHTS :: 16
// A point moves off its surface by this share of its level's spacing before the probes are looked up.
GI_PROBE_BIAS :: 0.25
// The threads of each group of the reset.
GI_PROBE_RESET_GROUP :: 64

#assert(GI_PROBE_GRID.x * GI_PROBE_GRID.y * GI_PROBE_GRID.z == GI_PROBE_COUNT)

// Gi_Probe_Params are the world probes at a level: how many levels, the first level's spacing as a power of two of
// meters, so every spacing divides the render origin's 1024 m cell, each probe's rays, and the probes that a frame
// updates.
Gi_Probe_Params :: struct {
	levels:  u32,
	spacing: u32,
	rays:    u32,
	budget:  u32,
}

@(rodata)
GI_PROBE_PARAMS := [Quality_Level]Gi_Probe_Params {
	.Low    = {levels = 2, spacing = 1, rays = 32, budget = 1024},
	.Medium = {levels = 3, spacing = 0, rays = 64, budget = 2048},
	.High   = {levels = 3, spacing = 0, rays = 64, budget = 4096},
	.Ultra  = {levels = 4, spacing = 0, rays = 64, budget = 8192},
}

// The engine's world probe shaders, by their .meta files.
GI_PROBE_RESET_SHADER :: #load("../content/shaders/gi_probe_reset.hlsl.meta", string)
GI_PROBE_TRACE_SHADER :: #load("../content/shaders/gi_probe_trace.hlsl.meta", string)
GI_PROBE_LIGHT_SHADER :: #load("../content/shaders/gi_probe_light.hlsl.meta", string)
GI_PROBE_SCREEN_SHADER :: #load("../content/shaders/gi_probe_screen.hlsl.meta", string)
GI_PROBE_UPDATE_SHADER :: #load("../content/shaders/gi_probe_update.hlsl.meta", string)

// Gi_Probe_Level is a level's box between frames: its first probe's world cell.
Gi_Probe_Level :: struct {
	min_cell: [3]i64,
	valid:    bool,
}

// Gi_Probes is the world probes' state between frames, in Gi_Passes: their pipelines, their textures and states, which
// are made for a count of levels, the rays' buffers, each level's box, and which probes wait for an update.
Gi_Probes :: struct {
	reset:        Shader_Pipeline,
	trace:        Shader_Pipeline,
	light:        Shader_Pipeline,
	screen:       Shader_Pipeline,
	update:       Shader_Pipeline,
	radiance:     gpu.Texture,
	irradiance:   gpu.Texture,
	states:       gpu.Buffer,
	level_count:  u32,
	spacing:      u32,
	hits:         gpu.Buffer,
	surfaces:     gpu.Buffer,
	rays:         gpu.Buffer,
	ray_capacity: int,
	levels:       [MAX_PROBE_LEVELS]Gi_Probe_Level,
	schedule:     Probe_Schedule,
	// Counts the updates, for the rays' rotation.
	frame:        u32,
}

// Probe_Schedule is which probes the next frames update: those that wait since their reset, a bit each, then each
// level in turn from its cursor.
Probe_Schedule :: struct {
	pending: [MAX_PROBE_LEVELS][GI_PROBE_COUNT / 64]u64,
	cursor:  [MAX_PROBE_LEVELS]u32,
}

// Probe_Level matches Probe_Level in gi_probes.hlsli.
Probe_Level :: struct {
	min:   [4]f32,
	phase: [4]i32,
	delta: [4]i32,
}

// Probe_Grid matches Probe_Grid in gi_probes.hlsli.
Probe_Grid :: struct {
	levels:        [MAX_PROBE_LEVELS]Probe_Level,
	rotation:      [3][4]f32,
	level_count:    u32,
	radiance:       u32,
	irradiance:     u32,
	states:         u32,
	radiance_out:   u32,
	irradiance_out: u32,
	states_out:     u32,
	sampler_index:  u32,
	rays:           u32,
	jobs:           u32,
	jobs_offset:    u32,
	job_count:      u32,
	hysteresis:     f32,
	bias:           f32,
	padding:        [2]u32,
}

// Probe_Push matches Probe_Push in gi_probe_pass.hlsli.
@(private = "file")
Probe_Push :: struct {
	shadow_atlas:  u32,
	shadow_mask:   u32,
	grid:          u32,
	grid_offset:   u32,
	hits:          u32,
	surfaces:      u32,
	rays:          u32,
	accel:         u32,
	lights:        u32,
	lights_offset: u32,
	light_count:   u32,
	ray_count:     u32,
	depth:         u32,
	lit:           u32,
	lit_valid:     u32,
	padding:       u32,
}

#assert(size_of(Probe_Push) <= 128)

// Gi_Probe_Frame is one frame's world probes, in frame memory.
@(private)
Gi_Probe_Frame :: struct {
	grid:        Probe_Grid,
	upload:      gpu.Upload,
	jobs:        []u32,
	lights:      gpu.Upload,
	light_count: u32,
	radiance:    Texture,
	irradiance:  Texture,
	states:      Buffer,
	hits:        Buffer,
	surfaces:    Buffer,
	rays:        Buffer,
	// The global illumination's lit scene of last frame, which the hits that the screen shows take their light from.
	lit:         History,
}

gi_probes_init :: proc(p: ^Gi_Probes) {
	p.reset = shader_pipeline(GI_PROBE_RESET_SHADER)
	p.trace = shader_pipeline(GI_PROBE_TRACE_SHADER)
	p.light = shader_pipeline(GI_PROBE_LIGHT_SHADER)
	p.screen = shader_pipeline(GI_PROBE_SCREEN_SHADER)
	p.update = shader_pipeline(GI_PROBE_UPDATE_SHADER)
}

gi_probes_destroy :: proc(p: ^Gi_Probes, platform: ^core.Platform_API) {
	for s in ([]^Shader_Pipeline{&p.reset, &p.trace, &p.light, &p.screen, &p.update}) {
		destroy_shader_pipeline(s, platform)
	}
	destroy_probe_storage(p, platform)
	for b in ([]gpu.Buffer{p.hits, p.surfaces, p.rays}) {
		platform.gpu_destroy_buffer(b)
	}
}

@(private = "file")
destroy_probe_storage :: proc(p: ^Gi_Probes, platform: ^core.Platform_API) {
	platform.gpu_destroy_texture(p.radiance)
	platform.gpu_destroy_texture(p.irradiance)
	platform.gpu_destroy_buffer(p.states)
	p.radiance, p.irradiance, p.states = {}, {}, {}
}

// sync_gi_probe_pipelines makes the probes' pipelines, with Ray_Query only.
@(private)
sync_gi_probe_pipelines :: proc(r: ^Renderer, force: bool) {
	if !r.caps.ray_query {
		return
	}
	p := &r.gi.probes
	assets := r.residency.assets
	sync_compute_pipeline(&p.reset, r.platform, assets, {label = "gi probe reset"}, force)
	sync_compute_pipeline(&p.trace, r.platform, assets, {label = "gi probe trace"}, force)
	sync_compute_pipeline(&p.light, r.platform, assets, {label = "gi probe light"}, force)
	sync_compute_pipeline(&p.screen, r.platform, assets, {label = "gi probe screen"}, force)
	sync_compute_pipeline(&p.update, r.platform, assets, {label = "gi probe update"}, force)
}

// gi_probes_ready is whether the probes' pipelines have compiled.
@(private)
gi_probes_ready :: proc(r: ^Renderer) -> bool {
	p := &r.gi.probes
	for s in ([]^Shader_Pipeline{&p.reset, &p.trace, &p.light, &p.screen, &p.update}) {
		if !pipeline_ready(r.platform, s) {
			return false
		}
	}
	return true
}

// probe_cell is the world cell of a position at a spacing of 2^spacing meters. The shift is arithmetic, so a
// negative position floors.
probe_cell :: proc(p: ecs.World_Position, spacing: u32) -> [3]i64 {
	shift := u64(ecs.POSITION_FRACTION_BITS) + u64(spacing)
	return {p.raw.x >> shift, p.raw.y >> shift, p.raw.z >> shift}
}

// probe_box_half is a box's probes from its first to its middle.
@(private = "file")
probe_box_half :: proc() -> [3]i64 {
	return {i64(GI_PROBE_GRID.x / 2), i64(GI_PROBE_GRID.y / 2), i64(GI_PROBE_GRID.z / 2)}
}

// place_probe_level moves a level's box to follow the camera, when the camera is more than GI_PROBE_RECENTER probes
// from its middle, and gives how far it moved, in probes. A box's first placement moves it a whole grid, which resets
// every probe.
place_probe_level :: proc(level: ^Gi_Probe_Level, camera: ecs.World_Position, spacing: u32) -> (delta: [3]i64) {
	cell := probe_cell(camera, spacing)
	half := probe_box_half()
	if !level.valid {
		level.min_cell, level.valid = cell - half, true
		return {i64(GI_PROBE_GRID.x), i64(GI_PROBE_GRID.y), i64(GI_PROBE_GRID.z)}
	}
	offset := cell - (level.min_cell + half)
	if max(abs(offset.x), abs(offset.y), abs(offset.z)) <= GI_PROBE_RECENTER {
		return {}
	}
	before := level.min_cell
	level.min_cell = cell - half
	return level.min_cell - before
}

// probe_phase is the storage of a level's first probe: its cell modulo the grid.
probe_phase :: proc(min_cell: [3]i64) -> (phase: [3]i32) {
	grid := [3]i64{i64(GI_PROBE_GRID.x), i64(GI_PROBE_GRID.y), i64(GI_PROBE_GRID.z)}
	for axis in 0 ..< 3 {
		phase[axis] = i32(((min_cell[axis] % grid[axis]) + grid[axis]) % grid[axis])
	}
	return
}

// probe_level_min is a level's first probe relative to the camera, in meters, from whole units, so it is exact
// wherever the camera is.
probe_level_min :: proc(min_cell: [3]i64, camera: ecs.World_Position, spacing: u32) -> [3]f32 {
	shift := u64(ecs.POSITION_FRACTION_BITS) + u64(spacing)
	scale := f64(1) / f64(i64(1) << ecs.POSITION_FRACTION_BITS)
	return {
		f32(f64((min_cell.x << shift) - camera.raw.x) * scale),
		f32(f64((min_cell.y << shift) - camera.raw.y) * scale),
		f32(f64((min_cell.z << shift) - camera.raw.z) * scale),
	}
}

// probe_storage_cell is the place in a level's box of the probe at a storage.
probe_storage_cell :: proc(storage: u32, phase: [3]i32) -> [3]i32 {
	s := [3]i32{i32(storage % GI_PROBE_GRID.x), i32((storage / GI_PROBE_GRID.x) % GI_PROBE_GRID.y), i32(storage / (GI_PROBE_GRID.x * GI_PROBE_GRID.y))}
	grid := [3]i32{i32(GI_PROBE_GRID.x), i32(GI_PROBE_GRID.y), i32(GI_PROBE_GRID.z)}
	return ((s - phase) % grid + grid) % grid
}

// mark_moved_probes has a level's schedule update first the probes whose cells the box moved over: those whose cells
// were outside it before it moved by delta.
mark_moved_probes :: proc(schedule: ^Probe_Schedule, level: int, phase: [3]i32, delta: [3]i64) {
	if delta == {} {
		return
	}
	grid := [3]i64{i64(GI_PROBE_GRID.x), i64(GI_PROBE_GRID.y), i64(GI_PROBE_GRID.z)}
	for storage in u32(0) ..< GI_PROBE_COUNT {
		cell := probe_storage_cell(storage, phase)
		before := [3]i64{i64(cell.x), i64(cell.y), i64(cell.z)} + delta
		if before.x < 0 || before.y < 0 || before.z < 0 || before.x >= grid.x || before.y >= grid.y || before.z >= grid.z {
			schedule.pending[level][storage / 64] |= 1 << (storage % 64)
		}
	}
}

// probe_jobs are the probes that a frame updates, at most budget, each its level above 24 bits and its storage below:
// the probes that wait since their reset, the finest level's first, then each level's share of the rest in turn from
// its cursor.
probe_jobs :: proc(schedule: ^Probe_Schedule, levels: u32, budget: int, allocator := context.allocator) -> []u32 {
	jobs := make([dynamic]u32, 0, budget, allocator)
	for l in 0 ..< int(levels) {
		for &word, w in schedule.pending[l] {
			for word != 0 && len(jobs) < budget {
				bit := u32(bits.count_trailing_zeros(word))
				word &= word - 1
				append(&jobs, u32(l) << 24 | u32(w) * 64 + bit)
			}
		}
	}
	share := (budget - len(jobs)) / max(int(levels), 1)
	for l in 0 ..< int(levels) {
		for _ in 0 ..< min(share, GI_PROBE_COUNT) {
			append(&jobs, u32(l) << 24 | schedule.cursor[l])
			schedule.cursor[l] = (schedule.cursor[l] + 1) % GI_PROBE_COUNT
		}
	}
	return jobs[:]
}

// ensure_probe_storage makes the probes' textures and states for a count of levels and a spacing, and their rays'
// buffers for a count of rays. New textures reset every level.
@(private = "file")
ensure_probe_storage :: proc(r: ^Renderer, params: Gi_Probe_Params, rays: int) {
	p := &r.gi.probes
	platform := r.platform
	if p.radiance == {} || p.level_count != params.levels || p.spacing != params.spacing {
		destroy_probe_storage(p, platform)
		size := [2]u32{GI_PROBE_GRID.x * GI_PROBE_GRID.y * GI_PROBE_TILE, GI_PROBE_GRID.z * params.levels * GI_PROBE_TILE}
		p.radiance = platform.gpu_create_texture({size = size, format = GI_PROBE_FORMAT, usage = {.Sampled, .Storage}, label = "gi probe radiance"}, nil)
		p.irradiance = platform.gpu_create_texture({size = size, format = GI_PROBE_FORMAT, usage = {.Sampled, .Storage}, label = "gi probe irradiance"}, nil)
		p.states = platform.gpu_create_buffer({size = u32(MAX_PROBE_LEVELS * GI_PROBE_COUNT * 4), usage = {.Storage}, label = "gi probe states"}, nil)
		p.level_count, p.spacing = params.levels, params.spacing
		p.levels = {}
		p.schedule = {}
	}
	if rays > p.ray_capacity {
		for b in ([]gpu.Buffer{p.hits, p.surfaces, p.rays}) {
			platform.gpu_destroy_buffer(b)
		}
		p.ray_capacity = max(rays, p.ray_capacity * 2)
		capacity := u32(p.ray_capacity)
		p.hits = platform.gpu_create_buffer({size = capacity * size_of(Hit_Record), usage = {.Storage}, label = "gi probe hits"}, nil)
		p.surfaces = platform.gpu_create_buffer({size = capacity * size_of(Hit_Surface), usage = {.Storage}, label = "gi probe surfaces"}, nil)
		p.rays = platform.gpu_create_buffer({size = capacity * 16, usage = {.Storage}, label = "gi probe rays"}, nil)
	}
}

// probe_lights are the punctual lights that the probes' hits see: those whose spheres reach the outermost level's box,
// the brightest over their squared distance from the camera first, at most GI_MAX_PROBE_LIGHTS.
@(private = "file")
probe_lights :: proc(f: ^Frame, reach: f32) -> []u32 {
	lf := f.lights
	order := make([dynamic]u32, f.renderer.platform.frame_allocator)
	importance := make([]f32, len(lf.records), f.renderer.platform.frame_allocator)
	for record, i in lf.records {
		if record.type == .Directional || linalg.length(record.position) - record.range > reach {
			continue
		}
		importance[i] = max(record.color.r, record.color.g, record.color.b) / max(linalg.length2(record.position), 1)
		append(&order, u32(i))
	}
	for i in 1 ..< len(order) {
		for j := i; j > 0 && importance[order[j]] > importance[order[j - 1]]; j -= 1 {
			order[j], order[j - 1] = order[j - 1], order[j]
		}
	}
	return order[:min(len(order), GI_MAX_PROBE_LIGHTS)]
}

// probe_rotation is the rays' rotation at an update, as the rows of its matrix: uniform over the rotations (Shoemake),
// from the Halton (2, 3, 5) sequence, so successive updates see directions spread over the sphere.
probe_rotation :: proc(frame: u32) -> (rows: [3][4]f32) {
	u1, u2, u3 := halton(frame + 1, 2), halton(frame + 1, 3), halton(frame + 1, 5)
	a, b := math.sqrt(1 - u1), math.sqrt(u1)
	q := quaternion(x = a * math.sin(math.TAU * u2), y = a * math.cos(math.TAU * u2), z = b * math.sin(math.TAU * u3), w = b * math.cos(math.TAU * u3))
	m := linalg.matrix3_from_quaternion(q)
	for r in 0 ..< 3 {
		rows[r] = {m[r, 0], m[r, 1], m[r, 2], 0}
	}
	return
}

// add_gi_probe_passes updates the frame's budget of world probes, after the prepass, on the compute queue: the reset of
// the probes that the boxes moved over, the trace, hit shading, the hits' light, their screen light and the update.
// The screen light reads the prepass's depth and the lit scene of last frame, lit. It gives
// the grid that the cascades read, or nil without the probes this frame: before their pipelines compile, or while the
// frame has nothing to trace. Then the levels stay where they were, so no probe is left unreset.
@(private)
add_gi_probe_passes :: proc(f: ^Frame, settings: Gi_Settings, lit: History) -> ^Gi_Probe_Frame {
	r := f.renderer
	platform := r.platform
	if settings.technique != .World_Probes || !gi_probes_ready(r) || !hit_shading_ready(f) {
		return nil
	}
	params := GI_PROBE_PARAMS[settings.level]
	// The uploads come first: once the levels move, the reset must run.
	jobs_upload, jobs_ok := platform.gpu_upload(int(params.budget) * 4, 16)
	lights_upload, lights_ok := platform.gpu_upload(GI_MAX_PROBE_LIGHTS * 4, 16)
	grid_upload, grid_ok := platform.gpu_upload(size_of(Probe_Grid), 16)
	if !jobs_ok || !lights_ok || !grid_ok {
		return nil
	}
	ensure_probe_storage(r, params, int(params.budget * params.rays))
	p := &r.gi.probes
	g := f.graph
	pf := new(Gi_Probe_Frame, platform.frame_allocator)
	pf.lit = lit
	pf.radiance = import_texture(g, p.radiance, .Storage)
	pf.irradiance = import_texture(g, p.irradiance, .Storage)
	pf.states = import_buffer(g, p.states)
	pf.hits = import_buffer(g, p.hits)
	pf.surfaces = import_buffer(g, p.surfaces)
	pf.rays = import_buffer(g, p.rays)

	grid := &pf.grid
	reach: f32
	for l in 0 ..< int(params.levels) {
		spacing := params.spacing + u32(l)
		level := &p.levels[l]
		delta := place_probe_level(level, f.view.position, spacing)
		phase := probe_phase(level.min_cell)
		mark_moved_probes(&p.schedule, l, phase, delta)
		meters := f32(u32(1) << spacing)
		min := probe_level_min(level.min_cell, f.view.position, spacing)
		grid.levels[l] = {
			min   = {min.x, min.y, min.z, meters},
			phase = {phase.x, phase.y, phase.z, 0},
			delta = {clamp_delta(delta.x, GI_PROBE_GRID.x), clamp_delta(delta.y, GI_PROBE_GRID.y), clamp_delta(delta.z, GI_PROBE_GRID.z), 0},
		}
		reach = meters * f32(GI_PROBE_GRID.x)
	}
	pf.jobs = probe_jobs(&p.schedule, params.levels, int(params.budget), platform.frame_allocator)
	copy(jobs_upload.data, ([^]byte)(raw_data(pf.jobs))[:len(pf.jobs) * 4])
	lights := probe_lights(f, reach)
	copy(lights_upload.data, ([^]byte)(raw_data(lights))[:len(lights) * 4])
	pf.lights, pf.light_count = lights_upload, u32(len(lights))
	p.frame += 1
	grid^ = {
		levels         = grid.levels,
		rotation       = probe_rotation(p.frame),
		level_count    = params.levels,
		radiance       = gpu.read_index(p.radiance),
		irradiance     = gpu.read_index(p.irradiance),
		states         = gpu.read_index(p.states),
		radiance_out   = gpu.write_index(p.radiance),
		irradiance_out = gpu.write_index(p.irradiance),
		states_out     = gpu.write_index(p.states),
		sampler_index  = gpu.sampler_index(r.post.sampler),
		rays           = params.rays,
		jobs           = gpu.read_index(jobs_upload.buffer),
		jobs_offset    = jobs_upload.offset,
		job_count      = u32(len(pf.jobs)),
		hysteresis     = GI_PROBE_HYSTERESIS,
		bias           = GI_PROBE_BIAS,
	}
	(^Probe_Grid)(raw_data(grid_upload.data))^ = grid^
	pf.upload = grid_upload
	ray_count := u32(len(pf.jobs)) * params.rays

	step :: proc(f: ^Frame, pf: ^Gi_Probe_Frame, pass: Probe_Pass, ray_count: u32) -> ^Probe_Step {
		return new_clone(Probe_Step{f, pf, pass, ray_count}, f.renderer.platform.frame_allocator)
	}
	pass := add_compute_pass(g, "gi probe reset", run_probe_pass, step(f, pf, .Reset, ray_count), queue = .Compute)
	write(g, pass, pf.states)
	pass = add_compute_pass(g, "gi probe trace", run_probe_pass, step(f, pf, .Trace, ray_count), queue = .Compute)
	read_accel(g, pass, ray_scene_accel(f))
	write(g, pass, pf.hits)
	// hit_shading_ready said that it can.
	add_hit_shading(f, {hits = pf.hits, surfaces = pf.surfaces, count = ray_count}, .Compute)
	pass = add_compute_pass(g, "gi probe light", run_probe_pass, step(f, pf, .Light, ray_count), queue = .Compute)
	read_accel(g, pass, ray_scene_accel(f))
	read(g, pass, pf.hits)
	read(g, pass, pf.surfaces)
	read(g, pass, pf.radiance)
	read(g, pass, pf.irradiance)
	read(g, pass, pf.states)
	write(g, pass, pf.rays)
	if lit.valid {
		pass = add_compute_pass(g, "gi probe screen", run_probe_pass, step(f, pf, .Screen, ray_count), queue = .Compute)
		read(g, pass, pf.hits)
		read(g, pass, pf.surfaces)
		read(g, pass, f.depth)
		read(g, pass, lit.previous)
		write(g, pass, pf.rays)
	}
	pass = add_compute_pass(g, "gi probe update", run_probe_pass, step(f, pf, .Update, ray_count), queue = .Compute)
	read(g, pass, pf.rays)
	write(g, pass, pf.radiance)
	write(g, pass, pf.irradiance)
	write(g, pass, pf.states)
	return pf
}

@(private = "file")
clamp_delta :: proc(delta: i64, grid: u32) -> i32 {
	return i32(clamp(delta, -i64(grid), i64(grid)))
}

@(private = "file")
Probe_Pass :: enum {
	Reset,
	Trace,
	Light,
	Screen,
	Update,
}

// Probe_Step is one probe pass's data, in frame memory.
@(private = "file")
Probe_Step :: struct {
	frame:     ^Frame,
	probes:    ^Gi_Probe_Frame,
	pass:      Probe_Pass,
	ray_count: u32,
}

// run_probe_pass dispatches a probe pass: a thread for each probe of each level, or for each ray, or a group for each
// updated probe. A pass binds the hits and the rays for writing where it writes them, and for reading where it reads
// them.
@(private = "file")
run_probe_pass :: proc(ctx: ^Pass_Context) {
	step := (^Probe_Step)(ctx.data)
	f := step.frame
	pf := step.probes
	probes := &f.renderer.gi.probes
	g := ctx.graph
	hits, rays := gpu_buffer(g, pf.hits), gpu_buffer(g, pf.rays)
	push := Probe_Push {
		grid          = gpu.read_index(pf.upload.buffer),
		grid_offset   = pf.upload.offset,
		hits          = step.pass == .Trace ? gpu.write_index(hits) : gpu.read_index(hits),
		surfaces      = gpu.read_index(gpu_buffer(g, pf.surfaces)),
		rays          = step.pass == .Light || step.pass == .Screen ? gpu.write_index(rays) : gpu.read_index(rays),
		accel         = gpu.read_index(gpu_accel(g, ray_scene_accel(f))),
		lights        = gpu.read_index(pf.lights.buffer),
		lights_offset = pf.lights.offset,
		light_count   = pf.light_count,
		ray_count     = step.ray_count,
		lit_valid     = u32(pf.lit.valid),
	}
	if step.pass == .Screen {
		push.depth = gpu.read_index(gpu_texture(g, f.depth))
		if pf.lit.valid {
			push.lit = gpu.read_index(gpu_texture(g, pf.lit.previous))
		}
	}
	ray_groups := (step.ray_count + HIT_GROUP_SIZE - 1) / HIT_GROUP_SIZE
	groups: [3]u32
	pipeline: gpu.Pipeline
	switch step.pass {
	case .Reset:
		probes_count := pf.grid.level_count * GI_PROBE_COUNT
		pipeline, groups = probes.reset.pipeline, {(probes_count + GI_PROBE_RESET_GROUP - 1) / GI_PROBE_RESET_GROUP, 1, 1}
	case .Trace:
		pipeline, groups = probes.trace.pipeline, {ray_groups, 1, 1}
	case .Light:
		pipeline, groups = probes.light.pipeline, {ray_groups, 1, 1}
	case .Screen:
		pipeline, groups = probes.screen.pipeline, {ray_groups, 1, 1}
	case .Update:
		// A group for each probe, in rows, as a dispatch has at most 65535 groups along x.
		jobs := pf.grid.job_count
		pipeline, groups = probes.update.pipeline, {min(jobs, 65535), (jobs + 65534) / 65535, 1}
	}
	if groups.x == 0 {
		return
	}
	gpu.cmd_set_pipeline(ctx.cb, pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, f.scene_frame.view_constants[VIEW_CAMERA])
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, groups)
}

// declare_probe_reads declares that a pass of the cascades reads the frame's probes.
@(private)
declare_probe_reads :: proc(f: ^Frame, pass: Pass) {
	pf := f.gi.probes
	if pf == nil {
		return
	}
	read(f.graph, pass, pf.radiance)
	read(f.graph, pass, pf.irradiance)
	read(f.graph, pass, pf.states)
}
