package cook

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import cook_link "cinnabar:engine/asset/cook_link"
import format "cinnabar:engine/asset/format"

@(test)
settle_counts_and_fail_pending_fails_the_rest :: proc(t: ^testing.T) {
	pass := Pass {
		assets = make([]Asset_Source, 3, context.temp_allocator),
	}
	pass.assets[0].kind = .Script
	pass.assets[1].kind = .Script
	pass.assets[2].kind = .Scene
	settle(&pass, 0, .Cooked)
	fail_pending(&pass, {.Script})
	testing.expect_value(t, pass.assets[0].result, Asset_Result.Cooked)
	testing.expect_value(t, pass.assets[1].result, Asset_Result.Failed)
	// Another kind's pass has not reached it.
	testing.expect_value(t, pass.assets[2].result, Asset_Result.Pending)
	testing.expect_value(t, pass.cooked[.Script], 1)
	testing.expect_value(t, pass.current[.Script], 0)
	testing.expect_value(t, link_status(.Pending), cook_link.Asset_Status.Failed)
	testing.expect_value(t, link_status(.Blocked), cook_link.Asset_Status.Failed)
	testing.expect_value(t, link_status(.Cooked), cook_link.Asset_Status.Current)
}

// When a kind's pass stops before its loop, as when it cannot make the cache's directory, none of the kind's assets is
// current (#325). The kinds without such a stop, the shading models and the material functions, are left out.
@(test)
a_pass_that_stops_early_fails_its_kind :: proc(t: ^testing.T) {
	kinds := ALL_KINDS - {.Shading_Model, .Material_Function}
	files := make([dynamic]struct {
			path, text: string,
		}, context.temp_allocator)
	for kind in kinds {
		append(&files, struct {
				path, text: string,
			}{fmt.tprintf("content/a%s", extension_of(kind)), "return 1"})
	}
	tree := make_tree(t, files[:])
	defer remove_tree(tree)
	options := tree_options(tree)
	// Windows takes no < in a name, so no pass can make the cache's directory.
	options.cache = fmt.tprintf("%s/cache<", tree.dir)
	// With DXC, the shaders reach their directory too.
	if dxc, err := os.get_absolute_path("vendor/dxc/1.9.2609/dxc.exe", context.temp_allocator); err == nil {
		if version, ok := dxc_version(dxc); ok {
			options.dxc, options.dxc_version = dxc, version
		}
	}

	pass := cook(options, ALL_KINDS, log_problems = false)
	testing.expect(t, !pass.ok)
	stopped := false
	for p in pass.problems.list {
		stopped ||= strings.has_prefix(p.file, options.cache) && p.error
	}
	testing.expectf(t, stopped, "no pass reported the cache's directory: %v", pass.problems.list)
	found: Asset_Kinds
	for a in pass.assets {
		found += {a.kind}
		testing.expectf(t, asset_failed(a.result), "%s is %v", a.name, a.result)
	}
	testing.expect_value(t, found, kinds)

	index: Index
	index_build(&index, pass, options.roots[:])
	defer index_destroy(&index)
	for _, a in index.assets {
		testing.expectf(t, a.status == .Failed, "%s is %v in the index", a.path, a.status)
	}
	testing.expect_value(t, pass.cooked, [format.Asset_Kind]int{})
	testing.expect_value(t, pass.current, [format.Asset_Kind]int{})
}
