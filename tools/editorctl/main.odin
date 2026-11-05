// tools/editorctl drives a running editor from a terminal (see docs/editor/capture.md#automation): it finds the
// editor's automation file, sends one JSON request to the editor's loopback socket, and prints the answer. An LLM
// tool or a script asks for a screenshot or a GIF this way, then reads the files it names.
//
//   editorctl [--automation <file>] [--json] status
//   editorctl [--automation <file>] [--json] screenshot [--view <name>]... [--out <path>]
//   editorctl [--automation <file>] [--json] gif [--out <path>]
//   editorctl [--automation <file>] [--json] viewport --set <name>=<value>...
//   editorctl [--automation <file>] [--json] camera --position <x>,<y>,<z> [--yaw <radians>] [--pitch <radians>]
//   editorctl [--automation <file>] [--json] ui [--window <panel>] [--out <path>]
//   editorctl [--automation <file>] [--json] content [--set <name>=<value>]...
package editorctl

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"

// Where the editor writes its port, under the repository root.
AUTOMATION_FILE :: "build/obj/editor/automation.json"
// The file that marks the repository root.
ROOT_MARKER :: "justfile"
// GetExitCodeProcess gives this for a process that still runs.
STILL_ACTIVE :: 259
// A response longer than this is not read.
MAX_RESPONSE :: 1 << 20

// Setting is a viewport setting's value: a boolean, a number or a string.
Setting :: json.Value

Options :: struct {
	command:    string,
	views:      [dynamic]string,
	out:        string,
	automation: string,
	json:       bool,
	// viewport's settings by their sidecar names, each a boolean, a number or a string, and camera's position in
	// meters and its angles in radians.
	settings:   map[string]Setting,
	position:   []f64,
	yaw:        Maybe(f64),
	pitch:      Maybe(f64),
	// The panel whose window ui draws, or "" for the main window.
	window:     string,
}

// Request matches AutomationRequest in Cinnabar.Editor.Model.
Request :: struct {
	id:       i64 `json:"id"`,
	command:  string `json:"command"`,
	views:    []string `json:"views"`,
	path:     string `json:"path"`,
	settings: map[string]json.Value `json:"settings"`,
	position: []f64 `json:"position"`,
	yaw:      Maybe(f64) `json:"yaw"`,
	pitch:    Maybe(f64) `json:"pitch"`,
	window:   string `json:"window"`,
}

// Status matches AutomationStatus.
Status :: struct {
	linked:     bool `json:"linked"`,
	host_state: string `json:"hostState"`,
	mode:       string `json:"mode"`,
	scene:      string `json:"scene"`,
	game:       string `json:"game"`,
	host_pid:   int `json:"hostPid"`,
}

// Content matches AutomationContent.
Content :: struct {
	folder:    string `json:"folder"`,
	search:    string `json:"search"`,
	selection: []string `json:"selection"`,
	items:     []string `json:"items"`,
	thumbnails_waiting: int `json:"thumbnailsWaiting"`,
	thumbnails_failed:  []string `json:"thumbnailsFailed"`,
}

// Response matches AutomationResponse.
Response :: struct {
	id:      i64 `json:"id"`,
	ok:      bool `json:"ok"`,
	files:   []string `json:"files"`,
	error:   string `json:"error"`,
	status:  Maybe(Status) `json:"status"`,
	content: Maybe(Content) `json:"content"`,
}

// Info matches AutomationInfo.
Info :: struct {
	port:    int `json:"port"`,
	pid:     u32 `json:"pid"`,
	started: string `json:"started"`,
}

main :: proc() {
	options, problem := parse_args(os.args[1:])
	if problem != "" {
		fmt.eprintfln("editorctl: %s", problem)
		fmt.eprintln(
			"usage: editorctl [--automation <file>] [--json] status | screenshot [--view <name>]... [--out <path>] | gif [--out <path>] | viewport --set <name>=<value>... | camera --position <x>,<y>,<z> [--yaw <radians>] [--pitch <radians>] | ui [--window <panel>] [--out <path>] | content [--set <name>=<value>]...",
		)
		os.exit(2)
	}
	info_path := options.automation
	if info_path == "" {
		cwd, _ := os.get_working_directory(context.temp_allocator)
		found, ok := find_automation_file(cwd, context.temp_allocator)
		if !ok {
			fmt.eprintfln(
				"editorctl: no editor is running: %s is missing below the repository root above %s",
				AUTOMATION_FILE,
				cwd,
			)
			os.exit(1)
		}
		info_path = found
	}
	info, read := read_info(info_path, context.temp_allocator)
	if !read {
		fmt.eprintfln(
			"editorctl: no editor is running: %s is missing or not an automation file",
			info_path,
		)
		os.exit(1)
	}
	if !process_alive(info.pid) {
		fmt.eprintfln(
			"editorctl: no editor is running: %s names process %d, which has exited",
			info_path,
			info.pid,
		)
		os.exit(1)
	}
	line := request_line(options, 1, context.temp_allocator)
	answer, sent := send_request(info.port, line, context.temp_allocator)
	if !sent {
		fmt.eprintfln("editorctl: the editor at 127.0.0.1:%d did not answer", info.port)
		os.exit(1)
	}
	if options.json {
		fmt.println(strings.trim_space(string(answer)))
	}
	response, decoded := decode_response(answer, context.temp_allocator)
	if !decoded {
		fmt.eprintfln("editorctl: the editor's answer is not a response: %s", answer)
		os.exit(1)
	}
	if !options.json {
		print_response(response)
	}
	if !response.ok {
		fmt.eprintfln("editorctl: %s", response.error)
		os.exit(1)
	}
}

// parse_args reads the command line. The problem is "" when it is well formed.
parse_args :: proc(args: []string) -> (o: Options, problem: string) {
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		switch {
		case arg == "--json":
			o.json = true
		case arg == "--automation" && i + 1 < len(args):
			o.automation = args[i + 1]
			i += 1
		case arg == "--view" && i + 1 < len(args):
			append(&o.views, args[i + 1])
			i += 1
		case arg == "--out" && i + 1 < len(args):
			o.out = args[i + 1]
			i += 1
		case arg == "--window" && i + 1 < len(args):
			o.window = args[i + 1]
			i += 1
		case arg == "--set" && i + 1 < len(args):
			name, _, value := strings.partition(args[i + 1], "=")
			if name == "" || value == "" {
				return o, fmt.tprintf("--set takes <name>=<value>, not %s", args[i + 1])
			}
			o.settings[name] = setting_value(value)
			i += 1
		case arg == "--position" && i + 1 < len(args):
			parts := strings.split(args[i + 1], ",", context.temp_allocator)
			o.position = make([]f64, len(parts), context.temp_allocator)
			for part, k in parts {
				v, ok := strconv.parse_f64(strings.trim_space(part))
				if !ok || len(parts) != 3 {
					return o, fmt.tprintf("--position takes three numbers, x,y,z in meters, not %s", args[i + 1])
				}
				o.position[k] = v
			}
			i += 1
		case (arg == "--yaw" || arg == "--pitch") && i + 1 < len(args):
			v, ok := strconv.parse_f64(args[i + 1])
			if !ok {
				return o, fmt.tprintf("%s takes radians, not %s", arg, args[i + 1])
			}
			if arg == "--yaw" {
				o.yaw = v
			} else {
				o.pitch = v
			}
			i += 1
		case strings.has_prefix(arg, "--"):
			return o, fmt.tprintf("unknown or incomplete option %s", arg)
		case o.command == "":
			o.command = arg
		case:
			return o, fmt.tprintf("unexpected argument %s", arg)
		}
	}
	switch o.command {
	case "status", "screenshot", "gif", "viewport", "camera", "ui", "content":
	case "":
		return o, "no command: status, screenshot, gif, viewport, camera, ui or content"
	case:
		return o, fmt.tprintf("unknown command %s: status, screenshot, gif, viewport, camera, ui or content", o.command)
	}
	if o.command != "content" && (len(o.settings) > 0) != (o.command == "viewport") {
		return o, o.command == "viewport" ? "viewport takes --set <name>=<value>" : "--set goes with viewport or content"
	}
	camera_options := o.position != nil || o.yaw != nil || o.pitch != nil
	if o.command == "camera" && o.position == nil {
		return o, "camera takes --position <x>,<y>,<z>"
	}
	if camera_options && o.command != "camera" {
		return o, "--position, --yaw and --pitch go with camera"
	}
	if len(o.views) > 0 && o.command != "screenshot" {
		return o, "--view goes with screenshot"
	}
	if o.window != "" && o.command != "ui" {
		return o, "--window goes with ui"
	}
	if o.out != "" && o.command != "screenshot" && o.command != "gif" && o.command != "ui" {
		return o, "--out goes with screenshot, gif or ui"
	}
	return o, ""
}

// setting_value is a --set value as JSON: true or false, a number, or else a string, such as a debug view's name.
setting_value :: proc(text: string) -> json.Value {
	switch text {
	case "true":
		return json.Boolean(true)
	case "false":
		return json.Boolean(false)
	}
	if v, ok := strconv.parse_f64(text); ok {
		return json.Float(v)
	}
	return json.String(text)
}

// find_automation_file walks up from start_dir to the directory with the root marker, and gives the automation file
// below it, if it exists.
find_automation_file :: proc(
	start_dir: string,
	allocator: runtime.Allocator,
) -> (
	path: string,
	ok: bool,
) {
	dir := start_dir
	for {
		marker, _ := filepath.join({dir, ROOT_MARKER}, context.temp_allocator)
		if os.exists(marker) {
			path, _ = filepath.join({dir, AUTOMATION_FILE}, allocator)
			return path, os.exists(path)
		}
		parent := filepath.dir(dir)
		if parent == dir || parent == "" {
			return "", false
		}
		dir = parent
	}
}

read_info :: proc(path: string, allocator: runtime.Allocator) -> (info: Info, ok: bool) {
	data, err := os.read_entire_file(path, allocator)
	if err != nil {
		return
	}
	if json.unmarshal(data, &info, allocator = allocator) != nil {
		return
	}
	return info, info.port > 0 && info.pid > 0
}

// process_alive is true while the process runs, so a file that an editor left behind when it died is known to be stale.
process_alive :: proc(pid: u32) -> bool {
	handle := win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if handle == nil {
		return false
	}
	defer win.CloseHandle(handle)
	code: win.DWORD
	if !win.GetExitCodeProcess(handle, &code) {
		return false
	}
	return code == STILL_ACTIVE
}

// request_line is the request as one JSON line, with --out made absolute, since the editor's working directory is
// not this one.
request_line :: proc(o: Options, id: i64, allocator: runtime.Allocator) -> []byte {
	path := o.out
	if path != "" {
		if absolute, err := os.get_absolute_path(path, context.temp_allocator); err == nil {
			path = absolute
		}
	}
	request := Request {
		id       = id,
		command  = o.command,
		views    = o.views[:],
		path     = path,
		settings = o.settings,
		position = o.position,
		yaw      = o.yaw,
		pitch    = o.pitch,
		window   = o.window,
	}
	data, _ := json.marshal(request, allocator = context.temp_allocator)
	line := make([]byte, len(data) + 1, allocator)
	copy(line, data)
	line[len(data)] = '\n'
	return line
}

// send_request connects to the editor, sends the line, and reads the answer up to its newline.
send_request :: proc(
	port: int,
	line: []byte,
	allocator: runtime.Allocator,
) -> (
	answer: []byte,
	ok: bool,
) {
	socket, err := net.dial_tcp_from_address_and_port(net.IP4_Loopback, port)
	if err != nil {
		return
	}
	defer net.close(socket)
	sent := 0
	for sent < len(line) {
		n, send_err := net.send_tcp(socket, line[sent:])
		if send_err != nil {
			return
		}
		sent += n
	}
	out := make([dynamic]byte, allocator)
	buffer: [4096]byte
	for len(out) < MAX_RESPONSE {
		n, recv_err := net.recv_tcp(socket, buffer[:])
		if recv_err != nil || n == 0 {
			break
		}
		append(&out, ..buffer[:n])
		if strings.contains_rune(string(buffer[:n]), '\n') {
			break
		}
	}
	return out[:], len(out) > 0
}

decode_response :: proc(
	data: []byte,
	allocator: runtime.Allocator,
) -> (
	response: Response,
	ok: bool,
) {
	if json.unmarshal(data, &response, allocator = allocator) != nil {
		return
	}
	return response, true
}

print_response :: proc(r: Response) {
	if status, has := r.status.?; has {
		fmt.printfln("linked: %v", status.linked)
		fmt.printfln("host: %s", status.host_state)
		fmt.printfln("mode: %s", status.mode)
		fmt.printfln("scene: %s", status.scene)
		fmt.printfln("game: %s", status.game)
		fmt.printfln("host pid: %d", status.host_pid)
	}
	if content, has := r.content.?; has {
		fmt.printfln("folder: %s", content.folder)
		fmt.printfln("search: %s", content.search)
		fmt.printfln("selection: %v", content.selection)
		fmt.printfln("items: %v", content.items)
		fmt.printfln("thumbnails waiting: %d", content.thumbnails_waiting)
		for failure in content.thumbnails_failed {
			fmt.printfln("thumbnail failed: %s", failure)
		}
	}
	for file in r.files {
		fmt.println(file)
	}
}
