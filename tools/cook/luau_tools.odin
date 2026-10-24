package cook

import "core:c"

// lib/core/luau/luau_tools.cpp, which `just luau` builds with the static Luau libraries. The analyzer and its
// configuration library are only the cooker's.
foreign import luau_tools {
	"../../build/luau/static/out/luau_tools.lib",
	"../../build/luau/static/out/Luau.Analysis.lib",
	"../../build/luau/static/out/Luau.Config.lib",
}

// Luau_Report receives a require path, or an error message. line is 1-based.
Luau_Report :: #type proc "c" (ud: rawptr, text: [^]u8, size: c.size_t, line: c.int)

@(default_calling_convention = "c")
foreign luau_tools {
	// cn_luau_find_requires parses source and reports each call of the global require with a string literal. A parse
	// error, or a require whose argument is not a string literal, goes to on_error. It returns false if the source
	// does not parse. defines_behaviour is set if the source calls Behaviour.define.
	cn_luau_find_requires :: proc(source: [^]u8, size: c.size_t, ud: rawptr, on_require, on_error: Luau_Report, defines_behaviour: ^bool) -> bool ---

	cn_luau_checker_create :: proc() -> ^Luau_Checker ---
	cn_luau_checker_destroy :: proc(checker: ^Luau_Checker) ---
	// cn_luau_checker_define loads a definition file into the global scope. It returns false, and reports the
	// errors, if the file does not load. Call it before the first check.
	cn_luau_checker_define :: proc(checker: ^Luau_Checker, source: [^]u8, size: c.size_t, ud: rawptr, on_error: Luau_Report) -> bool ---
	// mode: 0 for nocheck, 1 for nonstrict, 2 for strict. A --! comment in the source overrides it.
	cn_luau_checker_add_module :: proc(checker: ^Luau_Checker, name: [^]u8, name_size: c.size_t, source: [^]u8, size: c.size_t, mode: c.int) ---
	cn_luau_checker_add_require :: proc(checker: ^Luau_Checker, from: [^]u8, from_size: c.size_t, path: [^]u8, path_size: c.size_t, to: [^]u8, to_size: c.size_t) ---
	// cn_luau_checker_check checks a module and the modules it requires, and reports the errors in the module. It
	// returns the number of errors.
	cn_luau_checker_check :: proc(checker: ^Luau_Checker, name: [^]u8, name_size: c.size_t, ud: rawptr, on_error: Luau_Type_Error) -> c.int ---
}

Luau_Checker :: struct {}

// Luau_Type_Error receives a type error. line and column are 1-based.
Luau_Type_Error :: #type proc "c" (ud: rawptr, module: [^]u8, module_size: c.size_t, line, column: c.int, message: [^]u8, size: c.size_t)
