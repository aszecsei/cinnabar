package cook

import "core:os"
import "core:testing"

@(test)
targets_follow_entry_points :: proc(t: ^testing.T) {
	stages := targets("float4 ps_main() : SV_Target { return 0; }\nVaryings vs_main() {}")
	testing.expect_value(t, len(stages), 2)
	if len(stages) == 2 {
		testing.expect_value(t, stages[0], Target{"vs", "vs_6_6", "vs_main"})
		testing.expect_value(t, stages[1], Target{"ps", "ps_6_6", "ps_main"})
	}
	// An identifier that only contains an entry point name is not one.
	testing.expect_value(t, len(targets("void my_cs_main_helper() {}")), 0)

	library := targets("[shader(\"raygeneration\")] void ray_generation() {} void cs_main() {}")
	testing.expect_value(t, len(library), 1)
	if len(library) == 1 {
		testing.expect_value(t, library[0], Target{stage = "lib", profile = "lib_6_6"})
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
		testing.expect_value(t, names[0], "a.hlsli")
		testing.expect_value(t, names[1], "dir/b.hlsli")
	}

	// The fixed header resolves from the include directory, like DXC's -I.
	path, ok := resolve_include("cinnabar.hlsli", "samples/mygame/shaders", {"lib/core/gpu/shaders"})
	testing.expect(t, ok && os.is_file(path))
	_, missing := resolve_include("nothing.hlsli", "samples/mygame/shaders", {"lib/core/gpu/shaders"})
	testing.expect(t, !missing)
}

@(test)
keys_change_with_inputs :: proc(t: ^testing.T) {
	target := Target{"ps", "ps_6_6", "ps_main"}
	a := []Input{{"a.hlsl", transmute([]byte)string("one")}}
	b := []Input{{"a.hlsl", transmute([]byte)string("two")}}
	testing.expect(t, cache_key("dxc 1", target, a) == cache_key("dxc 1", target, a))
	testing.expect(t, cache_key("dxc 1", target, a) != cache_key("dxc 1", target, b), "the source did not change the key")
	testing.expect(t, cache_key("dxc 1", target, a) != cache_key("dxc 2", target, a), "the DXC version did not change the key")
	vertex := Target{"vs", "vs_6_6", "vs_main"}
	testing.expect(t, cache_key("dxc 1", target, a) != cache_key("dxc 1", vertex, a), "the target did not change the key")

	value, ok := strconv_parse_hex("00ff10")
	testing.expect(t, ok && value == 0xff10)
	_, bad := strconv_parse_hex("xyz")
	testing.expect(t, !bad)
}
