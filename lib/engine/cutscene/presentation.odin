package cutscene

import "core:math"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/render"

// MAX_SUBTITLES is how many subtitle lines show at once: the newest that cover the time, the newest at the bottom.
MAX_SUBTITLES :: 3

// Presentation is what the presentation tracks of an evaluation's tree give at the time of its last Late phase (see
// docs/cinematics/tracks.md#presentation-tracks). It is a value of the time alone: run_phase clears it before the Late
// phase's tracks, and each track adds its sections to it.
Presentation :: struct {
	// The tree's key when the tracks made it, so a reader whose blobs changed since does not read rows that moved.
	key:           u64,
	// A presentation track evaluated: the evaluation's player drives the overlay.
	tracks:        bool,
	// The fades' opacities, by their sections' weights, and their colors in linear light, by weight × opacity.
	fade:          Blend(f32),
	fade_color:    Blend([3]f32),
	// A fade track that keeps when finished covers the frame.
	fade_keeps:    bool,
	// The letterbox's amount and aspect, by their sections' weights, and whether the bars follow the camera.
	amount:        Blend(f32),
	aspect:        Blend(f32),
	follow_camera: bool,
	// The subtitle sections that cover the time, oldest first: at most MAX_SUBTITLES, the newest.
	lines:         [MAX_SUBTITLES]Line_Ref,
	line_count:    int,
}

// Line_Ref is a subtitle section that covers the time: its cutscene in the tree (0 for the root, n for children[n - 1]),
// its index in that cutscene's blob, and its start on the root's time, which orders the lines.
Line_Ref :: struct {
	child:   int,
	section: u32,
	start:   f64,
}

// Presented is what an evaluation's presentation shows: the fade's color, sRGB-encoded, and its opacity, the
// letterbox's aspect and how far its bars are in, and the subtitles' speakers and text, which point into the blobs.
Presented :: struct {
	fade_color:   [3]f32,
	fade_opacity: f32,
	fade_keeps:   bool,
	aspect:       f32,
	amount:       f32,
	lines:        [MAX_SUBTITLES]Presented_Line,
	line_count:   int,
}

Presented_Line :: struct {
	speaker: string,
	text:    string,
}

// presentation_track adds a presentation track's sections at the time that the frame shows to the evaluation's
// presentation. It writes nothing to the world: the overlay shows what it gives (see present).
presentation_track :: proc(ctx: ^Track_Context) {
	p := &ctx.evaluation.presented
	p.tracks = true
	status := Player_Status.Playing
	if player, found := player_of(ctx.cutscenes, ctx.evaluation); found {
		status = status_of(player.state)
	}
	t := i32(math.floor(max(shown_time(ctx, status), f64(ctx.range_start))))
	for section, j in format.cutscene_track_sections(ctx.data, ctx.blob, ctx.track) {
		at := sample_section(ctx, section, t) or_continue
		index := ctx.track.first_section + u32(j)
		row := format.cutscene_presentation_of(ctx.data, ctx.blob, index) or_continue
		switch row.kind {
		case .Fade:
			opacity := clamp(channel_at(ctx, section, format.CUTSCENE_FADE_OPACITY, at.local, 1), 0, 1)
			blend_add(&p.fade, opacity, at.weight)
			blend_add(&p.fade_color, linear_of(row.color.rgb), at.weight * opacity)
			if ctx.track.finish == .Keep && at.weight * opacity > 0 {
				p.fade_keeps = true
			}
		case .Letterbox:
			amount := clamp(
				channel_at(ctx, section, format.CUTSCENE_LETTERBOX_AMOUNT, at.local, 1),
				0,
				1,
			)
			aspect := clamp(
				channel_at(
					ctx,
					section,
					format.CUTSCENE_LETTERBOX_ASPECT,
					at.local,
					format.CUTSCENE_DEFAULT_ASPECT,
				),
				format.CUTSCENE_MIN_ASPECT,
				format.CUTSCENE_MAX_ASPECT,
			)
			blend_add(&p.amount, amount, at.weight)
			blend_add(&p.aspect, aspect, at.weight)
			if .Follow_Camera in ctx.track.flags {
				p.follow_camera = true
			}
		case .Subtitle:
			if at.weight > 0 {
				add_line(p, {ctx.child, index, root_time(ctx, f64(section.start))})
			}
		}
	}
}

// add_line keeps a subtitle among the newest MAX_SUBTITLES that cover the time, in order of their starts, the oldest
// first. Of two at one start, the later in the tree's order is the newer.
@(private = "file")
add_line :: proc(p: ^Presentation, line: Line_Ref) {
	at := p.line_count
	for at > 0 && p.lines[at - 1].start > line.start {
		at -= 1
	}
	if p.line_count == MAX_SUBTITLES {
		if at == 0 {
			return
		}
		// The oldest goes, and the lines before the new one move up.
		copy(p.lines[:at - 1], p.lines[1:at])
		p.lines[at - 1] = line
		return
	}
	copy(p.lines[at + 1:p.line_count + 1], p.lines[at:p.line_count])
	p.lines[at] = line
	p.line_count += 1
}

// channel_at is a section's channel of a name at a time in the section, or a value when it has no such channel.
@(private = "file")
channel_at :: proc(
	ctx: ^Track_Context,
	section: format.Cutscene_Section,
	name: string,
	local: i32,
	otherwise: f32,
) -> f32 {
	for channel in format.cutscene_section_channels(ctx.data, ctx.blob, section) {
		if format.blob_string(ctx.data, channel.name) == name {
			return curve_value(format.cutscene_channel_keys(ctx.data, ctx.blob, channel), local)
		}
	}
	return otherwise
}

// presentation_values is what an evaluation's presentation shows (see Presented). The bars of a letterbox that follows
// the camera take the aspect of the camera that the cut track shows, while it shows one. Subtitles whose blobs changed
// since the last Late phase are left out until the next.
presentation_values :: proc(s: ^State, w: ^ecs.World, e: ^Evaluation) -> (v: Presented) {
	p := &e.presented
	if p.fade.weight > 0 {
		v.fade_opacity = clamp(blend_value(p.fade, 0), 0, 1)
	}
	if p.fade_color.weight > 0 {
		v.fade_color = srgb_of(p.fade_color.sum / p.fade_color.weight)
	}
	v.fade_keeps = p.fade_keeps
	if p.amount.weight > 0 {
		v.amount = clamp(blend_value(p.amount, 0), 0, 1)
		v.aspect = p.aspect.sum / p.aspect.weight
		if p.follow_camera {
			if shot, showing := e.cut.shown.(Cut_Shot); showing {
				v.aspect = render.camera_aspect(w, shot.entity, v.aspect)
			}
		}
	}
	if key, keyed := e.key.?; !keyed || key != p.key {
		return
	}
	for line in p.lines[:p.line_count] {
		data: []byte
		blob: ^format.Cutscene_Blob
		found: bool
		if line.child == 0 {
			data, blob, found = cutscene_data(s, e)
		} else {
			data, blob, found = child_blob(s, e, line.child)
		}
		if !found {
			continue
		}
		row := format.cutscene_presentation_of(data, blob, line.section) or_continue
		v.lines[v.line_count] = {
			speaker = format.blob_string(data, row.speaker),
			text    = format.blob_string(data, row.text),
		}
		v.line_count += 1
	}
	return
}

// linear_of is an sRGB-encoded color of bytes in linear light, so fades of two colors blend as light does.
linear_of :: proc(c: [3]u8) -> [3]f32 {
	return {to_linear(f32(c.r) / 255), to_linear(f32(c.g) / 255), to_linear(f32(c.b) / 255)}
}

// srgb_of is a color in linear light, sRGB-encoded, from 0 to 1.
srgb_of :: proc(c: [3]f32) -> [3]f32 {
	return {to_srgb(c.r), to_srgb(c.g), to_srgb(c.b)}
}

// to_linear is an sRGB-encoded channel, from 0 to 1, in linear light.
to_linear :: proc(v: f32) -> f32 {
	v := clamp(v, 0, 1)
	return v / 12.92 if v <= 0.04045 else math.pow((v + 0.055) / 1.055, 2.4)
}

// to_srgb is a channel in linear light, sRGB-encoded, from 0 to 1.
to_srgb :: proc(v: f32) -> f32 {
	v := clamp(v, 0, 1)
	return v * 12.92 if v <= 0.0031308 else 1.055 * math.pow(v, 1 / 2.4) - 0.055
}
