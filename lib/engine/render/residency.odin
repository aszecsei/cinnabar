package render

import "core:log"
import "core:mem"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"

// At most this many assets are resident at once.
MAX_RESIDENT :: 512
// A resident mesh keeps at most this many submeshes. A mesh with more draws only these.
MAX_SUBMESHES :: 16
// An asset that cannot be made resident is tried again after this many frames.
RESIDENT_RETRY_FRAMES :: 60

// Resident_Mesh is a mesh asset's GPU buffers, and what drawing it needs from its blob. Its pointer is valid for the
// frame that it was given in.
Resident_Mesh :: struct {
	positions:         gpu.Buffer,
	attributes:        gpu.Buffer,
	indices:           gpu.Buffer,
	// The meshlets of every level of detail, which the mesh shader path draws (see docs/rendering/assets.md#gpu-residency).
	meshlets:          gpu.Buffer,
	meshlet_vertices:  gpu.Buffer,
	meshlet_triangles: gpu.Buffer,
	index_format:      gpu.Index_Format,
	index_count:       u32,
	vertex_count:      u32,
	attribute_stride:  u32,
	flags:             format.Mesh_Flags,
	bounds:            format.Mesh_Bounds,
	submesh_count:     u32,
	submeshes:         [MAX_SUBMESHES]Resident_Submesh,
	submesh_bounds:    [MAX_SUBMESHES]format.Mesh_Bounds,
	// With Ray_Query, the bottom-level acceleration structure of every triangle, which the renderer builds the first
	// frame after the mesh is ready (see docs/rendering/lighting-and-shadows.md#shadows).
	accel:             gpu.Accel_Struct,
	accel_built:       bool,
}

Resident_Submesh :: struct {
	first_index:   u32,
	index_count:   u32,
	first_meshlet: u32,
	meshlet_count: u32,
}

// Resident_Texture is a texture asset's GPU texture.
Resident_Texture :: struct {
	texture:   gpu.Texture,
	pixel_format: gpu.Format,
	size:      [2]u32,
	mip_count: u32,
	usage:     format.Texture_Usage,
}

// Residency gives the GPU resources of the texture and mesh assets that the renderer draws, by GUID (see
// docs/rendering/assets.md#gpu-residency). It lives in Game_State and holds handles only, so a code reload keeps it.
Residency :: struct {
	platform: ^core.Platform_API,
	assets:   ^asset.Assets,
	entries:  [MAX_RESIDENT]Resident_Entry,
	count:    int,
	frame:    u64,
	// Whether meshes get acceleration structures, which the renderer sets the first frame that traces (see
	// residency_enable_accels).
	accels:   bool,
}

@(private)
Resident_Entry :: struct {
	guid:          format.Guid,
	kind:          format.Asset_Kind,
	handle:        asset.Handle,
	// The resources that draw, from the blob of version, once ready.
	current:       Resident_Resources,
	version:       u32,
	ready:         bool,
	// New resources that stream in, from the blob of pending_version, which replace current when their transfers are
	// done, so the old version draws until then.
	pending:       Resident_Resources,
	pending_version: u32,
	streaming:     bool,
	// A mesh's six streams, or a texture's one.
	transfers:     [6]gpu.Transfer,
	transfer_count: int,
	// The frame of the last failure, which was logged, or 0.
	failed_at:     u64,
}

@(private)
Resident_Resources :: struct {
	mesh:    Resident_Mesh,
	texture: Resident_Texture,
}

residency_init :: proc(r: ^Residency, platform: ^core.Platform_API, assets: ^asset.Assets) {
	// The table is too large for a temporary on the stack, so it is zeroed in place.
	mem.zero_item(r)
	r.platform, r.assets = platform, assets
}

// residency_reload keeps every resident asset after a code reload.
residency_reload :: proc(r: ^Residency, platform: ^core.Platform_API) {
	r.platform = platform
}

// residency_destroy destroys every resident resource. Call it from the game's shutdown.
residency_destroy :: proc(r: ^Residency) {
	for &e in r.entries[:r.count] {
		destroy_resources(r, e.kind, &e.current)
		destroy_resources(r, e.kind, &e.pending)
	}
	r.count = 0
}

// residency_update starts a frame: it swaps in the resources whose transfers are done, and streams a new version of
// each asset whose blob asset.poll swapped. Call it once a frame, before drawing.
residency_update :: proc(r: ^Residency) {
	r.frame += 1
	for &e in r.entries[:r.count] {
		if e.streaming {
			done := true
			for t in e.transfers[:e.transfer_count] {
				done &&= r.platform.gpu_transfer_done(t)
			}
			if done {
				destroy_resources(r, e.kind, &e.current)
				if e.kind == .Mesh && r.accels {
					create_mesh_accel(r, &e.pending.mesh)
				}
				e.current, e.version, e.ready = e.pending, e.pending_version, true
				e.pending, e.streaming = {}, false
			}
			continue
		}
		// A failed version keeps its number, so only a newer blob tries again.
		if e.handle != {} && asset.version(r.assets, e.handle) != e.version {
			start_streaming(r, &e)
		}
	}
}

// resident_mesh gives a mesh asset's resources, and whether they are ready. The first call loads the asset and
// streams its data. Until it is ready, draw nothing.
resident_mesh :: proc(r: ^Residency, guid: format.Guid) -> (mesh: ^Resident_Mesh, ready: bool) {
	e := entry(r, guid, .Mesh) or_return
	return &e.current.mesh, e.ready
}

// resident_texture gives a texture asset's resources, and whether they are ready. Until it is ready, use a default
// for its usage.
resident_texture :: proc(r: ^Residency, guid: format.Guid) -> (texture: ^Resident_Texture, ready: bool) {
	e := entry(r, guid, .Texture) or_return
	return &e.current.texture, e.ready
}

// entry finds an asset's entry, or makes one and starts streaming. An asset that cannot load is tried again after
// RESIDENT_RETRY_FRAMES, and logged once.
@(private = "file")
entry :: proc(r: ^Residency, guid: format.Guid, kind: format.Asset_Kind) -> (e: ^Resident_Entry, ok: bool) {
	if guid == {} {
		return
	}
	for &existing in r.entries[:r.count] {
		if existing.guid == guid && existing.kind == kind {
			e = &existing
			break
		}
	}
	if e == nil {
		if r.count == MAX_RESIDENT {
			log.errorf("render: more than %d resident assets", MAX_RESIDENT)
			return
		}
		e = &r.entries[r.count]
		r.count += 1
		e^ = {guid = guid, kind = kind}
	}
	if e.handle == {} && !e.streaming && (e.failed_at == 0 || r.frame - e.failed_at >= RESIDENT_RETRY_FRAMES) {
		start_streaming(r, e)
	}
	return e, true
}

// start_streaming creates new resources from the asset's blob and streams its data into them.
@(private = "file")
start_streaming :: proc(r: ^Residency, e: ^Resident_Entry) {
	if e.handle == {} {
		handle, loaded := asset.load(r.assets, e.guid)
		if !loaded {
			fail(r, e, "is not cooked")
			return
		}
		e.handle = handle
	}
	data, _ := asset.data(r.assets, e.handle)
	version := asset.version(r.assets, e.handle)
	e.pending, e.transfer_count = {}, 0
	ok: bool
	#partial switch e.kind {
	case .Mesh:
		ok = stream_mesh(r, e, data)
	case .Texture:
		ok = stream_texture(r, e, data)
	}
	if !ok {
		destroy_resources(r, e.kind, &e.pending)
		// The version stays, so a broken blob is tried again when the cooker writes a new one.
		e.version = version
		fail(r, e, "is not a blob that can be made resident")
		return
	}
	e.pending_version, e.streaming, e.failed_at = version, true, 0
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
stream_mesh :: proc(r: ^Residency, e: ^Resident_Entry, data: []byte) -> bool {
	blob, ok := format.mesh_view(data)
	if !ok {
		return false
	}
	m := &e.pending.mesh
	m.vertex_count = blob.vertex_count
	m.attribute_stride = format.mesh_attribute_stride(blob.flags)
	m.flags = blob.flags
	m.bounds = blob.bounds
	m.index_format = .Index32 in blob.flags ? .U32 : .U16
	m.index_count = blob.index_count
	submeshes := format.mesh_submeshes(data, blob)
	m.submesh_count = u32(min(len(submeshes), MAX_SUBMESHES))
	for s, i in submeshes[:m.submesh_count] {
		m.submeshes[i] = {s.first_index, s.index_count, s.first_meshlet, s.meshlet_count}
		m.submesh_bounds[i] = s.bounds
	}
	m.positions = stream_buffer(r, e, format.blob_bytes(data, blob.positions), {}, "mesh positions") or_return
	m.attributes = stream_buffer(r, e, format.blob_bytes(data, blob.attributes), {}, "mesh attributes") or_return
	m.indices = stream_buffer(r, e, format.blob_bytes(data, blob.indices), {.Index}, "mesh indices") or_return
	m.meshlets = stream_buffer(r, e, format.blob_bytes(data, blob.meshlets), {}, "meshlets") or_return
	m.meshlet_vertices = stream_buffer(r, e, format.blob_bytes(data, blob.meshlet_vertices), {}, "meshlet vertices") or_return
	m.meshlet_triangles = stream_buffer(r, e, format.blob_bytes(data, blob.meshlet_triangles), {}, "meshlet triangles") or_return
	return true
}

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
@(private = "file")
create_mesh_accel :: proc(r: ^Residency, m: ^Resident_Mesh) {
	if m.index_count == 0 || m.index_count % 3 != 0 {
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
stream_buffer :: proc(r: ^Residency, e: ^Resident_Entry, data: []byte, usage: gpu.Buffer_Usages, label: string) -> (buffer: gpu.Buffer, ok: bool) {
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
	e.transfers[e.transfer_count] = transfer
	e.transfer_count += 1
	return buffer, true
}

@(private = "file")
stream_texture :: proc(r: ^Residency, e: ^Resident_Entry, data: []byte) -> bool {
	blob, ok := format.texture_view(data)
	if !ok {
		return false
	}
	t := &e.pending.texture
	t^ = {pixel_format = gpu_format(blob.format), size = blob.size, mip_count = blob.mip_count, usage = blob.usage}
	t.texture = r.platform.gpu_create_texture(
		{size = blob.size, format = t.pixel_format, mip_count = blob.mip_count, usage = {.Sampled, .Streamed}, label = "texture asset"},
		nil,
	)
	if t.texture == {} {
		return false
	}
	transfer := r.platform.gpu_stream_texture(t.texture, format.blob_bytes(data, blob.mips))
	if transfer == 0 {
		return false
	}
	e.transfers[0], e.transfer_count = transfer, 1
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
		r.platform.gpu_destroy_buffer(m.positions)
		r.platform.gpu_destroy_buffer(m.attributes)
		r.platform.gpu_destroy_buffer(m.indices)
		r.platform.gpu_destroy_buffer(m.meshlets)
		r.platform.gpu_destroy_buffer(m.meshlet_vertices)
		r.platform.gpu_destroy_buffer(m.meshlet_triangles)
		if m.accel != {} {
			r.platform.gpu_destroy_accel(m.accel)
		}
	case .Texture:
		r.platform.gpu_destroy_texture(resources.texture.texture)
	}
	resources^ = {}
}
