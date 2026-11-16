package cook

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import format "cinnabar:engine/asset/format"

@(private = "file")
INSTANCES :: `instances 1
# Three instances.
i 1.5 0 -2 0 0.3826834 0 0.9238795 1 1 1
i 0 0 0 0 0 0 1 2 2 2
i 4 0 4 0 0 0 -2 1 1 1
`

@(test)
instance_sets_cook_to_blobs_that_view :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/foliage/grass.instances", INSTANCES}})
	defer remove_tree(tree)
	pass := cook(tree_options(tree), {.Instance_Set}, log_problems = false)
	testing.expect(t, pass.ok)
	testing.expect_value(t, pass.cooked[.Instance_Set], 1)
	data := tree_blob(t, tree, tree_guid(t, tree, "foliage/grass.instances"))
	blob, ok := format.instance_set_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, blob.count, 3)
	testing.expect_value(t, blob.max_scale, 2)
	testing.expect_value(t, string(format.blob_bytes(data, blob.name)), "grass")
	instances := format.instance_set_instances(data, blob)
	points := 0
	for i in instances {
		// The third pose's rotation is zero but for w, which a pose keeps at least 0.
		points += 1 << i.point
		testing.expect(t, i.rotation.w >= 0)
	}
	testing.expect_value(t, points, 7)
}

@(test)
instance_set_mistakes_are_errors_at_their_lines :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/bad.instances", "instances 1\ni 0 0 0 0 0 0 1 1 1\n"}})
	defer remove_tree(tree)
	pass := cook(tree_options(tree), {.Instance_Set}, log_problems = false)
	testing.expect(t, !pass.ok)
	testing.expect_value(t, pass.cooked[.Instance_Set], 0)
	found := false
	for p in pass.problems.list {
		found ||= p.error && p.line == 2 && strings.contains(p.file, "bad.instances")
	}
	testing.expectf(t, found, "an error at line 2: %v", pass.problems.list)
}

@(test)
instance_sets_are_current_on_a_second_cook_and_a_bad_edit_keeps_the_blob :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/grass.instances", INSTANCES}})
	defer remove_tree(tree)
	options := tree_options(tree)
	testing.expect(t, cook(options, {.Instance_Set}, log_problems = false).ok)
	again := cook(options, {.Instance_Set}, log_problems = false)
	testing.expect(t, again.ok)
	testing.expect_value(t, again.cooked[.Instance_Set], 0)
	testing.expect_value(t, again.current[.Instance_Set], 1)
	guid := tree_guid(t, tree, "grass.instances")
	path := fmt.tprintf("%s/content/grass.instances", tree.dir)
	testing.expect(t, os.write_entire_file(path, "instances 1\ni 0 0 x 0 0 0 1 1 1 1\n") == nil)
	broken := cook(options, {.Instance_Set}, log_problems = false)
	testing.expect(t, !broken.ok)
	_, ok := format.instance_set_view(tree_blob(t, tree, guid))
	testing.expect(t, ok)
}
