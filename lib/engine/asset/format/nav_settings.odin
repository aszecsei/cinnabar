package asset_format

import "core:fmt"
import "core:strconv"
import "core:strings"

// The project settings' keys of the agent types that navmeshes are baked for (see
// docs/content/kinds/nav-meshes.md#agent-types): `nav.agents = Human, Large` names them, and
// `nav.agent.<Name>.<field> = <number>` sets one's radius, height, step_height or max_slope. The cooker reads them
// with nav_agents_parse, and lib/engine/project checks each line with nav_check_setting.
NAV_AGENTS_KEY :: "nav.agents"
NAV_AGENT_PREFIX :: "nav.agent."
// The agent type of a project without nav.agents.
NAV_DEFAULT_AGENT :: "Default"
// A Nav_Mesh_Volume's agents field is a u32 of bits.
NAV_MAX_AGENTS :: 32
NAV_MAX_AGENT_NAME :: 31

// Nav_Agent is an agent type, which a navmesh is baked for: an agent of radius and height walks where a cylinder of
// them fits, steps up and down by at most step_height, and walks up slopes of at most max_slope degrees.
Nav_Agent :: struct {
	name:        string,
	radius:      f32,
	height:      f32,
	step_height: f32,
	max_slope:   f32,
}

DEFAULT_NAV_AGENT :: Nav_Agent {
	name        = NAV_DEFAULT_AGENT,
	radius      = 0.4,
	height      = 1.8,
	step_height = 0.35,
	max_slope   = 45,
}

Nav_Settings_Problem :: struct {
	// The line of the settings' text, from 1.
	line: int,
	text: string,
}

// nav_is_setting says whether a settings key is one of the navigation's.
nav_is_setting :: proc(key: string) -> bool {
	return key == NAV_AGENTS_KEY || strings.has_prefix(key, NAV_AGENT_PREFIX)
}

// nav_check_setting checks one line of the navigation's settings on its own: nav.agents' names, or an agent type's
// field and number. It does not know whether nav.agents names the type, which nav_agents_parse checks over the whole
// text. problem is "" for a line that fits, and otherwise in the temp allocator.
nav_check_setting :: proc(key, value: string) -> (problem: string) {
	if key == NAV_AGENTS_KEY {
		_, problem = nav_parse_names(value, context.temp_allocator)
		return
	}
	_, _, _, problem = nav_parse_field(key, value)
	return
}

// nav_agents_parse reads the agent types from a project's settings text, which is the project's file followed by its
// user file, so a later line wins. Without nav.agents there is one type, NAV_DEFAULT_AGENT. A problem leaves the
// value that it is about at its default. The names point into text, and the problems' text is in allocator.
nav_agents_parse :: proc(text: string, allocator := context.allocator) -> (agents: []Nav_Agent, problems: []Nav_Settings_Problem) {
	list := make([dynamic]Nav_Agent, allocator)
	found := make([dynamic]Nav_Settings_Problem, allocator)

	// The last nav.agents line names the types, so it is found first.
	names_line := 0
	names_value := ""
	{
		rest := text
		line := 0
		for raw in strings.split_lines_iterator(&rest) {
			line += 1
			key, value, ok := settings_line(raw)
			if ok && key == NAV_AGENTS_KEY {
				names_line, names_value = line, value
			}
		}
	}
	if names_line == 0 {
		append(&list, DEFAULT_NAV_AGENT)
	} else {
		names, problem := nav_parse_names(names_value, context.temp_allocator)
		if problem != "" {
			append(&found, Nav_Settings_Problem{names_line, strings.clone(problem, allocator)})
		}
		for name in names {
			agent := DEFAULT_NAV_AGENT
			agent.name = name
			append(&list, agent)
		}
	}

	rest := text
	line := 0
	for raw in strings.split_lines_iterator(&rest) {
		line += 1
		key, value, ok := settings_line(raw)
		if !ok || !strings.has_prefix(key, NAV_AGENT_PREFIX) {
			continue
		}
		name, field, number, problem := nav_parse_field(key, value)
		if problem != "" {
			append(&found, Nav_Settings_Problem{line, strings.clone(problem, allocator)})
			continue
		}
		index := nav_agent_index(list[:], name)
		if index < 0 {
			append(&found, Nav_Settings_Problem{line, fmt.aprintf("%s: %s does not name %q", key, NAV_AGENTS_KEY, name, allocator = allocator)})
			continue
		}
		agent := &list[index]
		switch field {
		case "radius":
			agent.radius = number
		case "height":
			agent.height = number
		case "step_height":
			agent.step_height = number
		case "max_slope":
			agent.max_slope = number
		}
	}
	return list[:], found[:]
}

// nav_parse_names parses nav.agents' value: names between commas, each once, at most NAV_MAX_AGENTS. The names that
// fit are kept, and problem says what did not, or is "".
nav_parse_names :: proc(value: string, allocator := context.allocator) -> (names: []string, problem: string) {
	list := make([dynamic]string, allocator)
	for part in strings.split(value, ",", context.temp_allocator) {
		name := strings.trim_space(part)
		switch {
		case !nav_agent_name_valid(name):
			problem = fmt.tprintf("%s takes names of letters, digits and _ of at most %d characters between commas, not %q", NAV_AGENTS_KEY, NAV_MAX_AGENT_NAME, name)
		case nav_name_index(list[:], name) >= 0:
			problem = fmt.tprintf("%s gives %q twice", NAV_AGENTS_KEY, name)
		case len(list) == NAV_MAX_AGENTS:
			problem = fmt.tprintf("%s gives more than %d agent types", NAV_AGENTS_KEY, NAV_MAX_AGENTS)
		case:
			append(&list, name)
		}
	}
	return list[:], problem
}

// nav_parse_field parses a line `nav.agent.<Name>.<field> = <number>`: a valid name, a field that an agent type has,
// and a number above 0, and below 90 for max_slope. problem is "" when it fits.
nav_parse_field :: proc(key, value: string) -> (name, field: string, number: f32, problem: string) {
	name, _, field = strings.partition(key[len(NAV_AGENT_PREFIX):], ".")
	if !nav_agent_name_valid(name) {
		problem = fmt.tprintf("%s: %q cannot be an agent type's name", key, name)
		return
	}
	switch field {
	case "radius", "height", "step_height", "max_slope":
	case:
		problem = fmt.tprintf("there is no setting %q: an agent type has radius, height, step_height and max_slope", key)
		return
	}
	parsed: bool
	number, parsed = strconv.parse_f32(value)
	limit: f32 = 90 if field == "max_slope" else 1000
	if !parsed || !(number > 0 && number < limit) {
		problem = fmt.tprintf("%s takes a number above 0 and below %v, not %q", key, limit, value)
	}
	return
}

// nav_agent_index is the index of the agent type of a name, or -1.
nav_agent_index :: proc(agents: []Nav_Agent, name: string) -> int {
	for a, i in agents {
		if a.name == name {
			return i
		}
	}
	return -1
}

// nav_agent_name_valid says whether a name can be an agent type's: it is a sub-asset's name in a .meta file and a key
// of the settings, so it has only letters, digits and _.
nav_agent_name_valid :: proc(name: string) -> bool {
	if name == "" || len(name) > NAV_MAX_AGENT_NAME {
		return false
	}
	for c in transmute([]byte)name {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_') {
			return false
		}
	}
	return true
}

// nav_volume_agents says whether a Nav_Mesh_Volume's agents bits bake for the agent type at index.
nav_volume_agents :: proc "contextless" (bits: u32, index: int) -> bool {
	return bits == 0 || bits & (1 << u32(index)) != 0
}

@(private = "file")
nav_name_index :: proc(names: []string, name: string) -> int {
	for n, i in names {
		if n == name {
			return i
		}
	}
	return -1
}

@(private = "file")
settings_line :: proc(raw: string) -> (key, value: string, ok: bool) {
	s := strings.trim_space(raw)
	if s == "" || s[0] == '#' {
		return
	}
	k, _, v := strings.partition(s, "=")
	return strings.trim_space(k), strings.trim_space(v), true
}
