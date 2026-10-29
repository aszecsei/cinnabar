// Stages are USD files, .usda, .usdc and .usd, read with LightUSD (see usd.odin). A stage is a file of sub-assets: a
// Mesh for each mesh prim, split into parts of at most eight GeomSubsets, a Texture for each image that a material
// reads in each way that it reads it, a Material_Instance of a built-in preview_surface material for each
// UsdPreviewSurface material, and one Prefab of the whole stage, its prims as entities. The material instances and the
// prefab are text that the cooker generates and the material and scene passes cook, as they would a file. Each mesh and
// texture cooks and writes its blob on its own, so a stage of gigabytes of images never sits in memory whole. See
// docs/content/kinds/stages.md#stages.
package cook

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:hash"
import "core:math/linalg"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import format "cinnabar:engine/asset/format"

// Changing how the cooker cooks stages changes this, which invalidates every stage's sub-assets.
STAGE_COOK_VERSION :: "stages 1"
STAGE_EXTENSIONS :: []string{".usda", ".usdc", ".usd"}
// A part of a mesh has at most this many submeshes, which a Mesh_Renderer has material slots for.
STAGE_MAX_SLOTS :: format.MESH_MAX_SLOTS
// The name of a stage's prefab sub-asset.
STAGE_PREFAB_NAME :: "stage"

STAGE_SETTINGS := []Setting_Info {
	{
		key = "scale",
		values = {"0.001", "0.01", "0.0254", "0.1", "1", "10", "100"},
		default = "1",
		description = "Scale the stage after its metersPerUnit, which already puts it in meters.",
	},
	{
		key = "cluster_lod",
		values = {"true", "false"},
		default = "true",
		description = "Simplify the meshes' meshlets into a hierarchy of levels of detail, as for a model.",
	},
	{
		key = "collision",
		values = {"true", "false"},
		default = "false",
		description = "Write the welded triangles that a mesh collider is built from.",
	},
	{
		key = "impostor",
		values = {"true", "false"},
		default = "false",
		description = "Bake an octahedral impostor for each mesh.",
	},
	{
		key = "texture_max_size",
		values = {"256", "512", "1024", "2048", "4096", "8192", "16384"},
		default = "4096",
		description = "Halve each texture until its larger side fits.",
	},
	{
		key = "normal_y",
		values = {"file", "flip"},
		default = "file",
		description = "Take the normal maps' green channel as the files have it, or negate it, for maps made for the other convention.",
	},
	{
		key = "point_instancers",
		values = {"skip", "entities"},
		default = "skip",
		description = "Leave out point instancers, or make an entity of each point. A forest of them can be millions of entities.",
	},
}

// The built-in parents of a stage's material instances, by blend and sidedness: Stage_Blend * 2 + two-sided.
@(private = "file")
PREVIEW_SURFACE_METAS := [6]string {
	#load("../../lib/engine/content/materials/preview_surface.material.meta", string),
	#load("../../lib/engine/content/materials/preview_surface_two_sided.material.meta", string),
	#load("../../lib/engine/content/materials/preview_surface_masked.material.meta", string),
	#load("../../lib/engine/content/materials/preview_surface_masked_two_sided.material.meta", string),
	#load("../../lib/engine/content/materials/preview_surface_transparent.material.meta", string),
	#load("../../lib/engine/content/materials/preview_surface_transparent_two_sided.material.meta", string),
}

@(private = "file")
Stage_Blend :: enum {
	Opaque,
	Masked,
	Transparent,
}

// Stage_Role is a way that a material reads an image, which is a texture of its own: as color, as a normal map, or one
// channel of it as a mask.
@(private = "file")
Stage_Role :: struct {
	usage:   format.Texture_Usage,
	channel: int,
	srgb:    bool,
}

@(private = "file")
Stage_Texture :: struct {
	texture: i32,
	role:    Stage_Role,
	name:    string,
	guid:    format.Guid,
}

@(private = "file")
Stage_Material :: struct {
	material:   i32,
	two_sided:  bool,
	name:       string,
	guid:       format.Guid,
}

// Stage_Part is a run of at most STAGE_MAX_SLOTS of a mesh's subsets, which is a Mesh sub-asset.
@(private = "file")
Stage_Part :: struct {
	mesh:          i32,
	first, count:  int,
	name:          string,
	guid:          format.Guid,
}

// Stage_Manifest is what a stage's last cook made and read, beside its blobs as <cache>/stages/<guid>.deps, so a stage
// whose files have not changed is known current without opening it.
@(private = "file")
Stage_Manifest :: struct {
	key:       u64,
	files:     [dynamic]Stage_File,
	subassets: [dynamic]Stage_Manifest_Subasset,
}

@(private = "file")
Stage_File :: struct {
	size:     i64,
	modified: i64,
	path:     string,
}

@(private = "file")
Stage_Manifest_Subasset :: struct {
	kind:      format.Asset_Kind,
	guid:      format.Guid,
	// The key of its blob, which the stage writes, or 0 for one that a later pass cooks from its generated text.
	key:       u64,
	name:      string,
	// The generated text's file, for a material instance or the prefab.
	generated: string,
}

// cook_stages cooks the stages among the assets whose files changed, and adds each stage's generated material
// instances and prefab to the pass's assets, for the passes that cook them. It reports every failure, and returns
// false if any.
cook_stages :: proc(options: Cook_Options, pass: ^Pass) -> bool {
	stages := assets_of(pass.assets, .Stage)
	if len(stages) == 0 {
		return true
	}
	problems := &pass.problems
	out_dir := config_dir(options)
	for dir in ([]string{out_dir, fmt.tprintf("%s/stages", out_dir), fmt.tprintf("%s/generated/stages", out_dir)}) {
		if err := os.make_directory_all(dir); err != nil && err != .Exist {
			report_error(problems, dir, 0, 0, "%v", err)
			return false
		}
	}
	generated := make([dynamic]Asset_Source, context.temp_allocator)
	ok := true
	for i in stages {
		if !cook_stage(options, &pass.assets[i], out_dir, pass, &generated) {
			pass.assets[i].failed = true
			ok = false
		}
	}
	if len(generated) > 0 {
		all := make([]Asset_Source, len(pass.assets) + len(generated), context.temp_allocator)
		copy(all, pass.assets)
		copy(all[len(pass.assets):], generated[:])
		pass.assets = all
	}
	return ok
}

@(private = "file")
stage_setting :: proc(a: Asset_Source, key: string) -> string {
	if value, found := format.meta_value(a.meta, key); found {
		return value
	}
	info, _ := find_setting(STAGE_SETTINGS, key)
	return info.default
}

// stage_key covers what every sub-asset depends on besides the files that the stage reads: the cooker, the libraries,
// the configuration, the path, the source, the GUID and the settings. The sub-asset lines of the .meta file are not in
// it, because the cooker writes them.
@(private = "file")
stage_key :: proc(options: Cook_Options, a: Asset_Source) -> u64 {
	key := hash.fnv64a(
		transmute([]byte)fmt.tprintf(
			"%s\x00%s\x00%s\x00%s\x00%s\x00%v\x00%s\x00%x\x00%x\x00",
			STAGE_COOK_VERSION, LIGHTUSD_VERSION, MESHOPTIMIZER_VERSION, COMPRESSONATOR_VERSION, TEXTURE_COOK_VERSION,
			options.config, a.name, format.mesh_layout(), format.texture_layout(),
		),
	)
	key = hash.fnv64a(a.source, key)
	guid := a.meta.guid
	key = hash.fnv64a(guid[:], key)
	for s in a.meta.settings {
		key = hash.fnv64a(transmute([]byte)fmt.tprintf("%s=%s\x00", s.key, s.value), key)
	}
	return key
}

@(private = "file")
cook_stage :: proc(options: Cook_Options, a: ^Asset_Source, out_dir: string, pass: ^Pass, generated: ^[dynamic]Asset_Source) -> bool {
	problems := &pass.problems
	if !check_settings(a^, problems) {
		return false
	}
	key := stage_key(options, a^)
	manifest_path := fmt.tprintf("%s/stages/%s.deps", out_dir, guid_text(a.meta.guid))
	old, has_old := read_manifest(manifest_path)
	if has_old && old.key == key && !pass.force[a.meta.guid] && manifest_current(old, a^, out_dir) {
		pass.current[.Stage] += 1
		return use_manifest(a, old, generated, problems)
	}

	options_c := Cn_Usd_Options {
		point_instancers = stage_setting(a^, "point_instancers") == "entities" ? 1 : 0,
	}
	usd := cn_usd_open(strings.clone_to_cstring(a.path, context.temp_allocator), &options_c)
	defer cn_usd_close(usd)
	if err := usd_string(cn_usd_error(usd)); err != "" {
		if strings.has_prefix(err, "missing layer") {
			// A stage whose files are not there, as a sample's downloads, is not an error: the build goes on without it.
			report_warning(problems, a.path, 0, 0, "not cooked: %s. See the README beside the stage for where its files come from.", err)
			if has_old {
				return use_manifest(a, old, generated, problems)
			}
			return true
		}
		report_error(problems, a.path, 0, 0, "cannot read the stage: %s", strings.trim_space(err))
		return false
	}
	report_stage_warnings(a^, usd_string(cn_usd_warnings(usd)), problems)
	info: Cn_Usd_Info
	cn_usd_info(usd, &info)

	materials, textures := stage_materials(a^, usd, info, problems)
	parts := stage_parts(a^, usd, info)

	wanted := make([dynamic]Subasset, context.temp_allocator)
	for t in textures {
		append(&wanted, Subasset{kind = .Texture, name = t.name})
	}
	for m in materials {
		append(&wanted, Subasset{kind = .Material_Instance, name = m.name})
	}
	for p in parts {
		append(&wanted, Subasset{kind = .Mesh, name = p.name})
	}
	append(&wanted, Subasset{kind = .Prefab, name = STAGE_PREFAB_NAME})
	assign_subassets(a, wanted[:], pass.force[a.meta.guid], problems) or_return
	guid_of := make(map[string]format.Guid, len(a.subassets), context.temp_allocator)
	for s in a.subassets {
		guid_of[fmt.tprintf("%s.%s", subasset_kind_name(s.kind), s.name)] = s.guid
	}
	for &t in textures {
		t.guid = guid_of[fmt.tprintf("%s.%s", format.TEXTURE_KIND, t.name)]
	}
	for &m in materials {
		m.guid = guid_of[fmt.tprintf("%s.%s", format.MATERIAL_INSTANCE_KIND, m.name)]
	}
	for &p in parts {
		p.guid = guid_of[fmt.tprintf("%s.%s", format.MESH_KIND, p.name)]
	}
	prefab_guid := guid_of[fmt.tprintf("%s.%s", format.PREFAB_KIND, STAGE_PREFAB_NAME)]

	manifest := Stage_Manifest {
		key       = key,
		files     = make([dynamic]Stage_File, context.temp_allocator),
		subassets = make([dynamic]Stage_Manifest_Subasset, context.temp_allocator),
	}
	ok := true
	for i in 0 ..< info.layer_count {
		stage_watch_layers(usd_string(cn_usd_layer(usd, i)), &manifest)
	}

	for t in textures {
		blob_key, cooked := cook_stage_texture(options, a^, usd, t, out_dir, pass, &manifest)
		ok &&= cooked
		append(&manifest.subassets, Stage_Manifest_Subasset{.Texture, t.guid, blob_key, t.name, ""})
	}
	for p in parts {
		blob_key, cooked := cook_stage_part(a^, usd, info, p, out_dir, pass)
		ok &&= cooked
		append(&manifest.subassets, Stage_Manifest_Subasset{.Mesh, p.guid, blob_key, p.name, ""})
	}

	// The generated texts, which later passes cook as they would files.
	for m in materials {
		text := stage_instance_text(a^, usd, m, textures[:], stage_setting(a^, "normal_y") == "flip")
		path := fmt.tprintf("%s/generated/stages/%s%s", out_dir, guid_text(m.guid), format.MATERIAL_INSTANCE_EXTENSION)
		ok &&= write_generated(path, text, problems)
		append(&manifest.subassets, Stage_Manifest_Subasset{.Material_Instance, m.guid, 0, m.name, path})
	}
	{
		text := stage_prefab_text(a^, usd, info, parts[:], materials[:], problems)
		path := fmt.tprintf("%s/generated/stages/%s%s", out_dir, guid_text(prefab_guid), format.PREFAB_EXTENSION)
		ok &&= write_generated(path, text, problems)
		append(&manifest.subassets, Stage_Manifest_Subasset{.Prefab, prefab_guid, 0, STAGE_PREFAB_NAME, path})
	}
	if !ok {
		return false
	}
	if !write_manifest(manifest_path, manifest) {
		report_error(problems, manifest_path, 0, 0, "cannot write the stage's manifest")
		return false
	}
	add_generated(a^, manifest, generated, problems)
	pass.cooked[.Stage] += 1
	return true
}

// report_stage_warnings reports LightUSD's warnings about the stage, one problem a line, at most a screenful.
@(private = "file")
report_stage_warnings :: proc(a: Asset_Source, text: string, problems: ^Problems) {
	LIMIT :: 20
	count := 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		trimmed := strings.trim_space(line)
		if trimmed == "" {
			continue
		}
		if count < LIMIT {
			report_warning(problems, a.path, 0, 0, "%s", trimmed)
		}
		count += 1
	}
	if count > LIMIT {
		report_warning(problems, a.path, 0, 0, "and %d more warnings from LightUSD", count - LIMIT)
	}
}

@(private = "file")
role_name :: proc(r: Stage_Role) -> string {
	#partial switch r.usage {
	case .Normal:
		return "normal"
	case .Mask:
		channels := "rgba"
		return fmt.tprintf("mask.%c%s", channels[r.channel], r.srgb ? ".srgb" : "")
	}
	return "color"
}

// stage_texture_name is a texture's sub-asset name: its image's path, and how it is read. The path is from the folder
// that holds the stage's first sublayer's folder, as a download's, such as main_sponza/textures/a.png, or else from the
// stage's own folder.
@(private = "file")
stage_texture_name :: proc(a: Asset_Source, usd: ^Cn_Usd, resolved: string, role: Stage_Role) -> string {
	base := filepath.dir(a.path)
	info: Cn_Usd_Info
	cn_usd_info(usd, &info)
	if info.layer_count > 0 {
		downloads := filepath.dir(filepath.dir(usd_string(cn_usd_layer(usd, 0))))
		if strings.has_prefix(resolved, fmt.tprintf("%s/", downloads)) {
			base = downloads
		}
	}
	rel, err := filepath.rel(base, resolved, context.temp_allocator)
	if err != .None {
		rel = resolved
	}
	name := fmt.tprintf("%s@%s", forward_slashes(rel), role_name(role))
	name, _ = strings.replace_all(name, "=", "_", context.temp_allocator)
	return name
}

// stage_materials lists the material instances that the stage's meshes use, with each one's sidedness, and the
// textures that they read.
@(private = "file")
stage_materials :: proc(a: Asset_Source, usd: ^Cn_Usd, info: Cn_Usd_Info, problems: ^Problems) -> (materials: [dynamic]Stage_Material, textures: [dynamic]Stage_Texture) {
	materials = make([dynamic]Stage_Material, context.temp_allocator)
	textures = make([dynamic]Stage_Texture, context.temp_allocator)
	used := make(map[[2]i32]bool, context.temp_allocator)
	for i in 0 ..< info.mesh_count {
		m: Cn_Usd_Mesh
		if cn_usd_mesh(usd, i, &m) == 0 {
			continue
		}
		for s in m.subsets[:m.subset_count] {
			if s.material >= 0 {
				used[{s.material, m.double_sided}] = true
			}
		}
	}
	for i in 0 ..< info.instance_count {
		inst: Cn_Usd_Instance
		cn_usd_instance(usd, i, &inst)
		if inst.material >= 0 {
			used[{inst.material, 0}] = true
		}
	}
	keys, _ := slice.map_keys(used, context.temp_allocator)
	slice.sort_by(keys, proc(x, y: [2]i32) -> bool {return x[0] < y[0] || (x[0] == y[0] && x[1] < y[1])})
	texture_names := make(map[string]bool, context.temp_allocator)
	specular, occlusion := 0, 0
	for k in keys {
		mat: Cn_Usd_Material
		cn_usd_material(usd, k[0], &mat)
		name := strings.trim_prefix(usd_string(mat.path), "/")
		if k[1] != 0 {
			name = fmt.tprintf("%s#two_sided", name)
		}
		append(&materials, Stage_Material{material = k[0], two_sided = k[1] != 0, name = strings.clone(name, context.temp_allocator)})
		specular += int(mat.specular_workflow != 0)
		occlusion += int(mat.occlusion.texture >= 0)
		inputs := [?]struct {
			input: Cn_Usd_Input,
			usage: format.Texture_Usage,
		}{{mat.diffuse, .Color}, {mat.emissive, .Color}, {mat.normal, .Normal}, {mat.metallic, .Mask}, {mat.roughness, .Mask}, {mat.opacity, .Mask}}
		for input in inputs {
			t := input.input.texture
			// Opacity from the base color's alpha samples the base color's texture.
			if t < 0 || (input.usage == .Mask && t == mat.diffuse.texture && input.input.channel == .A && input.input == mat.opacity) {
				continue
			}
			role := stage_role(usd, input.input, input.usage)
			tex: Cn_Usd_Texture
			cn_usd_texture(usd, t, &tex)
			resolved := usd_string(tex.resolved)
			if resolved == "" {
				report_warning(problems, a.path, 0, 0, "material %s reads %s, which is not there", usd_string(mat.path), usd_string(tex.asset))
				continue
			}
			if !slice.contains(TEXTURE_EXTENSIONS, strings.to_lower(filepath.ext(resolved), context.temp_allocator)) {
				report_warning(problems, a.path, 0, 0, "material %s reads %s, which the cooker cannot decode, so the input keeps its value", usd_string(mat.path), resolved)
				continue
			}
			texture_name := stage_texture_name(a, usd, resolved, role)
			if texture_names[texture_name] {
				continue
			}
			texture_names[texture_name] = true
			append(&textures, Stage_Texture{texture = t, role = role, name = texture_name})
		}
	}
	if specular > 0 {
		report_warning(problems, a.path, 0, 0, "%d materials use the specular workflow, which draws as metallic 0", specular)
	}
	if occlusion > 0 {
		report_warning(problems, a.path, 0, 0, "%d materials have an occlusion texture, which the lit shading model does not take", occlusion)
	}
	return
}

@(private = "file")
stage_role :: proc(usd: ^Cn_Usd, input: Cn_Usd_Input, usage: format.Texture_Usage) -> Stage_Role {
	if usage != .Mask {
		return {usage = usage}
	}
	tex: Cn_Usd_Texture
	cn_usd_texture(usd, input.texture, &tex)
	channel := 0
	#partial switch input.channel {
	case .G:
		channel = 1
	case .B:
		channel = 2
	case .A:
		channel = 3
	}
	// A scalar's image is raw unless it says sRGB: auto, which UsdPreviewSurface takes as sRGB for 8-bit images, is
	// what exporters write for roughness and metalness maps that hold linear values.
	return {usage = .Mask, channel = channel, srgb = tex.color_space == .SRGB}
}

// stage_parts splits each mesh into parts of at most STAGE_MAX_SLOTS subsets.
@(private = "file")
stage_parts :: proc(a: Asset_Source, usd: ^Cn_Usd, info: Cn_Usd_Info) -> [dynamic]Stage_Part {
	parts := make([dynamic]Stage_Part, context.temp_allocator)
	names := make(map[string]int, context.temp_allocator)
	for i in 0 ..< info.mesh_count {
		m: Cn_Usd_Mesh
		if cn_usd_mesh(usd, i, &m) == 0 || m.subset_count == 0 {
			continue
		}
		base := strings.trim_prefix(usd_string(m.path), "/")
		base, _ = strings.replace_all(base, "=", "_", context.temp_allocator)
		// Two meshes of one prim path, as two instances' prototypes can be, keep apart.
		if n := names[base]; n > 0 {
			names[base] = n + 1
			base = fmt.tprintf("%s_%d", base, n + 1)
		} else {
			names[base] = 1
		}
		count := int(m.subset_count)
		part_count := (count + STAGE_MAX_SLOTS - 1) / STAGE_MAX_SLOTS
		for p in 0 ..< part_count {
			first := p * STAGE_MAX_SLOTS
			name := part_count == 1 ? strings.clone(base, context.temp_allocator) : fmt.tprintf("%s#%d", base, p + 1)
			append(&parts, Stage_Part{mesh = i, first = first, count = min(STAGE_MAX_SLOTS, count - first), name = name})
		}
	}
	return parts
}

// stage_basis is the matrix that takes a stage's axes to the engine's, and the scale that takes its units to meters.
// Y-up mirrors x, as glTF's axes do. Z-up turns z up to y first. Both mirror, so triangles reverse.
@(private = "file")
stage_basis :: proc(a: Asset_Source, info: Cn_Usd_Info) -> (basis: matrix[3, 3]f64, scale: f64) {
	scale = info.meters_per_unit * (strconv.parse_f64(stage_setting(a, "scale")) or_else 1)
	if info.up == .Z {
		basis = {
			-1, 0, 0,
			0, 0, 1,
			0, -1, 0,
		}
	} else {
		basis = {
			-1, 0, 0,
			0, 1, 0,
			0, 0, 1,
		}
	}
	return
}

// Scratch is an arena for one sub-asset's cook, so its memory goes as soon as its blob is written. Problems reported
// inside it are copied out when it ends.
@(private = "file")
Scratch :: struct {
	arena:    virtual.Arena,
	outer:    runtime.Allocator,
	problems: Problems,
}

@(private = "file")
scratch_begin :: proc(s: ^Scratch, pass: ^Pass) {
	_ = virtual.arena_init_growing(&s.arena)
	s.outer = context.temp_allocator
	s.problems = Problems{log = pass.problems.log}
	context.temp_allocator = virtual.arena_allocator(&s.arena)
}

@(private = "file")
scratch_end :: proc(s: ^Scratch, pass: ^Pass) {
	context.temp_allocator = s.outer
	if pass.problems.list == nil {
		pass.problems.list = make([dynamic]Problem, context.temp_allocator)
	}
	for p in s.problems.list {
		copied := p
		copied.file = strings.clone(p.file, context.temp_allocator)
		copied.text = strings.clone(p.text, context.temp_allocator)
		append(&pass.problems.list, copied)
	}
	virtual.arena_destroy(&s.arena)
}

@(private = "file")
file_stamp :: proc(path: string) -> (size, modified: i64, ok: bool) {
	info, err := os.stat(path, context.temp_allocator)
	if err != nil {
		return
	}
	return info.size, time.to_unix_nanoseconds(info.modification_time), true
}

// stage_watch_layers adds the USD files under a root sublayer's folder to the manifest: the stage's layers are among
// them, and LightUSD does not say which.
@(private = "file")
stage_watch_layers :: proc(layer: string, manifest: ^Stage_Manifest) {
	todo := make([dynamic]string, context.temp_allocator)
	append(&todo, filepath.dir(layer))
	for len(todo) > 0 {
		dir := pop(&todo)
		infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil {
			continue
		}
		for info in infos {
			if info.type == .Directory {
				append(&todo, info.fullpath)
				continue
			}
			ext := strings.to_lower(filepath.ext(info.name), context.temp_allocator)
			if ext == ".usd" || ext == ".usda" || ext == ".usdc" {
				append(&manifest.files, Stage_File{info.size, time.to_unix_nanoseconds(info.modification_time), forward_slashes(strings.clone(info.fullpath, context.temp_allocator))})
			}
		}
	}
}

@(private = "file")
cook_stage_texture :: proc(options: Cook_Options, a: Asset_Source, usd: ^Cn_Usd, t: Stage_Texture, out_dir: string, pass: ^Pass, manifest: ^Stage_Manifest) -> (blob_key: u64, ok: bool) {
	tex: Cn_Usd_Texture
	cn_usd_texture(usd, t.texture, &tex)
	path := strings.clone(usd_string(tex.resolved), context.temp_allocator)
	size, modified, stamped := file_stamp(path)
	if !stamped {
		report_error(&pass.problems, a.path, 0, 0, "cannot read %s", path)
		return
	}
	append(&manifest.files, Stage_File{size, modified, path})
	cook := Texture_Cook {
		usage    = t.role.usage,
		wrap     = tex.wrap_s != .Clamp && tex.wrap_t != .Clamp,
		mips     = true,
		max_size = strconv.parse_int(stage_setting(a, "texture_max_size")) or_else 4096,
		channel  = t.role.channel,
		srgb     = t.role.srgb,
		flip_y   = stage_setting(a, "normal_y") == "flip",
	}
	blob_key = hash.fnv64a(transmute([]byte)fmt.tprintf("%s\x00%s\x00%s\x00%v\x00%x\x00%s\x00%v\x00%d\x00%d\x00", STAGE_COOK_VERSION, TEXTURE_COOK_VERSION, COMPRESSONATOR_VERSION, options.config, format.texture_layout(), path, cook, size, modified))
	output := fmt.tprintf("%s/%s.blob", out_dir, guid_text(t.guid))
	if cooked_key(output, .Texture, format.texture_layout()) == blob_key && !pass.force[a.meta.guid] {
		pass.current[.Texture] += 1
		return blob_key, true
	}
	scratch: Scratch
	scratch_begin(&scratch, pass)
	context.temp_allocator = virtual.arena_allocator(&scratch.arena)
	ok = cook_stage_texture_blob(options, a, path, t, cook, blob_key, output, &scratch.problems)
	scratch_end(&scratch, pass)
	if ok {
		pass.cooked[.Texture] += 1
	}
	return blob_key, ok
}

@(private = "file")
cook_stage_texture_blob :: proc(options: Cook_Options, a: Asset_Source, path: string, t: Stage_Texture, cook: Texture_Cook, key: u64, output: string, problems: ^Problems) -> bool {
	source, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		report_error(problems, path, 0, 0, "%v", err)
		return false
	}
	image := decode_image_bytes(source, path, cook, problems) or_return
	blob := cook_texture_image(options, image, cook, t.guid, key, fmt.tprintf("%s#%s", a.name, t.name), path, problems) or_return
	return write_blob(output, blob)
}

@(private = "file")
cook_stage_part :: proc(a: Asset_Source, usd: ^Cn_Usd, info: Cn_Usd_Info, p: Stage_Part, out_dir: string, pass: ^Pass) -> (blob_key: u64, ok: bool) {
	scratch: Scratch
	scratch_begin(&scratch, pass)
	context.temp_allocator = virtual.arena_allocator(&scratch.arena)
	defer scratch_end(&scratch, pass)
	m: Cn_Usd_Mesh
	if cn_usd_mesh(usd, p.mesh, &m) == 0 {
		report_error(&scratch.problems, a.path, 0, 0, "mesh %s has faces that are not triangles after triangulation", p.name)
		return
	}
	basis, scale := stage_basis(a, info)
	cook := stage_cook_mesh(a, m, p, basis, scale)
	if len(cook.corners) == 0 {
		report_error(&scratch.problems, a.path, 0, 0, "mesh %s has no triangles", p.name)
		return
	}
	blob_key = hash.fnv64a(transmute([]byte)fmt.tprintf("%s\x00%s\x00%s\x00%x\x00%s\x00%v\x00%v\x00%v\x00", STAGE_COOK_VERSION, MESHOPTIMIZER_VERSION, a.name, format.mesh_layout(), p.name, cook.lod, cook.collision, cook.impostor_size))
	blob_key = hash.fnv64a(mem.slice_to_bytes(cook.corners), blob_key)
	blob_key = hash.fnv64a(mem.slice_to_bytes(cook.ranges), blob_key)
	for n in cook.names {
		blob_key = hash.fnv64a(transmute([]byte)fmt.tprintf("%s\x00", n), blob_key)
	}
	output := fmt.tprintf("%s/%s.blob", out_dir, guid_text(p.guid))
	if cooked_key(output, .Mesh, format.mesh_layout()) == blob_key && !pass.force[a.meta.guid] {
		pass.current[.Mesh] += 1
		return blob_key, true
	}
	if !write_blob(output, finish_mesh(cook, p.guid, blob_key)) {
		report_error(&scratch.problems, output, 0, 0, "cannot write the mesh")
		return
	}
	pass.cooked[.Mesh] += 1
	return blob_key, true
}

// stage_cook_mesh converts a part of a mesh to corners on the engine's axes in meters, with v down as the engine's
// textures have it, and makes smooth normals for a mesh without its own.
@(private = "file")
stage_cook_mesh :: proc(a: Asset_Source, m: Cn_Usd_Mesh, p: Stage_Part, basis: matrix[3, 3]f64, scale: f64) -> Cook_Mesh {
	subsets := m.subsets[p.first:][:p.count]
	total := 0
	for s in subsets {
		total += int(s.count)
	}
	corners := make([]Vertex, total, context.temp_allocator)
	ranges := make([][2]int, len(subsets), context.temp_allocator)
	names := make([]string, len(subsets), context.temp_allocator)
	b: matrix[3, 3]f32
	for r in 0 ..< 3 {
		for col in 0 ..< 3 {
			b[r, col] = f32(basis[r, col])
		}
	}
	s := f32(scale)
	// The basis mirrors, which reverses the triangles, unless the mesh's own orientation is left-handed.
	order := m.left_handed != 0 ? [3]int{0, 1, 2} : [3]int{0, 2, 1}
	flags: format.Mesh_Flags
	if m.uv1 != nil {
		flags += {.UV1}
	}
	at := 0
	for sub, i in subsets {
		ranges[i].x = at
		names[i] = strings.clone(usd_string(sub.name), context.temp_allocator)
		for t := int(sub.first); t + 2 < int(sub.first + sub.count); t += 3 {
			for k in 0 ..< 3 {
				c := t + order[k]
				v := Vertex {
					tangent = {1, 0, 0, 1},
					color   = {1, 1, 1, 1},
				}
				v.position = b * [3]f32{m.positions[c * 3], m.positions[c * 3 + 1], m.positions[c * 3 + 2]} * s
				if m.normals != nil {
					v.normal = linalg.normalize0(b * [3]f32{m.normals[c * 3], m.normals[c * 3 + 1], m.normals[c * 3 + 2]})
				}
				if m.uv0 != nil {
					v.uv0 = {m.uv0[c * 2], 1 - m.uv0[c * 2 + 1]}
				}
				if m.uv1 != nil {
					v.uv1 = {m.uv1[c * 2], 1 - m.uv1[c * 2 + 1]}
				}
				corners[at] = v
				at += 1
			}
		}
		ranges[i].y = at
	}
	if m.normals == nil {
		smooth_normals(corners)
	}
	return Cook_Mesh {
		corners = corners[:at],
		ranges = ranges,
		names = names,
		flags = flags,
		generate_tangents = true,
		lod = stage_setting(a, "cluster_lod") == "true",
		collision = stage_setting(a, "collision") == "true",
		impostor_size = stage_setting(a, "impostor") == "true" ? 64 : 0,
		name = p.name,
		source_path = a.name,
	}
}

// smooth_normals gives every corner the area-weighted normal of the triangles that share its position.
@(private = "file")
smooth_normals :: proc(corners: []Vertex) {
	if len(corners) == 0 {
		return
	}
	positions := make([][3]f32, len(corners), context.temp_allocator)
	for v, i in corners {
		positions[i] = v.position
	}
	remap := make([]c.uint, len(corners), context.temp_allocator)
	count := int(meshopt_generateVertexRemap(&remap[0], nil, c.size_t(len(corners)), &positions[0], c.size_t(len(corners)), 12))
	sums := make([][3]f32, count, context.temp_allocator)
	for t := 0; t + 2 < len(corners); t += 3 {
		face := linalg.cross(corners[t + 1].position - corners[t].position, corners[t + 2].position - corners[t].position)
		for k in 0 ..< 3 {
			sums[remap[t + k]] += face
		}
	}
	for &v, i in corners {
		v.normal = linalg.normalize0(sums[remap[i]])
	}
}

@(private = "file")
float_text :: proc(v: f64) -> string {
	text := fmt.tprintf("%.7g", v)
	if !strings.contains_any(text, ".eEn") {
		text = fmt.tprintf("%s.0", text)
	}
	return text
}

@(private = "file")
vector_text :: proc(v: []f64) -> string {
	parts := make([]string, len(v), context.temp_allocator)
	for x, i in v {
		parts[i] = float_text(x)
	}
	return fmt.tprintf("[%s]", strings.join(parts, ", ", context.temp_allocator))
}

@(private = "file")
stage_blend :: proc(mat: Cn_Usd_Material) -> Stage_Blend {
	if mat.opacity.texture < 0 && mat.opacity.value[0] >= 1 {
		return .Opaque
	}
	return mat.opacity_threshold > 0 ? .Masked : .Transparent
}

// stage_instance_text is a material instance of the preview_surface parent that the material's blend and the mesh's
// sides pick, with the material's values and textures.
@(private = "file")
stage_instance_text :: proc(a: Asset_Source, usd: ^Cn_Usd, m: Stage_Material, textures: []Stage_Texture, flip_y: bool) -> string {
	mat: Cn_Usd_Material
	cn_usd_material(usd, m.material, &mat)
	blend := stage_blend(mat)
	parent, _ := format.meta_guid(PREVIEW_SURFACE_METAS[int(blend) * 2 + int(m.two_sided)])
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(&b, "material_instance 1")
	fmt.sbprintfln(&b, "# Generated from %s's material %s. The stage makes it again at each cook.", a.name, usd_string(mat.path))
	fmt.sbprintfln(&b, "parent = $%s", guid_text(parent))
	find :: proc(textures: []Stage_Texture, usd: ^Cn_Usd, a: Asset_Source, input: Cn_Usd_Input, usage: format.Texture_Usage) -> (format.Guid, bool) {
		if input.texture < 0 {
			return {}, false
		}
		tex: Cn_Usd_Texture
		cn_usd_texture(usd, input.texture, &tex)
		if usd_string(tex.resolved) == "" {
			return {}, false
		}
		name := stage_texture_name(a, usd, usd_string(tex.resolved), stage_role(usd, input, usage))
		for t in textures {
			if t.name == name {
				return t.guid, true
			}
		}
		return {}, false
	}
	value3 :: proc(v: [3]f32) -> [4]f64 {
		return {f64(v.x), f64(v.y), f64(v.z), 1}
	}
	base := value3(mat.diffuse.value)
	emissive := value3(mat.emissive.value)
	fmt.sbprintfln(&b, "base_color = %s", vector_text(base[:]))
	fmt.sbprintfln(&b, "metallic = %s", float_text(f64(mat.metallic.value[0])))
	fmt.sbprintfln(&b, "roughness = %s", float_text(f64(mat.roughness.value[0])))
	fmt.sbprintfln(&b, "emissive = %s", vector_text(emissive[:]))
	fmt.sbprintfln(&b, "opacity = %s", float_text(f64(mat.opacity.value[0])))
	if blend == .Masked {
		fmt.sbprintfln(&b, "opacity_threshold = %s", float_text(f64(mat.opacity_threshold)))
	}
	Slot :: struct {
		input:   Cn_Usd_Input,
		usage:   format.Texture_Usage,
		param:   string,
		switch_: string,
	}
	slots := [?]Slot {
		{mat.diffuse, .Color, "base_color_tex", "has_base_color_tex"},
		{mat.metallic, .Mask, "metallic_tex", "has_metallic_tex"},
		{mat.roughness, .Mask, "roughness_tex", "has_roughness_tex"},
		{mat.normal, .Normal, "normal_tex", "has_normal_tex"},
		{mat.emissive, .Color, "emissive_tex", "has_emissive_tex"},
	}
	transform: Maybe(Cn_Usd_Texture)
	for slot in slots {
		if guid, found := find(textures, usd, a, slot.input, slot.usage); found {
			fmt.sbprintfln(&b, "%s = $%s", slot.param, guid_text(guid))
			fmt.sbprintfln(&b, "%s = true", slot.switch_)
			tex: Cn_Usd_Texture
			cn_usd_texture(usd, slot.input.texture, &tex)
			if tex.has_transform != 0 && transform == nil {
				transform = tex
			}
		}
	}
	if mat.opacity.texture >= 0 {
		if mat.opacity.texture == mat.diffuse.texture && mat.opacity.channel == .A {
			fmt.sbprintln(&b, "opacity_from_base_alpha = true")
		} else if guid, found := find(textures, usd, a, mat.opacity, .Mask); found {
			fmt.sbprintfln(&b, "opacity_tex = $%s", guid_text(guid))
			fmt.sbprintln(&b, "has_opacity_tex = true")
		}
	}
	// A UsdTransform2d maps st, with v up, so the engine's v, which is 1 - v, gets an offset of its own.
	if tex, found := transform.?; found {
		sx, sy := f64(tex.transform_scale.x), f64(tex.transform_scale.y)
		tx, ty := f64(tex.transform_translation.x), f64(tex.transform_translation.y)
		fmt.sbprintfln(&b, "uv_transform = %s", vector_text([]f64{sx, sy, tx, 1 - sy - ty}))
		fmt.sbprintln(&b, "use_uv_transform = true")
	}
	return strings.to_string(b)
}

// Stage_Entity is an entity of a stage's prefab as the cooker generates it.
@(private = "file")
Stage_Entity :: struct {
	id:        u64,
	parent:    u64,
	name:      string,
	// A child's pose under its parent, in meters on the engine's axes. The root has none.
	offset:    [3]f64,
	rotation:  quaternion256,
	scale:     [3]f64,
	mesh:      format.Guid,
	materials: [STAGE_MAX_SLOTS]format.Guid,
}

@(private = "file")
entity_id :: proc(path: string) -> u64 {
	id := hash.fnv64a(transmute([]byte)path)
	return id == 0 ? 1 : id
}

// stage_pose is a USD matrix, row-major for row vectors, as an offset, rotation and scale on the engine's axes in meters.
// It is false for a matrix with shear, which an entity's pose cannot hold; the pose is then the closest without it.
@(private = "file")
stage_pose :: proc(m: [16]f64, basis: matrix[3, 3]f64, scale: f64) -> (offset: [3]f64, rotation: quaternion256, size: [3]f64, exact: bool) {
	// The USD matrix's upper 3x3, for column vectors, is its transpose.
	l: matrix[3, 3]f64
	for r in 0 ..< 3 {
		for c in 0 ..< 3 {
			l[r, c] = m[c * 4 + r]
		}
	}
	l = basis * l * linalg.transpose(basis)
	offset = basis * [3]f64{m[12], m[13], m[14]} * scale
	columns := [3][3]f64{{l[0, 0], l[1, 0], l[2, 0]}, {l[0, 1], l[1, 1], l[2, 1]}, {l[0, 2], l[1, 2], l[2, 2]}}
	for col, i in columns {
		size[i] = linalg.length(col)
	}
	if linalg.determinant(l) < 0 {
		size.x = -size.x
	}
	r: matrix[3, 3]f64
	for i in 0 ..< 3 {
		col := size[i] != 0 ? columns[i] / size[i] : [3]f64{}
		r[0, i], r[1, i], r[2, i] = col.x, col.y, col.z
	}
	exact = true
	for i in 0 ..< 3 {
		for j in i + 1 ..< 3 {
			a := [3]f64{r[0, i], r[1, i], r[2, i]}
			b := [3]f64{r[0, j], r[1, j], r[2, j]}
			exact &&= abs(linalg.dot(a, b)) < 1e-3
		}
	}
	rotation = linalg.normalize(linalg.quaternion_from_matrix3_f64(r))
	return
}

// stage_prefab_text is the prefab of the whole stage: a root at the origin, an entity for each prim that holds a mesh
// or one below it, posed under its parent, and an entity for each instance, posed in the stage.
@(private = "file")
stage_prefab_text :: proc(a: Asset_Source, usd: ^Cn_Usd, info: Cn_Usd_Info, parts: []Stage_Part, materials: []Stage_Material, problems: ^Problems) -> string {
	basis, scale := stage_basis(a, info)
	entities := make([dynamic]Stage_Entity, context.temp_allocator)
	root := Stage_Entity {
		id   = entity_id("/"),
		name = filepath.stem(a.path),
	}
	append(&entities, root)

	parts_of := make(map[i32][dynamic]Stage_Part, context.temp_allocator)
	for p in parts {
		list := parts_of[p.mesh] or_else make([dynamic]Stage_Part, context.temp_allocator)
		append(&list, p)
		parts_of[p.mesh] = list
	}
	instance_of := make(map[[2]i32]format.Guid, context.temp_allocator)
	for m in materials {
		instance_of[{m.material, i32(m.two_sided)}] = m.guid
	}
	add_renderer :: proc(e: ^Stage_Entity, p: Stage_Part, mesh: Cn_Usd_Mesh, override: i32, instance_of: map[[2]i32]format.Guid) {
		e.mesh = p.guid
		for s, i in mesh.subsets[p.first:][:p.count] {
			material := override >= 0 ? override : s.material
			if material >= 0 {
				e.materials[i] = instance_of[{material, override >= 0 ? 0 : mesh.double_sided}]
			}
		}
	}
	// A mesh of several parts is an entity with a child for each.
	add_mesh :: proc(entities: ^[dynamic]Stage_Entity, e: ^Stage_Entity, usd: ^Cn_Usd, mesh: i32, path: string, override: i32, parts_of: map[i32][dynamic]Stage_Part, instance_of: map[[2]i32]format.Guid) {
		list, found := parts_of[mesh]
		if !found {
			return
		}
		m: Cn_Usd_Mesh
		if cn_usd_mesh(usd, mesh, &m) == 0 {
			return
		}
		if len(list) == 1 {
			add_renderer(e, list[0], m, override, instance_of)
			return
		}
		for p, i in list {
			child := Stage_Entity {
				id       = entity_id(fmt.tprintf("%s#%d", path, i + 1)),
				parent   = e.id,
				name     = fmt.tprintf("%s part %d", e.name, i + 1),
				rotation = 1,
				scale    = {1, 1, 1},
			}
			add_renderer(&child, p, m, override, instance_of)
			append(entities, child)
		}
	}

	// A prim is kept when it holds a mesh or one below it. The nodes are in pre-order, so a node's descendants follow
	// it, and walking backwards reaches every child before its parent.
	nodes := make([]Cn_Usd_Node, info.node_count, context.temp_allocator)
	keep := make([]bool, info.node_count, context.temp_allocator)
	for i in 0 ..< info.node_count {
		cn_usd_node(usd, i, &nodes[i])
	}
	for i := int(info.node_count) - 1; i >= 0; i -= 1 {
		n := nodes[i]
		keep[i] ||= n.kind == .Mesh && n.visible != 0 && n.mesh >= 0
		if keep[i] && n.parent >= 0 {
			keep[n.parent] = true
		}
	}
	ids := make([]u64, info.node_count, context.temp_allocator)
	sheared := 0
	for n, i in nodes {
		if !keep[i] {
			continue
		}
		path := usd_string(n.path)
		e := Stage_Entity {
			id     = entity_id(path),
			parent = n.parent >= 0 ? ids[n.parent] : root.id,
			name   = strings.clone(usd_string(n.name), context.temp_allocator),
		}
		exact: bool
		e.offset, e.rotation, e.scale, exact = stage_pose(n.local, basis, scale)
		sheared += int(!exact)
		ids[i] = e.id
		if n.kind == .Mesh {
			add_mesh(&entities, &e, usd, n.mesh, path, -1, parts_of, instance_of)
		}
		append(&entities, e)
	}
	for i in 0 ..< info.instance_count {
		inst: Cn_Usd_Instance
		cn_usd_instance(usd, i, &inst)
		if inst.visible == 0 || inst.mesh < 0 {
			continue
		}
		path := fmt.tprintf("%s#instance%d", usd_string(inst.path), i)
		e := Stage_Entity {
			id     = entity_id(path),
			parent = root.id,
			name   = filepath.base(usd_string(inst.path)),
		}
		exact: bool
		e.offset, e.rotation, e.scale, exact = stage_pose(inst.world, basis, scale)
		sheared += int(!exact)
		add_mesh(&entities, &e, usd, inst.mesh, path, inst.material, parts_of, instance_of)
		append(&entities, e)
	}
	if sheared > 0 {
		report_warning(problems, a.path, 0, 0, "%d prims have a transform with shear, which an entity cannot hold; they are posed without it", sheared)
	}

	// The scene format sorts entities by ID; the root stays first, as the editor writes a prefab.
	slice.sort_by(entities[1:], proc(x, y: Stage_Entity) -> bool {return x.id < y.id})
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "# Generated from %s. The stage makes it again at each cook; place it in a scene, and override", a.name)
	fmt.sbprintln(&b, "# its entities there (see docs/content/kinds/stages.md#prefab).")
	fmt.sbprintln(&b, "scene 2")
	for e, i in entities {
		fmt.sbprintfln(&b, "\nentity %016x", e.id)
		name, _ := strings.replace_all(e.name, "\"", "\\\"", context.temp_allocator)
		fmt.sbprintfln(&b, "name = \"%s\"", name)
		if i == 0 {
			fmt.sbprintln(&b, "component 1 Transform")
			fmt.sbprintln(&b, "\tposition = [0, 0, 0]")
			fmt.sbprintln(&b, "\trotation = [0.0, 0.0, 0.0, 1.0]")
			fmt.sbprintln(&b, "\tscale = [1.0, 1.0, 1.0]")
			continue
		}
		fmt.sbprintfln(&b, "parent = @%016x", e.parent)
		q := e.rotation
		// A child's Transform is what propagation writes from its Local_Transform, so it must have one.
		fmt.sbprintln(&b, "component 1 Transform")
		fmt.sbprintln(&b, "\tposition = [0, 0, 0]")
		fmt.sbprintln(&b, "\trotation = [0.0, 0.0, 0.0, 1.0]")
		fmt.sbprintln(&b, "\tscale = [1.0, 1.0, 1.0]")
		fmt.sbprintln(&b, "component 2 Local_Transform")
		fmt.sbprintfln(&b, "\toffset = %s", vector_text([]f64{e.offset.x, e.offset.y, e.offset.z}))
		fmt.sbprintfln(&b, "\trotation = %s", vector_text([]f64{imag(q), jmag(q), kmag(q), real(q)}))
		fmt.sbprintfln(&b, "\tscale = %s", vector_text([]f64{e.scale.x, e.scale.y, e.scale.z}))
		if e.mesh != {} {
			fmt.sbprintln(&b, "component 33 Mesh_Renderer")
			fmt.sbprintfln(&b, "\tmesh = $%s", guid_text(e.mesh))
			for m, slot in e.materials {
				if m != {} {
					fmt.sbprintfln(&b, "\tmaterials.%d = $%s", slot, guid_text(m))
				}
			}
			fmt.sbprintln(&b, "\tcast_shadows = true")
		}
	}
	return strings.to_string(b)
}

// stage_report opens each stage as a cook would, and prints what it would make, to set against the renderer's limits
// (see docs/rendering/assets.md#gpu-residency): the meshes and textures that are resident at once, and the entities.
stage_report :: proc(paths: []string) -> bool {
	ok := true
	for path in paths {
		started := time.now()
		a := Asset_Source{path = forward_slashes(path), name = path}
		options_c := Cn_Usd_Options{point_instancers = 1}
		usd := cn_usd_open(strings.clone_to_cstring(path, context.temp_allocator), &options_c)
		defer cn_usd_close(usd)
		fmt.printfln("%s: opened in %v", path, time.since(started))
		if err := usd_string(cn_usd_error(usd)); err != "" {
			fmt.printfln("  cannot read it: %s", strings.trim_space(err))
			ok = false
			continue
		}
		info: Cn_Usd_Info
		cn_usd_info(usd, &info)
		problems: Problems
		materials, textures := stage_materials(a, usd, info, &problems)
		parts := stage_parts(a, usd, info)
		triangles, most_subsets := 0, 0
		for i in 0 ..< info.mesh_count {
			m: Cn_Usd_Mesh
			if cn_usd_mesh(usd, i, &m) != 0 {
				triangles += int(m.corner_count) / 3
				most_subsets = max(most_subsets, int(m.subset_count))
			}
		}
		fmt.printfln("  up %v, %g meters per unit", info.up, info.meters_per_unit)
		fmt.printfln("  prims %d, meshes %d (%d parts, at most %d subsets in one), triangles %d", info.node_count, info.mesh_count, len(parts), most_subsets, triangles)
		fmt.printfln("  material instances %d, textures %d", len(materials), len(textures))
		fmt.printfln("  instances %d (with point instancers), lights %d", info.instance_count, info.light_count)
		fmt.printfln("  resident at once: %d meshes and textures", len(parts) + len(textures))
	}
	return ok
}

@(private = "file")
write_generated :: proc(path, text: string, problems: ^Problems) -> bool {
	if existing, err := os.read_entire_file(path, context.temp_allocator); err == nil && string(existing) == text {
		return true
	}
	if !write_blob(path, transmute([]byte)text) {
		report_error(problems, path, 0, 0, "cannot write the generated text")
		return false
	}
	return true
}

@(private = "file")
kind_word :: proc(kind: format.Asset_Kind) -> string {
	return subasset_kind_name(kind)
}

@(private = "file")
write_manifest :: proc(path: string, m: Stage_Manifest) -> bool {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "key %016x", m.key)
	for f in m.files {
		fmt.sbprintfln(&b, "file %d %d %s", f.size, f.modified, f.path)
	}
	for s in m.subassets {
		fmt.sbprintfln(&b, "subasset %s %s %016x %s", kind_word(s.kind), guid_text(s.guid), s.key, s.name)
		if s.generated != "" {
			fmt.sbprintfln(&b, "generated %s", s.generated)
		}
	}
	return write_blob(path, transmute([]byte)strings.to_string(b))
}

@(private = "file")
read_manifest :: proc(path: string) -> (m: Stage_Manifest, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return
	}
	m.files = make([dynamic]Stage_File, context.temp_allocator)
	m.subassets = make([dynamic]Stage_Manifest_Subasset, context.temp_allocator)
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		word, _, tail := strings.partition(line, " ")
		switch word {
		case "key":
			m.key = strconv.parse_u64_of_base(tail, 16) or_return
		case "file":
			size_text, _, after := strings.partition(tail, " ")
			modified_text, _, path := strings.partition(after, " ")
			size := strconv.parse_i64(size_text) or_return
			modified := strconv.parse_i64(modified_text) or_return
			append(&m.files, Stage_File{size, modified, path})
		case "subasset":
			fields := strings.split_n(tail, " ", 4, context.temp_allocator)
			if len(fields) != 4 {
				return
			}
			kind := format.subasset_kind_of(fields[0])
			guid := format.guid_parse(fields[1]) or_return
			key := strconv.parse_u64_of_base(fields[2], 16) or_return
			append(&m.subassets, Stage_Manifest_Subasset{kind, guid, key, fields[3], ""})
		case "generated":
			if len(m.subassets) == 0 {
				return
			}
			m.subassets[len(m.subassets) - 1].generated = tail
		}
	}
	return m, m.key != 0
}

// manifest_current is whether a stage's last cook still stands: every file it read is as it was, the .meta file still
// gives each sub-asset its GUID, and each blob that it wrote is still there with its key.
@(private = "file")
manifest_current :: proc(m: Stage_Manifest, a: Asset_Source, out_dir: string) -> bool {
	for f in m.files {
		size, modified, ok := file_stamp(f.path)
		if !ok || size != f.size || modified != f.modified {
			return false
		}
	}
	for s in m.subassets {
		guid, found := format.meta_subasset(a.meta, subasset_kind_name(s.kind), s.name)
		if !found || guid != s.guid {
			return false
		}
		if s.key != 0 {
			layout := s.kind == .Texture ? format.texture_layout() : format.mesh_layout()
			if cooked_key(fmt.tprintf("%s/%s.blob", out_dir, guid_text(s.guid)), s.kind, layout) != s.key {
				return false
			}
		}
		if s.generated != "" && !os.exists(s.generated) {
			return false
		}
	}
	return true
}

// use_manifest takes a stage's sub-assets and generated texts from its last cook.
@(private = "file")
use_manifest :: proc(a: ^Asset_Source, m: Stage_Manifest, generated: ^[dynamic]Asset_Source, problems: ^Problems) -> bool {
	for s in m.subassets {
		append(&a.subassets, Subasset{s.kind, s.name, s.guid})
	}
	return add_generated(a^, m, generated, problems)
}

// add_generated adds a stage's generated texts to the pass's assets, as sources that it owns.
@(private = "file")
add_generated :: proc(a: Asset_Source, m: Stage_Manifest, generated: ^[dynamic]Asset_Source, problems: ^Problems) -> bool {
	ok := true
	for s in m.subassets {
		if s.generated == "" {
			continue
		}
		source, err := os.read_entire_file(s.generated, context.temp_allocator)
		if err != nil {
			report_error(problems, s.generated, 0, 0, "%v", err)
			ok = false
			continue
		}
		append(generated, Asset_Source {
			kind         = s.kind,
			root         = a.root,
			path         = s.generated,
			name         = fmt.tprintf("%s#%s", a.name, s.name),
			meta_text    = fmt.tprintf("guid = %s\n", guid_text(s.guid)),
			meta         = {guid = s.guid},
			source       = source,
			dependencies = make([dynamic]format.Guid, context.temp_allocator),
			subassets    = make([dynamic]Subasset, context.temp_allocator),
			owner        = a.meta.guid,
		})
	}
	return ok
}
