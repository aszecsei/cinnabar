// Rewriting the requires that a move breaks (see docs/content/daemon-and-operations.md#moved-modules). A require names
// a path, so a move breaks the requires of the scripts that require a moved script, and the relative requires of a moved
// script. The daemon finds them from the index, works out each new string in the form that the source used, and
// rewrites only the string literal.
package cook

import "core:fmt"
import "core:os"
import "core:path/slashpath"
import "core:slice"
import "core:strings"

import cook_link "cinnabar:engine/asset/cook_link"

// Path_Move is a file or a directory that an operation moves, by absolute paths with forward slashes.
Path_Move :: struct {
	from, to: string,
}

// File_Edit is a script's new text, written at its path after the move.
File_Edit :: struct {
	path:     string,
	old, new: []byte,
}

// Require_Rewrites is what a move does to the requires: the files that it writes, and what the result says.
Require_Rewrites :: struct {
	edits:         []File_Edit,
	rewritten:     []cook_link.Rewritten_Require,
	not_rewritten: []string,
}

// moved_path is where a path is after the moves. A move of a directory moves everything in it.
moved_path :: proc(moves: []Path_Move, path: string) -> string {
	for m in moves {
		if path == m.from {
			return m.to
		}
		if strings.has_prefix(path, m.from) && path[len(m.from)] == '/' {
			return fmt.tprintf("%s%s", m.to, path[len(m.from):])
		}
	}
	return path
}

// plan_rewrites works out every require that the moves change, before anything moves. It reads each script that moves,
// or that requires one that moves, as the index has them. A script that does not parse goes to not_rewritten. It fails
// if a new string would not find its module after the move.
plan_rewrites :: proc(
	roots: []Root,
	index: ^Index,
	moves: []Path_Move,
) -> (
	rewrites: Require_Rewrites,
	error: string,
) {
	Script :: struct {
		guid:     string,
		old, new: string,
	}
	scripts := make([dynamic]Script, context.temp_allocator)
	for guid, a in index.assets {
		if a.kind != .Script || a.parent != "" {
			continue
		}
		for root in roots {
			if root.name == a.root {
				old := fmt.tprintf("%s/%s", root.dir, a.path)
				append(&scripts, Script{guid, old, moved_path(moves, old)})
				break
			}
		}
	}
	// In path order, so the result is in script and line order.
	slice.sort_by(scripts[:], proc(a, b: Script) -> bool {return a.new < b.new})
	old_by_path := make(map[string]int, len(scripts), context.temp_allocator)
	new_by_path := make(map[string]int, len(scripts), context.temp_allocator)
	moved := make(map[string]bool, context.temp_allocator)
	for s, i in scripts {
		old_by_path[s.old] = i
		new_by_path[s.new] = i
		if s.new != s.old {
			moved[s.guid] = true
		}
	}
	if len(moved) == 0 {
		return
	}
	edits := make([dynamic]File_Edit, context.temp_allocator)
	rewritten := make([dynamic]cook_link.Rewritten_Require, context.temp_allocator)
	not_rewritten := make([dynamic]string, context.temp_allocator)
	for s in scripts {
		candidate := moved[s.guid]
		for d in index.assets[s.guid].dependencies {
			candidate ||= moved[d]
		}
		if !candidate {
			continue
		}
		source, err := os.read_entire_file(s.old, context.temp_allocator)
		if err != nil {
			append(&not_rewritten, display(roots, s.new))
			continue
		}
		found := Script_Source {
			path     = s.old,
			source   = source,
			requires = make([dynamic]Found_Require, context.temp_allocator),
		}
		problems: Problems
		if !find_requires(&found, &problems) {
			append(&not_rewritten, display(roots, s.new))
			continue
		}
		Splice :: struct {
			start, end: int,
			text:       string,
		}
		splices := make([dynamic]Splice, context.temp_allocator)
		for r in found.requires {
			target, message := resolve_require(old_by_path, s.old, r.path)
			// A require that is broken already stays as it is: the next pass reports it.
			if message != "" {
				continue
			}
			t := scripts[target]
			if t.new == t.old && s.new == s.old {
				continue
			}
			path := new_require_path(r.path, s.new, t.new)
			if path == r.path {
				continue
			}
			again, again_message := resolve_require(new_by_path, s.new, path)
			if again_message != "" || again != target {
				return {}, fmt.tprintf("cannot rewrite the require %q at %s:%d as %q", r.path, display(roots, s.old), r.line, path)
			}
			text, literal_ok := literal_with(string(source[r.start:r.end]), path)
			if !literal_ok {
				return {}, fmt.tprintf("cannot find the string of the require %q at %s:%d", r.path, display(roots, s.old), r.line)
			}
			append(&splices, Splice{r.start, r.end, text})
			append(
				&rewritten,
				cook_link.Rewritten_Require {
					path = display(roots, s.new),
					line = u32(r.line),
					old = r.path,
					new = path,
				},
			)
		}
		if len(splices) == 0 {
			continue
		}
		slice.sort_by(splices[:], proc(a, b: Splice) -> bool {return a.start < b.start})
		b := strings.builder_make(context.temp_allocator)
		at := 0
		for sp in splices {
			strings.write_bytes(&b, source[at:sp.start])
			strings.write_string(&b, sp.text)
			at = sp.end
		}
		strings.write_bytes(&b, source[at:])
		append(&edits, File_Edit{s.new, source, b.buf[:]})
	}
	return {edits[:], rewritten[:], not_rewritten[:]}, ""
}

// new_require_path is a require's string after a move of the requirer or of its target, by their paths after it. It
// keeps the form of the old string: relative, @self/, or the alias that it names. When @self or the alias no longer
// reaches the target, it falls back to a relative path.
new_require_path :: proc(old, requirer, target: string) -> string {
	module := module_of(target)
	if strings.has_prefix(old, "@") {
		slash := strings.index_byte(old, '/')
		alias := old[:slash if slash >= 0 else len(old)]
		name := strings.to_lower(alias[1:], context.temp_allocator)
		base: string
		found: bool
		if name == "self" {
			base, found = module_of(requirer), true
		} else {
			message: string
			base, found, message = find_alias(
				slashpath.dir(requirer, context.temp_allocator),
				name,
			)
			found &&= message == ""
		}
		if found {
			if module == base {
				return alias
			}
			if strings.has_prefix(module, base) && module[len(base)] == '/' {
				return fmt.tprintf("%s%s", alias, module[len(base):])
			}
		}
	}
	return relative_require(slashpath.dir(module_of(requirer), context.temp_allocator), module)
}

// relative_require is a require from a module whose parent is dir to the module at path, which starts with ./ or ../.
relative_require :: proc(dir, path: string) -> string {
	from := strings.split(dir, "/", context.temp_allocator)
	to := strings.split(path, "/", context.temp_allocator)
	common := 0
	for common < len(from) && common < len(to) && from[common] == to[common] {
		common += 1
	}
	// The module is the parent itself, which a require names from its own parent.
	if common == len(to) {
		common -= 1
	}
	b := strings.builder_make(context.temp_allocator)
	if common == len(from) {
		strings.write_string(&b, "./")
	}
	for _ in common ..< len(from) {
		strings.write_string(&b, "../")
	}
	strings.write_string(&b, strings.join(to[common:], "/", context.temp_allocator))
	return strings.to_string(b)
}

// literal_with is a string literal with the delimiters of the old one, which is quoted or a long bracket string, and
// the new text. It fails if the old text is not a literal.
literal_with :: proc(old, text: string) -> (literal: string, ok: bool) {
	if len(old) < 2 {
		return
	}
	switch old[0] {
	case '"', '\'', '`':
		quote := old[:1]
		escaped, _ := strings.replace_all(text, "\\", "\\\\", context.temp_allocator)
		escaped, _ = strings.replace_all(
			escaped,
			quote,
			fmt.tprintf("\\%s", quote),
			context.temp_allocator,
		)
		return fmt.tprintf("%s%s%s", quote, escaped, quote), true
	case '[':
		open := strings.index_byte(old[1:], '[')
		if open < 0 {
			return
		}
		size := open + 2
		if len(old) < size * 2 || strings.contains(text, old[len(old) - size:]) {
			return
		}
		return fmt.tprintf("%s%s%s", old[:size], text, old[len(old) - size:]), true
	}
	return
}
