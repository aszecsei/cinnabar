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
// DEFAULT_SURFACE_MATERIAL is the engine's default surface material (default_surface.material), which a Surface_Renderer
// without a material, or with one that draws meshes or cannot draw, draws with (see docs/rendering/surfaces.md#surfaces).
DEFAULT_SURFACE_MATERIAL :: #load("../content/materials/default_surface.material.meta", string)
// DEFAULT_RIBBON_MATERIAL is the engine's default ribbon material (default_ribbon.material), which a particle ribbon
// without a material, or with one that does not draw ribbons, draws with (see docs/rendering/particles.md#ribbons).
DEFAULT_RIBBON_MATERIAL :: #load("../content/materials/default_ribbon.material.meta", string)
// The placeholders that a bin draws with while its material's pipelines compile, one for each blend mode, without
// parameters, so they read nothing of the draws' blocks (see docs/rendering/materials.md#runtime).
PLACEHOLDER_MATERIAL :: #load("../content/materials/placeholder.material.meta", string)
PLACEHOLDER_TRANSPARENT_MATERIAL :: #load("../content/materials/placeholder_transparent.material.meta", string)
PLACEHOLDER_ADDITIVE_MATERIAL :: #load("../content/materials/placeholder_additive.material.meta", string)

// Substitute is what a bin draws with while its material's pipelines compile: a placeholder in its blend mode, or the
// default surface material for a bin of patches.
Substitute :: enum u8 {
	Opaque,
	Transparent,
	Additive,
	Patches,
}

// Materials is the material runtime (see docs/rendering/materials.md#runtime): the materials and instances that the frames
// draw, their pipelines, and the textures that a texture parameter without its texture samples. It lives in the
// Renderer, and holds handles only.
Materials :: struct {
	refs:           [MAX_MATERIALS]Material_Ref,
	ref_count:      int,
	pipelines:      [MAX_MATERIAL_PIPELINES]Material_Pipeline,
	pipeline_count: int,
	default_guid:   format.Guid,
	default_surface_guid: format.Guid,
	default_ribbon_guid:  format.Guid,
	substitutes:    [Substitute]format.Guid,
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
// material's blob, and updated when the blob changes. The impostor passes are pipelines too, which an impostors' bin
// draws with in place of the opaque passes (see docs/rendering/gpu-scene.md#impostors).
Material_Pipeline :: struct {
	material:     format.Guid,
	switches:     u32,
	pipelines:    [format.Material_Pass]gpu.Pipeline,
	// The blob has each impostor pass, so a submesh of a mesh with an impostor draws it past its coarsest level.
	impostor_path: bool,
	// With Mesh_Shaders, the mesh shader path's pipelines of the opaque passes, which the world's opaque draws draw
	// with when mesh_path (see docs/rendering/gpu-scene.md#mesh-shader-path). The previews draw with pipelines.
	meshes:       [format.Material_Pass]gpu.Pipeline,
	mesh_path:    bool,
	version:      u32,
	two_sided:    bool,
	cast_shadows: bool,
	blend:        format.Material_Blend,
	// A Transparent material that draws sorted back to front, not with moment-based transparency.
	sorted:       bool,
	// How far the material's displacement may move a vertex, in meters, which culling adds to each sphere.
	displacement_bound: f32,
	// The material draws the patches of Surface_Renderers, with the patch vertex path, not meshes.
	patches:      bool,
	// The material draws its meshes as billboards, which face the camera (see docs/rendering/gpu-scene.md#billboards).
	billboard:    bool,
	// The material draws particle ribbons, with the ribbon vertex path, not meshes (see
	// docs/rendering/particles.md#ribbons).
	ribbon:       bool,
	// A transparent or additive material's transparent pass, blended over the scene: its back faces, for a two-sided
	// material, then its front faces. The sorted draws draw with them, and so do the previews of every transparent
	// material, which have no moments (see docs/rendering/transparency.md#transparency).
	over:         [2]gpu.Pipeline,
}

// material_group is the bins that a material's draws are in: the opaque ones, which the prepass and the forward pass
// draw, those of moment-based transparency, or the sorted transparent and additive draws.
material_group :: proc(p: ^Material_Pipeline) -> Bin_Group {
	switch {
	case !format.material_transparent(p.blend):
		return .Opaque
	case p.blend == .Transparent && !p.sorted:
		return .Moments
	}
	return .Sorted
}

@(private)
material_pipeline_destroy :: proc(p: ^Material_Pipeline, platform: ^core.Platform_API) {
	for pipeline in p.pipelines {
		platform.gpu_destroy_pipeline(pipeline)
	}
	for pipeline in p.meshes {
		platform.gpu_destroy_pipeline(pipeline)
	}
	for pipeline in p.over {
		platform.gpu_destroy_pipeline(pipeline)
	}
}

// The prepass's targets: the surface's normal in the world, folded into the octahedron, and the velocity in UV.
NORMAL_FORMAT :: gpu.Format.RG16_Float
VELOCITY_FORMAT :: gpu.Format.RG16_Float
PREPASS_COLORS :: []gpu.Color_Target{{format = NORMAL_FORMAT}, {format = VELOCITY_FORMAT}}

// Material_Table is one frame's material table: a parameter block for each material or instance that the frame draws,
// with its textures' bindless indices written. It is in frame memory, and the frame uploads it.
Material_Table :: struct {
	uses:     map[format.Guid]Material_Use,
	bytes:    [dynamic]byte,
	// A texture of a block is not resident yet, so it samples its default.
	waiting:  bool,
}

// Material_Use is a material or instance as the frame draws it: its pipeline, and its block's offset in the table.
Material_Use :: struct {
	pipeline: int,
	block:    u32,
}

materials_init :: proc(m: ^Materials, platform: ^core.Platform_API) {
	m.default_guid, _ = format.meta_guid(DEFAULT_MATERIAL)
	m.default_surface_guid, _ = format.meta_guid(DEFAULT_SURFACE_MATERIAL)
	m.default_ribbon_guid, _ = format.meta_guid(DEFAULT_RIBBON_MATERIAL)
	m.substitutes[.Opaque], _ = format.meta_guid(PLACEHOLDER_MATERIAL)
	m.substitutes[.Transparent], _ = format.meta_guid(PLACEHOLDER_TRANSPARENT_MATERIAL)
	m.substitutes[.Additive], _ = format.meta_guid(PLACEHOLDER_ADDITIVE_MATERIAL)
	m.substitutes[.Patches] = m.default_surface_guid
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
	for &p in m.pipelines[:m.pipeline_count] {
		material_pipeline_destroy(&p, platform)
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
	b := material_block(data, guid) or_return
	use.pipeline = material_pipeline(r, b.material, b.switches) or_return
	use.block = add_block(r, table, b)
	return use, true
}

// bin_draws gives the pipeline that each bin draws with this frame: its own, or while its own compiles, its blend
// mode's substitute (see docs/rendering/materials.md#runtime). The frame chooses once, so a bin's prepass and its
// forward pass draw the same surface, and it draws with its own pipeline the frame after that one compiles.
@(private)
bin_draws :: proc(r: ^Renderer, bin_pipelines: []int) -> []int {
	draws := make([]int, len(bin_pipelines), r.platform.frame_allocator)
	for index, bin in bin_pipelines {
		draws[bin] = index
		p := &r.materials.pipelines[index]
		kind := substitute_kind(p) or_continue
		if material_ready(r.platform, p) || p.material == r.materials.substitutes[kind] {
			continue
		}
		if substitute, ok := substitute_pipeline(r, kind); ok {
			draws[bin] = substitute
		}
	}
	return draws
}

// substitute_kind is the substitute that a material's bins draw with while it compiles. A transparent material of
// patches has none, and a ribbon material has none, since the substitutes draw meshes.
@(private)
substitute_kind :: proc(p: ^Material_Pipeline) -> (kind: Substitute, ok: bool) {
	if p.ribbon {
		return .Transparent, false
	}
	if p.patches {
		return .Patches, material_group(p) == .Opaque
	}
	switch p.blend {
	case .Opaque, .Masked:
		return .Opaque, true
	case .Transparent:
		return .Transparent, true
	case .Additive:
		return .Additive, true
	}
	return
}

// material_ready is whether each of a material's pipelines is compiled.
@(private)
material_ready :: proc(platform: ^core.Platform_API, p: ^Material_Pipeline) -> bool {
	if platform.gpu_pipeline_ready == nil {
		return true
	}
	for pipeline in p.pipelines {
		if pipeline != {} && !platform.gpu_pipeline_ready(pipeline) {
			return false
		}
	}
	for pipeline in p.meshes {
		if pipeline != {} && !platform.gpu_pipeline_ready(pipeline) {
			return false
		}
	}
	for pipeline in p.over {
		if pipeline != {} && !platform.gpu_pipeline_ready(pipeline) {
			return false
		}
	}
	return true
}

// substitute_pipeline gives a substitute's pipelines, which it loads and makes the first time a bin waits for its own.
@(private = "file")
substitute_pipeline :: proc(r: ^Renderer, kind: Substitute) -> (index: int, ok: bool) {
	guid := r.materials.substitutes[kind]
	data := material_data(r, guid) or_return
	b := material_block(data, guid) or_return
	return material_pipeline(r, b.material, b.switches)
}

// Material_Block is what a material's or an instance's blob gives a draw: its material, its switches, and its
// parameter block with its textures.
@(private)
Material_Block :: struct {
	material: format.Guid,
	switches: u32,
	block:    []byte,
	textures: []format.Material_Texture,
}

@(private)
material_block :: proc(data: []byte, guid: format.Guid) -> (b: Material_Block, ok: bool) {
	if blob, is_material := format.material_view(data); is_material {
		return {guid, blob.default_switches, format.blob_bytes(data, blob.block), format.material_textures(data, blob)}, true
	}
	if instance, is_instance := format.material_instance_view(data); is_instance {
		return {instance.material, instance.switches, format.blob_bytes(data, instance.block), format.instance_textures(data, instance)}, true
	}
	return
}

// add_block adds a parameter block to the table, with its textures' bindless indices, and gives its offset.
@(private)
add_block :: proc(r: ^Renderer, table: ^Material_Table, b: Material_Block) -> u32 {
	// Blocks start at 16 bytes, so the Params struct loads aligned.
	offset := u32(len(table.bytes))
	append(&table.bytes, ..b.block)
	for _ in 0 ..< (16 - len(b.block) % 16) % 16 {
		append(&table.bytes, 0)
	}
	for t in b.textures {
		index := gpu.read_index(r.materials.defaults[t.default])
		if t.guid != {} {
			if texture, ready := resident_texture(&r.residency, t.guid); ready {
				index = gpu.read_index(texture.texture)
			} else {
				table.waiting = true
			}
		}
		(^u32)(&table.bytes[offset + t.offset])^ = index
	}
	return offset
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
	if format.material_code(data, blob, switches, format.material_main_pass(blob), .Vertex) == nil {
		return -1, false
	}
	if index < 0 {
		if m.pipeline_count == MAX_MATERIAL_PIPELINES {
			log.errorf("render: more than %d material pipelines", MAX_MATERIAL_PIPELINES)
			return -1, false
		}
		index = m.pipeline_count
		m.pipeline_count += 1
		m.pipelines[index] = {material = guid, switches = switches}
	}
	make_pipelines(r, &m.pipelines[index], data, blob, switches)
	m.pipelines[index].version = ref_version
	return index, true
}

// make_pipelines creates or updates the pipelines of each pass of a material and switch combination from its blob.
@(private)
make_pipelines :: proc(r: ^Renderer, p: ^Material_Pipeline, data: []byte, blob: ^format.Material_Blob, switches: u32) {
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
		// 0, which passes only where the bit is clear (see docs/rendering/layers-and-output.md#view-model).
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
		// The transparent passes test the opaque surfaces' depth and write none, where the stencil bit is the
		// reference's, as the forward pass does. Their depth bias keeps a face in an opaque surface's plane in front of it.
		.Moments = {
			colors = MOMENT_COLORS,
			depth_format = DEPTH_FORMAT,
			depth_compare = .Greater,
			depth_bias = TRANSPARENT_DEPTH_BIAS,
			slope_bias = TRANSPARENT_SLOPE_BIAS,
			stencil = {compare = .Equal, read_mask = VIEW_MODEL_STENCIL},
			cull = cull,
			label = label,
		},
		// Moment-based transparency's: each surface adds its light and its opacity, so the order does not matter.
		.Transparent = {
			colors = ACCUMULATED_COLORS,
			depth_format = DEPTH_FORMAT,
			depth_compare = .Greater,
			depth_bias = TRANSPARENT_DEPTH_BIAS,
			slope_bias = TRANSPARENT_SLOPE_BIAS,
			stencil = {compare = .Equal, read_mask = VIEW_MODEL_STENCIL},
			cull = cull,
			label = label,
		},
		// After post-processing, for the editor: the IDs and the depth of the surfaces wherever they show.
		.Transparent_Ids = {
			colors = TRANSPARENT_ID_COLORS,
			depth_format = DEPTH_FORMAT,
			depth_compare = .Greater,
			depth_bias = TRANSPARENT_DEPTH_BIAS,
			slope_bias = TRANSPARENT_SLOPE_BIAS,
			depth_write = true,
			stencil = {compare = .Equal, read_mask = VIEW_MODEL_STENCIL},
			cull = cull,
			label = label,
		},
		.Impostor_Forward = {},
		.Impostor_Prepass = {},
		.Impostor_Depth = {},
	}
	// An impostor's quad faces its view, and its pixels write their own depths, which the shadow maps' bias does not
	// move, so the impostor's depth pass moves them itself.
	for pass in ([]format.Material_Pass{.Forward, .Prepass, .Depth}) {
		impostor := descs[pass]
		impostor.cull = .None
		descs[format.material_impostor_pass(pass)] = impostor
	}
	for &desc, pass in descs {
		desc.vertex = format.material_code(data, blob, switches, pass, .Vertex)
		desc.pixel = format.material_code(data, blob, switches, pass, .Pixel)
	}
	sorted := .Sorted in blob.flags
	over := descs[.Transparent]
	over.colors = blob.blend == .Additive ? ADDITIVE_COLORS : OVER_COLORS
	// Only moment-based transparency adds up its transparent pass; the sorted draws blend theirs over the scene.
	if blob.blend != .Transparent || sorted {
		descs[.Transparent].vertex = nil
	}
	platform := r.platform
	for desc, pass in descs {
		// A blob from before the pass existed has no code for it, and draws nothing in it.
		update_pipeline(platform, &p.pipelines[pass], desc)
	}
	// The mesh shader path draws the opaque passes when the device has mesh shaders and the blob has every one's code.
	// A vertex pipeline cannot become a mesh pipeline, so the two are apart.
	mesh_descs: [format.Material_Pass]gpu.Graphics_Pipeline_Desc
	p.mesh_path = r.caps.mesh_shaders && !format.material_transparent(blob.blend)
	p.impostor_path = !format.material_transparent(blob.blend)
	for pass in ([]format.Material_Pass{.Impostor_Forward, .Impostor_Prepass, .Impostor_Depth}) {
		p.impostor_path &&= descs[pass].vertex != nil && descs[pass].pixel != nil
	}
	for pass in ([]format.Material_Pass{.Forward, .Prepass, .Depth}) {
		desc := &mesh_descs[pass]
		desc^ = descs[pass]
		desc.vertex = nil
		desc.amplification = format.material_code(data, blob, switches, pass, .Amplification)
		desc.mesh = format.material_code(data, blob, switches, pass, .Mesh)
		p.mesh_path &&= desc.amplification != nil && desc.mesh != nil
	}
	for &desc, pass in mesh_descs {
		if !p.mesh_path {
			desc.mesh = nil
		}
		update_pipeline(platform, &p.meshes[pass], desc)
	}
	// Back faces first, which a one-sided material has none of.
	faces := [2]gpu.Cull_Mode{.Front, .Back}
	for &pipeline, i in p.over {
		desc := over
		desc.cull = faces[i]
		if i == 0 && !two_sided {
			desc.vertex = nil
		}
		update_pipeline(platform, &pipeline, desc)
	}
	p.two_sided = two_sided
	p.cast_shadows = .Cast_Shadows in blob.flags
	p.blend, p.sorted = blob.blend, sorted
	p.displacement_bound = .Displaces in blob.flags ? blob.displacement_bound : 0
	p.patches = .Patches in blob.flags
	p.billboard = .Billboard in blob.flags
	p.ribbon = .Ribbon in blob.flags
}

// update_pipeline updates a pipeline to a description, creates it, or destroys it for a description without code.
@(private = "file")
update_pipeline :: proc(platform: ^core.Platform_API, pipeline: ^gpu.Pipeline, desc: gpu.Graphics_Pipeline_Desc) {
	if desc.vertex == nil && desc.mesh == nil {
		platform.gpu_destroy_pipeline(pipeline^)
		pipeline^ = {}
	} else if pipeline^ == {} || !platform.gpu_update_graphics_pipeline(pipeline^, desc) {
		platform.gpu_destroy_pipeline(pipeline^)
		pipeline^ = platform.gpu_create_graphics_pipeline(desc)
	}
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
