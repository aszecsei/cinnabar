package render

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:sync"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/gpu"
import null "cinnabar:core/gpu/null"
import "cinnabar:core/jobs"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"

// The pipelines that the test's backend has not compiled yet.
@(private = "file")
compiling: [dynamic]gpu.Pipeline

// any_blob is a material blob whose variants are fake bytecode, which the null backend takes, for each pass that its
// blend has: the opaque passes, with the mesh shader path's stages unless it draws patches, or the transparent ones.
@(private = "file")
any_blob :: proc(guid: format.Guid, blend: format.Material_Blend, flags: format.Material_Flags = {}) -> []byte {
	code := []byte{1}
	variants := make([dynamic]format.Material_Variant_Entry, context.temp_allocator)
	if format.material_transparent(blend) {
		passes := []format.Material_Pass{.Transparent, .Transparent_Ids, .Moments}
		for pass in passes[:blend == .Transparent ? 3 : 2] {
			append(&variants, format.Material_Variant_Entry{0, pass, .Vertex, code}, format.Material_Variant_Entry{0, pass, .Pixel, code})
		}
	} else {
		for pass in ([]format.Material_Pass{.Forward, .Prepass, .Depth}) {
			append(&variants, format.Material_Variant_Entry{0, pass, .Vertex, code}, format.Material_Variant_Entry{0, pass, .Pixel, code})
			if .Patches not_in flags {
				append(&variants, format.Material_Variant_Entry{0, pass, .Amplification, code}, format.Material_Variant_Entry{0, pass, .Mesh, code})
			}
		}
	}
	contents := format.Material_Contents {
		guid        = guid,
		flags       = flags,
		blend       = blend,
		block       = make([]byte, 16, context.temp_allocator),
		variants    = variants[:],
		source_path = "test.material",
	}
	return format.material_write(contents, context.temp_allocator)
}

@(test)
a_bin_draws_with_its_blend_modes_substitute_until_its_pipelines_compile :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	testing.expect(t, jobs.init(2))
	defer jobs.shutdown()
	testing.expect(t, null.init(nil, {64, 32}))
	defer null.shutdown()
	compiling = make([dynamic]gpu.Pipeline)
	defer delete(compiling)
	platform := core.Platform_API {
		frame_allocator              = virtual.arena_allocator(&arena),
		heap_allocator               = runtime.heap_allocator(),
		asset_allocator              = runtime.heap_allocator(),
		file_read                    = core.file_read,
		file_modified                = core.file_modified,
		jobs_run                     = jobs.run,
		jobs_wait                    = jobs.wait,
		gpu_frame_target             = null.frame_target,
		gpu_submit                   = null.submit,
		gpu_upload                   = null.upload,
		gpu_create_texture           = null.create_texture,
		gpu_destroy_texture          = null.destroy_texture,
		gpu_create_buffer            = null.create_buffer,
		gpu_destroy_buffer           = null.destroy_buffer,
		gpu_create_sampler           = null.create_sampler,
		gpu_destroy_sampler          = null.destroy_sampler,
		gpu_create_graphics_pipeline = null.create_graphics_pipeline,
		gpu_update_graphics_pipeline = null.update_graphics_pipeline,
		gpu_destroy_pipeline         = null.destroy_pipeline,
		gpu_pipeline_ready           = proc(pipeline: gpu.Pipeline) -> bool {return !slice.contains(compiling[:], pipeline)},
	}
	dir, err := os.make_directory_temp("", "substitutes_test_*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	assets: asset.Assets
	asset.init(&assets, &platform, asset.loose_cache(dir))
	defer asset.destroy(&assets)
	r := new(Renderer)
	defer free(r)
	r.platform = &platform
	r.residency.assets = &assets
	r.residency.frame = 1
	r.caps.mesh_shaders = true
	materials_init(&r.materials, &platform)
	defer materials_destroy(&r.materials, &platform)

	// The cache holds the substitutes, as the engine's content cooks them.
	substitutes := [Substitute]struct {
		blend: format.Material_Blend,
		flags: format.Material_Flags,
	} {
		.Opaque      = {.Opaque, {}},
		.Transparent = {.Transparent, {}},
		.Additive    = {.Additive, {}},
		.Patches     = {.Opaque, {.Patches}},
	}
	for s, kind in substitutes {
		guid := r.materials.substitutes[kind]
		buffer: [32]u8
		path := fmt.tprintf("%s/%s.blob", dir, format.guid_format(guid, &buffer))
		testing.expect(t, os.write_entire_file(path, any_blob(guid, s.blend, s.flags)) == nil)
	}

	// A material of each blend mode, and of patches, whose pipelines have not compiled.
	reals := []struct {
		blend: format.Material_Blend,
		flags: format.Material_Flags,
		kind:  Maybe(Substitute),
	} {
		{.Opaque, {}, .Opaque},
		{.Masked, {}, .Opaque},
		{.Transparent, {}, .Transparent},
		{.Transparent, {.Sorted, .Two_Sided}, .Transparent},
		{.Additive, {}, .Additive},
		{.Opaque, {.Patches}, .Patches},
		{.Transparent, {.Patches}, nil},
	}
	bins := make([]int, len(reals), context.temp_allocator)
	for c, i in reals {
		guid := format.Guid{0 = u8(i + 1), 15 = 0xbb}
		data := any_blob(guid, c.blend, c.flags)
		blob, _ := format.material_view(data)
		p := &r.materials.pipelines[i]
		p.material = guid
		make_pipelines(r, p, data, blob, 0)
		for pipeline in p.pipelines {
			append(&compiling, pipeline)
		}
		for pipeline in p.meshes {
			append(&compiling, pipeline)
		}
		for pipeline in p.over {
			append(&compiling, pipeline)
		}
		bins[i] = i
	}
	r.materials.pipeline_count = len(reals)

	draws := bin_draws(r, bins)
	for c, i in reals {
		real := &r.materials.pipelines[i]
		kind, has := c.kind.?
		if !has {
			testing.expectf(t, draws[i] == i, "bin %d has no substitute but draws with %d", i, draws[i])
			continue
		}
		testing.expectf(t, draws[i] != i, "bin %d does not draw with a substitute", i)
		s := &r.materials.pipelines[draws[i]]
		testing.expectf(t, s.material == r.materials.substitutes[kind], "bin %d draws with the wrong substitute", i)
		// The substitute draws the passes of the bin's group: the sorted draws blend over the scene with its over.
		if material_group(real) == .Sorted {
			testing.expect(t, s.over[1] != {})
			testing.expect_value(t, s.blend, real.blend)
		} else {
			testing.expect_value(t, material_group(s), material_group(real))
		}
		testing.expect_value(t, s.patches, real.patches)
	}
	// Each substitute is made once, whichever bins wait for it.
	testing.expect_value(t, draws[0], draws[1])
	testing.expect_value(t, draws[2], draws[3])
	testing.expect_value(t, r.materials.pipeline_count, len(reals) + len(Substitute))

	// A substitute that has not compiled either is no substitute for itself.
	opaque := draws[0]
	for pipeline in r.materials.pipelines[opaque].pipelines {
		append(&compiling, pipeline)
	}
	testing.expect_value(t, bin_draws(r, {opaque})[0], opaque)

	// The frame after a bin's pipelines compile, it draws with them.
	clear(&compiling)
	testing.expect(t, slice.equal(bin_draws(r, bins), bins))
}
