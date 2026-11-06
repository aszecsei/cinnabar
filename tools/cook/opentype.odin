package cook

// What the font cook reads of an OpenType file itself, beside what vendor:stb/truetype reads: its table directory, and
// the glyphs that its substitutions can make, so the atlas holds every glyph that shaping gives (see
// docs/content/kinds/fonts.md#glyphs).

// The GSUB features that the runtime's shaper, kb_text_shape, applies to text by default, of every script's. A
// substitution in another feature, such as dlig or smcp, makes glyphs that shaped text never shows.
OPENTYPE_DEFAULT_FEATURES :: [?]string{"rvrn", "ccmp", "locl", "rlig", "liga", "clig", "calt", "rclt", "ltra", "ltrm", "frac", "numr", "dnom"}

// Font_Tables is where a font's tables are in its file.
Font_Tables :: struct {
	data:   []byte,
	tables: map[string][]byte,
}

// opentype_u16 and opentype_u32 read big-endian numbers, and 0 past the end, so a truncated table reads as empty.
@(private = "file")
opentype_u16 :: proc(data: []byte, offset: int) -> int {
	if offset < 0 || offset + 2 > len(data) {
		return 0
	}
	return int(data[offset]) << 8 | int(data[offset + 1])
}

@(private = "file")
opentype_u32 :: proc(data: []byte, offset: int) -> int {
	return opentype_u16(data, offset) << 16 | opentype_u16(data, offset + 2)
}

@(private = "file")
opentype_at :: proc(data: []byte, offset: int) -> []byte {
	if offset <= 0 || offset >= len(data) {
		return nil
	}
	return data[offset:]
}

// font_tables reads the table directory of the font that starts at offset in a file, which is 0 but in a collection.
font_tables :: proc(data: []byte, offset: int, allocator := context.temp_allocator) -> (tables: Font_Tables, ok: bool) {
	tables.data = data
	tables.tables = make(map[string][]byte, allocator)
	count := opentype_u16(data, offset + 4)
	if offset + 12 + count * 16 > len(data) {
		return
	}
	for i in 0 ..< count {
		record := offset + 12 + i * 16
		tag := string(data[record:][:4])
		start, size := opentype_u32(data, record + 8), opentype_u32(data, record + 12)
		if start + size > len(data) {
			return
		}
		tables.tables[tag] = data[start:][:size]
	}
	return tables, true
}

// opentype_coverage gives a coverage table's glyphs, each with its coverage index.
@(private = "file")
opentype_coverage :: proc(table: []byte, each: proc(glyph, index: int, data: rawptr), data: rawptr) {
	switch opentype_u16(table, 0) {
	case 1:
		for i in 0 ..< opentype_u16(table, 2) {
			each(opentype_u16(table, 4 + i * 2), i, data)
		}
	case 2:
		for i in 0 ..< opentype_u16(table, 2) {
			record := 4 + i * 6
			first, last, index := opentype_u16(table, record), opentype_u16(table, record + 2), opentype_u16(table, record + 4)
			for g in first ..= last {
				each(g, index + g - first, data)
			}
		}
	}
}

// Closure is the glyphs that a substitution's walk has, and the GSUB lookups that the default features reach.
@(private = "file")
Closure :: struct {
	glyphs:  ^[dynamic]bool,
	added:   bool,
	lookups: []byte,
	active:  [dynamic]bool,
	// For the subtable that the walk is in: its coverage index's glyph, when it has it.
	covered: map[int]int,
}

@(private = "file")
closure_has :: proc(c: ^Closure, glyph: int) -> bool {
	return glyph >= 0 && glyph < len(c.glyphs) && c.glyphs[glyph]
}

@(private = "file")
closure_add :: proc(c: ^Closure, glyph: int) {
	if glyph >= 0 && glyph < len(c.glyphs) && !c.glyphs[glyph] {
		c.glyphs[glyph] = true
		c.added = true
	}
}

// gsub_closure adds to glyphs, which a font's glyph count sizes, every glyph that the GSUB table's default features can
// substitute for the glyphs that it has, until no more come. A single, multiple or alternate substitution adds its
// output when its input is in the set, and a ligature when all of its components are. A contextual lookup's nested
// lookups count as active, whatever their context, so the walk may keep a glyph that no text makes, but never misses
// one. A font without a GSUB table substitutes nothing.
gsub_closure :: proc(gsub: []byte, glyphs: ^[dynamic]bool) {
	if len(gsub) < 10 {
		return
	}
	features := opentype_at(gsub, opentype_u16(gsub, 6))
	lookups := opentype_at(gsub, opentype_u16(gsub, 8))
	c := Closure {
		glyphs  = glyphs,
		lookups = lookups,
		active  = make([dynamic]bool, opentype_u16(lookups, 0), context.temp_allocator),
		covered = make(map[int]int, context.temp_allocator),
	}
	for i in 0 ..< opentype_u16(features, 0) {
		record := 2 + i * 6
		tag := string(features[record:][:4]) if record + 4 <= len(features) else ""
		wanted := false
		for f in OPENTYPE_DEFAULT_FEATURES {
			wanted ||= tag == f
		}
		if !wanted {
			continue
		}
		feature := opentype_at(features, opentype_u16(features, record + 4))
		for j in 0 ..< opentype_u16(feature, 2) {
			activate(&c, opentype_u16(feature, 4 + j * 2))
		}
	}
	for {
		c.added = false
		for active, i in c.active {
			if active {
				walk_lookup(&c, i)
			}
		}
		if !c.added {
			return
		}
	}

	activate :: proc(c: ^Closure, index: int) {
		if index >= len(c.active) || c.active[index] {
			return
		}
		c.active[index] = true
		lookup := opentype_at(c.lookups, opentype_u16(c.lookups, 2 + index * 2))
		kind := opentype_u16(lookup, 0)
		for s in 0 ..< opentype_u16(lookup, 4) {
			subtable := opentype_at(lookup, opentype_u16(lookup, 6 + s * 2))
			subtable_kind := kind
			if kind == 7 {
				subtable_kind = opentype_u16(subtable, 2)
				subtable = opentype_at(subtable, opentype_u32(subtable, 4))
			}
			if subtable_kind == 5 || subtable_kind == 6 {
				nested_lookups(c, subtable, subtable_kind)
			}
		}
	}

	// nested_lookups activates the lookups that a contextual subtable's rules call.
	nested_lookups :: proc(c: ^Closure, t: []byte, kind: int) {
		// records activates count SequenceLookupRecords at offset.
		records :: proc(c: ^Closure, t: []byte, offset, count: int) {
			for i in 0 ..< count {
				activate(c, opentype_u16(t, offset + i * 4 + 2))
			}
		}
		// rule activates a SequenceRule's records (kind 5) or a ChainedSequenceRule's (kind 6).
		rule :: proc(c: ^Closure, r: []byte, kind: int) {
			if kind == 5 {
				glyph_count, lookup_count := opentype_u16(r, 0), opentype_u16(r, 2)
				records(c, r, 4 + (glyph_count - 1) * 2, lookup_count)
				return
			}
			at := 0
			at += 2 + opentype_u16(r, at) * 2
			at += 2 + max(opentype_u16(r, at) - 1, 0) * 2
			at += 2 + opentype_u16(r, at) * 2
			records(c, r, at + 2, opentype_u16(r, at))
		}
		switch opentype_u16(t, 0) {
		case 1, 2:
			// Rule sets, each of rules.
			sets_at := kind == 5 ? (opentype_u16(t, 0) == 1 ? 4 : 6) : (opentype_u16(t, 0) == 1 ? 4 : 10)
			for i in 0 ..< opentype_u16(t, sets_at) {
				set := opentype_at(t, opentype_u16(t, sets_at + 2 + i * 2))
				for j in 0 ..< opentype_u16(set, 0) {
					rule(c, opentype_at(set, opentype_u16(set, 2 + j * 2)), kind)
				}
			}
		case 3:
			if kind == 5 {
				glyph_count, lookup_count := opentype_u16(t, 2), opentype_u16(t, 4)
				records(c, t, 6 + glyph_count * 2, lookup_count)
				return
			}
			at := 2
			at += 2 + opentype_u16(t, at) * 2
			at += 2 + opentype_u16(t, at) * 2
			at += 2 + opentype_u16(t, at) * 2
			records(c, t, at + 2, opentype_u16(t, at))
		}
	}

	walk_lookup :: proc(c: ^Closure, index: int) {
		lookup := opentype_at(c.lookups, opentype_u16(c.lookups, 2 + index * 2))
		kind := opentype_u16(lookup, 0)
		for s in 0 ..< opentype_u16(lookup, 4) {
			subtable := opentype_at(lookup, opentype_u16(lookup, 6 + s * 2))
			subtable_kind := kind
			if kind == 7 {
				subtable_kind = opentype_u16(subtable, 2)
				subtable = opentype_at(subtable, opentype_u32(subtable, 4))
			}
			walk_subtable(c, subtable, subtable_kind)
		}
	}

	walk_subtable :: proc(c: ^Closure, t: []byte, kind: int) {
		format := opentype_u16(t, 0)
		// covered maps each coverage index whose glyph the set has to the glyph.
		clear(&c.covered)
		if kind == 1 || kind == 2 || kind == 3 || kind == 4 || kind == 8 {
			opentype_coverage(opentype_at(t, opentype_u16(t, 2)), proc(glyph, index: int, data: rawptr) {
				c := (^Closure)(data)
				if closure_has(c, glyph) {
					c.covered[index] = glyph
				}
			}, c)
		}
		switch kind {
		case 1:
			if format == 1 {
				delta := opentype_u16(t, 4)
				for _, glyph in c.covered {
					closure_add(c, (glyph + delta) & 0xffff)
				}
			} else if format == 2 {
				for index in c.covered {
					closure_add(c, opentype_u16(t, 6 + index * 2))
				}
			}
		case 2, 3:
			// A multiple substitution's sequence and an alternate substitution's set have one layout: a count, then glyphs.
			for index in c.covered {
				sequence := opentype_at(t, opentype_u16(t, 6 + index * 2))
				for i in 0 ..< opentype_u16(sequence, 0) {
					closure_add(c, opentype_u16(sequence, 2 + i * 2))
				}
			}
		case 4:
			for index in c.covered {
				set := opentype_at(t, opentype_u16(t, 6 + index * 2))
				ligatures: for i in 0 ..< opentype_u16(set, 0) {
					ligature := opentype_at(set, opentype_u16(set, 2 + i * 2))
					for j in 1 ..< opentype_u16(ligature, 2) {
						if !closure_has(c, opentype_u16(ligature, 4 + (j - 1) * 2)) {
							continue ligatures
						}
					}
					closure_add(c, opentype_u16(ligature, 0))
				}
			}
		case 8:
			at := 4
			at += 2 + opentype_u16(t, at) * 2
			at += 2 + opentype_u16(t, at) * 2
			for index in c.covered {
				closure_add(c, opentype_u16(t, at + 2 + index * 2))
			}
		}
	}
}
