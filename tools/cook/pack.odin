package cook

import stbrp "vendor:stb/rect_pack"

// pack_rects places rectangles of the given sizes in the smallest atlas that holds them, of sides that are powers of
// two from 64 up to max_side, and gives each one's top left corner and the atlas's size. The atlas's height is then cut
// to the last rectangle's row. The fonts' glyphs and the sprite sheets' frames pack with it.
pack_rects :: proc(sizes: [][2]int, max_side: int) -> (corners: [][2]int, size: [2]int, ok: bool) {
	rects := make([]stbrp.Rect, len(sizes), context.temp_allocator)
	area := 0
	for s, i in sizes {
		rects[i] = {id = i32(i), w = stbrp.Coord(s.x), h = stbrp.Coord(s.y)}
		area += s.x * s.y
	}
	width, height := 64, 64
	for width * height < area {
		if width <= height {
			width *= 2
		} else {
			height *= 2
		}
	}
	for width <= max_side && height <= max_side {
		nodes := make([]stbrp.Node, width, context.temp_allocator)
		ctx: stbrp.Context
		stbrp.init_target(&ctx, i32(width), i32(height), raw_data(nodes), i32(width))
		if stbrp.pack_rects(&ctx, raw_data(rects), i32(len(rects))) == 1 {
			used := 1
			corners = make([][2]int, len(sizes), context.temp_allocator)
			for r, i in rects {
				used = max(used, int(r.y + r.h))
				corners[i] = {int(r.x), int(r.y)}
			}
			return corners, {width, used}, true
		}
		if width <= height {
			width *= 2
		} else {
			height *= 2
		}
	}
	return
}
