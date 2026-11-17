package cook

import "core:fmt"
import "core:hash"
import "core:slice"
import "core:strings"

import format "cinnabar:engine/asset/format"

// Worlds are .world text files: the scenes that stream in and out as the camera moves, each with its bounds and its
// load and unload distances, or the mark that it is always loaded (see docs/content/kinds/worlds.md).
WORLD_COOK_VERSION :: "worlds 1"

// World_Problem is an error in a world's text, at a line from 1.
World_Problem :: struct {
	line:    int,
	message: string,
}

// World_Scene is a scene of a world's text with the line that names it.
World_Scene :: struct {
	record: format.World_Scene_Record,
	line:   int,
}

cook_worlds :: proc(options: Cook_Options, assets: []Asset_Source, pass: ^Pass) -> bool {
	out_dir := config_dir(options)
	worlds := carry_kind(pass, {.World})
	if len(worlds) > 0 && !make_output_dir(pass, out_dir, {.World}) {
		return false
	}
	by_guid := make(map[format.Guid]int, len(assets), context.temp_allocator)
	for a, i in assets {
		by_guid[a.meta.guid] = i
	}
	ok := true
	step_begin(pass, .World, "", len(worlds))
	for i in worlds {
		defer step_advance(pass)
		asset_source(pass, i)
		result := cook_world(&assets[i], assets, by_guid, out_dir, pass)
		settle(pass, i, result)
		ok &&= !asset_failed(result)
	}
	return ok
}

@(private = "file")
cook_world :: proc(
	a: ^Asset_Source,
	assets: []Asset_Source,
	by_guid: map[format.Guid]int,
	out_dir: string,
	pass: ^Pass,
) -> Asset_Result {
	problems := &pass.problems
	settings_ok := check_settings(a^, problems)
	scenes, parse_problems := world_parse(string(source_of(a^)), context.temp_allocator)
	for p in parse_problems {
		report_error(problems, a.path, p.line, 0, "%s", p.message)
	}
	// What it names is known whether it cooks or not, so the index has it either way, and fixing a scene cooks the
	// world again.
	refs_ok := true
	for s in scenes {
		if !slice.contains(a.dependencies[:], s.record.guid) {
			append(&a.dependencies, s.record.guid)
		}
		child, found := by_guid[s.record.guid]
		switch {
		case !found:
			report_error(
				problems,
				a.path,
				s.line,
				0,
				"no asset has the GUID %s",
				guid_text(s.record.guid),
			)
			refs_ok = false
		case assets[child].kind != .Scene:
			report_error(
				problems,
				a.path,
				s.line,
				0,
				"%s is not a scene, but %s",
				assets[child].name,
				kind_noun(assets[child].kind),
			)
			refs_ok = false
		}
	}
	// A world with errors keeps its old blob, so the running game keeps the last good version.
	if len(parse_problems) > 0 || !refs_ok || !settings_ok {
		return .Failed
	}
	key := hash.fnv64a(
		transmute([]byte)fmt.tprintf(
			"%s\x00%s\x00%x\x00",
			WORLD_COOK_VERSION,
			a.name,
			format.world_layout(),
		),
	)
	key = hash.fnv64a(source_of(a^), key)
	guid := a.meta.guid
	key = hash.fnv64a(guid[:], key)
	output := fmt.tprintf("%s/%s.blob", out_dir, guid_text(guid))
	if cooked_key(output, .World, format.world_layout()) == key && !pass.force[guid] {
		return .Current
	}
	records := make([]format.World_Scene_Record, len(scenes), context.temp_allocator)
	for s, i in scenes {
		records[i] = s.record
	}
	contents := format.World_Contents {
		guid        = guid,
		key         = key,
		scenes      = records,
		source_path = a.name,
	}
	if !write_blob(output, format.world_write(contents, context.temp_allocator)) {
		return .Failed
	}
	return .Cooked
}

// kind_noun is what a kind of asset is called in a message.
@(private = "file")
kind_noun :: proc(kind: format.Asset_Kind) -> string {
	spaced, _ := strings.replace_all(fmt.tprint(kind), "_", " ", context.temp_allocator)
	return strings.to_lower(spaced, context.temp_allocator)
}

// World_Seen is a setting that a scene has set.
@(private = "file")
World_Seen :: enum {
	Persistent,
	Min,
	Max,
	Load,
	Unload,
}

// World_Pending is the scene that world_parse is reading, in the source's units.
@(private = "file")
World_Pending :: struct {
	scene:      World_Scene,
	min, max:   [3]f64,
	load:       f64,
	unload:     f64,
	seen:       bit_set[World_Seen],
	persistent: bool,
	// A line of the scene had a problem, which its other problems follow from.
	broken:     bool,
}

// world_parse parses a world's text into its scenes, without checking that their assets exist: the first line
// `world 1`, then a `scene $<guid>` line for each scene, followed by its `<name> = <value>` lines: `persistent`, and for
// a scene that is not persistent `min` and `max` in meters, `load_distance`, and `unload_distance`. It gives every
// problem that it finds, and the world is good only without any.
world_parse :: proc(
	text: string,
	allocator := context.allocator,
) -> (
	scenes: []World_Scene,
	problems: []World_Problem,
) {
	context.allocator = allocator
	found := make([dynamic]World_Problem)
	result := make([dynamic]World_Scene)
	problem :: proc(found: ^[dynamic]World_Problem, line: int, f: string, args: ..any) {
		append(found, World_Problem{line, fmt.aprintf(f, ..args)})
	}
	// finish checks the scene that has just ended and adds it.
	finish :: proc(
		found: ^[dynamic]World_Problem,
		result: ^[dynamic]World_Scene,
		p: ^World_Pending,
	) {
		if p.broken {
			return
		}
		line, axes := p.scene.line, "xyz"
		record := p.scene.record
		if p.persistent {
			record.flags = {.Persistent}
			append(result, World_Scene{record, line})
			return
		}
		ok := true
		if .Min not_in p.seen {
			problem(found, line, "a scene that is not persistent has a min")
			ok = false
		}
		if .Max not_in p.seen {
			problem(found, line, "a scene that is not persistent has a max")
			ok = false
		}
		if .Load not_in p.seen {
			problem(found, line, "a scene that is not persistent has a load_distance")
			ok = false
		}
		if !ok {
			return
		}
		if !(p.load > 0) {
			problem(found, line, "load_distance is more than 0")
			ok = false
		}
		unload := p.unload if .Unload in p.seen else p.load * format.DEFAULT_UNLOAD_FACTOR
		if unload < p.load {
			problem(found, line, "unload_distance is at least load_distance")
			ok = false
		}
		for axis in 0 ..< 3 {
			if p.min[axis] > p.max[axis] {
				problem(
					found,
					line,
					"min is at most max on each axis, and %s is not",
					axes[axis:axis + 1],
				)
				ok = false
			}
		}
		if !ok {
			return
		}
		for axis in 0 ..< 3 {
			record.min[axis], _ = format.world_raw_from_meters(p.min[axis])
			record.max[axis], _ = format.world_raw_from_meters(p.max[axis])
		}
		record.load_distance = f32(p.load)
		record.unload_distance = f32(unload)
		append(result, World_Scene{record, line})
	}
	current: World_Pending
	open, header := false, false
	for raw, index in strings.split_lines(text) {
		line := index + 1
		trimmed := strings.trim_space(strip_line_comment(raw))
		if trimmed == "" {
			continue
		}
		if !header {
			if fields := strings.fields(trimmed);
			   len(fields) == 2 && fields[0] == "world" && fields[1] == "1" {
				header = true
				continue
			}
			problem(&found, line, "a world starts with `world 1`")
			return nil, found[:]
		}
		if word, _, rest := strings.partition(trimmed, " "); word == "scene" {
			if open {
				finish(&found, &result, &current)
			}
			current, open = {}, true
			current.scene.line = line
			rest = strings.trim_space(rest)
			guid: format.Guid
			ok := false
			if strings.has_prefix(rest, "$") {
				guid, ok = format.guid_parse(rest[1:])
			}
			if !ok {
				problem(&found, line, "a scene is `scene $<guid>`, with 32 hex digits")
				open = false
				continue
			}
			current.scene.record.guid = guid
			for s in result {
				if s.record.guid == guid {
					problem(&found, line, "the world names this scene twice")
					break
				}
			}
			if len(result) >= format.MAX_WORLD_SCENES {
				problem(&found, line, "a world has at most %d scenes", format.MAX_WORLD_SCENES)
				current.broken = true
			}
			continue
		}
		name, has_value, value_text := strings.partition(trimmed, "=")
		name, value_text = strings.trim_space(name), strings.trim_space(value_text)
		if has_value == "" {
			problem(&found, line, "a line is `scene $<guid>` or `<name> = <value>`")
			if open {
				current.broken = true
			}
			continue
		}
		if !open {
			problem(&found, line, "%s comes after a `scene $<guid>` line", name)
			continue
		}
		value, message := parse_graph_value(value_text)
		if message != "" {
			problem(&found, line, "%s: %s", name, message)
			current.broken = true
			continue
		}
		seen: World_Seen
		switch name {
		case "persistent":
			seen = .Persistent
		case "min":
			seen = .Min
		case "max":
			seen = .Max
		case "load_distance":
			seen = .Load
		case "unload_distance":
			seen = .Unload
		case:
			current.broken = true
			problem(
				&found,
				line,
				"%q is not a scene's setting: persistent, min, max, load_distance or unload_distance",
				name,
			)
			continue
		}
		if seen in current.seen {
			problem(&found, line, "the scene sets %s twice", name)
			continue
		}
		current.seen += {seen}
		switch seen {
		case .Persistent:
			if value.kind != .Word || (value.text != "true" && value.text != "false") {
				problem(&found, line, "persistent is true or false")
				current.broken = true
			} else {
				current.persistent = value.text == "true"
			}
		case .Min, .Max:
			point := [3]f64{value.numbers[0], value.numbers[1], value.numbers[2]}
			if value.kind != .Numbers || value.count != 3 || !position_in_range(point) {
				problem(&found, line, "%s is three numbers in meters, such as [0, 0, 0]", name)
				current.broken = true
			} else if seen == .Min {
				current.min = point
			} else {
				current.max = point
			}
		case .Load, .Unload:
			if value.kind != .Numbers || value.count != 1 || !(abs(value.numbers[0]) < max(f64)) {
				problem(&found, line, "%s is one number in meters", name)
				current.broken = true
			} else if seen == .Load {
				current.load = value.numbers[0]
			} else {
				current.unload = value.numbers[0]
			}
		}
	}
	if !header {
		problem(&found, 1, "a world starts with `world 1`")
	}
	if open {
		finish(&found, &result, &current)
	}
	slice.stable_sort_by(found[:], proc(a, b: World_Problem) -> bool {return a.line < b.line})
	return result[:], found[:]
}

// position_in_range is whether a point in meters is inside the bounds of a World_Position.
@(private = "file")
position_in_range :: proc(meters: [3]f64) -> bool {
	for m in meters {
		if _, ok := format.world_raw_from_meters(m); !ok {
			return false
		}
	}
	return true
}
