package render

import "core:log"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"

// At most this many materials and instances are loaded at once, and this many pipelines exist, one for each material
// and switch combination that a frame draws.
MAX_MATERIALS :: 512
MAX_MATERIAL_PIPELINES :: 256
// A material that cannot load is tried again after this many frames.
MATERIAL_RETRY_FRAMES :: 60

// DEFAULT_MATERIAL is the engine's default material (lib/engine/content/materials/default.material), which a submesh
// without a material, or with one that cannot draw, draws with.
DEFAULT_MATERIAL :: #load("../content/materials/default.material.meta", string)

// Materials is the material runtime (see docs/rendering.md#runtime): the materials and instances that the frames
// draw, their pipelines, and the textures that a texture parameter without its texture samples. It lives in the
// Renderer, and holds handles only.
Materials :: struct {
	refs:           [MAX_MATERIALS]Material_Ref,
	ref_count:      int,
	pipelines:      [MAX_MATERIAL_PIPELINES]Material_Pipeline,
	pipeline_count: int,
	default_guid:   format.Guid,
	// White, black and a flat normal, by Material_Texture_Default.
	defaults:       [format.Material_Texture_Default]gpu.Texture,
	sampler:        gpu.Sampler,
}

@(private)
Material_Ref :: struct {
	guid:      format.Guid,
	handle:    asset.Handle,
	failed_at: u64,
}

// Material_Pipeline is the pipelines of one material and switch combination, one for each pass, made from the
// material's blob, and updated when the blob changes.
Material_Pipeline :: struct {
	material:     format.Guid,
	switches:     u32,
	pipelines:    [format.Material_Pass]gpu.Pipeline,
	version:      u32,
	two_sided:    bool,
	cast_shadows: bool,
}

// The prepass's targets: the surface's normal in the world, folded into the octahedron, and the velocity in UV.
NORMAL_FORMAT :: gpu.Format.RG16_Float
VELOCITY_FORMAT :: gpu.Format.RG16_Float
PREPASS_COLORS :: []gpu.Color_Target{{format = NORMAL_FORMAT}, {format = VELOCITY_FORMAT}}

// Material_Table is one frame's material table: a parameter block for each material or instance that the frame draws,
// with its textures' bindless indices written. It is in frame memory, and the frame uploads it.
Material_Table :: struct {
	uses:  map[format.Guid]Material_Use,
	bytes: [dynamic]byte,
}

// Material_Use is a material or instance as the frame draws it: its pipeline, and its block's offset in the table.
Material_Use :: struct {
	pipeline: int,
	block:    u32,
}

materials_init :: proc(m: ^Materials, platform: ^core.Platform_API) {
	m.default_guid, _ = format.meta_guid(DEFAULT_MATERIAL)
	texels := [format.Material_Texture_Default][4]u8 {
		.White  = {255, 255, 255, 255},
		.Black  = {0, 0, 0, 255},
		.Normal = {128, 128, 255, 255},
	}
	for &texel, d in texels {
		m.defaults[d] = platform.gpu_create_texture({size = {1, 1}, format = .RGBA8_Unorm, usage = {.Sampled}, label = "default texture"}, texel[:])
	}
	m.sampler = platform.gpu_create_sampler({filter = .Linear, label = "material sampler"})
}

materials_destroy :: proc(m: ^Materials, platform: ^core.Platform_API) {
	for p in m.pipelines[:m.pipeline_count] {
		for pipeline in p.pipelines {
			platform.gpu_destroy_pipeline(pipeline)
		}
	}
	for t in m.defaults {
		platform.gpu_destroy_texture(t)
	}
	platform.gpu_destroy_sampler(m.sampler)
	m^ = {}
}

// materials_reload makes every pipeline again at its next use, because a code reload may bring new descriptions.
materials_reload :: proc(m: ^Materials) {
	for &p in m.pipelines[:m.pipeline_count] {
		p.version = max(u32)
	}
}

// use_material gives a material or instance as this frame draws it, and adds its block to the table the first time.
// A GUID of zero is the default material, and so is one that cannot draw. It fails only when the default material
// cannot draw either.
use_material :: proc(r: ^Renderer, table: ^Material_Table, guid: format.Guid) -> (use: Material_Use, ok: bool) {
	wanted := guid if guid != {} else r.materials.default_guid
	if found, seen := table.uses[wanted]; seen {
		return found, true
	}
	use, ok = make_use(r, table, wanted)
	if !ok && wanted != r.materials.default_guid {
		use, ok = use_material(r, table, {})
	}
	if ok {
		table.uses[wanted] = use
	}
	return
}

@(private = "file")
make_use :: proc(r: ^Renderer, table: ^Material_Table, guid: format.Guid) -> (use: Material_Use, ok: bool) {
	data := material_data(r, guid) or_return
	material_guid := guid
	switches: u32
	block: []byte
	textures: []format.Material_Texture
	if blob, is_material := format.material_view(data); is_material {
		switches, block, textures = blob.default_switches, format.blob_bytes(data, blob.block), format.material_textures(data, blob)
	} else if instance, is_instance := format.material_instance_view(data); is_instance {
		material_guid, switches = instance.material, instance.switches
		block, textures = format.blob_bytes(data, instance.block), format.instance_textures(data, instance)
	} else {
		return
	}
	use.pipeline = material_pipeline(r, material_guid, switches) or_return
	// Blocks start at 16 bytes, so the Params struct loads aligned.
	use.block = u32(len(table.bytes))
	append(&table.bytes, ..block)
	for _ in 0 ..< (16 - len(block) % 16) % 16 {
		append(&table.bytes, 0)
	}
	for t in textures {
		index := gpu.read_index(r.materials.defaults[t.default])
		if t.guid != {} {
			if texture, ready := resident_texture(&r.residency, t.guid); ready {
				index = gpu.read_index(texture.texture)
			}
		}
		(^u32)(&table.bytes[use.block + t.offset])^ = index
	}
	return use, true
}

// material_data loads a material's or an instance's blob. An asset that cannot load is logged once, and tried again
// after MATERIAL_RETRY_FRAMES.
@(private = "file")
material_data :: proc(r: ^Renderer, guid: format.Guid) -> (data: []byte, ok: bool) {
	m := &r.materials
	ref: ^Material_Ref
	for &existing in m.refs[:m.ref_count] {
		if existing.guid == guid {
			ref = &existing
			break
		}
	}
	if ref == nil {
		if m.ref_count == MAX_MATERIALS {
			log.errorf("render: more than %d materials", MAX_MATERIALS)
			return
		}
		ref = &m.refs[m.ref_count]
		m.ref_count += 1
		ref^ = {guid = guid}
	}
	if asset.guid(r.residency.assets, ref.handle) != guid {
		if ref.failed_at != 0 && r.residency.frame - ref.failed_at < MATERIAL_RETRY_FRAMES {
			return
		}
		handle, loaded := asset.load(r.residency.assets, guid)
		if !loaded {
			if ref.failed_at == 0 {
				buffer: [32]u8
				log.errorf("render: the material %s is not cooked", format.guid_format(guid, &buffer))
			}
			ref.failed_at = max(r.residency.frame, 1)
			return
		}
		ref.handle, ref.failed_at = handle, 0
	}
	return asset.data(r.residency.assets, ref.handle)
}

// material_pipeline gives the pipelines of a material and switch combination, which it makes, or updates when the
// material's blob changed. It fails if the material has no such variant, as before the cooker compiles it.
@(private = "file")
material_pipeline :: proc(r: ^Renderer, guid: format.Guid, switches: u32) -> (index: int, ok: bool) {
	data := material_data(r, guid) or_return
	m := &r.materials
	blob := format.material_view(data) or_return
	ref_version := material_version(r, guid)
	index = -1
	for p, i in m.pipelines[:m.pipeline_count] {
		if p.material == guid && p.switches == switches {
			index = i
			break
		}
	}
	if index >= 0 && m.pipelines[index].version == ref_version {
		return index, true
	}
	if format.material_code(data, blob, switches, .Forward, .Vertex) == nil {
		return -1, false
	}
	two_sided := .Two_Sided in blob.flags
	cull: gpu.Cull_Mode = two_sided ? .None : .Back
	label := format.blob_string(data, blob.source_path)
	descs := [format.Material_Pass]gpu.Graphics_Pipeline_Desc {
		// The prepass wrote this depth, so the forward pass shades each pixel once, where the stencil bit is the
		// reference's.
		.Forward = {
			colors = WORLD_COLORS,
			depth_format = DEPTH_FORMAT,
			depth_compare = .Equal,
			stencil = {compare = .Equal, read_mask = VIEW_MODEL_STENCIL},
			cull = cull,
			label = label,
		},
		// The view model draws with the bit as its reference, which passes everywhere and sets it. The world draws with
		// 0, which passes only where the bit is clear (see docs/rendering.md#view-model).
		.Prepass = {
			colors = PREPASS_COLORS,
			depth_format = DEPTH_FORMAT,
			depth_compare = .Greater,
			depth_write = true,
			stencil = {compare = .Greater_Equal, pass = .Replace, read_mask = VIEW_MODEL_STENCIL, write_mask = VIEW_MODEL_STENCIL},
			cull = cull,
			label = label,
		},
		.Depth = {
			depth_format = SHADOW_FORMAT,
			depth_compare = .Greater,
			depth_write = true,
			depth_bias = SHADOW_DEPTH_BIAS,
			slope_bias = SHADOW_SLOPE_BIAS,
			depth_clamp = true,
			cull = cull,
			label = label,
		},
	}
	for &desc, pass in descs {
		desc.vertex = format.material_code(data, blob, switches, pass, .Vertex)
		desc.pixel = format.material_code(data, blob, switches, pass, .Pixel)
	}
	platform := r.platform
	if index < 0 {
		if m.pipeline_count == MAX_MATERIAL_PIPELINES {
			log.errorf("render: more than %d material pipelines", MAX_MATERIAL_PIPELINES)
			return -1, false
		}
		index = m.pipeline_count
		m.pipeline_count += 1
		m.pipelines[index] = {material = guid, switches = switches}
	}
	p := &m.pipelines[index]
	for desc, pass in descs {
		// A blob from before the pass existed has no code for it, and draws nothing in it.
		if desc.vertex == nil {
			platform.gpu_destroy_pipeline(p.pipelines[pass])
			p.pipelines[pass] = {}
		} else if p.pipelines[pass] == {} || !platform.gpu_update_graphics_pipeline(p.pipelines[pass], desc) {
			platform.gpu_destroy_pipeline(p.pipelines[pass])
			p.pipelines[pass] = platform.gpu_create_graphics_pipeline(desc)
		}
	}
	p.version = ref_version
	p.two_sided = two_sided
	p.cast_shadows = .Cast_Shadows in blob.flags
	return index, true
}

@(private = "file")
material_version :: proc(r: ^Renderer, guid: format.Guid) -> u32 {
	for ref in r.materials.refs[:r.materials.ref_count] {
		if ref.guid == guid {
			return asset.version(r.residency.assets, ref.handle)
		}
	}
	return 0
}
