package asset_format

import "core:encoding/json"
import "core:fmt"
import "core:testing"

// testdata/lexemes.json is shared with the editor's LexemeFixtureTests, so the cooker and the editor read each token the
// same way.
@(private = "file")
LEXEMES := #load("testdata/lexemes.json", string)

@(test)
every_lexeme_row_reads_as_the_fixture_says :: proc(t: ^testing.T) {
	root, err := json.parse_string(LEXEMES, .JSON, true, context.temp_allocator)
	if !testing.expectf(t, err == nil, "lexemes.json: %v", err) {
		return
	}
	rows := root.(json.Object)["rows"].(json.Array)
	testing.expect(t, len(rows) > 0)
	for entry, i in rows {
		row := entry.(json.Object)
		rule := row["rule"].(json.String)
		input := row["input"].(json.String)
		want_ok := row["ok"].(json.Boolean)
		want := row["value"]
		ok: bool
		got: json.Value
		switch rule {
		case "strip_comment", "strip_comment_word":
			got, ok = json.String(strip_comment(input, rule == "strip_comment_word")), true
		case "whole_ticks":
			n: i32
			n, ok = whole_ticks(input)
			got = json.Integer(n)
		case "whole_id":
			n: u32
			n, ok = whole_id(input)
			got = json.Integer(n)
		case "guid", "guid_ref":
			guid: Guid
			if rule == "guid" {
				guid, ok = guid_parse(input)
			} else {
				guid, ok = guid_ref(input)
			}
			got = json.String(guid_format(guid, new([32]u8, context.temp_allocator)))
		case "settings_line":
			key, value: string
			key, value, ok = settings_line(input)
			got = json.String(fmt.tprintf("%s=%s", key, value))
		case "sublevel_setting":
			key, value, is_setting := settings_line(input)
			if is_setting && sublevel_is_setting(key) {
				name, active, problem := sublevel_parse_setting(key, value)
				ok = problem == ""
				got = json.String(fmt.tprintf("%s=%s", name, active ? "active" : "inactive"))
			}
		case "sublevel_name":
			ok = sublevel_name_valid(input)
			got = nil
		case:
			testing.expectf(t, false, "row %d: no rule %q", i, rule)
			continue
		}
		testing.expectf(
			t,
			ok == want_ok,
			"row %d: %s(%q) ok = %v, not %v",
			i,
			rule,
			input,
			ok,
			want_ok,
		)
		if ok && want_ok && want != nil {
			testing.expectf(
				t,
				same_value(got, want),
				"row %d: %s(%q) = %v, not %v",
				i,
				rule,
				input,
				got,
				want,
			)
		}
	}
}

@(private = "file")
same_value :: proc(a, b: json.Value) -> bool {
	#partial switch x in a {
	case json.String:
		y, is := b.(json.String)
		return is && x == y
	case json.Integer:
		y, is := b.(json.Integer)
		return is && x == y
	}
	return false
}
