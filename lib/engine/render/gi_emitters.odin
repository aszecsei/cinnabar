package render

import "core:math/linalg"
import "core:slice"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/ecs"

// The GI's emitters (see docs/rendering/global-illumination.md#emitters): the emissive triangles that the hits' light
// samples beside the punctual lights. Emission is whatever a material's evaluate gives, from a constant, a texture or a
// graph, so the renderer learns it from hit shading itself: each frame a batch of rays starts at points of the frame's
// opaque submeshes, and hit shading evaluates their materials there. A discovery scan reads a few points of each
// submesh in turn back to the host, which lists a submesh whose points emit, and unlists one that stays dark or goes.
// Each listed submesh keeps a range of the radiance pool, a cell for each triangle, which the refresh's rays blend each
// triangle's emission into. Each frame, the build pass places the listed triangles relative to the camera, with their
// power, the radiance of the cell times the area, and a scan turns the powers into a distribution that the hits draw
// triangles from (see gi_light_sampling.hlsli). Each translucent submesh whose hit pass is ready keeps a range of the
// pool too, which the refresh blends its triangles' transmittance into, the light that passes through them, which the
// hits' shadow rays take (see gi_hit_light.hlsli). Only the frame's own view runs them.

// The most submeshes and triangles listed at once, and the most triangles of one listed submesh. Match
// gi_emitters.hlsl and gi_light_sampling.hlsli.
MAX_EMITTER_SUBMESHES :: 256
MAX_EMITTER_TRIANGLES :: 16384
MAX_EMITTER_SUBMESH_TRIANGLES :: 4096
// The discovery's submeshes a frame, and its points in each.
EMITTER_DISCOVERY_SUBMESHES :: 128
EMITTER_DISCOVERY_SAMPLES :: 8
EMITTER_DISCOVERY_JOBS :: EMITTER_DISCOVERY_SUBMESHES * EMITTER_DISCOVERY_SAMPLES
// The refresh's triangles a frame.
EMITTER_REFRESH_JOBS :: 4096
// The translucent triangles whose transmittance the refresh reads a frame, in turn.
EMITTER_TRANSMIT_JOBS :: 1024
MAX_EMITTER_JOBS :: EMITTER_DISCOVERY_JOBS + EMITTER_REFRESH_JOBS + EMITTER_TRANSMIT_JOBS
// A submesh is listed when a point's emitted luminance is at least this much, and unlisted after this many scans in a
// row find all its points darker.
EMITTER_MIN_LUMINANCE :: 1e-3
EMITTER_DARK_SCANS :: 4
// A discovery job's target has this bit, with its result's index below it; a refresh job's target is its pool cell.
EMITTER_DISCOVERY :: 0x80000000
// The threads of each group of every phase, which the scan's one group of a thread for each 16 triangles sets. Match
// gi_emitters.hlsl.
EMITTER_GROUP :: 1024
// The samples buffer: a header of the count and the total power, the distribution, then the triangles.
EMITTER_SAMPLES_HEADER :: 16
EMITTER_TRIANGLE_SIZE :: 48
EMITTER_SAMPLES_SIZE ::
	EMITTER_SAMPLES_HEADER +
	MAX_EMITTER_TRIANGLES * 4 +
	MAX_EMITTER_TRIANGLES * EMITTER_TRIANGLE_SIZE

// The emitters' shader, by its .meta file.
GI_EMITTERS_SHADER :: #load("../content/shaders/gi_emitters.hlsl.meta", string)

#assert(MAX_EMITTER_TRIANGLES % EMITTER_GROUP == 0)

// Emitter_Phase is a pass of gi_emitters.hlsl. Match its PHASE_ constants.
Emitter_Phase :: enum u32 {
	Jobs,
	Gather,
	Build,
	Scan,
}

// Emitter_Job matches Emitter_Job in gi_emitters.hlsl: a ray's slot and primitive, its target, and the seed of its
// point.
Emitter_Job :: struct {
	slot:      u32,
	primitive: u32,
	target:    u32,
	seed:      u32,
}

// Emitter_Submesh matches Emitter_Submesh in gi_emitters.hlsl: a listed submesh this frame, its slot and mesh record,
// its primitives, its first triangle among the frame's listed ones, its range of the pool, and EMITTER_TWO_SIDED.
Emitter_Submesh :: struct {
	slot:            u32,
	mesh:            u32,
	first_primitive: u32,
	primitive_count: u32,
	first_triangle:  u32,
	radiance_base:   u32,
	flags:           u32,
	_:               u32,
}

EMITTER_TWO_SIDED :: 1

// Emitter_Table_Header matches the emitter table's header in gi_emitter_samples.hlsli: the listed submeshes, their
// triangles, the byte offset of hit_emitters, which gives each hit table record's listed submesh, or ~0, the records,
// and the byte offset of hit_transmitters, which gives each record's first cell of the pool's transmittance, or ~0.
Emitter_Table_Header :: struct {
	count:            u32,
	triangles:        u32,
	hit_emitters:     u32,
	entries:          u32,
	hit_transmitters: u32,
	_:                [3]u32,
}

// Emitter_Push matches Emitter_Push in gi_emitters.hlsl.
@(private = "file")
Emitter_Push :: struct {
	phase:                u32,
	count:                u32,
	jobs:                 u32,
	jobs_offset:          u32,
	table:                u32,
	table_offset:         u32,
	hits:                 u32,
	surfaces:             u32,
	pool:                 u32,
	results:              u32,
	samples:              u32,
	hit_instances:        u32,
	hit_instances_offset: u32,
}

#assert(
	size_of(Emitter_Job) == 16 &&
	size_of(Emitter_Submesh) == 32 &&
	size_of(Emitter_Table_Header) == 32,
)

// Emitter_Key is a submesh that stays the same from frame to frame: its entity's, by its index in the mesh.
Emitter_Key :: struct {
	entity:  ecs.Entity,
	submesh: u32,
}

// Emitter_Signature is what a listed submesh was listed as: its material's pipeline and its primitives. A submesh whose
// signature changes is unlisted, and the discovery lists it again if it still emits.
Emitter_Signature :: struct {
	pipeline:        u32,
	first_primitive: u32,
	primitive_count: u32,
}

// Emitter is a listed submesh: its signature, its range of the pool, how many of its triangles the refresh reached at
// least once, so that a new one's come first, and the scans in a row that found it dark.
Emitter :: struct {
	signature: Emitter_Signature,
	two_sided: bool,
	base:      u32,
	filled:    u32,
	dark:      u32,
}

// Emitter_Probe is a submesh that a discovery scan read: its key and its signature, whose EMITTER_DISCOVERY_SAMPLES
// results follow in the scan's order.
Emitter_Probe :: struct {
	key:       Emitter_Key,
	signature: Emitter_Signature,
	two_sided: bool,
}

// Emitter_Scan is a readback slot's scan: its submeshes, which a frame's commit gives it once its copy has executed.
// A slot without one is free.
Emitter_Scan :: struct {
	probes: [EMITTER_DISCOVERY_SUBMESHES]Emitter_Probe,
	count:  int,
}

// Pool_Range is a free range of the radiance pool's cells.
Pool_Range :: struct {
	first: u32,
	count: u32,
}

// Gi_Emitters is the emitters' state between frames, in Gi_Passes: the pipeline, the radiance pool and the buffers of
// the batch, the readback slots and their scans, the listed submeshes, the pool's free ranges, and the cursors of the
// discovery and the refresh.
Gi_Emitters :: struct {
	pipeline:     Shader_Pipeline,
	pool:         gpu.Buffer,
	hits:         gpu.Buffer,
	surfaces:     gpu.Buffer,
	results:      gpu.Buffer,
	samples:      gpu.Buffer,
	readbacks:    [READBACK_COPIES]gpu.Buffer,
	scans:        [READBACK_COPIES]Maybe(Emitter_Scan),
	listed:       map[Emitter_Key]Emitter,
	// The translucent submeshes, each with its range of the pool, as sync_transmitters keeps them.
	transmitters: map[Emitter_Key]Emitter,
	free:         [dynamic]Pool_Range,
	discovery:    u32,
	refresh:      u32,
	transmit:     u32,
}

// Gi_Emitter_Frame is one frame's emitters, in frame memory: the table and the jobs in the upload ring, the frame's
// listed submeshes and their triangles, the buffers in the graph, and what the frame's commit gives the state.
Gi_Emitter_Frame :: struct {
	frame:           ^Frame,
	table:           gpu.Upload,
	jobs:            gpu.Upload,
	job_count:       u32,
	discovery_count: u32,
	triangles:       u32,
	pool:            Buffer,
	hits:            Buffer,
	surfaces:        Buffer,
	results:         Buffer,
	samples:         Buffer,
	readback:        Buffer,
	slot:            int,
	scan:            Emitter_Scan,
	fills:           []Emitter_Fill,
	next_discovery:  u32,
	next_refresh:    u32,
	next_transmit:   u32,
}

// Emitter_Fill is how far the frame's refresh reached into a listed submesh's triangles.
Emitter_Fill :: struct {
	key:    Emitter_Key,
	filled: u32,
}

gi_emitters_init :: proc(e: ^Gi_Emitters) {
	e.pipeline = shader_pipeline(GI_EMITTERS_SHADER)
}

gi_emitters_destroy :: proc(e: ^Gi_Emitters, platform: ^core.Platform_API) {
	destroy_shader_pipeline(&e.pipeline, platform)
	for b in ([]gpu.Buffer{e.pool, e.hits, e.surfaces, e.results, e.samples}) {
		platform.gpu_destroy_buffer(b)
	}
	for b in e.readbacks {
		platform.gpu_destroy_buffer(b)
	}
	delete(e.listed)
	delete(e.transmitters)
	delete(e.free)
	e^ = {
		pipeline = e.pipeline,
	}
}

// sync_gi_emitter_pipelines makes the emitters' pipeline, with Ray_Query only.
@(private)
sync_gi_emitter_pipelines :: proc(r: ^Renderer, force: bool) {
	if !r.caps.ray_query {
		return
	}
	sync_compute_pipeline(
		&r.gi.emitters.pipeline,
		r.platform,
		r.residency.assets,
		{label = "gi emitters"},
		force,
	)
}

// ensure_emitter_storage makes the buffers the first time. It has all of them or none.
@(private = "file")
ensure_emitter_storage :: proc(e: ^Gi_Emitters, platform: ^core.Platform_API) -> bool {
	if e.pool != {} {
		return true
	}
	storage :: proc(platform: ^core.Platform_API, size: int, label: string) -> gpu.Buffer {
		return platform.gpu_create_buffer(
			{size = u32(size), usage = {.Storage}, label = label},
			nil,
		)
	}
	e.pool = storage(platform, MAX_EMITTER_TRIANGLES * 16, "gi emitter pool")
	e.hits = storage(platform, MAX_EMITTER_JOBS * size_of(Hit_Record), "gi emitter hits")
	e.surfaces = storage(platform, MAX_EMITTER_JOBS * size_of(Hit_Surface), "gi emitter surfaces")
	e.results = storage(platform, EMITTER_DISCOVERY_JOBS * 4, "gi emitter results")
	e.samples = storage(platform, EMITTER_SAMPLES_SIZE, "gi emitter samples")
	ok := e.pool != {} && e.hits != {} && e.surfaces != {} && e.results != {} && e.samples != {}
	for &b in e.readbacks {
		b = platform.gpu_create_buffer(
			{
				size = EMITTER_DISCOVERY_JOBS * 4,
				usage = {.Readback},
				label = "gi emitter readback",
			},
			nil,
		)
		ok &&= b != {}
	}
	if !ok {
		for b in ([]gpu.Buffer{e.pool, e.hits, e.surfaces, e.results, e.samples}) {
			platform.gpu_destroy_buffer(b)
		}
		for b in e.readbacks {
			platform.gpu_destroy_buffer(b)
		}
		e.pool, e.hits, e.surfaces, e.results, e.samples, e.readbacks = {}, {}, {}, {}, {}, {}
		return false
	}
	clear(&e.free)
	append(&e.free, Pool_Range{0, MAX_EMITTER_TRIANGLES})
	return true
}

// pool_allocate takes a range of count cells, the first that fits, or false.
pool_allocate :: proc(free: ^[dynamic]Pool_Range, count: u32) -> (first: u32, ok: bool) {
	for &r, i in free {
		if r.count >= count {
			first = r.first
			r.first += count
			r.count -= count
			if r.count == 0 {
				ordered_remove(free, i)
			}
			return first, true
		}
	}
	return 0, false
}

// pool_free gives a range back, merged with the free ranges beside it.
pool_free :: proc(free: ^[dynamic]Pool_Range, first, count: u32) {
	at := len(free)
	for r, i in free {
		if r.first > first {
			at = i
			break
		}
	}
	inject_at(free, at, Pool_Range{first, count})
	if at + 1 < len(free) && free[at].first + free[at].count == free[at + 1].first {
		free[at].count += free[at + 1].count
		ordered_remove(free, at + 1)
	}
	if at > 0 && free[at - 1].first + free[at - 1].count == free[at].first {
		free[at - 1].count += free[at].count
		ordered_remove(free, at)
	}
}

// Emitter_Event is what happens to a submesh: a scan that read its points, or its absence from a frame, or a
// signature that changed.
Emitter_Event :: union #no_nil {
	Emitter_Scanned,
	Emitter_Gone,
}

// Emitter_Scanned is a scan's points of a submesh: the brightest's emitted luminance, or none when no point was
// evaluated.
Emitter_Scanned :: struct {
	probe:     Emitter_Probe,
	luminance: Maybe(f32),
}

Emitter_Gone :: struct {
	key: Emitter_Key,
}

// change_emitter is the one writer of the listed submeshes (see docs/overview/conventions.md#state-with-a-lifecycle).
// A scan that finds a point bright lists a submesh that is not listed, when the pool and the list have room, and resets
// a listed one's dark scans; one that finds every point dark counts a dark scan, and the last of EMITTER_DARK_SCANS
// unlists it. A scan of an old signature changes nothing. A submesh that goes is unlisted, and its range freed.
change_emitter :: proc(e: ^Gi_Emitters, event: Emitter_Event) {
	switch ev in event {
	case Emitter_Scanned:
		luminance, evaluated := ev.luminance.?
		if !evaluated {
			return
		}
		bright := luminance >= EMITTER_MIN_LUMINANCE
		if listed, found := &e.listed[ev.probe.key]; found {
			if listed.signature != ev.probe.signature {
				return
			}
			listed.dark = bright ? 0 : listed.dark + 1
			if listed.dark >= EMITTER_DARK_SCANS {
				change_emitter(e, Emitter_Gone{ev.probe.key})
			}
			return
		}
		count := ev.probe.signature.primitive_count
		if !bright ||
		   len(e.listed) >= MAX_EMITTER_SUBMESHES ||
		   count == 0 ||
		   count > MAX_EMITTER_SUBMESH_TRIANGLES {
			return
		}
		base, ok := pool_allocate(&e.free, count)
		if !ok {
			return
		}
		e.listed[ev.probe.key] = {
			signature = ev.probe.signature,
			two_sided = ev.probe.two_sided,
			base      = base,
		}
	case Emitter_Gone:
		listed, found := e.listed[ev.key]
		if !found {
			return
		}
		pool_free(&e.free, listed.base, listed.signature.primitive_count)
		delete_key(&e.listed, ev.key)
	}
}

// emitter_luminance is the brightest of a submesh's scanned points, from their results: negative where hit shading
// did not evaluate the material, as the fallback's.
emitter_luminance :: proc(results: []f32) -> Maybe(f32) {
	brightest: Maybe(f32)
	for r in results {
		if r < 0 {
			continue
		}
		if b, ok := brightest.?; !ok || r > b {
			brightest = r
		}
	}
	return brightest
}

// take_gi_emitter_scans reads each scan that has come back, and frees its slot.
@(private)
take_gi_emitter_scans :: proc(r: ^Renderer) {
	e := &r.gi.emitters
	for &scan, slot in e.scans {
		s, copied := scan.?
		if !copied {
			continue
		}
		data, ok := r.platform.gpu_read_buffer(e.readbacks[slot])
		if !ok || len(data) < s.count * EMITTER_DISCOVERY_SAMPLES * 4 {
			continue
		}
		results := ([^]f32)(raw_data(data))[:s.count * EMITTER_DISCOVERY_SAMPLES]
		for probe, i in s.probes[:s.count] {
			at := i * EMITTER_DISCOVERY_SAMPLES
			change_emitter(
				e,
				Emitter_Scanned {
					probe,
					emitter_luminance(results[at:at + EMITTER_DISCOVERY_SAMPLES]),
				},
			)
		}
		scan = nil
	}
}

// emitter_signature is a hit table record's signature.
emitter_signature :: proc(key: Hit_Entry_Key, submesh: Hit_Submesh) -> Emitter_Signature {
	return {
		pipeline = key.pipeline,
		first_primitive = submesh.first_primitive,
		primitive_count = submesh.primitive_count,
	}
}

// Emitter_Plan is what a frame's emitters do, as plan_gi_emitters gives it from the state and the frame's hit table:
// the listed submeshes this frame, by their records, with hit_emitters for each record, the jobs, the scan's
// submeshes, how far the refresh reaches into each new submesh, and the cursors after.
Emitter_Plan :: struct {
	submeshes:        []Emitter_Submesh,
	hit_emitters:     []u32,
	triangles:        u32,
	jobs:             []Emitter_Job,
	discovery:        u32,
	scan:             Emitter_Scan,
	fills:            []Emitter_Fill,
	next_discovery:   u32,
	next_refresh:     u32,
	// Each record's first cell of the pool's transmittance, or ~0, and the cursor of the transmittance's refresh after.
	hit_transmitters: []u32,
	next_transmit:    u32,
}

// plan_gi_emitters unlists the listed submeshes that the frame's hit table no longer has as they were, and plans the
// frame: the listed submeshes that it has, the refresh's jobs, the new submeshes' triangles first, then the others' in
// turn from the cursor, and, when scan is true, the discovery's jobs over the records that hit shading evaluates, in
// turn from the cursor.
plan_gi_emitters :: proc(
	e: ^Gi_Emitters,
	instances: []Hit_Instance,
	submeshes: []Hit_Submesh,
	keys: []Hit_Entry_Key,
	scan: bool,
	frame: u32,
	allocator := context.allocator,
) -> (
	plan: Emitter_Plan,
) {
	// The records of the frame, by their keys, and the slot of each.
	slots := make([]u32, len(submeshes), allocator)
	for instance, slot in instances {
		for k in instance.first ..< instance.first + instance.count {
			if int(k) < len(slots) {
				slots[k] = u32(slot)
			}
		}
	}
	records := make(map[Emitter_Key]int, len(keys), allocator)
	for key, i in keys {
		if key.shaded {
			records[{key.entity, key.submesh}] = i
		}
	}
	gone := make([dynamic]Emitter_Key, allocator)
	for key, listed in e.listed {
		i, found := records[key]
		if !found || emitter_signature(keys[i], submeshes[i]) != listed.signature {
			append(&gone, key)
		}
	}
	for key in gone {
		change_emitter(e, Emitter_Gone{key})
	}

	// The listed submeshes in the records' order, so the frame's triangles keep an order while nothing changes.
	listed := make([dynamic]Emitter_Submesh, allocator)
	listed_keys := make([dynamic]Emitter_Key, allocator)
	plan.hit_emitters = make([]u32, len(keys), allocator)
	for key, i in keys {
		plan.hit_emitters[i] = ~u32(0)
		if !key.shaded {
			continue
		}
		k := Emitter_Key{key.entity, key.submesh}
		l, found := e.listed[k]
		if !found {
			continue
		}
		plan.hit_emitters[i] = u32(len(listed))
		append(
			&listed,
			Emitter_Submesh {
				slot = slots[i],
				mesh = instances[slots[i]].mesh,
				first_primitive = submeshes[i].first_primitive,
				primitive_count = submeshes[i].primitive_count,
				first_triangle = plan.triangles,
				radiance_base = l.base,
				flags = l.two_sided ? EMITTER_TWO_SIDED : 0,
			},
		)
		append(&listed_keys, k)
		plan.triangles += submeshes[i].primitive_count
	}
	plan.submeshes = listed[:]
	transmitted := sync_transmitters(e, submeshes, keys, slots, allocator)
	plan.hit_transmitters = make([]u32, len(keys), allocator)
	for &cell in plan.hit_transmitters {
		cell = ~u32(0)
	}
	transmitted_triangles: u32
	for t in transmitted {
		plan.hit_transmitters[t.entry] = t.base
		transmitted_triangles += t.count
	}

	jobs := make([dynamic]Emitter_Job, allocator)
	seed := frame * 0x9e3779b9
	// The discovery: EMITTER_DISCOVERY_SAMPLES points of each of the next submeshes that hit shading evaluates.
	if scan {
		candidates := make([dynamic]int, allocator)
		for key, i in keys {
			count := submeshes[i].primitive_count
			if key.shaded && count > 0 && count <= MAX_EMITTER_SUBMESH_TRIANGLES {
				append(&candidates, i)
			}
		}
		n := min(len(candidates), EMITTER_DISCOVERY_SUBMESHES)
		start := len(candidates) > 0 ? int(e.discovery) % len(candidates) : 0
		for j in 0 ..< n {
			i := candidates[(start + j) % len(candidates)]
			key, sub := keys[i], submeshes[i]
			plan.scan.probes[j] = {
				key       = {key.entity, key.submesh},
				signature = emitter_signature(key, sub),
				two_sided = key.two_sided,
			}
			for s in 0 ..< EMITTER_DISCOVERY_SAMPLES {
				h := split_hash(seed ~ u32(j * EMITTER_DISCOVERY_SAMPLES + s))
				append(
					&jobs,
					Emitter_Job {
						slot = slots[i],
						primitive = sub.first_primitive + h % sub.primitive_count,
						target = EMITTER_DISCOVERY | u32(len(jobs)),
						seed = split_hash(h),
					},
				)
			}
		}
		plan.scan.count = n
		plan.discovery = u32(len(jobs))
		plan.next_discovery = len(candidates) > 0 ? u32((start + n) % len(candidates)) : 0
	} else {
		plan.next_discovery = e.discovery
	}

	// The refresh: the new submeshes' triangles first, then every listed triangle in turn.
	budget := EMITTER_REFRESH_JOBS
	fills := make([dynamic]Emitter_Fill, allocator)
	for sub, n in plan.submeshes {
		l := e.listed[listed_keys[n]]
		if l.filled >= sub.primitive_count || budget == 0 {
			continue
		}
		take := min(sub.primitive_count - l.filled, u32(budget))
		for t in l.filled ..< l.filled + take {
			append(
				&jobs,
				Emitter_Job {
					slot = sub.slot,
					primitive = sub.first_primitive + t,
					target = sub.radiance_base + t,
					seed = split_hash(seed ~ (sub.radiance_base + t) ~ 0x5bd1e995),
				},
			)
		}
		budget -= int(take)
		append(&fills, Emitter_Fill{listed_keys[n], l.filled + take})
	}
	plan.fills = fills[:]
	plan.next_refresh = e.refresh
	if plan.triangles > 0 && budget > 0 {
		cursor := e.refresh % plan.triangles
		n := min(u32(budget), plan.triangles)
		for k in 0 ..< n {
			t := (cursor + k) % plan.triangles
			// The listed submesh that holds triangle t.
			at, _ := slice.binary_search_by(
				plan.submeshes,
				t,
				proc(s: Emitter_Submesh, t: u32) -> slice.Ordering {
					return slice.cmp(s.first_triangle, t)
				},
			)
			if at >= len(plan.submeshes) || plan.submeshes[at].first_triangle > t {
				at -= 1
			}
			sub := plan.submeshes[at]
			local := t - sub.first_triangle
			append(
				&jobs,
				Emitter_Job {
					slot = sub.slot,
					primitive = sub.first_primitive + local,
					target = sub.radiance_base + local,
					seed = split_hash(seed ~ t),
				},
			)
		}
		plan.next_refresh = (cursor + n) % plan.triangles
	}
	// The transmittance's refresh: the translucent triangles in turn. A cell that no ray has reached lets all the
	// light through, as a translucent submesh without a cell does.
	plan.next_transmit = e.transmit
	if transmitted_triangles > 0 {
		cursor := e.transmit % transmitted_triangles
		n := min(u32(EMITTER_TRANSMIT_JOBS), transmitted_triangles)
		at, first := 0, u32(0)
		for k in 0 ..< n {
			t := (cursor + k) % transmitted_triangles
			if k == 0 || t == 0 {
				at, first = 0, 0
				for first + transmitted[at].count <= t {
					first += transmitted[at].count
					at += 1
				}
			}
			for t >= first + transmitted[at].count {
				first += transmitted[at].count
				at += 1
			}
			sub := transmitted[at]
			local := t - first
			append(
				&jobs,
				Emitter_Job {
					slot = sub.slot,
					primitive = sub.first_primitive + local,
					target = sub.base + local,
					seed = split_hash(seed ~ t ~ 0x27d4eb2f),
				},
			)
		}
		plan.next_transmit = (cursor + n) % transmitted_triangles
	}
	plan.jobs = jobs[:]
	return
}

// Transmitted is a translucent submesh of the frame with its range of the pool: its record, slot, primitives and first
// cell.
Transmitted :: struct {
	entry:           int,
	slot:            u32,
	first_primitive: u32,
	count:           u32,
	base:            u32,
}

// sync_transmitters is the one writer of the translucent submeshes' ranges of the pool (see
// docs/overview/conventions.md#state-with-a-lifecycle): it frees the range of each that the frame's hit table no longer
// has as it was, gives a range to each new one while the pool has room, and gives the frame's in the records' order.
sync_transmitters :: proc(
	e: ^Gi_Emitters,
	submeshes: []Hit_Submesh,
	keys: []Hit_Entry_Key,
	slots: []u32,
	allocator := context.allocator,
) -> []Transmitted {
	records := make(map[Emitter_Key]int, len(keys), allocator)
	for key, i in keys {
		count := submeshes[i].primitive_count
		if key.translucent && count > 0 && count <= MAX_EMITTER_SUBMESH_TRIANGLES {
			records[{key.entity, key.submesh}] = i
		}
	}
	gone := make([dynamic]Emitter_Key, allocator)
	for key, t in e.transmitters {
		i, found := records[key]
		if !found || emitter_signature(keys[i], submeshes[i]) != t.signature {
			append(&gone, key)
		}
	}
	for key in gone {
		t := e.transmitters[key]
		pool_free(&e.free, t.base, t.signature.primitive_count)
		delete_key(&e.transmitters, key)
	}
	frame := make([dynamic]Transmitted, allocator)
	for key, i in keys {
		k := Emitter_Key{key.entity, key.submesh}
		if _, present := records[k]; !present {
			continue
		}
		t, found := e.transmitters[k]
		if !found {
			signature := emitter_signature(key, submeshes[i])
			base, ok := pool_allocate(&e.free, signature.primitive_count)
			if !ok {
				continue
			}
			t = {
				signature = signature,
				base      = base,
			}
			e.transmitters[k] = t
		}
		append(
			&frame,
			Transmitted {
				entry = i,
				slot = slots[i],
				first_primitive = submeshes[i].first_primitive,
				count = submeshes[i].primitive_count,
				base = t.base,
			},
		)
	}
	return frame[:]
}

// gi_emitters_wanted is whether the frame's hits sample the emitters: on the frame's own view, with the ray scene and
// its hit table, when the world probes or the traced reflections light hits this frame.
@(private = "file")
gi_emitters_wanted :: proc(f: ^Frame) -> bool {
	r := f.renderer
	if f.extra || !r.caps.ray_query || !pipeline_ready(r.platform, &r.gi.emitters.pipeline) {
		return false
	}
	probes := f.gi != nil && f.gi.settings.technique == .Split_Cascades && gi_probes_ready(r)
	traced := f.ssr != nil && f.ssr.traced != nil
	return (probes || traced) && hit_shading_ready(f) && len(f.scene_frame.hit_keys) > 0
}

// add_gi_emitter_passes runs the frame's emitters before the passes that light hits: the jobs' rays, their hit
// shading, the gather into the pool and the scan's results, their copy into a readback slot, the build of the listed
// triangles and the scan of their powers. It gives the frame's emitters, which the hits' light takes, or nil without
// them this frame.
@(private)
add_gi_emitter_passes :: proc(f: ^Frame) -> ^Gi_Emitter_Frame {
	r := f.renderer
	platform := r.platform
	if !gi_emitters_wanted(f) {
		return nil
	}
	e := &r.gi.emitters
	if !ensure_emitter_storage(e, platform) {
		return nil
	}
	take_gi_emitter_scans(r)
	slot := -1
	for scan, i in e.scans {
		if _, copied := scan.?; !copied {
			slot = i
			break
		}
	}
	sf := f.scene_frame
	instances := ([^]Hit_Instance)(raw_data(sf.hit_instances.data))[:sf.hit_instance_count]
	submeshes := ([^]Hit_Submesh)(raw_data(sf.hit_submeshes.data))[:len(sf.hit_keys)]
	allocator := platform.frame_allocator
	plan := plan_gi_emitters(
		e,
		instances,
		submeshes,
		sf.hit_keys,
		slot >= 0,
		u32(f.state.frames),
		allocator,
	)

	header := Emitter_Table_Header {
		count        = u32(len(plan.submeshes)),
		triangles    = plan.triangles,
		hit_emitters = size_of(
			Emitter_Table_Header,
		) + u32(len(plan.submeshes)) * size_of(Emitter_Submesh),
		entries      = u32(len(plan.hit_emitters)),
	}
	header.hit_transmitters = header.hit_emitters + header.entries * 4
	table_size := int(header.hit_transmitters) + len(plan.hit_transmitters) * 4
	table, table_ok := platform.gpu_upload(table_size, 16)
	jobs, jobs_ok := platform.gpu_upload(max(len(plan.jobs), 1) * size_of(Emitter_Job), 16)
	if !table_ok || !jobs_ok {
		return nil
	}
	reservation: Maybe(Hit_Reservation)
	if len(plan.jobs) > 0 {
		reservation = reserve_hit_shading(f, u32(len(plan.jobs)))
		if reservation == nil {
			return nil
		}
	}
	(^Emitter_Table_Header)(raw_data(table.data))^ = header
	copy(table.data[size_of(Emitter_Table_Header):], slice.to_bytes(plan.submeshes))
	copy(table.data[header.hit_emitters:], slice.to_bytes(plan.hit_emitters))
	copy(table.data[header.hit_transmitters:], slice.to_bytes(plan.hit_transmitters))
	copy(jobs.data, slice.to_bytes(plan.jobs))

	g := f.graph
	ef := new(Gi_Emitter_Frame, allocator)
	ef^ = {
		frame           = f,
		table           = table,
		jobs            = jobs,
		job_count       = u32(len(plan.jobs)),
		discovery_count = plan.discovery,
		triangles       = plan.triangles,
		pool            = import_buffer(g, e.pool),
		hits            = import_buffer(g, e.hits),
		surfaces        = import_buffer(g, e.surfaces),
		results         = import_buffer(g, e.results),
		samples         = import_buffer(g, e.samples),
		slot            = plan.discovery > 0 ? slot : -1,
		scan            = plan.scan,
		fills           = plan.fills,
		next_discovery  = plan.next_discovery,
		next_refresh    = plan.next_refresh,
		next_transmit   = plan.next_transmit,
	}
	step :: proc(ef: ^Gi_Emitter_Frame, phase: Emitter_Phase) -> ^Emitter_Step {
		return new_clone(Emitter_Step{ef, phase}, ef.frame.renderer.platform.frame_allocator)
	}
	if res, reserved := reservation.?; reserved {
		p := add_compute_pass(
			g,
			"gi emitter jobs",
			run_emitter_pass,
			step(ef, .Jobs),
			queue = .Compute,
		)
		read(g, p, sf.instances)
		declare_skinned_reads(f, p)
		write(g, p, ef.hits)
		shaded := add_hit_shading(
			f,
			res,
			{hits = ef.hits, surfaces = ef.surfaces, count = ef.job_count},
			.Compute,
			"gi emitter",
			translucent = true,
		)
		p = add_compute_pass(
			g,
			"gi emitter gather",
			run_emitter_pass,
			step(ef, .Gather),
			queue = .Compute,
		)
		read(g, p, shaded.hits)
		read(g, p, shaded.surfaces)
		write(g, p, ef.pool)
		write(g, p, ef.results)
		if ef.slot >= 0 {
			ef.readback = import_buffer(g, e.readbacks[ef.slot])
			q := add_compute_pass(g, "copy gi emitter results", proc(ctx: ^Pass_Context) {
					ef := (^Gi_Emitter_Frame)(ctx.data)
					gpu.cmd_copy_buffer(
						ctx.cb,
						gpu_buffer(ctx.graph, ef.results),
						0,
						gpu_buffer(ctx.graph, ef.readback),
						0,
						ef.discovery_count * 4,
					)
				}, ef, queue = .Compute)
			copy_source(g, q, ef.results)
			copy_dest(g, q, ef.readback)
		}
	}
	if ef.triangles > 0 {
		p := add_compute_pass(
			g,
			"gi emitter build",
			run_emitter_pass,
			step(ef, .Build),
			queue = .Compute,
		)
		read(g, p, ef.pool)
		read(g, p, sf.instances)
		declare_skinned_reads(f, p)
		write(g, p, ef.samples)
		p = add_compute_pass(
			g,
			"gi emitter scan",
			run_emitter_pass,
			step(ef, .Scan),
			queue = .Compute,
		)
		write(g, p, ef.samples)
	}
	on_executed(g, commit_gi_emitters, ef)
	return ef
}

// commit_gi_emitters gives the state what the frame's executed work did: the cursors, the new submeshes' refreshed
// triangles, and the scan in its readback slot.
@(private = "file")
commit_gi_emitters :: proc(data: rawptr) {
	ef := (^Gi_Emitter_Frame)(data)
	e := &ef.frame.renderer.gi.emitters
	e.discovery, e.refresh, e.transmit = ef.next_discovery, ef.next_refresh, ef.next_transmit
	for fill in ef.fills {
		if listed, found := &e.listed[fill.key]; found {
			listed.filled = max(listed.filled, fill.filled)
		}
	}
	if ef.slot >= 0 {
		e.scans[ef.slot] = ef.scan
	}
}

@(private = "file")
Emitter_Step :: struct {
	emitters: ^Gi_Emitter_Frame,
	phase:    Emitter_Phase,
}

// run_emitter_pass dispatches a pass of the emitters: a thread for each job, or each listed triangle, or one group for
// the scan.
@(private = "file")
run_emitter_pass :: proc(ctx: ^Pass_Context) {
	step := (^Emitter_Step)(ctx.data)
	ef := step.emitters
	f := ef.frame
	sf := f.scene_frame
	g := ctx.graph
	hits := gpu_buffer(g, ef.hits)
	pool := gpu_buffer(g, ef.pool)
	samples := gpu_buffer(g, ef.samples)
	push := Emitter_Push {
		phase                = u32(step.phase),
		jobs                 = gpu.read_index(ef.jobs.buffer),
		jobs_offset          = ef.jobs.offset,
		table                = gpu.read_index(ef.table.buffer),
		table_offset         = ef.table.offset,
		hits                 = step.phase == .Jobs ? gpu.write_index(hits) : gpu.read_index(hits),
		surfaces             = gpu.read_index(gpu_buffer(g, ef.surfaces)),
		pool                 = step.phase == .Gather ? gpu.write_index(pool) : gpu.read_index(pool),
		results              = gpu.write_index(gpu_buffer(g, ef.results)),
		samples              = gpu.write_index(samples),
		hit_instances        = gpu.read_index(sf.hit_instances.buffer),
		hit_instances_offset = sf.hit_instances.offset,
	}
	groups: u32
	switch step.phase {
	case .Jobs, .Gather:
		push.count = ef.job_count
		groups = (ef.job_count + EMITTER_GROUP - 1) / EMITTER_GROUP
	case .Build:
		push.count = ef.triangles
		groups = (ef.triangles + EMITTER_GROUP - 1) / EMITTER_GROUP
	case .Scan:
		push.count = ef.triangles
		groups = 1
	}
	if groups == 0 {
		return
	}
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.gi.emitters.pipeline.pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, sf.view_constants[VIEW_CAMERA])
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, {groups, 1, 1})
}

// emitter_power is a triangle's share of the distribution: its emitted luminance times its area, twice for a
// two-sided one. The build pass computes it so; this is its mirror for the tests.
emitter_power :: proc(radiance: [3]f32, area: f32, two_sided: bool) -> f32 {
	luminance := linalg.dot(radiance, [3]f32{0.2126, 0.7152, 0.0722})
	return luminance * area * (two_sided ? 2 : 1)
}
