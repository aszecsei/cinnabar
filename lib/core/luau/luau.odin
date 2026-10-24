// Package luau binds the Luau C API: the VM (lua.h, lualib.h), the compiler (luacode.h) and the code generator
// (luacodegen.h). Names drop their C prefix: lua_pushnumber is pushnumber, luaL_sandbox is L_sandbox and luau_load
// is load. C macros are procedures here. See docs/scripting.md#embedding.
//
// lib/core/luau/CMakeLists.txt builds the libraries that this package links. Luau raises errors with longjmp, so an
// error skips the defer statements of the Odin frames that it jumps over.
package luau

import "core:c"

// LUAU_SHARED links luau.dll, which the development host and the game DLL share. Otherwise Luau links statically.
LUAU_SHARED :: #config(LUAU_SHARED, false)

when LUAU_SHARED {
	foreign import lib "../../../build/luau/shared/out/luau.lib"
} else {
	foreign import lib {
		"../../../build/luau/static/out/Luau.VM.lib",
		"../../../build/luau/static/out/Luau.CodeGen.lib",
		"../../../build/luau/static/out/Luau.Compiler.lib",
		"../../../build/luau/static/out/Luau.Ast.lib",
		"../../../build/luau/static/out/Luau.Bytecode.lib",
		"../../../build/luau/static/out/Luau.Common.lib",
		"../../../build/luau/static/out/luau_shim.lib",
	}
}

// These match vendor/luau/VM/include/luaconf.h as lib/core/luau/CMakeLists.txt builds it.
MAXCSTACK :: 8000
MINSTACK :: 20
IDSIZE :: 256
UTAG_LIMIT :: 128
LUTAG_LIMIT :: 128
MEMORY_CATEGORIES :: 256
VECTOR_SIZE :: 3

MULTRET :: -1
REGISTRYINDEX :: -MAXCSTACK - 2000
ENVIRONINDEX :: -MAXCSTACK - 2001
GLOBALSINDEX :: -MAXCSTACK - 2002

NOREF :: -1
REFNIL :: 0

State :: struct {}

Status :: enum c.int {
	OK,
	YIELD,
	ERRRUN,
	// A legacy code, kept for compatibility.
	ERRSYNTAX,
	ERRMEM,
	ERRERR,
	// Yielded for a debug breakpoint.
	BREAK,
}

Co_Status :: enum c.int {
	RUN,
	SUS,
	NOR,
	FIN,
	ERR,
}

// Type matches lua_Type with 32-bit float vectors.
Type :: enum c.int {
	NONE = -1,
	NIL,
	BOOLEAN,
	LIGHTUSERDATA,
	NUMBER,
	INTEGER,
	VECTOR,
	STRING,
	TABLE,
	FUNCTION,
	USERDATA,
	THREAD,
	BUFFER,
	CLASS,
	OBJECT,
}

GC_Op :: enum c.int {
	STOP,
	RESTART,
	COLLECT,
	COUNT,
	COUNTB,
	ISRUNNING,
	STEP,
	SETGOAL,
	SETSTEPMUL,
	SETSTEPSIZE,
	ISPAUSED,
}

CFunction :: #type proc "c" (L: ^State) -> c.int
Continuation :: #type proc "c" (L: ^State, status: c.int) -> c.int
Alloc :: #type proc "c" (ud: rawptr, ptr: rawptr, osize, nsize: c.size_t) -> rawptr
Destructor :: #type proc "c" (L: ^State, userdata: rawptr)
Hook :: #type proc "c" (L: ^State, ar: ^Debug)

Debug :: struct {
	name:        cstring,
	what:        cstring,
	source:      cstring,
	short_src:   cstring,
	linedefined: c.int,
	currentline: c.int,
	protoid:     c.int,
	bytecodeid:  c.int,
	nupvals:     u8,
	nparams:     u8,
	isvararg:    c.char,
	userdata:    rawptr,
	ssbuf:       [IDSIZE]c.char,
}

// Callbacks are shared by every thread of a VM. Every pointer stored here must stay valid for the VM's lifetime, so
// game-side code never stores one (see docs/scripting.md#host-trampolines).
Callbacks :: struct {
	userdata:            rawptr,
	interrupt:           proc "c" (L: ^State, gc: c.int),
	panic:               proc "c" (L: ^State, errcode: c.int),
	userthread:          proc "c" (LP: ^State, L: ^State),
	useratom:            proc "c" (L: ^State, s: [^]c.char, l: c.size_t) -> i16,
	userfinalizer:       proc "c" (L: ^State, co: ^State),
	debugbreak:          proc "c" (L: ^State, ar: ^Debug),
	debugstep:           proc "c" (L: ^State, ar: ^Debug),
	debuginterrupt:      proc "c" (L: ^State, ar: ^Debug),
	debugprotectederror: proc "c" (L: ^State),
	onallocate:          proc "c" (L: ^State, block: rawptr, osize, nsize: c.size_t, memcat: u8, tt: c.int, tag: c.int),
	preresume:           proc "c" (L: ^State),
	postresume:          proc "c" (L: ^State),
	onfree:              proc "c" (L: ^State, block: rawptr),
}

// The direct access callbacks of a userdata tag (see registeruserdatadirectaccess). The VM calls them in a C call frame
// with the same arguments as __index, __newindex or __namecall, and passes the key's atom and a slot that it caches per
// instruction. cachedslot is shared by every tag, so a callback checks its value before it trusts it.
UserdataDirectAccess :: #type proc "c" (L: ^State, data: rawptr, atom: c.int, cachedslot: ^u16, utag: c.int)
UserdataDirectNamecall :: #type proc "c" (L: ^State, data: rawptr, atom: c.int, cachedslot: ^u16, utag: c.int) -> c.int

L_Reg :: struct {
	name: cstring,
	func: CFunction,
}

@(default_calling_convention = "c", link_prefix = "lua_")
foreign lib {
	// State manipulation
	newstate :: proc(allocator: Alloc, ud: rawptr) -> ^State ---
	close :: proc(L: ^State) ---
	newthread :: proc(L: ^State) -> ^State ---
	mainthread :: proc(L: ^State) -> ^State ---
	resetthread :: proc(L: ^State) ---
	isthreadreset :: proc(L: ^State) -> b32 ---

	// Basic stack manipulation
	absindex :: proc(L: ^State, idx: c.int) -> c.int ---
	gettop :: proc(L: ^State) -> c.int ---
	settop :: proc(L: ^State, idx: c.int) ---
	pushvalue :: proc(L: ^State, idx: c.int) ---
	remove :: proc(L: ^State, idx: c.int) ---
	insert :: proc(L: ^State, idx: c.int) ---
	replace :: proc(L: ^State, idx: c.int) ---
	checkstack :: proc(L: ^State, sz: c.int) -> b32 ---
	rawcheckstack :: proc(L: ^State, sz: c.int) ---
	xmove :: proc(from, to: ^State, n: c.int) ---
	xpush :: proc(from, to: ^State, idx: c.int) ---

	// Access (stack to Odin)
	isnumber :: proc(L: ^State, idx: c.int) -> b32 ---
	isstring :: proc(L: ^State, idx: c.int) -> b32 ---
	iscfunction :: proc(L: ^State, idx: c.int) -> b32 ---
	isLfunction :: proc(L: ^State, idx: c.int) -> b32 ---
	isuserdata :: proc(L: ^State, idx: c.int) -> b32 ---
	type :: proc(L: ^State, idx: c.int) -> Type ---
	typename :: proc(L: ^State, tp: Type) -> cstring ---
	equal :: proc(L: ^State, idx1, idx2: c.int) -> b32 ---
	rawequal :: proc(L: ^State, idx1, idx2: c.int) -> b32 ---
	lessthan :: proc(L: ^State, idx1, idx2: c.int) -> b32 ---
	tonumberx :: proc(L: ^State, idx: c.int, isnum: ^b32) -> f64 ---
	tointegerx :: proc(L: ^State, idx: c.int, isnum: ^b32) -> c.int ---
	tounsignedx :: proc(L: ^State, idx: c.int, isnum: ^b32) -> c.uint ---
	tovector :: proc(L: ^State, idx: c.int) -> ^[VECTOR_SIZE]f32 ---
	toboolean :: proc(L: ^State, idx: c.int) -> b32 ---
	tointeger64 :: proc(L: ^State, idx: c.int, isinteger: ^b32) -> i64 ---
	tolstring :: proc(L: ^State, idx: c.int, len: ^c.size_t) -> [^]c.char ---
	tostringatom :: proc(L: ^State, idx: c.int, atom: ^c.int) -> cstring ---
	tolstringatom :: proc(L: ^State, idx: c.int, len: ^c.size_t, atom: ^c.int) -> [^]c.char ---
	namecallatom :: proc(L: ^State, atom: ^c.int) -> cstring ---
	objlen :: proc(L: ^State, idx: c.int) -> c.int ---
	tocfunction :: proc(L: ^State, idx: c.int) -> CFunction ---
	tolightuserdata :: proc(L: ^State, idx: c.int) -> rawptr ---
	tolightuserdatatagged :: proc(L: ^State, idx: c.int, tag: c.int) -> rawptr ---
	touserdata :: proc(L: ^State, idx: c.int) -> rawptr ---
	touserdatatagged :: proc(L: ^State, idx: c.int, tag: c.int) -> rawptr ---
	userdatatag :: proc(L: ^State, idx: c.int) -> c.int ---
	lightuserdatatag :: proc(L: ^State, idx: c.int) -> c.int ---
	tothread :: proc(L: ^State, idx: c.int) -> ^State ---
	tobuffer :: proc(L: ^State, idx: c.int, len: ^c.size_t) -> rawptr ---
	topointer :: proc(L: ^State, idx: c.int) -> rawptr ---

	// Push (Odin to stack)
	pushnil :: proc(L: ^State) ---
	pushnumber :: proc(L: ^State, n: f64) ---
	pushinteger :: proc(L: ^State, n: c.int) ---
	pushinteger64 :: proc(L: ^State, n: i64) ---
	pushunsigned :: proc(L: ^State, n: c.uint) ---
	pushvector :: proc(L: ^State, x, y, z: f32) ---
	pushlstring :: proc(L: ^State, s: [^]c.char, l: c.size_t) ---
	pushstring :: proc(L: ^State, s: cstring) ---
	pushfstringL :: proc(L: ^State, fmt: cstring, #c_vararg args: ..any) -> cstring ---
	pushcclosurek :: proc(L: ^State, fn: CFunction, debugname: cstring, nup: c.int, cont: Continuation) ---
	pushboolean :: proc(L: ^State, b: b32) ---
	pushthread :: proc(L: ^State) -> b32 ---
	pushlightuserdatatagged :: proc(L: ^State, p: rawptr, tag: c.int) ---
	newuserdatatagged :: proc(L: ^State, sz: c.size_t, tag: c.int) -> rawptr ---
	newuserdatataggedwithmetatable :: proc(L: ^State, sz: c.size_t, tag: c.int) -> rawptr ---
	newuserdatadtor :: proc(L: ^State, sz: c.size_t, dtor: Destructor) -> rawptr ---
	newbuffer :: proc(L: ^State, sz: c.size_t) -> rawptr ---

	// Get (Luau to stack)
	gettable :: proc(L: ^State, idx: c.int) -> Type ---
	getfield :: proc(L: ^State, idx: c.int, k: cstring) -> Type ---
	rawgetfield :: proc(L: ^State, idx: c.int, k: cstring) -> Type ---
	rawget :: proc(L: ^State, idx: c.int) -> Type ---
	rawgeti :: proc(L: ^State, idx: c.int, n: c.int) -> Type ---
	rawgetptagged :: proc(L: ^State, idx: c.int, p: rawptr, tag: c.int) -> Type ---
	createtable :: proc(L: ^State, narr, nrec: c.int) ---
	setreadonly :: proc(L: ^State, idx: c.int, enabled: b32) ---
	getreadonly :: proc(L: ^State, idx: c.int) -> b32 ---
	setsafeenv :: proc(L: ^State, idx: c.int, enabled: b32) ---
	getmetatable :: proc(L: ^State, objindex: c.int) -> b32 ---
	getfenv :: proc(L: ^State, idx: c.int) ---

	// Set (stack to Luau)
	settable :: proc(L: ^State, idx: c.int) ---
	setfield :: proc(L: ^State, idx: c.int, k: cstring) ---
	rawsetfield :: proc(L: ^State, idx: c.int, k: cstring) ---
	rawset :: proc(L: ^State, idx: c.int) ---
	rawseti :: proc(L: ^State, idx: c.int, n: c.int) ---
	rawsetptagged :: proc(L: ^State, idx: c.int, p: rawptr, tag: c.int) ---
	setmetatable :: proc(L: ^State, objindex: c.int) -> c.int ---
	setfenv :: proc(L: ^State, idx: c.int) -> b32 ---

	// Calls
	call :: proc(L: ^State, nargs, nresults: c.int) ---
	pcall :: proc(L: ^State, nargs, nresults, errfunc: c.int) -> Status ---
	cpcall :: proc(L: ^State, func: CFunction, ud: rawptr) -> Status ---
	callyieldable :: proc(L: ^State, nargs, nresults: c.int) -> c.int ---
	pcallyieldable :: proc(L: ^State, nargs, nresults, errfunc: c.int) -> c.int ---

	// Coroutines
	yield :: proc(L: ^State, nresults: c.int) -> c.int ---
	resume :: proc(L: ^State, from: ^State, narg: c.int) -> Status ---
	resumeerror :: proc(L: ^State, from: ^State) -> Status ---
	status :: proc(L: ^State) -> Status ---
	isyieldable :: proc(L: ^State) -> b32 ---
	getthreaddata :: proc(L: ^State) -> rawptr ---
	setthreaddata :: proc(L: ^State, data: rawptr) ---
	costatus :: proc(L: ^State, co: ^State) -> Co_Status ---

	// Garbage collection and memory statistics
	gc :: proc(L: ^State, what: GC_Op, data: c.int) -> c.int ---
	setmemcat :: proc(L: ^State, category: c.int) ---
	totalbytes :: proc(L: ^State, category: c.int) -> c.size_t ---
	allocationrate :: proc(L: ^State) -> i64 ---

	// Miscellaneous
	error :: proc(L: ^State) -> ! ---
	next :: proc(L: ^State, idx: c.int) -> b32 ---
	rawiter :: proc(L: ^State, idx: c.int, iter: c.int) -> c.int ---
	concat :: proc(L: ^State, n: c.int) ---
	clock :: proc() -> f64 ---
	setuserdatatag :: proc(L: ^State, idx: c.int, tag: c.int) ---
	setuserdatametatable :: proc(L: ^State, tag: c.int) ---
	getuserdatametatable :: proc(L: ^State, tag: c.int) ---
	getuserdataname :: proc(L: ^State, tag: c.int) -> cstring ---
	setlightuserdataname :: proc(L: ^State, tag: c.int, name: cstring) ---
	getlightuserdataname :: proc(L: ^State, tag: c.int) -> cstring ---
	clonefunction :: proc(L: ^State, idx: c.int) ---
	cleartable :: proc(L: ^State, idx: c.int) ---
	clonetable :: proc(L: ^State, idx: c.int) ---
	getallocf :: proc(L: ^State, ud: ^rawptr) -> Alloc ---

	// References pin values in the registry.
	ref :: proc(L: ^State, idx: c.int) -> c.int ---
	unref :: proc(L: ^State, ref: c.int) -> c.int ---

	// Experimental: the VM calls these for the tag's __index, __newindex and __namecall, when the key has an atom. The
	// tag's metatable must exist first. It returns false without one.
	registeruserdatadirectaccess :: proc(L: ^State, tag: c.int, get, set: UserdataDirectAccess, namecall: UserdataDirectNamecall) -> b32 ---

	// Debug
	stackdepth :: proc(L: ^State) -> c.int ---
	// The function at the level runs as native code.
	incustomexecution :: proc(L: ^State, level: c.int) -> b32 ---
	hascustomexecution :: proc(L: ^State, level: c.int) -> b32 ---
	getinfo :: proc(L: ^State, level: c.int, what: cstring, ar: ^Debug) -> b32 ---
	getargument :: proc(L: ^State, level: c.int, n: c.int) -> c.int ---
	getlocal :: proc(L: ^State, level: c.int, n: c.int) -> cstring ---
	setlocal :: proc(L: ^State, level: c.int, n: c.int) -> cstring ---
	getupvalue :: proc(L: ^State, funcindex: c.int, n: c.int) -> cstring ---
	setupvalue :: proc(L: ^State, funcindex: c.int, n: c.int) -> cstring ---
	singlestep :: proc(L: ^State, enabled: b32) ---
	breakpoint :: proc(L: ^State, funcindex: c.int, line: c.int, enabled: b32) -> c.int ---
	// Not thread-safe: the result is in a shared buffer.
	debugtrace :: proc(L: ^State) -> cstring ---

	callbacks :: proc(L: ^State) -> ^Callbacks ---
}

@(default_calling_convention = "c", link_prefix = "lua")
foreign lib {
	L_register :: proc(L: ^State, libname: cstring, l: [^]L_Reg) ---
	L_getmetafield :: proc(L: ^State, obj: c.int, e: cstring) -> b32 ---
	L_callmeta :: proc(L: ^State, obj: c.int, e: cstring) -> b32 ---
	L_typeerrorL :: proc(L: ^State, narg: c.int, tname: cstring) -> ! ---
	L_argerrorL :: proc(L: ^State, narg: c.int, extramsg: cstring) -> ! ---
	L_checklstring :: proc(L: ^State, numArg: c.int, l: ^c.size_t) -> [^]c.char ---
	L_optlstring :: proc(L: ^State, numArg: c.int, def: cstring, l: ^c.size_t) -> [^]c.char ---
	L_checknumber :: proc(L: ^State, numArg: c.int) -> f64 ---
	L_optnumber :: proc(L: ^State, nArg: c.int, def: f64) -> f64 ---
	L_checkboolean :: proc(L: ^State, narg: c.int) -> b32 ---
	L_optboolean :: proc(L: ^State, narg: c.int, def: b32) -> b32 ---
	L_checkinteger :: proc(L: ^State, numArg: c.int) -> c.int ---
	L_checkinteger64 :: proc(L: ^State, numArg: c.int) -> i64 ---
	L_optinteger :: proc(L: ^State, nArg: c.int, def: c.int) -> c.int ---
	L_optinteger64 :: proc(L: ^State, nArg: c.int, def: i64) -> i64 ---
	L_checkunsigned :: proc(L: ^State, numArg: c.int) -> c.uint ---
	L_optunsigned :: proc(L: ^State, numArg: c.int, def: c.uint) -> c.uint ---
	L_checkvector :: proc(L: ^State, narg: c.int) -> ^[VECTOR_SIZE]f32 ---
	L_optvector :: proc(L: ^State, narg: c.int, def: ^[VECTOR_SIZE]f32) -> ^[VECTOR_SIZE]f32 ---
	L_checkstack :: proc(L: ^State, sz: c.int, msg: cstring) ---
	L_checktype :: proc(L: ^State, narg: c.int, t: Type) ---
	L_checkany :: proc(L: ^State, narg: c.int) ---
	L_newmetatable :: proc(L: ^State, tname: cstring) -> b32 ---
	L_checkudata :: proc(L: ^State, ud: c.int, tname: cstring) -> rawptr ---
	L_checkudatatagged :: proc(L: ^State, ud: c.int, tag: c.int) -> rawptr ---
	L_checkbuffer :: proc(L: ^State, narg: c.int, len: ^c.size_t) -> rawptr ---
	L_where :: proc(L: ^State, lvl: c.int) ---
	L_errorL :: proc(L: ^State, fmt: cstring, #c_vararg args: ..any) -> ! ---
	L_tolstring :: proc(L: ^State, idx: c.int, len: ^c.size_t) -> [^]c.char ---
	L_findtable :: proc(L: ^State, idx: c.int, fname: cstring, szhint: c.int) -> cstring ---
	L_typename :: proc(L: ^State, idx: c.int) -> cstring ---
	L_traceback :: proc(L: ^State, L1: ^State, msg: cstring, level: c.int) ---

	// L_newstate opens a VM with the C runtime's allocator. The engine's VMs use the host's allocator instead (see
	// cinnabar:core/script), so only tools use it.
	L_newstate :: proc() -> ^State ---
	L_openlibs :: proc(L: ^State) ---
	// L_sandbox makes the built-in libraries and the globals read-only. Call it after the globals are set up.
	L_sandbox :: proc(L: ^State) ---
	// L_sandboxthread gives a thread its own global table, which reads through to the sandboxed globals.
	L_sandboxthread :: proc(L: ^State) ---
}

Compile_Constant :: rawptr
Library_Member_Type_Callback :: #type proc "c" (library: cstring, member: cstring) -> c.int
Library_Member_Constant_Callback :: #type proc "c" (library: cstring, member: cstring, constant: ^Compile_Constant)

// Compile_Options matches lua_CompileOptions. String arrays end with a nil entry.
Compile_Options :: struct {
	// 0: none. 1: baseline, keeps debuggability. 2: also inlining and other optimizations that harm debuggability.
	optimizationLevel:         c.int,
	// 0: none. 1: line info and function names, enough for tracebacks. 2: also locals and upvalues, for a debugger.
	debugLevel:                c.int,
	// 0: type info for native modules only. 1: for all modules.
	typeInfoLevel:             c.int,
	coverageLevel:             c.int,
	vectorLib:                 cstring,
	vectorCtor:                cstring,
	vectorType:                cstring,
	vectorPrecision:           c.int,
	mutableGlobals:            [^]cstring,
	userdataTypes:             [^]cstring,
	librariesWithKnownMembers: [^]cstring,
	libraryMemberTypeCb:       Library_Member_Type_Callback,
	libraryMemberConstantCb:   Library_Member_Constant_Callback,
	disabledBuiltins:          [^]cstring,
}

@(default_calling_convention = "c", link_prefix = "luau_")
foreign lib {
	// compile returns bytecode, which encodes the error if compilation failed. Release it with free_bytecode.
	compile :: proc(source: [^]c.char, size: c.size_t, options: ^Compile_Options, outsize: ^c.size_t) -> [^]c.char ---
	load :: proc(L: ^State, chunkname: cstring, data: [^]c.char, size: c.size_t, env: c.int) -> Status ---

	codegen_supported :: proc() -> b32 ---
	codegen_create :: proc(L: ^State) ---
	codegen_compile :: proc(L: ^State, idx: c.int) ---
}

@(default_calling_convention = "c")
foreign lib {
	@(link_name = "cn_luau_free")
	free_bytecode :: proc(p: rawptr) ---
}

// The C macros of lua.h and lualib.h.

upvalueindex :: #force_inline proc "contextless" (i: c.int) -> c.int {
	return GLOBALSINDEX - i
}

ispseudo :: #force_inline proc "contextless" (i: c.int) -> bool {
	return i <= REGISTRYINDEX
}

tonumber :: #force_inline proc "c" (L: ^State, i: c.int) -> f64 {
	return tonumberx(L, i, nil)
}

tointeger :: #force_inline proc "c" (L: ^State, i: c.int) -> c.int {
	return tointegerx(L, i, nil)
}

tounsigned :: #force_inline proc "c" (L: ^State, i: c.int) -> c.uint {
	return tounsignedx(L, i, nil)
}

pop :: #force_inline proc "c" (L: ^State, n: c.int) {
	settop(L, -n - 1)
}

newtable :: #force_inline proc "c" (L: ^State) {
	createtable(L, 0, 0)
}

newuserdata :: #force_inline proc "c" (L: ^State, sz: c.size_t) -> rawptr {
	return newuserdatatagged(L, sz, 0)
}

isfunction :: #force_inline proc "c" (L: ^State, n: c.int) -> bool {return type(L, n) == .FUNCTION}
istable :: #force_inline proc "c" (L: ^State, n: c.int) -> bool {return type(L, n) == .TABLE}
islightuserdata :: #force_inline proc "c" (L: ^State, n: c.int) -> bool {return type(L, n) == .LIGHTUSERDATA}
isnil :: #force_inline proc "c" (L: ^State, n: c.int) -> bool {return type(L, n) == .NIL}
isboolean :: #force_inline proc "c" (L: ^State, n: c.int) -> bool {return type(L, n) == .BOOLEAN}
isinteger64 :: #force_inline proc "c" (L: ^State, n: c.int) -> bool {return type(L, n) == .INTEGER}
isvector :: #force_inline proc "c" (L: ^State, n: c.int) -> bool {return type(L, n) == .VECTOR}
isthread :: #force_inline proc "c" (L: ^State, n: c.int) -> bool {return type(L, n) == .THREAD}
isbuffer :: #force_inline proc "c" (L: ^State, n: c.int) -> bool {return type(L, n) == .BUFFER}
isnone :: #force_inline proc "c" (L: ^State, n: c.int) -> bool {return type(L, n) == .NONE}
isnoneornil :: #force_inline proc "c" (L: ^State, n: c.int) -> bool {return type(L, n) <= .NIL}

pushcfunction :: #force_inline proc "c" (L: ^State, fn: CFunction, debugname: cstring) {
	pushcclosurek(L, fn, debugname, 0, nil)
}

pushcclosure :: #force_inline proc "c" (L: ^State, fn: CFunction, debugname: cstring, nup: c.int) {
	pushcclosurek(L, fn, debugname, nup, nil)
}

pushlightuserdata :: #force_inline proc "c" (L: ^State, p: rawptr) {
	pushlightuserdatatagged(L, p, 0)
}

// pushodinstring pushes an Odin string, which need not end with a zero byte.
pushodinstring :: #force_inline proc "c" (L: ^State, s: string) {
	pushlstring(L, raw_data(s), c.size_t(len(s)))
}

// toodinstring is the string at idx, or "" if the value is not a string or a number. It points into the VM heap, so
// it is valid while the value stays on the stack.
toodinstring :: #force_inline proc "c" (L: ^State, idx: c.int) -> string {
	n: c.size_t
	s := tolstring(L, idx, &n)
	return s == nil ? "" : string(s[:n])
}

setglobal :: #force_inline proc "c" (L: ^State, s: cstring) {
	setfield(L, GLOBALSINDEX, s)
}

getglobal :: #force_inline proc "c" (L: ^State, s: cstring) -> Type {
	return getfield(L, GLOBALSINDEX, s)
}

tostring :: #force_inline proc "c" (L: ^State, i: c.int) -> cstring {
	return cstring(tolstring(L, i, nil))
}

getref :: #force_inline proc "c" (L: ^State, ref: c.int) -> Type {
	return rawgeti(L, REGISTRYINDEX, ref)
}

L_checkstring :: #force_inline proc "c" (L: ^State, n: c.int) -> cstring {
	return cstring(L_checklstring(L, n, nil))
}

// caller_source is the chunk name of the nearest Luau function that called the running C function, skipping C
// functions such as pcall in between. It is "" if there is none.
caller_source :: proc "c" (L: ^State) -> string {
	ar: Debug
	for level: c.int = 1; getinfo(L, level, "s", &ar); level += 1 {
		if ar.what != "C" {
			return string(ar.source)
		}
	}
	return ""
}

L_getmetatable :: #force_inline proc "c" (L: ^State, n: cstring) -> Type {
	return getfield(L, REGISTRYINDEX, n)
}
