package render

import "core:math"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/ecs"

// The split radiance cascades (see docs/rendering/global-illumination.md#split-cascades), after Tollenaar's "Split
// Radiance Cascades": with the world probes, sparse probes in world space on the surfaces that the screen shows, which
// keep their light from frame to frame. Each frame traces one ray from a pixel of each tile of the screen through the
// ray scene, lights its hit as the world probes' rays are lit, and splits it by its distance among the cascades of
// the pixel's cell. The cascades merge from the last to the first, with the world probes' light beyond, and each
// pixel gathers its light from the probes around it. Every level of detail is a window of cells around the camera, of
// World_Position, so a render-origin rebase moves nothing, and a probe's key is its place in the window, which the
// tables rebuild as the window follows the camera.

// The tables' limits. Match gi_split.hlsli.
MAX_SPLIT_LEVELS :: 8
MAX_SPLIT_CASCADES :: 4
// A window's cells along each axis, at the first cascade.
SPLIT_WINDOW :: 512
SPLIT_GROUP :: 64
SPLIT_SLOT_SIZE :: 16
SPLIT_ENTRY_SIZE :: 8
SPLIT_ACCUM_SIZE :: 20
SPLIT_HISTORY_SIZE :: 12
SPLIT_MERGED_SIZE :: 8
SPLIT_COUNTERS_SIZE :: 16
// A window's first cell is a multiple of this, so a cascade's cell is the first cascade's shifted right, exactly.
SPLIT_SNAP :: 1 << MAX_SPLIT_CASCADES
// A probe that no ray reached for this many frames is freed.
SPLIT_LIFETIME :: 60
// The share of each level's distances that blends into the next.
SPLIT_BAND :: 0.5
// A ray starts this many pixels off its surface.
SPLIT_BIAS :: 2
// A bin's history holds at most this many rays.
SPLIT_MAX_COUNT :: 256
// A probe counts half as much as a well-lit one when this many rays reached it, decayed as its bins' are.
SPLIT_CONFIDENCE_HALF :: 8
// The hits' light is pre-exposed, at most SPLIT_RADIANCE_MAX, and added in units of 1 / SPLIT_RADIANCE_SCALE, so a bin
// holds 65536 rays a frame.
SPLIT_RADIANCE_SCALE :: 1024
SPLIT_RADIANCE_MAX :: 64
// The atlas's tiles along each row.
SPLIT_ATLAS_COLUMNS :: 256
SPLIT_FORMAT :: gpu.Format.RGBA16_Float

#assert(SPLIT_RADIANCE_SCALE * SPLIT_RADIANCE_MAX * 65536 <= 1 << 32)

// Gi_Split_Params are the split cascades at a level. A ray is traced from one pixel of each tile a frame. Cascade k's
// probes have (directions << k)^2 directions. A level of detail's cells are 2^(voxel + L) meters, and it holds the
// distances from distance cells of level 0 times 2^L, to twice that. The first cascade has slots probes, and each
// after it a quarter of the one before, but no fewer than min_slots. The bins' histories hold about history_frames
// frames of rays.
Gi_Split_Params :: struct {
	tile:           [2]u32,
	directions:     u32,
	cascades:       u32,
	voxel:          i32,
	distance:       u32,
	levels:         u32,
	slots:          u32,
	min_slots:      u32,
	history_frames: f32,
}

@(rodata)
GI_SPLIT_PARAMS := [Quality_Level]Gi_Split_Params {
	.Low    = {tile = {4, 4}, directions = 4, cascades = 3, voxel = -1, distance = 16, levels = 4, slots = 8192, min_slots = 256, history_frames = 16},
	.Medium = {tile = {2, 2}, directions = 4, cascades = 4, voxel = -2, distance = 16, levels = 5, slots = 16384, min_slots = 256, history_frames = 12},
	.High   = {tile = {2, 2}, directions = 6, cascades = 4, voxel = -2, distance = 24, levels = 5, slots = 16384, min_slots = 256, history_frames = 12},
	.Ultra  = {tile = {1, 1}, directions = 8, cascades = 4, voxel = -3, distance = 32, levels = 5, slots = 32768, min_slots = 512, history_frames = 10},
}

// The engine's split cascade shaders, by their .meta files.
GI_SPLIT_TABLE_SHADER :: #load("../content/shaders/gi_split_table.hlsl.meta", string)
GI_SPLIT_TRACE_SHADER :: #load("../content/shaders/gi_split_trace.hlsl.meta", string)
GI_SPLIT_DEPOSIT_SHADER :: #load("../content/shaders/gi_split_deposit.hlsl.meta", string)
GI_SPLIT_MERGE_SHADER :: #load("../content/shaders/gi_split_merge.hlsl.meta", string)
GI_SPLIT_GATHER_SHADER :: #load("../content/shaders/gi_split_gather.hlsl.meta", string)

// Split_Level matches Split_Level in gi_split.hlsli.
Split_Level :: struct {
	min:   [4]f32,
	delta: [4]i32,
}

// Split_Cascade matches Split_Cascade in gi_split.hlsli.
Split_Cascade :: struct {
	first_slot:  u32,
	slots:       u32,
	first_entry: u32,
	entries:     u32,
	first_bin:   u32,
	side:        u32,
	chunks:      u32,
	padding:     u32,
}

// Split_Grid matches Split_Grid in gi_split.hlsli.
Split_Grid :: struct {
	levels:          [MAX_SPLIT_LEVELS]Split_Level,
	cascades:        [MAX_SPLIT_CASCADES]Split_Cascade,
	camera_offset:   [4]f32,
	level_count:     u32,
	cascade_count:   u32,
	directions:      u32,
	frame:           u32,
	tile:            [2]u32,
	tiles:           [2]u32,
	rotation:        [2]u32,
	lifetime:        u32,
	ray_count:       u32,
	level_distance:  f32,
	band:            f32,
	interval:        f32,
	bias:            f32,
	decay:           f32,
	max_count:       f32,
	confidence_half: f32,
	radiance_scale:  f32,
	radiance_max:    f32,
	total_slots:     u32,
	total_entries:   u32,
	total_bins:      u32,
	atlas_columns:   u32,
	padding:         [3]u32,
}

// Split_Push matches Split_Push in gi_split.hlsli.
@(private = "file")
Split_Push :: struct {
	grid:        u32,
	grid_offset: u32,
	phase:       u32,
	cascade:     u32,
	slots:       u32,
	deposits:    u32,
	index:       u32,
	lists:       u32,
	counters:    u32,
	arguments:   u32,
	accum:       u32,
	history:     u32,
	merged:      u32,
	atlas:       u32,
	hits:        u32,
	rays:        u32,
	accel:       u32,
	exposure:    u32,
	padding:     [2]u32,
}

#assert(size_of(Split_Push) <= 128)

// Split_Layout is where each cascade's slots, table entries and bins are in the buffers that hold every cascade's.
Split_Layout :: struct {
	cascades: [MAX_SPLIT_CASCADES]Split_Cascade,
	count:    u32,
	slots:    u32,
	entries:  u32,
	bins:     u32,
}

// Split_Window is a level of detail's window between frames: its first cell, of World_Position.
Split_Window :: struct {
	anchor: [3]i64,
	valid:  bool,
}

// Gi_Split is the split cascades' state between frames, in Gi_Passes: their pipelines, their tables, bins and atlas,
// made for a level's parameters, the rays' buffers, and each level of detail's window.
Gi_Split :: struct {
	table:        Shader_Pipeline,
	trace:        Shader_Pipeline,
	deposit:      Shader_Pipeline,
	merge:        Shader_Pipeline,
	gather:       Shader_Pipeline,
	params:       Gi_Split_Params,
	layout:       Split_Layout,
	slots:        gpu.Buffer,
	deposits:     gpu.Buffer,
	index:        gpu.Buffer,
	lists:        gpu.Buffer,
	counters:     gpu.Buffer,
	arguments:    gpu.Buffer,
	accum:        gpu.Buffer,
	history:      gpu.Buffer,
	merged:       gpu.Buffer,
	atlas:        gpu.Texture,
	hits:         gpu.Buffer,
	surfaces:     gpu.Buffer,
	rays:         gpu.Buffer,
	ray_capacity: int,
	windows:      [MAX_SPLIT_LEVELS]Split_Window,
	// Whether the storage is new since the last frame, so its slots and accumulators must be cleared.
	fresh:        bool,
	frame:        u32,
}

// Gi_Split_Frame is one frame's split cascades, in frame memory.
@(private)
Gi_Split_Frame :: struct {
	grid:      Split_Grid,
	upload:    gpu.Upload,
	fresh:     bool,
	slots:     Buffer,
	deposits:  Buffer,
	index:     Buffer,
	lists:     Buffer,
	counters:  Buffer,
	arguments: Buffer,
	accum:     Buffer,
	history:   Buffer,
	merged:    Buffer,
	atlas:     Texture,
	hits:      Buffer,
	surfaces:  Buffer,
	rays:      Buffer,
}

gi_split_init :: proc(s: ^Gi_Split) {
	s.table = shader_pipeline(GI_SPLIT_TABLE_SHADER)
	s.trace = shader_pipeline(GI_SPLIT_TRACE_SHADER)
	s.deposit = shader_pipeline(GI_SPLIT_DEPOSIT_SHADER)
	s.merge = shader_pipeline(GI_SPLIT_MERGE_SHADER)
	s.gather = shader_pipeline(GI_SPLIT_GATHER_SHADER)
}

gi_split_destroy :: proc(s: ^Gi_Split, platform: ^core.Platform_API) {
	for p in ([]^Shader_Pipeline{&s.table, &s.trace, &s.deposit, &s.merge, &s.gather}) {
		destroy_shader_pipeline(p, platform)
	}
	destroy_split_storage(s, platform)
	for b in ([]gpu.Buffer{s.hits, s.surfaces, s.rays}) {
		platform.gpu_destroy_buffer(b)
	}
	s.hits, s.surfaces, s.rays, s.ray_capacity = {}, {}, {}, 0
}

@(private = "file")
destroy_split_storage :: proc(s: ^Gi_Split, platform: ^core.Platform_API) {
	for b in ([]gpu.Buffer{s.slots, s.deposits, s.index, s.lists, s.counters, s.arguments, s.accum, s.history, s.merged}) {
		platform.gpu_destroy_buffer(b)
	}
	platform.gpu_destroy_texture(s.atlas)
	s.slots, s.deposits, s.index, s.lists, s.counters, s.arguments, s.accum, s.history, s.merged, s.atlas = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
}

// sync_gi_split_pipelines makes the split cascades' pipelines, with Ray_Query only.
@(private)
sync_gi_split_pipelines :: proc(r: ^Renderer, force: bool) {
	if !r.caps.ray_query {
		return
	}
	s := &r.gi.split
	assets := r.residency.assets
	sync_compute_pipeline(&s.table, r.platform, assets, {label = "gi split table"}, force)
	sync_compute_pipeline(&s.trace, r.platform, assets, {label = "gi split trace"}, force)
	sync_compute_pipeline(&s.deposit, r.platform, assets, {label = "gi split deposit"}, force)
	sync_compute_pipeline(&s.merge, r.platform, assets, {label = "gi split merge"}, force)
	sync_compute_pipeline(&s.gather, r.platform, assets, {label = "gi split gather"}, force)
}

// gi_split_ready is whether the split cascades' pipelines have compiled.
@(private)
gi_split_ready :: proc(r: ^Renderer) -> bool {
	s := &r.gi.split
	for p in ([]^Shader_Pipeline{&s.table, &s.trace, &s.deposit, &s.merge, &s.gather}) {
		if !pipeline_ready(r.platform, p) {
			return false
		}
	}
	return true
}

// split_cell is the cell of a position whose cells are 2^exponent meters. The shift is arithmetic, so a negative
// position floors.
split_cell :: proc(p: ecs.World_Position, exponent: i32) -> [3]i64 {
	shift := u64(i32(ecs.POSITION_FRACTION_BITS) + exponent)
	return {p.raw.x >> shift, p.raw.y >> shift, p.raw.z >> shift}
}

// place_split_window moves a level's window to have the camera's cell in its middle, its first cell a multiple of
// SPLIT_SNAP, and gives how far it moved, in cells. A window's first placement moves it a whole window, which frees
// every probe of its level.
place_split_window :: proc(w: ^Split_Window, camera: ecs.World_Position, exponent: i32) -> (delta: [3]i64) {
	cell := split_cell(camera, exponent)
	anchor: [3]i64
	for axis in 0 ..< 3 {
		anchor[axis] = (cell[axis] - SPLIT_WINDOW / 2) & ~i64(SPLIT_SNAP - 1)
	}
	if !w.valid {
		w.anchor, w.valid = anchor, true
		return {SPLIT_WINDOW, SPLIT_WINDOW, SPLIT_WINDOW}
	}
	delta = anchor - w.anchor
	w.anchor = anchor
	return
}

// split_window_min is a window's first cell relative to the camera, in meters, from whole units, so it is exact
// wherever the camera is.
split_window_min :: proc(anchor: [3]i64, camera: ecs.World_Position, exponent: i32) -> [3]f32 {
	shift := u64(i32(ecs.POSITION_FRACTION_BITS) + exponent)
	scale := f64(1) / f64(i64(1) << ecs.POSITION_FRACTION_BITS)
	return {
		f32(f64((anchor.x << shift) - camera.raw.x) * scale),
		f32(f64((anchor.y << shift) - camera.raw.y) * scale),
		f32(f64((anchor.z << shift) - camera.raw.z) * scale),
	}
}

// split_key matches split_key in gi_split.hlsli.
split_key :: proc(level: u32, u: [3]u32) -> u32 {
	return 0x80000000 | level << 27 | u.z << 18 | u.y << 9 | u.x
}

// split_rekey is a key after its level's window moved by delta, at cascade k, and false when it left the window.
split_rekey :: proc(key: u32, k: u32, delta: [3]i32) -> (u32, bool) {
	level := (key >> 27) & 7
	u := [3]i32{i32(key & 511) - (delta.x >> k), i32((key >> 9) & 511) - (delta.y >> k), i32((key >> 18) & 511) - (delta.z >> k)}
	limit := i32(SPLIT_WINDOW >> k)
	if u.x < 0 || u.y < 0 || u.z < 0 || u.x >= limit || u.y >= limit || u.z >= limit {
		return 0, false
	}
	return split_key(level, {u32(u.x), u32(u.y), u32(u.z)}), true
}

// split_hash matches split_hash in gi_split.hlsli.
split_hash :: proc(x: u32) -> u32 {
	x := x
	x ~= x >> 16
	x *= 0x7feb352d
	x ~= x >> 15
	x *= 0x846ca68b
	x ~= x >> 16
	return x
}

// split_lod matches split_lod in gi_split.hlsli: the levels at a Chebyshev distance from the camera, level and level
// + 1 by blend.
split_lod :: proc(r, distance, band: f32) -> (level: u32, blend: f32) {
	x := math.log2(max(r, distance) / distance)
	level = u32(math.floor(x))
	blend = clamp((x - math.floor(x) - (1 - band)) / band, 0, 1)
	return
}

// split_interval is the first cascade's interval, in cells: a direction texel's width at the probe's center, so the
// rays of neighbouring directions meet where the interval ends.
split_interval :: proc(directions: u32) -> f32 {
	return f32(directions) / math.sqrt(f32(4 * math.PI))
}

// split_hit_cascade matches split_hit_cascade in gi_split.hlsli.
split_hit_cascade :: proc(t, first: f32) -> u32 {
	return u32(math.ceil(max(0.5 * math.log2(max(t, 1e-6) / first), 0)))
}

// split_layout places each cascade's slots, entries and bins.
split_layout :: proc(params: Gi_Split_Params) -> (l: Split_Layout) {
	l.count = params.cascades
	for k in 0 ..< params.cascades {
		slots := max(params.slots >> (2 * k), params.min_slots)
		side := params.directions << k
		entries := next_power_of_two(2 * slots)
		l.cascades[k] = {
			first_slot  = l.slots,
			slots       = slots,
			first_entry = l.entries,
			entries     = entries,
			first_bin   = l.bins,
			side        = side,
			chunks      = (side * side + SPLIT_GROUP - 1) / SPLIT_GROUP,
		}
		l.slots += slots
		l.entries += entries
		l.bins += slots * side * side
	}
	return
}

@(private = "file")
next_power_of_two :: proc(n: u32) -> u32 {
	p := u32(1)
	for p < n {
		p <<= 1
	}
	return p
}

// split_tile is the tiles that a frame traces, a ray from each: the level's tile, widened while the rays are more
// than hit shading takes.
split_tile :: proc(size: [2]u32, params: Gi_Split_Params) -> (tile, tiles: [2]u32) {
	tile = params.tile
	for {
		tiles = (size + tile - 1) / tile
		if tiles.x * tiles.y <= MAX_HIT_RAYS {
			return
		}
		if tile.x <= tile.y {
			tile.x *= 2
		} else {
			tile.y *= 2
		}
	}
}

// split_rotation is the pixel of each tile that a frame traces: over tile.x * tile.y frames each in turn, in the
// order of their bit-reversed indices, so successive frames are far apart in the tile.
split_rotation :: proc(frame: u32, tile: [2]u32) -> [2]u32 {
	count := tile.x * tile.y
	bits := u32(0)
	for (u32(1) << bits) < count {
		bits += 1
	}
	i := frame % count
	j := u32(0)
	for b in 0 ..< bits {
		j |= ((i >> b) & 1) << (bits - 1 - b)
	}
	return {j % tile.x, j / tile.x}
}

// split_bytes is the split cascades' memory at a level, without the rays' buffers.
split_bytes :: proc(params: Gi_Split_Params) -> int {
	l := split_layout(params)
	rows := (params.slots + SPLIT_ATLAS_COLUMNS - 1) / SPLIT_ATLAS_COLUMNS
	atlas := int(SPLIT_ATLAS_COLUMNS * GI_PROBE_TILE) * int(rows * GI_PROBE_TILE) * 8
	return int(l.slots) * (SPLIT_SLOT_SIZE + 4 + 8) + int(l.entries) * SPLIT_ENTRY_SIZE + int(l.bins) * (SPLIT_ACCUM_SIZE + SPLIT_HISTORY_SIZE + SPLIT_MERGED_SIZE) + atlas
}

// ensure_split_storage makes the tables, bins and atlas for a level's parameters, and the rays' buffers for a count
// of rays. New storage frees every probe.
@(private = "file")
ensure_split_storage :: proc(r: ^Renderer, params: Gi_Split_Params, rays: int) {
	s := &r.gi.split
	platform := r.platform
	if s.slots == {} || s.params != params {
		destroy_split_storage(s, platform)
		l := split_layout(params)
		buffer :: proc(platform: ^core.Platform_API, size: u32, label: string, indirect := false) -> gpu.Buffer {
			usage: gpu.Buffer_Usages = indirect ? {.Storage, .Indirect} : {.Storage}
			return platform.gpu_create_buffer({size = size, usage = usage, label = label}, nil)
		}
		s.slots = buffer(platform, l.slots * SPLIT_SLOT_SIZE, "gi split slots")
		s.deposits = buffer(platform, l.slots * 4, "gi split deposits")
		s.index = buffer(platform, l.entries * SPLIT_ENTRY_SIZE, "gi split index")
		s.lists = buffer(platform, l.slots * 8, "gi split lists")
		s.counters = buffer(platform, MAX_SPLIT_CASCADES * SPLIT_COUNTERS_SIZE, "gi split counters")
		s.arguments = buffer(platform, MAX_SPLIT_CASCADES * size_of(gpu.Dispatch_Indirect_Args), "gi split arguments", indirect = true)
		s.accum = buffer(platform, l.bins * SPLIT_ACCUM_SIZE, "gi split accumulators")
		s.history = buffer(platform, l.bins * SPLIT_HISTORY_SIZE, "gi split history")
		s.merged = buffer(platform, l.bins * SPLIT_MERGED_SIZE, "gi split merged")
		rows := (l.cascades[0].slots + SPLIT_ATLAS_COLUMNS - 1) / SPLIT_ATLAS_COLUMNS
		size := [2]u32{SPLIT_ATLAS_COLUMNS * GI_PROBE_TILE, rows * GI_PROBE_TILE}
		s.atlas = platform.gpu_create_texture({size = size, format = SPLIT_FORMAT, usage = {.Sampled, .Storage}, label = "gi split atlas"}, nil)
		s.params, s.layout = params, l
		s.windows = {}
		s.fresh = true
	}
	if rays > s.ray_capacity {
		for b in ([]gpu.Buffer{s.hits, s.surfaces, s.rays}) {
			platform.gpu_destroy_buffer(b)
		}
		s.ray_capacity = max(rays, s.ray_capacity * 2)
		capacity := u32(s.ray_capacity)
		s.hits = platform.gpu_create_buffer({size = capacity * size_of(Hit_Record), usage = {.Storage}, label = "gi split hits"}, nil)
		s.surfaces = platform.gpu_create_buffer({size = capacity * size_of(Hit_Surface), usage = {.Storage}, label = "gi split surfaces"}, nil)
		s.rays = platform.gpu_create_buffer({size = capacity * 16, usage = {.Storage}, label = "gi split rays"}, nil)
	}
}

// add_gi_split_passes adds the split cascades after the world probes, on the compute queue, and has the gather write
// the frame's diffuse and specular light. It is false, and adds nothing, without the world probes this frame, the
// split's pipelines, room for a batch of hit shading, or room in the upload ring; the frame then takes the screen
// cascades.
@(private)
add_gi_split_passes :: proc(f: ^Frame) -> bool {
	r := f.renderer
	platform := r.platform
	gf := f.gi
	pf := gf.probes
	if pf == nil || !gi_split_ready(r) || !hit_shading_ready(f) {
		return false
	}
	params := GI_SPLIT_PARAMS[gf.settings.level]
	tile, tiles := split_tile(f.size, params)
	ray_count := tiles.x * tiles.y
	upload, ok := platform.gpu_upload(size_of(Split_Grid), 16)
	if !ok {
		return false
	}
	ensure_split_storage(r, params, int(ray_count))
	s := &r.gi.split
	g := f.graph
	sf := new(Gi_Split_Frame, platform.frame_allocator)
	sf.upload, sf.fresh = upload, s.fresh
	s.fresh = false
	sf.slots = import_buffer(g, s.slots)
	sf.deposits = import_buffer(g, s.deposits)
	sf.index = import_buffer(g, s.index)
	sf.lists = import_buffer(g, s.lists)
	sf.counters = import_buffer(g, s.counters)
	sf.arguments = import_buffer(g, s.arguments)
	sf.accum = import_buffer(g, s.accum)
	sf.history = import_buffer(g, s.history)
	sf.merged = import_buffer(g, s.merged)
	sf.atlas = import_texture(g, s.atlas, .Storage)
	sf.hits = import_buffer(g, s.hits)
	sf.surfaces = import_buffer(g, s.surfaces)
	sf.rays = import_buffer(g, s.rays)

	s.frame += 1
	grid := &sf.grid
	for l in 0 ..< int(params.levels) {
		exponent := params.voxel + i32(l)
		w := &s.windows[l]
		delta := place_split_window(w, f.view.position, exponent)
		min := split_window_min(w.anchor, f.view.position, exponent)
		// A move of a whole window or more frees every probe, however far it went.
		clamped := [3]i32{i32(clamp(delta.x, -SPLIT_WINDOW, SPLIT_WINDOW)), i32(clamp(delta.y, -SPLIT_WINDOW, SPLIT_WINDOW)), i32(clamp(delta.z, -SPLIT_WINDOW, SPLIT_WINDOW))}
		grid.levels[l] = {min = {min.x, min.y, min.z, math.pow(2, f32(exponent))}, delta = {clamped.x, clamped.y, clamped.z, 0}}
	}
	l := s.layout
	copy(grid.cascades[:], l.cascades[:])
	offset := ecs.position_sub(f.view.position, r.scene.origin)
	grid^ = {
		levels          = grid.levels,
		cascades        = grid.cascades,
		camera_offset   = {offset.x, offset.y, offset.z, 0},
		level_count     = params.levels,
		cascade_count   = params.cascades,
		directions      = params.directions,
		frame           = s.frame,
		tile            = tile,
		tiles           = tiles,
		rotation        = split_rotation(s.frame, tile),
		lifetime        = SPLIT_LIFETIME,
		ray_count       = ray_count,
		level_distance  = f32(params.distance) * math.pow(2, f32(params.voxel)),
		band            = SPLIT_BAND,
		interval        = split_interval(params.directions),
		bias            = SPLIT_BIAS,
		decay           = 1 - 1 / params.history_frames,
		max_count       = SPLIT_MAX_COUNT,
		confidence_half = SPLIT_CONFIDENCE_HALF,
		radiance_scale  = SPLIT_RADIANCE_SCALE,
		radiance_max    = SPLIT_RADIANCE_MAX,
		total_slots     = l.slots,
		total_entries   = l.entries,
		total_bins      = l.bins,
		atlas_columns   = SPLIT_ATLAS_COLUMNS,
	}
	(^Split_Grid)(raw_data(upload.data))^ = grid^

	step :: proc(f: ^Frame, sf: ^Gi_Split_Frame, pass: Split_Pass, cascade: u32 = 0) -> ^Split_Step {
		return new_clone(Split_Step{f, sf, pass, cascade}, f.renderer.platform.frame_allocator)
	}
	if sf.fresh {
		p := add_compute_pass(g, "gi split clear", run_split_pass, step(f, sf, .Clear), queue = .Compute)
		write(g, p, sf.slots)
		write(g, p, sf.deposits)
		write(g, p, sf.accum)
	}
	p := add_compute_pass(g, "gi split index", run_split_pass, step(f, sf, .Index), queue = .Compute)
	write(g, p, sf.index)
	write(g, p, sf.counters)
	p = add_compute_pass(g, "gi split rebuild", run_split_pass, step(f, sf, .Rebuild), queue = .Compute)
	write(g, p, sf.slots)
	write(g, p, sf.index)
	write(g, p, sf.lists)
	write(g, p, sf.counters)
	p = add_compute_pass(g, "gi split allocate", run_split_pass, step(f, sf, .Allocate), queue = .Compute)
	read(g, p, f.depth)
	read(g, p, f.normals)
	write(g, p, sf.slots)
	write(g, p, sf.index)
	write(g, p, sf.lists)
	write(g, p, sf.counters)
	p = add_compute_pass(g, "gi split arguments", run_split_pass, step(f, sf, .Arguments), queue = .Compute)
	write(g, p, sf.counters)
	write(g, p, sf.arguments)
	p = add_compute_pass(g, "gi split trace", run_split_pass, step(f, sf, .Trace), queue = .Compute)
	read(g, p, f.depth)
	read(g, p, f.normals)
	read_accel(g, p, ray_scene_accel(f))
	write(g, p, sf.hits)
	// hit_shading_ready said that it can.
	add_hit_shading(f, {hits = sf.hits, surfaces = sf.surfaces, count = ray_count}, .Compute)
	add_hit_light_passes(f, pf, "gi split", sf.hits, sf.surfaces, sf.rays, ray_count)
	p = add_compute_pass(g, "gi split deposit", run_split_pass, step(f, sf, .Deposit), queue = .Compute)
	read(g, p, f.depth)
	read(g, p, f.normals)
	read(g, p, sf.hits)
	read(g, p, sf.rays)
	read(g, p, sf.index)
	read(g, p, f.exposure)
	write(g, p, sf.accum)
	write(g, p, sf.slots)
	write(g, p, sf.deposits)
	for k := int(params.cascades) - 1; k >= 0; k -= 1 {
		p = add_compute_pass(g, "gi split merge", run_split_pass, step(f, sf, .Merge, u32(k)), queue = .Compute)
		indirect_buffer(g, p, sf.arguments)
		read(g, p, sf.lists)
		read(g, p, sf.counters)
		read(g, p, sf.index)
		read(g, p, f.exposure)
		write(g, p, sf.slots)
		write(g, p, sf.deposits)
		write(g, p, sf.accum)
		write(g, p, sf.history)
		write(g, p, sf.merged)
		if k == 0 {
			write(g, p, sf.atlas)
		}
		declare_probe_reads(f, p)
	}
	p = add_compute_pass(g, "gi split gather", run_split_pass, step(f, sf, .Gather), queue = .Compute)
	read(g, p, f.depth)
	read(g, p, f.normals)
	read(g, p, sf.index)
	read(g, p, sf.slots)
	read(g, p, sf.merged)
	read(g, p, sf.atlas)
	write(g, p, gf.diffuse.current)
	write(g, p, gf.specular.current)
	declare_probe_reads(f, p)
	return true
}

@(private = "file")
Split_Pass :: enum {
	Clear,
	Index,
	Rebuild,
	Allocate,
	Arguments,
	Trace,
	Deposit,
	Merge,
	Gather,
}

// Split_Step is one split pass's data, in frame memory.
@(private = "file")
Split_Step :: struct {
	frame:   ^Frame,
	split:   ^Gi_Split_Frame,
	pass:    Split_Pass,
	cascade: u32,
}

// run_split_pass dispatches a split pass. A pass binds each table for writing where it writes it, and for reading
// where it reads it. Its pass constants are the global illumination's, for the pixels' surfaces and the world probes.
@(private = "file")
run_split_pass :: proc(ctx: ^Pass_Context) {
	step := (^Split_Step)(ctx.data)
	f := step.frame
	sf := step.split
	s := &f.renderer.gi.split
	gf := f.gi
	g := ctx.graph
	written: bit_set[Split_Table]
	switch step.pass {
	case .Clear:
		written = {.Slots, .Deposits, .Accum}
	case .Index:
		written = {.Index, .Counters}
	case .Rebuild, .Allocate:
		written = {.Slots, .Index, .Lists, .Counters}
	case .Arguments:
		written = {.Counters, .Arguments}
	case .Trace:
		written = {.Hits}
	case .Deposit:
		written = {.Accum, .Slots, .Deposits}
	case .Merge:
		// Only the first cascade's merge writes the atlas.
		written = {.Slots, .Deposits, .Accum, .History, .Merged}
		if step.cascade == 0 {
			written += {.Atlas}
		}
	case .Gather:
	}
	bind :: proc(g: ^Graph, buffer: Buffer, table: Split_Table, written: bit_set[Split_Table]) -> u32 {
		b := gpu_buffer(g, buffer)
		return table in written ? gpu.write_index(b) : gpu.read_index(b)
	}
	atlas := gpu_texture(g, sf.atlas)
	push := Split_Push {
		grid        = gpu.read_index(sf.upload.buffer),
		grid_offset = sf.upload.offset,
		phase       = u32(step.pass),
		cascade     = step.cascade,
		slots       = bind(g, sf.slots, .Slots, written),
		deposits    = bind(g, sf.deposits, .Deposits, written),
		index       = bind(g, sf.index, .Index, written),
		lists       = bind(g, sf.lists, .Lists, written),
		counters    = bind(g, sf.counters, .Counters, written),
		arguments   = bind(g, sf.arguments, .Arguments, written),
		accum       = bind(g, sf.accum, .Accum, written),
		history     = bind(g, sf.history, .History, written),
		merged      = bind(g, sf.merged, .Merged, written),
		atlas       = .Atlas in written ? gpu.write_index(atlas) : gpu.read_index(atlas),
		hits        = bind(g, sf.hits, .Hits, written),
		rays        = bind(g, sf.rays, .Rays, written),
		exposure    = gpu.read_index(gpu_buffer(g, f.exposure)),
	}
	if step.pass == .Trace {
		push.accel = gpu.read_index(gpu_accel(g, ray_scene_accel(f)))
	}
	c := gi_constants(ctx, f)
	pipeline := s.table.pipeline
	dispatch: [3]u32
	grid := &sf.grid
	switch step.pass {
	case .Clear:
		dispatch = split_groups(max(grid.total_bins, grid.total_slots))
	case .Index:
		dispatch = split_groups(max(grid.total_entries, grid.cascade_count))
	case .Rebuild:
		dispatch = split_groups(grid.total_slots)
	case .Allocate:
		dispatch = split_groups(grid.ray_count)
	case .Arguments:
		dispatch = {1, 1, 1}
	case .Trace:
		pipeline, dispatch = s.trace.pipeline, split_groups(grid.ray_count)
	case .Deposit:
		pipeline, dispatch = s.deposit.pipeline, split_groups(grid.ray_count)
	case .Merge:
		pipeline = s.merge.pipeline
	case .Gather:
		pipeline, dispatch = s.gather.pipeline, groups(f.size, POST_GROUP_SIZE)
		c.out_diffuse = gpu.write_index(gpu_texture(g, gf.diffuse.current))
		c.out_specular = gpu.write_index(gpu_texture(g, gf.specular.current))
	}
	// The table's phases are its own: the pass's phase is its index among them.
	if step.pass > .Arguments {
		push.phase = 0
	}
	gpu.cmd_set_pipeline(ctx.cb, pipeline)
	if !upload_gi_constants(ctx, f, c) {
		return
	}
	gpu.cmd_push_constants(ctx.cb, &push)
	if step.pass == .Merge {
		gpu.cmd_dispatch_indirect(ctx.cb, gpu_buffer(g, sf.arguments), step.cascade * size_of(gpu.Dispatch_Indirect_Args))
	} else if dispatch.x > 0 {
		gpu.cmd_dispatch(ctx.cb, dispatch)
	}
}

@(private = "file")
Split_Table :: enum {
	Slots,
	Deposits,
	Index,
	Lists,
	Counters,
	Arguments,
	Accum,
	History,
	Merged,
	Atlas,
	Hits,
	Rays,
}

// split_groups is a dispatch of a thread for each of count, in groups of SPLIT_GROUP, in rows of at most 65535 groups.
split_groups :: proc(count: u32) -> [3]u32 {
	n := (count + SPLIT_GROUP - 1) / SPLIT_GROUP
	return {min(n, 65535), (n + 65534) / 65535, 1}
}
