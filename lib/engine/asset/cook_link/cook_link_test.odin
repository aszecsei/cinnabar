package cook_link

import "core:strings"
import "core:testing"

@(test)
every_message_round_trips :: proc(t: ^testing.T) {
	messages := []Message {
		Hello{protocol = 0x1234_5678_9abc_def0, editor = "cinnabar editor"},
		Welcome{
			protocol = 1,
			config = "dev",
			roots = {{"game", "E:/game/content"}},
			importers = {{kind = .Script, extension = ".luau", settings = {{"native", {"true", "false"}, "false", "Compile to machine code."}}}},
		},
		Refused{reason = "versions differ", protocol = 2},
		Log{level = .Error, time = -5, location = "daemon.odin:12:run_daemon()", text = "ünïcode"},
		Asset_Snapshot{
			assets = {
				{
					guid = "00112233445566778899aabbccddeeff",
					kind = .Script,
					root = "game",
					path = "scripts/door.luau",
					status = .Failed,
					errors = 2,
					behaviour = "Door",
					settings = {{"native", "true"}},
					dependencies = {"ffeeddccbbaa99887766554433221100"},
				},
			},
			folders = {{"game", "scripts"}},
		},
		Asset_Delta{changed = {{guid = "01", kind = .Scene}}, removed = {"02"}, added_folders = {{"game", "a"}}, removed_folders = {{"game", "b"}}},
		Asset_Problems{guid = "01", problems = {{file = "E:/x.luau", line = 3, column = 4, error = true, text = "oops"}}},
		Cook_Finished{generation = 7, cooked = {{.Script, 2}, {.Shader, 1}}, failed = 1, milliseconds = 9.5},
		Create_Asset{template = .Behaviour, root = "game", folder = "scripts", name = "door"},
		Create_Folder{root = "game", path = "scripts/ui"},
		Move_Assets{guids = {"01", "02"}, root = "game", folder = "a"},
		Rename_Asset{guid = "01", name = "gate"},
		Rename_Folder{root = "game", path = "a", name = "b"},
		Duplicate_Assets{guids = {"01"}},
		Delete_Assets{guids = {"01"}, folders = {{"game", "old"}}},
		Set_Import_Settings{guid = "01", settings = {{"native", "true"}}},
		Reimport{guids = {"01"}},
		Operation_Result{error = "exists", guids = {"03"}},
	}
	for message in messages {
		buf: [dynamic]byte
		defer delete(buf)
		write_message(&buf, message, request = 3)
		header, ok := read_header(buf[:])
		testing.expect(t, ok)
		decoded, decoded_ok := decode_message(header.kind, buf[HEADER_SIZE:], context.temp_allocator)
		testing.expect(t, decoded_ok)
		again: [dynamic]byte
		defer delete(again)
		write_message(&again, decoded, request = 3)
		testing.expectf(t, string(buf[:]) == string(again[:]), "%v decoded as %v", message, decoded)
	}
}

@(test)
the_schema_names_every_message :: proc(t: ^testing.T) {
	text := schema(context.temp_allocator)
	for name in ([]string{"Hello", "Asset_Snapshot", "Asset_Problems", "Cook_Finished", "Asset_Kind", "Problem", "Create_Asset", "Operation_Result", "Setting_Info"}) {
		testing.expectf(t, strings.contains(text, name), "the schema lacks %s", name)
	}
	// The editor link and the cook link have their own versions.
	testing.expect(t, protocol_version() != 0)
}
