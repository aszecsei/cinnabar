package project

import "core:fmt"
import "core:log"
import "core:strings"

import "cinnabar:core"

// Subtitle_Keys are the player's subtitle settings that the settings files give (see
// docs/cinematics/tracks.md#presentation-tracks). A key that no file gives is nil.
Subtitle_Keys :: struct {
	enabled:    Maybe(bool),
	size:       Maybe(f32),
	background: Maybe(f32),
}

// Subtitle_Choice is what the player chose for subtitles, as the user file keeps it: whether they show, a scale of their
// size, and the opacity of their backs.
Subtitle_Choice :: struct {
	enabled:    bool,
	size:       f32,
	background: f32,
}

// with_subtitles is a settings file's text with the keys of a choice set, and its other lines as they were.
with_subtitles :: proc(
	text: string,
	c: Subtitle_Choice,
	allocator := context.temp_allocator,
) -> string {
	out := set_value(text, SUBTITLES_ENABLED_KEY, "true" if c.enabled else "false")
	out = set_value(out, SUBTITLES_SIZE_KEY, fmt.tprintf("%v", c.size))
	out = set_value(out, SUBTITLES_BACKGROUND_KEY, fmt.tprintf("%v", c.background))
	return strings.clone(out, allocator)
}

// save_subtitles writes a choice to the user file beside a project file, as save_display writes a display. It returns
// false if it could not write the file.
save_subtitles :: proc(platform: ^core.Platform_API, path: string, c: Subtitle_Choice) -> bool {
	user := user_path(path, platform.frame_allocator)
	text := ""
	if data, ok := platform.file_read(user, 1, platform.frame_allocator); ok {
		text = string(data)
	}
	text = with_subtitles(text, c, platform.frame_allocator)
	if !platform.file_write(user, transmute([]byte)text) {
		log.errorf("project: could not write %s", user)
		return false
	}
	return true
}
