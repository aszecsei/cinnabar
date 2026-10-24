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
	Load_Scene,
	Apply_Operations,
	Edit_Problems,
	Editor_Camera,
	Set_Selection,
	Gizmo_State,
	Pick_Request,
	Pick_Result,
	Set_Hidden,
	Set_Mode,
	Step_Frame,
	Editor_Input,
	Host_Stats,
	Game_Stats,
	Game_Commands,
	Run_Game_Command,
	Game_Command_Result,
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
	// The Name component's text, or "".
	name:       string,
	// The scene ID of an entity that a scene made, or 0 for one that the game spawned.
	scene_id:   u64,
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
	// The script asset that the class comes from, as scenes name it, or zero.
	script:  [16]u8,
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

// Edit (see docs/editor.md#document-model).

// Editor to game: the editor's scene document. The game replaces its world with it, and then sends an
// Entity_Snapshot and the Edit_Problems of the load. The editor sends it when the link connects and after a soft
// restart. Values are tagged as the scene file writes them, and the game converts them to its fields' kinds.
Load_Scene :: struct {
	entities: []Scene_Entity,
}

Scene_Entity :: struct {
	id:         u64,
	name:       string,
	// The parent's scene ID, or 0.
	parent:     u64,
	active:     bool,
	components: []Scene_Component,
	behaviours: []Scene_Behaviour,
}

Scene_Component :: struct {
	id:     u64,
	name:   string,
	fields: []Scene_Field,
}

Scene_Behaviour :: struct {
	// The script's GUID.
	script: [16]u8,
	fields: []Scene_Field,
}

Scene_Field :: struct {
	name:  string,
	value: Scene_Value,
}

Scene_Value_Kind :: enum u8 {
	Bool,
	Number,
	String,
	Name,
	Entity,
}

// A field's value, as asset_format.Scene_Value describes it. Only the members for its kind are set.
Scene_Value :: struct {
	kind:    Scene_Value_Kind,
	// Number: how many numbers, 1 to 4.
	count:   u8,
	// Number: bit i is set when number i is an integer, which ints holds exactly.
	integer: u8,
	// Bool: 1 or 0 in ints[0].
	ints:    [4]i64,
	floats:  [4]f64,
	text:    string,
	// Entity: a scene ID, or 0 for none.
	entity:  u64,
}

Operation_Kind :: enum u8 {
	// created holds the entity, with its components and behaviours.
	Create_Entity,
	// The entity and its descendants. The editor sends their operations too, so each can be undone.
	Destroy_Entity,
	// name.
	Rename,
	// parent: a scene ID, or 0 for none.
	Set_Parent,
	// active.
	Set_Active,
	// components holds the component, with its values. It replaces one that the entity has.
	Add_Component,
	// component.
	Remove_Component,
	// component, and the value in fields.
	Set_Field,
	// component, and the field's name in fields. The field becomes zero, as in a scene that does not set it.
	Reset_Field,
	// script, and the values in fields.
	Add_Behaviour,
	// script.
	Remove_Behaviour,
	// script, and the value in fields.
	Set_Behaviour_Field,
	// script, and the field's name in fields. The field gets its class's default.
	Reset_Behaviour_Field,
}

// An edit of the scene, by the entity's scene ID. Only the members for its kind are set.
Operation :: struct {
	kind:       Operation_Kind,
	entity:     u64,
	created:    []Scene_Entity,
	name:       string,
	parent:     u64,
	active:     bool,
	component:  u64,
	components: []Scene_Component,
	script:     [16]u8,
	fields:     []Scene_Field,
}

// Editor to game: edits, in order. The editor has already applied them to its document, and does not wait for an
// answer. The game sends Edit_Problems for the ones that it cannot apply.
Apply_Operations :: struct {
	operations: []Operation,
}

Edit_Problem :: struct {
	// The scene ID of the entity.
	entity:  u64,
	message: string,
}

// Game to editor: what the game could not apply of a Load_Scene, with snapshot set, or of an Apply_Operations. A
// snapshot's problems replace the ones before it. The editor keeps the document as it is, and shows the problems on
// their entities.
Edit_Problems :: struct {
	snapshot: bool,
	problems: []Edit_Problem,
}

// Viewport tools (see docs/editor.md#viewport). The editor owns its camera, its selection and its gizmo, and the game
// draws them: the frame from the camera, an outline around the selected entities, and the gizmo. The game also
// renders an entity ID buffer, which answers picks.

// Editor to game: the camera that the game draws from while an editor is linked. The editor sends it when it changes,
// and when the link connects.
Editor_Camera :: struct {
	// A World_Position: units of 2^-24 m.
	position:     [3]i64,
	// Camera to world: x, y, z, w. The camera looks down its +z, with +y up and +x right.
	rotation:     [4]f32,
	// Vertical, in radians.
	vertical_fov: f32,
	// The near plane's distance in meters. The far plane is at infinity.
	near:         f32,
}

// Editor to game: the selected entities, which the game outlines with their descendants. The editor sends it when the
// selection changes, and after each Entity_Snapshot.
Set_Selection :: struct {
	entities: []u64,
}

Gizmo_Kind :: enum u8 {
	None,
	Translate,
	Rotate,
	Scale,
}

// A part of a gizmo. View is the handle in the middle for Translate and Scale, which moves in the view's plane or
// scales evenly, and the outer ring for Rotate, which turns about the view's axis.
Gizmo_Part :: enum u8 {
	None,
	X,
	Y,
	Z,
	XY,
	YZ,
	ZX,
	View,
}

// Editor to game: the gizmo to draw. The editor does the hit test and the drag math, so the game only draws it.
Gizmo_State :: struct {
	kind:     Gizmo_Kind,
	// A World_Position.
	position: [3]i64,
	// The axes: the entity's rotation in local space, or none in world space. x, y, z, w.
	rotation: [4]f32,
	// An axis's length in meters, which the editor sets so the gizmo keeps its size on screen.
	size:     f32,
	// The part under the mouse, or the part that a drag holds.
	hot:      Gizmo_Part,
	dragging: bool,
}

// Editor to game: which entities are drawn in a rectangle of the frame, in pixels of the current frame target from its
// top left. A click is a rectangle of one pixel. The game answers each with a Pick_Result, in order.
Pick_Request :: struct {
	id:     u32,
	x:      i32,
	y:      i32,
	width:  i32,
	height: i32,
}

Pick_Hit :: struct {
	entity:   u64,
	// 0 for an entity that the game spawned.
	scene_id: u64,
}

// Game to editor: the entities that a Pick_Request found, sorted by entity. For one pixel, depth is the view-space
// distance of what is drawn there in meters, or 0 where nothing is.
Pick_Result :: struct {
	id:    u32,
	hits:  []Pick_Hit,
	depth: f32,
}

// Editor to game: the entities that the editor hides, which the game does not draw, with their descendants. Hiding is
// the editor's own state: it changes neither the game's Disabled nor the scene. The editor sends it when it changes,
// and after each Entity_Snapshot.
Set_Hidden :: struct {
	entities: []u64,
}

// Modes (see docs/editor.md#modes).

Editor_Mode :: enum u8 {
	// The world does not run: no Fixed or Update systems and no scripts. Transforms still propagate, so edits show.
	Edit,
	// The full frame.
	Play,
	// Nothing runs, except one frame for each Step_Frame.
	Paused,
}

// Editor to game: the mode. A game that an editor has just linked to is in Edit. The editor stops play by setting
// Edit and sending its scene again, so nothing of play mode stays.
Set_Mode :: struct {
	mode:        Editor_Mode,
	// In Play and Paused, the game draws from the editor's camera instead of its own.
	free_camera: bool,
}

// Editor to game: while paused, run one frame of one fixed tick.
Step_Frame :: struct {}

// A key or a mouse button, as core.Key has them.
Input_Key :: enum u8 {
	None,
	A, B, C, D, E, F, G, H, I, J, K, L, M, N, O, P, Q, R, S, T, U, V, W, X, Y, Z,
	Num_0, Num_1, Num_2, Num_3, Num_4, Num_5, Num_6, Num_7, Num_8, Num_9,
	Space, Enter, Escape, Tab, Backspace, Delete, Insert, Home, End, Page_Up, Page_Down,
	Left, Right, Up, Down,
	Left_Shift, Right_Shift, Left_Control, Right_Control, Left_Alt, Right_Alt,
	F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
	Mouse_Left, Mouse_Right, Mouse_Middle, Mouse_4, Mouse_5,
}

// As core.Input_Event_Kind.
Input_Event_Kind :: enum u8 {
	Key_Down,
	Key_Up,
	Mouse_Move,
	Scroll,
	Release_All,
}

Input_Event :: struct {
	kind:     Input_Event_Kind,
	key:      Input_Key,
	// Mouse_Move: in pixels from the frame's top-left corner.
	position: [2]f32,
	// Scroll: wheel notches, positive away from the user.
	scroll:   f32,
}

// Editor to host: keyboard and mouse input while the viewport has focus in play mode. The host gives it to the game as
// core.Input from the next frame.
Editor_Input :: struct {
	events: []Input_Event,
}

// Stats (see docs/editor.md#resource-monitor). The host and the game each send theirs four times a second while an
// editor is linked.

// Host to editor: the frames and the memory of the last interval.
Host_Stats :: struct {
	// The length of the interval, in seconds, and the frames in it.
	interval:            f32,
	frames:              u32,
	// The time from one frame's start to the next's, and the part of it that the game's update and the frame's end
	// took, in milliseconds.
	frame_ms_average:    f32,
	frame_ms_max:        f32,
	work_ms_average:     f32,
	work_ms_max:         f32,
	// The permanent arena's bytes in use, and the most that a frame's arena used.
	permanent_bytes:     u64,
	frame_bytes_max:     u64,
	// The most that a frame's upload ring used.
	upload_bytes_max:    u64,
	// The GPU resources that live now.
	buffers:             u32,
	textures:            u32,
	samplers:            u32,
	pipelines:           u32,
	accels:              u32,
	// The adapter's local memory that the process uses, and the budget that the OS gives it, or 0 when unknown.
	video_memory_used:   u64,
	video_memory_budget: u64,
}

Script_Module_Memory :: struct {
	// The module's asset path, or its GUID.
	name:  string,
	bytes: u64,
}

// Game to editor: the world and the scripts.
Game_Stats :: struct {
	entities:     u32,
	archetypes:   u32,
	behaviours:   u32,
	// Every byte that the script VM holds, and the part that each module's code allocated. The engine's own part is
	// the rest.
	script_bytes: u64,
	modules:      []Script_Module_Memory,
}

// Game commands (see docs/editor.md#commands).

Game_Command_Info :: struct {
	// Unique in the game, such as "mygame.add_triangle". The editor's command ID is "game." and this.
	id:          string,
	label:       string,
	description: string,
	// The ribbon tab and group to show it in, by label. A tab that the editor lacks is added.
	tab:         string,
	group:       string,
	// The name of an icon of the editor's set, or "".
	icon:        string,
	// Whether the command edits the scene, so the editor offers it only in Edit.
	edits:       bool,
}

// Game to editor: the game's commands, with the types: when a new editor links and after a code reload.
Game_Commands :: struct {
	commands: []Game_Command_Info,
}

// Editor to game: run a command, with the selection that the editor last sent.
Run_Game_Command :: struct {
	id: string,
}

// Game to editor: what a command did. The game does not apply the operations itself: the editor applies them to its
// document as one undo entry, which sends them back as for any edit. message goes to the console.
Game_Command_Result :: struct {
	id:         string,
	operations: []Operation,
	message:    string,
}
