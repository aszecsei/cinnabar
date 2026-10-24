// The commands that cook the content roots share their options and one pass: a scan of the roots, and then each kind
// of asset in turn. See docs/content-pipeline.md#cooking.
package cook

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"

import format "cinnabar:engine/asset/format"

Root :: struct {
	name: string,
	// Absolute, with forward slashes.
	dir:  string,
}

Cook_Options :: struct {
	cache:       string,
	config:      Script_Config,
	roots:       [dynamic]Root,
	// The definition file to type check scripts against, or "" for none.
	definitions: string,
}

// Pass is what one cook did.
Pass :: struct {
	ok:         bool,
	cooked:     [format.Asset_Kind]int,
	current:    [format.Asset_Kind]int,
	// The cache's generation after the pass. It changes only when the pass writes a blob.
	generation: u64,
}

// parse_cook_args reads `--cache <dir> --config dev|release [--definitions <file>] --root <name>=<dir>...`. The daemon
// always cooks the dev configuration, so it takes no --config.
parse_cook_args :: proc(args: []string, daemon := false) -> (options: Cook_Options, ok: bool) {
	options.roots = make([dynamic]Root, context.temp_allocator)
	config_set := daemon
	for i := 0; i < len(args); i += 1 {
		if i + 1 >= len(args) {
			return
		}
		value := args[i + 1]
		switch args[i] {
		case "--cache":
			options.cache = value
		case "--definitions":
			options.definitions = value
		case "--config":
			if daemon {
				return
			}
			switch value {
			case "dev":
				options.config = .Dev
			case "release":
				options.config = .Release
			case:
				return
			}
			config_set = true
		case "--root":
			equals := strings.index_byte(value, '=')
			if equals <= 0 {
				return
			}
			dir, err := os.get_absolute_path(value[equals + 1:], context.temp_allocator)
			if err != nil {
				return
			}
			append(&options.roots, Root{value[:equals], forward_slashes(dir)})
		case:
			return
		}
		i += 1
	}
	return options, options.cache != "" && config_set && len(options.roots) > 0
}

// cook scans the roots and cooks the assets of the kinds whose keys changed. When it writes a blob, it then writes the
// cache's generation, so a running game swaps the pass's blobs together (see docs/content-pipeline.md#loading).
cook :: proc(options: Cook_Options, kinds: Asset_Kinds) -> (pass: Pass) {
	assets, scanned := scan(options.roots[:])
	pass.ok = scanned
	if .Script in kinds {
		pass.ok = cook_scripts(options, assets, &pass) && pass.ok
	}
	if .Scene in kinds {
		pass.ok = cook_scenes(options, assets, &pass) && pass.ok
	}
	written := 0
	for n in pass.cooked {
		written += n
	}
	out_dir := config_dir(options)
	if written == 0 {
		pass.generation = read_generation(out_dir)
		return
	}
	generation, generation_ok := write_generation(out_dir)
	pass.generation = generation
	pass.ok &&= generation_ok
	return
}

// config_dir is the configuration's directory in the cache, where its blobs and its generation are.
config_dir :: proc(options: Cook_Options) -> string {
	return fmt.tprintf("%s/%s", options.cache, options.config == .Dev ? "dev" : "release")
}

// read_generation reads the counter in a configuration directory's generation file. It is 0 if there is none.
read_generation :: proc(dir: string) -> u64 {
	data, err := os.read_entire_file(fmt.tprintf("%s/%s", dir, format.GENERATION_FILE), context.temp_allocator)
	if err != nil {
		return 0
	}
	return strconv.parse_u64(strings.trim_space(string(data))) or_else 0
}

// write_generation adds one to the counter in a configuration directory's generation file.
write_generation :: proc(dir: string) -> (generation: u64, ok: bool) {
	generation = read_generation(dir) + 1
	text := fmt.tprintf("%d\n", generation)
	return generation, write_blob(fmt.tprintf("%s/%s", dir, format.GENERATION_FILE), transmute([]byte)text)
}
