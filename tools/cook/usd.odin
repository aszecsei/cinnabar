package cook

import "core:c"

// vendor/lightusd (TinyUSDZ), which `just lightusd` builds with cn_usd.cpp, its C interface (see usd/cn_usd.h). Only the
// cooker links them.
foreign import lightusd {"../../build/obj/lightusd/out/cn_usd.lib", "../../build/obj/lightusd/out/lightusd_static.lib"}

// The justfile passes the vendor/lightusd tag, so a LightUSD update cooks every stage again.
LIGHTUSD_VERSION :: #config(LIGHTUSD_VERSION, "unknown")

Cn_Usd :: struct {}

Cn_Usd_String :: struct {
	ptr: [^]u8,
	len: c.size_t,
}

Cn_Usd_Up :: enum i32 {
	Y = 0,
	Z = 1,
}

Cn_Usd_Info :: struct {
	up:              Cn_Usd_Up,
	meters_per_unit: f64,
	node_count:      i32,
	mesh_count:      i32,
	material_count:  i32,
	texture_count:   i32,
	instance_count:  i32,
	light_count:     i32,
	layer_count:     i32,
}

Cn_Usd_Node_Kind :: enum i32 {
	Group  = 0,
	Mesh   = 1,
	Camera = 2,
	Light  = 3,
	Other  = 4,
}

Cn_Usd_Node :: struct {
	parent:  i32,
	kind:    Cn_Usd_Node_Kind,
	mesh:    i32,
	visible: i32,
	name:    Cn_Usd_String,
	path:    Cn_Usd_String,
	// Row-major, for row vectors, as USD stores it.
	local:   [16]f64,
	world:   [16]f64,
}

Cn_Usd_Instance :: struct {
	mesh:     i32,
	material: i32,
	visible:  i32,
	path:     Cn_Usd_String,
	world:    [16]f64,
}

Cn_Usd_Subset :: struct {
	material: i32,
	first:    i32,
	count:    i32,
	name:     Cn_Usd_String,
}

Cn_Usd_Mesh :: struct {
	name:          Cn_Usd_String,
	path:          Cn_Usd_String,
	double_sided:  i32,
	left_handed:   i32,
	corner_count:  i32,
	positions:     [^]f32,
	normals:       [^]f32,
	uv0:           [^]f32,
	uv1:           [^]f32,
	colors:        [^]f32,
	subset_count:  i32,
	subsets:       [^]Cn_Usd_Subset,
}

Cn_Usd_Channel :: enum i32 {
	R    = 0,
	G    = 1,
	B    = 2,
	A    = 3,
	RGB  = 4,
	RGBA = 5,
}

Cn_Usd_Input :: struct {
	texture: i32,
	channel: Cn_Usd_Channel,
	value:   [3]f32,
}

Cn_Usd_Material :: struct {
	name:              Cn_Usd_String,
	path:              Cn_Usd_String,
	preview_surface:   i32,
	specular_workflow: i32,
	diffuse:           Cn_Usd_Input,
	emissive:          Cn_Usd_Input,
	metallic:          Cn_Usd_Input,
	roughness:         Cn_Usd_Input,
	opacity:           Cn_Usd_Input,
	normal:            Cn_Usd_Input,
	occlusion:         Cn_Usd_Input,
	opacity_threshold: f32,
}

Cn_Usd_Color_Space :: enum i32 {
	Auto = 0,
	SRGB = 1,
	Raw  = 2,
}

Cn_Usd_Wrap :: enum i32 {
	Repeat = 0,
	Clamp  = 1,
	Mirror = 2,
	Black  = 3,
}

Cn_Usd_Texture :: struct {
	asset:                 Cn_Usd_String,
	resolved:              Cn_Usd_String,
	color_space:           Cn_Usd_Color_Space,
	wrap_s:                Cn_Usd_Wrap,
	wrap_t:                Cn_Usd_Wrap,
	uv_name:               Cn_Usd_String,
	scale:                 [4]f32,
	bias:                  [4]f32,
	has_transform:         i32,
	transform_scale:       [2]f32,
	transform_rotation:    f32,
	transform_translation: [2]f32,
}

Cn_Usd_Options :: struct {
	point_instancers: i32,
}

@(default_calling_convention = "c")
foreign lightusd {
	cn_usd_open :: proc(path: cstring, options: ^Cn_Usd_Options) -> ^Cn_Usd ---
	cn_usd_close :: proc(usd: ^Cn_Usd) ---
	cn_usd_error :: proc(usd: ^Cn_Usd) -> Cn_Usd_String ---
	cn_usd_warnings :: proc(usd: ^Cn_Usd) -> Cn_Usd_String ---
	cn_usd_info :: proc(usd: ^Cn_Usd, info: ^Cn_Usd_Info) ---
	cn_usd_layer :: proc(usd: ^Cn_Usd, index: i32) -> Cn_Usd_String ---
	cn_usd_node :: proc(usd: ^Cn_Usd, index: i32, node: ^Cn_Usd_Node) ---
	cn_usd_instance :: proc(usd: ^Cn_Usd, index: i32, instance: ^Cn_Usd_Instance) ---
	cn_usd_mesh :: proc(usd: ^Cn_Usd, index: i32, mesh: ^Cn_Usd_Mesh) -> i32 ---
	cn_usd_material :: proc(usd: ^Cn_Usd, index: i32, material: ^Cn_Usd_Material) ---
	cn_usd_texture :: proc(usd: ^Cn_Usd, index: i32, texture: ^Cn_Usd_Texture) ---
}

// usd_string is a shim string as an Odin string, which stays valid as the shim's does.
usd_string :: proc(s: Cn_Usd_String) -> string {
	return string(s.ptr[:s.len]) if s.len > 0 else ""
}
