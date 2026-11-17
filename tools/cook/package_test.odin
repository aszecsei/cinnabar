package cook

import "core:encoding/endian"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:testing"

import "cinnabar:core/lz4"
import format "cinnabar:engine/asset/format"

@(private = "file")
HALL :: "a0000000000000000000000000000001"
@(private = "file")
YARD :: "a0000000000000000000000000000002"
@(private = "file")
MENU :: "a0000000000000000000000000000003"
@(private = "file")
DOOR :: "b0000000000000000000000000000001"
@(private = "file")
HELLO :: "b0000000000000000000000000000002"
@(private = "file")
STONE :: "c0000000000000000000000000000001"
@(private = "file")
MOSS :: "c0000000000000000000000000000002"
@(private = "file")
ROCK :: "c0000000000000000000000000000003"
@(private = "file")
BOX :: "d0000000000000000000000000000001"
@(private = "file")
WIND :: "e0000000000000000000000000000001"
@(private = "file")
VALE :: "f0000000000000000000000000000001"
@(private = "file")
NORTH :: "a0000000000000000000000000000011"
@(private = "file")
SOUTH :: "a0000000000000000000000000000012"
@(private = "file")
CAMP :: "a0000000000000000000000000000013"
@(private = "file")
FERN :: "c0000000000000000000000000000011"
@(private = "file")
REED :: "c0000000000000000000000000000012"
@(private = "file")
BARK :: "c0000000000000000000000000000013"
@(private = "file")
ASH :: "c0000000000000000000000000000014"

// package_tree is content of each kind that a bundle holds: two levels, the hall and the yard, and a menu that is not a
// level. Stone is in both levels, so it is global; moss is the hall's, and the box and the wind, which streams, are the
// yard's. Rock is the hall's and the menu's, and the menu is global, so rock is too. Hello is in no scene.
@(private = "file")
package_tree :: proc(t: ^testing.T) -> Tree {
	png := string(#load("testdata/2x2.png"))
	samples := make([]i16, 48000, context.temp_allocator)
	return make_tree(
		t,
		{
			{"content/scripts/door.luau", "return 1"},
			{"content/scripts/door.luau.meta", "guid = " + DOOR + "\n"},
			{"content/scripts/hello.luau", "return 2"},
			{"content/scripts/hello.luau.meta", "guid = " + HELLO + "\n"},
			{"content/textures/stone.png", png},
			{"content/textures/stone.png.meta", "guid = " + STONE + "\nusage = color\n"},
			{"content/textures/moss.png", png},
			{"content/textures/moss.png.meta", "guid = " + MOSS + "\nusage = color\n"},
			{"content/textures/rock.png", png},
			{"content/textures/rock.png.meta", "guid = " + ROCK + "\nusage = color\n"},
			{"content/meshes/box.mesh", MESH_TEMPLATE},
			{"content/meshes/box.mesh.meta", "guid = " + BOX + "\n"},
			{"content/audio/wind.wav", wav_of(samples)},
			{"content/audio/wind.wav.meta", "guid = " + WIND + "\nstream = true\n"},
			{
				"content/levels/hall.scene",
				"scene 2\nentity 0000000000000001\ncomponent 7 Renderer\n\ta = $" +
				STONE +
				"\n\tb = $" +
				MOSS +
				"\n\tc = $" +
				ROCK +
				"\nbehaviour " +
				DOOR +
				"\n",
			},
			{"content/levels/hall.scene.meta", "guid = " + HALL + "\n"},
			{
				"content/levels/yard.scene",
				"scene 2\nentity 0000000000000001\ncomponent 7 Renderer\n\ta = $" +
				STONE +
				"\n\tb = $" +
				BOX +
				"\n\tc = $" +
				WIND +
				"\n",
			},
			{"content/levels/yard.scene.meta", "guid = " + YARD + "\n"},
			{
				"content/levels/menu.scene",
				"scene 2\nentity 0000000000000001\ncomponent 7 Renderer\n\ta = $" + ROCK + "\n",
			},
			{"content/levels/menu.scene.meta", "guid = " + MENU + "\n"},
			{
				"project.settings",
				"output = Sdr\n" + format.BUNDLE_GLOBAL_SCENES_KEY + " = " + MENU + "\n",
			},
		},
	)
}

// wav_of is a mono .wav file of 16-bit PCM at the engine's rate.
@(private = "file")
wav_of :: proc(samples: []i16) -> string {
	size := len(samples) * size_of(i16)
	data := make([]byte, 44 + size, context.temp_allocator)
	copy(data[0:], "RIFF")
	endian.put_u32(data[4:], .Little, u32(36 + size))
	copy(data[8:], "WAVEfmt ")
	endian.put_u32(data[16:], .Little, 16)
	endian.put_u16(data[20:], .Little, 1)
	endian.put_u16(data[22:], .Little, 1)
	endian.put_u32(data[24:], .Little, 48000)
	endian.put_u32(data[28:], .Little, 48000 * size_of(i16))
	endian.put_u16(data[32:], .Little, size_of(i16))
	endian.put_u16(data[34:], .Little, 16)
	copy(data[36:], "data")
	endian.put_u32(data[40:], .Little, u32(size))
	return string(data)
}

@(private = "file")
guid_of :: proc(text: string) -> format.Guid {
	return format.guid_parse(text) or_else {}
}

// Read_Bundle is a bundle that the package step wrote, at the runtime's alignment.
@(private = "file")
Read_Bundle :: struct {
	data:         []byte,
	entries:      []format.Bundle_Entry,
	dependencies: []string,
}

// read_bundle reads a bundle, if there is one of the name.
@(private = "file")
read_bundle :: proc(t: ^testing.T, out, name: string) -> (bundle: Read_Bundle, found: bool) {
	data, err := os.read_entire_file(
		fmt.tprintf("%s/%s%s", out, name, format.BUNDLE_EXTENSION),
		context.temp_allocator,
	)
	if err != nil {
		return
	}
	bundle.data, _ = mem.alloc_bytes(len(data), format.BLOB_ALIGN, context.temp_allocator)
	copy(bundle.data, data)
	head := bundle.data[:format.bundle_head_size(bundle.data)]
	header, entries, ok := format.bundle_view(head, i64(len(bundle.data)))
	testing.expectf(t, ok, "%s does not check", name)
	if !ok {
		return
	}
	bundle.entries = entries
	bundle.dependencies = make(
		[]string,
		format.bundle_dependency_count(header),
		context.temp_allocator,
	)
	for &d, i in bundle.dependencies {
		d = format.bundle_dependency(head, header, i)
	}
	return bundle, true
}

// unpack is a blob of a bundle as the runtime loads it: decompressed if the bundle compresses it.
@(private = "file")
unpack :: proc(bundle: Read_Bundle, entry: format.Bundle_Entry) -> []byte {
	stored := bundle.data[entry.offset:][:entry.stored_size]
	if entry.codec == .None {
		return stored
	}
	blob := make([]byte, entry.size, context.temp_allocator)
	return blob if lz4.decompress(stored, blob) else nil
}

@(private = "file")
has :: proc(bundle: Read_Bundle, text: string) -> bool {
	_, found := format.bundle_find(bundle.entries, guid_of(text))
	return found
}

@(test)
a_release_cache_packs_into_a_bundle_for_each_level_and_one_for_the_rest :: proc(t: ^testing.T) {
	tree := package_tree(t)
	defer remove_tree(tree)
	options := tree_options(tree)
	options.config = .Release
	pass := cook(options, ALL_KINDS, log_problems = false)
	testing.expectf(t, pass.ok, "%v", pass.problems.list)
	out := fmt.tprintf("%s/bundles", tree.dir)
	testing.expect(
		t,
		package_content(
			{
				cache = options.cache,
				out = out,
				project = fmt.tprintf("%s/project.settings", tree.dir),
			},
		),
	)

	global, global_found := read_bundle(t, out, format.GLOBAL_BUNDLE)
	hall, hall_found := read_bundle(t, out, HALL)
	yard, yard_found := read_bundle(t, out, YARD)
	_, menu_found := read_bundle(t, out, MENU)
	testing.expect(t, global_found && hall_found && yard_found)
	testing.expect(t, !menu_found)
	testing.expect_value(t, len(global.dependencies), 0)
	testing.expect(t, slice.equal(hall.dependencies, []string{format.GLOBAL_BUNDLE}))
	testing.expect(t, slice.equal(yard.dependencies, []string{format.GLOBAL_BUNDLE}))
	testing.expect(
		t,
		has(global, STONE) && has(global, ROCK) && has(global, MENU) && has(global, HELLO),
	)
	testing.expect(t, has(hall, HALL) && has(hall, MOSS) && has(hall, DOOR))
	testing.expect(t, has(yard, YARD) && has(yard, BOX) && has(yard, WIND))
	testing.expect_value(t, len(global.entries) + len(hall.entries) + len(yard.entries), 10)
	wind, _ := format.bundle_find(yard.entries, guid_of(WIND))
	testing.expect_value(t, wind.codec, format.Bundle_Codec.None)

	// Every blob is its loose blob, compressed or not, and the script, the scenes and the mesh are smaller.
	for bundle in ([]Read_Bundle{global, hall, yard}) {
		for e in bundle.entries {
			buffer: [32]u8
			name := format.guid_format(e.guid, &buffer)
			testing.expectf(
				t,
				slice.equal(unpack(bundle, e), tree_blob(t, tree, e.guid)),
				"%s is not its loose blob",
				name,
			)
			if e.kind == .Script || e.kind == .Scene || e.kind == .Mesh {
				testing.expectf(t, e.codec == .Lz4, "%s is not compressed", name)
			}
		}
	}
}

@(test)
units_are_levels_and_what_only_they_reach :: proc(t: ^testing.T) {
	scene, other, shared, own, code :=
		guid_of(HALL), guid_of(YARD), guid_of(STONE), guid_of(MOSS), guid_of(HELLO)
	blobs := []Package_Blob {
		{guid = scene, kind = .Scene, references = {shared, own, other}},
		{guid = other, kind = .Scene, references = {shared}},
		{guid = shared, kind = .Texture},
		{guid = own, kind = .Material, references = {shared}},
		{guid = code, kind = .Script, references = {own}},
	}
	levels := assign_units(blobs, nil)
	testing.expect(
		t,
		slice.equal(levels, []Package_Unit{{scene, GLOBAL_UNIT}, {other, GLOBAL_UNIT}}),
	)
	// The hall names the yard, which stays in its own unit; the material is the hall's alone, but a global script names
	// it, so it is global.
	testing.expect_value(t, blobs[0].unit, 0)
	testing.expect_value(t, blobs[1].unit, 1)
	testing.expect_value(t, blobs[2].unit, GLOBAL_UNIT)
	testing.expect_value(t, blobs[3].unit, GLOBAL_UNIT)
	testing.expect_value(t, blobs[4].unit, GLOBAL_UNIT)

	blobs[4].references = nil
	levels = assign_units(blobs, {other})
	testing.expect(t, slice.equal(levels, []Package_Unit{{scene, GLOBAL_UNIT}}))
	testing.expect_value(t, blobs[1].unit, 0)
	testing.expect_value(t, blobs[3].unit, 0)
	testing.expect_value(t, blobs[2].unit, 0)
}

// chunk_tree is the package tree with a world, the vale, that the yard names. The vale has two chunks, north and south,
// and a camp that is persistent. Fern is north's alone and reed is south's alone. Bark is in both chunks, so it is the
// yard's, and so is ash, which the camp uses. South uses stone too, which the hall uses, so it stays global.
@(private = "file")
chunk_tree :: proc(t: ^testing.T) -> Tree {
	tree := package_tree(t)
	png := string(#load("testdata/2x2.png"))
	ENTITY :: "scene 2\nentity 0000000000000001\ncomponent 7 Renderer\n"
	files := [][2]string {
		{"content/textures/fern.png", png},
		{"content/textures/fern.png.meta", "guid = " + FERN + "\nusage = color\n"},
		{"content/textures/reed.png", png},
		{"content/textures/reed.png.meta", "guid = " + REED + "\nusage = color\n"},
		{"content/textures/bark.png", png},
		{"content/textures/bark.png.meta", "guid = " + BARK + "\nusage = color\n"},
		{"content/textures/ash.png", png},
		{"content/textures/ash.png.meta", "guid = " + ASH + "\nusage = color\n"},
		{"content/levels/north.scene", ENTITY + "\ta = $" + FERN + "\n\tb = $" + BARK + "\n"},
		{"content/levels/north.scene.meta", "guid = " + NORTH + "\n"},
		{
			"content/levels/south.scene",
			ENTITY + "\ta = $" + REED + "\n\tb = $" + BARK + "\n\tc = $" + STONE + "\n",
		},
		{"content/levels/south.scene.meta", "guid = " + SOUTH + "\n"},
		{"content/levels/camp.scene", ENTITY + "\ta = $" + ASH + "\n"},
		{"content/levels/camp.scene.meta", "guid = " + CAMP + "\n"},
		{
			"content/levels/vale.world",
			"world 1\nscene $" +
			CAMP +
			"\n\tpersistent = true\nscene $" +
			NORTH +
			"\n\tmin = [0, 0, 0]\n\tmax = [40, 10, 40]\n\tload_distance = 25\nscene $" +
			SOUTH +
			"\n\tmin = [0, 0, 40]\n\tmax = [40, 10, 80]\n\tload_distance = 25\n",
		},
		{"content/levels/vale.world.meta", "guid = " + VALE + "\n"},
		{
			"content/levels/yard.scene",
			ENTITY +
			"\ta = $" +
			STONE +
			"\n\tb = $" +
			BOX +
			"\n\tc = $" +
			WIND +
			"\n\td = $" +
			VALE +
			"\n",
		},
	}
	for f in files {
		path := fmt.tprintf("%s/%s", tree.dir, f[0])
		testing.expect(t, os.write_entire_file(path, transmute([]byte)f[1]) == nil)
	}
	return tree
}

@(test)
each_chunk_of_a_world_packs_into_its_own_bundle_under_its_level :: proc(t: ^testing.T) {
	tree := chunk_tree(t)
	defer remove_tree(tree)
	options := tree_options(tree)
	options.config = .Release
	pass := cook(options, ALL_KINDS, log_problems = false)
	testing.expectf(t, pass.ok, "%v", pass.problems.list)
	out := fmt.tprintf("%s/bundles", tree.dir)
	testing.expect(
		t,
		package_content(
			{
				cache = options.cache,
				out = out,
				project = fmt.tprintf("%s/project.settings", tree.dir),
			},
		),
	)

	global, global_found := read_bundle(t, out, format.GLOBAL_BUNDLE)
	yard, yard_found := read_bundle(t, out, YARD)
	north, north_found := read_bundle(t, out, NORTH)
	south, south_found := read_bundle(t, out, SOUTH)
	_, camp_found := read_bundle(t, out, CAMP)
	_, vale_found := read_bundle(t, out, VALE)
	testing.expect(t, global_found && yard_found && north_found && south_found)
	testing.expect(t, !camp_found && !vale_found)
	testing.expect(t, slice.equal(yard.dependencies, []string{format.GLOBAL_BUNDLE}))
	testing.expect(t, slice.equal(north.dependencies, []string{YARD, format.GLOBAL_BUNDLE}))
	testing.expect(t, slice.equal(south.dependencies, []string{YARD, format.GLOBAL_BUNDLE}))
	// Each chunk holds its scene and what it alone uses.
	testing.expect(t, has(north, NORTH) && has(north, FERN))
	testing.expect(t, has(south, SOUTH) && has(south, REED))
	testing.expect_value(t, len(north.entries), 2)
	testing.expect_value(t, len(south.entries), 2)
	// What both chunks use, the world, its persistent scene and what that uses are the level's.
	testing.expect(
		t,
		has(yard, YARD) && has(yard, BARK) && has(yard, VALE) && has(yard, CAMP) && has(yard, ASH),
	)
	// What another level uses too is global.
	testing.expect(t, has(global, STONE))
}

@(private = "file")
world_blob :: proc(scenes: []format.Guid, persistent: format.Guid) -> []byte {
	records := make([]format.World_Scene_Record, len(scenes), context.temp_allocator)
	for &r, i in records {
		r.guid = scenes[i]
		if scenes[i] == persistent {
			r.flags = {.Persistent}
		}
	}
	data := format.world_write({scenes = records}, context.temp_allocator)
	aligned, _ := mem.alloc_bytes(len(data), format.BLOB_ALIGN, context.temp_allocator)
	copy(aligned, data)
	return aligned
}

@(test)
a_chunk_is_under_the_one_level_that_reaches_its_world :: proc(t: ^testing.T) {
	hall, yard, vale := guid_of(HALL), guid_of(YARD), guid_of(VALE)
	north, south, camp, bark := guid_of(NORTH), guid_of(SOUTH), guid_of(CAMP), guid_of(BARK)
	blobs := []Package_Blob {
		{guid = hall, kind = .Scene},
		{guid = yard, kind = .Scene, references = {vale}},
		{
			guid = vale,
			kind = .World,
			data = world_blob({camp, north, south}, camp),
			references = {camp, north, south},
		},
		{guid = north, kind = .Scene, references = {bark}},
		{guid = south, kind = .Scene, references = {bark}},
		{guid = camp, kind = .Scene},
		{guid = bark, kind = .Texture},
	}
	units := assign_units(blobs, nil)
	testing.expect(
		t,
		slice.equal(
			units,
			[]Package_Unit{{hall, GLOBAL_UNIT}, {yard, GLOBAL_UNIT}, {north, 1}, {south, 1}},
		),
	)
	// The world and its persistent scene are the yard's, each chunk is its own, and what both chunks use is the yard's.
	testing.expect_value(t, blobs[2].unit, 1)
	testing.expect_value(t, blobs[3].unit, 2)
	testing.expect_value(t, blobs[4].unit, 3)
	testing.expect_value(t, blobs[5].unit, 1)
	testing.expect_value(t, blobs[6].unit, 1)

	// When two levels reach the world, its chunks have no level, and what they share is global.
	blobs[0].references = {vale}
	units = assign_units(blobs, nil)
	testing.expect(
		t,
		slice.equal(
			units,
			[]Package_Unit {
				{hall, GLOBAL_UNIT},
				{yard, GLOBAL_UNIT},
				{north, GLOBAL_UNIT},
				{south, GLOBAL_UNIT},
			},
		),
	)
	testing.expect_value(t, blobs[2].unit, GLOBAL_UNIT)
	testing.expect_value(t, blobs[3].unit, 2)
	testing.expect_value(t, blobs[6].unit, GLOBAL_UNIT)

	// When no level reaches the world, each chunk is still a unit without a level.
	blobs[0].references = nil
	blobs[1].references = nil
	units = assign_units(blobs, nil)
	testing.expect_value(t, len(units), 4)
	testing.expect_value(t, units[2].parent, GLOBAL_UNIT)
	testing.expect_value(t, blobs[3].unit, 2)
	testing.expect_value(t, blobs[6].unit, GLOBAL_UNIT)

	// A scene that global_scenes names is not a chunk, so it goes with the level that alone reaches it, as what it uses
	// does.
	blobs[1].references = {vale}
	units = assign_units(blobs, {south})
	testing.expect(
		t,
		slice.equal(units, []Package_Unit{{hall, GLOBAL_UNIT}, {yard, GLOBAL_UNIT}, {north, 1}}),
	)
	testing.expect_value(t, blobs[3].unit, 2)
	testing.expect_value(t, blobs[4].unit, 1)
	testing.expect_value(t, blobs[6].unit, 1)
}
