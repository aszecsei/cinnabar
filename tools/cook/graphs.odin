// Material graphs (see docs/content/kinds/materials.md#material-graphs): the nodes of a .material or a .material_function
// file, the kinds of node, and the HLSL that the cooker generates from them. A material's graph becomes its evaluate,
// and each material function that it calls a function of its own. Each variant generates its source with its static
// switches decided, so a switch node keeps only the branch that its switch picks.
package cook

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

import cook_link "cinnabar:engine/asset/cook_link"
import format "cinnabar:engine/asset/format"

// The widths of values in a graph: 1 to 4 floats, or a texture's bindless index.
@(private = "file")
TEXTURE_WIDTH :: 5

Pin_Type :: cook_link.Pin_Type
Property_Kind :: cook_link.Property_Kind

Node_Pin :: struct {
	name:          string,
	type:          Pin_Type,
	default:       [4]f64,
	// For an input, the HLSL of a value that the shaders give, used when the input is not linked and has no value,
	// with its name for the editor. For an output, its HLSL, in which {a} is input a, {.p} property p, and {=o} this
	// node's earlier output o.
	code:          string,
	default_label: string,
}

Node_Property :: struct {
	name:    string,
	kind:    Property_Kind,
	choices: []string,
	default: string,
}

Node_Kind :: struct {
	name:        string,
	label:       string,
	category:    string,
	description: string,
	inputs:      []Node_Pin,
	outputs:     []Node_Pin,
	properties:  []Node_Property,
	pins_from:   cook_link.Node_Pins_From,
	scope:       cook_link.Node_Scope,
}

@(private = "file")
FLOATS :: []string{"float", "float2", "float3", "float4"}

// NODE_KINDS are the kinds of node, in the order that the editor lists them. The cook link sends them to the editor
// (see node_infos), so the cooker is the only place that knows them.
@(private = "file")
NODE_KINDS := []Node_Kind {
	{
		name = "output",
		label = "Surface",
		category = "Output",
		description = "The material's surface: an input for each input of its shading model. An input without a link or a value keeps the shading model's default.",
		pins_from = .Shading_Model,
		scope = .Material,
	},
	{
		name = "parameter",
		label = "Parameter",
		category = "Inputs",
		description = "One of the material's parameters, which instances override.",
		outputs = {{name = "value", type = .Any}},
		properties = {{name = "name", kind = .Parameter}},
		scope = .Material,
	},
	{name = "scalar", label = "Scalar", category = "Inputs", description = "A number.", outputs = {{name = "value", type = .Float, code = "{.value}"}}, properties = {{name = "value", kind = .Number, default = "0"}}},
	{name = "vector2", label = "Vector 2", category = "Inputs", description = "Two numbers.", outputs = {{name = "value", type = .Float2, code = "{.value}"}}, properties = {{name = "value", kind = .Vector2, default = "[0, 0]"}}},
	{name = "vector3", label = "Vector 3", category = "Inputs", description = "Three numbers.", outputs = {{name = "value", type = .Float3, code = "{.value}"}}, properties = {{name = "value", kind = .Vector3, default = "[0, 0, 0]"}}},
	{name = "vector4", label = "Vector 4", category = "Inputs", description = "Four numbers.", outputs = {{name = "value", type = .Float4, code = "{.value}"}}, properties = {{name = "value", kind = .Vector4, default = "[0, 0, 0, 0]"}}},
	{name = "color", label = "Color", category = "Inputs", description = "A linear color with alpha.", outputs = {{name = "value", type = .Float4, code = "{.value}"}}, properties = {{name = "value", kind = .Color, default = "[1, 1, 1, 1]"}}},
	{name = "uv", label = "UV", category = "Inputs", description = "A UV set of the mesh.", outputs = {{name = "uv", type = .Float2, code = "inputs.uv{.set}"}}, properties = {{name = "set", kind = .Choice, choices = {"0", "1"}, default = "0"}}},
	{name = "vertex_color", label = "Vertex Color", category = "Inputs", description = "The mesh's vertex color, or white.", outputs = {{name = "color", type = .Float4, code = "inputs.color"}}},
	{name = "position", label = "World Position", category = "Inputs", description = "The point's position in meters relative to the render origin, which snaps to a grid of 1024 m, so it stays put while the camera moves. A pattern whose period divides 1024 m has no seam when the origin moves.", outputs = {{name = "position", type = .Float3, code = "world_position(inputs)"}}},
	{name = "object_position", label = "Object Position", category = "Inputs", description = "The point's position in the mesh's own space, in meters, before its entity's pose, so a pattern moves, turns and scales with the object.", outputs = {{name = "position", type = .Float3, code = "inputs.object_position"}}},
	{name = "normal", label = "World Normal", category = "Inputs", description = "The mesh's normal in the world, before a normal map.", outputs = {{name = "normal", type = .Float3, code = "inputs.normal"}}},
	{name = "tangent", label = "World Tangent", category = "Inputs", description = "The mesh's tangent in the world, with the bitangent's sign in w.", outputs = {{name = "tangent", type = .Float4, code = "inputs.tangent"}}},
	{name = "view", label = "View Direction", category = "Inputs", description = "The direction from the point toward the camera.", outputs = {{name = "view", type = .Float3, code = "inputs.view"}}},
	{name = "time", label = "Time", category = "Inputs", description = "The frame's time in seconds, which wraps every hour.", outputs = {{name = "time", type = .Float, code = "frame.time"}}},
	{name = "front_facing", label = "Front Facing", category = "Inputs", description = "1 on the front of a face, and 0 on the back of a two-sided one.", outputs = {{name = "front", type = .Float, code = "(inputs.front_facing ? 1.0 : 0.0)"}}},
	{
		name = "texture_sample",
		label = "Texture Sample",
		category = "Textures",
		description = "Samples a texture parameter.",
		inputs = {{name = "texture", type = .Texture}, {name = "uv", type = .Float2, code = "inputs.uv0", default_label = "UV0"}},
		outputs = {
			{name = "rgba", type = .Float4, code = "cn_sample({texture}, {uv})"},
			{name = "rgb", type = .Float3, code = "{=rgba}.rgb"},
			{name = "r", type = .Float, code = "{=rgba}.r"},
			{name = "g", type = .Float, code = "{=rgba}.g"},
			{name = "b", type = .Float, code = "{=rgba}.b"},
			{name = "a", type = .Float, code = "{=rgba}.a"},
		},
	},
	{
		name = "normal_map",
		label = "Normal Map",
		category = "Textures",
		description = "Samples a two-channel normal map, and gives the tangent-space normal.",
		inputs = {{name = "texture", type = .Texture}, {name = "uv", type = .Float2, code = "inputs.uv0", default_label = "UV0"}},
		outputs = {{name = "normal", type = .Float3, code = "cn_normal_map({texture}, {uv})"}},
	},
	{
		name = "add",
		label = "Add",
		category = "Math",
		description = "a + b.",
		inputs = {{name = "a", type = .Any}, {name = "b", type = .Any}},
		outputs = {{name = "out", type = .Any, code = "{a} + {b}"}},
	},
	{
		name = "subtract",
		label = "Subtract",
		category = "Math",
		description = "a - b.",
		inputs = {{name = "a", type = .Any}, {name = "b", type = .Any}},
		outputs = {{name = "out", type = .Any, code = "{a} - {b}"}},
	},
	{
		name = "multiply",
		label = "Multiply",
		category = "Math",
		description = "a × b.",
		inputs = {{name = "a", type = .Any, default = {1, 1, 1, 1}}, {name = "b", type = .Any, default = {1, 1, 1, 1}}},
		outputs = {{name = "out", type = .Any, code = "{a} * {b}"}},
	},
	{
		name = "divide",
		label = "Divide",
		category = "Math",
		description = "a ÷ b.",
		inputs = {{name = "a", type = .Any, default = {1, 1, 1, 1}}, {name = "b", type = .Any, default = {1, 1, 1, 1}}},
		outputs = {{name = "out", type = .Any, code = "{a} / {b}"}},
	},
	{
		name = "min",
		label = "Min",
		category = "Math",
		description = "The smaller of a and b.",
		inputs = {{name = "a", type = .Any}, {name = "b", type = .Any}},
		outputs = {{name = "out", type = .Any, code = "min({a}, {b})"}},
	},
	{
		name = "max",
		label = "Max",
		category = "Math",
		description = "The larger of a and b.",
		inputs = {{name = "a", type = .Any}, {name = "b", type = .Any}},
		outputs = {{name = "out", type = .Any, code = "max({a}, {b})"}},
	},
	{
		name = "power",
		label = "Power",
		category = "Math",
		description = "a to the power b.",
		inputs = {{name = "a", type = .Any, default = {1, 1, 1, 1}}, {name = "b", type = .Any, default = {2, 2, 2, 2}}},
		outputs = {{name = "out", type = .Any, code = "pow({a}, {b})"}},
	},
	{
		name = "step",
		label = "Step",
		category = "Math",
		description = "1 where b ≥ a, and 0 elsewhere.",
		inputs = {{name = "a", type = .Any, default = {0.5, 0.5, 0.5, 0.5}}, {name = "b", type = .Any}},
		outputs = {{name = "out", type = .Any, code = "step({a}, {b})"}},
	},
	{
		name = "lerp",
		label = "Lerp",
		category = "Math",
		description = "From a at t = 0 to b at t = 1.",
		inputs = {{name = "a", type = .Any}, {name = "b", type = .Any, default = {1, 1, 1, 1}}, {name = "t", type = .Any, default = {0.5, 0.5, 0.5, 0.5}}},
		outputs = {{name = "out", type = .Any, code = "lerp({a}, {b}, {t})"}},
	},
	{
		name = "clamp",
		label = "Clamp",
		category = "Math",
		description = "x, kept between min and max.",
		inputs = {{name = "x", type = .Any}, {name = "min", type = .Any}, {name = "max", type = .Any, default = {1, 1, 1, 1}}},
		outputs = {{name = "out", type = .Any, code = "clamp({x}, {min}, {max})"}},
	},
	{
		name = "smoothstep",
		label = "Smoothstep",
		category = "Math",
		description = "0 below min, 1 above max, and a smooth curve between.",
		inputs = {{name = "min", type = .Any}, {name = "max", type = .Any, default = {1, 1, 1, 1}}, {name = "x", type = .Any}},
		outputs = {{name = "out", type = .Any, code = "smoothstep({min}, {max}, {x})"}},
	},
	{name = "saturate", label = "Saturate", category = "Math", description = "x, kept between 0 and 1.", inputs = {{name = "x", type = .Any}}, outputs = {{name = "out", type = .Any, code = "saturate({x})"}}},
	{name = "one_minus", label = "One Minus", category = "Math", description = "1 - x.", inputs = {{name = "x", type = .Any}}, outputs = {{name = "out", type = .Any, code = "1 - {x}"}}},
	{name = "negate", label = "Negate", category = "Math", description = "-x.", inputs = {{name = "x", type = .Any}}, outputs = {{name = "out", type = .Any, code = "-{x}"}}},
	{name = "abs", label = "Abs", category = "Math", description = "The absolute value of x.", inputs = {{name = "x", type = .Any}}, outputs = {{name = "out", type = .Any, code = "abs({x})"}}},
	{name = "sqrt", label = "Square Root", category = "Math", description = "The square root of x.", inputs = {{name = "x", type = .Any}}, outputs = {{name = "out", type = .Any, code = "sqrt({x})"}}},
	{name = "floor", label = "Floor", category = "Math", description = "x, rounded down.", inputs = {{name = "x", type = .Any}}, outputs = {{name = "out", type = .Any, code = "floor({x})"}}},
	{name = "ceil", label = "Ceil", category = "Math", description = "x, rounded up.", inputs = {{name = "x", type = .Any}}, outputs = {{name = "out", type = .Any, code = "ceil({x})"}}},
	{name = "frac", label = "Frac", category = "Math", description = "The part of x after the point.", inputs = {{name = "x", type = .Any}}, outputs = {{name = "out", type = .Any, code = "frac({x})"}}},
	{name = "sin", label = "Sin", category = "Math", description = "The sine of x, in radians.", inputs = {{name = "x", type = .Any}}, outputs = {{name = "out", type = .Any, code = "sin({x})"}}},
	{name = "cos", label = "Cos", category = "Math", description = "The cosine of x, in radians.", inputs = {{name = "x", type = .Any}}, outputs = {{name = "out", type = .Any, code = "cos({x})"}}},
	{name = "normalize", label = "Normalize", category = "Math", description = "x, scaled to a length of 1.", inputs = {{name = "x", type = .Any}}, outputs = {{name = "out", type = .Any, code = "normalize({x})"}}},
	{
		name = "dot",
		label = "Dot",
		category = "Vector",
		description = "The dot product of a and b.",
		inputs = {{name = "a", type = .Any}, {name = "b", type = .Any}},
		outputs = {{name = "out", type = .Float, code = "dot({a}, {b})"}},
	},
	{
		name = "cross",
		label = "Cross",
		category = "Vector",
		description = "The cross product of a and b.",
		inputs = {{name = "a", type = .Float3}, {name = "b", type = .Float3}},
		outputs = {{name = "out", type = .Float3, code = "cross({a}, {b})"}},
	},
	{name = "length", label = "Length", category = "Vector", description = "The length of x.", inputs = {{name = "x", type = .Any}}, outputs = {{name = "out", type = .Float, code = "length({x})"}}},
	{
		name = "distance",
		label = "Distance",
		category = "Vector",
		description = "The distance from a to b.",
		inputs = {{name = "a", type = .Any}, {name = "b", type = .Any}},
		outputs = {{name = "out", type = .Float, code = "distance({a}, {b})"}},
	},
	{
		name = "split",
		label = "Split",
		category = "Vector",
		description = "The components of x. Those that x does not have are 0.",
		inputs = {{name = "x", type = .Float4}},
		outputs = {{name = "x", type = .Float, code = "{x}.x"}, {name = "y", type = .Float, code = "{x}.y"}, {name = "z", type = .Float, code = "{x}.z"}, {name = "w", type = .Float, code = "{x}.w"}},
	},
	{
		name = "combine",
		label = "Combine",
		category = "Vector",
		description = "A vector of the components.",
		inputs = {{name = "x", type = .Float}, {name = "y", type = .Float}, {name = "z", type = .Float}, {name = "w", type = .Float}},
		outputs = {
			{name = "xy", type = .Float2, code = "float2({x}, {y})"},
			{name = "xyz", type = .Float3, code = "float3({x}, {y}, {z})"},
			{name = "xyzw", type = .Float4, code = "float4({x}, {y}, {z}, {w})"},
		},
	},
	{
		name = "fresnel",
		label = "Fresnel",
		category = "Vector",
		description = "1 where the surface is seen edge on, and 0 where it faces the camera, with a falloff.",
		inputs = {{name = "exponent", type = .Float, default = {5, 0, 0, 0}}, {name = "normal", type = .Float3, code = "inputs.normal", default_label = "World normal"}},
		outputs = {{name = "out", type = .Float, code = "pow(1 - saturate(dot(normalize({normal}), inputs.view)), {exponent})"}},
	},
	{
		name = "switch",
		label = "Static Switch",
		category = "Logic",
		description = "on or off, by one of the material's static switches. Each permutation keeps only the branch that it uses.",
		inputs = {{name = "on", type = .Any}, {name = "off", type = .Any}},
		outputs = {{name = "out", type = .Any}},
		properties = {{name = "switch", kind = .Switch}},
		scope = .Material,
	},
	{
		name = "custom",
		label = "Custom HLSL",
		category = "Advanced",
		description = "HLSL of a, b, c and d, which are float4, and inputs, the Material_Inputs: an expression, or a function's body that returns the value.",
		inputs = {{name = "a", type = .Float4}, {name = "b", type = .Float4}, {name = "c", type = .Float4}, {name = "d", type = .Float4}},
		outputs = {{name = "out", type = .Any}},
		properties = {{name = "type", kind = .Choice, choices = FLOATS, default = "float3"}, {name = "code", kind = .Code, default = "\"a.rgb\""}},
	},
	{
		name = "function",
		label = "Material Function",
		category = "Advanced",
		description = "Calls a material function, with its inputs and outputs.",
		properties = {{name = "function", kind = .Function}},
		pins_from = .Function,
	},
	{
		name = "function_input",
		label = "Function Input",
		category = "Function",
		description = "An input of the material function. A call that leaves it unlinked gives its default.",
		outputs = {{name = "value", type = .Any}},
		properties = {
			{name = "name", kind = .Text, default = "\"input\""},
			{name = "type", kind = .Choice, choices = {"float", "float2", "float3", "float4", "texture"}, default = "float3"},
			{name = "default", kind = .Vector4, default = "[0, 0, 0, 0]"},
		},
		scope = .Function,
	},
	{
		name = "function_output",
		label = "Function Output",
		category = "Function",
		description = "An output of the material function.",
		inputs = {{name = "value", type = .Any}},
		properties = {{name = "name", kind = .Text, default = "\"output\""}, {name = "type", kind = .Choice, choices = FLOATS, default = "float3"}},
		scope = .Function,
	},
}

find_node_kind :: proc(name: string) -> ^Node_Kind {
	for &k in NODE_KINDS {
		if k.name == name {
			return &k
		}
	}
	return nil
}

// node_infos are the kinds of node for the editor, in the temporary allocator.
node_infos :: proc() -> []cook_link.Node_Info {
	pins :: proc(list: []Node_Pin) -> []cook_link.Node_Pin {
		result := make([]cook_link.Node_Pin, len(list), context.temp_allocator)
		for p, i in list {
			result[i] = {p.name, p.type, {f32(p.default.x), f32(p.default.y), f32(p.default.z), f32(p.default.w)}, p.default_label}
		}
		return result
	}
	infos := make([]cook_link.Node_Info, len(NODE_KINDS), context.temp_allocator)
	for k, i in NODE_KINDS {
		properties := make([]cook_link.Node_Property, len(k.properties), context.temp_allocator)
		for p, j in k.properties {
			properties[j] = {p.name, p.kind, p.choices, p.default}
		}
		infos[i] = {k.name, k.label, k.category, k.description, pins(k.inputs), pins(k.outputs), properties, k.pins_from, k.scope}
	}
	return infos
}

Graph_Value_Kind :: enum {
	Numbers,
	Text,
	Word,
	Asset,
	Link,
}

// Graph_Value is a value in a node's block: a number or an array of up to four, a quoted string, a bare word, an
// asset's GUID after $, or a link to another node's output, @<node>.<output>.
Graph_Value :: struct {
	kind:    Graph_Value_Kind,
	numbers: [4]f64,
	count:   int,
	// Text: the string, unquoted. Word: the word. Link: the output's name.
	text:    string,
	guid:    format.Guid,
	node:    int,
}

Graph_Field :: struct {
	name:  string,
	value: Graph_Value,
	line:  int,
}

Graph_Node :: struct {
	id:     int,
	kind:   ^Node_Kind,
	line:   int,
	fields: [dynamic]Graph_Field,
}

Graph :: struct {
	nodes: [dynamic]Graph_Node,
	// Each node's index in nodes, by its ID.
	ids:   map[int]int,
}

// parse_graph_value reads a value of a node's block, and gives a message if it is not one.
parse_graph_value :: proc(text: string) -> (v: Graph_Value, message: string) {
	switch {
	case text == "":
		return {}, "a value follows the ="
	case text[0] == '"':
		unquoted, ok := unquote(text)
		if !ok {
			return {}, "a string is quoted, with \\\", \\\\, \\n and \\t"
		}
		return {kind = .Text, text = unquoted}, ""
	case text[0] == '$':
		guid, ok := format.guid_parse(text[1:])
		if !ok {
			return {}, "an asset is 32 hex digits after $"
		}
		return {kind = .Asset, guid = guid}, ""
	case text[0] == '@':
		node_text, _, output := strings.partition(text[1:], ".")
		node, ok := strconv.parse_int(node_text)
		if !ok || output == "" {
			return {}, "a link is @<node>.<output>, such as @3.rgb"
		}
		return {kind = .Link, node = node, text = output}, ""
	case text[0] == '[' || text[0] == '-' || text[0] == '.' || (text[0] >= '0' && text[0] <= '9'):
		numbers, count, ok := parse_numbers(text)
		if !ok {
			return {}, fmt.tprintf("%q is not a number or an array of up to four", text)
		}
		// A number is also a word, for a choice such as `set = 1`.
		return {kind = .Numbers, numbers = numbers, count = count, text = text}, ""
	case is_identifier(text):
		return {kind = .Word, text = text}, ""
	}
	return {}, fmt.tprintf("%q is not a value", text)
}

@(private = "file")
unquote :: proc(text: string) -> (result: string, ok: bool) {
	if len(text) < 2 || text[len(text) - 1] != '"' {
		return
	}
	b := strings.builder_make(context.temp_allocator)
	inner := text[1:len(text) - 1]
	for i := 0; i < len(inner); i += 1 {
		c := inner[i]
		switch c {
		case '"':
			return
		case '\\':
			i += 1
			if i == len(inner) {
				return
			}
			switch inner[i] {
			case '"', '\\':
				strings.write_byte(&b, inner[i])
			case 'n':
				strings.write_byte(&b, '\n')
			case 't':
				strings.write_byte(&b, '\t')
			case:
				return
			}
		case:
			strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b), true
}

// parse_numbers reads a number or an array of up to four, such as 0.5 or [1, 0, 0, 1].
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

// graph_node_start reads a node's first line, `node <id> <kind>`, and adds the node.
graph_node_start :: proc(g: ^Graph, rest: string, line: int, path: string, problems: ^Problems) -> (node: ^Graph_Node, ok: bool) {
	if g.nodes == nil {
		g.nodes = make([dynamic]Graph_Node, context.temp_allocator)
		g.ids = make(map[int]int, context.temp_allocator)
	}
	fields := strings.fields(rest, context.temp_allocator)
	id, id_ok := strconv.parse_int(fields[0] if len(fields) > 0 else "")
	if len(fields) != 2 || !id_ok || id <= 0 {
		report_error(problems, path, line, 0, "a node is `node <id> <kind>`, with an ID above 0")
		return
	}
	if _, taken := g.ids[id]; taken {
		report_error(problems, path, line, 0, "another node has the ID %d", id)
		return
	}
	kind := find_node_kind(fields[1])
	if kind == nil {
		report_error(problems, path, line, 0, "there is no kind of node named %s", fields[1])
		return
	}
	g.ids[id] = len(g.nodes)
	append(&g.nodes, Graph_Node{id = id, kind = kind, line = line, fields = make([dynamic]Graph_Field, context.temp_allocator)})
	return &g.nodes[len(g.nodes) - 1], true
}

// graph_node_field reads a line of a node's block, `<name> = <value>`. A field is an input, a property or the node's
// position in the editor, which the cooker does not read; graph_check checks the names.
graph_node_field :: proc(node: ^Graph_Node, text: string, line: int, path: string, problems: ^Problems) -> bool {
	key, _, value := strings.partition(text, "=")
	key, value = strings.trim_space(key), strings.trim_space(value)
	if !is_identifier(key) {
		report_error(problems, path, line, 0, "a node's line is `<input or property> = <value>`")
		return false
	}
	for f in node.fields {
		if f.name == key {
			report_error(problems, path, line, 0, "the node sets %s twice", key)
			return false
		}
	}
	v, message := parse_graph_value(value)
	if message != "" {
		report_error(problems, path, line, 0, "%s", message)
		return false
	}
	append(&node.fields, Graph_Field{key, v, line})
	return true
}

@(private = "file")
find_field :: proc(node: ^Graph_Node, name: string) -> ^Graph_Field {
	for &f in node.fields {
		if f.name == name {
			return &f
		}
	}
	return nil
}

@(private = "file")
find_pin :: proc(pins: []Node_Pin, name: string) -> (Node_Pin, bool) {
	for p in pins {
		if p.name == name {
			return p, true
		}
	}
	return {}, false
}

@(private = "file")
find_property :: proc(kind: ^Node_Kind, name: string) -> (Node_Property, bool) {
	for p in kind.properties {
		if p.name == name {
			return p, true
		}
	}
	return {}, false
}

// property gives a node's property, or its kind's default.
@(private = "file")
property :: proc(node: ^Graph_Node, name: string) -> Graph_Value {
	if f := find_field(node, name); f != nil {
		return f.value
	}
	p, _ := find_property(node.kind, name)
	v, _ := parse_graph_value(p.default)
	return v
}

// Function_Pin is an input or an output of a material function: its name, its width, and for an input, its default.
Function_Pin :: struct {
	name:    string,
	width:   int,
	default: [4]f64,
	node:    int,
}

// Function_Decl is a parsed .material_function file.
Function_Decl :: struct {
	asset:   int,
	guid:    format.Guid,
	path:    string,
	graph:   Graph,
	inputs:  [dynamic]Function_Pin,
	outputs: [dynamic]Function_Pin,
	ok:      bool,
}

@(private = "file")
type_width :: proc(name: string) -> int {
	switch name {
	case "float":
		return 1
	case "float2":
		return 2
	case "float3":
		return 3
	case "float4":
		return 4
	case "texture":
		return TEXTURE_WIDTH
	}
	return 0
}

@(private = "file")
pin_width :: proc(type: Pin_Type) -> int {
	switch type {
	case .Float:
		return 1
	case .Float2:
		return 2
	case .Float3:
		return 3
	case .Float4:
		return 4
	case .Texture:
		return TEXTURE_WIDTH
	case .Any:
		return 0
	}
	return 0
}

@(private = "file")
width_type :: proc(width: int) -> string {
	switch width {
	case 1:
		return "float"
	case 2:
		return "float2"
	case 3:
		return "float3"
	case 4:
		return "float4"
	}
	return "uint"
}

parse_function :: proc(a: Asset_Source, index: int, problems: ^Problems) -> (decl: Function_Decl) {
	decl = {
		asset   = index,
		guid    = a.meta.guid,
		path    = a.path,
		inputs  = make([dynamic]Function_Pin, context.temp_allocator),
		outputs = make([dynamic]Function_Pin, context.temp_allocator),
		ok      = true,
	}
	lines, _, _, _ := decl_lines(string(a.source))
	if len(lines) == 0 || lines[0].text != "material_function 1" {
		report_error(problems, a.path, 1, 0, "a material function starts with `material_function 1`")
		decl.ok = false
		return
	}
	node: ^Graph_Node
	for l in lines[1:] {
		word, _, rest := strings.partition(l.text, " ")
		switch {
		case l.indented && node != nil:
			decl.ok = graph_node_field(node, l.text, l.number, a.path, problems) && decl.ok
		case l.indented:
			report_error(problems, a.path, l.number, 0, "an indented line belongs to a node")
			decl.ok = false
		case word == "node":
			added, added_ok := graph_node_start(&decl.graph, rest, l.number, a.path, problems)
			node = added if added_ok else nil
			decl.ok &&= added_ok
		case:
			report_error(problems, a.path, l.number, 0, "a material function has only nodes, not %q", word)
			decl.ok = false
		}
	}
	decl.ok = graph_check(&decl.graph, a.path, .Function, nil, nil, problems) && decl.ok
	for &n, i in decl.graph.nodes {
		if n.kind.name != "function_input" && n.kind.name != "function_output" {
			continue
		}
		name := property(&n, "name").text
		width := type_width(property(&n, "type").text)
		list := &decl.inputs if n.kind.name == "function_input" else &decl.outputs
		if !is_identifier(name) {
			report_error(problems, a.path, n.line, 0, "%q is not a name for a function's input or output", name)
			decl.ok = false
			continue
		}
		for p in list {
			if p.name == name {
				report_error(problems, a.path, n.line, 0, "the function has two %ss named %s", n.kind.name == "function_input" ? "input" : "output", name)
				decl.ok = false
			}
		}
		append(list, Function_Pin{name, width, property(&n, "default").numbers, i})
	}
	if decl.ok && len(decl.outputs) == 0 {
		report_error(problems, a.path, 0, 0, "a material function has a function_output node")
		decl.ok = false
	}
	return
}

// graph_check checks what a graph's nodes can be checked for without the graphs that they link: each kind is in its
// scope, each field is an input, a property or the position, each property's value fits its kind, and each link names
// a node of the graph. A material's graph has one output node.
graph_check :: proc(
	g: ^Graph,
	path: string,
	scope: cook_link.Node_Scope,
	params: []Param_Decl,
	switches: []Switch_Decl,
	problems: ^Problems,
) -> bool {
	ok := true
	outputs := 0
	for &n in g.nodes {
		k := n.kind
		if k.scope != .Both && k.scope != scope {
			report_error(problems, path, n.line, 0, "a %s node is only in a %s", k.name, k.scope == .Material ? "material" : "material function")
			ok = false
			continue
		}
		outputs += int(k.name == "output")
		for f in n.fields {
			if f.name == "position" {
				if f.value.kind != .Numbers || f.value.count != 2 {
					report_error(problems, path, f.line, 0, "position is [x, y]")
					ok = false
				}
				continue
			}
			if f.value.kind == .Link {
				if _, linked := g.ids[f.value.node]; !linked {
					report_error(problems, path, f.line, 0, "%s links to node %d, which the graph does not have", f.name, f.value.node)
					ok = false
				}
			}
			if p, is_property := find_property(k, f.name); is_property {
				if message := check_property(p, f.value, params, switches); message != "" {
					report_error(problems, path, f.line, 0, "%s", message)
					ok = false
				}
				continue
			}
			if _, is_input := find_pin(k.inputs, f.name); is_input || k.pins_from != .Kind {
				if f.value.kind != .Link && f.value.kind != .Numbers {
					report_error(problems, path, f.line, 0, "the input %s takes a link or numbers", f.name)
					ok = false
				}
				continue
			}
			report_error(problems, path, f.line, 0, "a %s node has no input or property named %s", k.name, f.name)
			ok = false
		}
	}
	if scope == .Material && outputs != 1 {
		report_error(problems, path, 0, 0, "a material's graph has one output node, not %d", outputs)
		ok = false
	}
	return ok
}

@(private = "file")
check_property :: proc(p: Node_Property, v: Graph_Value, params: []Param_Decl, switches: []Switch_Decl) -> string {
	want_numbers := 0
	switch p.kind {
	case .Number:
		want_numbers = 1
	case .Vector2:
		want_numbers = 2
	case .Vector3:
		want_numbers = 3
	case .Vector4, .Color:
		want_numbers = 4
	case .Text, .Code:
		if v.kind != .Text {
			return fmt.tprintf("%s is a quoted string", p.name)
		}
	case .Choice:
		if (v.kind != .Word && v.kind != .Numbers) || !slice.contains(p.choices, v.text) {
			return fmt.tprintf("%s is %s", p.name, strings.join(p.choices, " or ", context.temp_allocator))
		}
	case .Parameter:
		if v.kind != .Text {
			return fmt.tprintf("%s is a parameter's name, quoted", p.name)
		}
		for param in params {
			if param.name == v.text {
				return ""
			}
		}
		return fmt.tprintf("the material has no parameter named %s", v.text)
	case .Switch:
		if v.kind != .Text {
			return fmt.tprintf("%s is a static switch's name, quoted", p.name)
		}
		for s in switches {
			if s.name == v.text {
				return ""
			}
		}
		return fmt.tprintf("the material has no static switch named %s", v.text)
	case .Function:
		if v.kind != .Asset {
			return fmt.tprintf("%s is a material function's GUID after $", p.name)
		}
	}
	if want_numbers > 0 && (v.kind != .Numbers || v.count != want_numbers) {
		return fmt.tprintf("%s takes %d numbers", p.name, want_numbers)
	}
	return ""
}

// Generator writes the HLSL of a material's graph and of the functions that it calls: globals, the functions that its
// custom and function nodes need, before evaluate.
Generator :: struct {
	params:     []Param_Decl,
	switches:   []Switch_Decl,
	mask:       u32,
	shading:    ^Shading_Decl,
	functions:  map[format.Guid]^Function_Decl,
	problems:   ^Problems,
	globals:    strings.Builder,
	// Each function's HLSL name once it is written, and the functions being written, which a call must not reach.
	written:    map[format.Guid]string,
	writing:    [dynamic]format.Guid,
	reads_time: bool,
	ok:         bool,
}

// Graph_Body is one graph as the generator writes it: evaluate, or a material function.
@(private = "file")
Graph_Body :: struct {
	gen:      ^Generator,
	g:        ^Graph,
	path:     string,
	// The prefix of the graph's global names, such as "mf3_" in a function.
	prefix:   string,
	function: ^Function_Decl,
	b:        strings.Builder,
	// Each node's state: 0 not seen, 1 being visited, 2 written, and its outputs' widths.
	state:    []u8,
	widths:   [][]int,
}

// generate_evaluate writes the evaluate of a material's graph for one combination of switches, and the functions that
// it needs before it, into globals and body.
generate_evaluate :: proc(gen: ^Generator, g: ^Graph, path: string) -> (body: string) {
	gen.ok = true
	gen.globals = strings.builder_make(context.temp_allocator)
	gen.written = make(map[format.Guid]string, context.temp_allocator)
	gen.writing = make([dynamic]format.Guid, context.temp_allocator)
	gb := new_body(gen, g, path, "", nil)
	strings.write_string(&gb.b, "Surface evaluate(Material_Inputs inputs) {\n\tSurface s = default_surface();\n")
	for &n, i in g.nodes {
		if n.kind.name == "output" {
			visit(gb, i)
		}
	}
	strings.write_string(&gb.b, "\treturn s;\n}\n")
	return strings.to_string(gb.b)
}

@(private = "file")
new_body :: proc(gen: ^Generator, g: ^Graph, path, prefix: string, function: ^Function_Decl) -> ^Graph_Body {
	gb := new(Graph_Body, context.temp_allocator)
	gb^ = {
		gen      = gen,
		g        = g,
		path     = path,
		prefix   = prefix,
		function = function,
		b        = strings.builder_make(context.temp_allocator),
		state    = make([]u8, len(g.nodes), context.temp_allocator),
		widths   = make([][]int, len(g.nodes), context.temp_allocator),
	}
	return gb
}

@(private = "file")
fail :: proc(gb: ^Graph_Body, line: int, text: string, args: ..any) {
	report_error(gb.gen.problems, gb.path, line, 0, text, ..args)
	gb.gen.ok = false
}

// float_text writes a number so that HLSL reads it back as the same float.
@(private = "file")
float_text :: proc(x: f64) -> string {
	text := fmt.tprintf("%v", f32(x))
	if !strings.contains_any(text, ".eEn") {
		text = fmt.tprintf("%s.0", text)
	}
	return text
}

// literal writes count numbers as a value of a width: a scalar for any width, and a vector made wider with zeros or
// narrower by its first components.
@(private = "file")
literal :: proc(numbers: [4]f64, count, width: int) -> string {
	if width == 1 {
		return float_text(numbers[0])
	}
	if count == 1 {
		return fmt.tprintf("(%s)%s", width_type(width), float_text(numbers[0]))
	}
	parts := make([]string, width, context.temp_allocator)
	for &p, i in parts {
		p = i < count ? float_text(numbers[i]) : "0.0"
	}
	return fmt.tprintf("%s(%s)", width_type(width), strings.join(parts, ", ", context.temp_allocator))
}

// convert gives an expression of one width as another: a scalar fills every component, a wider value keeps its first
// components, and a narrower one gets zeros.
@(private = "file")
convert :: proc(expr: string, from, to: int) -> string {
	switch {
	case from == to:
		return expr
	case from == 1:
		return fmt.tprintf("((%s)%s)", width_type(to), expr)
	case from > to:
		components := "xyzw"
		return fmt.tprintf("(%s).%s", expr, components[:to])
	}
	zeros := make([]string, to - from, context.temp_allocator)
	for &z in zeros {
		z = "0.0"
	}
	return fmt.tprintf("%s(%s, %s)", width_type(to), expr, strings.join(zeros, ", ", context.temp_allocator))
}

// Source is where an input's value comes from, and its width.
@(private = "file")
Source :: struct {
	expr:  string,
	width: int,
	// Not linked and without a value: the input's default, which fits any width.
	default: bool,
}

// source finds an input's value: the output that it links to, its own numbers, or its pin's default.
@(private = "file")
source :: proc(gb: ^Graph_Body, n: ^Graph_Node, pin: Node_Pin) -> (s: Source, ok: bool) {
	f := find_field(n, pin.name)
	if f == nil || f.value.kind != .Link {
		if f != nil {
			return {literal(f.value.numbers, f.value.count, f.value.count), f.value.count, false}, true
		}
		if pin.type == .Texture {
			fail(gb, n.line, "the %s node's %s input links to a texture parameter or a texture function input", n.kind.name, pin.name)
			return
		}
		if pin.code != "" {
			return {pin.code, pin_width(pin.type), false}, true
		}
		return {literal(pin.default, 1, 1), 1, true}, true
	}
	index := gb.g.ids[f.value.node]
	visit(gb, index) or_return
	from := &gb.g.nodes[index]
	output := -1
	for name, i in output_names(gb, from) {
		if name == f.value.text {
			output = i
		}
	}
	if output < 0 {
		fail(gb, f.line, "node %d has no output named %s", f.value.node, f.value.text)
		return
	}
	return {fmt.tprintf("n%d_%s", from.id, f.value.text), gb.widths[index][output], false}, true
}

// output_names are a node's outputs: its kind's, or for a function call, its function's.
@(private = "file")
output_names :: proc(gb: ^Graph_Body, n: ^Graph_Node) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	if n.kind.pins_from == .Function {
		if f, found := gb.gen.functions[property(n, "function").guid]; found {
			for o in f.outputs {
				append(&names, o.name)
			}
		}
		return names[:]
	}
	for o in n.kind.outputs {
		append(&names, o.name)
	}
	return names[:]
}

// input_expr is an input's value at a width. A texture fits only a texture input.
@(private = "file")
input_expr :: proc(gb: ^Graph_Body, n: ^Graph_Node, pin: Node_Pin, width: int) -> (expr: string, ok: bool) {
	s := source(gb, n, pin) or_return
	if (s.width == TEXTURE_WIDTH) != (width == TEXTURE_WIDTH) {
		fail(gb, n.line, "the %s node's %s input takes %s, not %s", n.kind.name, pin.name, width == TEXTURE_WIDTH ? "a texture" : "numbers", s.width == TEXTURE_WIDTH ? "a texture" : "numbers")
		return
	}
	if s.default {
		return literal(pin.default, width == TEXTURE_WIDTH ? 1 : width, width), true
	}
	return convert(s.expr, s.width, width), true
}

// line_directive makes DXC's messages about the HLSL that follows name the node's line of its file.
@(private = "file")
line_directive :: proc(gb: ^Graph_Body, line: int) {
	fmt.sbprintfln(&gb.b, "#line %d \"%s\"", max(line, 1), gb.path)
}

// visit writes a node after the nodes that its inputs link to, once. A node that a link reaches while it is being
// visited is in a loop.
@(private = "file")
visit :: proc(gb: ^Graph_Body, index: int) -> bool {
	switch gb.state[index] {
	case 1:
		fail(gb, gb.g.nodes[index].line, "node %d links back to itself through its inputs", gb.g.nodes[index].id)
		return false
	case 2:
		return gb.widths[index] != nil
	}
	gb.state[index] = 1
	defer gb.state[index] = 2
	n := &gb.g.nodes[index]
	switch n.kind.name {
	case "output":
		return write_output(gb, n)
	case "parameter":
		return write_parameter(gb, index)
	case "switch":
		return write_switch(gb, index)
	case "custom":
		return write_custom(gb, index)
	case "function":
		return write_call(gb, index)
	case "function_input":
		return write_function_input(gb, index)
	case "function_output":
		return write_function_output(gb, n)
	}
	return write_template(gb, index)
}

// write_template writes a node whose outputs are its kind's code. Its Any inputs take the widest of them, and so do
// its Any outputs.
@(private = "file")
write_template :: proc(gb: ^Graph_Body, index: int) -> bool {
	n := &gb.g.nodes[index]
	k := n.kind
	generic := 1
	for pin in k.inputs {
		if pin.type == .Any {
			s := source(gb, n, pin) or_return
			if s.width == TEXTURE_WIDTH {
				fail(gb, n.line, "the %s node's %s input takes numbers, not a texture", k.name, pin.name)
				return false
			}
			generic = max(generic, s.width)
		}
	}
	inputs := make(map[string]string, context.temp_allocator)
	for pin in k.inputs {
		width := pin.type == .Any ? generic : pin_width(pin.type)
		inputs[pin.name] = input_expr(gb, n, pin, width) or_return
	}
	if k.name == "time" {
		gb.gen.reads_time = true
	}
	line_directive(gb, n.line)
	widths := make([]int, len(k.outputs), context.temp_allocator)
	for out, i in k.outputs {
		widths[i] = out.type == .Any ? generic : pin_width(out.type)
		expr := expand(out.code, n, inputs)
		fmt.sbprintfln(&gb.b, "\t%s n%d_%s = %s;", width_type(widths[i]), n.id, out.name, expr)
	}
	gb.widths[index] = widths
	return true
}

// expand fills in an output's code: {a} is input a, {.p} property p, and {=o} the node's output o.
@(private = "file")
expand :: proc(code: string, n: ^Graph_Node, inputs: map[string]string) -> string {
	b := strings.builder_make(context.temp_allocator)
	rest := code
	for {
		open := strings.index_byte(rest, '{')
		if open < 0 {
			strings.write_string(&b, rest)
			break
		}
		close := strings.index_byte(rest[open:], '}')
		strings.write_string(&b, rest[:open])
		name := rest[open + 1:open + close]
		rest = rest[open + close + 1:]
		switch {
		case strings.has_prefix(name, "."):
			v := property(n, name[1:])
			p, _ := find_property(n.kind, name[1:])
			if v.kind == .Numbers && p.kind != .Choice {
				// A property's numbers keep their count: a Vector3 is a float3.
				strings.write_string(&b, literal(v.numbers, v.count, v.count))
			} else {
				strings.write_string(&b, v.text)
			}
		case strings.has_prefix(name, "="):
			fmt.sbprintf(&b, "n%d_%s", n.id, name[1:])
		case:
			fmt.sbprintf(&b, "(%s)", inputs[name])
		}
	}
	return strings.to_string(b)
}

@(private = "file")
write_output :: proc(gb: ^Graph_Body, n: ^Graph_Node) -> bool {
	shading := gb.gen.shading
	for f in n.fields {
		if f.name == "position" {
			continue
		}
		found := false
		for input in shading.inputs {
			found ||= input.name == f.name
		}
		if !found {
			fail(gb, f.line, "the shading model %s has no input named %s", shading.name, f.name)
		}
	}
	assignments := make([dynamic]string, context.temp_allocator)
	for input in shading.inputs {
		if find_field(n, input.name) == nil {
			continue
		}
		pin := Node_Pin {
			name    = input.name,
			type    = Pin_Type(input.count - 1),
			default = input.default,
		}
		expr := input_expr(gb, n, pin, input.count) or_continue
		append(&assignments, fmt.tprintf("\ts.%s = %s;", input.name, expr))
	}
	line_directive(gb, n.line)
	for a in assignments {
		fmt.sbprintln(&gb.b, a)
	}
	gb.widths[slice_index(gb, n)] = {}
	return true
}

@(private = "file")
slice_index :: proc(gb: ^Graph_Body, n: ^Graph_Node) -> int {
	return gb.g.ids[n.id]
}

@(private = "file")
write_parameter :: proc(gb: ^Graph_Body, index: int) -> bool {
	n := &gb.g.nodes[index]
	name := property(n, "name").text
	for p in gb.gen.params {
		if p.name != name {
			continue
		}
		width := p.type == .Texture ? TEXTURE_WIDTH : param_count(p.type)
		line_directive(gb, n.line)
		fmt.sbprintfln(&gb.b, "\t%s n%d_value = params.%s;", width_type(width), n.id, name)
		gb.widths[index] = slice.clone([]int{width}, context.temp_allocator)
		return true
	}
	fail(gb, n.line, "the material has no parameter named %s", name)
	return false
}

// write_switch keeps only the branch that the variant's switch picks.
@(private = "file")
write_switch :: proc(gb: ^Graph_Body, index: int) -> bool {
	n := &gb.g.nodes[index]
	name := property(n, "switch").text
	on := false
	for s, i in gb.gen.switches {
		if s.name == name {
			on = gb.gen.mask & (1 << u32(i)) != 0
		}
	}
	pin, _ := find_pin(n.kind.inputs, on ? "on" : "off")
	s := source(gb, n, pin) or_return
	width := s.default ? 1 : s.width
	expr := s.default ? literal(pin.default, 1, 1) : s.expr
	line_directive(gb, n.line)
	fmt.sbprintfln(&gb.b, "\t%s n%d_out = %s;", width_type(width), n.id, expr)
	gb.widths[index] = slice.clone([]int{width}, context.temp_allocator)
	return true
}

// write_custom writes a custom node's HLSL as a function of its own, among the globals: its code is the body when it
// returns, and otherwise the expression that the function returns.
@(private = "file")
write_custom :: proc(gb: ^Graph_Body, index: int) -> bool {
	n := &gb.g.nodes[index]
	width := type_width(property(n, "type").text)
	code := property(n, "code").text
	code_line := n.line
	if f := find_field(n, "code"); f != nil {
		code_line = f.line
	}
	args := make([dynamic]string, context.temp_allocator)
	for pin in n.kind.inputs {
		append(&args, input_expr(gb, n, pin, 4) or_return)
	}
	name := fmt.tprintf("%scustom%d", gb.prefix, n.id)
	body := code if contains_word(code, "return") else fmt.tprintf("return %s;", code)
	fmt.sbprintfln(&gb.gen.globals, "%s %s(float4 a, float4 b, float4 c, float4 d, Material_Inputs inputs) {{", width_type(width), name)
	fmt.sbprintfln(&gb.gen.globals, "#line %d \"%s\"", code_line, gb.path)
	fmt.sbprintfln(&gb.gen.globals, "%s\n}}", body)
	line_directive(gb, n.line)
	fmt.sbprintfln(&gb.b, "\t%s n%d_out = %s(%s, inputs);", width_type(width), n.id, name, strings.join(args[:], ", ", context.temp_allocator))
	gb.widths[index] = slice.clone([]int{width}, context.temp_allocator)
	return true
}

// write_call writes a material function among the globals, once, and calls it.
@(private = "file")
write_call :: proc(gb: ^Graph_Body, index: int) -> bool {
	n := &gb.g.nodes[index]
	guid := property(n, "function").guid
	f, found := gb.gen.functions[guid]
	if !found {
		buffer: [32]u8
		fail(gb, n.line, "%s is not a material function", format.guid_format(guid, &buffer))
		return false
	}
	if !f.ok {
		fail(gb, n.line, "the material function %s has errors", f.path)
		return false
	}
	for field in n.fields {
		known := field.name == "position" || field.name == "function"
		for p in f.inputs {
			known ||= p.name == field.name
		}
		if !known {
			fail(gb, field.line, "the material function %s has no input named %s", f.path, field.name)
		}
	}
	name := write_function(gb, f) or_return
	args := make([dynamic]string, context.temp_allocator)
	for p in f.inputs {
		pin := Node_Pin {
			name    = p.name,
			type    = p.width == TEXTURE_WIDTH ? .Texture : Pin_Type(p.width - 1),
			default = p.default,
		}
		if p.width == TEXTURE_WIDTH && find_field(n, p.name) == nil {
			fail(gb, n.line, "the material function's input %s is a texture, which a call must link", p.name)
			return false
		}
		s := source(gb, n, pin) or_return
		if s.default {
			// The function's own default, as its input node gives it.
			append(&args, literal(p.default, 4, p.width))
			continue
		}
		append(&args, input_expr(gb, n, pin, p.width) or_return)
	}
	append(&args, "inputs")
	line_directive(gb, n.line)
	widths := make([]int, len(f.outputs), context.temp_allocator)
	for o, i in f.outputs {
		widths[i] = o.width
		fmt.sbprintfln(&gb.b, "\t%s n%d_%s;", width_type(o.width), n.id, o.name)
		append(&args, fmt.tprintf("n%d_%s", n.id, o.name))
	}
	fmt.sbprintfln(&gb.b, "\t%s(%s);", name, strings.join(args[:], ", ", context.temp_allocator))
	gb.widths[index] = widths
	return true
}

// write_function writes a material function's HLSL among the globals, after the functions that it calls, and gives
// its name. Its inputs are parameters, then the Material_Inputs, then its outputs as out parameters.
@(private = "file")
write_function :: proc(gb: ^Graph_Body, f: ^Function_Decl) -> (name: string, ok: bool) {
	gen := gb.gen
	if written, done := gen.written[f.guid]; done {
		return written, true
	}
	if slice.contains(gen.writing[:], f.guid) {
		fail(gb, 0, "the material function %s calls itself through its nodes", f.path)
		return
	}
	append(&gen.writing, f.guid)
	defer pop(&gen.writing)
	name = fmt.tprintf("mf%d", len(gen.written))
	fb := new_body(gen, &f.graph, f.path, fmt.tprintf("%s_", name), f)
	for &n, i in f.graph.nodes {
		if n.kind.name == "function_output" {
			visit(fb, i)
		}
	}
	if !gen.ok {
		return
	}
	parameters := make([dynamic]string, context.temp_allocator)
	for p in f.inputs {
		append(&parameters, fmt.tprintf("%s in_%s", width_type(p.width), p.name))
	}
	append(&parameters, "Material_Inputs inputs")
	for p in f.outputs {
		append(&parameters, fmt.tprintf("out %s out_%s", width_type(p.width), p.name))
	}
	// A function that a later call reaches first is written first, because its body names only what is above it.
	fmt.sbprintfln(&gen.globals, "void %s(%s) {{", name, strings.join(parameters[:], ", ", context.temp_allocator))
	strings.write_string(&gen.globals, strings.to_string(fb.b))
	strings.write_string(&gen.globals, "}\n")
	gen.written[f.guid] = name
	return name, true
}

@(private = "file")
write_function_input :: proc(gb: ^Graph_Body, index: int) -> bool {
	n := &gb.g.nodes[index]
	width := type_width(property(n, "type").text)
	line_directive(gb, n.line)
	fmt.sbprintfln(&gb.b, "\t%s n%d_value = in_%s;", width_type(width), n.id, property(n, "name").text)
	gb.widths[index] = slice.clone([]int{width}, context.temp_allocator)
	return true
}

@(private = "file")
write_function_output :: proc(gb: ^Graph_Body, n: ^Graph_Node) -> bool {
	width := type_width(property(n, "type").text)
	expr := input_expr(gb, n, n.kind.inputs[0], width) or_return
	line_directive(gb, n.line)
	fmt.sbprintfln(&gb.b, "\tout_%s = %s;", property(n, "name").text, expr)
	gb.widths[slice_index(gb, n)] = {}
	return true
}
