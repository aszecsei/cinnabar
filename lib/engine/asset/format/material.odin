package asset_format

import "core:mem"

import "cinnabar:core/layout"

// Materials and their instances (see docs/rendering/materials.md#materials). A material compiles one variant for each static
// switch combination that it or an instance uses, for each pass. A parameter block is the bytes that the material's
// Params struct loads from the material table, with each texture as its bindless index, which the runtime writes.

SHADING_EXTENSION :: ".shading"
MATERIAL_EXTENSION :: ".material"
MATERIAL_INSTANCE_EXTENSION :: ".material_instance"
MATERIAL_FUNCTION_EXTENSION :: ".material_function"
// At most this many static switches, a bit each in a variant's mask.
MAX_MATERIAL_SWITCHES :: 16

Material_Blend :: enum u32 {
	Opaque,
	// Opaque, but the shading model's opacity below the cutoff discards the pixel.
	Masked,
	// Blended over what is behind by its opacity, with moment-based order-independent transparency, or sorted back to
	// front with the Sorted flag (see docs/rendering/transparency.md#transparency).
	Transparent,
	// Its light times its opacity adds to what is behind, sorted with the sorted transparent draws.
	Additive,
}

Material_Flag :: enum u32 {
	Two_Sided,
	Cast_Shadows,
	// The shading model only emits, so the template skips the light loop.
	No_Lighting,
	// The material reads the frame's time, so its look changes from frame to frame without a change of its own. The
	// editor's previews draw it every frame.
	Reads_Time,
	// A Transparent material that draws sorted back to front instead of with moment-based transparency.
	Sorted,
	// The material defines displace, which moves its vertices (see docs/rendering/materials.md#vertex-displacement).
	Displaces,
	// The material draws the patches of Surface_Renderers, not meshes (see docs/rendering/surfaces.md#surfaces).
	Patches,
}

Material_Flags :: bit_set[Material_Flag;u32]

Material_Pass :: enum u32 {
	Forward,
	// Depth, the normal and the velocity, before the forward pass.
	Prepass,
	// Depth only, for the shadow maps. An opaque material's has no pixel stage.
	Depth,
	// A Transparent material's optical depth and its moments, which the transparent pass reconstructs the
	// transmittance in front of each surface from.
	Moments,
	// A transparent or additive material's shading, premultiplied by its opacity.
	Transparent,
	// A transparent or additive material's entity IDs and depth wherever it shows, for the editor.
	Transparent_Ids,
}

// material_transparent is whether a blend draws after the opaque surfaces, without a prepass, shadows or a forward pass.
material_transparent :: proc "contextless" (blend: Material_Blend) -> bool {
	return blend == .Transparent || blend == .Additive
}

// material_main_pass is the pass that every variant of a material has: the forward pass, or the transparent pass.
material_main_pass :: proc "contextless" (blob: ^Material_Blob) -> Material_Pass {
	return material_transparent(blob.blend) ? .Transparent : .Forward
}

Material_Param_Type :: enum u32 {
	Float,
	Float2,
	Float3,
	Float4,
	// A float4 that the editor shows as a color.
	Color,
	// A texture asset, which the block holds as its bindless index.
	Texture,
}

// Material_Texture_Default is what a texture parameter without a texture, or with one that is not resident yet, samples.
Material_Texture_Default :: enum u32 {
	White,
	Black,
	// A flat normal, (0.5, 0.5, 1).
	Normal,
}

Material_Param :: struct {
	name:   Slice,
	type:   Material_Param_Type,
	offset: u32,
}

// Material_Texture is a texture in a parameter block: where its index goes, and the texture, or its default.
Material_Texture :: struct {
	offset:  u32,
	default: Material_Texture_Default,
	guid:    Guid,
}

// Material_Variant is the bytecode of one stage of a pass for one combination of static switches.
Material_Variant :: struct {
	switches: u32,
	pass:     Material_Pass,
	stage:    Shader_Stage,
	code:     Slice,
}

// Material_Blob is the start of a material blob (see docs/content/blobs-and-loading.md#blob-format).
Material_Blob :: struct {
	header:           Blob_Header,
	flags:            Material_Flags,
	blend:            Material_Blend,
	// The opacity below which a Masked material discards.
	cutoff:             f32,
	// How far displace may move a vertex, in meters, which culling adds to each sphere.
	displacement_bound: f32,
	// Material_Param records, in the block's order.
	params:           Slice,
	// The switches' names, a Slice each, a switch's bit being its index.
	switches:         Slice,
	default_switches: u32,
	// The default parameter block, and its Material_Texture records.
	block:            Slice,
	textures:         Slice,
	// Material_Variant records, sorted by switches, pass and stage.
	variants:         Slice,
	source_path:      Slice,
}

// Material_Instance_Blob is the start of a material instance blob: the material that it is an instance of, through any
// instances between, its switches, and its parameter block with every value resolved.
Material_Instance_Blob :: struct {
	header:      Blob_Header,
	material:    Guid,
	switches:    u32,
	block:       Slice,
	textures:    Slice,
	source_path: Slice,
}

material_layout :: proc() -> u64 {
	return layout.hash(Material_Blob) ~ layout.hash(Material_Param) * 31 ~ layout.hash(Material_Texture) * 961 ~ layout.hash(Material_Variant) * 29791
}

material_instance_layout :: proc() -> u64 {
	return layout.hash(Material_Instance_Blob) ~ layout.hash(Material_Texture) * 31
}

@(private = "file")
slices_inside :: proc(data: []byte, slices: []Slice) -> bool {
	for s in slices {
		if u64(s.offset) + u64(s.size) > u64(len(data)) {
			return false
		}
	}
	return true
}

@(private = "file")
records_fit :: proc(s: Slice, $T: typeid) -> bool {
	return s.size % size_of(T) == 0 && s.offset % align_of(T) == 0
}

// material_view checks a material blob: its header, its layout, and that its slices and records are inside it.
material_view :: proc(data: []byte) -> (blob: ^Material_Blob, ok: bool) {
	header := blob_header(data) or_return
	if header.kind != .Material || header.layout != material_layout() || len(data) < size_of(Material_Blob) {
		return
	}
	blob = (^Material_Blob)(raw_data(data))
	if !slices_inside(data, {blob.params, blob.switches, blob.block, blob.textures, blob.variants, blob.source_path}) {
		return nil, false
	}
	if !records_fit(blob.params, Material_Param) || !records_fit(blob.switches, Slice) || !records_fit(blob.textures, Material_Texture) || !records_fit(blob.variants, Material_Variant) {
		return nil, false
	}
	for v in material_variants(data, blob) {
		slices_inside(data, {v.code}) or_return
	}
	for p in material_params(data, blob) {
		slices_inside(data, {p.name}) or_return
	}
	for s in material_switches(data, blob) {
		slices_inside(data, {s}) or_return
	}
	if !textures_inside(material_textures(data, blob), blob.block.size) {
		return nil, false
	}
	return blob, true
}

material_instance_view :: proc(data: []byte) -> (blob: ^Material_Instance_Blob, ok: bool) {
	header := blob_header(data) or_return
	if header.kind != .Material_Instance || header.layout != material_instance_layout() || len(data) < size_of(Material_Instance_Blob) {
		return
	}
	blob = (^Material_Instance_Blob)(raw_data(data))
	if !slices_inside(data, {blob.block, blob.textures, blob.source_path}) || !records_fit(blob.textures, Material_Texture) {
		return nil, false
	}
	if !textures_inside(instance_textures(data, blob), blob.block.size) {
		return nil, false
	}
	return blob, true
}

@(private = "file")
textures_inside :: proc(textures: []Material_Texture, block_size: u32) -> bool {
	for t in textures {
		if t.offset + 4 > block_size {
			return false
		}
	}
	return true
}

material_params :: proc "contextless" (data: []byte, blob: ^Material_Blob) -> []Material_Param {
	bytes := blob_bytes(data, blob.params)
	return ([^]Material_Param)(raw_data(bytes))[:len(bytes) / size_of(Material_Param)]
}

material_switches :: proc "contextless" (data: []byte, blob: ^Material_Blob) -> []Slice {
	bytes := blob_bytes(data, blob.switches)
	return ([^]Slice)(raw_data(bytes))[:len(bytes) / size_of(Slice)]
}

material_textures :: proc "contextless" (data: []byte, blob: ^Material_Blob) -> []Material_Texture {
	bytes := blob_bytes(data, blob.textures)
	return ([^]Material_Texture)(raw_data(bytes))[:len(bytes) / size_of(Material_Texture)]
}

material_variants :: proc "contextless" (data: []byte, blob: ^Material_Blob) -> []Material_Variant {
	bytes := blob_bytes(data, blob.variants)
	return ([^]Material_Variant)(raw_data(bytes))[:len(bytes) / size_of(Material_Variant)]
}

instance_textures :: proc "contextless" (data: []byte, blob: ^Material_Instance_Blob) -> []Material_Texture {
	bytes := blob_bytes(data, blob.textures)
	return ([^]Material_Texture)(raw_data(bytes))[:len(bytes) / size_of(Material_Texture)]
}

// material_code is a variant's bytecode, or nil if the material has no such variant.
material_code :: proc "contextless" (data: []byte, blob: ^Material_Blob, switches: u32, pass: Material_Pass, stage: Shader_Stage) -> []byte {
	for v in material_variants(data, blob) {
		if v.switches == switches && v.pass == pass && v.stage == stage {
			return blob_bytes(data, v.code)
		}
	}
	return nil
}

Material_Param_Entry :: struct {
	name:   string,
	type:   Material_Param_Type,
	offset: u32,
}

Material_Variant_Entry :: struct {
	switches: u32,
	pass:     Material_Pass,
	stage:    Shader_Stage,
	code:     []byte,
}

Material_Contents :: struct {
	guid:             Guid,
	key:              u64,
	flags:            Material_Flags,
	blend:            Material_Blend,
	cutoff:           f32,
	displacement_bound: f32,
	params:           []Material_Param_Entry,
	switches:         []string,
	default_switches: u32,
	block:            []byte,
	textures:         []Material_Texture,
	variants:         []Material_Variant_Entry,
	source_path:      string,
}

material_write :: proc(contents: Material_Contents, allocator := context.allocator) -> []byte {
	buffer := make([dynamic]byte, size_of(Material_Blob), allocator)
	params := reserve_bytes(&buffer, len(contents.params) * size_of(Material_Param), align_of(Material_Param))
	switches := reserve_bytes(&buffer, len(contents.switches) * size_of(Slice), align_of(Slice))
	textures := reserve_bytes(&buffer, len(contents.textures) * size_of(Material_Texture), align_of(Material_Texture))
	if len(contents.textures) > 0 {
		mem.copy(&buffer[textures.offset], raw_data(contents.textures), len(contents.textures) * size_of(Material_Texture))
	}
	variants := reserve_bytes(&buffer, len(contents.variants) * size_of(Material_Variant), align_of(Material_Variant))
	block := reserve_bytes(&buffer, len(contents.block), BLOB_ALIGN)
	copy(buffer[block.offset:], contents.block)
	for v, i in contents.variants {
		code := reserve_bytes(&buffer, len(v.code), BLOB_ALIGN)
		copy(buffer[code.offset:], v.code)
		record := Material_Variant{v.switches, v.pass, v.stage, code}
		mem.copy(&buffer[variants.offset + u32(i * size_of(Material_Variant))], &record, size_of(record))
	}
	for p, i in contents.params {
		record := Material_Param{append_bytes(&buffer, transmute([]byte)p.name), p.type, p.offset}
		mem.copy(&buffer[params.offset + u32(i * size_of(Material_Param))], &record, size_of(record))
	}
	for name, i in contents.switches {
		record := append_bytes(&buffer, transmute([]byte)name)
		mem.copy(&buffer[switches.offset + u32(i * size_of(Slice))], &record, size_of(record))
	}
	source_path := append_bytes(&buffer, transmute([]byte)contents.source_path)
	blob := Material_Blob {
		header = {magic = BLOB_MAGIC, kind = .Material, layout = material_layout(), key = contents.key, guid = contents.guid},
		flags = contents.flags,
		blend = contents.blend,
		cutoff = contents.cutoff,
		displacement_bound = contents.displacement_bound,
		params = params,
		switches = switches,
		default_switches = contents.default_switches,
		block = block,
		textures = textures,
		variants = variants,
		source_path = source_path,
	}
	mem.copy(raw_data(buffer), &blob, size_of(blob))
	return buffer[:]
}

Material_Instance_Contents :: struct {
	guid:        Guid,
	key:         u64,
	material:    Guid,
	switches:    u32,
	block:       []byte,
	textures:    []Material_Texture,
	source_path: string,
}

material_instance_write :: proc(contents: Material_Instance_Contents, allocator := context.allocator) -> []byte {
	buffer := make([dynamic]byte, size_of(Material_Instance_Blob), allocator)
	textures := reserve_bytes(&buffer, len(contents.textures) * size_of(Material_Texture), align_of(Material_Texture))
	if len(contents.textures) > 0 {
		mem.copy(&buffer[textures.offset], raw_data(contents.textures), len(contents.textures) * size_of(Material_Texture))
	}
	block := reserve_bytes(&buffer, len(contents.block), BLOB_ALIGN)
	copy(buffer[block.offset:], contents.block)
	source_path := append_bytes(&buffer, transmute([]byte)contents.source_path)
	blob := Material_Instance_Blob {
		header = {magic = BLOB_MAGIC, kind = .Material_Instance, layout = material_instance_layout(), key = contents.key, guid = contents.guid},
		material = contents.material,
		switches = contents.switches,
		block = block,
		textures = textures,
		source_path = source_path,
	}
	mem.copy(raw_data(buffer), &blob, size_of(blob))
	return buffer[:]
}
