// Package cook_link is the cook link's protocol: the messages between the editor and the cook daemon, which go over
// the transport in lib/engine/wire (see docs/content/daemon-and-operations.md#cook-link). tools/cook uses it, and the editor's C#
// is generated from its schema. It imports nothing from core or engine.
package cook_link

import "core:mem"

import "cinnabar:engine/wire"

// A message's kind is its index in this union, from 1. Adding, removing or reordering messages changes the schema,
// and with it the protocol version, so an editor and a daemon that disagree refuse each other at the handshake.
Message :: union {
	Hello,
	Welcome,
	Refused,
	Log,
	Asset_Snapshot,
	Asset_Delta,
	Asset_Problems,
	Cook_Finished,
	Create_Asset,
	Create_Folder,
	Move_Assets,
	Rename_Asset,
	Rename_Folder,
	Duplicate_Assets,
	Delete_Assets,
	Set_Import_Settings,
	Reimport,
	Operation_Result,
	Shading_Models,
	Cook_Preview,
	Preview_Result,
}

// Editor to daemon, first: the editor's protocol version and its name.
Hello :: struct {
	protocol: u64,
	editor:   string,
}

// Daemon to editor, the answer to a Hello with the same protocol version. An Asset_Snapshot and the Shading_Models
// follow it.
Welcome :: struct {
	protocol:  u64,
	// The configuration that the daemon cooks, "dev".
	config:    string,
	roots:     []Root,
	importers: []Importer,
	// The kinds of node that material graphs have, which the editor's node editor shows (see
	// docs/content/kinds/materials.md#material-graphs).
	nodes:     []Node_Info,
}

// A content root, by its name, such as "game", and its directory: absolute, with forward slashes.
Root :: struct {
	name: string,
	dir:  string,
}

// Importer is what the daemon cooks of one kind of asset: its extension, such as ".luau", and its import settings.
Importer :: struct {
	kind:      Asset_Kind,
	extension: string,
	settings:  []Setting_Info,
}

// Setting_Info is an import setting that an importer knows: its key in the .meta file, the values that it takes, and
// the value that an asset without the setting has.
Setting_Info :: struct {
	key:         string,
	values:      []string,
	default:     string,
	description: string,
}

// Daemon to editor, the answer to a Hello with another protocol version. The daemon closes the link after it.
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

// Daemon to editor: a line of the daemon's log. While an editor is linked, the log goes here and not to the daemon's
// console.
Log :: struct {
	level:    Log_Level,
	// Nanoseconds since the Unix epoch.
	time:     i64,
	// file:line:procedure.
	location: string,
	text:     string,
}

Asset_Kind :: enum u8 {
	Script,
	Scene,
	Shader,
	Texture,
	Model,
	Mesh,
	Shading_Model,
	Material,
	Material_Instance,
	Material_Function,
	Prefab,
	Effect,
	Stage,
}

Asset_Status :: enum u8 {
	// Its blob is up to date.
	Current,
	// The last cook failed, so it keeps its old blob, if it has one.
	Failed,
}

// Asset is an asset in the daemon's index.
Asset :: struct {
	// 32 hex digits, as in its .meta file.
	guid:         string,
	kind:         Asset_Kind,
	// The root's name, and the path in the root with forward slashes, such as "scripts/hello.luau".
	root:         string,
	path:         string,
	status:       Asset_Status,
	errors:       u32,
	warnings:     u32,
	// For a script that defines a behaviour, the class's name.
	behaviour:    string,
	// The import settings in its .meta file, in the file's order.
	settings:     []Setting,
	// The GUIDs of the assets that it depends on: a script's requires, and the scripts that a scene names.
	dependencies: []string,
	// For a sub-asset, such as a mesh of a glTF file, the GUID of the file that makes it and its name in the file. Its
	// root and path are the file's. "" for a file.
	parent:       string,
	subasset:     string,
	// For a material, the combinations of static switches that it and its instances use, which each compile its
	// shaders. 0 for other kinds.
	permutations: u32,
	// For a texture, its cooked size in texels, or zero before it has cooked. For a material or an instance, the
	// texture that the editor's texture tools measure by (see docs/editor/mesh-editing.md#texture-tools), by GUID or
	// "", and the hotspot rectangles of the material's source, in that texture's texels.
	size:         [2]u32,
	tool_texture: string,
	hotspots:     []Hotspot,
	// For a sub-asset whose source the cooker generates, as a USD stage's prefab, the generated text's absolute path,
	// which the editor reads in place of the file's (see docs/content/kinds/stages.md#prefab). "" otherwise.
	generated:    string,
}

// A hotspot rectangle of a material's tool texture, in texels: a complete tileable piece that the Hotspot tool maps a
// face onto.
Hotspot :: struct {
	x0, y0, x1, y1: u32,
}

Setting :: struct {
	key:   string,
	value: string,
}

// A directory in a root, by the root's name and its path in the root, such as "scripts/ui".
Folder :: struct {
	root: string,
	path: string,
}

// Daemon to editor: every asset and folder. It follows the Welcome, and replaces what the editor had.
Asset_Snapshot :: struct {
	assets:  []Asset,
	folders: []Folder,
}

// Daemon to editor, after a cook that changed the index: the assets that are new or changed, by their whole entry,
// and the GUIDs of the assets that are gone, with the folders that came and went.
Asset_Delta :: struct {
	changed:         []Asset,
	removed:         []string,
	added_folders:   []Folder,
	removed_folders: []Folder,
}

// Daemon to editor: the problems of one asset, which replace its earlier ones. An empty list clears them. Problems
// that belong to no asset, such as a broken definition file, have the GUID "".
Asset_Problems :: struct {
	guid:     string,
	problems: []Problem,
}

Problem :: struct {
	// Absolute, with forward slashes: the asset's source or .meta file, or another file. Empty for none.
	file:   string,
	// From 1, or 0 for the whole file.
	line:   u32,
	column: u32,
	error:  bool,
	text:   string,
}

Cooked_Count :: struct {
	kind:  Asset_Kind,
	count: u32,
}

// Daemon to editor: a cook is done.
Cook_Finished :: struct {
	// The cache's generation after the cook.
	generation:   u64,
	// The assets that the cook wrote, for each kind that it wrote any of.
	cooked:       []Cooked_Count,
	failed:       u32,
	milliseconds: f32,
}

// The asset operations go from the editor to the daemon, which is the only program that writes .meta files (see
// docs/content/daemon-and-operations.md#asset-operations). Each is a request with an ID in its header. The daemon checks
// everything first, so an operation fails without changing anything, or does all of it. It then cooks, sends what
// changed, and answers with an Operation_Result with the request's ID, so the editor's index already has the change.
// Names are file and folder names without a path, and an asset's name is without its extension.

Asset_Template :: enum u8 {
	// A module that returns a table.
	Script,
	// A script that defines a behaviour, whose class is named for the file.
	Behaviour,
	// An empty scene.
	Scene,
	// A material graph with a Lit output and nothing linked to it.
	Material,
	// A material function with one input and one output, linked.
	Material_Function,
	// A mesh file of a 1 m box with world-aligned mappings.
	Mesh,
	// A prefab with one root, named for the file, at the origin.
	Prefab,
	// An effect with one emitter of soft puffs.
	Effect,
}

// Makes an asset from a template in a folder, with a new .meta file. The result has its GUID.
Create_Asset :: struct {
	template: Asset_Template,
	root:     string,
	// The folder's path in the root, or "" for the root.
	folder:   string,
	name:     string,
}

// Makes a folder. Its parent must exist.
Create_Folder :: struct {
	root: string,
	path: string,
}

// Moves assets, each with its .meta file, into a folder, of the same root or another.
Move_Assets :: struct {
	guids:  []string,
	root:   string,
	folder: string,
}

// Renames an asset in its folder. It keeps its extension.
Rename_Asset :: struct {
	guid: string,
	name: string,
}

// Renames a folder in its parent, with everything in it.
Rename_Folder :: struct {
	root: string,
	path: string,
	name: string,
}

// Copies assets in their folders, each with a new .meta file that has its import settings. The result has the copies'
// GUIDs, in order.
Duplicate_Assets :: struct {
	guids: []string,
}

// Sends assets with their .meta files, and folders with everything in them, to the Recycle Bin.
Delete_Assets :: struct {
	guids:   []string,
	folders: []Folder,
}

// Replaces an asset's import settings. The daemon checks them with the asset's importer, writes its .meta file, and
// cooks it again.
Set_Import_Settings :: struct {
	guid:     string,
	settings: []Setting,
}

// Cooks assets again with the same settings, also when their blobs are up to date.
Reimport :: struct {
	guids: []string,
}

// Daemon to editor: the answer to an operation, with its request's ID.
Operation_Result :: struct {
	// Why the operation failed, or "" when it succeeded.
	error: string,
	// The GUIDs of the assets that it made, if any.
	guids: []string,
}

// Material graphs (see docs/content/kinds/materials.md#material-graphs). The daemon gives the editor the kinds of node and
// the shading models, whose surface inputs are the inputs of a graph's output node, and cooks the graphs that the
// editor has not saved, for its previews.

// The type of a node's input or output. Any takes the widest of the node's Any inputs, and a scalar fits any width.
Pin_Type :: enum u8 {
	Float,
	Float2,
	Float3,
	Float4,
	Any,
	// A texture parameter's bindless index, which only texture inputs take.
	Texture,
}

// An input or an output of a kind of node. An input that is not linked and has no value of its own takes default, or
// with a default_label, a value that the shaders give, such as the mesh's first UV set.
Node_Pin :: struct {
	name:          string,
	type:          Pin_Type,
	default:       [4]f32,
	default_label: string,
}

Property_Kind :: enum u8 {
	Number,
	Vector2,
	Vector3,
	Vector4,
	Color,
	// A quoted string.
	Text,
	// HLSL, a quoted string.
	Code,
	// One of choices, as a bare word.
	Choice,
	// The name of one of the material's parameters, quoted.
	Parameter,
	// The name of one of the material's static switches, quoted.
	Switch,
	// A material function's GUID after $.
	Function,
}

// A setting of a node that is not an input, such as the parameter that a parameter node reads. default is as a
// .material file writes it.
Node_Property :: struct {
	name:    string,
	kind:    Property_Kind,
	choices: []string,
	default: string,
}

// Where a kind of node's inputs and outputs come from, besides its lists.
Node_Pins_From :: enum u8 {
	// Its lists only.
	Kind,
	// The inputs of the material's shading model: the output node.
	Shading_Model,
	// The inputs and outputs of the material function that it calls.
	Function,
}

// Which graphs a kind of node is in.
Node_Scope :: enum u8 {
	Both,
	Material,
	Function,
}

// A kind of node of material graphs, by its name in a .material file, such as "multiply".
Node_Info :: struct {
	kind:        string,
	label:       string,
	category:    string,
	description: string,
	inputs:      []Node_Pin,
	outputs:     []Node_Pin,
	properties:  []Node_Property,
	pins_from:   Node_Pins_From,
	scope:       Node_Scope,
}

// A shading model, by its name, such as "lit", and the surface inputs that its .shading file declares.
Shading_Model_Info :: struct {
	name:        string,
	guid:        string,
	inputs:      []Node_Pin,
	no_lighting: bool,
}

// Daemon to editor: every shading model that cooks. It follows the Asset_Snapshot, and comes again after a pass that
// changed any.
Shading_Models :: struct {
	models: []Shading_Model_Info,
}

// Editor to daemon: the text of a material that the editor has not saved, as a request. The daemon cooks it as the
// material with this GUID, into the preview area of the cache, <cache>/dev/preview/<guid>.blob, which the host's
// previews load. The material's own blob does not change. A Preview_Result with the request's ID answers it.
Cook_Preview :: struct {
	guid: string,
	text: string,
}

// Daemon to editor: the answer to a Cook_Preview. error is "" when the preview cooked, and problems are its errors and
// warnings, with the lines of the text that it was given.
Preview_Result :: struct {
	error:    string,
	problems: []Problem,
}

Header :: wire.Header
HEADER_SIZE :: wire.HEADER_SIZE

read_header :: wire.read_header

write_message :: proc(buf: ^[dynamic]byte, message: Message, request: u32 = 0) {
	wire.write_message(buf, message, request)
}

kind_of :: proc($T: typeid) -> u16 {
	return wire.kind_of(Message, T)
}

decode_message :: proc(kind: u16, payload: []byte, allocator: mem.Allocator) -> (message: Message, ok: bool) {
	return wire.decode_message(Message, kind, payload, allocator)
}

schema :: proc(allocator := context.allocator) -> string {
	return wire.schema(Message, allocator)
}

protocol_version :: proc() -> u64 {
	return wire.protocol_version(Message)
}
