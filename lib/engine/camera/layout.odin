package camera

import "core:math"

// Rect is a part of the window, normalized: 0, 0 is the top left and 1, 1 the bottom right.
Rect :: struct {
	min, max: [2]f32,
}

FULL :: Rect{{0, 0}, {1, 1}}

// Preset is a layout of the game's views that the engine knows. The first view is the one at the top left, and the
// views go left to right, then top to bottom.
Preset :: enum u8 {
	Single,
	Side_By_Side,
	Over_Under,
	Grid_4,
}

// Custom is a layout that the game lays out itself: its first count rects.
Custom :: struct {
	rects: [MAX_VIEWS]Rect,
	count: u8,
}

// Layout is where each of the game's views is in the window. The zero value is one full-screen view.
Layout :: union #no_nil {
	Preset,
	Custom,
}

// preset_rects gives the rects of a preset's views, and how many it has.
preset_rects :: proc(p: Preset) -> (rects: [MAX_VIEWS]Rect, count: int) {
	switch p {
	case .Single:
		rects[0] = FULL
		return rects, 1
	case .Side_By_Side:
		rects[0] = {{0, 0}, {0.5, 1}}
		rects[1] = {{0.5, 0}, {1, 1}}
		return rects, 2
	case .Over_Under:
		rects[0] = {{0, 0}, {1, 0.5}}
		rects[1] = {{0, 0.5}, {1, 1}}
		return rects, 2
	case .Grid_4:
		rects[0] = {{0, 0}, {0.5, 0.5}}
		rects[1] = {{0.5, 0}, {1, 0.5}}
		rects[2] = {{0, 0.5}, {0.5, 1}}
		rects[3] = {{0.5, 0.5}, {1, 1}}
		return rects, 4
	}
	return preset_rects(.Single)
}

// layout_rects gives the rects of a layout's views, and how many it has: 1 to MAX_VIEWS.
@(private)
layout_rects :: proc(layout: Layout) -> (rects: [MAX_VIEWS]Rect, count: int) {
	switch l in layout {
	case Preset:
		return preset_rects(l)
	case Custom:
		return l.rects, clamp(int(l.count), 1, MAX_VIEWS)
	}
	return preset_rects(.Single)
}

// pixel_rect is a rect's place in a window of this size in pixels. It rounds each edge, not the origin and the extent,
// so neighbouring rects share their edge and the presets tile the window with no gap and no overlap.
pixel_rect :: proc(rect: Rect, size: [2]u32) -> (origin, extent: [2]u32) {
	low, high: [2]u32
	for axis in 0 ..< 2 {
		edge :: proc(fraction: f32, size: u32) -> u32 {
			return u32(clamp(math.round(fraction * f32(size)), 0, f32(size)))
		}
		low[axis] = edge(rect.min[axis], size[axis])
		high[axis] = max(low[axis], edge(rect.max[axis], size[axis]))
	}
	return low, high - low
}
