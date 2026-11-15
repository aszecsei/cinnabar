package save

import "core:testing"

@(test)
a_save_reads_back_what_was_written :: proc(t: ^testing.T) {
	entries := []Entry{{"best_time", 41.25}, {"options.invert_y", true}, {"player_name", "Mara"}}
	text := format(entries, context.temp_allocator)
	testing.expect_value(
		t,
		text,
		"save 1\nbest_time = 41.25\noptions.invert_y = true\nplayer_name = \"Mara\"\n",
	)
	read, problems := parse(text, context.temp_allocator)
	testing.expect_value(t, len(problems), 0)
	testing.expect_value(t, len(read), 3)
	for e, i in entries {
		testing.expect_value(t, read[i], e)
	}
}

@(test)
a_string_with_quotes_and_newlines_survives :: proc(t: ^testing.T) {
	value := "say \"hi\"\\\n\tline two\r"
	text := format({{"note", value}}, context.temp_allocator)
	testing.expect_value(t, text, "save 1\nnote = \"say \\\"hi\\\"\\\\\\n\\tline two\\r\"\n")
	read, problems := parse(text, context.temp_allocator)
	testing.expect_value(t, len(problems), 0)
	testing.expect_value(t, len(read), 1)
	testing.expect_value(t, read[0].value.(string), value)
}

@(test)
numbers_read_back_exactly :: proc(t: ^testing.T) {
	numbers := []f64 {
		0,
		-0.0,
		1,
		-3,
		0.1,
		1.0 / 3.0,
		1e21,
		1e-7,
		123456789.123456789,
		5e-324,
		1.7976931348623157e308,
	}
	for n in numbers {
		entries := []Entry{{"n", n}}
		read, problems := parse(format(entries, context.temp_allocator), context.temp_allocator)
		testing.expect_value(t, len(problems), 0)
		testing.expect_value(t, len(read), 1)
		testing.expect_value(t, read[0].value.(f64), n)
	}
}

@(test)
a_bad_line_is_a_problem_and_the_rest_reads :: proc(t: ^testing.T) {
	text := "save 1\n# a comment\n\nfirst = 1\nno equals sign\nbad key = 2\nthird = \"open\nfourth = nan\nfifth = true\r\nsixth = \"a\\qb\"\nlast = 0x10\n"
	entries, problems := parse(text, context.temp_allocator)
	testing.expect_value(t, len(entries), 2)
	testing.expect_value(t, entries[0].key, "first")
	testing.expect_value(t, entries[1].key, "fifth")
	testing.expect_value(t, entries[1].value.(bool), true)
	testing.expect_value(t, len(problems), 6)
	lines := []int{5, 6, 7, 8, 10, 11}
	for p, i in problems {
		testing.expect_value(t, p.line, lines[i])
	}
}

@(test)
text_without_the_header_has_no_entries :: proc(t: ^testing.T) {
	for text in ([]string{"", "first = 1\n", "save 2\nfirst = 1\n"}) {
		entries, problems := parse(text, context.temp_allocator)
		testing.expect_value(t, len(entries), 0)
		testing.expect_value(t, len(problems), 1)
		testing.expect_value(t, problems[0].line, 1)
	}
}

@(test)
a_name_with_a_slash_is_refused :: proc(t: ^testing.T) {
	for name in ([]string{"", "a/b", "..\\x", "a.b", "Upper", "has space", "x.save", "this_name_is_longer_than_thirty_two_characters"}) {
		testing.expectf(t, !check_name(name), "%q is refused", name)
	}
	for name in ([]string{"records", "key-bindings", "slot_1", "a"}) {
		testing.expectf(t, check_name(name), "%q is accepted", name)
	}
	testing.expect(t, !check_key("a b"))
	testing.expect(t, !check_key(""))
	testing.expect(t, check_key("Options.Volume_2"))
}
