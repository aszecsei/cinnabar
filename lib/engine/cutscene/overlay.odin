package cutscene

import "core:fmt"
import "core:math"
import "core:time"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/ui"

// The cutscene overlay (see docs/cinematics/tracks.md#presentation-tracks): one UI document that the state owns, with
// no entity, so it outlives a level. It shows the presentation of the player that drives it, and the skip's fade over
// it. When that player ends, what the overlay holds of it goes on: a fade back from a skip, or a fade that its track
// keeps.

// OVERLAY_DOCUMENT_META is the engine's overlay document's metadata, which holds its GUID.
OVERLAY_DOCUMENT_META :: #load("../content/ui/cutscene_overlay.ui.meta", string)

// OVERLAY_ORDER is the overlay's order: over gameplay documents, and under the pause menu (see
// docs/ui/design.md#documents).
OVERLAY_ORDER :: 8

// The sizes of a subtitle's line and speaker when the overlay's document gives none on those elements.
DEFAULT_LINE_SIZE :: 30
DEFAULT_SPEAKER_SIZE :: 22

// Subtitle_Settings are the player's settings for subtitles: whether they show, a scale of their text's size, and the
// opacity of the box behind each one.
Subtitle_Settings :: struct {
	enabled:    bool,
	size:       f32,
	background: f32,
}

DEFAULT_SUBTITLES :: Subtitle_Settings {
	enabled    = true,
	size       = 1,
	background = 0.5,
}

// The range of a subtitle's size scale.
MIN_SUBTITLE_SIZE :: 0.5
MAX_SUBTITLE_SIZE :: 2

// Overlay is the overlay's part of the state: its document, the project's choices, the player's subtitle settings, and
// what it holds of a player that ended.
Overlay :: struct {
	// The document open in the UI, or nil before update opens it.
	opened:    Maybe(Overlay_Document),
	// The project's document, or zero for the engine's, and the bars' color.
	document:  format.Guid,
	letterbox: [3]u8,
	subtitles: Subtitle_Settings,
	// What the overlay holds of a player that ended. Change it only with change_overlay.
	held:      Overlay_Held,
}

Overlay_Document :: struct {
	index: int,
	guid:  format.Guid,
}

// Overlay_Held is what the overlay shows with no player to drive it. nil is nothing: the overlay hides.
Overlay_Held :: union {
	Overlay_Fading,
	Overlay_Kept,
}

// Overlay_Fading is a color over the frame that fades back to clear over a length of real time: after a skip, from the
// skip's color.
Overlay_Fading :: struct {
	color:   [3]f32,
	opacity: f32,
	elapsed: time.Duration,
	length:  time.Duration,
}

// Overlay_Kept is a fade that a track set to keep left over the frame when its cutscene ended. It stays until
// release_fade, or until another cutscene drives the overlay.
Overlay_Kept :: struct {
	color:   [3]f32,
	opacity: f32,
}

// Overlay_Frame is what the overlay shows in a frame. The fade's color is sRGB-encoded.
Overlay_Frame :: struct {
	shown:        bool,
	fade_color:   [3]f32,
	fade_opacity: f32,
	aspect:       f32,
	amount:       f32,
	lines:        [MAX_SUBTITLES]Presented_Line,
	line_count:   int,
}

// change_overlay is the one writer of what the overlay holds of a player that ended.
@(private)
change_overlay :: proc(s: ^State, held: Overlay_Held) {
	s.overlay.held = held
}

// set_subtitles sets the player's subtitle settings, clamped into their ranges.
set_subtitles :: proc(s: ^State, settings: Subtitle_Settings) {
	size := settings.size if settings.size == settings.size else 1
	background := settings.background if settings.background == settings.background else 0.5
	s.overlay.subtitles = {
		enabled    = settings.enabled,
		size       = clamp(size, MIN_SUBTITLE_SIZE, MAX_SUBTITLE_SIZE),
		background = clamp(background, 0, 1),
	}
}

// subtitles is the player's subtitle settings.
subtitles :: proc(s: ^State) -> Subtitle_Settings {
	return s.overlay.subtitles
}

// set_overlay sets the project's overlay document, zero for the engine's, and the letterbox bars' color. A new
// document opens at the next update.
set_overlay :: proc(s: ^State, document: format.Guid, letterbox: [3]u8) {
	s.overlay.document = document
	s.overlay.letterbox = letterbox
}

// release_fade fades back a fade that a track kept over the frame when its cutscene ended, over a length of real time,
// so a game that loaded behind it shows itself. 0 clears it at once. It does nothing when the overlay keeps no fade.
release_fade :: proc(s: ^State, length: time.Duration) {
	kept, keeping := s.overlay.held.(Overlay_Kept)
	if !keeping {
		return
	}
	if length <= 0 {
		change_overlay(s, nil)
		return
	}
	change_overlay(s, Overlay_Fading{color = kept.color, opacity = kept.opacity, length = length})
}

// overlay_document is the GUID of the overlay's document: the project's, or the engine's.
overlay_document :: proc(s: ^State) -> format.Guid {
	if s.overlay.document != {} {
		return s.overlay.document
	}
	guid, _ := format.meta_guid(OVERLAY_DOCUMENT_META)
	return guid
}

// update_overlay opens the overlay's document, or opens the project's new one, moves a fade back on by real time, and
// ends what the overlay holds once a player drives it. update calls it at its end.
@(private)
update_overlay :: proc(s: ^State, dt: time.Duration) {
	if s.ui != nil {
		guid := overlay_document(s)
		if opened, open := s.overlay.opened.?; !open || opened.guid != guid {
			if open {
				ui.close_owned(s.ui, opened.index)
				s.overlay.opened = nil
			}
			if index := ui.open_owned(s.ui, guid, OVERLAY_ORDER); index >= 0 {
				s.overlay.opened = Overlay_Document{index, guid}
			}
		}
	}
	if _, driven := overlay_driver(s); driven {
		if s.overlay.held != nil {
			change_overlay(s, nil)
		}
		return
	}
	if fading, is_fading := s.overlay.held.(Overlay_Fading); is_fading {
		fading.elapsed += max(dt, 0)
		change_overlay(s, nil if fading.elapsed >= fading.length else fading)
	}
}

// close_overlay closes the overlay's document and forgets what it holds, for destroy.
@(private)
close_overlay :: proc(s: ^State) {
	if opened, open := s.overlay.opened.?; open && s.ui != nil {
		ui.close_owned(s.ui, opened.index)
	}
	s.overlay.opened = nil
	change_overlay(s, nil)
}

// overlay_driver is the player whose presentation the overlay shows: of the players that play, are paused, skip or
// finish with a presentation track or a skip's fade, the one of the highest priority, and of those the latest to begin,
// as a field goes to (see docs/cinematics/player.md#conflicts).
@(private)
overlay_driver :: proc(s: ^State) -> (slot: int, found: bool) {
	for &p, i in s.players {
		status := status_of(p.state)
		if status != .Playing && status != .Paused && status != .Skipping && status != .Finishing {
			continue
		}
		e := &live_of(&p.state).evaluation
		covers := false
		#partial switch state in p.state {
		case Player_Skipping:
			covers = skip_fade_length(s, e) > 0
		case Player_Finishing:
			covers = state.cover > 0
		}
		if !e.presented.tracks && !covers {
			continue
		}
		if found {
			best := &s.players[slot]
			if p.priority < best.priority ||
			   (p.priority == best.priority && p.order < best.order) {
				continue
			}
		}
		slot, found = i, true
	}
	return
}

// hand_off_overlay keeps what the overlay shows of a player that drives it as the player gives the world back: a fade
// that its track keeps, if it covers the frame; else a fade back from the skip's fade that covered the frame as the
// player finished, over the skip's fade; else nothing. A player that fails hands off nothing. change_cutscene calls it
// before give_back, while the evaluation holds the last presentation.
@(private)
hand_off_overlay :: proc(s: ^State, w: ^ecs.World, slot: int, failed: bool) {
	driver, driven := overlay_driver(s)
	if !driven || driver != slot {
		return
	}
	if failed {
		change_overlay(s, nil)
		return
	}
	p := &s.players[slot]
	e := &live_of(&p.state).evaluation
	v := presentation_values(s, w, e)
	if v.fade_keeps && v.fade_opacity > 0 {
		change_overlay(s, Overlay_Kept{v.fade_color, v.fade_opacity})
		return
	}
	finishing, is_finishing := p.state.(Player_Finishing)
	length := skip_fade_length(s, e)
	if !is_finishing || finishing.cover <= 0 || length <= 0 {
		change_overlay(s, nil)
		return
	}
	color, opacity := over(v.fade_color, v.fade_opacity, skip_color(s, e), finishing.cover)
	change_overlay(s, Overlay_Fading{color = color, opacity = opacity, length = length})
}

// skip_color is the color that a cutscene's skip fades to, sRGB-encoded, from 0 to 1. Black without its blob.
@(private = "file")
skip_color :: proc(s: ^State, e: ^Evaluation) -> [3]f32 {
	_, blob, ok := cutscene_data(s, e)
	if !ok {
		return {}
	}
	return unit_of(blob.skip_color.rgb)
}

// over is a color of an opacity over another, as one color and opacity, in linear light.
@(private = "file")
over :: proc(
	below: [3]f32,
	below_opacity: f32,
	above: [3]f32,
	above_opacity: f32,
) -> (
	color: [3]f32,
	opacity: f32,
) {
	opacity = above_opacity + below_opacity * (1 - above_opacity)
	if opacity <= 0 {
		return above, 0
	}
	linear :: proc(c: [3]f32) -> [3]f32 {
		return {to_linear(c.r), to_linear(c.g), to_linear(c.b)}
	}
	under := linear(below) * below_opacity * (1 - above_opacity)
	top := linear(above) * above_opacity
	return srgb_of((under + top) / opacity), opacity
}

// overlay_frame is what the overlay shows now: the driver's presentation, with its skip's fade over it and no subtitles
// while it skips, or what the overlay holds of a player that ended.
overlay_frame :: proc(s: ^State, w: ^ecs.World) -> (f: Overlay_Frame) {
	if slot, driven := overlay_driver(s); driven {
		p := &s.players[slot]
		e := &live_of(&p.state).evaluation
		v := presentation_values(s, w, e)
		f = {
			shown        = true,
			fade_color   = v.fade_color,
			fade_opacity = v.fade_opacity,
			aspect       = v.aspect,
			amount       = v.amount,
		}
		cover: f32
		#partial switch state in p.state {
		case Player_Skipping:
			cover = skip_cover(s, state)
		case Player_Finishing:
			cover = state.cover
		}
		if cover > 0 {
			f.fade_color, f.fade_opacity = over(
				f.fade_color,
				f.fade_opacity,
				skip_color(s, e),
				cover,
			)
		} else if s.overlay.subtitles.enabled {
			f.lines, f.line_count = v.lines, v.line_count
		}
		return
	}
	switch held in s.overlay.held {
	case Overlay_Fading:
		left: f32 = 0
		if held.length > 0 {
			left = 1 - f32(clamp(f64(held.elapsed) / f64(held.length), 0, 1))
		}
		f = {
			shown        = true,
			fade_color   = held.color,
			fade_opacity = held.opacity * left,
		}
	case Overlay_Kept:
		f = {
			shown        = true,
			fade_color   = held.color,
			fade_opacity = held.opacity,
		}
	}
	return
}

// present writes what the overlay shows into its document, for a window of a size in pixels: the fade's color and
// opacity, the bars' sizes and color, and each subtitle's text, size and back. It hides the document when nothing
// shows. Call it each frame after the Late stage, before the UI's layout.
present :: proc(s: ^State, w: ^ecs.World, window: [2]f32) {
	if s.ui == nil {
		return
	}
	opened, open := s.overlay.opened.?
	if !open {
		return
	}
	d := ui.owned_document(s.ui, opened.index)
	if d == nil || !d.built {
		return
	}
	f := overlay_frame(s, w)
	d.visible = f.shown
	if !f.shown {
		return
	}
	fade := color_of(f.fade_color)
	ui.set_value(s.ui, d, "fade", .Fill, format.Ui_Paint{colors = {fade, fade}})
	ui.set_value(s.ui, d, "fade", .Opacity, f.fade_opacity)

	// The bars crop the window to the aspect: at its top and bottom for a wider aspect, at its sides for a narrower one.
	top, side: f32
	window_aspect := window.x / max(window.y, 1)
	if f.amount > 0 && f.aspect > 0 && window_aspect > 0 {
		if f.aspect > window_aspect {
			top = (1 - window_aspect / f.aspect) / 2 * f.amount
		} else {
			side = (1 - f.aspect / window_aspect) / 2 * f.amount
		}
	}
	bars := color_of(unit_of(s.overlay.letterbox))
	paint := format.Ui_Paint {
		colors = {bars, bars},
	}
	for id in ([?]string{"bar_top", "bar_bottom"}) {
		ui.set_value(s.ui, d, id, .Height, format.Ui_Length{.Percent, top * 100})
		ui.set_value(s.ui, d, id, .Fill, paint)
	}
	for id in ([?]string{"bar_left", "bar_right"}) {
		ui.set_value(s.ui, d, id, .Width, format.Ui_Length{.Percent, side * 100})
		ui.set_value(s.ui, d, id, .Fill, paint)
	}

	settings := s.overlay.subtitles
	for i in 0 ..< MAX_SUBTITLES {
		n := i + 1
		shown := i < f.line_count
		ui.set_value(s.ui, d, fmt.tprintf("subtitle_%d", n), .Visible, shown)
		line := f.lines[i] if shown else {}
		speaker_id := fmt.tprintf("speaker_%d", n)
		line_id := fmt.tprintf("line_%d", n)
		ui.set_binding(s.ui, d, speaker_id, line.speaker)
		ui.set_binding(s.ui, d, line_id, line.text)
		ui.set_value(s.ui, d, speaker_id, .Visible, line.speaker != "")
		ui.set_value(
			s.ui,
			d,
			speaker_id,
			.Size,
			own_size(d, speaker_id, DEFAULT_SPEAKER_SIZE) * settings.size,
		)
		ui.set_value(
			s.ui,
			d,
			line_id,
			.Size,
			own_size(d, line_id, DEFAULT_LINE_SIZE) * settings.size,
		)
		ui.set_value(s.ui, d, fmt.tprintf("subtitle_back_%d", n), .Opacity, settings.background)
	}
}

// own_size is the size that the document gives an element, or a size when it gives none.
@(private = "file")
own_size :: proc(d: ^ui.Document, id: string, otherwise: f32) -> f32 {
	if value, found := ui.own_attribute(d, id, .Size); found {
		if size, is_size := value.(f32); is_size {
			return size
		}
	}
	return otherwise
}

// color_of is an sRGB-encoded color, from 0 to 1, as an opaque UI color.
@(private = "file")
color_of :: proc(c: [3]f32) -> format.Ui_Color {
	return {
		u8(math.round(clamp(c.r, 0, 1) * 255)),
		u8(math.round(clamp(c.g, 0, 1) * 255)),
		u8(math.round(clamp(c.b, 0, 1) * 255)),
		255,
	}
}

// unit_of is an sRGB-encoded color of bytes, from 0 to 1.
@(private = "file")
unit_of :: proc(c: [3]u8) -> [3]f32 {
	return {f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255}
}
