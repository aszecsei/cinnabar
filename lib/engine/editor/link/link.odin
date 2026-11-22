// Package link is the editor link's protocol: its messages, which go over the transport in lib/engine/wire (see
// docs/editor/link.md#editor-link). The host and the game both use it, so it imports nothing from core or engine.
package link

import "core:mem"

import "cinnabar:engine/wire"

Header :: wire.Header
HEADER_SIZE :: wire.HEADER_SIZE
MAX_PAYLOAD :: wire.MAX_PAYLOAD

read_header :: wire.read_header

// write_message appends a message, with its header, to buf.
write_message :: proc(buf: ^[dynamic]byte, message: Message, request: u32 = 0) {
	wire.write_message(buf, message, request)
}

// kind_of is the kind of a message type: its index in Message, from 1.
kind_of :: proc($T: typeid) -> u16 {
	return wire.kind_of(Message, T)
}

// decode_message decodes a payload of the given kind. Strings and slices are allocated with allocator. A payload
// that does not decode to exactly one message of the kind is refused.
decode_message :: proc(
	kind: u16,
	payload: []byte,
	allocator: mem.Allocator,
) -> (
	message: Message,
	ok: bool,
) {
	return wire.decode_message(Message, kind, payload, allocator)
}

// schema describes every message as JSON, for the editor's C# source generator. Its version is the protocol version.
schema :: proc(allocator := context.allocator) -> string {
	return wire.schema(Message, allocator)
}

// protocol_version is a hash of the schema, so any change to a message changes it.
protocol_version :: proc() -> u64 {
	return wire.protocol_version(Message)
}

// A message's kind is its index in this union, from 1. Adding, removing or reordering messages changes the schema,
// and with it the protocol version, so an editor and a host that disagree refuse each other at the handshake.
Message :: union {
	Hello,
	Welcome,
	Refused,
	Log,
	Game_Reloaded,
	Game_Size,
	Component_Types,
	Entity_Snapshot,
	Entity_Delta,
	Watch_Entity,
	Unwatch_Entity,
	Entity_Values,
	Load_Scene,
	Add_Scene,
	Remove_Scene,
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
	Open_Preview,
	Preview_Settings,
	Close_Preview,
	Preview_Target,
	Preview_Acknowledged,
	Set_Viewport_Settings,
	Profile_Summary,
	Profile_Capture_Request,
	Profile_Capture,
	Profile_Recording,
	Capture_Request,
	Capture_Result,
	Bake_Thumbnail,
	Thumbnail_Failed,
	Live_Mesh,
	Live_Mesh_Vertices,
	Release_Live_Mesh,
	Mesh_Overlay,
	Sky_Sun_Request,
	Sky_Sun,
	Animator_View,
	Agent_View,
	Agent_Actions,
	Set_Preview_Parameter,
	Restart_Preview,
	Ui_Preview_Settings,
	Ui_Preview_Layout,
	Capture_Reflection_Probes,
	Reflection_Probe_View,
	Box_Handles,
	Open_Viewport,
	Close_Viewport,
	Viewport_Target,
	Viewport_Acknowledged,
	Capture_Source,
	Nav_Probe,
	Behaviour_Operations,
	Behaviour_Operations_Answer,
	Live_Texture,
	Live_Texture_Region,
	Release_Live_Texture,
	Landscape_Overlay,
	Live_Instances,
	Release_Live_Instances,
	World_View,
	Streamed_Scenes,
	Begin_Override,
	Override_Frame,
	Release_Override,
	Override_Ended,
	Overridden_Entities,
	Cutscene_Preview_Open,
	Cutscene_Preview_Time,
	Cutscene_Preview_Play,
	Cutscene_Preview_Close,
	Cutscene_Preview_Opened,
	Cutscene_Preview_Ended,
	Cutscene_Preview_Tick,
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

// Editor to host: the size of the game's picture in physical pixels, which is the Game view's (see
// docs/editor/viewport.md#views). The game sees it as its window's size from a following frame, so its UI and its
// camera's aspect follow the Game view. The frames themselves reach the editor through each view's own target (see
// Open_Viewport), not through the host's frame target.
Game_Size :: struct {
	width:  i32,
	height: i32,
}

// The world (see docs/editor/link.md#world). The game side sends these, and handles Watch_Entity and Unwatch_Entity.
// When it sees a new editor, which includes after a soft restart, it sends Component_Types and an Entity_Snapshot,
// and then an Entity_Delta at most ten times a second. After a snapshot, the editor sends its watches again.

// Game to editor: every registered component type. Again after a code reload.
Component_Types :: struct {
	types: []Component_Type,
}

Component_Type :: struct {
	id:       u64,
	name:     string,
	// Where the Add Component menu offers the type: its folders with / between them, such as "Physics/Joints", or "-"
	// for a type that the engine adds and removes itself, which the menu leaves out (see ecs.Component_Info).
	category: string,
	size:     u32,
	// The fields that the editor can show. Nested structs are flattened, with dotted names.
	fields:   []Field_Info,
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
	// An asset's GUID, 16 bytes.
	Asset,
	// [2]f32.
	Vector2,
}

Field_Info :: struct {
	name:            string,
	// The byte offset in the component.
	offset:          u32,
	kind:            Field_Kind,
	enum_base:       Field_Kind,
	enum_values:     []Enum_Value,
	// From the struct tag editor:"read".
	read_only:       bool,
	// From the struct tag editor:"range=min,max".
	has_range:       bool,
	range_min:       f64,
	range_max:       f64,
	// From the struct tag editor:"color": a Vector3 that holds a linear color.
	color:           bool,
	// A setting that a volume can override: the byte at override_offset is 1 when the component overrides it. A scene
	// that sets the field overrides it.
	has_override:    bool,
	override_offset: u32,
	// For an Asset field, the kind of asset that it takes, from the struct tag asset:"<kind>", in lowercase as the
	// cook link's Asset_Kind names it, such as "mesh". "" takes any asset.
	asset_kind:      string,
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
	// The number of the scene that made it, as Load_Scene gives it, or 0 for the game's own scene and for an entity
	// that the game spawned.
	scene:      u32,
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
	// The fields that overrides hold (see Override_Frame). components has the document's values of them, not the
	// overrides'.
	held:       []Held_Field,
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
	// An asset reference, from Field.asset, which is the zero GUID while the field holds none.
	Asset,
}

// A behaviour field's value. Only the member for its kind is set.
Behaviour_Field :: struct {
	name:       string,
	kind:       Behaviour_Field_Kind,
	number:     f64,
	boolean:    bool,
	text:       string,
	vector:     [3]f32,
	entity:     u64,
	asset:      [16]u8,
	// For an Asset field, the kind of asset that it takes, as the cook link names kinds, or "" for any.
	asset_kind: string,
}

// Edit (see docs/editor/document-and-scenes.md#document-model).

// Editor to game: the editor's open scene documents (see docs/editor/document-and-scenes.md#several-scenes). The game
// replaces its world with them, and then sends an Entity_Snapshot and the Edit_Problems of the load. The editor sends
// it when the link connects, after a soft restart, and when Open Scene replaces the open scenes. A scene that opens
// beside them, or closes, is an Add_Scene or a Remove_Scene. Values are tagged as the scene
// file writes them, and the game converts them to its fields' kinds.
Load_Scene :: struct {
	scenes: []Loaded_Scene,
	// The editor's number for this load, which a Behaviour_Operations repeats, so the editor knows the scenes that a
	// behaviour edited.
	ticket: u64,
}

// Editor to game: a scene that the editor opened beside the open ones (see
// docs/editor/document-and-scenes.md#several-scenes). The game adds it to its world with its number, and the other
// scenes' entities stay as they are, with their handles. It then sends an Entity_Snapshot, and Edit_Problems that are
// not a snapshot when the scene has problems.
Add_Scene :: struct {
	scene:  Loaded_Scene,
	// The editor's number for the world with this scene, as a Load_Scene's ticket.
	ticket: u64,
}

// Editor to game: the number of a scene that the editor closed. The game despawns that scene's entities, and what they
// own, and the other scenes' entities stay as they are. It then sends an Entity_Snapshot.
Remove_Scene :: struct {
	scene:  u32,
	// The editor's number for the world without this scene, as a Load_Scene's ticket.
	ticket: u64,
}

// One scene of a Load_Scene or an Add_Scene. Its scene IDs are its own: another scene can have the same, and a parent names an entity
// of the same scene. A reference names one of the same scene, or by its Scene_Value.scene one of another.
Loaded_Scene :: struct {
	// The editor's number for the scene, nonzero and unique among the open scenes, which its entities' Entity_Info and
	// the operations on them carry.
	scene:    u32,
	entities: []Scene_Entity,
	// The scene's GUID, so the game finds what its cooked blob lists, such as its navmeshes, or zero for a scene that
	// has none yet. A part has its sublevel's sub-asset GUID, or zero before the scene's first cook.
	guid:     [16]u8,
	// For a part of a scene's sublevel, the number of the scene's base, which comes before it; 0 for a base (see
	// docs/editor/document-and-scenes.md#parts).
	base:     u32,
	// For a part, its sublevel's name; empty for a base.
	sublevel: string,
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
	Asset,
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
	// Entity: the GUID of the scene that the entity is in, or zero for the field's own scene.
	scene:   [16]u8,
	// Asset: a GUID, or zero for none.
	asset:   [16]u8,
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
	// An instance of prefab, whose root has the scene ID entity, under parent (or none), with the pose component in
	// components, and active. Only an edit-mode behaviour's edits have it: the editor makes the instance, and sends its
	// entities (see Behaviour_Operations).
	Create_Instance,
	// The entity and its descendants move from the part scene to the part target of the same scene's base, whose
	// sublevel is sublevel (empty for the base) and whose GUID is guid. They keep their handles. A part that gets its
	// first entity loads, and a part that has none left unloads (see docs/editor/document-and-scenes.md#parts).
	Set_Sublevel,
}

// An edit of a scene, by the scene's number and the entity's scene ID. Only the members for its kind are set. A
// parent names an entity of the same scene, and a reference one of it or by its scene's GUID of another. From the game, a scene of 0 is the editor's active scene,
// as for an entity that a command or a behaviour creates at the root.
Operation :: struct {
	kind:       Operation_Kind,
	scene:      u32,
	entity:     u64,
	created:    []Scene_Entity,
	name:       string,
	parent:     u64,
	active:     bool,
	component:  u64,
	components: []Scene_Component,
	script:     [16]u8,
	fields:     []Scene_Field,
	prefab:     [16]u8,
	target:     u32,
	sublevel:   string,
	guid:       [16]u8,
}

// Editor to game: edits, in order. The editor has already applied them to its document, and does not wait for an
// answer. The game sends Edit_Problems for the ones that it cannot apply.
Apply_Operations :: struct {
	operations: []Operation,
}

Edit_Problem :: struct {
	// The number of the entity's scene, and its scene ID.
	scene:   u32,
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

// Viewport tools (see docs/editor/viewport.md#viewport). The editor owns its cameras, its selection and its gizmo, and the game
// draws them: each viewport's frame from its camera, an outline around the selected entities, and the gizmo. The game
// also renders an entity ID buffer for each viewport, which answers its picks.
//
// A viewport is a number below MAX_VIEWPORTS (see docs/editor/viewport.md#views). Each is open from its Open_Viewport
// to its Close_Viewport, which the editor sends as the viewport shows and hides, and while it is open the game draws it
// into a shared target of its own. Its kind says what it shows.
MAX_VIEWPORTS :: 5

Viewport_Kind :: enum u8 {
	// A scene view: the world from the viewport's Editor_Camera, with the editor's tools, in every mode.
	Scene,
	// The Game view: the world from the game's own camera, with the game's UI and without the editor's tools, as a
	// player sees it. In Play it has the game's input.
	Game,
}

// Editor to game: the camera that the game draws a viewport from while an editor is linked. The editor sends it when
// it changes, and when the link connects.
Editor_Camera :: struct {
	viewport:            u32,
	// A World_Position: units of 2^-24 m.
	position:            [3]i64,
	// Camera to world: x, y, z, w. The camera looks down its +z, with +y up and +x right.
	rotation:            [4]f32,
	// Vertical, in radians.
	vertical_fov:        f32,
	// The near plane's distance in meters. A perspective camera's far plane is at infinity.
	near:                f32,
	// An orthographic camera shows orthographic_height meters from bottom to top, between near and far (see
	// docs/editor/viewport.md#projection). A perspective camera does not read them.
	projection:          Camera_Projection,
	orthographic_height: f32,
	far:                 f32,
}

// Camera_Projection is how an editor's camera projects: with perspective, or without.
Camera_Projection :: enum u8 {
	Perspective,
	Orthographic,
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

// Editor to game: the gizmo to draw in a viewport. The editor does the hit test and the drag math, so the game only
// draws it. Each viewport has its own, because the gizmo's size follows the viewport's camera.
Gizmo_State :: struct {
	viewport: u32,
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

// Editor to game: which entities are drawn in a rectangle of a viewport's frame, in pixels of its current target from
// its top left. A click is a rectangle of one pixel. The game answers each with a Pick_Result, in order. A pick of a
// viewport that is not open answers with no hits.
Pick_Request :: struct {
	id:       u32,
	viewport: u32,
	x:        i32,
	y:        i32,
	width:    i32,
	height:   i32,
}

Pick_Hit :: struct {
	entity:   u64,
	// 0 for an entity that the game spawned.
	scene_id: u64,
	// The number of its scene, as Entity_Info has it.
	scene:    u32,
}

// Game to editor: the entities that a Pick_Request found, sorted by entity. For one pixel, depth is the view-space
// distance of what is drawn there in meters, or 0 where nothing is, and submesh is the index of the mesh's submesh
// drawn there, or -1 where no entity is drawn and for a larger rectangle.
Pick_Result :: struct {
	id:      u32,
	hits:    []Pick_Hit,
	depth:   f32,
	submesh: i32,
}

// Editor to game: the entities that the editor hides, which the game does not draw, with their descendants. Hiding is
// the editor's own state: it changes neither the game's Disabled nor the scene. The editor sends it when it changes,
// and after each Entity_Snapshot.
Set_Hidden :: struct {
	entities: []u64,
}

// What the viewport shows in place of the lit scene (see docs/rendering/post-processing.md#debug-views). Matches render.Debug_View.
Debug_View :: enum u8 {
	Lit,
	Lighting_Only,
	Direct_Light,
	Indirect_Light,
	Fog,
	Albedo,
	Light_Complexity,
	Shadow_Cascades,
	Normals,
	Depth,
	Velocity,
	Ambient_Occlusion,
	Gi_Diffuse,
	Gi_Specular,
	Shadow_Mask,
	Entity_Ids,
	Luminance,
	Transparent_Overdraw,
	Meshlets,
	Lod_Depth,
	Emission,
	Gi_Probes,
	Quad_Overdraw,
	Shadow_Virtual,
	Roughness,
	Reflection_Probes,
	Reflections,
	Clouds,
	Shadow_Virtual_Invalidated,
	Circle_Of_Confusion,
}

// Which entities the viewport draws the shapes of: lights' ranges and cones, volumes and cameras.
Helper_Mode :: enum u8 {
	None,
	Selected,
	All,
}

// The viewport's quality preset, in place of the game's (see docs/editor/viewport.md#quality). Game keeps the game's;
// the others match render.Quality_Preset.
Viewport_Preset :: enum u8 {
	Game,
	Low,
	Medium,
	High,
	Ultra,
}

// The viewport's anti-aliasing, in place of the quality's. Game keeps the quality's; the others match
// render.Aa_Technique.
Viewport_Aa :: enum u8 {
	Game,
	Off,
	Taa,
	Fxaa,
	Smaa,
	Fsr,
}

// The viewport's global illumination, in place of the quality's. Game keeps the quality's; the others match
// render.Gi_Technique. Split_Cascades needs Ray_Query; without it, the viewport draws the screen cascades.
Viewport_Gi :: enum u8 {
	Game,
	Off,
	Screen_Cascades,
	Split_Cascades,
	Voxel_Cones,
}

// The viewport's reflections, in place of the quality's. Game keeps the quality's; the others match
// render.Reflection_Technique. Ray_Traced needs Ray_Query; without it, the viewport draws the screen-space reflections.
Viewport_Reflections :: enum u8 {
	Game,
	Off,
	Probes,
	Screen,
	Ray_Traced,
}

// A level of the viewport's quality, in place of the quality's. Game keeps the quality's, or the viewport's preset's;
// the others match render.Quality_Level.
Viewport_Level :: enum u8 {
	Game,
	Low,
	Medium,
	High,
	Ultra,
}

// How a viewport draws while an editor is linked (see docs/editor/viewport.md#viewport), which a Set_Viewport_Settings
// carries. The features are the ones that the viewport turns off.
Viewport_Settings :: struct {
	debug_view:           Debug_View,
	no_temporal_aa:       bool,
	no_bloom:             bool,
	no_tone_mapping:      bool,
	no_fog:               bool,
	no_ambient_occlusion: bool,
	no_gi:                bool,
	no_shadows:           bool,
	no_post_effects:      bool,
	no_occlusion_culling: bool,
	no_meshlet_hierarchy: bool,
	no_clouds:            bool,
	// Count the forward pass's quads for Game_Stats (see docs/rendering/lighting-and-shadows.md#quad-overdraw).
	shading_stats:        bool,
	// Stops added to the exposure.
	exposure_offset:      f32,
	// Icons for the lights, volumes and cameras, which pick them.
	show_icons:           bool,
	helpers:              Helper_Mode,
	// The quality that the viewport draws at, from the game's: a preset, the anti-aliasing, the global illumination's
	// technique, the render scale, 0 keeping the game's, and the reflections' technique and level.
	quality_preset:       Viewport_Preset,
	anti_aliasing:        Viewport_Aa,
	global_illumination:  Viewport_Gi,
	render_scale:         f32,
	reflections:          Viewport_Reflections,
	reflections_level:    Viewport_Level,
}

// Editor to game: how a viewport draws. The editor sends it when it changes, and when the link connects. Each viewport
// has its own view, features, exposure, icons and quality. The shapes are debug lines, which every viewport with a debug
// layer draws, so they are those of the scene view with the lowest number (see docs/editor/viewport.md#views).
Set_Viewport_Settings :: struct {
	viewport: u32,
	settings: Viewport_Settings,
}

// Editor to game: a viewport is open, at a size in physical pixels, or has a new size or kind. The game draws it into a
// shared target of its own, and tells the editor of it with a Viewport_Target. A side is at most
// gpu.MAX_VIEWPORT_SIZE. A scene view draws once it has an Editor_Camera.
Open_Viewport :: struct {
	viewport: u32,
	kind:     Viewport_Kind,
	width:    i32,
	height:   i32,
}

// Editor to game: a viewport is closed, as when its panel hides, and its shared target can go. The game keeps what it
// has of the viewport's camera between frames only while the viewport is open.
Close_Viewport :: struct {
	viewport: u32,
}

// Game to editor: the shared target that a viewport renders into (see docs/gpu/presentation.md#presentation). The
// objects are named <prefix>.texture0..2 and <prefix>.fence. Each size makes a new generation, whose frames count from
// 1 again.
Viewport_Target :: struct {
	viewport:   u32,
	prefix:     string,
	generation: u32,
	width:      i32,
	height:     i32,
}

// Editor to host: the editor has finished copying this frame of this generation of a viewport's target. The host
// renders frame k of the viewport only if k <= frame + 2, so it never draws into a texture that the editor still reads.
Viewport_Acknowledged :: struct {
	viewport:   u32,
	generation: u32,
	frame:      u64,
}

// Modes (see docs/editor/document-and-scenes.md#modes).

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
	mode: Editor_Mode,
}

// Editor to game: while paused, run one frame of one fixed tick.
Step_Frame :: struct {}

// Editor to game: ask where the sun of the frame's texture sky is (see docs/rendering/sky.md#texture), which the
// editor aims the scene's sun at. The game answers with a Sky_Sun.
Sky_Sun_Request :: struct {}

// Sky_Sun_State matches render.Sky_Sun_State: whether the sky has a sun, or why not.
Sky_Sun_State :: enum u8 {
	Found,
	No_Texture_Sky,
	Not_Ready,
	No_Sun,
}

// Editor to game: capture these reflection probes now, or every probe with none, each in one frame whatever the
// level's budget, one a frame (see docs/rendering/lighting-and-shadows.md#reflection-probes). A probe that holds no
// slot is not captured.
Capture_Reflection_Probes :: struct {
	entities: []u64,
}

// What the renderer did with a probe: None when the entity has no Reflection_Probe or the reflections are off,
// No_Slot when nearer or higher-priority probes hold every slot, Waiting when it holds a slot with no capture yet, and
// Captured.
Reflection_Probe_Status :: enum u8 {
	None,
	No_Slot,
	Waiting,
	Captured,
}

// Game to editor: a watched entity's reflection probe's state, which the Properties panel shows (see
// docs/editor/shell-and-panels.md#properties). It goes out once after a watch, None included, then when it changes, but
// for age: capturing is whether a capture of it is in flight or asked for, complete is false for a provisional capture,
// and age is the seconds since its last capture finished, when it was sent.
Reflection_Probe_View :: struct {
	entity:    u64,
	status:    Reflection_Probe_Status,
	capturing: bool,
	complete:  bool,
	age:       f32,
}

// A box handle's box: a reflection probe's influence box, its fade inside it, or its projection box.
Box_Handle_Kind :: enum u8 {
	Influence,
	Blend,
	Projection,
}

// A handle on a face of a box, which a drag resizes: its World_Position, its box, and whether the mouse is over it or
// a drag holds it.
Box_Handle :: struct {
	position: [3]i64,
	kind:     Box_Handle_Kind,
	hot:      bool,
}

// Editor to game: the box handles to draw in a viewport, as cubes of size meters, none to draw none (see
// docs/editor/viewport.md#reflection-probes). The editor does the hit test and the drag math, as with the gizmo.
Box_Handles :: struct {
	viewport: u32,
	size:     f32,
	handles:  []Box_Handle,
}

// Game to editor: the direction toward the texture sky's sun in the world, where its brightest texels are, when the
// state is Found.
Sky_Sun :: struct {
	state:     Sky_Sun_State,
	direction: [3]f32,
}

// Animator_Parameter_Kind matches format.Animation_Graph_Parameter_Kind.
Animator_Parameter_Kind :: enum u8 {
	Float,
	Bool,
	Trigger,
}

// Animator_Parameter is a parameter of an Animator's graph and its value: a number, 1 or 0 for a bool, and 1 for a
// trigger that the next tick will see.
Animator_Parameter :: struct {
	name:  string,
	kind:  Animator_Parameter_Kind,
	value: f32,
}

// Game to editor: what a watched entity's Animator plays, which its component's bytes do not say (see
// docs/editor/animation-graph-editor.md#live-view), or with entity 0, what an animation graph's preview plays. A watched
// entity's goes out once after the watch, empty without an Animator, then when it changes. States and transitions are by
// their node IDs in the graph's text, or 0: source is 0 in an interrupted fade too, which has no one state that it fades from. Without
// a graph that is ready, graph is zero and the rest is too, which tells the editor that it has gone.
Animator_View :: struct {
	entity:        u64,
	graph:         [16]u8,
	state:         u32,
	source:        u32,
	transition:    u32,
	fade:          f32,
	fade_duration: f32,
	progress:      f32,
	parameters:    []Animator_Parameter,
}

// Editor to game: sets a parameter of what an animation graph's preview plays, by its name: a number, 1 or 0 for a bool,
// and for a trigger, anything but 0 pulls it and 0 resets it. It changes nothing in the world.
Set_Preview_Parameter :: struct {
	id:    u32,
	name:  string,
	value: f32,
}

// Editor to game: an animation graph's preview starts again in the entry state, with the parameters at their defaults.
Restart_Preview :: struct {
	id: u32,
}

// UI previews (see docs/editor/ui-editor.md#the-games-side). An Open_Preview of a UI document, with unsaved for the text
// that the cook daemon cooked into the preview area, shows it in preview id. The game lays it out on a screen of its own
// and draws it through a view, and tells the editor where each element went.

Ui_Preview_Background :: enum u8 {
	Dark,
	Light,
}

// A value for a {name} in the document's text, which the file does not keep.
Ui_Preview_Binding :: struct {
	name:  string,
	value: string,
}

// Editor to game: how preview id shows its UI document, in place of Preview_Settings. The document is laid out on a
// screen of screen_width by screen_height pixels at a UI scale of scale, as a game of that size would, and a pixel p of
// the screen draws at p * view_scale + (view_x, view_y) in the preview's target, which is width by height pixels within
// gpu.MAX_PREVIEW_SIZE. The element that is the blob's node forced_node, or none with max(u32), shows the states
// forced_states (1 hover, 2 focus, 4 press, 8 disabled) in place of the player's.
Ui_Preview_Settings :: struct {
	id:            u32,
	screen_width:  i32,
	screen_height: i32,
	scale:         f32,
	view_scale:    f32,
	view_x:        f32,
	view_y:        f32,
	width:         i32,
	height:        i32,
	background:    Ui_Preview_Background,
	forced_node:   u32,
	forced_states: u8,
	bindings:      []Ui_Preview_Binding,
}

// Where an element of a UI preview went, in the screen's pixels as x0, y0, x1, y1: its rectangle, the rectangle inside
// its padding, and what its drawing is cut to. source is its node in the blob, in the order of the document's text.
Ui_Layout_Node :: struct {
	source:  u32,
	shown:   bool,
	rect:    [4]f32,
	content: [4]f32,
	clip:    [4]f32,
}

// Game to editor: where preview id's elements went when it last drew, when it changed. key is the blob's, which for a
// text that the cook daemon cooked is the text's FNV-1a hash, and scale the UI scale that it was laid out at.
Ui_Preview_Layout :: struct {
	id:     u32,
	key:    u64,
	scale:  f32,
	width:  i32,
	height: i32,
	nodes:  []Ui_Layout_Node,
}

// A key or a mouse button, as core.Key has them.
Input_Key :: enum u8 {
	None,
	A,
	B,
	C,
	D,
	E,
	F,
	G,
	H,
	I,
	J,
	K,
	L,
	M,
	N,
	O,
	P,
	Q,
	R,
	S,
	T,
	U,
	V,
	W,
	X,
	Y,
	Z,
	Num_0,
	Num_1,
	Num_2,
	Num_3,
	Num_4,
	Num_5,
	Num_6,
	Num_7,
	Num_8,
	Num_9,
	Space,
	Enter,
	Escape,
	Tab,
	Backspace,
	Delete,
	Insert,
	Home,
	End,
	Page_Up,
	Page_Down,
	Left,
	Right,
	Up,
	Down,
	Left_Shift,
	Right_Shift,
	Left_Control,
	Right_Control,
	Left_Alt,
	Right_Alt,
	F1,
	F2,
	F3,
	F4,
	F5,
	F6,
	F7,
	F8,
	F9,
	F10,
	F11,
	F12,
	Mouse_Left,
	Mouse_Right,
	Mouse_Middle,
	Mouse_4,
	Mouse_5,
}

// As core.Input_Event_Kind.
Input_Event_Kind :: enum u8 {
	Key_Down,
	Key_Up,
	Mouse_Move,
	Scroll,
	Release_All,
	Gamepad,
	Text,
	Composition,
}

Input_Event :: struct {
	kind:      Input_Event_Kind,
	key:       Input_Key,
	// Mouse_Move: in pixels from the frame's top-left corner.
	position:  [2]f32,
	// Scroll: wheel notches, positive away from the user.
	scroll:    f32,
	// Gamepad: what the pad in this slot reports, before the dead zones: core.Gamepad_Buttons, which are the bits of
	// XInput's wButtons, and the axes in the order of core.Gamepad_Axis.
	pad:       u8,
	connected: bool,
	buttons:   u16,
	axes:      [6]f32,
	// Text: the characters typed. Composition: what the IME composes, and empty when it stops.
	text:      string,
	// Composition: the bytes of text before the cursor.
	cursor:    i32,
}

// Editor to host: keyboard, mouse, gamepad and text input while the viewport has focus in play mode. The host gives it
// to the game as core.Input from the next frame.
Editor_Input :: struct {
	events: []Input_Event,
}

// Stats (see docs/editor/shell-and-panels.md#resource-monitor). The host and the game each send theirs four times a second while an
// editor is linked.

// Host to editor: the frames and the memory of the last interval.
Host_Stats :: struct {
	// The length of the interval, in seconds, and the frames in it.
	interval:                        f32,
	frames:                          u32,
	// The time from one frame's start to the next's, and the part of it that the game's update and the frame's end
	// took, in milliseconds.
	frame_ms_average:                f32,
	frame_ms_max:                    f32,
	work_ms_average:                 f32,
	work_ms_max:                     f32,
	// The permanent arena's bytes in use, and the most that a frame's arena used.
	permanent_bytes:                 u64,
	frame_bytes_max:                 u64,
	// The most that a frame's upload ring used.
	upload_bytes_max:                u64,
	// The GPU resources that live now.
	buffers:                         u32,
	textures:                        u32,
	samplers:                        u32,
	pipelines:                       u32,
	accels:                          u32,
	// The adapter's local memory that the process uses, and the budget that the OS gives it, or 0 when unknown.
	video_memory_used:               u64,
	video_memory_budget:             u64,
	// The bottom-level acceleration structures' memory, and what it would be without their compaction.
	bottom_accel_memory:             u64,
	bottom_accel_memory_uncompacted: u64,
	// The memory of the GPU backend's resource heaps, and the part of it that the live resources take.
	heap_memory:                     u64,
	resource_memory:                 u64,
}

// The profiler (see docs/editor/link.md#profile). The host handles every profile message: the zones are its own.

// Profile_Category is profile.Category.
Profile_Category :: enum u8 {
	Frame,
	Wait,
	Job,
	System,
	Script,
	Render,
	Gpu,
	Asset,
	Editor,
	User,
}

Profile_Cost_Kind :: enum u8 {
	// An ECS system's CPU time, summed over the threads.
	System,
	// A behaviour class's CPU time in one callback, without the script callbacks nested in it. detail is the callback.
	Script,
	// A render pass's GPU time on one queue.
	Pass,
}

// Profile_Callback is profile.Callback, a Script cost's detail.
Profile_Callback :: enum u16 {
	None,
	Awake,
	Start,
	Update,
	On_Enable,
	On_Disable,
	On_Destroy,
	On_Reload,
	Event,
	Coroutine,
	Fixed_Update,
}

// Profile_Cost is a cost per frame over a stats interval: per profiled frame for systems and scripts, per frame with
// GPU times for passes.
Profile_Cost :: struct {
	kind:       Profile_Cost_Kind,
	name:       string,
	callback:   Profile_Callback,
	// A Pass's queue: 0 graphics, 1 compute.
	queue:      u8,
	calls:      f32,
	ms_average: f32,
	// The most in one frame.
	ms_max:     f32,
}

// Host to editor, right before each Host_Stats: the profiler's view of the same interval.
Profile_Summary :: struct {
	first_frame:     u64,
	last_frame:      u64,
	frames:          u32,
	gpu_frames:      u32,
	// The frames' time without the main thread's waits for the GPU and the display, which wait is.
	cpu_ms_average:  f32,
	cpu_ms_max:      f32,
	cpu_worst_frame: u64,
	wait_ms_average: f32,
	wait_ms_max:     f32,
	// From each frame's first GPU timestamp to its last.
	gpu_ms_average:  f32,
	gpu_ms_max:      f32,
	gpu_worst_frame: u64,
	// Zones that the threads' rings had no room for.
	dropped:         u32,
	recording:       bool,
	costs:           []Profile_Cost,
}

Profile_Capture_Mode :: enum u8 {
	// The next frame that ends.
	Next,
	// The longest of the last count frames.
	Worst_Recent,
	// The frame numbered frame, from the recent frames or the pinned worst frames.
	Frame,
}

// Editor to host: capture a frame. The host answers with a Profile_Capture with the same id once the frame's GPU
// times are in.
Profile_Capture_Request :: struct {
	id:    u32,
	mode:  Profile_Capture_Mode,
	frame: u64,
	count: u32,
}

Profile_Name :: struct {
	text:     string,
	category: Profile_Category,
}

Profile_Lane_Kind :: enum u8 {
	Thread,
	Gpu_Graphics,
	Gpu_Compute,
}

Profile_Lane :: struct {
	name: string,
	kind: Profile_Lane_Kind,
}

// Profile_Zone is a zone's segment on a thread, or a GPU span on a GPU lane.
Profile_Zone :: struct {
	// Nanoseconds from the frame's start. A neighbouring frame's zone can start before it.
	start:    i64,
	duration: u32,
	// An index into the capture's names.
	name:     u16,
	// The callback of a Script zone, the piece of a split render pass, and 0 otherwise.
	detail:   u16,
	lane:     u8,
	depth:    u8,
	// profile.Zone_Flags: 1 suspended, 2 resumed, 4 job, 8 unbalanced.
	flags:    u8,
	// The fiber's index + 1, which links a zone's segments, or 0.
	fiber:    u8,
}

// Host to editor: a captured frame. available is false, with a reason, when the host no longer has the frame.
Profile_Capture :: struct {
	id:        u32,
	frame:     u64,
	available: bool,
	reason:    string,
	frame_ns:  u64,
	cpu_ns:    u64,
	wait_ns:   u64,
	gpu_ns:    u64,
	// The frame's first and last GPU timestamps, from the frame's start. Both are 0 without GPU times.
	gpu_begin: i64,
	gpu_end:   i64,
	dropped:   u32,
	names:     []Profile_Name,
	lanes:     []Profile_Lane,
	zones:     []Profile_Zone,
}

// Editor to host: start or stop recording zones.
Profile_Recording :: struct {
	recording: bool,
}

Script_Module_Memory :: struct {
	// The module's asset path, or its GUID.
	name:  string,
	bytes: u64,
}

// One push of an input context, for the resource monitor (see docs/core/input.md#contexts).
Input_Context_Stats :: struct {
	name:    string,
	// The pads whose stacks have it, a bit each from pad 1's. The keys read pad 1's stack.
	players: u8,
	// Who pushed it: a behaviour's class, "script", or what native code names itself.
	pusher:  string,
}

// Game to editor: the world and the scripts.
Game_Stats :: struct {
	entities:                   u32,
	archetypes:                 u32,
	behaviours:                 u32,
	// Every byte that the script VM holds, and the part that each module's code allocated. The engine's own part is
	// the rest.
	script_bytes:               u64,
	modules:                    []Script_Module_Memory,
	// What the camera drew a frame or two ago (see docs/rendering/gpu-scene.md#occlusion-culling): its items, as
	// draws, and its instance sets' instances, each drawn early or late, and those that occlusion culling hid.
	early_items:                u32,
	late_items:                 u32,
	hidden_items:               u32,
	early_instances:            u32,
	late_instances:             u32,
	hidden_instances:           u32,
	// Of the items whose meshlets have a hierarchy, their meshlets, and those that the walk of the hierarchy gave the
	// amplification shaders to test (see docs/rendering/gpu-scene.md#mesh-shader-path).
	hierarchy_meshlets:         u32,
	selected_meshlets:          u32,
	// The forward pass's 2x2 quads and their lanes that cover a pixel, with the viewport's shading stats on, a frame or
	// two ago (see docs/rendering/lighting-and-shadows.md#quad-overdraw).
	forward_quads:              u32,
	forward_pixels:             u32,
	// The virtual shadow map's pages a frame or two ago: those that the frame asked for, those that it got, those that the
	// pool had no room for, and how many the pool holds, 0 without it (see
	// docs/rendering/lighting-and-shadows.md#virtual-shadow-maps); of those that it got, those that the pool held and those
	// that it drew, the pages that left the pool for them, and the pages that the pool holds after the frame (see
	// docs/rendering/lighting-and-shadows.md#caching).
	virtual_pages_requested:    u32,
	virtual_pages_allocated:    u32,
	virtual_pages_missed:       u32,
	virtual_pages_capacity:     u32,
	virtual_pages_cached:       u32,
	virtual_pages_drawn:        u32,
	virtual_pages_evicted:      u32,
	virtual_pages_resident:     u32,
	// The virtual shadow map's pages that streaming dropped in the last frame, and those that wait for their turn (see
	// docs/rendering/lighting-and-shadows.md#streaming).
	virtual_pages_streamed:     u32,
	virtual_pages_waiting:      u32,
	// The virtual shadow map's pages that the pool held that the casters that changed dropped a frame or two ago, and
	// the levels that dropped every page in the last frame, since their drops passed the limit (see
	// docs/rendering/lighting-and-shadows.md#caching).
	virtual_pages_invalidated:  u32,
	virtual_levels_invalidated: u32,
	// The shadow atlas's cache in the last frame: the lights that it held, 0 without it, the slots that the frame copied
	// from it, those that it drew, and those of them that a dynamic caster's report drew on the budget (see
	// docs/rendering/lighting-and-shadows.md#cached-shadow-maps).
	atlas_cache_lights:         u32,
	atlas_cache_copied:         u32,
	atlas_cache_drawn:          u32,
	atlas_cache_refreshed:      u32,
	// The pool of mesh pages: the pages that are resident, the slots that it has, 0 without a paged mesh, the pages that
	// views want and that are not resident yet, and the bytes a second that the frames since the last stats copied into
	// it (see docs/rendering/assets.md#mesh-pages).
	mesh_pages_resident:        u32,
	mesh_pages_capacity:        u32,
	mesh_pages_pending:         u32,
	mesh_pages_streamed_bytes:  u32,
	// The pool of virtual texture pages: the pages that are resident, the slots that it has, 0 without a virtual texture,
	// the pages that views want and that are not resident yet, the bytes a second that the frames since the last stats
	// copied into it, and the bytes of its atlases. Then the video memory that the process uses and the budget that the OS
	// gives it, both 0 when the backend does not know (see docs/rendering/assets.md#virtual-textures).
	texture_pages_resident:     u32,
	texture_pages_capacity:     u32,
	texture_pages_pending:      u32,
	texture_streamed_bytes:     u32,
	texture_pool_bytes:         u64,
	video_memory_used:          u64,
	video_memory_budget:        u64,
	// The assets that are resident: how many, the GPU memory of their buffers and textures, and how many were unloaded
	// because nothing used them and how many times a texture streamed another mip, since the start (see
	// docs/rendering/assets.md#gpu-residency).
	assets_resident:            u32,
	assets_unloaded:            u32,
	texture_mips_streamed:      u32,
	resident_bytes:             u64,
	// The scenes that the streaming policy is loading, and the entities that the last frame's work made and gave their
	// components, across all of them (see docs/world/streaming.md#budgets).
	scenes_loading:             u32,
	scene_entities_spawned:     u32,
	scene_entities_filled:      u32,
	// The split cascades' tables a frame or two ago, a cascade each, none without them (see
	// docs/rendering/global-illumination.md#split-cascades).
	gi_cascades:                []Gi_Cascade_Stats,
	// The reflection probes in the last frame, the slots whose probe has a cube, of the level's slots, 0 without the
	// probes, and the faces that the frame captured (see docs/rendering/lighting-and-shadows.md#reflection-probes).
	reflection_probes:          u32,
	reflection_probe_slots:     u32,
	reflection_probe_capacity:  u32,
	reflection_probe_faces:     u32,
	// The bytes that the reflections keep between frames: the probes' cubes and the screen-space or traced
	// reflections' histories (see render.reflection_memory).
	reflection_memory:          u64,
	// The input contexts' pushes, the top first, none while every stack is the default alone.
	input_contexts:             []Input_Context_Stats,
}

// Gi_Cascade_Stats is a split cascade's table: the probes that rays reached, its slots, and the keys that found no
// room this frame.
Gi_Cascade_Stats :: struct {
	active:  u32,
	slots:   u32,
	dropped: u32,
}

// Agent_Result is how a decision node last ended: None before it has ended, or Aborted when its parent or its guard
// stopped it while it ran.
Agent_Result :: enum u8 {
	None,
	Succeeded,
	Failed,
	Aborted,
}

// Agent_Node is a decision node that runs or has ended, by its ID in the decision's text.
Agent_Node :: struct {
	id:      u32,
	running: bool,
	last:    Agent_Result,
}

// Agent_Kind is the type of a blackboard key or an action's parameter. It matches format.Blackboard_Type, and String is
// only an action's parameter.
Agent_Kind :: enum u8 {
	Float,
	Int,
	Bool,
	Enum,
	Entity,
	Position,
	Vector,
	String,
}

// Agent_Value is a blackboard key and its value as the editor shows it: a float with up to three decimals, an enum as
// its name, an entity as `none` or `#index:generation`, a position in meters as `[x, y, z]`, a vector as `[x, y, z]`.
Agent_Value :: struct {
	name: string,
	kind: Agent_Kind,
	text: string,
}

// Agent_Option is a utility option as the agent's last think scored it, by its ID in the decision's text: its score,
// whether it is the option that the agent runs, and its considerations. Scores are rounded to three decimals.
Agent_Option :: struct {
	id:             u32,
	score:          f32,
	chosen:         bool,
	considerations: []Agent_Consideration,
}

// Agent_Consideration is a consideration of an option, by its ID: its input normalized to 0 to 1, and its curve's
// value there, each rounded to three decimals.
Agent_Consideration :: struct {
	id:    u32,
	input: f32,
	score: f32,
}

// Agent_Goal is a GOAP goal's priority in the agent's last think, by its ID, rounded to three decimals.
Agent_Goal :: struct {
	id:       u32,
	priority: f32,
}

// Agent_Method is the method, by its ID, that a running HTN plan chose for a compound task, by its ID.
Agent_Method :: struct {
	task:   u32,
	method: u32,
}

// Agent_Plan is a planning agent's plan: its goal's ID, 0 for none or for an HTN plan, which has no goal, the goals'
// priorities, the action nodes of the plan that runs, in their order, and the step that runs, an HTN plan's methods,
// and whether the agent searches for a plan.
Agent_Plan :: struct {
	goal:      u32,
	goals:     []Agent_Goal,
	steps:     []u32,
	step:      u32,
	methods:   []Agent_Method,
	searching: bool,
}

// Game to editor: what a watched entity's Agent does, which its component's bytes do not say (see
// docs/editor/decision-editor.md#live-view). A watched entity's goes out once after the watch, empty without an Agent,
// then when it changes. nodes are those of the decision that run or have ended, and values the blackboard's keys in
// their order. options are a utility decision's, and plan has at most one, a GOAP or an HTN decision's. Without an agent
// that is ready, decision is zero and the rest is too, which tells the editor that it has gone.
Agent_View :: struct {
	entity:   u64,
	decision: [16]u8,
	nodes:    []Agent_Node,
	values:   []Agent_Value,
	options:  []Agent_Option,
	plan:     []Agent_Plan,
}

// Agent_Action_Param is a parameter of a native action.
Agent_Action_Param :: struct {
	name: string,
	kind: Agent_Kind,
}

// Agent_Action_Info is a native action that the game registered, with its parameters.
Agent_Action_Info :: struct {
	name:   string,
	params: []Agent_Action_Param,
}

// Game to editor: the game's native actions, which a decision's `action` lines may name: when a new editor links and
// after a code reload, as for Game_Commands.
Agent_Actions :: struct {
	actions: []Agent_Action_Info,
}

// Game commands (see docs/editor/shell-and-panels.md#commands).

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

// Game to editor: what the edit-mode behaviours did to the scene in Edit mode (see
// docs/editor/document-and-scenes.md#behaviours-edits), as operations by scene ID, which the game has not applied.
// scene is the ticket of the Load_Scene that the world has. label names the behaviour's class, for the undo entry. The
// editor applies them to its document, which sends them back in Apply_Operations, and then answers with the ticket.
Behaviour_Operations :: struct {
	ticket:     u64,
	scene:      u64,
	label:      string,
	operations: []Operation,
}

// Editor to game: the answer to the Behaviour_Operations with the ticket, after the Apply_Operations that it sent.
// applied is false when the editor did not apply them: it does not edit now, the scene is another, or an operation
// does not fit its document.
Behaviour_Operations_Answer :: struct {
	ticket:  u64,
	applied: bool,
}

// Material previews (see docs/rendering/materials.md#material-previews). The game renders each open preview into a shared
// target of its own, beside the viewport's, when what it shows changes. The editor copies its frames as it copies the
// viewport's, and acknowledges them to the host.

Preview_Mesh :: enum u8 {
	Sphere,
	Cube,
	Plane,
	// The mesh asset that Preview_Settings names.
	Asset,
}

// Editor to game: show a material or a material instance, by its GUID, in preview id, which is below
// gpu.MAX_PREVIEW_TARGETS. With unsaved, the game loads the material from the preview area of the cache, where the
// cook daemon cooks the editor's unsaved graph (Cook_Preview on the cook link), and not from its own blob. For an open
// preview, it changes what the preview shows.
Open_Preview :: struct {
	id:       u32,
	material: [16]u8,
	unsaved:  bool,
}

// Editor to game: how preview id shows its material. The camera orbits the middle of the mesh: yaw turns it about the
// world's up axis and pitch tilts it, in radians, at distance meters. The size is in pixels, which the game keeps
// within gpu.MAX_PREVIEW_SIZE.
Preview_Settings :: struct {
	id:         u32,
	mesh:       Preview_Mesh,
	mesh_asset: [16]u8,
	yaw:        f32,
	pitch:      f32,
	distance:   f32,
	width:      i32,
	height:     i32,
}

// Editor to game: preview id is closed, and its shared target can go.
Close_Preview :: struct {
	id: u32,
}

// Game to editor: the shared target that preview id renders into, named <prefix>.texture0..2 and <prefix>.fence, as
// Frame_Target names the viewport's. Each size makes a new generation, whose frames count from 1 again.
Preview_Target :: struct {
	id:         u32,
	prefix:     string,
	generation: u32,
	width:      i32,
	height:     i32,
}

// Editor to host: the editor has finished copying this frame of this generation of preview id's target. The host
// renders frame k of a preview only if k <= frame + 2, as it does the viewport's frames.
Preview_Acknowledged :: struct {
	id:         u32,
	generation: u32,
	frame:      u64,
}

// Captures (see docs/editor/capture.md#capture). The host handles both messages: the frames are its own.

Capture_Kind :: enum u8 {
	// The next frame, as a PNG.
	Screenshot,
	// The history ring's last frames, as a looping GIF.
	Gif,
	// A texture that the game's next Bake_Thumbnail with this id draws, as a PNG.
	Thumbnail,
}

// What a Bake_Thumbnail draws.
Thumbnail_Kind :: enum u8 {
	Material,
	Mesh,
	Prefab,
}

// Editor to game: draw a picture of an asset, which the host writes to the path of the Capture_Request with this id, as
// its Capture_Result says. With node, only that entity of a prefab and what is under it. A new one replaces one that is
// not done. See docs/content/daemon-and-operations.md#thumbnails.
Bake_Thumbnail :: struct {
	id:     u32,
	kind:   Thumbnail_Kind,
	asset:  [16]u8,
	node:   u64,
	width:  i32,
	height: i32,
}

// Game to editor: a Bake_Thumbnail that cannot be drawn, and why.
Thumbnail_Failed :: struct {
	id:     u32,
	reason: string,
}

// Matches gpu.Output_Mode.
Output_Mode :: enum u8 {
	Sdr,
	Hdr10,
	Scrgb,
}

// Editor to host: the viewport whose frames the host's screenshots and history ring read (see
// docs/editor/capture.md#capture), or a negative number for the host's frame target, which is the start. The editor
// sends it when its capture view changes, and when the link connects. A frame that does not draw the viewport has no
// capture, as a minimized frame has none.
Capture_Source :: struct {
	viewport: i32,
}

// Editor to game: the points that the Navigation Path tool picked: none, a start, or a start and a goal (see
// docs/editor/viewport.md#navigation-path). With both, the helpers draw the path between them for each agent type,
// from the cooked navmeshes. The editor sends it when a click picks a point, when the tool closes, with none, and when
// the link connects.
Nav_Probe :: struct {
	points: []Nav_Probe_Point,
}

// A point of a Nav_Probe: a World_Position's raw value.
Nav_Probe_Point :: struct {
	position: [3]i64,
}

// Editor to game: the scenes of the world that the editor shows, which the helpers draw (see
// docs/editor/world-view.md#the-viewport), and the preview's position, none or one. The editor works out each scene's
// flags, so the game only draws. The editor sends it when the world, its scenes, the active scene, the preview or the
// game's streamed scenes change, with no scenes when no world shows, and when the link connects.
World_View :: struct {
	scenes:  []World_View_Scene,
	preview: []Nav_Probe_Point,
}

// A scene of a World_View: its bounds as World_Positions' raw values, and its distances in meters, as the world's
// World_Scene_Record has them.
World_View_Scene :: struct {
	min, max:        [3]i64,
	load_distance:   f32,
	unload_distance: f32,
	// Persistent scenes have no bounds, and draw nothing.
	persistent:      bool,
	// The editor's active scene.
	active:          bool,
	// The preview loads it.
	previewed:       bool,
	// The game streamed it in.
	loaded:          bool,
}

// Game to editor: the scenes of its world that the streaming policy has in (see
// docs/editor/world-view.md#play), in the world's order. The game sends it when they change, and when the link
// connects, with no world and no scenes when nothing streams.
Streamed_Scenes :: struct {
	world:  [16]u8,
	scenes: []Streamed_Scene,
}

Streamed_Scene :: struct {
	guid:   [16]u8,
	// The game's number for the scene, from scene.FIRST_RUNTIME_SCENE up.
	number: u32,
	// The scene is shown; it is loading until then.
	ready:  bool,
}

// Editor to host: write the next frame of the capture's source as a PNG, or the history ring as a GIF, to path, an
// absolute path whose directory the host makes, or to captures/<utc time>-f<frame>.<png|gif> beside the host when path
// is "". The host answers with a Capture_Result with the same id, once the file is written.
Capture_Request :: struct {
	id:   u32,
	kind: Capture_Kind,
	path: string,
}

// Host to editor: the file that a request made, or why it made none. frame is the captured frame's number in the
// host's count, or a GIF's last frame; frames and duration_ms are a GIF's frames and the time they span; output is
// the frame's output mode, which says how the colors were converted.
Capture_Result :: struct {
	id:          u32,
	kind:        Capture_Kind,
	ok:          bool,
	reason:      string,
	path:        string,
	frame:       u64,
	width:       u32,
	height:      u32,
	frames:      u32,
	duration_ms: f32,
	output:      Output_Mode,
}

// Live meshes (see docs/editor/mesh-editing.md#live-meshes). The editor edits a mesh file as a structured mesh, and the
// game draws it from memory in place of the mesh's cooked blob while the editor holds it, so a drag shows at frame
// rate. The structure is the file's, as a Load_Scene is a scene's, so the game bakes it with the parser's result type.

// A material slot of a live mesh that names a material.
Live_Material :: struct {
	slot: u32,
	guid: [16]u8,
}

// A face's texture mapping, as the file's map line has it.
Live_Mapping :: struct {
	u_axis:   [3]f32,
	v_axis:   [3]f32,
	// Meters per texture repeat.
	scale:    [2]f32,
	// In repeats.
	shift:    [2]f32,
	// Degrees.
	rotation: f32,
}

// A polygon of three or more vertex indices, clockwise seen from its front.
Live_Face :: struct {
	slot:    u32,
	corners: []u32,
	mapping: Live_Mapping,
}

// A sharp edge between two vertices.
Live_Edge :: struct {
	a, b: u32,
}

// Editor to game: the whole structured mesh of the mesh asset guid. The game bakes it and makes it resident in place
// of the asset, until a Release_Live_Mesh. positions are x, y, z per vertex, in meters in the mesh's space.
Live_Mesh :: struct {
	guid:      [16]u8,
	materials: []Live_Material,
	positions: []f32,
	faces:     []Live_Face,
	sharp:     []Live_Edge,
}

// Editor to game: a drag's step: the positions only, for a mesh that a Live_Mesh gave, with the same count. The game
// bakes it again and streams it again.
Live_Mesh_Vertices :: struct {
	guid:      [16]u8,
	positions: []f32,
}

// Editor to game: the editor has let go of the mesh. The game clears the override and draws the asset's blob.
Release_Live_Mesh :: struct {
	guid: [16]u8,
}

// The landscape tools' live textures (see docs/editor/landscape.md#live-textures): a surface's height map, hole mask or
// layer map that the editor paints, which the game draws, and collides with, from memory in place of its cooked blob.

Live_Texture_Usage :: enum u8 {
	// A height texture: R16_Unorm.
	Height,
	// A hole mask: 0 is a hole.
	Mask,
	// A layer map: four values a texel, the weights of the layers that a terrain material blends, as RGBA8_Unorm.
	Layers,
}

// live_texture_channels is how many values a texel of a live texture has: four for a layer map, one for the others.
live_texture_channels :: proc "contextless" (usage: Live_Texture_Usage) -> int {
	return 4 if usage == .Layers else 1
}

// Editor to game: the whole of the texture asset guid, size.x by size.y texels from 0 to 65535, row-major, each of
// live_texture_channels values. The game builds a blob with its mips and puts it in place of the asset's, until a
// Release_Live_Texture.
Live_Texture :: struct {
	guid:   [16]u8,
	usage:  Live_Texture_Usage,
	size:   [2]u32,
	texels: []u16,
}

// Editor to game: a stroke's step: size.x by size.y texels at origin, for a texture that a Live_Texture gave.
Live_Texture_Region :: struct {
	guid:   [16]u8,
	origin: [2]u32,
	size:   [2]u32,
	texels: []u16,
}

// Editor to game: the editor has let go of the texture. The game loads the asset's cooked blob again.
Release_Live_Texture :: struct {
	guid: [16]u8,
}

// Editor to game: the whole of the instance set asset guid, which the landscape tools' foliage brushes paint (see
// docs/editor/landscape.md#foliage): each instance's position x, y, z, rotation x, y, z, w and scale x, y, z, relative
// to its entity. The game builds a blob of them and puts it in place of the asset's, until a Release_Live_Instances.
Live_Instances :: struct {
	guid:      [16]u8,
	positions: []f32,
	rotations: []f32,
	scales:    []f32,
}

// Editor to game: the editor has let go of the instance set. The game loads the asset's cooked blob again.
Release_Live_Instances :: struct {
	guid: [16]u8,
}

// Editor to game: the landscape brush under the mouse, which the helpers draw while visible: two circles about center,
// a World_Position's raw value, across the plane whose normal is up, of radius meters and of radius * (1 - falloff),
// where its strength starts to fall off.
Landscape_Overlay :: struct {
	visible: bool,
	center:  [3]i64,
	up:      [3]f32,
	radius:  f32,
	falloff: f32,
}

// Mesh mode's overlay (see docs/editor/mesh-editing.md#overlay-and-picking). The editor does the picking itself, and
// tells the game what to draw over each live mesh: its edges and vertices, with the selected and the hovered elements
// highlighted, the selected faces filled, and the grid.

Mesh_Element :: enum u8 {
	Vertices,
	Edges,
	Faces,
}

// One edited mesh: the live mesh guid, drawn at entity's pose, with its selected elements by index, edges by their
// vertices, and the hovered one of each kind, -1 or none for none.
Mesh_Overlay_Mesh :: struct {
	guid:              [16]u8,
	entity:            u64,
	selected_vertices: []u32,
	selected_edges:    []Live_Edge,
	selected_faces:    []u32,
	hovered_vertex:    i32,
	hovered_edge:      Live_Edge,
	has_hovered_edge:  bool,
	hovered_face:      i32,
	// The points of a Cut or a Draw so far, x, y, z each, in the mesh's space.
	marks:             []f32,
}

// Editor to game: what mesh mode shows this frame, or with active false, nothing. The grid is on the plane through
// grid_origin, a World_Position, facing the world axis grid_axis (0 for x, 1 for y, 2 for z), with lines grid_size
// apart.
Mesh_Overlay :: struct {
	active:      bool,
	element:     Mesh_Element,
	meshes:      []Mesh_Overlay_Mesh,
	grid:        bool,
	grid_size:   f32,
	grid_origin: [3]i64,
	grid_axis:   u8,
}

// Overrides (see docs/editor/link.md#overrides). In Edit, an owner in the editor, such as the cutscene editor's scrub,
// writes values over the world that mirrors the document, without the document: no operation, no undo entry, and
// no change to what the editor saves. The editor picks each override's number, which only goes up in a session, so a
// late message for an override that ended is dropped.

// Editor to game: start the override with this number. The game answers only when it cannot start it, with
// Override_Ended.
Begin_Override :: struct {
	override: u64,
}

Override_Target_Kind :: enum u8 {
	// An entity of the editor's document, by its scene's number and its scene ID.
	Scene_Entity,
	// An entity that the override spawned, by the key of its Override_Spawn.
	Spawned,
}

// An entity that an override writes. scene is the number of the scene whose IDs entity (for a Scene_Entity) and the
// references in values name.
Override_Target :: struct {
	kind:   Override_Target_Kind,
	scene:  u32,
	entity: u64,
}

// An instance of prefab, which lives while the override has it in its frames. key names it, and only the first
// frame that has the key spawns it, at pose.
Override_Spawn :: struct {
	key:      u64,
	prefab:   [16]u8,
	// A World_Position's raw value.
	position: [3]i64,
	rotation: [4]f32,
	scale:    [3]f32,
}

// A component's field, by its component ID and the hash of its name (asset_format.scene_field_hash), as the scene
// format names it.
Override_Field :: struct {
	target:    Override_Target,
	component: u64,
	field:     u64,
	value:     Scene_Value,
}

// An entity's pose, in its own space: for a root, the world's, and position is a World_Position's raw value; for a
// child, its parent's, and position is in the same units, 2^-24 m. The entity moves without interpolation.
Override_Transform :: struct {
	target:   Override_Target,
	position: [3]i64,
	rotation: [4]f32,
	scale:    [3]f32,
}

// A clip that poses an Animator over its graph's pose, as anim.Driven_Sample is.
Override_Sample :: struct {
	clip:        [16]u8,
	time:        f32,
	weight:      f32,
	root_motion: bool,
}

// An Animator's driven samples (see docs/animation/design.md#driving-an-animator). With hold, its graph's time stops.
Override_Animator :: struct {
	target:  Override_Target,
	hold:    bool,
	samples: [2]Override_Sample,
}

// A camera on the stack of a game view (see docs/world/cameras.md#stacks).
Override_Camera :: struct {
	view:     u8,
	target:   Override_Target,
	priority: i32,
}

// Editor to game: everything that the override writes, for one frame. What an earlier frame wrote and this one does
// not goes back to the document's value, and a spawned entity whose key is not in spawns goes.
Override_Frame :: struct {
	override:   u64,
	spawns:     []Override_Spawn,
	fields:     []Override_Field,
	transforms: []Override_Transform,
	animators:  []Override_Animator,
	cameras:    []Override_Camera,
}

// Editor to game: end the override. The world shows the document's values again, and its spawned entities go, in
// the same frame.
Release_Override :: struct {
	override: u64,
}

Override_End_Reason :: enum u8 {
	// The game is not in Edit with the editor's scene, so the override did not start.
	Not_Editing,
	// The game has as many overrides as it holds, so the override did not start.
	Full,
	// The mode changed from Edit.
	Mode,
	// The editor's scene replaced the world.
	Scene_Loaded,
	// The game's code reloaded.
	Code_Reloaded,
}

// Game to editor: the game ended an override that the editor did not release, or did not start it.
Override_Ended :: struct {
	override: u64,
	reason:   Override_End_Reason,
}

// A field of a watched entity that an override holds, as Override_Field names it. A transform holds each field of the
// entity's Transform, or of its Local_Transform for a child.
Held_Field :: struct {
	component: u64,
	field:     u64,
}

// Game to editor: the entities that overrides write or spawned, when they change.
Overridden_Entities :: struct {
	entities: []u64,
}

// The cutscene preview (see docs/editor/cutscene-editor.md#preview). In Edit, the cutscene editor's tab shows its
// cutscene in the world at the playhead, without the document: the game binds the cutscene, spawns its spawned
// entities, and evaluates it at a time that the editor sends, or on its own clock while it plays. The editor picks each
// preview's ticket, which only goes up in a session, so a late message for a preview that ended is dropped. One
// preview is open at a time; an Open with a higher ticket ends the one before it.

// Editor to game: preview the cutscene at tick, paused. With unsaved, its blob is the one that the cook daemon wrote to
// the preview area from the editor's unsaved text, and a newer one there replaces it in place, at the same time.
// The game answers with Cutscene_Preview_Opened, or with Cutscene_Preview_Ended when it cannot.
Cutscene_Preview_Open :: struct {
	ticket:   u64,
	cutscene: [16]u8,
	unsaved:  bool,
	tick:     i32,
}

// Editor to game: show the preview at tick, paused. No event fires.
Cutscene_Preview_Time :: struct {
	ticket: u64,
	tick:   i32,
}

// Editor to game: play the preview from tick on the game's clock, at rate times real time. With looping, the time
// goes back to loop_start when it reaches loop_end; without, it stops at the end of the cutscene's range.
Cutscene_Preview_Play :: struct {
	ticket:     u64,
	tick:       i32,
	rate:       f32,
	looping:    bool,
	loop_start: i32,
	loop_end:   i32,
}

// Editor to game: end the preview. The world shows the document again, and the spawned entities go, in the same
// frame. The game does not answer.
Cutscene_Preview_Close :: struct {
	ticket: u64,
}

// Game to editor: the preview is open, at the tick, with the cutscene's range.
Cutscene_Preview_Opened :: struct {
	ticket:      u64,
	tick:        i32,
	range_start: i32,
	range_end:   i32,
}

Cutscene_Preview_End_Reason :: enum u8 {
	// The game is not in Edit with the editor's scene, so the preview did not open.
	Not_Editing,
	// The cutscene, an asset that it references, or a binding did not load, so the preview did not open or ended.
	Failed,
	// The mode changed from Edit.
	Mode,
	// The editor's scene replaced the world.
	Scene_Loaded,
	// The game's code reloaded.
	Code_Reloaded,
}

// Game to editor: the game ended a preview that the editor did not close, or did not open it.
Cutscene_Preview_Ended :: struct {
	ticket: u64,
	reason: Cutscene_Preview_End_Reason,
}

// Game to editor: the preview's time, in each frame while it plays, and once when it stops at the end of the range,
// with playing false. The editor draws its playhead from it, and never waits for it.
Cutscene_Preview_Tick :: struct {
	ticket:  u64,
	tick:    i32,
	playing: bool,
}
