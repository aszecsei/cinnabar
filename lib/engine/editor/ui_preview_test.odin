package editor

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/render"

@(private = "file")
DOCUMENT :: "55555555555555555555555555555555"

@(private = "file")
TEXT :: `ui 1
<ui>
	<style name="panel" fill="#000000"/>
	<style name="panel:hover" fill="#ff0000"/>
	<column id="panel" style="panel" anchor="center" width="400" height="200" padding="10 20">
		<box id="inner" height="50"/>
	</column>
</ui>`

@(private = "file")
Fixture :: struct {
	platform: core.Platform_API,
	frame:    virtual.Arena,
	world:    ecs.World,
	editor:   Editor,
	assets:   asset.Assets,
	cache:    string,
	out:      [dynamic]byte,
}

@(private = "file")
setup :: proc(t: ^testing.T) -> ^Fixture {
	f := new(Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
		heap_allocator = runtime.heap_allocator(),
		asset_allocator = runtime.heap_allocator(),
		file_read = core.file_read,
		file_modified = core.file_modified,
		time_seconds = proc() -> f64 {return 0},
		gpu_release_preview_target = proc(id: int) {},
		gpu_preview_target = proc(id: int, size: [2]u32) -> (gpu.Preview_Target, bool) {
			return {prefix = "test.preview", generation = 1, size = size}, true
		},
		gpu_create_sampler = proc(desc: gpu.Sampler_Desc) -> gpu.Sampler {return {}},
		memory_reserve = proc(size: int) -> rawptr {
			data, err := virtual.reserve(uint(size))
			return err == nil ? raw_data(data) : nil
		},
		memory_commit = proc(ptr: rawptr, size: int) -> bool {
			return virtual.commit(ptr, uint(size)) == nil
		},
		memory_release = proc(ptr: rawptr, size: int) {
			virtual.release(ptr, uint(size))
		},
	}
	testing.expect(t, ecs.init(&f.world, &f.platform))
	ecs.register_engine_components(&f.world.registry)
	cache, err := os.make_directory_temp("", "editor_ui_preview_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.cache = cache
	asset.init(&f.assets, &f.platform, asset.loose_cache(f.cache))
	document, problems, ok := format.ui_parse(TEXT)
	testing.expectf(t, ok, "%v", problems)
	guid, _ := format.guid_parse(DOCUMENT)
	written := format.ui_write({guid = guid, key = 77, document = document}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s.blob", f.cache, DOCUMENT), written) == nil)
	init(&f.editor, &f.platform, &f.assets)
	return f
}

@(private = "file")
teardown :: proc(f: ^Fixture) {
	destroy(&f.editor)
	asset.destroy(&f.assets)
	ecs.destroy(&f.world)
	_ = os.remove_all(f.cache)
	delete(f.cache)
	delete(f.out)
	virtual.arena_destroy(&f.frame)
	free(f)
}

// exchange polls once with the editor's messages, and gives the UI layouts that the game sent.
@(private = "file")
exchange :: proc(f: ^Fixture, incoming: ..link.Message) -> []link.Ui_Preview_Layout {
	encoded := make([dynamic]core.Editor_Message, context.temp_allocator)
	for m in incoming {
		bytes := make([dynamic]byte, context.temp_allocator)
		link.write_message(&bytes, m)
		header, _ := link.read_header(bytes[:])
		append(&encoded, core.Editor_Message{kind = header.kind, payload = bytes[link.HEADER_SIZE:]})
	}
	clear(&f.out)
	f.editor.session.last_values = -1
	poll(&f.editor, &f.world, nil, 1, encoded[:], &f.out)
	found := make([dynamic]link.Ui_Preview_Layout, context.temp_allocator)
	rest := f.out[:]
	for len(rest) > 0 {
		header, _ := link.read_header(rest)
		message, ok := link.decode_message(header.kind, rest[link.HEADER_SIZE:][:header.length], context.temp_allocator)
		if layout, is_layout := message.(link.Ui_Preview_Layout); ok && is_layout {
			append(&found, layout)
		}
		rest = rest[link.HEADER_SIZE + int(header.length):]
	}
	return found[:]
}

// draw draws the frame's previews as the renderer would, through their UI hooks, and gives how many it drew.
@(private = "file")
draw :: proc(f: ^Fixture) -> int {
	descs := previews(&f.editor)
	for &d in descs {
		if d.ui != nil {
			frame := render.Frame {
				data        = d.ui_data,
				output_size = d.size,
			}
			d.ui(&frame)
		}
	}
	return len(descs)
}

@(test)
a_ui_preview_lays_its_document_out_on_its_screen_and_says_where_its_elements_went :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	guid, _ := format.guid_parse(DOCUMENT)
	settings := link.Ui_Preview_Settings {
		id            = 2,
		screen_width  = 3840,
		screen_height = 2160,
		scale         = 2,
		view_scale    = 0.25,
		width         = 960,
		height        = 540,
		forced_node   = max(u32),
	}
	testing.expect_value(t, len(exchange(f, link.Open_Preview{id = 2, material = ([16]u8)(guid)}, settings)), 0)
	testing.expect_value(t, draw(f), 1)
	p := &f.editor.session.previews[2]
	testing.expect(t, p.ui)

	layouts := exchange(f)
	testing.expect_value(t, len(layouts), 1)
	if len(layouts) != 1 {
		return
	}
	l := layouts[0]
	testing.expect_value(t, l.id, 2)
	testing.expect_value(t, l.key, 77)
	testing.expect_value(t, l.scale, 2)
	testing.expect_value(t, l.width, 3840)
	// ui, panel and inner, by their nodes in the blob, in the screen's pixels at the scale.
	testing.expect_value(t, len(l.nodes), 3)
	panel := l.nodes[1]
	testing.expect_value(t, panel.source, 1)
	testing.expect(t, panel.shown)
	testing.expect_value(t, panel.rect, [4]f32{1520, 880, 2320, 1280})
	testing.expect_value(t, panel.content, [4]f32{1560, 900, 2280, 1260})
	// Nothing changed, so nothing goes out again.
	testing.expect_value(t, len(exchange(f)), 0)

	// The editor shows a state on an element, which the document takes when it next draws.
	settings.forced_node, settings.forced_states = 1, 1
	exchange(f, settings)
	testing.expect_value(t, draw(f), 1)
	d := &f.editor.ui.documents[p.ui_preview.slot]
	testing.expect_value(t, d.nodes[1].style.fill.colors[0], format.Ui_Color{0xff, 0, 0, 0xff})

	// Closing it frees its document.
	exchange(f, link.Close_Preview{id = 2})
	testing.expect(t, !d.used)
}
