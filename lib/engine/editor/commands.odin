package editor

import "base:runtime"
import "core:log"
import "core:math/rand"

import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/script"

// Game commands (see docs/editor.md#commands): commands that the game describes, which the editor shows in its ribbon
// and its command palette and runs in the game. A command that changes the scene does not change the world itself: it
// adds operations to its context, and the editor applies them to its document as one undo entry, which sends them
// back, so the edit can be undone like any other.

Command_Proc :: #type proc(ctx: ^Command_Context)

// Command is a game command. Its strings and its procedure are the DLL's, so it is a registration: register it again
// after editor.reload, in on_reload.
Command :: struct {
	// Unique in the game, such as "mygame.add_triangle".
	id:          string,
	label:       string,
	description: string,
	// The ribbon tab and group to show it in, by label.
	tab:         string,
	group:       string,
	// The name of an icon of the editor's set, or "".
	icon:        string,
	// Whether the command edits the scene, so the editor offers it only in Edit.
	edits:       bool,
	procedure:   Command_Proc,
}

// Command_Context is what a command runs with. Its memory is the frame's.
Command_Context :: struct {
	world:      ^ecs.World,
	scripts:    ^script.Runtime,
	// The game's own data, as the game passed it to poll.
	user:       rawptr,
	// The entities that the editor has selected, the primary one last.
	selection:  []ecs.Entity,
	// The editor's camera, so a command can put something in view.
	camera:     link.Editor_Camera,
	// Edits of the scene, by scene ID, which the editor applies.
	operations: [dynamic]link.Operation,
	// A line for the editor's console, or "".
	message:    string,
	allocator:  runtime.Allocator,
}

// register_command adds a command. The editor gets the list with the types.
register_command :: proc(e: ^Editor, command: Command) {
	for c in e.commands {
		if c.id == command.id {
			log.errorf("editor: the command %s is registered twice", command.id)
			return
		}
	}
	append(&e.commands, command)
	e.types_sent = false
}

// scene_id is an entity's scene ID, or 0 for one that the game spawned, which no operation can name.
scene_id :: proc(w: ^ecs.World, entity: ecs.Entity) -> u64 {
	return scene_id_of(w, entity)
}

// new_scene_id is a random scene ID for an entity that a command creates.
new_scene_id :: proc() -> u64 {
	for {
		if id := rand.uint64(); id != 0 {
			return id
		}
	}
}

// scene_numbers is a field value of up to four numbers.
scene_numbers :: proc(values: ..f64) -> (v: link.Scene_Value) {
	v.kind = .Number
	v.count = u8(min(len(values), 4))
	for x, i in values[:v.count] {
		v.floats[i] = x
	}
	return
}

// scene_position is a World_Position as a field value: three integers.
scene_position :: proc(p: ecs.World_Position) -> (v: link.Scene_Value) {
	v.kind = .Number
	v.count = 3
	v.integer = 0b111
	for x, i in p.raw {
		v.ints[i] = x
		v.floats[i] = f64(x)
	}
	return
}

// scene_field is a field with a value, for an operation's fields or a component's.
scene_field :: proc(name: string, value: link.Scene_Value) -> link.Scene_Field {
	return {name = name, value = value}
}

@(private)
command_infos :: proc(e: ^Editor, allocator: runtime.Allocator) -> link.Game_Commands {
	infos := make([]link.Game_Command_Info, len(e.commands), allocator)
	for c, i in e.commands {
		infos[i] = {id = c.id, label = c.label, description = c.description, tab = c.tab, group = c.group, icon = c.icon, edits = c.edits}
	}
	return {commands = infos}
}

@(private)
run_command :: proc(e: ^Editor, w: ^ecs.World, scripts: ^script.Runtime, user: rawptr, id: string, out: ^[dynamic]byte, allocator: runtime.Allocator) {
	for c in e.commands {
		if c.id != id {
			continue
		}
		ctx := Command_Context {
			world      = w,
			scripts    = scripts,
			user       = user,
			selection  = e.viewport.selection[:],
			camera     = e.viewport.camera,
			operations = make([dynamic]link.Operation, allocator),
			allocator  = allocator,
		}
		context.allocator = allocator
		c.procedure(&ctx)
		link.write_message(out, link.Game_Command_Result{id = id, operations = ctx.operations[:], message = ctx.message})
		return
	}
	log.warnf("editor: the game has no command %s", id)
	link.write_message(out, link.Game_Command_Result{id = id, message = "the game has no such command"})
}
