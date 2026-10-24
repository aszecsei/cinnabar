// Package script is the host side of the script VM. It owns the VM heaps and every function pointer that Luau stores:
// the allocator, the binding dispatcher, the atom interner, the watchdog and the panic handler. The game reaches them
// through Platform_API, and fills a Bindings table that the dispatcher reads. See docs/scripting.md#host-trampolines.
package script_host

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:hash"
import "core:log"
import "core:os"
import "core:sync"
import "core:time"

import "cinnabar:core/luau"

MAX_BINDINGS :: 4096
// Open addressing at half load at most.
BINDING_SLOTS :: 2 * MAX_BINDINGS
#assert(BINDING_SLOTS & (BINDING_SLOTS - 1) == 0)

// The watchdog reads the clock once per this many interrupts, because Luau interrupts at every loop back edge.
WATCHDOG_INTERVAL :: 1024

// Binding_Id is the stable ID of a binding: the hash of its qualified name, such as "Entity.get". Zero is never an ID.
Binding_Id :: distinct u32

// Binding_Proc is a game-side binding. It runs with Bindings.ctx as its context, and returns its number of results,
// or YIELD to yield the calling coroutine with no results. It may raise a Luau error, which skips its defers.
Binding_Proc :: #type proc(L: ^luau.State) -> c.int

YIELD :: -1

Binding :: struct {
	id:        Binding_Id,
	procedure: Binding_Proc,
}

// Bindings is the game's table of bindings. It lives in Game_State, and the VM keeps a pointer to it, so it must not
// move while the VM is open. Its procedures point into the DLL image, so on_reload clears it and registers every
// binding again. The VM's closures hold binding IDs, not procedures, so they stay valid.
Bindings :: struct {
	// The context that bindings run with. The game sets it each time before it runs scripts, so it never holds a
	// stale allocator or logger.
	ctx:      runtime.Context,
	// The watchdog stops a script that is still running at this time. The zero tick disables the watchdog.
	deadline: time.Tick,
	slots:    [BINDING_SLOTS]Binding,
	count:    int,
	// Counts interrupts, so the watchdog reads the clock only once per WATCHDOG_INTERVAL.
	interrupts: u32,
}

binding_id :: proc "contextless" (name: string) -> Binding_Id {
	id := Binding_Id(hash.fnv32a(transmute([]byte)name))
	return id == 0 ? 1 : id
}

// register adds a binding. A second binding with the same name, or with a name of the same hash, is a programming
// error and panics.
register :: proc(b: ^Bindings, name: string, procedure: Binding_Proc) -> Binding_Id {
	id := binding_id(name)
	if b.count == MAX_BINDINGS {
		log.panicf("script: more than %d bindings", MAX_BINDINGS)
	}
	for i := u32(id); ; i += 1 {
		slot := &b.slots[i & (BINDING_SLOTS - 1)]
		if slot.id == id {
			log.panicf("script: binding %s conflicts with another binding", name)
		}
		if slot.id == 0 {
			slot^ = {id, procedure}
			b.count += 1
			return id
		}
	}
}

find :: proc "contextless" (b: ^Bindings, id: Binding_Id) -> Binding_Proc {
	for i := u32(id); ; i += 1 {
		slot := &b.slots[i & (BINDING_SLOTS - 1)]
		if slot.id == id {
			return slot.procedure
		}
		if slot.id == 0 {
			return nil
		}
	}
}

// clear removes every binding, for on_reload. ctx and deadline stay.
clear :: proc(b: ^Bindings) {
	b.slots = {}
	b.count = 0
}

// dispatch is the lua_CFunction of every binding. Its upvalues are the binding ID and the binding's name.
@(private)
dispatch :: proc "c" (L: ^luau.State) -> c.int {
	b := (^Bindings)(luau.callbacks(L).userdata)
	procedure := find(b, Binding_Id(luau.tounsigned(L, luau.upvalueindex(1))))
	if procedure == nil {
		luau.L_errorL(L, "binding %s no longer exists", luau.tostring(L, luau.upvalueindex(2)))
	}
	context = b.ctx
	n := procedure(L)
	return n == YIELD ? luau.yield(L, 0) : n
}

// push_binding pushes a closure that calls the binding with this name. The binding need not be registered yet.
push_binding :: proc(L: ^luau.State, name: string) {
	buffer: [128]byte
	debugname := fmt.bprintf(buffer[:len(buffer) - 1], "%s", name)
	luau.pushunsigned(L, c.uint(binding_id(name)))
	luau.pushodinstring(L, name)
	luau.pushcclosurek(L, dispatch, cstring(raw_data(debugname)), 2, nil)
}

// The atom interner is host-owned and append-only, so an atom never changes meaning across a code reload or a soft
// restart. Strings get atoms lazily, the first time the VM asks for one.
MAX_ATOMS :: 1 << 14
@(private)
ATOM_SLOTS :: 2 * MAX_ATOMS

@(private)
Atom_Slot :: struct {
	hash: u32,
	atom: i16,
}

@(private)
Atoms :: struct {
	mutex: sync.Mutex,
	slots: [ATOM_SLOTS]Atom_Slot,
	names: [MAX_ATOMS]string,
	count: int,
}

@(private)
atoms: Atoms

// atom interns a name and returns its atom, or -1 if the interner is full.
atom :: proc(name: string) -> i16 {
	sync.guard(&atoms.mutex)
	h := hash.fnv32a(transmute([]byte)name)
	for i := h; ; i += 1 {
		slot := &atoms.slots[i & (ATOM_SLOTS - 1)]
		if slot.atom == 0 {
			if atoms.count == MAX_ATOMS {
				log.errorf("script: more than %d atoms, %q gets none", MAX_ATOMS, name)
				return -1
			}
			index := i16(atoms.count)
			atoms.names[index] = strings_clone_host(name)
			atoms.count += 1
			slot^ = {h, index + 1}
			return index
		}
		if slot.hash == h && atoms.names[slot.atom - 1] == name {
			return slot.atom - 1
		}
	}
}

// atom_name is the name of an atom, or "" if it has none.
atom_name :: proc(atom: i16) -> string {
	sync.guard(&atoms.mutex)
	return atom >= 0 && int(atom) < atoms.count ? atoms.names[atom] : ""
}

// The interner keeps its names for the life of the process, in the host's own heap.
@(private = "file")
strings_clone_host :: proc(s: string) -> string {
	data := make([]byte, len(s), runtime.heap_allocator())
	copy(data, s)
	return string(data)
}

@(private)
useratom :: proc "c" (L: ^luau.State, s: [^]c.char, l: c.size_t) -> i16 {
	name := string(s[:l])
	h := hash.fnv32a(transmute([]byte)name)
	sync.mutex_lock(&atoms.mutex)
	defer sync.mutex_unlock(&atoms.mutex)
	for i := h; ; i += 1 {
		slot := &atoms.slots[i & (ATOM_SLOTS - 1)]
		if slot.atom == 0 {
			return -1
		}
		if slot.hash == h && atoms.names[slot.atom - 1] == name {
			return slot.atom - 1
		}
	}
}

// interrupt is the watchdog. Luau calls it at safepoints, and with gc >= 0 for collector steps, which must not raise
// errors.
@(private)
interrupt :: proc "c" (L: ^luau.State, gc: c.int) {
	b := (^Bindings)(luau.callbacks(L).userdata)
	if gc >= 0 || b.deadline == {} {
		return
	}
	b.interrupts += 1
	if b.interrupts % WATCHDOG_INTERVAL != 0 {
		return
	}
	if time.tick_diff(b.deadline, time.tick_now()) > 0 {
		b.deadline = {}
		luau.L_errorL(L, "script ran past its time budget")
	}
}

// panic runs when an error is raised outside of any protected call. The VM cannot continue.
@(private)
panic :: proc "c" (L: ^luau.State, errcode: c.int) {
	context = runtime.default_context()
	fmt.eprintfln("script: unprotected error %d: %s", errcode, luau.tostring(L, -1))
	os.exit(1)
}

// Every open VM, so a soft restart can close the ones that the old game left open.
@(private)
open_states: [dynamic]^luau.State
@(private)
open_states_mutex: sync.Mutex

// open creates a VM with the built-in libraries open. The game sets up its globals and then calls luau.L_sandbox.
// bindings must stay at the same address until close.
open :: proc(bindings: ^Bindings) -> ^luau.State {
	h := new(Heap, runtime.heap_allocator())
	if !heap_init(h) {
		log.error("script: cannot reserve the script heap")
		free(h, runtime.heap_allocator())
		return nil
	}
	L := luau.newstate(heap_alloc, h)
	if L == nil {
		heap_destroy(h)
		free(h, runtime.heap_allocator())
		return nil
	}
	callbacks := luau.callbacks(L)
	callbacks.userdata = bindings
	callbacks.interrupt = interrupt
	callbacks.panic = panic
	callbacks.useratom = useratom
	luau.L_openlibs(L)

	sync.guard(&open_states_mutex)
	if open_states == nil {
		open_states = make([dynamic]^luau.State, runtime.heap_allocator())
	}
	append(&open_states, L)
	return L
}

// close destroys a VM and releases its heap.
close :: proc(L: ^luau.State) {
	if L == nil {
		return
	}
	sync.lock(&open_states_mutex)
	for state, i in open_states {
		if state == L {
			unordered_remove(&open_states, i)
			break
		}
	}
	sync.unlock(&open_states_mutex)
	destroy_state(L)
}

// close_all closes every open VM, for a soft restart. It returns how many there were.
close_all :: proc() -> int {
	sync.lock(&open_states_mutex)
	states := open_states
	open_states = nil
	sync.unlock(&open_states_mutex)
	defer delete(states)
	for L in states {
		destroy_state(L)
	}
	return len(states)
}

@(private = "file")
destroy_state :: proc(L: ^luau.State) {
	ud: rawptr
	luau.getallocf(L, &ud)
	luau.close(L)
	h := (^Heap)(ud)
	heap_destroy(h)
	free(h, runtime.heap_allocator())
}

// heap_bytes is the number of bytes that a VM holds.
heap_bytes :: proc(L: ^luau.State) -> int {
	ud: rawptr
	luau.getallocf(L, &ud)
	return (^Heap)(ud).bytes
}
