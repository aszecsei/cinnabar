package editor

import "core:math"
import "core:math/linalg"
import "core:slice"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/render"

// Mesh mode's overlay (see docs/editor/mesh-editing.md#overlay-and-picking): over each live mesh that the editor edits,
// its edges as lines and, in the vertices kind, its vertices as squares facing the camera, the selected elements in
// the accent color and the hovered one brighter, the selected faces as a half-transparent fill, and the grid. The
// editor sends a Mesh_Overlay when any of it changes, and the game keeps it in the host's heap. The overlay draws
// with the gizmo's pipeline, in a mode that fades what the scene hides.

// The accent: cinnabar, as the selection outline.
@(private = "file")
ACCENT :: [4]f32{0.77, 0.06, 0.04, 1}
@(private = "file")
HOT :: [4]f32{1, 0.55, 0.1, 1}
@(private = "file")
EDGE :: [4]f32{0.92, 0.92, 0.92, 0.9}
@(private = "file")
VERTEX :: [4]f32{0.98, 0.98, 0.98, 1}
@(private = "file")
FACE_SELECTED :: [4]f32{0.77, 0.06, 0.04, 0.35}
@(private = "file")
FACE_HOT :: [4]f32{1, 0.55, 0.1, 0.22}
@(private = "file")
GRID :: [4]f32{0.65, 0.65, 0.65, 0.16}
@(private = "file")
GRID_MAJOR :: [4]f32{0.75, 0.75, 0.75, 0.38}
// Widths on screen, in pixels of the frame.
@(private = "file")
EDGE_PIXELS :: 1.5
@(private = "file")
SELECTED_EDGE_PIXELS :: 2.5
@(private = "file")
VERTEX_PIXELS :: 6
@(private = "file")
GRID_PIXELS :: 1
// The grid reaches this many lines each way from its origin.
@(private = "file")
GRID_LINES :: 40

// set_mesh_overlay keeps a Mesh_Overlay, whose slices are in the frame, in the host's heap.
@(private)
set_mesh_overlay :: proc(e: ^Editor, m: link.Mesh_Overlay) {
	clear_mesh_overlay(e)
	heap := e.platform.heap_allocator
	o := m
	o.meshes = make([]link.Mesh_Overlay_Mesh, len(m.meshes), heap)
	for mesh, i in m.meshes {
		o.meshes[i] = mesh
		o.meshes[i].selected_vertices = slice.clone(mesh.selected_vertices, heap)
		o.meshes[i].selected_edges = slice.clone(mesh.selected_edges, heap)
		o.meshes[i].selected_faces = slice.clone(mesh.selected_faces, heap)
	}
	e.mesh_overlay = o
}

@(private)
clear_mesh_overlay :: proc(e: ^Editor) {
	heap := e.platform.heap_allocator
	for mesh in e.mesh_overlay.meshes {
		delete(mesh.selected_vertices, heap)
		delete(mesh.selected_edges, heap)
		delete(mesh.selected_faces, heap)
	}
	delete(e.mesh_overlay.meshes, heap)
	e.mesh_overlay = {}
}

// mesh_overlay_vertices builds the overlay's triangles, relative to the view, into out: nothing without an active
// overlay. Widths are in pixels of a frame height pixels tall.
@(private)
mesh_overlay_vertices :: proc(e: ^Editor, w: ^ecs.World, view: render.View, height: u32, out: ^[dynamic]Gizmo_Vertex) {
	o := e.mesh_overlay
	if !o.active {
		return
	}
	right, up, forward := render.view_axes(view)
	b := Gizmo_Builder{out, right, up}
	// The meters that a pixel covers at a point's depth.
	pixel := f32(2 * math.tan(view.vertical_fov / 2) / f32(max(height, 1)))
	size :: proc(p: [3]f32, forward: [3]f32, pixel: f32, pixels: f32) -> f32 {
		return max(linalg.dot(p, forward), 0.01) * pixel * pixels
	}
	for mesh in o.meshes {
		live, found := e.live_meshes[format.Guid(mesh.guid)]
		if !found {
			continue
		}
		pose, has_pose := ecs.presented(w, ecs.Entity(mesh.entity))
		if !has_pose {
			continue
		}
		origin := ecs.position_sub(pose.position, view.position)
		to_view :: proc(origin: [3]f32, pose: ecs.Transform, local: [3]f32) -> [3]f32 {
			return origin + linalg.quaternion128_mul_vector3(pose.rotation, local * pose.scale)
		}
		source := live.source
		positions := make([][3]f32, len(source.vertices), e.platform.frame_allocator)
		for v, i in source.vertices {
			positions[i] = to_view(origin, pose, v)
		}
		// The selected faces' fills, and the hovered face's, from the bake's triangles.
		if o.element == .Faces {
			for t in 0 ..< len(live.bake_indices) / 3 {
				face := live.triangle_faces[t]
				color: [4]f32
				switch {
				case slice.contains(mesh.selected_faces, face):
					color = FACE_SELECTED
				case i32(face) == mesh.hovered_face:
					color = FACE_HOT
				case:
					continue
				}
				i := live.bake_indices[t * 3:][:3]
				p0 := to_view(origin, pose, live.bake_positions[i[0]])
				p1 := to_view(origin, pose, live.bake_positions[i[1]])
				p2 := to_view(origin, pose, live.bake_positions[i[2]])
				triangle(&b, p0, p1, p2, pack_color(color))
			}
		}
		// The polygon edges, each once, with the selected faces' and edges' in the accent and the hovered in the
		// highlight.
		seen := make(map[[2]u32]bool, e.platform.frame_allocator)
		for f, fi in source.faces {
			selected_face := o.element == .Faces && slice.contains(mesh.selected_faces, u32(fi))
			hot_face := o.element == .Faces && i32(fi) == mesh.hovered_face
			for c, k in f.corners {
				next := f.corners[(k + 1) % len(f.corners)]
				if int(c) >= len(positions) || int(next) >= len(positions) {
					continue
				}
				key := [2]u32{min(c, next), max(c, next)}
				if key[0] == key[1] || seen[key] {
					continue
				}
				seen[key] = true
				color, pixels := EDGE, f32(EDGE_PIXELS)
				if selected_face || (o.element == .Edges && has_edge(mesh.selected_edges, key)) {
					color, pixels = ACCENT, SELECTED_EDGE_PIXELS
				}
				if hot_face || (o.element == .Edges && mesh.has_hovered_edge && same_edge(mesh.hovered_edge, key)) {
					color, pixels = HOT, SELECTED_EDGE_PIXELS
				}
				a, d := positions[c], positions[next]
				ribbon(&b, a, d, size((a + d) * 0.5, forward, pixel, pixels), pack_color(color))
			}
		}
		if o.element == .Vertices {
			for p, i in positions {
				color := VERTEX
				if slice.contains(mesh.selected_vertices, u32(i)) {
					color = ACCENT
				}
				if i32(i) == mesh.hovered_vertex {
					color = HOT
				}
				h := size(p, forward, pixel, VERTEX_PIXELS) * 0.5
				quad(&b, p - right * h - up * h, p + right * h - up * h, p + right * h + up * h, p - right * h + up * h, pack_color(color))
			}
		}
	}
	if o.grid && o.grid_size > 0 {
		grid_vertices(&b, o, view, forward, pixel)
	}
}

// grid_vertices draws the grid on its plane: GRID_LINES lines each way from the origin along the plane's two axes,
// every tenth brighter, faint, as ribbons a pixel wide.
@(private = "file")
grid_vertices :: proc(b: ^Gizmo_Builder, o: link.Mesh_Overlay, view: render.View, forward: [3]f32, pixel: f32) {
	origin := ecs.position_sub({o.grid_origin}, view.position)
	axis := int(o.grid_axis) % 3
	u := [3]f32{}
	v := [3]f32{}
	u[(axis + 1) % 3] = 1
	v[(axis + 2) % 3] = 1
	extent := f32(GRID_LINES) * o.grid_size
	for k in -GRID_LINES ..= GRID_LINES {
		offset := f32(k) * o.grid_size
		color := k % 10 == 0 ? GRID_MAJOR : GRID
		for pass in 0 ..< 2 {
			along, across := u, v
			if pass == 1 {
				along, across = v, u
			}
			from := origin + across * offset - along * extent
			to := origin + across * offset + along * extent
			width := max(linalg.dot((from + to) * 0.5, forward), 0.01) * pixel * GRID_PIXELS
			ribbon(b, from, to, width, pack_color(color))
		}
	}
}

@(private = "file")
has_edge :: proc(edges: []link.Live_Edge, key: [2]u32) -> bool {
	for e in edges {
		if same_edge(e, key) {
			return true
		}
	}
	return false
}

@(private = "file")
same_edge :: proc(e: link.Live_Edge, key: [2]u32) -> bool {
	return (e.a == key[0] && e.b == key[1]) || (e.a == key[1] && e.b == key[0])
}
