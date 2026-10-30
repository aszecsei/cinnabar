package cook

import "core:fmt"
import "core:testing"

import cook_link "cinnabar:engine/asset/cook_link"

@(test)
a_pass_reports_each_steps_progress :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/a.luau", "return 1"}, {"content/b.luau", "return 2"}, {"content/c.luau", "return 3"}})
	defer remove_tree(tree)
	for i in 0 ..< 3 {
		write_test_image(t, tree, fmt.tprintf("t%d.png", i), 8, 8)
	}
	options := tree_options(tree)
	reports: [dynamic]cook_link.Cook_Progress
	defer delete(reports)
	progress := Progress {
		data = &reports,
		report = proc(data: rawptr, p: cook_link.Cook_Progress) {
			append((^[dynamic]cook_link.Cook_Progress)(data), p)
		},
	}

	pass := cook(options, {.Script, .Texture}, progress = progress)
	testing.expect(t, pass.ok)
	// Without a delay or an interval, each job reports, and a step's counts only go up to its total.
	last: [cook_link.Asset_Kind]u32
	for r in reports {
		testing.expectf(t, r.done > last[r.kind] && r.done <= r.total && r.total == 3 && r.name == "", "%v", r)
		last[r.kind] = r.done
	}
	testing.expect_value(t, last[.Script], 3)
	testing.expect_value(t, last[.Texture], 3)

	// A pass that is done within the delay reports nothing.
	clear(&reports)
	progress.delay, progress.interval = PROGRESS_DELAY, PROGRESS_INTERVAL
	testing.expect_value(t, cook(options, {.Script, .Texture}, progress = progress).current[.Texture], 3)
	testing.expect_value(t, len(reports), 0)
}
