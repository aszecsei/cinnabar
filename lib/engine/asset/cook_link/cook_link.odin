// Package cook_link is the cook link's protocol: the messages between the editor and the cook daemon, which go over
// the transport in lib/engine/wire (see docs/content-pipeline.md#cook-link). tools/cook uses it, and the editor's C#
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
}

// Editor to daemon, first: the editor's protocol version and its name.
Hello :: struct {
	protocol: u64,
	editor:   string,
}

// Daemon to editor, the answer to a Hello with the same protocol version. An Asset_Snapshot follows it.
Welcome :: struct {
	protocol:  u64,
	// The configuration that the daemon cooks, "dev".
	config:    string,
	roots:     []Root,
	importers: []Importer,
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
// docs/content-pipeline.md#asset-operations). Each is a request with an ID in its header. The daemon checks
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
