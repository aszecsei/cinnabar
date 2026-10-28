package render

import "core:log"
import "core:math"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// GPU particles (see docs/rendering/particles.md#particles): a Particle_System places an effect asset, whose emitters
// the GPU simulates in frame time and draws as compute sprites. Each emitter of a system owns a range of one pool of
// particles. Every frame, a thread for each particle of a range ages it, moves it with the emitter's modules and
// collides it with the depth that the camera saw last frame, or, while it is dead, takes one of the frame's new
// particles, if any are left, from a counter. A living particle appends its sprite, with its color, size and emission
// from the emitter's curves at its age. Particles are relative to their system's anchor, the system's position when
// its effect started, so they stay where they are when it moves and the render origin moves under nothing.

PARTICLE_UPDATE_SHADER :: #load("../content/shaders/particle_update.hlsl.meta", string)
PARTICLE_HISTORY_SHADER :: #load("../content/shaders/particle_history.hlsl.meta", string)

PARTICLE_SYSTEM_ID :: ecs.Component_Id(52)

// The pool's size, in particles, and the systems that can be alive at once.
MAX_PARTICLES :: 1 << 18
MAX_PARTICLE_SYSTEMS :: 256
// The pool's free ranges, which a pool of many small systems that come and go may fill.
MAX_PARTICLE_RANGES :: 1024
// A frame steps its particles by this much time at most, in seconds, so a long frame does not throw them far.
MAX_PARTICLE_DELTA :: 0.1
// Matches Particle in particles.hlsli, and numthreads in particle_update.hlsl.
PARTICLE_SIZE :: 48
PARTICLE_GROUP :: 64
// Last frame's view depth in w and world normal in xyz, which the particles collide with.
PARTICLE_HISTORY_FORMAT :: gpu.Format.RGBA16_Float

// Particle_System places an effect at its entity's Transform: its emitters spawn particles there, which then move in
// the world on their own (see docs/rendering/particles.md#particles). A new effect, or a new version of it, starts the
// system again.
Particle_System :: struct {
	effect:     format.Guid `asset:"effect"`,
	// Stops new particles. Those that are alive live out their lives.
	paused:     bool,
	// Scales the emitters' rates and bursts. 0 means 1.
	rate_scale: f32 `editor:"range=0,10"`,
}

// Particle_Range is a range of the pool, in particles.
@(private)
Particle_Range :: struct {
	first, count: u32,
}

// Particle_Slot is a system's state between frames: its effect, its anchor, and each emitter's range of the pool and
// what it has spawned.
@(private)
Particle_Slot :: struct {
	used:       bool,
	entity:     ecs.Entity,
	effect:     format.Guid,
	handle:     asset.Handle,
	// The effect's blob version that the ranges are for, once started.
	started:    bool,
	version:    u32,
	// Whether the effect's ranges are new this frame, so their particles start dead.
	reset:      bool,
	anchor:     ecs.World_Position,
	// Seconds since the effect started, in the system's time.
	age:        f32,
	ranges:     [format.MAX_EFFECT_EMITTERS]Particle_Range,
	// The fraction of a particle that each emitter's rate has spawned, and its next burst's time, or -1 after its only
	// one.
	carry:      [format.MAX_EFFECT_EMITTERS]f32,
	next_burst: [format.MAX_EFFECT_EMITTERS]f32,
	seen:       u64,
}

// Particles is the particles' state between frames, in the Renderer.
Particles :: struct {
	update:                   Shader_Pipeline,
	history:                  Shader_Pipeline,
	// A registration, made again in renderer_reload.
	systems:                  Extractor,
	pool:                     gpu.Buffer,
	// The emitters' counters of the frame's new particles that they took.
	counters:                 gpu.Buffer,
	free:                     [MAX_PARTICLE_RANGES]Particle_Range,
	free_count:               int,
	slots:                    [MAX_PARTICLE_SYSTEMS]Particle_Slot,
	// The effect previews' systems, by preview, and their cameras last frame (see docs/rendering/particles.md#previews).
	previews:                 [gpu.MAX_PREVIEW_TARGETS]Particle_Slot,
	preview_cameras:          [gpu.MAX_PREVIEW_TARGETS]Particle_Camera,
	frame:                    u64,
	// The host's time at the last frame, and the time since then, which the systems that play in the editor and the
	// previews step by, in seconds.
	last_wall:                f64,
	wall_delta:               f32,
	// Last frame's camera, whose depth the history holds.
	previous_position:        ecs.World_Position,
	previous_view_projection: matrix[4, 4]f32,
	has_previous:             bool,
	// The emitters that a system could not fit in the pool, which are logged once.
	full_logged:              bool,
}

// Particle_Camera is a view's camera last frame, relative to its anchor's space, for a preview's collisions.
@(private)
Particle_Camera :: struct {
	position:        [3]f32,
	view_projection: matrix[4, 4]f32,
	valid:           bool,
}

// Emitter_Record matches Emitter_Record in particles.hlsli: one emitter of a system this frame. rows is the system's
// pose relative to its anchor, and anchor and previous_anchor the anchor relative to this frame's and last frame's
// camera. delta is the time that the system steps, and time its age, which the noise moves with.
@(private)
Emitter_Record :: struct {
	first:           u32,
	capacity:        u32,
	spawn:           u32,
	reset:           u32,
	rows:            [3][4]f32,
	anchor:          [3]f32,
	seed:            u32,
	previous_anchor: [3]f32,
	module_count:    u32,
	lifetime:        [2]f32,
	speed:           [2]f32,
	spin:            [2]f32,
	shape:           u32,
	shape_size:      [3]f32,
	texture:         u32,
	flipbook:        [2]u32,
	flipbook_rate:   f32,
	softness:        f32,
	modules:         u32,
	curves:          u32,
	delta:           f32,
	time:            f32,
}

// Particle_Constants matches Particle_Constants in particles.hlsli, the update pass's pass constants.
@(private)
Particle_Constants :: struct {
	previous_view_projection: matrix[4, 4]f32,
	emitters:                 u32,
	emitters_offset:          u32,
	modules:                  u32,
	modules_offset:           u32,
	curves:                   u32,
	curves_offset:            u32,
	pool:                     u32,
	counters:                 u32,
	sprites:                  u32,
	sprite_count:             u32,
	history:                  u32,
	has_history:              u32,
	history_size:             [2]u32,
	near:                     f32,
	padding:                  [3]u32,
}

// History_Push matches History_Push in particle_history.hlsl.
@(private = "file")
History_Push :: struct {
	depth:   u32,
	normals: u32,
	output:  u32,
	padding: u32,
	size:    [2]u32,
}

#assert(size_of(Emitter_Record) == 172 && size_of(Particle_Constants) <= 256)

// Particle_Frame is what one frame's particle passes need, in frame memory.
@(private)
Particle_Frame :: struct {
	emitters:  gpu.Upload,
	count:     int,
	modules:   gpu.Upload,
	curves:    gpu.Upload,
	zeros:     gpu.Upload,
	constants: gpu.Upload,
	target:    Sprite_Target,
	pool:      Buffer,
	counters:  Buffer,
	history:   History,
	// The history's label, one for each view that keeps one.
	history_label: string,
	// Whether last frame drew from a camera, which the history's depth is from.
	has_previous: bool,
}

// Particle_Step is what a view's systems write this frame, in frame memory: their emitters' records, modules and curve
// rows, and the sprites that they may append.
@(private = "file")
Particle_Step :: struct {
	emitters: [dynamic]Emitter_Record,
	modules:  [dynamic]format.Effect_Module,
	curves:   [dynamic]format.Effect_Curve_Row,
	capacity: int,
}

particles_init :: proc(p: ^Particles, w: ^ecs.World) {
	p.update = shader_pipeline(PARTICLE_UPDATE_SHADER)
	p.history = shader_pipeline(PARTICLE_HISTORY_SHADER)
	particles_register(p, w)
}

// particles_register makes the systems' extractor, in init and after a code reload.
particles_register :: proc(p: ^Particles, w: ^ecs.World) {
	p.systems = extractor(w, {ecs.read(w, Particle_System)})
}

particles_destroy :: proc(p: ^Particles, platform: ^core.Platform_API) {
	destroy_shader_pipeline(&p.update, platform)
	destroy_shader_pipeline(&p.history, platform)
	for b in ([]gpu.Buffer{p.pool, p.counters}) {
		if b != {} {
			platform.gpu_destroy_buffer(b)
		}
	}
}

@(private)
sync_particle_pipelines :: proc(r: ^Renderer, force: bool) {
	p := &r.particles
	sync_compute_pipeline(&p.update, r.platform, r.residency.assets, {label = "particle update"}, force)
	sync_compute_pipeline(&p.history, r.platform, r.residency.assets, {label = "particle history"}, force)
}

// begin_particles steps the systems' state on the CPU, after begin_sprites: what each emitter spawns this frame, from
// its rate, its bursts and its time, and its records for the update pass. A system's first frame, or its effect's new
// version, gives its emitters new ranges of the pool. The ranges of a system that is gone return to the pool. Without
// the particles' pipelines or the sprites', no system steps. delta is the frame's simulation time, in seconds; a system
// in playing steps by the host's time instead while delta is 0, as the editor plays its selected systems.
@(private)
begin_particles :: proc(f: ^Frame, w: ^ecs.World, delta: f32, hidden: []u32, playing: []ecs.Entity) {
	r := f.renderer
	p := &r.particles
	platform := r.platform
	if platform.time_seconds != nil {
		now := platform.time_seconds()
		p.wall_delta = p.last_wall > 0 ? f32(clamp(now - p.last_wall, 0, MAX_PARTICLE_DELTA)) : 0
		p.last_wall = now
	}
	// The history that the update reads is last frame's, from last frame's camera, which only a frame after another has.
	has_previous := p.has_previous
	defer {
		p.previous_position, p.previous_view_projection, p.has_previous = f.view.position, f.view_projection, true
	}
	if !particles_ready(f) {
		return
	}
	dt := clamp(delta, 0, MAX_PARTICLE_DELTA)
	p.frame += 1
	assets := r.residency.assets
	step := new_particle_step(platform)

	it := ecs.query_iter(w, p.systems.query)
	for view in ecs.query_next(&it) {
		for e, i in ecs.entities(view) {
			system := ecs.column(view, EXTRACT_TERMS, Particle_System)[i]
			slot := particle_slot(p, e)
			if slot == nil {
				continue
			}
			slot.seen = p.frame
			pose, visible := light_pose(w, view, i, hidden, e)
			data, version, loaded := slot_effect(p, slot, assets, system.effect, nil, 0)
			if !loaded {
				continue
			}
			if !slot.started || version != slot.version {
				anchor := pose
				if !visible {
					anchor, _ = ecs.presented(w, e)
				}
				start_slot(p, slot, data, version)
				slot.anchor = anchor.position
			}
			// A hidden system keeps its particles where they are, and draws none.
			if !visible {
				continue
			}
			system_dt := dt
			if dt == 0 && slice_has(playing, e) {
				system_dt = p.wall_delta
			}
			scale := system.rate_scale > 0 ? system.rate_scale : 1
			anchor := ecs.position_sub(slot.anchor, f.view.position)
			previous_anchor := ecs.position_sub(slot.anchor, p.previous_position)
			step_slot(r, step, slot, data, pose_rows(pose, slot.anchor), anchor, previous_anchor, system_dt, scale, system.paused)
		}
	}
	// The systems that are gone, inactive or without the component return their ranges.
	for &slot in p.slots {
		if slot.used && slot.seen != p.frame {
			free_slot_ranges(p, &slot)
			slot = {}
		}
	}
	finish_particles(f, step, p.previous_view_projection, has_previous, "particle history")
}

// particles_ready is whether the frame can step particles: the particles' pipelines and the sprites' are compiled. The
// pool is made the first time.
@(private = "file")
particles_ready :: proc(f: ^Frame) -> bool {
	r := f.renderer
	p := &r.particles
	platform := r.platform
	if f.sprites == nil || r.residency.assets == nil || !pipeline_ready(platform, &p.update) || !pipeline_ready(platform, &p.history) {
		return false
	}
	if p.pool == {} {
		p.pool = platform.gpu_create_buffer({size = MAX_PARTICLES * PARTICLE_SIZE, usage = {.Storage}, label = "particles"}, nil)
		p.counters = platform.gpu_create_buffer({size = MAX_PARTICLE_SYSTEMS * format.MAX_EFFECT_EMITTERS * 4, usage = {.Storage}, label = "particle counters"}, nil)
		p.free[0], p.free_count = {0, MAX_PARTICLES}, 1
	}
	return true
}

@(private = "file")
new_particle_step :: proc(platform: ^core.Platform_API) -> ^Particle_Step {
	step := new(Particle_Step, platform.frame_allocator)
	step.emitters = make([dynamic]Emitter_Record, platform.frame_allocator)
	step.modules = make([dynamic]format.Effect_Module, platform.frame_allocator)
	step.curves = make([dynamic]format.Effect_Curve_Row, platform.frame_allocator)
	return step
}

@(private = "file")
slice_has :: proc(entities: []ecs.Entity, e: ecs.Entity) -> bool {
	for x in entities {
		if x == e {
			return true
		}
	}
	return false
}

// slot_effect gives a system's effect blob and its version: unsaved, the data that a preview gives with its version,
// or the cooked asset, which the first call loads. A new effect frees the system's ranges, so it starts again.
@(private = "file")
slot_effect :: proc(p: ^Particles, slot: ^Particle_Slot, assets: ^asset.Assets, effect: format.Guid, unsaved: []byte, unsaved_version: u32) -> (data: []byte, version: u32, ok: bool) {
	if effect != slot.effect {
		free_slot_ranges(p, slot)
		slot.effect, slot.started, slot.handle = effect, false, {}
		if unsaved == nil {
			slot.handle, _ = asset.load(assets, effect)
		}
	}
	if unsaved != nil {
		data, version = unsaved, unsaved_version
	} else {
		loaded: bool
		data, loaded = asset.data(assets, slot.handle)
		if !loaded || asset.guid(assets, slot.handle) != effect {
			return
		}
		version = asset.version(assets, slot.handle)
	}
	_, ok = format.effect_view(data)
	return
}

// step_slot steps a started system by dt and appends its emitters' records: what each spawns from its rate, its
// carried fraction and its bursts, and the records of its ranges.
@(private = "file")
step_slot :: proc(
	r: ^Renderer,
	step: ^Particle_Step,
	slot: ^Particle_Slot,
	data: []byte,
	rows: [3][4]f32,
	anchor, previous_anchor: [3]f32,
	dt, scale: f32,
	paused: bool,
) {
	p := &r.particles
	blob, _ := format.effect_view(data)
	effect_emitters := format.effect_emitters(data, blob)
	effect_curves := format.effect_curves(data, blob)
	for em, k in effect_emitters[:min(len(effect_emitters), format.MAX_EFFECT_EMITTERS)] {
		spawn := 0
		if !paused {
			slot.carry[k] += em.rate * scale * dt
			spawn = int(slot.carry[k])
			slot.carry[k] -= f32(spawn)
			if em.burst > 0 && slot.next_burst[k] >= 0 && slot.age >= slot.next_burst[k] && dt > 0 {
				spawn += int(f32(em.burst) * scale)
				slot.next_burst[k] = em.burst_interval > 0 ? slot.next_burst[k] + em.burst_interval : -1
			}
		}
		rng := slot.ranges[k]
		if rng.count == 0 {
			continue
		}
		texture := u32(SPRITE_NO_TEXTURE)
		if t, ready := resident_texture(&r.residency, em.texture); ready {
			texture = gpu.read_index(t.texture)
		}
		em_modules := format.effect_modules(data, em)
		append(&step.emitters, Emitter_Record {
			first           = rng.first,
			capacity        = rng.count,
			spawn           = u32(min(spawn, int(rng.count))),
			reset           = u32(slot.reset),
			rows            = rows,
			anchor          = anchor,
			seed            = u32(p.frame) * 2654435761 ~ u32(len(step.emitters)) * 40503 ~ rng.first,
			previous_anchor = previous_anchor,
			module_count    = u32(len(em_modules)),
			lifetime        = em.lifetime,
			speed           = em.speed,
			spin            = em.spin,
			shape           = u32(em.shape),
			shape_size      = em.shape_size,
			texture         = texture,
			flipbook        = em.flipbook,
			flipbook_rate   = em.flipbook_rate,
			softness        = em.softness,
			modules         = u32(len(step.modules)),
			curves          = u32(len(step.curves)),
			delta           = dt,
			time            = slot.age,
		})
		append(&step.modules, ..em_modules)
		append(&step.curves, ..effect_curves[em.curves:][:len(format.Effect_Curve)])
		step.capacity += int(rng.count)
	}
	slot.reset = false
	slot.age = math.mod(slot.age + dt, 3600)
}

// finish_particles reserves the view's sprites and uploads its step's records, for its update pass. Without emitters
// to step, Frame.particles stays nil.
@(private = "file")
finish_particles :: proc(f: ^Frame, step: ^Particle_Step, previous_view_projection: matrix[4, 4]f32, has_previous: bool, history_label: string) {
	if len(step.emitters) == 0 {
		return
	}
	platform := f.renderer.platform
	target, reserved := reserve_sprites(f, step.capacity)
	if !reserved {
		return
	}
	pf := new(Particle_Frame, platform.frame_allocator)
	pf.target = target
	pf.count = len(step.emitters)
	pf.has_previous = has_previous
	pf.history_label = history_label
	// An upload is never empty, so a view without modules uploads one that no emitter reads.
	if len(step.modules) == 0 {
		append(&step.modules, format.Effect_Module{})
	}
	ok: bool
	if pf.emitters, ok = upload_bytes(platform, ([^]byte)(raw_data(step.emitters))[:len(step.emitters) * size_of(Emitter_Record)]); !ok {
		return
	}
	if pf.modules, ok = upload_bytes(platform, ([^]byte)(raw_data(step.modules))[:len(step.modules) * size_of(format.Effect_Module)]); !ok {
		return
	}
	if pf.curves, ok = upload_bytes(platform, ([^]byte)(raw_data(step.curves))[:len(step.curves) * size_of(format.Effect_Curve_Row)]); !ok {
		return
	}
	if pf.zeros, ok = platform.gpu_upload(len(step.emitters) * 4, 4); !ok {
		return
	}
	for &b in pf.zeros.data {
		b = 0
	}
	if pf.constants, ok = platform.gpu_upload(size_of(Particle_Constants), gpu.PASS_CONSTANTS_ALIGN); !ok {
		return
	}
	(^Particle_Constants)(raw_data(pf.constants.data))^ = {
		previous_view_projection = previous_view_projection,
		near                     = f.view.near,
	}
	f.particles = pf
}

// begin_preview_particles steps an effect preview's system, after the preview's frame began its sprites: the effect at
// the preview's origin, by the host's time, so it always plays. camera is the preview's camera relative to the origin.
// A new effect, or a new version of its blob, starts it again.
@(private)
begin_preview_particles :: proc(f: ^Frame, desc: ^Preview_Desc, camera: [3]f32) {
	r := f.renderer
	p := &r.particles
	if desc.id < 0 || desc.id >= len(p.previews) || !particles_ready(f) {
		return
	}
	slot := &p.previews[desc.id]
	previous := &p.preview_cameras[desc.id]
	has_previous := previous.valid
	defer {
		previous^ = {position = camera, view_projection = f.view_projection, valid = true}
	}
	data, version, loaded := slot_effect(p, slot, r.residency.assets, desc.material, desc.data, desc.version)
	if !loaded {
		return
	}
	slot.used = true
	if !slot.started || version != slot.version {
		start_slot(p, slot, data, version)
		has_previous = false
	}
	identity := [3][4]f32{{1, 0, 0, 0}, {0, 1, 0, 0}, {0, 0, 1, 0}}
	step := new_particle_step(r.platform)
	previous_position := has_previous ? previous.position : camera
	step_slot(r, step, slot, data, identity, -camera, -previous_position, p.wall_delta, 1, false)
	finish_particles(f, step, previous.view_projection, has_previous, "particle history (preview)")
}

// particle_slot is a system's slot, or a new one the first time that it is seen, or nil when every slot is in use.
@(private = "file")
particle_slot :: proc(p: ^Particles, e: ecs.Entity) -> ^Particle_Slot {
	empty: ^Particle_Slot
	for &slot in p.slots {
		if slot.used && slot.entity == e {
			return &slot
		}
		if !slot.used && empty == nil {
			empty = &slot
		}
	}
	if empty != nil {
		empty^ = {used = true, entity = e}
	}
	return empty
}

// start_slot starts a system's effect: a new range of the pool for each emitter, whose particles start dead, and its
// bursts at once. An emitter that the pool has no room for draws nothing, which is logged once.
@(private = "file")
start_slot :: proc(p: ^Particles, slot: ^Particle_Slot, data: []byte, version: u32) {
	blob, _ := format.effect_view(data)
	emitters := format.effect_emitters(data, blob)
	free_slot_ranges(p, slot)
	slot.started, slot.version, slot.reset, slot.age = true, version, true, 0
	for em, k in emitters[:min(len(emitters), format.MAX_EFFECT_EMITTERS)] {
		slot.carry[k] = 0
		slot.next_burst[k] = 0
		if rng, ok := allocate_particles(p, em.capacity); ok {
			slot.ranges[k] = rng
		} else if !p.full_logged {
			log.warnf("render: the particle pool has no room for an emitter of %d particles", em.capacity)
			p.full_logged = true
		}
	}
}

@(private = "file")
free_slot_ranges :: proc(p: ^Particles, slot: ^Particle_Slot) {
	for &rng in slot.ranges {
		if rng.count > 0 {
			free_particles(p, rng)
		}
		rng = {}
	}
}

// allocate_particles takes a range of count particles from the pool's first free range that holds it.
@(private)
allocate_particles :: proc(p: ^Particles, count: u32) -> (rng: Particle_Range, ok: bool) {
	for i in 0 ..< p.free_count {
		f := &p.free[i]
		if f.count < count {
			continue
		}
		rng = {f.first, count}
		f.first += count
		f.count -= count
		if f.count == 0 {
			copy(p.free[i:p.free_count - 1], p.free[i + 1:p.free_count])
			p.free_count -= 1
		}
		return rng, true
	}
	return
}

// free_particles returns a range to the pool, merged with the free ranges beside it. The free ranges stay in order.
@(private)
free_particles :: proc(p: ^Particles, rng: Particle_Range) {
	at := 0
	for at < p.free_count && p.free[at].first < rng.first {
		at += 1
	}
	joins_before := at > 0 && p.free[at - 1].first + p.free[at - 1].count == rng.first
	joins_after := at < p.free_count && rng.first + rng.count == p.free[at].first
	switch {
	case joins_before && joins_after:
		p.free[at - 1].count += rng.count + p.free[at].count
		copy(p.free[at:p.free_count - 1], p.free[at + 1:p.free_count])
		p.free_count -= 1
	case joins_before:
		p.free[at - 1].count += rng.count
	case joins_after:
		p.free[at].first = rng.first
		p.free[at].count += rng.count
	case p.free_count < MAX_PARTICLE_RANGES:
		copy(p.free[at + 1:p.free_count + 1], p.free[at:p.free_count])
		p.free[at] = rng
		p.free_count += 1
	case:
		// The pool loses the range until it restarts, rather than a smaller one: it is rare and small.
		log.warn("render: the particle pool has too many free ranges")
	}
}

// add_particle_passes adds the update pass before the prepass: it reads the history that last frame's history pass
// wrote, and appends the frame's sprites.
@(private)
add_particle_passes :: proc(f: ^Frame) {
	pf := f.particles
	if pf == nil {
		return
	}
	g := f.graph
	p := &f.renderer.particles
	pf.pool = import_buffer(g, p.pool)
	pf.counters = import_buffer(g, p.counters)
	pf.history = history_texture(g, {size = f.size, format = PARTICLE_HISTORY_FORMAT, label = pf.history_label})
	pass := add_compute_pass(g, "particle counters", proc(ctx: ^Pass_Context) {
		pf := (^Frame)(ctx.data).particles
		gpu.cmd_copy_buffer(ctx.cb, pf.zeros.buffer, pf.zeros.offset, gpu_buffer(ctx.graph, pf.counters), 0, u32(pf.count * 4))
	}, f)
	copy_dest(g, pass, pf.counters)
	pass = add_compute_pass(g, "particle update", run_particle_update, f)
	write(g, pass, pf.pool)
	write(g, pass, pf.counters)
	write(g, pass, pf.target.records)
	write(g, pass, pf.target.count)
	if pf.history.previous != 0 && pf.history.valid {
		read(g, pass, pf.history.previous)
	}
}

// add_particle_history_pass adds, after the prepass, the pass that keeps this frame's view depth and normals for next
// frame's collisions.
@(private)
add_particle_history_pass :: proc(f: ^Frame) {
	pf := f.particles
	if pf == nil || pf.history.current == 0 {
		return
	}
	g := f.graph
	pass := add_compute_pass(g, "particle history", proc(ctx: ^Pass_Context) {
		f := (^Frame)(ctx.data)
		g := ctx.graph
		push := History_Push {
			depth   = gpu.read_index(gpu_texture(g, f.depth)),
			normals = gpu.read_index(gpu_texture(g, f.normals)),
			output  = gpu.write_index(gpu_texture(g, f.particles.history.current)),
			size    = f.size,
		}
		gpu.cmd_set_pipeline(ctx.cb, f.renderer.particles.history.pipeline)
		gpu.cmd_set_pass_constants(ctx.cb, f.scene_frame.view_constants[VIEW_CAMERA])
		gpu.cmd_push_constants(ctx.cb, &push)
		gpu.cmd_dispatch(ctx.cb, groups(f.size, 8))
	}, f)
	read(g, pass, f.depth)
	read(g, pass, f.normals)
	write(g, pass, pf.history.current)
}

@(private = "file")
run_particle_update :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	pf := f.particles
	g := ctx.graph
	c := (^Particle_Constants)(raw_data(pf.constants.data))
	c.emitters, c.emitters_offset = gpu.read_index(pf.emitters.buffer), pf.emitters.offset
	c.modules, c.modules_offset = gpu.read_index(pf.modules.buffer), pf.modules.offset
	c.curves, c.curves_offset = gpu.read_index(pf.curves.buffer), pf.curves.offset
	c.pool = gpu.write_index(gpu_buffer(g, pf.pool))
	c.counters = gpu.write_index(gpu_buffer(g, pf.counters))
	c.sprites = gpu.write_index(gpu_buffer(g, pf.target.records))
	c.sprite_count = gpu.write_index(gpu_buffer(g, pf.target.count))
	if pf.history.valid && pf.history.previous != 0 && pf.has_previous {
		c.history = gpu.read_index(gpu_texture(g, pf.history.previous))
		c.has_history = 1
		c.history_size = f.size
	}
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.particles.update.pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, pf.constants)
	emitters := ([^]Emitter_Record)(raw_data(pf.emitters.data))[:pf.count]
	for e, i in emitters {
		push := u32(i)
		gpu.cmd_push_constants(ctx.cb, &push)
		gpu.cmd_dispatch(ctx.cb, {(e.capacity + PARTICLE_GROUP - 1) / PARTICLE_GROUP, 1, 1})
	}
}
