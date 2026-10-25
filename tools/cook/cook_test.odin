package cook

import "core:os"
import "core:testing"

@(test)
targets_follow_entry_points :: proc(t: ^testing.T) {
	stages := targets("float4 ps_main() : SV_Target { return 0; }\nVaryings vs_main() {}")
	testing.expect_value(t, len(stages), 2)
	if len(stages) == 2 {
		testing.expect_value(t, stages[0], Target{.Vertex, "vs_6_6", "vs_main"})
		testing.expect_value(t, stages[1], Target{.Pixel, "ps_6_6", "ps_main"})
	}
	// An identifier that only contains an entry point name is not one.
	testing.expect_value(t, len(targets("void my_cs_main_helper() {}")), 0)

	library := targets("[shader(\"raygeneration\")] void ray_generation() {} void cs_main() {}")
	testing.expect_value(t, len(library), 1)
	if len(library) == 1 {
		testing.expect_value(t, library[0], Target{stage = .Library, profile = "lib_6_6"})
	}
}

@(test)
words_match_whole_identifiers :: proc(t: ^testing.T) {
	testing.expect(t, contains_word("vs_main", "vs_main"))
	testing.expect(t, contains_word("x = vs_main(1);", "vs_main"))
	testing.expect(t, !contains_word("vs_main2", "vs_main"))
	testing.expect(t, !contains_word("_vs_main", "vs_main"))
	testing.expect(t, contains_word("_vs_main vs_main", "vs_main"))
}

@(test)
includes_are_found :: proc(t: ^testing.T) {
	names := include_names("#include \"a.hlsli\"\n  #include \"dir/b.hlsli\" // note\n#include <system>\nint x;")
	testing.expect_value(t, len(names), 2)
	if len(names) == 2 {
		testing.expect_value(t, names[0], Include{"a.hlsli", 1})
		testing.expect_value(t, names[1], Include{"dir/b.hlsli", 2})
	}

	// The fixed header resolves from the include directory, like DXC's -I.
	path, ok := resolve_include("cinnabar.hlsli", "samples/mygame/content/shaders", {"lib/core/gpu/shaders"})
	testing.expect(t, ok && os.is_file(path))
	_, missing := resolve_include("nothing.hlsli", "samples/mygame/content/shaders", {"lib/core/gpu/shaders"})
	testing.expect(t, !missing)
}

@(test)
dxc_messages_become_problems :: proc(t: ^testing.T) {
	problems: Problems
	text := "E:\\game\\shaders\\post.hlsl:12:5: error: use of undeclared identifier 'x'\n" +
		"    x = 1;\n    ^\n" +
		"E:/engine/cinnabar.hlsli:3:1: warning: unused variable\n"
	testing.expect_value(t, report_dxc_messages(text, &problems), 1)
	testing.expect_value(t, len(problems.list), 2)
	if len(problems.list) == 2 {
		testing.expect_value(t, problems.list[0], Problem{"E:/game/shaders/post.hlsl", 12, 5, true, "use of undeclared identifier 'x'"})
		testing.expect_value(t, problems.list[1], Problem{"E:/engine/cinnabar.hlsli", 3, 1, false, "unused variable"})
	}
	file, line, column := dxc_place("no place")
	testing.expect_value(t, file, "no place")
	testing.expect_value(t, line, 0)
	testing.expect_value(t, column, 0)
}
