package render

import "core:math"
import "core:math/linalg"
import "core:testing"

import "cinnabar:engine/ecs"

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
	position: [3]f64 = {},
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
		position = position,
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

// test_buffers are a frame's requests, and a page table and a pool's records that hold nothing, as after a reset.
@(private = "file")
test_buffers :: proc(
	levels: int,
	capacity := 1024,
	allocator := context.temp_allocator,
) -> (
	requests, table: []u32,
	pages: []Virtual_Page,
) {
	requests = make([]u32, levels * VIRTUAL_LEVEL_WORDS, allocator)
	table = make([]u32, VIRTUAL_TABLE_WORDS, allocator)
	pages = make([]Virtual_Page, capacity, allocator)
	virtual_reset(table, pages)
	return
}

// relative is a point in meters from the world's origin, relative to the camera.
@(private = "file")
relative :: proc(p: [3]f32, c: Virtual_Camera) -> [3]f32 {
	return p - [3]f32{f32(c.position.x), f32(c.position.y), f32(c.position.z)}
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
	c := test_camera(position = {123.4, 5.6, -789})
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

// A level's corner is on a whole page of the world's space, wherever the camera is, so a page stays at the same texels as
// the camera moves, and the shadow's edges do not swim.
@(test)
a_levels_grid_stays_on_the_worlds_pages_as_the_camera_moves :: proc(t: ^testing.T) {
	direction := linalg.normalize(TEST_LIGHT)
	// A point fixed in the world's space.
	anchor := [3]f32{10, 2, 20}
	for level in ([]int{0, 3, 8}) {
		first := test_camera()
		a := virtual_level(first, direction, level).view
		a_texel, _ := virtual_project(a, relative(anchor, first))
		for step in 1 ..= 40 {
			moved := test_camera(
				position = {f64(step) * 0.173, f64(step) * 0.031, f64(step) * -0.219},
			)
			b := virtual_level(moved, direction, level).view
			b_texel, _ := virtual_project(b, relative(anchor, moved))
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
	position := [3]f64{55.5, 3, -21}
	ahead := test_camera(position = position)
	turned := test_camera(position = position, forward = linalg.normalize([3]f32{0.8, 0.1, 0.6}))
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

// Far from the world's origin, every level still holds the camera, and every point near it still finds its pages.
@(test)
a_camera_far_from_the_worlds_origin_has_every_level_around_it :: proc(t: ^testing.T) {
	before := [3]f64{1500, 10, -1400}
	for position in ([][3]f64{before, before - {f64(ORIGIN_CELL), 0, -f64(ORIGIN_CELL)}, {-3.2e6, 410, 8.7e5}}) {
		c := test_camera(position = position)
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
		requests, table, pages := test_buffers(len(views))
		p := [3]f32{1, -1, 5}
		level := virtual_footprint_level(c.selection, linalg.length(p))
		testing.expect_value(t, virtual_mark(requests, views, .Taps_4, p, level), level)
		virtual_allocate(requests, table, pages, views)
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
	c := test_camera(position = {123.4, 5.6, -789})
	direction := linalg.normalize(TEST_LIGHT)
	for level in 0 ..< c.selection.levels {
		l := virtual_level(c, direction, level)
		fields := virtual_page_fields(l.view, level)
		page := f32(virtual_level_extent(level)) / VIRTUAL_PAGES
		first := [2]i32{i32((fields >> 4) & 0x7f), i32((fields >> 11) & 0x7f)}
		testing.expect_value(t, int(fields & 0xf), level)
		testing.expect_value(t, i32((fields >> 18) & 0x7f), l.view.page_origin.x & (VIRTUAL_PAGES - 1))
		testing.expect_value(t, i32((fields >> 25) & 0x7f), l.view.page_origin.y & (VIRTUAL_PAGES - 1))
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
culling_keeps_only_what_reaches_a_page_that_draws :: proc(t: ^testing.T) {
	c := test_camera()
	direction := linalg.normalize(TEST_LIGHT)
	views := test_views(c)
	requests, table, pages := test_buffers(len(views), 64)
	level := 6
	l := virtual_level(c, direction, level)
	fields := virtual_page_fields(l.view, level)
	p := c.forward * 5
	testing.expect_value(t, virtual_mark(requests, views, .Taps_1, p, level), level)
	virtual_allocate(requests, table, pages, views)
	page := f32(virtual_level_extent(level)) / VIRTUAL_PAGES
	right, _ := light_basis(direction)
	// On the page, and just reaching it from the next but one.
	testing.expect(t, virtual_reaches_draws(table, l.planes, fields, p, 0))
	testing.expect(t, virtual_reaches_draws(table, l.planes, fields, p + right * (page * 4), page * 4.5))
	// Far enough off the page that the sphere misses it.
	testing.expect(t, !virtual_reaches_draws(table, l.planes, fields, p + right * (page * 4), page * 0.5))
	// A level that draws no page keeps nothing, not even a sphere too big to test, which a level that draws keeps.
	coarse := virtual_level(c, direction, 3)
	coarse_page := f32(virtual_level_extent(3)) / VIRTUAL_PAGES
	testing.expect(t, !virtual_reaches_draws(table, coarse.planes, virtual_page_fields(views[3], 3), p, 0))
	testing.expect(t, !virtual_reaches_draws(table, coarse.planes, virtual_page_fields(views[3], 3), p, coarse_page * VIRTUAL_CULL_PAGES))
	testing.expect(t, virtual_reaches_draws(table, l.planes, fields, p + right * (page * 4), page * VIRTUAL_CULL_PAGES))
	// Outside the level, it reaches nothing.
	testing.expect(t, !virtual_reaches_draws(table, l.planes, fields, right * f32(virtual_level_extent(level)) * 4, page))
	// The next frame asks for the same page, which the pool holds, so nothing draws, and the culling keeps nothing.
	testing.expect_value(t, virtual_mark(requests, views, .Taps_1, p, level), level)
	stats := virtual_allocate(requests, table, pages, views, now = 2)
	testing.expect_value(t, stats.drawn, 0)
	testing.expect(t, !virtual_reaches_draws(table, l.planes, fields, p, 0))
	testing.expect(t, !virtual_reaches_draws(table, l.planes, fields, p + right * (page * 4), page * VIRTUAL_CULL_PAGES))
}

@(test)
marking_for_soft_shadows_reaches_the_pages_around_a_block :: proc(t: ^testing.T) {
	c := test_camera()
	views := test_views(c)
	// The middle of a page, as in the test below, which marks that page alone.
	p := c.forward * 10
	level := virtual_footprint_level(c.selection, linalg.length(p))
	texel, _ := virtual_project(views[level], p)
	middle :=
		[2]f32{math.floor(texel.x / VIRTUAL_PAGE_TEXELS) + 0.5, math.floor(texel.y / VIRTUAL_PAGE_TEXELS) + 0.5} *
		VIRTUAL_PAGE_TEXELS
	direction := linalg.normalize(TEST_LIGHT)
	right, up := light_basis(direction)
	p += right * ((middle.x - texel.x) * views[level].texel) - up * ((middle.y - texel.y) * views[level].texel)
	// A reach of half a page or less stays on it; one of a page reaches its eight neighbours too.
	Case :: struct {
		pages:  f32,
		marked: int,
	}
	for k in ([]Case{{0.4, 1}, {1, 9}}) {
		requests, _, _ := test_buffers(len(views))
		meters := k.pages * VIRTUAL_PAGE_TEXELS * views[level].texel
		testing.expect_value(t, virtual_mark(requests, views, .Taps_4, p, level, meters), level)
		testing.expect_value(t, count_marked(requests), k.marked)
	}
}

@(test)
marking_sets_the_one_page_of_a_block_inside_a_page :: proc(t: ^testing.T) {
	c := test_camera()
	views := test_views(c)
	requests, _, _ := test_buffers(len(views))
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
	requests, _, _ := test_buffers(len(views))
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
	requests, _, _ := test_buffers(len(views))
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
	requests, table, _ := test_buffers(len(views))
	p := c.forward * 1e6
	testing.expect_value(t, virtual_mark(requests, views, .Taps_4, p, 2), -1)
	testing.expect_value(t, count_marked(requests), 0)
	testing.expect_value(t, virtual_lookup(table, views, p, 2), -1)
}

@(test)
marks_that_fit_the_pool_move_nothing :: proc(t: ^testing.T) {
	c := test_camera()
	views := test_views(c)
	requests, _, _ := test_buffers(len(views))
	virtual_mark(requests, views, .Taps_1, c.forward * 0.5, 0)
	marked := u32(count_marked(requests))
	requested, moved, _ := virtual_fit_pool(requests, views, marked)
	testing.expect_value(t, requested, marked)
	testing.expect_value(t, moved, u32(0))
	testing.expect_value(t, u32(count_marked(requests)), marked)
}

@(test)
marks_that_do_not_fit_move_the_finest_to_their_parents_only_until_they_fit :: proc(t: ^testing.T) {
	c := test_camera()
	views := test_views(c)
	requests, _, _ := test_buffers(len(views))
	// Pages of level 0 in a row, and one of level 3 that nothing moves to.
	for x in i32(60) ..< 68 {
		index := VIRTUAL_LEVEL_PAGES * 0 + 64 * VIRTUAL_PAGES + int(x)
		requests[index >> 5] |= 1 << uint(index & 31)
	}
	coarse := 3 * VIRTUAL_LEVEL_PAGES + 64 * VIRTUAL_PAGES + 64
	requests[coarse >> 5] |= 1 << uint(coarse & 31)
	requested, moved, _ := virtual_fit_pool(requests, views, 7)
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
	requests, table, pages := test_buffers(len(views), 1)
	// Two points on neighbouring pages of the first level. With room for one page, their marks move up to one parent.
	right, _ := light_basis(linalg.normalize(TEST_LIGHT))
	page := f32(virtual_level_extent(0)) / VIRTUAL_PAGES
	a := c.forward * 0.5
	b := a + right * page
	testing.expect_value(t, virtual_mark(requests, views, .Taps_1, a, 0), 0)
	testing.expect_value(t, virtual_mark(requests, views, .Taps_1, b, 0), 0)
	_, moved, _ := virtual_fit_pool(requests, views, 1)
	testing.expect(t, moved > 0)
	testing.expect_value(t, count_marked(requests), 1)
	stats := virtual_allocate(requests, table, pages, views)
	testing.expect_value(t, stats.allocated, u32(1))
	found := virtual_lookup(table, views, a, 0)
	testing.expect(t, found > 0, "the point falls back to a coarser level")
	testing.expect_value(t, virtual_lookup(table, views, b, 0), found)
}

// entry is a level's page's table entry, by its place in the level.
@(private = "file")
entry :: proc(table: []u32, views: []Shadow_View, level: int, page: [2]i32) -> u32 {
	return table[virtual_table_slot(level, views[level].page_origin + page)]
}

@(test)
allocation_gives_every_page_a_physical_page_while_the_pool_has_room :: proc(t: ^testing.T) {
	views := test_views(test_camera(levels = 2))
	requests, table, pages := test_buffers(2, 16)
	requests[0] = 0b1011
	requests[VIRTUAL_LEVEL_WORDS] = 0b1
	stats := virtual_allocate(requests, table, pages, views)
	testing.expect_value(
		t,
		stats,
		Virtual_Shadow_Stats{requested = 4, allocated = 4, missed = 0, capacity = 16, drawn = 4, resident = 4},
	)
	// The coarsest first, and each page its own, which draws.
	testing.expect_value(t, entry(table, views, 1, {0, 0}), 0 | VIRTUAL_DRAW)
	testing.expect_value(t, entry(table, views, 0, {0, 0}), 1 | VIRTUAL_DRAW)
	testing.expect_value(t, entry(table, views, 0, {1, 0}), 2 | VIRTUAL_DRAW)
	testing.expect_value(t, entry(table, views, 0, {3, 0}), 3 | VIRTUAL_DRAW)
	testing.expect_value(t, entry(table, views, 0, {2, 0}), VIRTUAL_NO_PAGE)
	testing.expect_value(t, table[VIRTUAL_TABLE_COUNTS], 3)
	testing.expect_value(t, table[VIRTUAL_TABLE_COUNTS + 1], 1)
	testing.expect_value(t, pages[1], Virtual_Page{level = 0, page = views[0].page_origin, last = 1})
}

@(test)
the_finest_levels_go_first_when_pages_are_short :: proc(t: ^testing.T) {
	views := test_views(test_camera(levels = 3))
	requests, table, pages := test_buffers(3, 7)
	requests[0] = 0xff
	requests[VIRTUAL_LEVEL_WORDS] = 0xf
	requests[2 * VIRTUAL_LEVEL_WORDS] = 0x3
	drawn, missed := virtual_assign(requests, table, pages, views, {0, 1, 2, 3, 4, 5, 6}, 1)
	testing.expect_value(t, drawn, 7)
	testing.expect_value(t, missed, 7)
	for i in i32(0) ..< 2 {
		testing.expect(t, entry(table, views, 2, {i, 0}) != VIRTUAL_NO_PAGE, "the coarsest level has its pages")
	}
	for i in i32(0) ..< 4 {
		testing.expect(t, entry(table, views, 1, {i, 0}) != VIRTUAL_NO_PAGE, "the next level has its pages")
	}
	allocated := 0
	for i in i32(0) ..< 8 {
		if entry(table, views, 0, {i, 0}) != VIRTUAL_NO_PAGE {
			allocated += 1
		}
	}
	testing.expect_value(t, allocated, 1)
}

@(test)
the_pool_stays_within_its_size_and_every_page_is_its_own :: proc(t: ^testing.T) {
	c := test_camera()
	views := test_views(c)
	capacity: u32 = 32
	requests, table, pages := test_buffers(len(views), int(capacity))
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
	requested, moved, _ := virtual_fit_pool(requests, views, capacity)
	stats := virtual_allocate(requests, table, pages, views)
	testing.expect(t, requested > capacity, "this view asks for more than the pool holds")
	testing.expect(t, moved > 0, "some marks moved")
	testing.expect(t, stats.allocated <= capacity, "the pool stays within its size")
	seen := make([]bool, capacity, context.temp_allocator)
	for e in table[:VIRTUAL_TABLE_COUNTS] {
		page := virtual_entry_page(e)
		if page == VIRTUAL_NO_PAGE {
			continue
		}
		testing.expect(t, page < capacity, "a page is in the pool")
		testing.expect(t, !seen[page], "no two pages share a physical page")
		seen[page] = true
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
	requests, table, pages := test_buffers(len(views), 2)
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
	stats := virtual_allocate(requests, table, pages, views)
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
	requests, table, pages := test_buffers(len(views), 48)
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
	_, moved, _ := virtual_fit_pool(requests, views, 48)
	testing.expect(t, moved > 0, "the pool is too small")
	virtual_allocate(requests, table, pages, views)

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
	requests, table, pages := test_buffers(len(views), len(views) * VIRTUAL_LEVEL_PAGES)
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
	_, moved, _ := virtual_fit_pool(requests, views, u32(len(views) * VIRTUAL_LEVEL_PAGES))
	testing.expect_value(t, moved, u32(0))
	stats := virtual_allocate(requests, table, pages, views)
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

// mark_view marks the pages of a grid of points on the ground in front of a camera, as the prepass's pixels would.
@(private = "file")
mark_view :: proc(requests: []u32, views: []Shadow_View, c: Virtual_Camera) {
	for &word in requests {
		word = 0
	}
	for x in -20 ..= 20 {
		for z in 1 ..= 60 {
			p := c.right * f32(x) * 0.5 + c.forward * f32(z) * 0.5 - c.up
			virtual_mark(requests, views, .Taps_4, p, virtual_footprint_level(c.selection, linalg.length(p)))
		}
	}
}

@(test)
every_levels_pool_fits_the_scratch :: proc(t: ^testing.T) {
	for p in SHADOW_PARAMS {
		testing.expect(t, int(p.pool_pages.x * p.pool_pages.y) <= VIRTUAL_MAX_POOL_PAGES)
	}
}

// With a still camera, light and scene, every page that the next frames ask for is in the pool, so none draws, and each
// keeps its physical page.
@(test)
a_still_view_draws_no_page_after_the_first_frame :: proc(t: ^testing.T) {
	c := test_camera()
	views := test_views(c)
	requests, table, pages := test_buffers(len(views))
	mark_view(requests, views, c)
	first := virtual_allocate(requests, table, pages, views, now = 1)
	testing.expect(t, first.drawn > 0 && first.cached == 0)
	before := make([]u32, VIRTUAL_TABLE_COUNTS, context.temp_allocator)
	copy(before, table[:VIRTUAL_TABLE_COUNTS])
	for now in u32(2) ..= 4 {
		mark_view(requests, views, c)
		stats := virtual_allocate(requests, table, pages, views, now = now)
		testing.expect_value(
			t,
			stats,
			Virtual_Shadow_Stats {
				requested = first.requested,
				allocated = first.allocated,
				capacity = first.capacity,
				cached = first.drawn,
				resident = first.drawn,
			},
		)
		for e, i in table[:VIRTUAL_TABLE_COUNTS] {
			testing.expect_value(t, e, virtual_entry_page(before[i]))
		}
		for count in table[VIRTUAL_TABLE_COUNTS:] {
			testing.expect_value(t, count, 0)
		}
	}
}

// A camera that moves keeps the pages that stay in each level at their physical pages, through their absolute pages'
// entries, and draws only the pages that it uncovers. The pages that left a level leave the pool.
@(test)
a_camera_that_moves_draws_only_the_pages_it_uncovers :: proc(t: ^testing.T) {
	a := test_camera()
	views_a := test_views(a)
	requests, table, pages := test_buffers(len(views_a), 2048)
	mark_view(requests, views_a, a)
	virtual_allocate(requests, table, pages, views_a, now = 1)
	held := make(map[[3]i32]u32, context.temp_allocator)
	for page, p in pages {
		if page.level != VIRTUAL_FREE {
			held[{i32(page.level), page.page.x, page.page.y}] = u32(p)
		}
	}

	// Three of level 0's pages across the light, so its origin moves by three pages, and coarser levels' by fewer.
	page := f64(virtual_level_extent(0)) / VIRTUAL_PAGES
	right, _ := light_basis(linalg.normalize(TEST_LIGHT))
	b := test_camera(position = [3]f64{f64(right.x), f64(right.y), f64(right.z)} * page * 3)
	views_b := test_views(b)
	testing.expect(t, views_b[0].page_origin != views_a[0].page_origin, "level 0 did not move")
	mark_view(requests, views_b, b)
	wanted := make(map[[3]i32]bool, context.temp_allocator)
	for word, w in requests {
		for bit in u32(0) ..< 32 {
			if word & (1 << bit) != 0 {
				index := w * 32 + int(bit)
				level := index / VIRTUAL_LEVEL_PAGES
				local := index % VIRTUAL_LEVEL_PAGES
				absolute := views_b[level].page_origin + {i32(local % VIRTUAL_PAGES), i32(local / VIRTUAL_PAGES)}
				wanted[{i32(level), absolute.x, absolute.y}] = true
			}
		}
	}
	stats := virtual_allocate(requests, table, pages, views_b, now = 2)
	kept, uncovered := 0, 0
	for key in wanted {
		if key in held {
			kept += 1
		} else {
			uncovered += 1
		}
	}
	testing.expect(t, kept > 0 && uncovered > 0, "the move kept no pages or uncovered none")
	testing.expect_value(t, int(stats.cached), kept)
	testing.expect_value(t, int(stats.drawn), uncovered)
	for key in wanted {
		e := table[virtual_table_slot(int(key.x), key.yz)]
		if p, ok := held[key]; ok {
			testing.expect_value(t, e, p)
		} else {
			testing.expect(t, virtual_entry_draws(e), "an uncovered page does not draw")
		}
	}
	// No physical page holds a page outside its level.
	for page in pages {
		if page.level == VIRTUAL_FREE {
			continue
		}
		local := page.page - views_b[page.level].page_origin
		testing.expect(t, local.x >= 0 && local.y >= 0 && local.x < VIRTUAL_PAGES && local.y < VIRTUAL_PAGES)
	}
}

// With a full pool, the pages that were asked for longest ago leave first, and none that the frame asks for leaves.
@(test)
a_full_pool_evicts_the_least_recently_used :: proc(t: ^testing.T) {
	views := test_views(test_camera(levels = 1))
	requests, table, pages := test_buffers(1, 6)
	ask :: proc(requests: []u32, xs: []i32) {
		for &word in requests {
			word = 0
		}
		for x in xs {
			index := 64 * VIRTUAL_PAGES + int(x)
			requests[index >> 5] |= 1 << uint(index & 31)
		}
	}
	holds :: proc(table: []u32, views: []Shadow_View, x: i32) -> bool {
		return table[virtual_table_slot(0, views[0].page_origin + {x, 64})] != VIRTUAL_NO_PAGE
	}
	ask(requests, {0, 1})
	virtual_allocate(requests, table, pages, views, now = 1)
	ask(requests, {2, 3})
	virtual_allocate(requests, table, pages, views, now = 2)
	ask(requests, {4, 5})
	virtual_allocate(requests, table, pages, views, now = 3)
	// The pool is full. Asking for 2 again and for three new pages takes the three oldest that the frame does not ask
	// for: 0 and 1 from the first frame, then the second's 3.
	ask(requests, {2, 6, 7, 8})
	stats := virtual_allocate(requests, table, pages, views, now = 4)
	testing.expect_value(
		t,
		stats,
		Virtual_Shadow_Stats{requested = 4, allocated = 4, capacity = 6, cached = 1, drawn = 3, evicted = 3, resident = 6},
	)
	for x in ([]i32{0, 1, 3}) {
		testing.expectf(t, !holds(table, views, x), "page %d stayed", x)
	}
	for x in ([]i32{2, 4, 5, 6, 7, 8}) {
		testing.expectf(t, holds(table, views, x), "page %d left", x)
	}
	// Page 2 was asked for again, so 4 and 5 are now the oldest.
	ask(requests, {9, 10})
	stats = virtual_allocate(requests, table, pages, views, now = 5)
	testing.expect_value(t, stats.evicted, 2)
	for x in ([]i32{4, 5}) {
		testing.expectf(t, !holds(table, views, x), "page %d stayed", x)
	}
	for x in ([]i32{2, 6, 7, 8, 9, 10}) {
		testing.expectf(t, holds(table, views, x), "page %d left", x)
	}
}

// A camera that moves and turns over a pool too small to keep what it saw evicts what it no longer reads, and every
// point that it marks finds a page: the view shows no holes.
@(test)
a_full_pool_leaves_no_holes_as_the_camera_moves :: proc(t: ^testing.T) {
	capacity := 160
	views := test_views(test_camera())
	requests, table, pages := test_buffers(len(views), capacity)
	evicted: u32
	for step in 0 ..< 12 {
		turn := f32(step) * 0.4
		c := test_camera(
			position = {f64(step) * 3.7, 0, f64(step) * 2.9},
			forward = linalg.normalize([3]f32{math.sin(turn), 0, math.cos(turn)}),
		)
		views = test_views(c)
		mark_view(requests, views, c)
		stats := virtual_allocate(requests, table, pages, views, now = u32(step + 1))
		evicted += stats.evicted
		testing.expect(t, int(stats.resident) <= capacity)
		for x in -20 ..= 20 {
			for z in 1 ..= 60 {
				p := c.right * f32(x) * 0.5 + c.forward * f32(z) * 0.5 - c.up
				found := virtual_lookup(table, views, p, virtual_lookup_level(c.selection, linalg.length(p)))
				testing.expectf(t, found >= 0, "step %d: %v has no page", step, p)
			}
		}
	}
	testing.expect(t, evicted > 0, "the pool never filled")
}

// A caster that changed drops the pages under it in every level, and only those: the frame draws them again, and the
// pool keeps the others.
@(test)
a_changed_caster_draws_only_the_pages_under_it_again :: proc(t: ^testing.T) {
	c := test_camera()
	views := test_views(c)
	requests, table, pages := test_buffers(len(views))
	mark_view(requests, views, c)
	first := virtual_allocate(requests, table, pages, views, now = 1)
	// A sphere of half a meter on the marked ground, 5 m in front of the camera.
	sphere := [4]f32{0, -1, 5, 0.5}
	dropped := make([]u32, VIRTUAL_MAX_LEVELS * VIRTUAL_LEVEL_WORDS, context.temp_allocator)
	virtual_drop_pages(views, {sphere}, dropped)
	for view, level in views {
		texel, _ := virtual_project(view, sphere.xyz)
		page := [2]i32{i32(texel.x) / VIRTUAL_PAGE_TEXELS, i32(texel.y) / VIRTUAL_PAGE_TEXELS}
		testing.expectf(t, is_marked(dropped, level, page), "level %d: the page under the sphere was not dropped", level)
	}
	// Level 0's pages are 12.5 cm, so a page 3 m to the side is not under it.
	far, _ := virtual_project(views[0], sphere.xyz + c.right * 3)
	testing.expect(t, !is_marked(dropped, 0, {i32(far.x) / VIRTUAL_PAGE_TEXELS, i32(far.y) / VIRTUAL_PAGE_TEXELS}))
	mark_view(requests, views, c)
	under: u32
	for word, i in requests {
		under += u32(count_marked({word & dropped[i]}))
	}
	testing.expect(t, under > 0 && under < first.allocated, "the sphere is not under some of the marked pages")
	stats := virtual_allocate(requests, table, pages, views, now = 2, dropped = dropped)
	testing.expect_value(t, stats.drawn, under)
	testing.expect_value(t, stats.cached, first.allocated - under)
	// The next frame, with nothing changed, draws nothing.
	mark_view(requests, views, c)
	still := virtual_allocate(requests, table, pages, views, now = 3)
	testing.expect_value(t, still.drawn, 0)
}

// A sphere off a level's grid drops none of its pages.
@(test)
a_sphere_off_the_levels_drops_nothing :: proc(t: ^testing.T) {
	c := test_camera()
	views := test_views(c)
	dropped := make([]u32, VIRTUAL_MAX_LEVELS * VIRTUAL_LEVEL_WORDS, context.temp_allocator)
	virtual_drop_pages(views, {{1e6, 0, 1e6, 1}}, dropped)
	testing.expect_value(t, count_marked(dropped), 0)
}

// A level whose depth anchor moved drops its pages alone, and the frame draws them again. A reset drops every level's.
@(test)
an_invalidated_level_draws_its_pages_again :: proc(t: ^testing.T) {
	c := test_camera()
	views := test_views(c)
	requests, table, pages := test_buffers(len(views))
	mark_view(requests, views, c)
	virtual_allocate(requests, table, pages, views, now = 1)
	level0 := table[VIRTUAL_TABLE_COUNTS]
	testing.expect(t, level0 > 0)
	mark_view(requests, views, c)
	stats := virtual_allocate(requests, table, pages, views, now = 2, invalidate = 1)
	testing.expect_value(t, stats.drawn, level0)
	testing.expect_value(t, table[VIRTUAL_TABLE_COUNTS], level0)
	for count in table[VIRTUAL_TABLE_COUNTS + 1:] {
		testing.expect_value(t, count, 0)
	}
	mark_view(requests, views, c)
	all := virtual_allocate(requests, table, pages, views, now = 3, reset = true)
	testing.expect_value(t, all.cached, 0)
	testing.expect_value(t, all.drawn, all.allocated)
}

@(test)
the_cache_plan_keeps_the_pages_only_for_what_they_were_drawn_for :: proc(t: ^testing.T) {
	c := test_camera()
	direction := linalg.normalize(TEST_LIGHT)
	params := SHADOW_PARAMS[.High]
	settings := Shadow_Settings{level = .High, virtual = true, virtual_cache = true}
	first, reset, invalidate := virtual_cache_plan(nil, true, {}, c, direction, params, settings)
	testing.expect(t, reset, "a frame without a cache kept its pages")
	testing.expect_value(t, first.epoch, 1)
	next: Virtual_Cache
	next, reset, invalidate = virtual_cache_plan(first, true, {}, c, direction, params, settings)
	testing.expect(t, !reset && invalidate == 0, "a still frame dropped pages")
	testing.expect_value(t, next.epoch, 2)
	testing.expect_value(t, next.anchors, first.anchors)
	_, reset, _ = virtual_cache_plan(first, false, {}, c, direction, params, settings)
	testing.expect(t, reset, "the cache off kept its pages")
	// A frame that does not know every change of casters since the cache drew starts again.
	_, reset, _ = virtual_cache_plan(first, true, {}, c, direction, params, settings, tracked = false)
	testing.expect(t, reset, "a frame that missed changes kept its pages")
	// The atlas's cache draws nothing of the levels.
	atlas := settings
	atlas.atlas_cache = true
	_, reset, _ = virtual_cache_plan(first, true, {}, c, direction, params, atlas)
	testing.expect(t, !reset, "the atlas's cache dropped the pages")
	turned := linalg.normalize(TEST_LIGHT + {0, 0, 0.001})
	_, reset, _ = virtual_cache_plan(first, true, {}, c, turned, params, settings)
	testing.expect(t, reset, "a turned light kept its pages")
	_, reset, _ = virtual_cache_plan(first, true, {}, c, direction, SHADOW_PARAMS[.Ultra], settings)
	testing.expect(t, reset, "another level kept its pages")
	other := settings
	other.ray_traced = true
	_, reset, _ = virtual_cache_plan(first, true, {}, c, direction, params, other)
	testing.expect(t, reset, "other settings kept their pages")
	// Another anchor moves every page.
	_, reset, _ = virtual_cache_plan(first, true, {raw = {1, 0, 0}}, c, direction, params, settings)
	testing.expect(t, reset, "a moved anchor kept its pages")
	// The cascades' distance, which a volume may blend, draws nothing of the levels.
	blended := settings
	blended.distance, blended.split_lambda = 80, 0.7
	_, reset, _ = virtual_cache_plan(first, true, {}, c, direction, params, blended)
	testing.expect(t, !reset, "the cascades' settings dropped the pages")

	// Moving along the light by less than level 0's extent keeps every anchor; by more, level 0's moves, alone.
	along := [3]f64{f64(direction.x), f64(direction.y), f64(direction.z)}
	near := test_camera(position = along * 0.9 * virtual_level_extent(0))
	next, reset, invalidate = virtual_cache_plan(first, true, {}, near, direction, params, settings)
	testing.expect(t, !reset && invalidate == 0, "a small move along the light dropped a level")
	far := test_camera(position = along * 1.5 * virtual_level_extent(0))
	next, reset, invalidate = virtual_cache_plan(first, true, {}, far, direction, params, settings)
	testing.expect(t, !reset)
	testing.expect_value(t, invalidate, 1)
	moved := abs(virtual_camera_depth(far, direction) - next.anchors[0])
	testing.expect(t, moved <= virtual_level_extent(0) / VIRTUAL_PAGES, "the moved anchor is not at the camera")
}

// A level's depth range holds its extent around the camera from any anchor within its extent, so the anchor can stay
// as the camera moves.
@(test)
a_levels_depth_holds_its_extent_around_the_camera_from_any_anchor :: proc(t: ^testing.T) {
	direction := linalg.normalize(TEST_LIGHT)
	c := test_camera(position = {12.5, -3, 40})
	depth := virtual_camera_depth(c, direction)
	for level in ([]int{0, 4, 9}) {
		extent := virtual_level_extent(level)
		for shift in ([]f64{-1, -0.5, 0, 0.5, 1}) {
			l := virtual_level(c, direction, level, depth + shift * extent)
			for along in ([]f32{-1, 0, 1}) {
				_, z := virtual_project(l.view, direction * along * f32(extent))
				testing.expectf(t, z >= 0 && z <= 1, "level %d, anchor %v extents off: depth %v at %v", level, shift, z, along)
			}
		}
	}
}

// The levels are of the world's space, so a rebase, which changes only the render origin, leaves a world point on the
// same texel of every level.
@(test)
a_rebase_keeps_every_levels_pages :: proc(t: ^testing.T) {
	direction := linalg.normalize(TEST_LIGHT)
	camera := ecs.World_Position{raw = {i64(1530) << 24, i64(12) << 24, -(i64(1410) << 24)}}
	point := ecs.position_offset(camera, {3, -1, 7})
	c := test_camera(position = ecs.position_sub_f64(camera, {}))
	cell := i64(ORIGIN_CELL) << 24
	for level in 0 ..< c.selection.levels {
		l := virtual_level(c, direction, level)
		texels: [2][2]f32
		for origin, i in ([]ecs.World_Position{{raw = {cell, 0, -cell}}, {raw = {2 * cell, 0, -cell}}}) {
			// The shaders' positions are relative to the camera, from the render origin's space.
			p := ecs.position_sub(point, origin) - ecs.position_sub(camera, origin)
			texels[i], _ = virtual_project(l.view, p)
		}
		testing.expectf(t, linalg.length(texels[0] - texels[1]) < 0.01, "level %d: %v against %v", level, texels[0], texels[1])
	}
}

// The levels' grids are measured from an anchor near the camera, so their page indices fit 32 bits wherever the camera
// is: the sample's playground is at 1.5e11 m. The anchor stays while the camera is within its reach, and moves to the
// camera past it.
@(test)
the_levels_anchor_stays_near_the_camera :: proc(t: ^testing.T) {
	far_away := ecs.position_offset_f64({}, {1.5e11, 4, -20})
	testing.expect_value(t, virtual_grid_anchor(nil, far_away), far_away)
	cache := Virtual_Cache {
		anchor = far_away,
	}
	near := ecs.position_offset_f64(far_away, {3e7, -1e3, 5e7})
	testing.expect_value(t, virtual_grid_anchor(cache, near), far_away)
	past := ecs.position_offset_f64(far_away, {0, 0, VIRTUAL_ANCHOR_REACH + 1})
	testing.expect_value(t, virtual_grid_anchor(cache, past), past)
	// From the anchor's reach, every level's origin fits in 32 bits with room to spare.
	direction := linalg.normalize(TEST_LIGHT)
	edge := VIRTUAL_ANCHOR_REACH * 0.99
	c := test_camera(position = {edge, -edge, edge})
	for level in 0 ..< c.selection.levels {
		l := virtual_level(c, direction, level)
		page := virtual_level_extent(level) / VIRTUAL_PAGES
		u := f64(l.view.page_origin.x) * page
		testing.expectf(t, abs(u) < 2 * edge, "level %d's origin %v is not near the camera", level, l.view.page_origin)
	}
}
