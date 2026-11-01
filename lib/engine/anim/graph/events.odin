package anim_graph

import "core:math"

import format "cinnabar:engine/asset/format"

// markers raises the events of the markers that the current state's heaviest clip passed in the tick: those after
// its time before the tick, up to and at its time after, or from its start when the state began in the tick. Across
// a loop's wrap, the end of the clip and then its start; a tick wraps once at most. A blend's other clips and the
// state that it fades from raise none, so a step that two blended clips both mark is raised once (see
// docs/animation/design.md#events).
@(private)
markers :: proc(g: ^Graph, inst: ^Instance, m: ^Motion, weights: [format.MAX_ANIMATION_GRAPH_POINTS]f32, previous_progress: f32, entered: bool, out: ^Tick_Output) {
	if g.blob == nil {
		return
	}
	heaviest := 0
	for i in 1 ..< m.count {
		if weights[i] > weights[heaviest] {
			heaviest = i
		}
	}
	clip := m.points[heaviest].clip
	d := clip_duration(g, clip)
	if d <= 0 {
		return
	}
	c := format.animation_graph_clips(g.data, g.blob)[clip]
	clip_markers := format.animation_graph_markers(g.data, g.blob)[c.first_marker:][:c.marker_count]
	t1 := phase(inst.progress, m.loop) * d
	t0 := phase(previous_progress, m.loop) * d
	wrapped := m.loop && math.floor(inst.progress) > math.floor(previous_progress)
	if wrapped {
		pass_markers(clip_markers, t0, d, entered, inst.state, out)
		pass_markers(clip_markers, 0, t1, true, inst.state, out)
	} else {
		pass_markers(clip_markers, t0, t1, entered, inst.state, out)
	}
}

// pass_markers raises the markers after from, or at it with closed, up to and at to, in the order of their times.
@(private = "file")
pass_markers :: proc(markers: []format.Animation_Graph_Marker, from, to: f32, closed: bool, state: u16, out: ^Tick_Output) {
	for marker in markers {
		after := marker.time > from || (closed && marker.time == from)
		if after && marker.time <= to {
			raise(out, .Marker, state, marker.event)
		}
	}
}
