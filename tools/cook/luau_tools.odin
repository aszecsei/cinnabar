package cook

import "core:c"

// lib/core/luau/luau_tools.cpp, which `just luau` builds with the static Luau libraries.
foreign import luau_tools "../../build/luau/static/out/luau_tools.lib"

// Luau_Report receives a require path, or an error message. line is 1-based.
Luau_Report :: #type proc "c" (ud: rawptr, text: [^]u8, size: c.size_t, line: c.int)

@(default_calling_convention = "c")
foreign luau_tools {
	// cn_luau_find_requires parses source and reports each call of the global require with a string literal. A parse
	// error, or a require whose argument is not a string literal, goes to on_error. It returns false if the source
	// does not parse.
	cn_luau_find_requires :: proc(source: [^]u8, size: c.size_t, ud: rawptr, on_require, on_error: Luau_Report) -> bool ---
}
