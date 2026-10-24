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
