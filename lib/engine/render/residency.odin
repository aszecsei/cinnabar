package render

import "core:log"
import "core:mem"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"

// At most this many assets are resident at once: Sponza with its curtains, a USD stage, is about 250 meshes and textures,
// and Jungle Ruins about 1,200 with an instance set for each of its 778 point instancers (see
// docs/content/kinds/stages.md#limits).
MAX_RESIDENT :: 4096
// A resident mesh keeps at most this many submeshes. A mesh with more draws only these.
MAX_SUBMESHES :: 16
// An asset that cannot be made resident is tried again after this many frames.
RESIDENT_RETRY_FRAMES :: 60

// Resident_Mesh is a mesh asset's GPU buffers, and what drawing it needs from its blob. Its pointer is valid for the
// frame that it was given in. A paged mesh has no meshlet buffers: its meshlets are in the pool of pages. It has no
// positions, attributes or indices either until its level 0 is ready, which resident_level0 asks for.
Resident_Mesh :: struct {
	// Whether the mesh's meshlets and vertices are in pages, its id in the pool, and its level 0 (see mesh_pages.odin and
	// mesh_level0.odin).
	paged:             bool,
	pool_mesh:         u32,
	// Its range of the page table, for its mesh record.
	pages_first:       u32,
	page_count:        u32,
	level0:            Level0,
	// The frame of the last failure to assemble level 0, which was logged, or 0.
	level0_failed_at:  u64,
	positions:         gpu.Buffer,
	attributes:        gpu.Buffer,
	indices:           gpu.Buffer,
	// The meshlets of every level of detail, which the mesh shader path draws (see docs/rendering/assets.md#gpu-residency).
	meshlets:          gpu.Buffer,
	meshlet_vertices:  gpu.Buffer,
	meshlet_triangles: gpu.Buffer,
	// The trees over each level's groups of meshlets, which select meshlets walks (see
	// docs/rendering/gpu-scene.md#mesh-shader-path), for a mesh cooked with them.
	meshlet_nodes:     gpu.Buffer,
	// For a mesh cooked with a skin stream, each vertex's joints and weights, which skin_meshes.hlsl poses the vertices
	// by (see docs/rendering/gpu-scene.md#skinned-meshes).
	skin:              gpu.Buffer,
	// The impostor's atlas, for a mesh cooked with one, the side of its frames in texels, and how far it may be from the
	// mesh, in meters (see docs/rendering/gpu-scene.md#impostors).
	impostor:          gpu.Buffer,
	impostor_size:     u32,
	impostor_error:    f32,
	index_format:      gpu.Index_Format,
	index_count:       u32,
	vertex_count:      u32,
	attribute_stride:  u32,
	flags:             format.Mesh_Flags,
	bounds:            format.Mesh_Bounds,
	submesh_count:     u32,
	submeshes:         [MAX_SUBMESHES]Resident_Submesh,
	submesh_bounds:    [MAX_SUBMESHES]format.Mesh_Bounds,
	// For instanced draws on the mesh shader path (see docs/rendering/gpu-scene.md#instanced-meshes): each submesh's
	// first meshlet of each level bucket, from its first, at its last level for a bucket past it; and for each level
	// below the last bucket's, the largest parent error of the mesh's meshlets there and how far their parents'
	// spheres reach from the mesh's center, F32_MAX past the mesh's last level.
	level_first:       [MAX_SUBMESHES][INSTANCE_LEVEL_BUCKETS]u32,
	levels:            [INSTANCE_LEVEL_BUCKETS][2]f32,
	// With Ray_Query, the bottom-level acceleration structure of every triangle, which the renderer builds the first
	// frame after the mesh is ready (see docs/rendering/lighting-and-shadows.md#shadows).
	accel:             gpu.Accel_Struct,
	accel_built:       bool,
}

// Resident_Submesh is a submesh's ranges of its mesh's indices, meshlets and meshlet nodes, the first root_count of
// which are its levels' roots.
Resident_Submesh :: struct {
	first_index:   u32,
	index_count:   u32,
	first_meshlet: u32,
	meshlet_count: u32,
	first_node:    u32,
	node_count:    u32,
	root_count:    u32,
}

// Resident_Instance_Set is an instance set asset's GPU buffers, its instances and its cells, and what culling them
// needs from its blob (see docs/rendering/gpu-scene.md#instanced-meshes).
Resident_Instance_Set :: struct {
	instances:  gpu.Buffer,
	cells:      gpu.Buffer,
	count:      u32,
	cell_count: u32,
}

// Resident_Texture is a texture asset's GPU texture.
Resident_Texture :: struct {
	texture:   gpu.Texture,
	pixel_format: gpu.Format,
	size:      [2]u32,
	mip_count: u32,
	usage:     format.Texture_Usage,
	// What its layers are, and how many. A shader must read it through the type of its dimension.
	dimension:   format.Texture_Dimension,
	layer_count: u32,
}

// Residency gives the GPU resources of the texture and mesh assets that the renderer draws, by GUID (see
// docs/rendering/assets.md#gpu-residency). It lives in Game_State and holds handles only, so a code reload keeps it.
Residency :: struct {
	platform: ^core.Platform_API,
	assets:   ^asset.Assets,
	entries:  [MAX_RESIDENT]Resident_Entry,
	count:    int,
	// Each entry's index, by its GUID and kind.
	index:    map[Resident_Key]int,
	frame:    u64,
	// Whether meshes get acceleration structures, which the renderer sets the first frame that traces (see
	// residency_enable_accels).
	accels:   bool,
	// What this asks for is for a thumbnail, not the world, so it can go when the thumbnails are done.
	baking:   bool,
	// The pages of the paged meshes that are resident (see mesh_pages.odin).
	pool:     Mesh_Pool,
}

@(private)
Resident_Key :: struct {
	guid: format.Guid,
	kind: format.Asset_Kind,
}

@(private)
Resident_Entry :: struct {
	guid:          format.Guid,
	kind:          format.Asset_Kind,
	// The asset, once loaded. Every source keeps it, so a live mesh that is let go streams its asset's blob again.
	handle:        asset.Handle,
	// The resources that draw, from the blob of version, once ready.
	current:       Resident_Resources,
	version:       u32,
	ready:         bool,
	// What the resources come from, and what streams in to replace current. Only change writes them.
	source:        Resident_Source,
	stream:        Maybe(Resident_Stream),
	// The frame of the last failure, which was logged, or 0.
	failed_at:     u64,
	// This version of a texture was read as another dimension, which was logged.
	wrong_dimension_logged: bool,
	// Who has asked for it: a thumbnail, or anything else, which keeps it.
	baked:         bool,
	world:         bool,
}

@(private)
Resident_Resources :: struct {
	mesh:    Resident_Mesh,
	texture: Resident_Texture,
	set:     Resident_Instance_Set,
}

// Resident_Source is what an entry's resources come from.
@(private)
Resident_Source :: union #no_nil {
	Asset_Source,
	Live_Source,
	Released_Source,
}

// Asset_Source is the asset's blob.
@(private)
Asset_Source :: struct {}

// Live_Source is a live mesh: the editor's unsaved mesh, streamed from memory in place of the asset's blob (see
// set_live). next is the newest blob that arrived while one streamed, in the heap, which streams when that one is in.
@(private)
Live_Source :: struct {
	next: []byte,
}

// Released_Source is a live mesh that was let go. Its buffers draw until the asset's blob is in, whatever its version,
// and go if the asset's blob cannot stream, as what the editor gave up must not stay on screen.
@(private)
Released_Source :: struct {}

// Resident_Stream is new resources that stream in, from the blob of version, which replace current when their
// transfers are done, so the old version draws until then.
@(private)
Resident_Stream :: struct {
	pending:        Resident_Resources,
	version:        u32,
	// A mesh's seven streams, its impostor and its skin, a texture's one, or an instance set's two.
	transfers:      [9]gpu.Transfer,
	transfer_count: int,
	// It streams in over a live mesh that was let go, which must not go on drawing if this does not come in.
	released:       bool,
}

// Resident_Event is what changes an entry's source or stream, which change applies.
@(private = "file")
Resident_Event :: union #no_nil {
	Event_Live_Blob,
	Event_Let_Go,
	Event_Landed,
	Event_Stream_Failed,
	Event_Stream_Superseded,
	Event_Asset_Streaming,
	Event_Asset_Failed,
}

// The editor sent a live mesh's blob.
@(private = "file")
Event_Live_Blob :: struct {
	blob: []byte,
}

// The editor let the live mesh go.
@(private = "file")
Event_Let_Go :: struct {}

// The stream's transfers are done.
@(private = "file")
Event_Landed :: struct {}

// What streams cannot come in: a page of a paged mesh's roots was not what its table said.
@(private = "file")
Event_Stream_Failed :: struct {
	reason: string,
}

// The asset's blob was swapped while what streams was still coming in from the blob before it, which cannot finish: a
// paged mesh's root pages are in the head that went.
@(private = "file")
Event_Stream_Superseded :: struct {}

// The asset's blob started to stream.
@(private = "file")
Event_Asset_Streaming :: struct {
	stream: Resident_Stream,
}

// The asset's blob could not stream.
@(private = "file")
Event_Asset_Failed :: struct {
	reason: string,
}

residency_init :: proc(r: ^Residency, platform: ^core.Platform_API, assets: ^asset.Assets) {
	// The table is too large for a temporary on the stack, so it is zeroed in place.
	mem.zero_item(r)
	r.platform, r.assets = platform, assets
	r.index = make(map[Resident_Key]int, platform.heap_allocator)
	mesh_pool_init(&r.pool, platform)
}

// residency_reload keeps every resident asset after a code reload.
residency_reload :: proc(r: ^Residency, platform: ^core.Platform_API) {
	r.platform = platform
}

// residency_destroy destroys every resident resource. Call it from the game's shutdown.
residency_destroy :: proc(r: ^Residency) {
	for &e in r.entries[:r.count] {
		destroy_resources(r, e.kind, &e.current)
		if s, streaming := &e.stream.(Resident_Stream); streaming {
			destroy_resources(r, e.kind, &s.pending)
		}
		if live, is_live := &e.source.(Live_Source); is_live {
			free_next(r, &live.next)
		}
	}
	r.count = 0
	delete(r.index)
	mesh_pool_destroy(&r.pool, r.platform)
}

// residency_set_mesh_pool sets the budget of the pool of mesh pages, in MiB. The pool is made again at its new size at
// the next update, and every page streams in again, the roots first.
residency_set_mesh_pool :: proc(r: ^Residency, megabytes: u32) {
	r.pool.wanted_slots = mesh_pool_slots(megabytes)
}

// mesh_stream_stats is what the pool of mesh pages holds and what it waits for.
mesh_stream_stats :: proc(r: ^Residency) -> Mesh_Stream_Stats {
	return r.pool.stats
}

// resident_pin keeps every page of a paged mesh resident for this frame, and asks for the ones that are not. What draws
// a mesh's meshlets without the selection, which tests every one, pins it: instanced meshes and the view model.
resident_pin :: proc(r: ^Residency, m: ^Resident_Mesh) {
	if m.paged {
		mesh_pool_pin(&r.pool, m.pool_mesh)
	}
}

// residency_update starts a frame: it swaps in the resources whose transfers are done, and streams a new version of
// each asset whose blob asset.poll swapped. Call it once a frame, before drawing.
residency_update :: proc(r: ^Residency) {
	r.frame += 1
	mesh_pool_update(&r.pool, r.platform, r.assets)
	for &e in r.entries[:r.count] {
		// A paged mesh's level 0 comes in over some frames, for what asked for it, and for the ray scene.
		if e.kind == .Mesh && e.ready && e.current.mesh.paged {
			if r.accels {
				resident_level0(r, &e.current.mesh)
			}
			advance_level0(r, &e.current.mesh)
		}
		if s, streaming := &e.stream.(Resident_Stream); streaming {
			done := true
			for t in s.transfers[:s.transfer_count] {
				done &&= r.platform.gpu_transfer_done(t)
			}
			// A paged mesh is in when its roots are in the pool.
			superseded := false
			if e.kind == .Mesh && s.pending.mesh.paged {
				if mesh_pool_failed(&r.pool, s.pending.mesh.pool_mesh) {
					change(r, &e, Event_Stream_Failed{"has a root page that is not what its table names"})
					continue
				}
				done &&= mesh_pool_ready(&r.pool, s.pending.mesh.pool_mesh)
				// Its roots come from the head of the version that it streams, which a newer blob has replaced.
				superseded = !done && e.handle != {} && asset.version(r.assets, e.handle) != s.version
			}
			if done {
				change(r, &e, Event_Landed{})
			}
			if !superseded {
				continue
			}
			// The newer version streams below, in this frame.
			change(r, &e, Event_Stream_Superseded{})
		}
		// A live mesh draws from memory, whatever the asset's blob does.
		switch _ in e.source {
		case Live_Source:
		case Released_Source:
			// The asset's blob streams again, whatever its version. With no asset to load, the buffers go now, not when
			// something next draws the mesh.
			start_streaming(r, &e)
		case Asset_Source:
			// A failed version keeps its number, so only a newer blob tries again.
			if e.handle != {} && asset.version(r.assets, e.handle) != e.version {
				start_streaming(r, &e)
			}
		}
	}
}

// resident_mesh gives a mesh asset's resources, and whether they are ready. The first call loads the asset and
// streams its data. Until it is ready, draw nothing.
resident_mesh :: proc(r: ^Residency, guid: format.Guid) -> (mesh: ^Resident_Mesh, ready: bool) {
	e := entry(r, guid, .Mesh) or_return
	// A paged mesh draws nothing while the pool of pages was made again and the GPU's table is still the old pool's.
	return &e.current.mesh, e.ready && (!e.current.mesh.paged || mesh_pool_drawable(&r.pool))
}

// resident_whole_mesh gives a mesh asset's resources as resident_mesh does, for what draws its vertices by index: it is
// ready when the mesh's positions, attributes and indices are resident too, which a paged mesh's are some frames after
// the first call (see resident_level0).
resident_whole_mesh :: proc(r: ^Residency, guid: format.Guid) -> (mesh: ^Resident_Mesh, ready: bool) {
	mesh, ready = resident_mesh(r, guid)
	if ready {
		ready = resident_level0(r, mesh)
	}
	return
}

// resident_failed is whether a mesh asset could not be made resident, so what waits for it should not.
resident_failed :: proc(r: ^Residency, guid: format.Guid) -> bool {
	i, found := r.index[{guid, .Mesh}]
	return !found || r.entries[i].failed_at != 0
}

// resident_streaming is how many assets are on their way to the GPU.
resident_streaming :: proc(r: ^Residency) -> (count: int) {
	for &e in r.entries[:r.count] {
		count += int(e.stream != nil)
	}
	return
}

// residency_baked_count is how many entries only thumbnails asked for.
residency_baked_count :: proc(r: ^Residency) -> (count: int) {
	for &e in r.entries[:r.count] {
		count += int(e.baked && !e.world)
	}
	return
}

// residency_release_baked gives back what only thumbnails asked for, and gives how many it let go. Something that streams
// stays for a later call, and a thumbnail that asks again makes it resident again. The GPU's destroys wait for the frames
// that use what they destroy.
residency_release_baked :: proc(r: ^Residency) -> (released: int) {
	for i := r.count - 1; i >= 0; i -= 1 {
		e := &r.entries[i]
		_, live := e.source.(Live_Source)
		if !e.baked || e.world || e.stream != nil || live {
			continue
		}
		destroy_resources(r, e.kind, &e.current)
		if e.handle != {} {
			asset.unload(r.assets, e.handle)
		}
		delete_key(&r.index, Resident_Key{e.guid, e.kind})
		r.count -= 1
		if i != r.count {
			r.entries[i] = r.entries[r.count]
			r.index[{r.entries[i].guid, r.entries[i].kind}] = i
		}
		r.entries[r.count] = {}
		released += 1
	}
	return
}

// resident_instance_set gives an instance set asset's resources, and whether they are ready, as resident_mesh does.
resident_instance_set :: proc(r: ^Residency, guid: format.Guid) -> (set: ^Resident_Instance_Set, ready: bool) {
	e := entry(r, guid, .Instance_Set) or_return
	return &e.current.set, e.ready
}

// resident_texture gives a texture asset's resources, and whether they are ready. Until it is ready, use a default
// for its usage. A shader reads a texture through the type of its dimension, and any other is undefined, so a texture of
// another dimension is never ready, which is logged once for each of its versions.
resident_texture :: proc(r: ^Residency, guid: format.Guid, dimension := format.Texture_Dimension.D2) -> (texture: ^Resident_Texture, ready: bool) {
	e := entry(r, guid, .Texture) or_return
	if e.ready && e.current.texture.dimension != dimension {
		log_wrong_dimension(e, dimension)
		return &e.current.texture, false
	}
	return &e.current.texture, e.ready
}

// resident_texture_of gives a texture asset's resources as resident_texture does, for a reader that takes either of two
// dimensions and reads the one that it gets.
resident_texture_of :: proc(r: ^Residency, guid: format.Guid, first, second: format.Texture_Dimension) -> (texture: ^Resident_Texture, ready: bool) {
	e := entry(r, guid, .Texture) or_return
	if e.ready && e.current.texture.dimension != first && e.current.texture.dimension != second {
		log_wrong_dimension(e, first)
		return &e.current.texture, false
	}
	return &e.current.texture, e.ready
}

@(private = "file")
log_wrong_dimension :: proc(e: ^Resident_Entry, wanted: format.Texture_Dimension) {
	if !e.wrong_dimension_logged {
		e.wrong_dimension_logged = true
		buffer: [32]u8
		log.errorf("render: texture %s is a %v, and is read as a %v", format.guid_format(e.guid, &buffer), e.current.texture.dimension, wanted)
	}
}

// entry finds an asset's entry, or makes one and starts streaming. An asset that cannot load is tried again after
// RESIDENT_RETRY_FRAMES, and logged once. A live mesh never loads its asset.
@(private = "file")
entry :: proc(r: ^Residency, guid: format.Guid, kind: format.Asset_Kind) -> (e: ^Resident_Entry, ok: bool) {
	e = find_entry(r, guid, kind) or_return
	if r.baking {
		e.baked = true
	} else {
		e.world = true
	}
	_, live := e.source.(Live_Source)
	if !live && e.handle == {} && e.stream == nil && (e.failed_at == 0 || r.frame - e.failed_at >= RESIDENT_RETRY_FRAMES) {
		start_streaming(r, e)
	}
	return e, true
}

// find_entry finds an asset's entry, or makes an empty one.
@(private = "file")
find_entry :: proc(r: ^Residency, guid: format.Guid, kind: format.Asset_Kind) -> (e: ^Resident_Entry, ok: bool) {
	if guid == {} {
		return
	}
	if i, found := r.index[{guid, kind}]; found {
		return &r.entries[i], true
	}
	if r.count == MAX_RESIDENT {
		log.errorf("render: more than %d resident assets", MAX_RESIDENT)
		return
	}
	e = &r.entries[r.count]
	r.index[{guid, kind}] = r.count
	r.count += 1
	e^ = {guid = guid, kind = kind}
	return e, true
}

// set_live makes a mesh blob in memory resident under a GUID, in place of the asset's blob, until clear_live (see
// docs/rendering/assets.md#gpu-residency): the editor's live meshes. The blob streams as an asset's does, and swaps in when
// its transfers are done, so the version before draws until then. A blob that arrives while one streams waits for it,
// and the newest wins, so a drag never queues behind itself. The blob is copied, so it may go after the call.
set_live :: proc(r: ^Residency, guid: format.Guid, blob: []byte) -> bool {
	e := find_entry(r, guid, .Mesh) or_return
	return change(r, e, Event_Live_Blob{blob})
}

// clear_live ends a GUID's live mesh. The asset's blob streams again at the next chance, or loads when it is cooked.
// The live mesh draws until then, and draws nothing if the asset's blob cannot stream.
clear_live :: proc(r: ^Residency, guid: format.Guid) {
	if i, found := r.index[{guid, .Mesh}]; found {
		change(r, &r.entries[i], Event_Let_Go{})
	}
}

// is_live is whether a GUID draws a live mesh.
is_live :: proc(r: ^Residency, guid: format.Guid) -> bool {
	i := r.index[{guid, .Mesh}] or_return
	_, live := r.entries[i].source.(Live_Source)
	return live
}

// change is the one writer of an entry's source and stream (see docs/overview/conventions.md#state-with-a-lifecycle).
// It gives false for an event that the entry's source does not take, and for a live blob that cannot stream.
@(private = "file")
change :: proc(r: ^Residency, e: ^Resident_Entry, event: Resident_Event) -> (ok: bool) {
	defer {
		live, is_live := e.source.(Live_Source)
		assert(!is_live || live.next == nil || e.stream != nil, "a live mesh's next blob waits only for a stream")
	}
	switch ev in event {
	case Event_Live_Blob:
		e.failed_at = 0
		if _, is_live := e.source.(Live_Source); !is_live {
			e.source = Live_Source{}
		}
		live := &e.source.(Live_Source)
		// A blob that arrives while one streams waits for it, and the newest wins.
		if e.stream != nil {
			free_next(r, &live.next)
			next, err := mem.alloc_bytes(len(ev.blob), format.BLOB_ALIGN, r.platform.heap_allocator)
			if err != nil {
				return false
			}
			copy(next, ev.blob)
			live.next = next
			return true
		}
		e.stream = live_stream(r, e, ev.blob) or_return
	case Event_Let_Go:
		live := e.source.(Live_Source) or_return
		free_next(r, &live.next)
		e.source = Released_Source{}
	case Event_Landed:
		s := e.stream.? or_return
		destroy_resources(r, e.kind, &e.current)
		if e.kind == .Mesh && r.accels {
			create_mesh_accel(r, &s.pending.mesh)
		}
		e.current, e.version, e.ready = s.pending, s.version, true
		e.stream, e.wrong_dimension_logged = nil, false
		// The newest live step waited for this one.
		if live, is_live := &e.source.(Live_Source); is_live && live.next != nil {
			next := live.next
			live.next = nil
			defer mem.free_bytes(next, r.platform.heap_allocator)
			if stream, streams := live_stream(r, e, next); streams {
				e.stream = stream
			}
		}
	case Event_Stream_Failed:
		s := e.stream.? or_return
		destroy_resources(r, e.kind, &s.pending)
		// Nothing may go on drawing what the editor gave up.
		if s.released {
			destroy_resources(r, e.kind, &e.current)
			e.ready = false
		}
		// The version stays, so only a newer blob tries again.
		e.stream, e.version = nil, s.version
		fail(r, e, ev.reason)
	case Event_Stream_Superseded:
		s := e.stream.? or_return
		destroy_resources(r, e.kind, &s.pending)
		e.stream = nil
		// What it was to replace is as it was, a live mesh that was let go too.
		if s.released {
			e.source = Released_Source{}
		}
	case Event_Asset_Streaming:
		_, is_live := e.source.(Live_Source)
		assert(!is_live && e.stream == nil, "an asset streams only into an entry that is not live and streams nothing")
		// A live mesh that was let go draws until this is in.
		stream := ev.stream
		_, stream.released = e.source.(Released_Source)
		e.source, e.stream, e.failed_at = Asset_Source{}, stream, 0
	case Event_Asset_Failed:
		_, is_live := e.source.(Live_Source)
		assert(!is_live && e.stream == nil, "an asset fails only in an entry that is not live and streams nothing")
		// Nothing may go on drawing what the editor gave up.
		if _, released := e.source.(Released_Source); released {
			destroy_resources(r, e.kind, &e.current)
			e.ready = false
		}
		e.source = Asset_Source{}
		fail(r, e, ev.reason)
	}
	return true
}

// live_stream streams a live mesh's blob, at the version that draws, as it is not the asset's.
@(private = "file")
live_stream :: proc(r: ^Residency, e: ^Resident_Entry, blob: []byte) -> (s: Resident_Stream, ok: bool) {
	s, ok = new_stream(r, .Mesh, blob, e.version, {})
	if !ok {
		buffer: [32]u8
		log.errorf("render: the live mesh %s is not a blob that can be made resident", format.guid_format(e.guid, &buffer))
	}
	return
}

@(private = "file")
free_next :: proc(r: ^Residency, next: ^[]byte) {
	if next^ != nil {
		mem.free_bytes(next^, r.platform.heap_allocator)
		next^ = nil
	}
}

// start_streaming streams the asset's blob, which it loads first if it must.
@(private = "file")
start_streaming :: proc(r: ^Residency, e: ^Resident_Entry) {
	if e.handle == {} {
		handle, loaded := asset.load(r.assets, e.guid)
		if !loaded {
			change(r, e, Event_Asset_Failed{"is not cooked"})
			return
		}
		e.handle = handle
	}
	data, _ := asset.data(r.assets, e.handle)
	version := asset.version(r.assets, e.handle)
	stream, ok := new_stream(r, e.kind, data, version, {e.guid, e.handle, asset.modified(r.assets, e.handle)})
	if !ok {
		// The version stays, so a broken blob is tried again when the cooker writes a new one.
		e.version = version
		change(r, e, Event_Asset_Failed{"is not a blob that can be made resident"})
		return
	}
	change(r, e, Event_Asset_Streaming{stream})
}

// Stream_Origin is the asset that a blob is the head of, which a paged mesh reads its pages from: its GUID, its handle
// and its file's time. A blob from memory, a live mesh's, has none.
@(private = "file")
Stream_Origin :: struct {
	guid:     format.Guid,
	handle:   asset.Handle,
	modified: i64,
}

// new_stream creates new resources from a blob and streams its data into them.
@(private = "file")
new_stream :: proc(r: ^Residency, kind: format.Asset_Kind, data: []byte, version: u32, origin: Stream_Origin) -> (s: Resident_Stream, ok: bool) {
	#partial switch kind {
	case .Mesh:
		ok = stream_mesh(r, &s, data, version, origin)
	case .Texture:
		ok = stream_texture(r, &s, data)
	case .Instance_Set:
		ok = stream_instance_set(r, &s, data)
	}
	if !ok {
		destroy_resources(r, kind, &s.pending)
		return {}, false
	}
	s.version = version
	return s, true
}

@(private = "file")
fail :: proc(r: ^Residency, e: ^Resident_Entry, reason: string) {
	if e.failed_at == 0 {
		buffer: [32]u8
		log.errorf("render: the %v asset %s %s", e.kind, format.guid_format(e.guid, &buffer), reason)
	}
	e.failed_at = max(r.frame, 1)
}

@(private = "file")
stream_mesh :: proc(r: ^Residency, s: ^Resident_Stream, data: []byte, version: u32, origin: Stream_Origin) -> bool {
	blob, ok := format.mesh_view(data)
	paged := ok && .Paged in blob.flags
	// A paged mesh reads its pages from its asset's file, so a blob from memory cannot be one.
	if !ok || (paged && origin.handle == {}) {
		return false
	}
	m := &s.pending.mesh
	m.paged = paged
	m.vertex_count = blob.vertex_count
	m.attribute_stride = format.mesh_attribute_stride(blob.flags)
	m.flags = blob.flags
	m.bounds = blob.bounds
	m.index_format = .Index32 in blob.flags ? .U32 : .U16
	m.index_count = blob.index_count
	submeshes := format.mesh_submeshes(data, blob)
	m.submesh_count = u32(min(len(submeshes), MAX_SUBMESHES))
	for s, i in submeshes[:m.submesh_count] {
		m.submeshes[i] = {s.first_index, s.index_count, s.first_meshlet, s.meshlet_count, s.first_node, s.node_count, s.root_count}
		m.submesh_bounds[i] = s.bounds
		// A paged mesh's level buckets are in its head, as its meshlets are not.
		m.level_first[i] = s.level_first
	}
	if paged {
		m.levels = blob.levels
		m.pool_mesh = mesh_pool_add(&r.pool, r.platform, origin.guid, origin.handle, version, origin.modified, data, blob)
		if m.pool_mesh == 0 {
			return false
		}
		m.pages_first, m.page_count = mesh_pool_range(&r.pool, m.pool_mesh)
	} else {
		mesh_levels(m, format.mesh_meshlets(data, blob))
		m.positions = stream_buffer(r, s, format.blob_bytes(data, blob.positions), {}, "mesh positions") or_return
		m.attributes = stream_buffer(r, s, format.blob_bytes(data, blob.attributes), {}, "mesh attributes") or_return
		m.indices = stream_buffer(r, s, format.blob_bytes(data, blob.indices), {.Index}, "mesh indices") or_return
		m.meshlets = stream_buffer(r, s, format.blob_bytes(data, blob.meshlets), {}, "meshlets") or_return
		m.meshlet_vertices = stream_buffer(r, s, format.blob_bytes(data, blob.meshlet_vertices), {}, "meshlet vertices") or_return
		m.meshlet_triangles = stream_buffer(r, s, format.blob_bytes(data, blob.meshlet_triangles), {}, "meshlet triangles") or_return
	}
	m.meshlet_nodes = {}
	if blob.meshlet_nodes.size > 0 {
		m.meshlet_nodes = stream_buffer(r, s, format.blob_bytes(data, blob.meshlet_nodes), {}, "meshlet nodes") or_return
	}
	m.skin = {}
	if .Skinned in blob.flags {
		m.skin = stream_buffer(r, s, format.blob_bytes(data, blob.skin), {}, "mesh skin") or_return
	}
	m.impostor, m.impostor_size, m.impostor_error = {}, 0, 0
	if blob.impostor.size > 0 {
		m.impostor = stream_buffer(r, s, format.blob_bytes(data, blob.impostor), {}, "mesh impostor") or_return
		m.impostor_size, m.impostor_error = blob.impostor_size, blob.impostor_error
	}
	return true
}

@(private = "file")
stream_instance_set :: proc(r: ^Residency, s: ^Resident_Stream, data: []byte) -> bool {
	blob, ok := format.instance_set_view(data)
	if !ok || blob.count == 0 {
		return false
	}
	set := &s.pending.set
	set.count, set.cell_count = blob.count, blob.cell_count
	set.instances = stream_buffer(r, s, format.blob_bytes(data, blob.instances), {}, "instances") or_return
	set.cells = stream_buffer(r, s, format.blob_bytes(data, blob.cells), {}, "instance cells") or_return
	return true
}

// mesh_levels finds each submesh's level buckets and each level's errors among the mesh's meshlets, which the cooker
// orders by level within each submesh (see format.mesh_level_buckets). A paged mesh's are in its blob.
@(private)
mesh_levels :: proc(m: ^Resident_Mesh, meshlets: []format.Meshlet) {
	deepest := -1
	m.levels = {}
	for s, i in m.submeshes[:m.submesh_count] {
		if u64(s.first_meshlet) + u64(s.meshlet_count) > u64(len(meshlets)) {
			continue
		}
		last: int
		m.level_first[i], last = format.mesh_level_buckets(meshlets[s.first_meshlet:][:s.meshlet_count], m.bounds.center, &m.levels)
		deepest = max(deepest, last)
	}
	for &l in m.levels[clamp(deepest + 1, 0, INSTANCE_LEVEL_BUCKETS):] {
		l[0] = max(f32)
	}
}

#assert(INSTANCE_LEVEL_BUCKETS == format.MESH_LEVEL_BUCKETS)

// residency_enable_accels gives meshes acceleration structures from now on, and gives one to every mesh that is
// resident already.
residency_enable_accels :: proc(r: ^Residency) {
	if r.accels {
		return
	}
	r.accels = true
	for &e in r.entries[:r.count] {
		if e.kind == .Mesh && e.ready && e.current.mesh.accel == {} {
			create_mesh_accel(r, &e.current.mesh)
		}
	}
}

// create_mesh_accel creates a ready mesh's bottom-level acceleration structure, which unbuilt_accels then gives to the
// renderer to build.
@(private)
create_mesh_accel :: proc(r: ^Residency, m: ^Resident_Mesh) {
	if m.index_count == 0 || m.index_count % 3 != 0 || m.accel != {} {
		return
	}
	// A paged mesh's is of its level 0, which the residency asks for while meshes have acceleration structures, and
	// which makes this when it is in.
	if _, ready := m.level0.(Level0_Ready); m.paged && !ready {
		return
	}
	geometry := gpu.Accel_Geometry {
		vertices      = m.positions,
		vertex_stride = 12,
		vertex_count  = m.vertex_count,
		vertex_format = .RGB32_Float,
		indices       = m.indices,
		index_count   = m.index_count,
		index_format  = m.index_format,
		opaque        = true,
	}
	m.accel = r.platform.gpu_create_accel({kind = .Bottom, geometries = {geometry}, label = "mesh"})
}

// unbuilt_accels are the ready meshes whose acceleration structures have not been built, in frame memory.
unbuilt_accels :: proc(r: ^Residency) -> []^Resident_Mesh {
	meshes := make([dynamic]^Resident_Mesh, r.platform.frame_allocator)
	for &e in r.entries[:r.count] {
		if e.kind == .Mesh && e.ready && e.current.mesh.accel != {} && !e.current.mesh.accel_built {
			append(&meshes, &e.current.mesh)
		}
	}
	return meshes[:]
}

// stream_buffer creates a buffer for data and streams it in. Buffers are multiples of 4 bytes, so 16-bit indices are
// padded.
@(private = "file")
stream_buffer :: proc(r: ^Residency, s: ^Resident_Stream, data: []byte, usage: gpu.Buffer_Usages, label: string) -> (buffer: gpu.Buffer, ok: bool) {
	size := (len(data) + 3) &~ 3
	if size == 0 {
		return
	}
	buffer = r.platform.gpu_create_buffer({size = u32(size), usage = usage, label = label}, nil)
	if buffer == {} {
		return
	}
	padded := data
	if size != len(data) {
		padded = make([]byte, size, r.platform.frame_allocator)
		copy(padded, data)
	}
	transfer := r.platform.gpu_stream_buffer(buffer, 0, padded)
	if transfer == 0 {
		r.platform.gpu_destroy_buffer(buffer)
		return {}, false
	}
	s.transfers[s.transfer_count] = transfer
	s.transfer_count += 1
	return buffer, true
}

@(private = "file")
stream_texture :: proc(r: ^Residency, s: ^Resident_Stream, data: []byte) -> bool {
	blob, ok := format.texture_view(data)
	if !ok {
		return false
	}
	t := &s.pending.texture
	t^ = {pixel_format = gpu_format(blob.format), size = blob.size, mip_count = blob.mip_count, usage = blob.usage, dimension = blob.dimension, layer_count = blob.layer_count}
	desc := gpu.Texture_Desc {
		size      = blob.size,
		format    = t.pixel_format,
		mip_count = blob.mip_count,
		usage     = {.Sampled, .Streamed},
		label     = "texture asset",
	}
	if blob.dimension != .D2 {
		desc.layers = blob.layer_count
		desc.cube = blob.dimension == .Cube
	}
	t.texture = r.platform.gpu_create_texture(desc, nil)
	if t.texture == {} {
		return false
	}
	transfer := r.platform.gpu_stream_texture(t.texture, format.blob_bytes(data, blob.mips))
	if transfer == 0 {
		return false
	}
	s.transfers[0], s.transfer_count = transfer, 1
	return true
}

// gpu_format is a texture blob's format as the GPU names it.
gpu_format :: proc(f: format.Texture_Format) -> gpu.Format {
	switch f {
	case .RGBA8_Unorm:
		return .RGBA8_Unorm
	case .BC1_Unorm:
		return .BC1_Unorm
	case .BC1_Unorm_Srgb:
		return .BC1_Unorm_Srgb
	case .BC4_Unorm:
		return .BC4_Unorm
	case .BC5_Unorm:
		return .BC5_Unorm
	case .BC6H_Ufloat:
		return .BC6H_Ufloat
	case .BC7_Unorm:
		return .BC7_Unorm
	case .BC7_Unorm_Srgb:
		return .BC7_Unorm_Srgb
	}
	return .Unknown
}

@(private = "file")
destroy_resources :: proc(r: ^Residency, kind: format.Asset_Kind, resources: ^Resident_Resources) {
	#partial switch kind {
	case .Mesh:
		m := &resources.mesh
		drop_level0(r, m)
		mesh_pool_remove(&r.pool, r.platform, m.pool_mesh)
		r.platform.gpu_destroy_buffer(m.positions)
		r.platform.gpu_destroy_buffer(m.attributes)
		r.platform.gpu_destroy_buffer(m.indices)
		r.platform.gpu_destroy_buffer(m.meshlets)
		r.platform.gpu_destroy_buffer(m.meshlet_vertices)
		r.platform.gpu_destroy_buffer(m.meshlet_triangles)
		if m.meshlet_nodes != {} {
			r.platform.gpu_destroy_buffer(m.meshlet_nodes)
		}
		if m.skin != {} {
			r.platform.gpu_destroy_buffer(m.skin)
		}
		if m.impostor != {} {
			r.platform.gpu_destroy_buffer(m.impostor)
		}
		if m.accel != {} {
			r.platform.gpu_destroy_accel(m.accel)
		}
	case .Texture:
		r.platform.gpu_destroy_texture(resources.texture.texture)
	case .Instance_Set:
		r.platform.gpu_destroy_buffer(resources.set.instances)
		r.platform.gpu_destroy_buffer(resources.set.cells)
	}
	resources^ = {}
}
