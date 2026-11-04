package render

import "core:math"
import "core:math/linalg"
import "core:testing"

@(private = "file")
test_selection :: proc(levels := 11, bias: f32 = 0) -> Virtual_Selection {
	// 1080 pixels over a 60 degree view.
	scale := 1 / math.tan(math.to_radians(f32(30)))
	return {
		levels = levels,
		first_texel = f32(virtual_level_texel(0)),
		pixel_angle = 2 / (scale * 1080),
		bias = bias,
	}
}

@(private = "file")
test_camera :: proc(
	offset: [3]f32 = {},
	forward: [3]f32 = {0, 0, 1},
	levels := 11,
	bias: f32 = 0,
) -> Virtual_Camera {
	scale := 1 / math.tan(math.to_radians(f32(30)))
	right := linalg.normalize(linalg.cross([3]f32{0, 1, 0}, forward))
	return {
		right = right,
		up = linalg.cross(forward, right),
		forward = forward,
		scale = {scale * 1080.0 / 1920.0, scale},
		near = 0.1,
		offset = offset,
		selection = test_selection(levels, bias),
	}
}

@(private = "file")
TEST_LIGHT := [3]f32{0.3, -0.8, 0.2}

@(private = "file")
test_views :: proc(c: Virtual_Camera, allocator := context.temp_allocator) -> []Shadow_View {
	views := make([]Shadow_View, c.selection.levels, allocator)
	direction := linalg.normalize(TEST_LIGHT)
	for &view, level in views {
		view = virtual_level(c, direction, level).view
	}
	return views
}

@(private = "file")
test_buffers :: proc(
	levels: int,
	allocator := context.temp_allocator,
) -> (
	requests, table: []u32,
) {
	requests = make([]u32, levels * VIRTUAL_LEVEL_WORDS, allocator)
	table = make([]u32, levels * VIRTUAL_LEVEL_PAGES, allocator)
	for &entry in table {
		entry = VIRTUAL_NO_PAGE
	}
	return
}

@(private = "file")
is_marked :: proc(requests: []u32, level: int, page: [2]i32) -> bool {
	index := level * VIRTUAL_LEVEL_PAGES + int(page.y) * VIRTUAL_PAGES + int(page.x)
	return requests[index >> 5] & (1 << uint(index & 31)) != 0
}

@(private = "file")
count_marked :: proc(requests: []u32) -> (count: int) {
	for word in requests {
		for b in 0 ..< uint(32) {
			if word & (1 << b) != 0 {
				count += 1
			}
		}
	}
	return
}

@(test)
each_level_is_twice_the_extent_of_the_one_before :: proc(t: ^testing.T) {
	testing.expect_value(t, virtual_level_extent(0), VIRTUAL_FIRST_EXTENT)
	for level in 1 ..< VIRTUAL_MAX_LEVELS {
		testing.expect_value(t, virtual_level_extent(level), 2 * virtual_level_extent(level - 1))
	}
}

@(test)
a_level_is_a_virtual_texture_of_16384_texels_in_pages_of_128 :: proc(t: ^testing.T) {
	testing.expect_value(t, VIRTUAL_SIZE, 16384)
	testing.expect_value(t, VIRTUAL_PAGE_TEXELS, 128)
}

@(test)
every_level_with_a_virtual_shadow_map_reaches_1_km :: proc(t: ^testing.T) {
	for level in Quality_Level.Medium ..= Quality_Level.Ultra {
		p := SHADOW_PARAMS[level]
		testing.expect(t, p.virtual_levels <= VIRTUAL_MAX_LEVELS)
		testing.expect(
			t,
			virtual_level_extent(p.virtual_levels - 1) * 0.5 >= 1000,
			"the coarsest level reaches 1 km",
		)
		// At 1 km at 1080p with a 60 degree view, the coarsest texel is no finer than a pixel's footprint, so a far view asks
		// for about as many pages as a near one.
		testing.expect(
			t,
			f32(virtual_level_texel(p.virtual_levels - 1)) >=
			0.7 * 1000 * test_selection().pixel_angle,
		)
		testing.expect(
			t,
			p.pool_pages.x * VIRTUAL_PAGE_TEXELS <= 16384 &&
			p.pool_pages.y * VIRTUAL_PAGE_TEXELS <= 16384,
			"the pool is a texture that a device can make",
		)
	}
	testing.expect_value(t, SHADOW_PARAMS[.Low].virtual_levels, 0)
}

@(test)
near_the_camera_a_level_has_smaller_texels_than_the_high_cascades_first :: proc(t: ^testing.T) {
	near: f32 = 0.1
	// The High cascades' first cascade, as add_cascades fits it for a 60 degree view at 16:9.
	split := cascade_splits(near, count = SHADOW_PARAMS[.High].cascades)[0]
	half_height := split * math.tan(math.to_radians(f32(30)))
	half_width := half_height * 16 / 9
	radius := linalg.length([3]f32{half_width, half_height, (split - near) * 0.5})
	cascade_texel := 2 * radius / f32(SHADOW_PARAMS[.High].cell)

	s := test_selection()
	for distance in ([]f32{0.5, 1, 2, 4}) {
		texel := f32(virtual_level_texel(virtual_footprint_level(s, distance)))
		testing.expect(t, texel < cascade_texel, "the texel is smaller than the first cascade's")
	}
}

@(test)
a_point_picks_the_level_whose_texel_is_nearest_its_footprint :: proc(t: ^testing.T) {
	s := test_selection(levels = 16)
	for distance in ([]f32{1, 7, 30, 300, 1000}) {
		level := virtual_footprint_level(s, distance)
		ratio := f32(virtual_level_texel(level)) / (distance * s.pixel_angle)
		testing.expect(
			t,
			ratio >= 0.7 && ratio <= 1.42,
			"the level's texel is within half a level of the footprint",
		)
	}
	testing.expect_value(t, virtual_footprint_level(s, 0), 0)
	testing.expect_value(t, virtual_footprint_level(test_selection(levels = 11), 1e7), 10)
}

@(test)
the_bias_moves_the_level :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		virtual_footprint_level(test_selection(levels = 16, bias = 1), 30),
		virtual_footprint_level(test_selection(levels = 16), 30) + 1,
	)
	testing.expect_value(
		t,
		virtual_footprint_level(test_selection(levels = 16, bias = -1), 30),
		virtual_footprint_level(test_selection(levels = 16), 30) - 1,
	)
}

@(test)
a_level_reaches_as_far_as_the_points_that_pick_it :: proc(t: ^testing.T) {
	s := test_selection()
	for level in 0 ..< s.levels - 1 {
		reach := virtual_level_reach(s, level)
		testing.expect(
			t,
			virtual_footprint_level(s, reach * 0.99) <= level,
			"a nearer point picks this level or a finer one",
		)
		testing.expect_value(t, virtual_footprint_level(s, reach * 1.01), level + 1)
	}
	testing.expect(
		t,
		math.is_inf(virtual_level_reach(s, s.levels - 1), 1),
		"the last level takes every farther point",
	)
}

@(test)
each_levels_pages_nest_in_the_next_levels :: proc(t: ^testing.T) {
	c := test_camera(offset = {123.4, 5.6, -789})
	views := test_views(c)
	// A point in a level's page is in the page's parent in the next level.
	for x in -40 ..= 40 {
		for z in -40 ..= 40 {
			p := [3]f32{f32(x) * 0.37, 1, f32(z) * 0.41}
			for level in 0 ..< len(views) - 1 {
				texel, _ := virtual_project(views[level], p)
				coarse, _ := virtual_project(views[level + 1], p)
				page := [2]i32 {
					i32(math.floor(texel.x / VIRTUAL_PAGE_TEXELS)),
					i32(math.floor(texel.y / VIRTUAL_PAGE_TEXELS)),
				}
				parent := [2]i32 {
					i32(math.floor(coarse.x / VIRTUAL_PAGE_TEXELS)),
					i32(math.floor(coarse.y / VIRTUAL_PAGE_TEXELS)),
				}
				nested := virtual_parent_page(
					views[level].page_origin,
					page,
					views[level + 1].page_origin,
				)
				testing.expect_value(t, nested, parent)
			}
		}
	}
}

// A level's corner is on a whole page of the render origin's space, wherever the camera is, so a page stays at the same
// texels as the camera moves, and the shadow's edges do not swim.
@(test)
a_levels_grid_stays_on_the_render_origins_pages_as_the_camera_moves :: proc(t: ^testing.T) {
	direction := linalg.normalize(TEST_LIGHT)
	// A point fixed in the render origin's space.
	anchor := [3]f32{10, 2, 20}
	for level in ([]int{0, 3, 8}) {
		first := test_camera()
		a := virtual_level(first, direction, level).view
		a_texel, _ := virtual_project(a, anchor - first.offset)
		for step in 1 ..= 40 {
			moved := test_camera(
				offset = {f32(step) * 0.173, f32(step) * 0.031, f32(step) * -0.219},
			)
			b := virtual_level(moved, direction, level).view
			b_texel, _ := virtual_project(b, anchor - moved.offset)
			// The anchor's texel moves by whole pages, as the level's origin does.
			pages := b.page_origin - a.page_origin
			expected := a_texel - [2]f32{f32(pages.x), f32(pages.y)} * VIRTUAL_PAGE_TEXELS
			testing.expectf(
				t,
				abs(b_texel.x - expected.x) < 0.2 && abs(b_texel.y - expected.y) < 0.2,
				"level %d at step %d: %v against %v",
				level,
				step,
				b_texel,
				expected,
			)
		}
	}
}

@(test)
turning_the_camera_moves_no_levels_grid_and_no_points_level :: proc(t: ^testing.T) {
	direction := linalg.normalize(TEST_LIGHT)
	offset := [3]f32{55.5, 3, -21}
	ahead := test_camera(offset = offset)
	turned := test_camera(offset = offset, forward = linalg.normalize([3]f32{0.8, 0.1, 0.6}))
	for level in 0 ..< ahead.selection.levels {
		a := virtual_level(ahead, direction, level)
		b := virtual_level(turned, direction, level)
		testing.expect_value(t, a.view.page_origin, b.view.page_origin)
		testing.expect_value(t, a.view.rows, b.view.rows)
		testing.expect_value(t, a.view.texel, b.view.texel)
	}
	testing.expect_value(
		t,
		virtual_footprint_level(ahead.selection, 42),
		virtual_footprint_level(turned.selection, 42),
	)
}

// A rebase moves the camera's offset from the origin by whole cells. Every level still holds the camera, and every
// point near it still finds its pages.
@(test)
a_rebase_leaves_every_level_valid_around_the_camera :: proc(t: ^testing.T) {
	before := [3]f32{1500, 10, -1400}
	for offset in ([][3]f32{before, before - {ORIGIN_CELL, 0, -ORIGIN_CELL}}) {
		c := test_camera(offset = offset)
		views := test_views(c)
		for view in views {
			texel, _ := virtual_project(view, {0, 0, 0})
			testing.expect(
				t,
				abs(texel.x - VIRTUAL_SIZE / 2) <= VIRTUAL_PAGE_TEXELS &&
				abs(texel.y - VIRTUAL_SIZE / 2) <= VIRTUAL_PAGE_TEXELS,
				"a level's middle is within a page of the camera",
			)
			testing.expect(
				t,
				virtual_in_rect(view, {i32(texel.x), i32(texel.y)}, {i32(texel.x), i32(texel.y)}),
				"the valid rectangle holds the camera",
			)
		}
		requests, table := test_buffers(len(views))
		p := [3]f32{1, -1, 5}
		level := virtual_footprint_level(c.selection, linalg.length(p))
		testing.expect_value(t, virtual_mark(requests, views, .Taps_4, p, level), level)
		virtual_allocate(requests, table, len(views), 1024)
		testing.expect_value(t, virtual_lookup(table, views, p, level), level)
	}
}

@(test)
the_valid_rectangle_holds_every_pixel_that_picks_the_level :: proc(t: ^testing.T) {
	c := test_camera()
	views := test_views(c)
	for level in 0 ..< len(views) {
		// A point on the frustum's edge, as far as the level reaches, or as the level's half extent for the last.
		reach := min(
			virtual_level_reach(c.selection, level) * 0.9,
			f32(virtual_level_extent(level)) * 0.4,
		)
		for sx in ([]f32{-1, 0, 1}) {
			for sy in ([]f32{-1, 0, 1}) {
				p :=
					c.right * (sx * reach / c.scale.x) +
					c.up * (sy * reach / c.scale.y) +
					c.forward * reach
				if linalg.length(p) > f32(virtual_level_extent(level)) * 0.45 {
					continue
				}
				texel, _ := virtual_project(views[level], p)
				at := [2]i32{i32(texel.x), i32(texel.y)}
				testing.expectf(
					t,
					virtual_in_rect(views[level], at, at),
					"level %d: %v is in %v",
					level,
					texel,
					views[level].rect,
				)
			}
		}
	}
}

@(test)
a_levels_scissor_is_its_valid_rectangle_and_much_less_than_its_extent_near_the_camera :: proc(
	t: ^testing.T,
) {
	c := test_camera()
	direction := linalg.normalize(TEST_LIGHT)
	for level in 0 ..< c.selection.levels {
		l := virtual_level(c, direction, level)
		testing.expect_value(t, f32(l.scissor.x), l.view.rect.x * VIRTUAL_SIZE)
		testing.expect_value(t, f32(l.scissor.y), l.view.rect.y * VIRTUAL_SIZE)
		testing.expect_value(t, f32(l.scissor.x + l.scissor.z), l.view.rect.z * VIRTUAL_SIZE)
		testing.expect_value(t, f32(l.scissor.y + l.scissor.w), l.view.rect.w * VIRTUAL_SIZE)
		testing.expect(
			t,
			l.scissor.x + l.scissor.z <= VIRTUAL_SIZE && l.scissor.y + l.scissor.w <= VIRTUAL_SIZE,
			"the scissor is in the level",
		)
	}
	// A middling level's pixels take a small part of it, so its depth pass costs far less than the level's whole area.
	l := virtual_level(c, direction, 5)
	area := u64(l.scissor.z) * u64(l.scissor.w)
	testing.expectf(
		t,
		area < VIRTUAL_SIZE * VIRTUAL_SIZE / 4,
		"%v of %v texels",
		area,
		VIRTUAL_SIZE * VIRTUAL_SIZE,
	)
}

@(test)
a_levels_culling_keeps_casters_toward_the_light_and_only_those_over_its_rectangle :: proc(
	t: ^testing.T,
) {
	c := test_camera()
	direction := linalg.normalize(TEST_LIGHT)
	inside :: proc(planes: [6][4]f32, p: [3]f32) -> bool {
		for plane in planes {
			if linalg.dot(plane.xyz, p) + plane.w < 0 {
				return false
			}
		}
		return true
	}
	l := virtual_level(c, direction, 4)
	// Far up the light from a point in view, past the level's own depth range, a caster still casts.
	in_view := c.forward * 5
	testing.expect(t, inside(l.planes, in_view))
	testing.expect(t, inside(l.planes, in_view - direction * 5000))
	// Far behind the level's depth range, it cannot cast on anything in view.
	testing.expect(t, !inside(l.planes, in_view + direction * 5000))
	// Across the light, past the valid rectangle, its texels are not drawn.
	right, _ := light_basis(direction)
	testing.expect(t, !inside(l.planes, in_view + right * f32(virtual_level_extent(4))))
}

@(test)
a_block_covers_as_many_texels_as_its_filter_reads :: proc(t: ^testing.T) {
	base, size := virtual_block({100.25, 200.75}, .Taps_1)
	testing.expect_value(t, base, [2]i32{99, 200})
	testing.expect_value(t, size, 2)
	base, size = virtual_block({100.25, 200.75}, .Taps_4)
	testing.expect_value(t, base, [2]i32{99, 199})
	testing.expect_value(t, size, 3)
	base, size = virtual_block({100.25, 200.75}, .Taps_9)
	testing.expect_value(t, base, [2]i32{98, 199})
	testing.expect_value(t, size, 4)
}

// The culling has only a level's planes and page fields, so they have to place a point where the level's projection does.
@(test)
a_levels_planes_and_page_fields_place_a_point_on_its_page :: proc(t: ^testing.T) {
	c := test_camera(offset = {123.4, 5.6, -789})
	direction := linalg.normalize(TEST_LIGHT)
	for level in 0 ..< c.selection.levels {
		l := virtual_level(c, direction, level)
		fields := virtual_page_fields(l.view, level)
		page := f32(virtual_level_extent(level)) / VIRTUAL_PAGES
		first := [2]i32{i32((fields >> 8) & 0xff), i32((fields >> 16) & 0xff)}
		testing.expect_value(t, int(fields & 0xff), level)
		for sx in ([]f32{-0.8, -0.3, 0.1, 0.7}) {
			for sy in ([]f32{-0.6, 0, 0.5}) {
				p := c.right * (sx * page * 3) + c.up * (sy * page * 3) + c.forward * page
				texel, _ := virtual_project(l.view, p)
				at := [2]f32{linalg.dot(l.planes[0].xyz, p) + l.planes[0].w, linalg.dot(l.planes[3].xyz, p) + l.planes[3].w} / page
				placed := at + [2]f32{f32(first.x), f32(first.y)}
				expected := texel / VIRTUAL_PAGE_TEXELS
				testing.expectf(t, abs(placed.x - expected.x) < 0.01 && abs(placed.y - expected.y) < 0.01, "level %d: %v against %v", level, placed, expected)
			}
		}
	}
}

@(test)
culling_keeps_only_what_reaches_a_page_that_was_allocated :: proc(t: ^testing.T) {
	c := test_camera()
	direction := linalg.normalize(TEST_LIGHT)
	views := test_views(c)
	requests, table := test_buffers(len(views))
	level := 6
	l := virtual_level(c, direction, level)
	fields := virtual_page_fields(l.view, level)
	p := c.forward * 5
	testing.expect_value(t, virtual_mark(requests, views, .Taps_1, p, level), level)
	virtual_allocate(requests, table, len(views), 64)
	page := f32(virtual_level_extent(level)) / VIRTUAL_PAGES
	right, _ := light_basis(direction)
	// On the page, and just reaching it from the next but one.
	testing.expect(t, virtual_reaches_pages(table, l.planes, fields, p, 0))
	testing.expect(t, virtual_reaches_pages(table, l.planes, fields, p + right * (page * 4), page * 4.5))
	// Far enough off the page that the sphere misses it.
	testing.expect(t, !virtual_reaches_pages(table, l.planes, fields, p + right * (page * 4), page * 0.5))
	// A level with no pages keeps nothing but a sphere too big to test.
	testing.expect(t, !virtual_reaches_pages(table, virtual_level(c, direction, 3).planes, virtual_page_fields(views[3], 3), p, 0))
	testing.expect(t, virtual_reaches_pages(table, l.planes, fields, p + right * (page * 4), page * VIRTUAL_CULL_PAGES))
	// Outside the level, it reaches nothing.
	testing.expect(t, !virtual_reaches_pages(table, l.planes, fields, right * f32(virtual_level_extent(level)) * 4, page))
}

@(test)
marking_sets_the_one_page_of_a_block_inside_a_page :: proc(t: ^testing.T) {
	c := test_camera()
	views := test_views(c)
	requests, _ := test_buffers(len(views))
	// The middle of a page of the level at a point's own level.
	p := c.forward * 10
	level := virtual_footprint_level(c.selection, linalg.length(p))
	texel, _ := virtual_project(views[level], p)
	middle :=
		[2]f32 {
			math.floor(texel.x / VIRTUAL_PAGE_TEXELS) + 0.5,
			math.floor(texel.y / VIRTUAL_PAGE_TEXELS) + 0.5,
		} *
		VIRTUAL_PAGE_TEXELS
	direction := linalg.normalize(TEST_LIGHT)
	right, up := light_basis(direction)
	p +=
		right * ((middle.x - texel.x) * views[level].texel) -
		up * ((middle.y - texel.y) * views[level].texel)
	testing.expect_value(t, virtual_mark(requests, views, .Taps_4, p, level), level)
	testing.expect_value(t, count_marked(requests), 1)
	testing.expect(
		t,
		is_marked(
			requests,
			level,
			{i32(middle.x / VIRTUAL_PAGE_TEXELS), i32(middle.y / VIRTUAL_PAGE_TEXELS)},
		),
	)
}

@(test)
marking_sets_every_page_that_a_block_across_a_corner_reads :: proc(t: ^testing.T) {
	c := test_camera()
	views := test_views(c)
	requests, _ := test_buffers(len(views))
	p := c.forward * 10
	level := virtual_footprint_level(c.selection, linalg.length(p))
	texel, _ := virtual_project(views[level], p)
	corner :=
		[2]f32 {
			math.floor(texel.x / VIRTUAL_PAGE_TEXELS),
			math.floor(texel.y / VIRTUAL_PAGE_TEXELS),
		} *
		VIRTUAL_PAGE_TEXELS
	direction := linalg.normalize(TEST_LIGHT)
	right, up := light_basis(direction)
	p +=
		right * ((corner.x - texel.x) * views[level].texel) -
		up * ((corner.y - texel.y) * views[level].texel)
	testing.expect_value(t, virtual_mark(requests, views, .Taps_4, p, level), level)
	testing.expect_value(t, count_marked(requests), 4)
	page := [2]i32{i32(corner.x / VIRTUAL_PAGE_TEXELS), i32(corner.y / VIRTUAL_PAGE_TEXELS)}
	for offset in ([][2]i32{{-1, -1}, {0, -1}, {-1, 0}, {0, 0}}) {
		testing.expect(t, is_marked(requests, level, page + offset))
	}
}

@(test)
a_mark_past_a_levels_valid_rectangle_goes_to_a_coarser_level :: proc(t: ^testing.T) {
	c := test_camera()
	views := test_views(c)
	requests, _ := test_buffers(len(views))
	// Behind the camera and past level 0's view model reach, where level 0 does not draw.
	p := c.forward * -f32(VIRTUAL_VIEW_MODEL_REACH + 2)
	level := virtual_mark(requests, views, .Taps_4, p, 0)
	testing.expect(t, level > 0)
	testing.expect(
		t,
		count_marked(requests) >= 1 && count_marked(requests) <= 4,
		"the block's pages, at one level",
	)
}

@(test)
a_point_past_every_level_marks_nothing :: proc(t: ^testing.T) {
	c := test_camera(levels = 3)
	views := test_views(c)
	requests, table := test_buffers(len(views))
	p := c.forward * 1e6
	testing.expect_value(t, virtual_mark(requests, views, .Taps_4, p, 2), -1)
	testing.expect_value(t, count_marked(requests), 0)
	testing.expect_value(t, virtual_lookup(table, views, p, 2), -1)
}

@(test)
marks_that_fit_the_pool_move_nothing :: proc(t: ^testing.T) {
	c := test_camera()
	views := test_views(c)
	requests, _ := test_buffers(len(views))
	virtual_mark(requests, views, .Taps_1, c.forward * 0.5, 0)
	marked := u32(count_marked(requests))
	requested, moved := virtual_fit_pool(requests, views, marked)
	testing.expect_value(t, requested, marked)
	testing.expect_value(t, moved, u32(0))
	testing.expect_value(t, u32(count_marked(requests)), marked)
}

@(test)
marks_that_do_not_fit_move_the_finest_to_their_parents_only_until_they_fit :: proc(t: ^testing.T) {
	c := test_camera()
	views := test_views(c)
	requests, _ := test_buffers(len(views))
	// Pages of level 0 in a row, and one of level 3 that nothing moves to.
	for x in i32(60) ..< 68 {
		index := VIRTUAL_LEVEL_PAGES * 0 + 64 * VIRTUAL_PAGES + int(x)
		requests[index >> 5] |= 1 << uint(index & 31)
	}
	coarse := 3 * VIRTUAL_LEVEL_PAGES + 64 * VIRTUAL_PAGES + 64
	requests[coarse >> 5] |= 1 << uint(coarse & 31)
	requested, moved := virtual_fit_pool(requests, views, 7)
	testing.expect_value(t, requested, u32(9))
	testing.expect(t, moved >= 2, "at least two moved")
	testing.expect(t, count_marked(requests) <= 7, "they fit")
	// One less than the whole row stays where it was asked for, so the pool loses no more detail than it must.
	kept := 0
	for x in i32(60) ..< 68 {
		if is_marked(requests, 0, {x, 64}) {
			kept += 1
		}
	}
	testing.expect_value(t, kept, 8 - int(moved))
	testing.expect(t, kept > 0, "level 0 keeps what fits")
	testing.expect(t, is_marked(requests, 3, {64, 64}), "a coarser level keeps its page")
}

@(test)
a_moved_mark_leaves_its_points_to_its_parent :: proc(t: ^testing.T) {
	c := test_camera()
	views := test_views(c)
	requests, table := test_buffers(len(views))
	// Two points on neighbouring pages of the first level. With room for one page, their marks move up to one parent.
	right, _ := light_basis(linalg.normalize(TEST_LIGHT))
	page := f32(virtual_level_extent(0)) / VIRTUAL_PAGES
	a := c.forward * 0.5
	b := a + right * page
	testing.expect_value(t, virtual_mark(requests, views, .Taps_1, a, 0), 0)
	testing.expect_value(t, virtual_mark(requests, views, .Taps_1, b, 0), 0)
	_, moved := virtual_fit_pool(requests, views, 1)
	testing.expect(t, moved > 0)
	testing.expect_value(t, count_marked(requests), 1)
	stats := virtual_allocate(requests, table, len(views), 1)
	testing.expect_value(t, stats.allocated, u32(1))
	found := virtual_lookup(table, views, a, 0)
	testing.expect(t, found > 0, "the point falls back to a coarser level")
	testing.expect_value(t, virtual_lookup(table, views, b, 0), found)
}

@(test)
allocation_gives_every_page_a_physical_page_while_the_pool_has_room :: proc(t: ^testing.T) {
	requests, table := test_buffers(2)
	requests[0] = 0b1011
	requests[VIRTUAL_LEVEL_WORDS] = 0b1
	stats := virtual_allocate(requests, table, 2, 16)
	testing.expect_value(
		t,
		stats,
		Virtual_Shadow_Stats{requested = 4, allocated = 4, missed = 0, capacity = 16},
	)
	// The coarsest first, and each page its own.
	testing.expect_value(t, table[VIRTUAL_LEVEL_PAGES], 0)
	testing.expect_value(t, table[0], 1)
	testing.expect_value(t, table[1], 2)
	testing.expect_value(t, table[3], 3)
	testing.expect_value(t, table[2], VIRTUAL_NO_PAGE)
}

@(test)
the_finest_levels_go_first_when_pages_are_short :: proc(t: ^testing.T) {
	requests, table := test_buffers(3)
	requests[0] = 0xff
	requests[VIRTUAL_LEVEL_WORDS] = 0xf
	requests[2 * VIRTUAL_LEVEL_WORDS] = 0x3
	stats := virtual_allocate(requests, table, 3, 7)
	testing.expect_value(
		t,
		stats,
		Virtual_Shadow_Stats{requested = 14, allocated = 7, missed = 7, capacity = 7},
	)
	for i in 0 ..< 2 {
		testing.expect(
			t,
			table[2 * VIRTUAL_LEVEL_PAGES + i] != VIRTUAL_NO_PAGE,
			"the coarsest level has its pages",
		)
	}
	for i in 0 ..< 4 {
		testing.expect(
			t,
			table[VIRTUAL_LEVEL_PAGES + i] != VIRTUAL_NO_PAGE,
			"the next level has its pages",
		)
	}
	allocated := 0
	for i in 0 ..< 8 {
		if table[i] != VIRTUAL_NO_PAGE {
			allocated += 1
		}
	}
	testing.expect_value(t, allocated, 1)
}

@(test)
the_pool_stays_within_its_size_and_every_page_is_its_own :: proc(t: ^testing.T) {
	c := test_camera()
	views := test_views(c)
	requests, table := test_buffers(len(views))
	for x in -60 ..= 60 {
		for z in 1 ..= 200 {
			p := c.right * f32(x) * 0.5 + c.forward * f32(z) * 0.5 - c.up
			virtual_mark(
				requests,
				views,
				.Taps_4,
				p,
				virtual_footprint_level(c.selection, linalg.length(p)),
			)
		}
	}
	capacity: u32 = 32
	requested, moved := virtual_fit_pool(requests, views, capacity)
	stats := virtual_allocate(requests, table, len(views), capacity)
	testing.expect(t, requested > capacity, "this view asks for more than the pool holds")
	testing.expect(t, moved > 0, "some marks moved")
	testing.expect(t, stats.allocated <= capacity, "the pool stays within its size")
	seen := make([]bool, capacity, context.temp_allocator)
	for entry in table {
		if entry == VIRTUAL_NO_PAGE {
			continue
		}
		testing.expect(t, entry < capacity, "a page is in the pool")
		testing.expect(t, !seen[entry], "no two pages share a physical page")
		seen[entry] = true
	}
}

// The coarsest level has nothing to fall back to, so a pool that cannot hold its own pages leaves the rest of its points
// with none, which are lit. Those that it can hold still find their pages.
@(test)
a_pool_that_cannot_hold_the_coarsest_levels_pages_leaves_the_rest_without_any :: proc(
	t: ^testing.T,
) {
	c := test_camera(levels = 3)
	views := test_views(c)
	requests, table := test_buffers(len(views))
	points := make([dynamic][3]f32, context.temp_allocator)
	page := f32(virtual_level_extent(2)) / VIRTUAL_PAGES
	right, up := light_basis(linalg.normalize(TEST_LIGHT))
	for x in -3 ..= 3 {
		p := right * (f32(x) * page * 2) + up * (page * 0.5)
		if level := virtual_mark(requests, views, .Taps_1, p, 2); level == 2 {
			append(&points, p)
		}
	}
	testing.expect(t, len(points) >= 3)
	stats := virtual_allocate(requests, table, len(views), 2)
	testing.expect_value(t, stats.allocated, 2)
	testing.expect(t, stats.missed > 0)
	found := 0
	for p in points {
		if virtual_lookup(table, views, p, 2) == 2 {
			found += 1
		}
	}
	testing.expect(
		t,
		found >= 1 && found < len(points),
		"some points have their pages, and the rest have none",
	)
}

// With a pool too small for the view, each pixel falls back to a coarser level that has its pages, so no pixel that
// marked its pages finds none.
@(test)
with_a_pool_too_small_every_marked_point_falls_back_to_a_coarser_level_with_no_holes :: proc(
	t: ^testing.T,
) {
	c := test_camera()
	views := test_views(c)
	filter := Shadow_Filter.Taps_4
	requests, table := test_buffers(len(views))
	points := make([dynamic][3]f32, context.temp_allocator)
	for x in -60 ..= 60 {
		for z in 1 ..= 200 {
			p := c.right * f32(x) * 0.5 + c.forward * f32(z) * 0.5 - c.up
			append(&points, p)
			virtual_mark(
				requests,
				views,
				filter,
				p,
				virtual_footprint_level(c.selection, linalg.length(p)),
			)
		}
	}
	_, moved := virtual_fit_pool(requests, views, 48)
	testing.expect(t, moved > 0, "the pool is too small")
	virtual_allocate(requests, table, len(views), 48)

	fell_back := 0
	for p in points {
		wanted := virtual_footprint_level(c.selection, linalg.length(p))
		found := virtual_lookup(table, views, p, virtual_lookup_level(c.selection, linalg.length(p)))
		testing.expectf(t, found >= 0, "%v wants level %d and has none", p, wanted)
		if found > wanted {
			fell_back += 1
		}
	}
	testing.expect(t, fell_back > 0, "some pixels fell back")
}

@(test)
with_room_in_the_pool_every_marked_point_has_its_own_level :: proc(t: ^testing.T) {
	c := test_camera()
	views := test_views(c)
	filter := Shadow_Filter.Taps_9
	requests, table := test_buffers(len(views))
	Point :: struct {
		p:      [3]f32,
		marked: int,
	}
	points := make([dynamic]Point, context.temp_allocator)
	for x in -60 ..= 60 {
		for z in 1 ..= 200 {
			p := c.right * f32(x) * 0.5 + c.forward * f32(z) * 0.5 - c.up
			append(
				&points,
				Point {
					p,
					virtual_mark(
						requests,
						views,
						filter,
						p,
						virtual_footprint_level(c.selection, linalg.length(p)),
					),
				},
			)
		}
	}
	_, moved := virtual_fit_pool(requests, views, u32(len(views) * VIRTUAL_LEVEL_PAGES))
	testing.expect_value(t, moved, u32(0))
	stats := virtual_allocate(requests, table, len(views), u32(len(views) * VIRTUAL_LEVEL_PAGES))
	testing.expect_value(t, stats.missed, 0)
	for point in points {
		// A point outside its footprint's valid rectangle marks a coarser level, and a neighbour's mark may give it better.
		wanted := virtual_footprint_level(c.selection, linalg.length(point.p))
		found := virtual_lookup(table, views, point.p, wanted)
		testing.expectf(
			t,
			found >= wanted && found <= point.marked,
			"%v wants level %d, marked %d and has %d",
			point.p,
			wanted,
			point.marked,
			found,
		)
	}
}
