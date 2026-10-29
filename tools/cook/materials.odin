// Shading models, materials, material instances and material functions (see docs/content/kinds/materials.md#materials). A
// shading model is a .shading declaration of its surface inputs, with its implementation in the .hlsli beside it. A
// material picks a shading model, declares its parameters and static switches, and defines evaluate with a graph of
// nodes (see graphs.odin), or in HLSL after a `---` line. The cooker generates a source for each combination of
// switches that the material or an instance uses, and compiles each with the engine's templates of every pass, once
// for each source: a source's name is its hash. An instance names its parent and overrides values; its blob holds the
// values resolved through every parent.
package cook

import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

import format "cinnabar:engine/asset/format"

// Changing how the cooker cooks materials changes this, which invalidates every cooked material and instance.
MATERIAL_COOK_VERSION :: "materials 8"


Shading_Input :: struct {
	name:    string,
	// float, float2, float3 or float4.
	type:    string,
	count:   int,
	default: [4]f64,
}

// Shading_Decl is a parsed .shading file.
Shading_Decl :: struct {
	asset:          int,
	// The file's name without its extension, such as "lit", which materials name.
	name:           string,
	inputs:         [dynamic]Shading_Input,
	no_lighting:    bool,
	// The .hlsli beside it, absolute.
	implementation: string,
	ok:             bool,
}

Param_Decl :: struct {
	name:            string,
	type:            format.Material_Param_Type,
	value:           [4]f64,
	texture_default: format.Material_Texture_Default,
	texture:         format.Guid,
	line:            int,
	// The group that the editor shows it in, or "".
	group:           string,
}

Switch_Decl :: struct {
	name:    string,
	default: bool,
}

// Material_Decl is a parsed .material file.
Material_Decl :: struct {
	asset:        int,
	shading:      string,
	blend:        format.Material_Blend,
	cutoff:       f32,
	// A Transparent material's transparency: sorted back to front, or moment-based by default.
	sorted:       bool,
	two_sided:    bool,
	cast_shadows: bool,
	// How far displace may move a vertex, in meters (see docs/rendering/materials.md#vertex-displacement).
	displacement_bound: f32,
	// The material draws the patches of Surface_Renderers (geometry = patches, see docs/rendering/surfaces.md#surfaces).
	patches:      bool,
	// The material draws its meshes as billboards (geometry = billboard or billboard_axis, see
	// docs/rendering/gpu-scene.md#billboards).
	billboard:    Billboard,
	// The material draws particle ribbons (geometry = ribbon, see docs/rendering/particles.md#ribbons).
	ribbon:       bool,
	params:       [dynamic]Param_Decl,
	switches:     [dynamic]Switch_Decl,
	// The HLSL after the `---` line, and the line of the file that it starts at, or the graph.
	body:         string,
	body_line:    int,
	has_body:     bool,
	graph:        Graph,
	// The texture that the editor's texture tools measure by, from a `tool_texture` line, or zero for the first texture
	// that the graph samples, and the hotspot rectangles in its texels (see docs/editor/mesh-editing.md#texture-tools).
	tool_texture: format.Guid,
	hotspots:     [dynamic][4]u32,
	ok:           bool,
}

// Billboard is how a material's meshes face the camera: not at all, wholly, or turning about their +y.
Billboard :: enum u8 {
	None,
	Camera,
	Axis,
}

Override :: struct {
	name:  string,
	value: string,
	line:  int,
}

// Instance_Decl is a parsed .material_instance file.
Instance_Decl :: struct {
	asset:        int,
	parent:       format.Guid,
	overrides:    [dynamic]Override,
	// Its own `tool_texture` line, or zero to take its parent's.
	tool_texture: format.Guid,
	ok:           bool,
}

// Resolved is a material or an instance with its values resolved through its parents: its material, its switches,
// and its parameters' values.
@(private = "file")
Resolved :: struct {
	material: ^Material_Decl,
	switches: u32,
	params:   []Param_Decl,
	// The sources of it and every parent, which its key covers.
	chain:    [dynamic][]byte,
	// The texture that the editor's texture tools measure by: the nearest `tool_texture` line, else the first texture
	// that the material samples, with the instances' overrides.
	tool_texture: format.Guid,
	ok:       bool,
}

// Material_Set is what cooking a material needs of the other assets: the shading models by name, the material
// functions by GUID, and every asset's kind.
Material_Set :: struct {
	shadings:  map[string]^Shading_Decl,
	functions: map[format.Guid]^Function_Decl,
	kinds:     map[format.Guid]format.Asset_Kind,
}

// material_set parses the shading models and the material functions, and marks those with errors as failed.
material_set :: proc(assets: []Asset_Source, problems: ^Problems) -> (set: Material_Set, ok: bool) {
	ok = true
	set.shadings = make(map[string]^Shading_Decl, context.temp_allocator)
	for i in assets_of(assets, .Shading_Model) {
		decl := new(Shading_Decl, context.temp_allocator)
		decl^ = parse_shading(assets[i], i, problems)
		if previous, taken := set.shadings[decl.name]; taken {
			report_error(problems, assets[i].path, 0, 0, "a shading model named %s is also at %s", decl.name, assets[previous.asset].path)
			decl.ok, previous.ok = false, false
		}
		set.shadings[decl.name] = decl
		assets[i].failed = !decl.ok
		ok &&= decl.ok
	}
	set.kinds = make(map[format.Guid]format.Asset_Kind, len(assets), context.temp_allocator)
	for a in assets {
		set.kinds[a.meta.guid] = a.kind
		// A sub-asset's kind, as a stage's textures, which its material instances name.
		for s in a.meta.subassets {
			set.kinds[s.guid] = format.subasset_kind_of(s.kind)
		}
	}
	set.functions = make(map[format.Guid]^Function_Decl, context.temp_allocator)
	for i in assets_of(assets, .Material_Function) {
		decl := new(Function_Decl, context.temp_allocator)
		decl^ = parse_function(assets[i], i, problems)
		set.functions[assets[i].meta.guid] = decl
		for &n in decl.graph.nodes {
			add_function_dependency(&assets[i], &n)
		}
		assets[i].failed = !decl.ok
		ok &&= decl.ok
	}
	return
}

// add_function_dependency makes a function node's material function a dependency of the asset whose graph has it.
@(private = "file")
add_function_dependency :: proc(a: ^Asset_Source, n: ^Graph_Node) {
	if n.kind.name != "function" {
		return
	}
	for f in n.fields {
		if f.name == "function" && f.value.kind == .Asset && !slice.contains(a.dependencies[:], f.value.guid) {
			append(&a.dependencies, f.value.guid)
		}
	}
}

// cook_materials checks the shading models and the material functions, and cooks the materials and instances whose
// keys changed. A material cooks a variant for each combination of switches that it or an instance uses. It reports
// every failure, and returns false if any.
cook_materials :: proc(options: Cook_Options, assets: []Asset_Source, pass: ^Pass) -> bool {
	problems := &pass.problems
	set, ok := material_set(assets, problems)
	if pass.shadings == nil {
		pass.shadings = make([dynamic]^Shading_Decl, context.temp_allocator)
	}
	for _, decl in set.shadings {
		append(&pass.shadings, decl)
	}
	materials := make(map[format.Guid]^Material_Decl, context.temp_allocator)
	for i in assets_of(assets, .Material) {
		decl := new(Material_Decl, context.temp_allocator)
		decl^ = parse_material(assets[i], i, set.kinds, problems)
		materials[assets[i].meta.guid] = decl
	}
	instances := make(map[format.Guid]^Instance_Decl, context.temp_allocator)
	for i in assets_of(assets, .Material_Instance) {
		decl := new(Instance_Decl, context.temp_allocator)
		decl^ = parse_instance(assets[i], i, problems)
		instances[assets[i].meta.guid] = decl
	}

	// Each instance resolves through its parents, and its switches add a variant to its material.
	resolved := make(map[format.Guid]Resolved, context.temp_allocator)
	variants := make(map[^Material_Decl][dynamic]u32, context.temp_allocator)
	for guid, decl in materials {
		resolved[guid] = resolve(assets, guid, materials, instances, set.kinds, problems)
		add_variant(&variants, decl, resolved[guid].switches)
	}
	for guid in instances {
		r := resolve(assets, guid, materials, instances, set.kinds, problems)
		resolved[guid] = r
		if r.ok {
			add_variant(&variants, r.material, r.switches)
		}
	}

	out_dir := config_dir(options)
	if len(materials) + len(instances) > 0 {
		if err := os.make_directory_all(fmt.tprintf("%s/generated", out_dir)); err != nil && err != .Exist {
			report_error(problems, out_dir, 0, 0, "%v", err)
			return false
		}
	}
	for guid, decl in materials {
		a := &assets[decl.asset]
		a.tool_texture, a.hotspots = resolved[guid].tool_texture, decl.hotspots[:]
		shading, found := set.shadings[decl.shading]
		if found {
			append(&a.dependencies, assets[shading.asset].meta.guid)
		}
		add_texture_dependencies(a, decl.params[:])
		for &n in decl.graph.nodes {
			add_function_dependency(a, &n)
		}
		list := variants[decl]
		slice.sort(list[:])
		a.permutations = len(list)
		switch {
		case !decl.ok || !check_settings(a^, problems):
			a.failed = true
		case !found:
			report_error(problems, a.path, 0, 0, "no shading model is named %s", decl.shading)
			a.failed = true
		case !shading.ok:
			report_error(problems, a.path, 0, 0, "not cooked, because its shading model %s has errors", decl.shading)
			a.failed = true
		case:
			a.failed = !cook_material(options, a^, guid, decl, shading, set, list[:], fmt.tprintf("%s/%s.blob", out_dir, guid_text(guid)), pass)
		}
		ok &&= !a.failed
	}
	for guid, decl in instances {
		a := &assets[decl.asset]
		if decl.parent != {} {
			append(&a.dependencies, decl.parent)
		}
		r := resolved[guid]
		add_texture_dependencies(a, r.params)
		a.tool_texture = r.tool_texture
		if r.material != nil {
			a.hotspots = r.material.hotspots[:]
		}
		if !decl.ok || !r.ok || !check_settings(a^, problems) {
			a.failed = true
			ok = false
			continue
		}
		a.failed = !cook_instance(options, a^, guid, r, assets, out_dir, pass)
		ok &&= !a.failed
	}
	return ok
}

// cook_preview cooks a material's text that the editor has not saved, as the material with this GUID, into the
// preview area of the cache, <config>/preview/<guid>.blob (see docs/rendering/materials.md#material-previews). It compiles the
// material's default switches only. Its problems name the material's file, with the lines of the text.
cook_preview :: proc(options: Cook_Options, guid: format.Guid, text: string) -> (problems: Problems, ok: bool) {
	// The scan's and the other assets' problems are the content's, which the daemon's passes report.
	content: Problems
	assets, _, _, scanned := scan(options.roots[:], &content)
	if !scanned {
		report_error(&problems, "", 0, 0, "cannot scan the content roots")
		return
	}
	set, _ := material_set(assets, &content)
	index := -1
	for a, i in assets {
		if a.meta.guid == guid {
			index = i
		}
	}
	if index < 0 || assets[index].kind != .Material {
		report_error(&problems, "", 0, 0, "%s is not a material in the content", guid_text(guid))
		return
	}
	a := assets[index]
	a.source = transmute([]byte)text
	decl := new(Material_Decl, context.temp_allocator)
	decl^ = parse_material(a, index, set.kinds, &problems)
	shading, found := set.shadings[decl.shading]
	switch {
	case !decl.ok:
		return
	case !found:
		report_error(&problems, a.path, 0, 0, "no shading model is named %s", decl.shading)
		return
	case !shading.ok:
		report_error(&problems, a.path, 0, 0, "its shading model %s has errors", decl.shading)
		return
	}
	switches: u32
	for s, i in decl.switches {
		if s.default {
			switches |= 1 << u32(i)
		}
	}
	dir := fmt.tprintf("%s/preview", config_dir(options))
	for sub in ([]string{dir, fmt.tprintf("%s/generated", config_dir(options))}) {
		if err := os.make_directory_all(sub); err != nil && err != .Exist {
			report_error(&problems, sub, 0, 0, "%v", err)
			return
		}
	}
	pass := Pass {
		problems = problems,
		force    = make(map[format.Guid]bool, context.temp_allocator),
	}
	pass.force[guid] = true
	ok = cook_material(options, a, guid, decl, shading, set, {switches}, fmt.tprintf("%s/%s.blob", dir, guid_text(guid)), &pass)
	return pass.problems, ok
}

@(private = "file")
guid_text :: proc(guid: format.Guid) -> string {
	buffer := new([32]u8, context.temp_allocator)
	return format.guid_format(guid, buffer)
}

@(private = "file")
add_variant :: proc(variants: ^map[^Material_Decl][dynamic]u32, decl: ^Material_Decl, switches: u32) {
	list := variants[decl] or_else make([dynamic]u32, context.temp_allocator)
	if !slice.contains(list[:], switches) {
		append(&list, switches)
	}
	variants[decl] = list
}

@(private = "file")
add_texture_dependencies :: proc(a: ^Asset_Source, params: []Param_Decl) {
	for p in params {
		if p.type == .Texture && p.texture != {} && !slice.contains(a.dependencies[:], p.texture) {
			append(&a.dependencies, p.texture)
		}
	}
}

// Decl_Line is a line of a declaration: its text without comments and blank lines, whether it is indented, which
// makes it part of the item above it, and its number from 1.
Decl_Line :: struct {
	text:     string,
	indented: bool,
	number:   int,
}

decl_lines :: proc(text: string, stop_at_body := false) -> (lines: []Decl_Line, body: string, body_line: int, has_body: bool) {
	result := make([dynamic]Decl_Line, context.temp_allocator)
	rest := text
	number := 0
	for raw in strings.split_lines_iterator(&rest) {
		number += 1
		line := strings.trim_space(raw)
		if stop_at_body && line == "---" {
			return result[:], rest, number + 1, true
		}
		if line == "" || line[0] == '#' {
			continue
		}
		append(&result, Decl_Line{line, raw[0] == ' ' || raw[0] == '\t', number})
	}
	return result[:], "", 0, false
}

@(private = "file")
input_count :: proc(type: string) -> int {
	switch type {
	case "float":
		return 1
	case "float2":
		return 2
	case "float3":
		return 3
	case "float4":
		return 4
	}
	return 0
}

parse_shading :: proc(a: Asset_Source, index: int, problems: ^Problems) -> (decl: Shading_Decl) {
	decl = {asset = index, name = filepath.stem(a.path), inputs = make([dynamic]Shading_Input, context.temp_allocator), ok = true}
	lines, _, _, _ := decl_lines(string(a.source))
	if len(lines) == 0 || lines[0].text != "shading 1" {
		report_error(problems, a.path, 1, 0, "a shading model starts with `shading 1`")
		decl.ok = false
		return
	}
	for l in lines[1:] {
		word, _, rest := strings.partition(l.text, " ")
		switch word {
		case "flag":
			if strings.trim_space(rest) != "no_lighting" {
				report_error(problems, a.path, l.number, 0, "the only flag is no_lighting")
				decl.ok = false
			}
			decl.no_lighting = true
		case "input":
			// input <name> <type> = <default>
			head, _, value := strings.partition(rest, "=")
			fields := strings.fields(head, context.temp_allocator)
			if len(fields) != 2 || !is_identifier(fields[0]) || input_count(fields[1]) == 0 {
				report_error(problems, a.path, l.number, 0, "an input is `input <name> <float, float2, float3 or float4> = <default>`")
				decl.ok = false
				continue
			}
			values, count, numbers_ok := parse_numbers(strings.trim_space(value))
			if !numbers_ok || count != input_count(fields[1]) {
				report_error(problems, a.path, l.number, 0, "the input %s needs %d numbers as its default", fields[0], input_count(fields[1]))
				decl.ok = false
				continue
			}
			append(&decl.inputs, Shading_Input{fields[0], fields[1], count, values})
		case:
			report_error(problems, a.path, l.number, 0, "a shading model's lines are `input` and `flag`, not %q", word)
			decl.ok = false
		}
	}
	decl.implementation = fmt.tprintf("%s/%s.hlsli", filepath.dir(a.path), decl.name)
	if !os.is_file(decl.implementation) {
		report_error(problems, a.path, 0, 0, "has no implementation: %s.hlsli is not beside it", decl.name)
		decl.ok = false
	}
	return
}

// parse_texture reads a texture value: a texture asset's GUID after $, or white, black or normal for none.
@(private = "file")
parse_texture :: proc(text: string, kinds: map[format.Guid]format.Asset_Kind) -> (guid: format.Guid, default: format.Material_Texture_Default, message: string) {
	switch text {
	case "white":
		return {}, .White, ""
	case "black":
		return {}, .Black, ""
	case "normal":
		return {}, .Normal, ""
	}
	if !strings.has_prefix(text, "$") {
		return {}, .White, "a texture is a texture asset's GUID after $, or white, black or normal"
	}
	parsed, parsed_ok := format.guid_parse(text[1:])
	if !parsed_ok {
		return {}, .White, "a texture is 32 hex digits after $"
	}
	if kind, found := kinds[parsed]; found && kind != .Texture {
		return {}, .White, fmt.tprintf("%s is a %v, not a texture", text, kind)
	}
	return parsed, .White, ""
}

parse_material :: proc(a: Asset_Source, index: int, kinds: map[format.Guid]format.Asset_Kind, problems: ^Problems) -> (decl: Material_Decl) {
	decl = {
		asset        = index,
		cast_shadows = true,
		cutoff       = 0.5,
		params       = make([dynamic]Param_Decl, context.temp_allocator),
		switches     = make([dynamic]Switch_Decl, context.temp_allocator),
		hotspots     = make([dynamic][4]u32, context.temp_allocator),
		ok           = true,
	}
	cutoff_line, transparency_line, geometry_line := 0, 0, 0
	lines, body, body_line, has_body := decl_lines(string(a.source), stop_at_body = true)
	if len(lines) == 0 || lines[0].text != "material 1" {
		report_error(problems, a.path, 1, 0, "a material starts with `material 1`")
		decl.ok = false
		return
	}
	decl.body, decl.body_line, decl.has_body = body, body_line, has_body
	names := make(map[string]bool, context.temp_allocator)
	// The node or the parameter that the indented lines below belong to. The lines of a node that is not one are
	// skipped, because its own line has the error.
	node: ^Graph_Node
	param := -1
	skipping := false
	for l in lines[1:] {
		if l.indented {
			switch {
			case skipping:
			case node != nil:
				decl.ok = graph_node_field(node, l.text, l.number, a.path, problems) && decl.ok
			case param >= 0:
				key, _, value := strings.partition(l.text, "=")
				v, message := parse_graph_value(strings.trim_space(value))
				if strings.trim_space(key) != "group" || message != "" || v.kind != .Text {
					report_error(problems, a.path, l.number, 0, "a parameter's line is `group = \"<name>\"`")
					decl.ok = false
					continue
				}
				decl.params[param].group = v.text
			case:
				report_error(problems, a.path, l.number, 0, "an indented line belongs to a parameter or a node")
				decl.ok = false
			}
			continue
		}
		node, param, skipping = nil, -1, false
		word, _, rest := strings.partition(l.text, " ")
		if word == "node" {
			added, added_ok := graph_node_start(&decl.graph, rest, l.number, a.path, problems)
			node, skipping = added, !added_ok
			decl.ok &&= added_ok
			continue
		}
		if word == "hotspot" {
			fields := strings.fields(rest, context.temp_allocator)
			rect: [4]u32
			rect_ok := len(fields) == 4
			for f, i in fields {
				if !rect_ok {
					break
				}
				n, n_ok := strconv.parse_uint(f)
				rect[i] = u32(n)
				rect_ok = n_ok && n <= 1 << 16
			}
			if !rect_ok || rect[2] <= rect[0] || rect[3] <= rect[1] {
				report_error(problems, a.path, l.number, 0, "a hotspot is `hotspot <x0> <y0> <x1> <y1>`, in texels of the tool texture, with x1 above x0 and y1 above y0")
				decl.ok = false
				continue
			}
			append(&decl.hotspots, rect)
			continue
		}
		if word == "param" || word == "switch" {
			head, _, value := strings.partition(rest, "=")
			fields := strings.fields(head, context.temp_allocator)
			value = strings.trim_space(value)
			name := fields[0] if len(fields) > 0 else ""
			if !is_identifier(name) || names[name] {
				report_error(problems, a.path, l.number, 0, "%q is not a name, or is taken", name)
				decl.ok = false
				continue
			}
			names[name] = true
			if word == "switch" {
				if len(fields) != 1 || (value != "true" && value != "false") {
					report_error(problems, a.path, l.number, 0, "a switch is `switch <name> = true` or `false`")
					decl.ok = false
					continue
				}
				if len(decl.switches) == format.MAX_MATERIAL_SWITCHES {
					report_error(problems, a.path, l.number, 0, "a material has at most %d switches", format.MAX_MATERIAL_SWITCHES)
					decl.ok = false
					continue
				}
				append(&decl.switches, Switch_Decl{name, value == "true"})
				continue
			}
			p := Param_Decl {
				name = name,
				line = l.number,
			}
			type_name := fields[1] if len(fields) == 2 else ""
			switch type_name {
			case "float":
				p.type = .Float
			case "float2":
				p.type = .Float2
			case "float3":
				p.type = .Float3
			case "float4":
				p.type = .Float4
			case "color":
				p.type = .Color
			case "texture":
				p.type = .Texture
			case:
				report_error(problems, a.path, l.number, 0, "a parameter is `param <name> <float, float2, float3, float4, color or texture> = <default>`")
				decl.ok = false
				continue
			}
			if message := set_param(&p, value, kinds); message != "" {
				report_error(problems, a.path, l.number, 0, "%s", message)
				decl.ok = false
				continue
			}
			append(&decl.params, p)
			param = len(decl.params) - 1
			continue
		}
		key, _, value := strings.partition(l.text, "=")
		key, value = strings.trim_space(key), strings.trim_space(value)
		switch key {
		case "shading":
			decl.shading = value
		case "blend":
			switch value {
			case "opaque":
				decl.blend = .Opaque
			case "masked":
				decl.blend = .Masked
			case "transparent":
				decl.blend = .Transparent
			case "additive":
				decl.blend = .Additive
			case:
				report_error(problems, a.path, l.number, 0, "blend is opaque, masked, transparent or additive")
				decl.ok = false
			}
		case "cutoff":
			cutoff, cutoff_ok := strconv.parse_f32(value)
			if !cutoff_ok {
				report_error(problems, a.path, l.number, 0, "cutoff is a number")
				decl.ok = false
			}
			decl.cutoff = cutoff
			cutoff_line = l.number
		case "transparency":
			switch value {
			case "moments":
				decl.sorted = false
			case "sorted":
				decl.sorted = true
			case:
				report_error(problems, a.path, l.number, 0, "transparency is moments or sorted")
				decl.ok = false
			}
			transparency_line = l.number
		case "geometry":
			geometry_line = l.number
			decl.patches, decl.billboard, decl.ribbon = false, .None, false
			switch value {
			case "mesh":
			case "patches":
				decl.patches = true
			case "billboard":
				decl.billboard = .Camera
			case "billboard_axis":
				decl.billboard = .Axis
			case "ribbon":
				decl.ribbon = true
			case:
				report_error(problems, a.path, l.number, 0, "geometry is mesh, patches, billboard, billboard_axis or ribbon")
				decl.ok = false
			}
		case "displacement_bound":
			bound, bound_ok := strconv.parse_f32(value)
			if !bound_ok || bound < 0 {
				report_error(problems, a.path, l.number, 0, "displacement_bound is a number of meters, 0 or more")
				decl.ok = false
			}
			decl.displacement_bound = bound
		case "tool_texture":
			guid, _, message := parse_texture(value, kinds)
			if message != "" || guid == {} {
				report_error(problems, a.path, l.number, 0, "tool_texture is a texture's GUID after $")
				decl.ok = false
			}
			decl.tool_texture = guid
		case "two_sided", "cast_shadows":
			if value != "true" && value != "false" {
				report_error(problems, a.path, l.number, 0, "%s is true or false", key)
				decl.ok = false
			}
			if key == "two_sided" {
				decl.two_sided = value == "true"
			} else {
				decl.cast_shadows = value == "true"
			}
		case:
			report_error(problems, a.path, l.number, 0, "%q is not a material setting", key)
			decl.ok = false
		}
	}
	// The settings can come in any order, so the blend is known only now.
	if cutoff_line != 0 && format.material_transparent(decl.blend) {
		report_error(problems, a.path, cutoff_line, 0, "cutoff is for masked materials; a transparent one blends by its opacity")
		decl.ok = false
	}
	if decl.ribbon && !format.material_transparent(decl.blend) {
		report_error(problems, a.path, geometry_line, 0, "a ribbon material's blend is transparent or additive")
		decl.ok = false
	}
	if transparency_line != 0 && decl.blend != .Transparent {
		report_error(problems, a.path, transparency_line, 0, "transparency is for transparent materials")
		decl.ok = false
	}
	// Transparent surfaces cast no shadows: the shadow maps hold only depth (see docs/rendering/transparency.md#transparency).
	if format.material_transparent(decl.blend) {
		decl.cast_shadows = false
	}
	if decl.shading == "" {
		report_error(problems, a.path, 0, 0, "a material names its shading model, such as `shading = lit`")
		decl.ok = false
	}
	switch {
	case has_body && len(decl.graph.nodes) > 0:
		report_error(problems, a.path, 0, 0, "a material defines evaluate with nodes or in HLSL after a `---` line, not both")
		decl.ok = false
	case !has_body && len(decl.graph.nodes) == 0:
		report_error(problems, a.path, 0, 0, "a material defines evaluate with nodes, or in HLSL after a `---` line")
		decl.ok = false
	case !has_body:
		decl.ok = graph_check(&decl.graph, a.path, .Material, decl.params[:], decl.switches[:], problems) && decl.ok
	}
	return
}

// set_param sets a parameter's value from its text, and gives a message if the text does not fit its type.
@(private = "file")
set_param :: proc(p: ^Param_Decl, text: string, kinds: map[format.Guid]format.Asset_Kind) -> string {
	if p.type == .Texture {
		guid, default, message := parse_texture(text, kinds)
		p.texture, p.texture_default = guid, default
		return message
	}
	want := param_count(p.type)
	values, count, ok := parse_numbers(text)
	if !ok || count != want {
		return fmt.tprintf("%s takes %d numbers, not %q", p.name, want, text)
	}
	p.value = values
	return ""
}

param_count :: proc(type: format.Material_Param_Type) -> int {
	switch type {
	case .Float, .Texture:
		return 1
	case .Float2:
		return 2
	case .Float3:
		return 3
	case .Float4, .Color:
		return 4
	}
	return 0
}

parse_instance :: proc(a: Asset_Source, index: int, problems: ^Problems) -> (decl: Instance_Decl) {
	decl = {asset = index, overrides = make([dynamic]Override, context.temp_allocator), ok = true}
	lines, _, _, _ := decl_lines(string(a.source))
	if len(lines) == 0 || lines[0].text != "material_instance 1" {
		report_error(problems, a.path, 1, 0, "a material instance starts with `material_instance 1`")
		decl.ok = false
		return
	}
	for l in lines[1:] {
		key, _, value := strings.partition(l.text, "=")
		key, value = strings.trim_space(key), strings.trim_space(value)
		if key == "parent" {
			parent, parent_ok := format.guid_parse(strings.trim_prefix(value, "$"))
			if !parent_ok || !strings.has_prefix(value, "$") {
				report_error(problems, a.path, l.number, 0, "parent is a material's or an instance's GUID after $")
				decl.ok = false
			}
			decl.parent = parent
			continue
		}
		if key == "tool_texture" {
			guid, guid_ok := format.guid_parse(strings.trim_prefix(value, "$"))
			if !guid_ok || !strings.has_prefix(value, "$") {
				report_error(problems, a.path, l.number, 0, "tool_texture is a texture's GUID after $")
				decl.ok = false
			}
			decl.tool_texture = guid
			continue
		}
		append(&decl.overrides, Override{key, value, l.number})
	}
	if decl.parent == {} && decl.ok {
		report_error(problems, a.path, 0, 0, "a material instance names its parent, as `parent = $<GUID>`")
		decl.ok = false
	}
	return
}

// resolve resolves a material or an instance through its parents to its material, and applies each instance's
// overrides, from the material down.
@(private = "file")
resolve :: proc(
	assets: []Asset_Source,
	guid: format.Guid,
	materials: map[format.Guid]^Material_Decl,
	instances: map[format.Guid]^Instance_Decl,
	kinds: map[format.Guid]format.Asset_Kind,
	problems: ^Problems,
) -> (
	r: Resolved,
) {
	r.chain = make([dynamic][]byte, context.temp_allocator)
	path := make([dynamic]^Instance_Decl, context.temp_allocator)
	current := guid
	for {
		if decl, is_material := materials[current]; is_material {
			r.material = decl
			break
		}
		decl, is_instance := instances[current]
		if !is_instance {
			if len(path) > 0 {
				buffer: [32]u8
				report_error(problems, assets[path[len(path) - 1].asset].path, 0, 0, "its parent %s is not a material or an instance", format.guid_format(current, &buffer))
			}
			return
		}
		for seen in path {
			if seen == decl {
				report_error(problems, assets[decl.asset].path, 0, 0, "its parents loop back to it")
				return
			}
		}
		append(&path, decl)
		if !decl.ok {
			return
		}
		current = decl.parent
	}
	m := r.material
	append(&r.chain, assets[m.asset].source)
	for s, i in m.switches {
		if s.default {
			r.switches |= 1 << u32(i)
		}
	}
	r.params = slice.clone(m.params[:], context.temp_allocator)
	r.ok = m.ok
	r.tool_texture = m.tool_texture
	// The material's parameters, then each instance's overrides, from the one nearest the material.
	#reverse for decl in path {
		a := assets[decl.asset]
		append(&r.chain, a.source)
		if decl.tool_texture != {} {
			r.tool_texture = decl.tool_texture
		}
		for o in decl.overrides {
			if switch_index, found := find_switch(m, o.name); found {
				if o.value != "true" && o.value != "false" {
					report_error(problems, a.path, o.line, 0, "the switch %s is true or false", o.name)
					r.ok = false
				} else if o.value == "true" {
					r.switches |= 1 << u32(switch_index)
				} else {
					r.switches &~= 1 << u32(switch_index)
				}
				continue
			}
			found := false
			for &p in r.params {
				if p.name == o.name {
					found = true
					if message := set_param(&p, o.value, kinds); message != "" {
						report_error(problems, a.path, o.line, 0, "%s", message)
						r.ok = false
					}
				}
			}
			if !found {
				report_error(problems, a.path, o.line, 0, "its material has no parameter or switch named %s", o.name)
				r.ok = false
			}
		}
	}
	if r.tool_texture == {} {
		r.tool_texture = sampled_texture(m, r.params)
	}
	return
}

// sampled_texture is the texture that a material's first texture sample node names, through its parameter, or its
// first texture parameter for a material in HLSL, with the parameters' values as an instance resolves them. Zero for
// a material that samples nothing.
@(private = "file")
sampled_texture :: proc(m: ^Material_Decl, params: []Param_Decl) -> format.Guid {
	param_texture :: proc(params: []Param_Decl, name: string) -> format.Guid {
		for p in params {
			if p.name == name && p.type == .Texture {
				return p.texture
			}
		}
		return {}
	}
	for n in m.graph.nodes {
		if n.kind == nil || n.kind.name != "texture_sample" {
			continue
		}
		for f in n.fields {
			if f.name != "texture" || f.value.kind != .Link {
				continue
			}
			if index, linked := m.graph.ids[f.value.node]; linked {
				for g in m.graph.nodes[index].fields {
					if g.name == "name" && g.value.kind == .Text {
						return param_texture(params, g.value.text)
					}
				}
			}
		}
	}
	for p in params {
		if p.type == .Texture {
			return p.texture
		}
	}
	return {}
}

@(private = "file")
find_switch :: proc(m: ^Material_Decl, name: string) -> (index: int, found: bool) {
	for s, i in m.switches {
		if s.name == name {
			return i, true
		}
	}
	return
}

// Block_Layout is where each parameter goes in a parameter block, packed at 4 bytes, as a raw buffer's Load packs the
// generated Params struct.
@(private = "file")
Block_Layout :: struct {
	offsets: []u32,
	size:    u32,
}

@(private = "file")
block_layout :: proc(params: []Param_Decl) -> (l: Block_Layout) {
	l.offsets = make([]u32, len(params), context.temp_allocator)
	for p, i in params {
		l.offsets[i] = l.size
		l.size += u32(param_count(p.type) * 4)
	}
	// Blocks start at 16 bytes in the material table.
	l.size = max((l.size + 15) &~ 15, 16)
	return
}

// encode_block writes the parameters' values into a block, with each texture's index 0, which the runtime writes, and
// gives the textures.
@(private = "file")
encode_block :: proc(params: []Param_Decl, l: Block_Layout) -> (block: []byte, textures: []format.Material_Texture) {
	block = make([]byte, l.size, context.temp_allocator)
	list := make([dynamic]format.Material_Texture, context.temp_allocator)
	for p, i in params {
		if p.type == .Texture {
			append(&list, format.Material_Texture{l.offsets[i], p.texture_default, p.texture})
			continue
		}
		for c in 0 ..< param_count(p.type) {
			value := f32(p.value[c])
			mem.copy(&block[l.offsets[i] + u32(c * 4)], &value, 4)
		}
	}
	return block, list[:]
}

@(private = "file")
hlsl_type :: proc(type: format.Material_Param_Type) -> string {
	switch type {
	case .Float:
		return "float"
	case .Float2:
		return "float2"
	case .Float3:
		return "float3"
	case .Float4, .Color:
		return "float4"
	case .Texture:
		return "uint"
	}
	return "float"
}

// generate_source is the HLSL of one variant: the settings and switches as defines, the shading model's Surface and
// its implementation, the Params struct, the material's evaluate, and the templates of every pass, which compile by
// their entry points (see material_passes.hlsli). A graph's evaluate has a #line before each node, and HLSL after a
// `---` line one before it, so DXC's messages name the material's own lines. It also gives whether evaluate reads the
// frame's time.
@(private = "file")
generate_source :: proc(
	a: Asset_Source,
	decl: ^Material_Decl,
	shading: ^Shading_Decl,
	set: Material_Set,
	switches: u32,
	problems: ^Problems,
) -> (
	source: string,
	reads_time: bool,
	displaces: bool,
	ok: bool,
) {
	// A material displaces its vertices when its HLSL defines displace, or its graph has a vertex_output node.
	if decl.has_body {
		displaces = contains_word(decl.body, "displace")
	} else {
		for n in decl.graph.nodes {
			displaces ||= n.kind.name == "vertex_output"
		}
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "// Generated by tools/cook from %s, switches %x. See docs/content/kinds/materials.md#materials.", a.name, switches)
	fmt.sbprintfln(&b, "#define MATERIAL_TWO_SIDED %d", int(decl.two_sided))
	fmt.sbprintfln(&b, "#define MATERIAL_DISPLACES %d", int(displaces))
	fmt.sbprintfln(&b, "#define MATERIAL_PATCHES %d", int(decl.patches))
	fmt.sbprintfln(&b, "#define MATERIAL_BILLBOARD %d", int(decl.billboard))
	fmt.sbprintfln(&b, "#define MATERIAL_RIBBON %d", int(decl.ribbon))
	fmt.sbprintfln(&b, "#define MATERIAL_MASKED %d", int(decl.blend == .Masked))
	fmt.sbprintfln(&b, "#define MATERIAL_TRANSPARENT %d", int(format.material_transparent(decl.blend)))
	fmt.sbprintfln(&b, "#define MATERIAL_ADDITIVE %d", int(decl.blend == .Additive))
	fmt.sbprintfln(&b, "#define MATERIAL_CUTOFF %f", decl.cutoff)
	fmt.sbprintfln(&b, "#define SHADING_NO_LIGHTING %d", int(shading.no_lighting))
	has_normal, has_base_color := false, false
	for input in shading.inputs {
		has_normal ||= input.name == "normal" && input.type == "float3"
		has_base_color ||= input.name == "base_color" && input.type == "float3"
	}
	fmt.sbprintfln(&b, "#define SHADING_HAS_NORMAL %d", int(has_normal))
	fmt.sbprintfln(&b, "#define SHADING_HAS_BASE_COLOR %d", int(has_base_color))
	for s, i in decl.switches {
		fmt.sbprintfln(&b, "#define %s %d", s.name, (switches >> u32(i)) & 1)
	}
	strings.write_string(&b, "#include \"material_common.hlsli\"\n\nstruct Surface {\n")
	for input in shading.inputs {
		fmt.sbprintfln(&b, "\t%s %s;", input.type, input.name)
	}
	strings.write_string(&b, "};\n\nSurface default_surface() {\n\tSurface s;\n")
	for input in shading.inputs {
		values := make([]string, input.count, context.temp_allocator)
		for &v, c in values {
			v = fmt.tprintf("%f", input.default[c])
		}
		fmt.sbprintfln(&b, "\ts.%s = %s(%s);", input.name, input.type, strings.join(values, ", ", context.temp_allocator))
	}
	strings.write_string(&b, "\treturn s;\n}\n\n")
	fmt.sbprintfln(&b, "#include \"%s\"\n", shading.implementation)
	strings.write_string(&b, "struct Params {\n")
	for p in decl.params {
		fmt.sbprintfln(&b, "\t%s %s;", hlsl_type(p.type), p.name)
	}
	if len(decl.params) == 0 {
		strings.write_string(&b, "\tuint unused;\n")
	}
	strings.write_string(&b, "};\nstatic Params params;\n\n")
	if decl.has_body {
		fmt.sbprintfln(&b, "#line %d \"%s\"", decl.body_line, a.path)
		strings.write_string(&b, decl.body)
		// frame.time, inputs.time or v.time.
		reads_time = contains_word(decl.body, "time")
	} else {
		gen := Generator {
			params    = decl.params[:],
			switches  = decl.switches[:],
			mask      = switches,
			shading   = shading,
			functions = set.functions,
			problems  = problems,
		}
		evaluate, displace := generate_evaluate(&gen, &decl.graph, a.path)
		if !gen.ok {
			return
		}
		strings.write_string(&b, strings.to_string(gen.globals))
		strings.write_string(&b, evaluate)
		if displaces {
			strings.write_string(&b, "\n")
			strings.write_string(&b, displace)
		}
		reads_time = gen.reads_time
	}
	strings.write_string(&b, "\n#include \"material_passes.hlsli\"\n")
	return strings.to_string(b), reads_time, displaces, true
}

@(private = "file")
Material_Entry :: struct {
	pass:   format.Material_Pass,
	target: Target,
}

// material_entries are the entry points that each variant compiles, the main pass's first. A masked material's
// depth pass discards in a pixel shader; an opaque one's has none. The opaque passes of a material of meshes have the
// mesh shader path's entries too, an amplification and a mesh shader each, and the impostor path's, which a
// billboard has neither of (see docs/rendering/materials.md#permutations). A transparent or
// additive material has no prepass, forward or depth pass, but the transparent passes; a Transparent one has moments
// too, which a sorted one draws only in the overdraw debug view.
@(private = "file")
material_entries :: proc(decl: ^Material_Decl) -> []Material_Entry {
	entries := make([dynamic]Material_Entry, context.temp_allocator)
	if format.material_transparent(decl.blend) {
		append(
			&entries,
			Material_Entry{.Transparent, {.Vertex, "vs_" + SHADER_MODEL, "vs_forward"}},
			Material_Entry{.Transparent, {.Pixel, "ps_" + SHADER_MODEL, "ps_transparent"}},
			Material_Entry{.Transparent_Ids, {.Vertex, "vs_" + SHADER_MODEL, "vs_forward"}},
			Material_Entry{.Transparent_Ids, {.Pixel, "ps_" + SHADER_MODEL, "ps_transparent_ids"}},
		)
		if decl.blend == .Transparent {
			append(
				&entries,
				Material_Entry{.Moments, {.Vertex, "vs_" + SHADER_MODEL, "vs_forward"}},
				Material_Entry{.Moments, {.Pixel, "ps_" + SHADER_MODEL, "ps_moments"}},
			)
		}
		return entries[:]
	}
	append(
		&entries,
		Material_Entry{.Forward, {.Vertex, "vs_" + SHADER_MODEL, "vs_forward"}},
		Material_Entry{.Forward, {.Pixel, "ps_" + SHADER_MODEL, "ps_forward"}},
		Material_Entry{.Prepass, {.Vertex, "vs_" + SHADER_MODEL, "vs_prepass"}},
		Material_Entry{.Prepass, {.Pixel, "ps_" + SHADER_MODEL, "ps_prepass"}},
		Material_Entry{.Depth, {.Vertex, "vs_" + SHADER_MODEL, "vs_depth"}},
	)
	if decl.blend == .Masked {
		append(&entries, Material_Entry{.Depth, {.Pixel, "ps_" + SHADER_MODEL, "ps_depth"}})
	}
	// A patches material has no meshlets to draw, and a billboard draws its own quads.
	if !decl.patches && decl.billboard == .None {
		append(
			&entries,
			Material_Entry{.Forward, {.Amplification, "as_" + SHADER_MODEL, "as_cluster"}},
			Material_Entry{.Forward, {.Mesh, "ms_" + SHADER_MODEL, "ms_forward"}},
			Material_Entry{.Prepass, {.Amplification, "as_" + SHADER_MODEL, "as_cluster"}},
			Material_Entry{.Prepass, {.Mesh, "ms_" + SHADER_MODEL, "ms_prepass"}},
			Material_Entry{.Depth, {.Amplification, "as_" + SHADER_MODEL, "as_cluster"}},
			Material_Entry{.Depth, {.Mesh, "ms_" + SHADER_MODEL, "ms_depth"}},
			Material_Entry{.Impostor_Forward, {.Vertex, "vs_" + SHADER_MODEL, "vs_impostor_forward"}},
			Material_Entry{.Impostor_Forward, {.Pixel, "ps_" + SHADER_MODEL, "ps_impostor_forward"}},
			Material_Entry{.Impostor_Prepass, {.Vertex, "vs_" + SHADER_MODEL, "vs_impostor_prepass"}},
			Material_Entry{.Impostor_Prepass, {.Pixel, "ps_" + SHADER_MODEL, "ps_impostor_prepass"}},
			Material_Entry{.Impostor_Depth, {.Vertex, "vs_" + SHADER_MODEL, "vs_impostor_depth"}},
			Material_Entry{.Impostor_Depth, {.Pixel, "ps_" + SHADER_MODEL, "ps_impostor_depth"}},
		)
	}
	return entries[:]
}

// compile_source compiles a generated source's entries, the main pass's first: an error in evaluate fails it, and
// the other passes would only fail the same way. The source's name is its hash, which covers the files that it
// includes, DXC and the configuration, so a source compiles once in a pass, and its bytecode stays in the cache's
// generated directory for later passes and previews.
@(private = "file")
compile_source :: proc(
	options: Cook_Options,
	a: Asset_Source,
	source: string,
	hash: u64,
	entries: []Material_Entry,
	out_dir: string,
	pass: ^Pass,
) -> (
	codes: [][]byte,
	ok: bool,
) {
	if pass.compiled == nil {
		pass.compiled = make(map[u64][][]byte, context.temp_allocator)
	}
	if found, seen := pass.compiled[hash]; seen && len(found) == len(entries) {
		return found, true
	}
	path := fmt.tprintf("%s/generated/%016x.hlsl", out_dir, hash)
	codes = make([][]byte, len(entries), context.temp_allocator)
	cached := true
	for entry, i in entries {
		data, err := os.read_entire_file(fmt.tprintf("%s.%v.%v.dxil", path, entry.pass, entry.target.stage), context.temp_allocator)
		cached &&= err == nil
		codes[i] = data
	}
	if !cached {
		if err := os.write_entire_file(path, transmute([]byte)source); err != nil {
			report_error(&pass.problems, a.path, 0, 0, "cannot write %s: %v", path, err)
			return
		}
		for entry, i in entries {
			output := fmt.tprintf("%s.%v.%v.dxil", path, entry.pass, entry.target.stage)
			code := compile_file(options, path, entry.target, fmt.tprintf("%s.tmp", output), &pass.problems, a.path) or_return
			if err := os.write_entire_file(output, code); err != nil {
				report_error(&pass.problems, a.path, 0, 0, "cannot write %s: %v", output, err)
				return
			}
			codes[i] = code
		}
	}
	pass.compiled[hash] = codes
	return codes, true
}

// cook_material generates and compiles the material's variants, and writes its blob to output if its key changed.
@(private = "file")
cook_material :: proc(
	options: Cook_Options,
	a: Asset_Source,
	guid: format.Guid,
	decl: ^Material_Decl,
	shading: ^Shading_Decl,
	set: Material_Set,
	switch_masks: []u32,
	output: string,
	pass: ^Pass,
) -> bool {
	problems := &pass.problems
	if options.dxc == "" {
		report_error(problems, a.path, 0, 0, "not cooked: the cooker has no --dxc to compile materials with")
		return false
	}
	out_dir := config_dir(options)
	sources := make([]string, len(switch_masks), context.temp_allocator)
	reads_time, displaces := false, false
	for mask, i in switch_masks {
		source, time, moves, generated := generate_source(a, decl, shading, set, mask, problems)
		if !generated {
			return false
		}
		sources[i] = source
		reads_time ||= time
		displaces ||= moves
	}
	// Every variant includes the same files.
	inputs, inputs_ok := gather_includes(fmt.tprintf("%s/generated/material.hlsl", out_dir), transmute([]byte)sources[0], options.includes[:], problems)
	if !inputs_ok {
		return false
	}
	inputs_hash := hash.fnv64a(transmute([]byte)fmt.tprintf("%s\x00%s\x00%v\x00", MATERIAL_COOK_VERSION, options.dxc_version, options.config))
	for input in inputs[1:] {
		inputs_hash = hash.fnv64a(transmute([]byte)input.path, inputs_hash)
		inputs_hash = hash.fnv64a(input.data, inputs_hash)
	}
	// The sources hold the declarations, the HLSL and the material functions that the graph calls; the source file
	// adds the parameters' values.
	key := hash.fnv64a(transmute([]byte)fmt.tprintf("%s\x00%x\x00%x\x00", a.name, format.material_layout(), inputs_hash))
	key = hash.fnv64a(transmute([]byte)a.meta_text, key)
	key = hash.fnv64a(a.source, key)
	for source in sources {
		key = hash.fnv64a(transmute([]byte)source, key)
	}
	if cooked_key(output, .Material, format.material_layout()) == key && !pass.force[guid] {
		pass.current[.Material] += 1
		return true
	}

	entries := material_entries(decl)
	variants := make([dynamic]format.Material_Variant_Entry, context.temp_allocator)
	for mask, i in switch_masks {
		codes := compile_source(options, a, sources[i], hash.fnv64a(transmute([]byte)sources[i], inputs_hash), entries, out_dir, pass) or_return
		for entry, e in entries {
			append(&variants, format.Material_Variant_Entry{mask, entry.pass, entry.target.stage, codes[e]})
		}
	}
	l := block_layout(decl.params[:])
	block, textures := encode_block(decl.params[:], l)
	params := make([]format.Material_Param_Entry, len(decl.params), context.temp_allocator)
	for p, i in decl.params {
		params[i] = {p.name, p.type, l.offsets[i]}
	}
	switch_names := make([]string, len(decl.switches), context.temp_allocator)
	default_switches: u32
	for s, i in decl.switches {
		switch_names[i] = s.name
		if s.default {
			default_switches |= 1 << u32(i)
		}
	}
	flags: format.Material_Flags
	if decl.two_sided {
		flags += {.Two_Sided}
	}
	if decl.cast_shadows {
		flags += {.Cast_Shadows}
	}
	if decl.sorted {
		flags += {.Sorted}
	}
	if shading.no_lighting {
		flags += {.No_Lighting}
	}
	if reads_time {
		flags += {.Reads_Time}
	}
	if displaces {
		flags += {.Displaces}
	}
	if decl.patches {
		flags += {.Patches}
	}
	switch decl.billboard {
	case .None:
	case .Camera:
		flags += {.Billboard}
	case .Axis:
		flags += {.Billboard, .Billboard_Axis}
	}
	if decl.ribbon {
		flags += {.Ribbon}
	}
	contents := format.Material_Contents {
		guid             = guid,
		key              = key,
		flags            = flags,
		blend            = decl.blend,
		cutoff           = decl.cutoff,
		displacement_bound = decl.displacement_bound,
		params           = params,
		switches         = switch_names,
		default_switches = default_switches,
		block            = block,
		textures         = textures,
		variants         = variants[:],
		source_path      = a.name,
	}
	if !write_blob(output, format.material_write(contents, context.temp_allocator)) {
		return false
	}
	pass.cooked[.Material] += 1
	return true
}

// cook_instance writes the instance's blob, with its values resolved, if its key changed.
@(private = "file")
cook_instance :: proc(options: Cook_Options, a: Asset_Source, guid: format.Guid, r: Resolved, assets: []Asset_Source, out_dir: string, pass: ^Pass) -> bool {
	key := hash.fnv64a(transmute([]byte)fmt.tprintf("%s\x00%v\x00%s\x00%x\x00", MATERIAL_COOK_VERSION, options.config, a.name, format.material_instance_layout()))
	key = hash.fnv64a(transmute([]byte)a.meta_text, key)
	for source in r.chain {
		key = hash.fnv64a(source, key)
	}
	buffer: [32]u8
	output := fmt.tprintf("%s/%s.blob", out_dir, format.guid_format(guid, &buffer))
	if cooked_key(output, .Material_Instance, format.material_instance_layout()) == key && !pass.force[guid] {
		pass.current[.Material_Instance] += 1
		return true
	}
	block, textures := encode_block(r.params, block_layout(r.params))
	contents := format.Material_Instance_Contents {
		guid        = guid,
		key         = key,
		material    = assets[r.material.asset].meta.guid,
		switches    = r.switches,
		block       = block,
		textures    = textures,
		source_path = a.name,
	}
	if !write_blob(output, format.material_instance_write(contents, context.temp_allocator)) {
		return false
	}
	pass.cooked[.Material_Instance] += 1
	return true
}
