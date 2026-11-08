package cook

import "core:log"

import cook_link "cinnabar:engine/asset/cook_link"
import "cinnabar:engine/wire/serve"

// The daemon's side of the cook link (see docs/content/daemon-and-operations.md#cook-link) is a serve.Server, as the
// host's side of the editor link is. These wrappers take the cook link's union, so a message of any of its types
// converts.

// server_send queues a message for a connection, if it is still the one that is open.
server_send :: proc(s: ^serve.Server, connection: u64, message: cook_link.Message, request: u32 = 0) {
	serve.send(s, connection, message, request)
}

// server_send_linked queues a message for the linked editor, if there is one.
server_send_linked :: proc(s: ^serve.Server, message: cook_link.Message, request: u32 = 0) {
	serve.send_linked(s, message, request)
}

// write_log is the server's Write_Log: a log line as the cook link's Log.
write_log :: proc(out: ^[dynamic]byte, level: log.Level, time: i64, location: string, text: string) {
	cook_link.write_message(out, cook_link.Log{level = log_level(level), time = time, location = location, text = text})
}

@(private = "file")
log_level :: proc(level: log.Level) -> cook_link.Log_Level {
	switch {
	case level >= .Fatal:
		return .Fatal
	case level >= .Error:
		return .Error
	case level >= .Warning:
		return .Warning
	case level >= .Info:
		return .Info
	}
	return .Debug
}
