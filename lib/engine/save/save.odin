// Package save is the player's data on disk (see docs/scripting/api.md#save): a text format of named values, and the
// Save script library that reads and writes it. The engine keeps no store. A script holds the data in its own tables
// and asks for a file when it reads or saves.
//
// A file is the line "save 1", then one `key = value` line per entry. A value is a number, true, false, or a string in
// double quotes. Blank lines and lines that start with # are skipped.
package save

import "base:runtime"
import "core:strconv"
import "core:strings"

// The most characters in a save's name, the file's stem.
MAX_NAME :: 32

// The first line of every file, which names the format's version.
HEADER :: "save 1"

// Value is what an entry holds.
Value :: union {
	f64,
	bool,
	string,
}

// Entry is one `key = value` line.
Entry :: struct {
	key:   string,
	value: Value,
}

// Problem is a line that parse could not read.
Problem :: struct {
	line:    int,
	message: string,
}

// check_name is whether name is a save's name: 1 to MAX_NAME of a to z, 0 to 9, _ and -. It becomes the file's stem,
// so it cannot hold a slash or a dot.
check_name :: proc(name: string) -> bool {
	if len(name) < 1 || len(name) > MAX_NAME {
		return false
	}
	for c in transmute([]byte)name {
		switch c {
		case 'a' ..= 'z', '0' ..= '9', '_', '-':
		case:
			return false
		}
	}
	return true
}

// check_key is whether key is an entry's key: one or more of A to Z, a to z, 0 to 9, _ and a dot.
check_key :: proc(key: string) -> bool {
	if len(key) == 0 {
		return false
	}
	for c in transmute([]byte)key {
		switch c {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '_', '.':
		case:
			return false
		}
	}
	return true
}

// format is the text of entries, in their order, in allocator. The keys must pass check_key, and a number must be
// finite. A number is written in the shortest form that reads back as the same value.
format :: proc(entries: []Entry, allocator: runtime.Allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, HEADER)
	strings.write_byte(&b, '\n')
	for e in entries {
		strings.write_string(&b, e.key)
		strings.write_string(&b, " = ")
		switch v in e.value {
		case f64:
			buffer: [32]byte
			// write_float gives a positive number a leading +.
			strings.write_string(
				&b,
				strings.trim_left(strconv.write_float(buffer[:], v, 'g', -1, 64), "+"),
			)
		case bool:
			strings.write_string(&b, "true" if v else "false")
		case string:
			write_quoted(&b, v)
		}
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

@(private)
write_quoted :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for c in transmute([]byte)s {
		switch c {
		case '"':
			strings.write_string(b, `\"`)
		case '\\':
			strings.write_string(b, `\\`)
		case '\n':
			strings.write_string(b, `\n`)
		case '\r':
			strings.write_string(b, `\r`)
		case '\t':
			strings.write_string(b, `\t`)
		case:
			strings.write_byte(b, c)
		}
	}
	strings.write_byte(b, '"')
}

// parse reads text into entries, in the file's order, and the problems with its lines. A malformed line is a problem
// with its number, and the lines after it still read. Text whose first line is not the header has no entries and one
// problem, since it is not a file of this format. The entries' keys and strings, and the problems' messages, are in
// allocator.
parse :: proc(
	text: string,
	allocator: runtime.Allocator,
) -> (
	entries: [dynamic]Entry,
	problems: [dynamic]Problem,
) {
	entries = make([dynamic]Entry, allocator)
	problems = make([dynamic]Problem, allocator)
	rest := text
	number := 0
	for len(rest) > 0 || number == 0 {
		line: string
		if i := strings.index_byte(rest, '\n'); i >= 0 {
			line, rest = rest[:i], rest[i + 1:]
		} else {
			line, rest = rest, ""
		}
		number += 1
		line = strings.trim_right(line, "\r")
		if number == 1 {
			if line != HEADER {
				append(&problems, Problem{1, `the first line must be "save 1"`})
				return
			}
			continue
		}
		trimmed := strings.trim_space(line)
		if trimmed == "" || trimmed[0] == '#' {
			continue
		}
		entry, message := parse_line(trimmed, allocator)
		if message != "" {
			append(&problems, Problem{number, message})
			continue
		}
		append(&entries, entry)
	}
	return
}

// parse_line reads one line that is not blank or a comment, or says why it cannot.
@(private)
parse_line :: proc(line: string, allocator: runtime.Allocator) -> (entry: Entry, message: string) {
	equals := strings.index_byte(line, '=')
	if equals < 0 {
		return {}, "expected `key = value`"
	}
	key := strings.trim_space(line[:equals])
	if !check_key(key) {
		return {}, "the key has a character other than A to Z, a to z, 0 to 9, _ and ."
	}
	literal := strings.trim_space(line[equals + 1:])
	value: Value
	switch {
	case literal == "true":
		value = true
	case literal == "false":
		value = false
	case len(literal) > 0 && literal[0] == '"':
		s, ok := unquote(literal, allocator)
		if !ok {
			return {}, `the string is not closed, or has an escape other than \" \\ \n \r \t`
		}
		value = s
	case:
		n, ok := parse_number(literal)
		if !ok {
			return {}, "the value is not a number, true, false or a string in quotes"
		}
		value = n
	}
	return Entry{strings.clone(key, allocator), value}, ""
}

// parse_number reads a decimal number: digits, a sign, a point and an exponent, and nothing else that strconv would
// take, such as inf, nan, hex or underscores.
@(private)
parse_number :: proc(literal: string) -> (n: f64, ok: bool) {
	if len(literal) == 0 {
		return
	}
	for c in transmute([]byte)literal {
		switch c {
		case '0' ..= '9', '+', '-', '.', 'e', 'E':
		case:
			return
		}
	}
	n, ok = strconv.parse_f64(literal)
	// An exponent too large to hold reads as infinity, which a save never holds.
	return n, ok && n - n == 0
}

// unquote reads a string literal, which ends at the line's end with its closing quote.
@(private)
unquote :: proc(literal: string, allocator: runtime.Allocator) -> (s: string, ok: bool) {
	b := strings.builder_make(allocator)
	i := 1
	for i < len(literal) {
		c := literal[i]
		switch c {
		case '"':
			if i + 1 != len(literal) {
				return
			}
			return strings.to_string(b), true
		case '\\':
			i += 1
			if i >= len(literal) {
				return
			}
			switch literal[i] {
			case '"':
				strings.write_byte(&b, '"')
			case '\\':
				strings.write_byte(&b, '\\')
			case 'n':
				strings.write_byte(&b, '\n')
			case 'r':
				strings.write_byte(&b, '\r')
			case 't':
				strings.write_byte(&b, '\t')
			case:
				return
			}
		case:
			strings.write_byte(&b, c)
		}
		i += 1
	}
	return
}
