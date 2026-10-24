// Package link is the editor link's protocol: its messages, their framing and their wire format (see
// docs/editor.md#editor-link). The host and the game both use it, so it imports nothing from core or engine.
package link

// A message's kind is its index in this union, from 1. Adding, removing or reordering messages changes the schema,
// and with it the protocol version, so an editor and a host that disagree refuse each other at the handshake.
Message :: union {
	Hello,
	Welcome,
	Refused,
	Log,
	Game_Reloaded,
	Viewport_Size,
	Frame_Target,
	Frame_Acknowledged,
	Component_Types,
	Entity_Snapshot,
	Entity_Delta,
	Watch_Entity,
	Unwatch_Entity,
	Entity_Values,
}

// Editor to host, first: the editor's protocol version and its name.
Hello :: struct {
	protocol: u64,
	editor:   string,
}

// Host to editor, the answer to a Hello with the same protocol version.
Welcome :: struct {
	protocol:    u64,
	game:        string,
	// The game DLL's Game_State layout hash.
	layout_hash: u64,
}

// Host to editor, the answer to a Hello with another protocol version. The host closes the link after it.
Refused :: struct {
	reason:   string,
	protocol: u64,
}

Log_Level :: enum u8 {
	Debug,
	Info,
	Warning,
	Error,
	Fatal,
}

// Host to editor: a line of the host's or the game's log. While an editor is linked, the log goes here and not to
// the host's console.
Log :: struct {
	level:    Log_Level,
	// Nanoseconds since the Unix epoch.
	time:     i64,
	// file:line:procedure.
	location: string,
	text:     string,
}

Reload_Kind :: enum u8 {
	// The DLL changed and Game_State kept its layout.
	Code,
	// The DLL changed Game_State's layout, so the game restarted with fresh state.
	Soft_Restart,
	// The host could not load the new DLL and kept the old one.
	Refused,
}

// Host to editor, after a new game DLL.
Game_Reloaded :: struct {
	kind: Reload_Kind,
}

// Editor to host: the viewport's size in physical pixels. The host renders at that size from a following frame.
Viewport_Size :: struct {
	width:  i32,
	height: i32,
}

// Host to editor: the shared target that frames render into (see docs/gpu.md#presentation). The objects are named
// <prefix>.texture0..2 and <prefix>.fence. Each resize makes a new generation, whose frames count from 1 again.
Frame_Target :: struct {
	prefix:     string,
	generation: u32,
	width:      i32,
	height:     i32,
}

// Editor to host: the editor has finished copying this frame of this generation. While an editor is linked, the host
// renders frame k into a shared texture only if k <= frame + 2.
Frame_Acknowledged :: struct {
	generation: u32,
	frame:      u64,
}

// The world (see docs/editor.md#world). The game side sends these, and handles Watch_Entity and Unwatch_Entity.
// When it sees a new editor, which includes after a soft restart, it sends Component_Types and an Entity_Snapshot,
// and then an Entity_Delta at most ten times a second. After a snapshot, the editor sends its watches again.

// Game to editor: every registered component type. Again after a code reload.
Component_Types :: struct {
	types: []Component_Type,
}

Component_Type :: struct {
	id:     u64,
	name:   string,
	size:   u32,
	// The fields that the editor can show. Nested structs are flattened, with dotted names.
	fields: []Field_Info,
}

Field_Kind :: enum u8 {
	Bool,
	I8,
	I16,
	I32,
	I64,
	U8,
	U16,
	U32,
	U64,
	F32,
	F64,
	// An integer of the kind enum_base, with names in enum_values.
	Enum,
	// [3]f32.
	Vector3,
	// quaternion128: x, y, z, w.
	Quaternion,
	// World_Position: three i64 in units of 2^-24 m.
	Position,
	// An entity handle, u64.
	Entity,
}

Field_Info :: struct {
	name:        string,
	// The byte offset in the component.
	offset:      u32,
	kind:        Field_Kind,
	enum_base:   Field_Kind,
	enum_values: []Enum_Value,
	// From the struct tag editor:"read".
	read_only:   bool,
	// From the struct tag editor:"range=min,max".
	has_range:   bool,
	range_min:   f64,
	range_max:   f64,
}

Enum_Value :: struct {
	name:  string,
	value: i64,
}

Entity_Info :: struct {
	entity:     u64,
	// The Parent component's entity, or 0.
	parent:     u64,
	// False when the entity has the Inactive tag.
	active:     bool,
	// The component IDs, sorted.
	components: []u64,
}

// Game to editor: every entity. It replaces the editor's mirror of the world.
Entity_Snapshot :: struct {
	entities: []Entity_Info,
}

// Game to editor: the entities that are new or changed since the last snapshot or delta, and those that are gone.
Entity_Delta :: struct {
	changed:   []Entity_Info,
	destroyed: []u64,
}

// Editor to game: send this entity's values while it lives.
Watch_Entity :: struct {
	entity: u64,
}

Unwatch_Entity :: struct {
	entity: u64,
}

// Game to editor: a watched entity's values, at most twenty times a second, and only when they changed.
Entity_Values :: struct {
	entity:     u64,
	components: []Component_Value,
	behaviours: []Behaviour_Value,
}

// A component's bytes, as they are in memory. The editor reads the fields with the Field_Info offsets.
Component_Value :: struct {
	id:   u64,
	data: []u8,
}

Behaviour_Value :: struct {
	class:   string,
	enabled: bool,
	fields:  []Behaviour_Field,
}

Behaviour_Field_Kind :: enum u8 {
	Nil,
	Number,
	Boolean,
	String,
	Vector,
	Entity,
}

// A behaviour field's value. Only the member for its kind is set.
Behaviour_Field :: struct {
	name:    string,
	kind:    Behaviour_Field_Kind,
	number:  f64,
	boolean: bool,
	text:    string,
	vector:  [3]f32,
	entity:  u64,
}
