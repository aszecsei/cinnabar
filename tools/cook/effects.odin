package cook

import "core:fmt"
import "core:hash"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"

import format "cinnabar:engine/asset/format"

// Effects are .effect text files: emitters of particles, each with settings, modules and curves, which the renderer's
// simulation runs (see docs/content/kinds/effects.md#effects). The cooker parses one, bakes its curves to
// format.EFFECT_CURVE_SAMPLES samples and writes an Effect blob.
EFFECT_COOK_VERSION :: "effects 1"

// EFFECT_TEMPLATE is a new effect's text: one emitter of soft puffs that rise and fade.
EFFECT_TEMPLATE :: `effect 1

emitter puffs
	capacity = 256
	rate = 20
	lifetime = 2 3
	speed = 0.5 1
	shape = cone 0.1 20
	softness = 0.2
	curve color = 0:1,1,1,0 0.1:1,1,1,0.5 1:1,1,1,0
	curve size = 0:0.1 1:0.4
`

// Effect_Problem is an error in an effect's text, at a line from 1.
Effect_Problem :: struct {
	line:    int,
	message: string,
}

// Curve_Key is a key of a curve: a point of a particle's life, from 0 to 1, and the value there.
@(private = "file")
Curve_Key :: struct {
	t:     f32,
	value: [4]f32,
}

// An emitter's settings when its text does not give them.
@(private = "file")
DEFAULT_EMITTER :: format.Effect_Emitter {
	capacity = 256,
	rate     = 10,
	lifetime = {1, 1},
	speed    = {1, 1},
	flipbook = {1, 1},
}

// The value of each curve that an emitter does not give: white and opaque, 0.1 m, no emission.
@(private = "file")
DEFAULT_CURVES := [format.Effect_Curve][4]f32 {
	.Color    = {1, 1, 1, 1},
	.Size     = {0.1, 0, 0, 0},
	.Emission = {0, 0, 0, 0},
}

// The components that each curve's values have. A color may leave out its alpha, which is then 1.
@(private = "file")
CURVE_COMPONENTS := [format.Effect_Curve]int {
	.Color    = 4,
	.Size     = 1,
	.Emission = 3,
}

cook_effects :: proc(options: Cook_Options, assets: []Asset_Source, pass: ^Pass) -> bool {
	problems := &pass.problems
	out_dir := config_dir(options)
	effects := assets_of(assets, .Effect)
	if len(effects) > 0 {
		if err := os.make_directory_all(out_dir); err != nil && err != .Exist {
			report_error(problems, out_dir, 0, 0, "%v", err)
			return false
		}
	}
	ok := true
	for i in effects {
		if !cook_effect(&assets[i], out_dir, pass) {
			assets[i].failed = true
			ok = false
		}
	}
	return ok
}

@(private = "file")
cook_effect :: proc(a: ^Asset_Source, out_dir: string, pass: ^Pass) -> bool {
	problems := &pass.problems
	settings_ok := check_settings(a^, problems)
	emitters, parse_problems := effect_parse(string(a.source), context.temp_allocator)
	for p in parse_problems {
		report_error(problems, a.path, p.line, 0, "%s", p.message)
	}
	// An effect with errors keeps its old blob, so the running game keeps the last good version.
	if len(parse_problems) > 0 || !settings_ok {
		return false
	}
	key := hash.fnv64a(transmute([]byte)fmt.tprintf("%s\x00%s\x00%x\x00", EFFECT_COOK_VERSION, a.name, format.effect_layout()))
	key = hash.fnv64a(a.source, key)
	guid := a.meta.guid
	key = hash.fnv64a(guid[:], key)
	buffer: [32]u8
	output := fmt.tprintf("%s/%s.blob", out_dir, format.guid_format(guid, &buffer))
	if cooked_key(output, .Effect, format.effect_layout()) == key && !pass.force[guid] {
		pass.current[.Effect] += 1
		return true
	}
	for e in emitters {
		if e.emitter.texture != {} {
			append(&a.dependencies, e.emitter.texture)
		}
	}
	blob := format.effect_write({guid = guid, key = key, emitters = emitters, source_path = a.name}, context.temp_allocator)
	if !write_blob(output, blob) {
		return false
	}
	pass.cooked[.Effect] += 1
	return true
}

// effect_parse parses an effect's text into its emitters, with their curves baked. It gives every problem that it
// finds, and the effect is good only without any.
effect_parse :: proc(text: string, allocator := context.allocator) -> (emitters: []format.Effect_Emitter_Contents, problems: []Effect_Problem) {
	context.allocator = allocator
	result := make([dynamic]format.Effect_Emitter_Contents)
	found := make([dynamic]Effect_Problem)
	problem :: proc(found: ^[dynamic]Effect_Problem, line: int, f: string, args: ..any) {
		append(found, Effect_Problem{line, fmt.aprintf(f, ..args)})
	}
	modules := make([dynamic]format.Effect_Module)
	keys: [format.Effect_Curve][dynamic]Curve_Key
	header := false
	current := -1
	finish :: proc(e: ^format.Effect_Emitter_Contents, modules: ^[dynamic]format.Effect_Module, keys: ^[format.Effect_Curve][dynamic]Curve_Key) {
		e.modules = modules[:]
		for curve in format.Effect_Curve {
			e.curves[curve] = bake_curve(keys[curve][:], DEFAULT_CURVES[curve])
		}
	}
	lines := strings.split_lines(text)
	for raw, index in lines {
		line := index + 1
		trimmed := strings.trim_space(raw)
		if hash_at := strings.index_byte(trimmed, '#'); hash_at >= 0 {
			trimmed = strings.trim_space(trimmed[:hash_at])
		}
		if trimmed == "" {
			continue
		}
		indented := raw[0] == '\t' || raw[0] == ' '
		fields := strings.fields(trimmed)
		if !header {
			if !indented && len(fields) == 2 && fields[0] == "effect" && fields[1] == "1" {
				header = true
			} else {
				problem(&found, line, "an effect starts with `effect 1`")
				return result[:], found[:]
			}
			continue
		}
		if !indented {
			if len(fields) != 2 || fields[0] != "emitter" {
				problem(&found, line, "expected `emitter <name>`")
				continue
			}
			if current >= 0 {
				finish(&result[current], &modules, &keys)
			}
			if len(result) == format.MAX_EFFECT_EMITTERS {
				problem(&found, line, "an effect has at most %d emitters", format.MAX_EFFECT_EMITTERS)
			}
			append(&result, format.Effect_Emitter_Contents{emitter = DEFAULT_EMITTER, name = fields[1]})
			current = len(result) - 1
			modules = make([dynamic]format.Effect_Module)
			keys = {}
			continue
		}
		if current < 0 {
			problem(&found, line, "a setting is indented under an `emitter`")
			continue
		}
		e := &result[current].emitter
		if fields[0] == "module" {
			if m, message := parse_module(fields[1:]); message != "" {
				problem(&found, line, "%s", message)
			} else if len(modules) == format.MAX_EFFECT_MODULES {
				problem(&found, line, "an emitter has at most %d modules", format.MAX_EFFECT_MODULES)
			} else {
				append(&modules, m)
			}
			continue
		}
		if fields[0] == "curve" {
			equals := strings.index_byte(trimmed, '=')
			if len(fields) < 2 || equals < 0 {
				problem(&found, line, "expected `curve <color|size|emission> = <t>:<value> ...`")
				continue
			}
			name := strings.trim_space(trimmed[len("curve"):equals])
			curve, known := curve_named(name)
			if !known {
				problem(&found, line, "unknown curve %q: color, size or emission", name)
				continue
			}
			if message := parse_curve(strings.fields(trimmed[equals + 1:]), CURVE_COMPONENTS[curve], &keys[curve]); message != "" {
				problem(&found, line, "%s", message)
			}
			continue
		}
		equals := strings.index_byte(trimmed, '=')
		if equals < 0 {
			problem(&found, line, "expected `<setting> = <value>`, `module ...` or `curve ...`")
			continue
		}
		key := strings.trim_space(trimmed[:equals])
		values := strings.fields(trimmed[equals + 1:])
		if message := parse_setting(e, key, values); message != "" {
			problem(&found, line, "%s", message)
		}
	}
	if !header {
		problem(&found, 1, "an effect starts with `effect 1`")
	} else if current < 0 {
		problem(&found, 1, "an effect has an emitter at least")
	} else {
		finish(&result[current], &modules, &keys)
	}
	return result[:], found[:]
}

@(private = "file")
curve_named :: proc(name: string) -> (format.Effect_Curve, bool) {
	switch name {
	case "color":
		return .Color, true
	case "size":
		return .Size, true
	case "emission":
		return .Emission, true
	}
	return .Color, false
}

// numbers parses floats, or gives the first that is not one.
@(private = "file")
numbers :: proc(values: []string, out: []f32) -> (bad: string, ok: bool) {
	for v, i in values {
		n, parsed := strconv.parse_f32(v)
		if !parsed || math.is_nan(n) || math.is_inf(n) {
			return v, false
		}
		out[i] = n
	}
	return "", true
}

// range parses one number, or a low and a high one, as a range.
@(private = "file")
range :: proc(key: string, values: []string, low_bound: f32) -> (r: [2]f32, message: string) {
	if len(values) < 1 || len(values) > 2 {
		return {}, fmt.tprintf("%s takes a value, or a low and a high one", key)
	}
	n: [2]f32
	if bad, ok := numbers(values, n[:len(values)]); !ok {
		return {}, fmt.tprintf("%s: %q is not a number", key, bad)
	}
	r = len(values) == 1 ? {n[0], n[0]} : n
	if r.x > r.y {
		return {}, fmt.tprintf("%s: the low value is above the high one", key)
	}
	if r.x < low_bound {
		return {}, fmt.tprintf("%s is at least %v", key, low_bound)
	}
	return r, ""
}

@(private = "file")
parse_setting :: proc(e: ^format.Effect_Emitter, key: string, values: []string) -> string {
	n: [4]f32
	switch key {
	case "capacity":
		count, ok := strconv.parse_int(len(values) == 1 ? values[0] : "")
		if !ok || count < 1 || count > format.MAX_EMITTER_CAPACITY {
			return fmt.tprintf("capacity is a whole number from 1 to %d", format.MAX_EMITTER_CAPACITY)
		}
		e.capacity = u32(count)
	case "rate":
		if len(values) != 1 {
			return "rate is particles a second"
		}
		if bad, ok := numbers(values, n[:1]); !ok || n[0] < 0 {
			return fmt.tprintf("rate: %q is not a number of 0 or more", bad if !ok else values[0])
		}
		e.rate = n[0]
	case "burst":
		count, ok := strconv.parse_int(len(values) >= 1 ? values[0] : "")
		if !ok || count < 0 || len(values) > 2 {
			return "burst is a count, and an interval in seconds"
		}
		e.burst = u32(count)
		if len(values) == 2 {
			if bad, number := numbers(values[1:], n[:1]); !number || n[0] < 0 {
				return fmt.tprintf("burst: %q is not an interval of 0 or more", bad if !number else values[1])
			}
			e.burst_interval = n[0]
		}
	case "lifetime":
		r, message := range(key, values, 0.001)
		if message != "" {
			return message
		}
		e.lifetime = r
	case "speed":
		r, message := range(key, values, 0)
		if message != "" {
			return message
		}
		e.speed = r
	case "spin":
		r, message := range(key, values, -math.F32_MAX)
		if message != "" {
			return message
		}
		e.spin = r
	case "shape":
		if len(values) < 1 {
			return "shape is point, sphere <radius>, box <x> <y> <z> or cone <radius> <angle>"
		}
		shapes := [?]struct {
			name:   string,
			shape:  format.Effect_Shape,
			values: int,
		}{{"point", .Point, 0}, {"sphere", .Sphere, 1}, {"box", .Box, 3}, {"cone", .Cone, 2}}
		for s in shapes {
			if s.name != values[0] {
				continue
			}
			if len(values) - 1 != s.values {
				return fmt.tprintf("shape %s takes %d values", s.name, s.values)
			}
			if bad, ok := numbers(values[1:], n[:s.values]); !ok {
				return fmt.tprintf("shape: %q is not a number", bad)
			}
			e.shape, e.shape_size = s.shape, n.xyz
			if s.shape == .Cone {
				// The angle is in degrees in the text.
				e.shape_size.y = n.y * math.RAD_PER_DEG
			}
			return ""
		}
		return fmt.tprintf("unknown shape %q: point, sphere, box or cone", values[0])
	case "texture":
		if len(values) != 1 || !strings.has_prefix(values[0], "$") {
			return "texture is $<guid>"
		}
		guid, ok := format.guid_parse(values[0][1:])
		if !ok {
			return fmt.tprintf("texture: %q is not a GUID", values[0])
		}
		e.texture = guid
	case "flipbook":
		if len(values) != 3 {
			return "flipbook is columns, rows and frames a second"
		}
		columns, columns_ok := strconv.parse_int(values[0])
		rows, rows_ok := strconv.parse_int(values[1])
		if !columns_ok || !rows_ok || columns < 1 || rows < 1 {
			return "flipbook's columns and rows are whole numbers of 1 or more"
		}
		if bad, ok := numbers(values[2:], n[:1]); !ok || n[0] < 0 {
			return fmt.tprintf("flipbook: %q is not frames a second", bad if !ok else values[2])
		}
		e.flipbook, e.flipbook_rate = {u32(columns), u32(rows)}, n[0]
	case "softness":
		if len(values) != 1 {
			return "softness is meters"
		}
		if bad, ok := numbers(values, n[:1]); !ok || n[0] < 0 {
			return fmt.tprintf("softness: %q is not meters of 0 or more", bad if !ok else values[0])
		}
		e.softness = n[0]
	case:
		return fmt.tprintf("unknown setting %q", key)
	}
	return ""
}

@(private = "file")
parse_module :: proc(fields: []string) -> (m: format.Effect_Module, message: string) {
	if len(fields) < 1 {
		return {}, "expected `module <gravity|drag|noise|collide> <values>`"
	}
	modules := [?]struct {
		name:   string,
		kind:   format.Effect_Module_Kind,
		values: int,
		usage:  string,
	}{
		{"gravity", .Gravity, 3, "module gravity <x> <y> <z>"},
		{"drag", .Drag, 1, "module drag <per second>"},
		{"noise", .Noise, 2, "module noise <strength> <frequency>"},
		{"collide", .Collide, 2, "module collide <restitution> <friction>"},
	}
	for info in modules {
		if info.name != fields[0] {
			continue
		}
		if len(fields) - 1 != info.values {
			return {}, fmt.tprintf("expected `%s`", info.usage)
		}
		m.kind = info.kind
		if bad, ok := numbers(fields[1:], m.values[:info.values]); !ok {
			return {}, fmt.tprintf("module %s: %q is not a number", info.name, bad)
		}
		return m, ""
	}
	return {}, fmt.tprintf("unknown module %q: gravity, drag, noise or collide", fields[0])
}

// parse_curve parses a curve's keys, `<t>:<value>[,<value>...]`, with t from 0 to 1 and rising.
@(private = "file")
parse_curve :: proc(fields: []string, components: int, keys: ^[dynamic]Curve_Key) -> string {
	if len(fields) == 0 {
		return "a curve has a key at least"
	}
	clear(keys)
	for field in fields {
		colon := strings.index_byte(field, ':')
		if colon < 0 {
			return fmt.tprintf("%q is not `<t>:<value>`", field)
		}
		key: Curve_Key
		t: [1]f32
		if bad, ok := numbers({field[:colon]}, t[:]); !ok || t[0] < 0 || t[0] > 1 {
			return fmt.tprintf("%q is not a point of life from 0 to 1", bad if !ok else field[:colon])
		}
		key.t = t[0]
		values := strings.split(field[colon + 1:], ",", context.temp_allocator)
		alpha_left_out := components == 4 && len(values) == 3
		if len(values) != components && !alpha_left_out {
			return fmt.tprintf("%q has %d values, not %d", field, len(values), components)
		}
		if bad, ok := numbers(values, key.value[:len(values)]); !ok {
			return fmt.tprintf("%q is not a number", bad)
		}
		if alpha_left_out {
			key.value.w = 1
		}
		if len(keys) > 0 && key.t <= keys[len(keys) - 1].t {
			return fmt.tprintf("%q comes before the key in front of it", field)
		}
		append(keys, key)
	}
	return ""
}

// bake_curve samples a curve's keys evenly over a particle's life, linearly between them and held beyond them.
@(private = "file")
bake_curve :: proc(keys: []Curve_Key, default: [4]f32) -> (row: format.Effect_Curve_Row) {
	for &sample, i in row {
		t := f32(i) / f32(format.EFFECT_CURVE_SAMPLES - 1)
		switch {
		case len(keys) == 0:
			sample = default
		case t <= keys[0].t:
			sample = keys[0].value
		case t >= keys[len(keys) - 1].t:
			sample = keys[len(keys) - 1].value
		case:
			for k in 1 ..< len(keys) {
				if t <= keys[k].t {
					a, b := keys[k - 1], keys[k]
					sample = math.lerp(a.value, b.value, (t - a.t) / (b.t - a.t))
					break
				}
			}
		}
	}
	return
}
