// Shading models, materials and material instances (see docs/content-pipeline.md#materials). A shading model is a
// .shading declaration of its surface inputs, with its implementation in the .hlsli beside it. A material picks a
// shading model, declares its parameters and static switches, and defines evaluate in HLSL after a `---` line. The
// cooker generates a source for each combination of switches that the material or an instance uses, and compiles
// each with the engine's templates of every pass. An instance names its parent and overrides values; its blob holds the
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
MATERIAL_COOK_VERSION :: "materials 2"

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
	two_sided:    bool,
	cast_shadows: bool,
	params:       [dynamic]Param_Decl,
	switches:     [dynamic]Switch_Decl,
	// The HLSL after the `---` line, and the line of the file that it starts at.
	body:         string,
	body_line:    int,
	ok:           bool,
}

Override :: struct {
	name:  string,
	value: string,
	line:  int,
}

// Instance_Decl is a parsed .material_instance file.
Instance_Decl :: struct {
	asset:     int,
	parent:    format.Guid,
	overrides: [dynamic]Override,
	ok:        bool,
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
	ok:       bool,
}

// cook_materials checks the shading models, and cooks the materials and instances whose keys changed. A material
// cooks a variant for each combination of switches that it or an instance uses. It reports every failure, and returns
// false if any.
cook_materials :: proc(options: Cook_Options, assets: []Asset_Source, pass: ^Pass) -> bool {
	problems := &pass.problems
	ok := true
	shadings := make(map[string]^Shading_Decl, context.temp_allocator)
	for i in assets_of(assets, .Shading_Model) {
		decl := new(Shading_Decl, context.temp_allocator)
		decl^ = parse_shading(assets[i], i, problems)
		if previous, taken := shadings[decl.name]; taken {
			report_error(problems, assets[i].path, 0, 0, "a shading model named %s is also at %s", decl.name, assets[previous.asset].path)
			decl.ok, previous.ok = false, false
		}
		shadings[decl.name] = decl
		assets[i].failed = !decl.ok
		ok &&= decl.ok
	}
	kinds := make(map[format.Guid]format.Asset_Kind, len(assets), context.temp_allocator)
	for a in assets {
		kinds[a.meta.guid] = a.kind
	}
	materials := make(map[format.Guid]^Material_Decl, context.temp_allocator)
	for i in assets_of(assets, .Material) {
		decl := new(Material_Decl, context.temp_allocator)
		decl^ = parse_material(assets[i], i, kinds, problems)
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
		resolved[guid] = resolve(assets, guid, materials, instances, kinds, problems)
		add_variant(&variants, decl, resolved[guid].switches)
	}
	for guid in instances {
		r := resolve(assets, guid, materials, instances, kinds, problems)
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
		shading, found := shadings[decl.shading]
		if found {
			append(&a.dependencies, assets[shading.asset].meta.guid)
		}
		add_texture_dependencies(a, decl.params[:])
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
			list := variants[decl]
			slice.sort(list[:])
			a.failed = !cook_material(options, a^, guid, decl, shading, list[:], out_dir, pass)
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

// Lines reads a declaration's lines: their text without comments and blank lines, and their numbers from 1.
@(private = "file")
Decl_Line :: struct {
	text:   string,
	number: int,
}

@(private = "file")
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
		append(&result, Decl_Line{line, number})
	}
	return result[:], "", 0, false
}

@(private = "file")
is_identifier :: proc(name: string) -> bool {
	if name == "" || (name[0] >= '0' && name[0] <= '9') {
		return false
	}
	for c in transmute([]byte)name {
		if !(c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
			return false
		}
	}
	return true
}

// parse_numbers reads a number or an array of up to four, such as 0.5 or [1, 0, 0, 1].
@(private = "file")
parse_numbers :: proc(text: string) -> (values: [4]f64, count: int, ok: bool) {
	inner := text
	if strings.has_prefix(text, "[") {
		if !strings.has_suffix(text, "]") {
			return
		}
		inner = text[1:len(text) - 1]
	}
	parts := strings.split(inner, ",", context.temp_allocator)
	if len(parts) > 4 {
		return
	}
	for part, i in parts {
		values[i] = strconv.parse_f64(strings.trim_space(part)) or_return
	}
	return values, len(parts), true
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
		ok           = true,
	}
	lines, body, body_line, has_body := decl_lines(string(a.source), stop_at_body = true)
	if len(lines) == 0 || lines[0].text != "material 1" {
		report_error(problems, a.path, 1, 0, "a material starts with `material 1`")
		decl.ok = false
		return
	}
	if !has_body {
		report_error(problems, a.path, 0, 0, "a material's HLSL follows a `---` line, and defines evaluate")
		decl.ok = false
	}
	decl.body, decl.body_line = body, body_line
	names := make(map[string]bool, context.temp_allocator)
	for l in lines[1:] {
		word, _, rest := strings.partition(l.text, " ")
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
			case "transparent", "additive":
				report_error(problems, a.path, l.number, 0, "the %s blend comes with sorted transparent draws, which are not in yet", value)
				decl.ok = false
			case:
				report_error(problems, a.path, l.number, 0, "blend is opaque or masked")
				decl.ok = false
			}
		case "cutoff":
			cutoff, cutoff_ok := strconv.parse_f32(value)
			if !cutoff_ok {
				report_error(problems, a.path, l.number, 0, "cutoff is a number")
				decl.ok = false
			}
			decl.cutoff = cutoff
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
	if decl.shading == "" {
		report_error(problems, a.path, 0, 0, "a material names its shading model, such as `shading = lit`")
		decl.ok = false
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

@(private = "file")
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
	// The material's parameters, then each instance's overrides, from the one nearest the material.
	#reverse for decl in path {
		a := assets[decl.asset]
		append(&r.chain, a.source)
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
	return
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
// their entry points (see material_passes.hlsli). A #line before evaluate makes DXC's messages name the material's
// own lines.
@(private = "file")
generate_source :: proc(a: Asset_Source, decl: ^Material_Decl, shading: ^Shading_Decl, switches: u32) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "// Generated by tools/cook from %s, switches %x. See docs/content-pipeline.md#materials.", a.name, switches)
	fmt.sbprintfln(&b, "#define MATERIAL_TWO_SIDED %d", int(decl.two_sided))
	fmt.sbprintfln(&b, "#define MATERIAL_MASKED %d", int(decl.blend == .Masked))
	fmt.sbprintfln(&b, "#define MATERIAL_CUTOFF %f", decl.cutoff)
	fmt.sbprintfln(&b, "#define SHADING_NO_LIGHTING %d", int(shading.no_lighting))
	has_normal := false
	for input in shading.inputs {
		has_normal ||= input.name == "normal" && input.type == "float3"
	}
	fmt.sbprintfln(&b, "#define SHADING_HAS_NORMAL %d", int(has_normal))
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
	fmt.sbprintfln(&b, "#line %d \"%s\"", decl.body_line, a.path)
	strings.write_string(&b, decl.body)
	strings.write_string(&b, "\n#include \"material_passes.hlsli\"\n")
	return strings.to_string(b)
}

@(private = "file")
Material_Entry :: struct {
	pass:   format.Material_Pass,
	target: Target,
}

// material_entries are the entry points that each variant compiles, the forward pass's first. A masked material's
// depth pass discards in a pixel shader; an opaque one's has none.
@(private = "file")
material_entries :: proc(decl: ^Material_Decl) -> []Material_Entry {
	entries := make([dynamic]Material_Entry, context.temp_allocator)
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
	return entries[:]
}

// cook_material generates and compiles the material's variants, and writes its blob if its key changed.
@(private = "file")
cook_material :: proc(
	options: Cook_Options,
	a: Asset_Source,
	guid: format.Guid,
	decl: ^Material_Decl,
	shading: ^Shading_Decl,
	switch_masks: []u32,
	out_dir: string,
	pass: ^Pass,
) -> bool {
	problems := &pass.problems
	if options.dxc == "" {
		report_error(problems, a.path, 0, 0, "not cooked: the cooker has no --dxc to compile materials with")
		return false
	}
	buffer: [32]u8
	guid_text := format.guid_format(guid, &buffer)
	sources := make([]string, len(switch_masks), context.temp_allocator)
	paths := make([]string, len(switch_masks), context.temp_allocator)
	for mask, i in switch_masks {
		sources[i] = generate_source(a, decl, shading, mask)
		paths[i] = fmt.tprintf("%s/generated/%s_%x.hlsl", out_dir, guid_text, mask)
	}
	// Every variant includes the same files.
	inputs, inputs_ok := gather_includes(paths[0], transmute([]byte)sources[0], options.includes[:], problems)
	if !inputs_ok {
		return false
	}
	key := hash.fnv64a(
		transmute([]byte)fmt.tprintf("%s\x00%s\x00%v\x00%s\x00%x\x00", MATERIAL_COOK_VERSION, options.dxc_version, options.config, a.name, format.material_layout()),
	)
	key = hash.fnv64a(transmute([]byte)a.meta_text, key)
	for source in sources {
		key = hash.fnv64a(transmute([]byte)source, key)
	}
	for input in inputs[1:] {
		key = hash.fnv64a(transmute([]byte)input.path, key)
		key = hash.fnv64a(input.data, key)
	}
	output := fmt.tprintf("%s/%s.blob", out_dir, guid_text)
	if cooked_key(output, .Material, format.material_layout()) == key && !pass.force[guid] {
		pass.current[.Material] += 1
		return true
	}

	entries := make([dynamic]format.Material_Variant_Entry, context.temp_allocator)
	compiled := true
	for mask, i in switch_masks {
		if err := os.write_entire_file(paths[i], transmute([]byte)sources[i]); err != nil {
			report_error(problems, a.path, 0, 0, "cannot write %s: %v", paths[i], err)
			return false
		}
		// The forward pass first: an error in evaluate fails it, and the other passes would only fail the same way.
		variant: for entry in material_entries(decl) {
			temporary := fmt.tprintf("%s.%v.%v.dxil.tmp", paths[i], entry.pass, entry.target.stage)
			code, code_ok := compile_file(options, paths[i], entry.target, temporary, problems, a.path)
			if !code_ok {
				compiled = false
				break variant
			}
			append(&entries, format.Material_Variant_Entry{mask, entry.pass, entry.target.stage, code})
		}
	}
	if !compiled {
		return false
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
	if shading.no_lighting {
		flags += {.No_Lighting}
	}
	contents := format.Material_Contents {
		guid             = guid,
		key              = key,
		flags            = flags,
		blend            = decl.blend,
		cutoff           = decl.cutoff,
		params           = params,
		switches         = switch_names,
		default_switches = default_switches,
		block            = block,
		textures         = textures,
		variants         = entries[:],
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
