package asset_format

// The token rules that several text formats share. The editor has a C# twin of each: TextLine.StripComment,
// CutsceneFile.TryParseTicks and TryParseId, AssetGuid.TryParse and TryParseRef, ProjectSettings.TryParseLine and
// SceneFile.IsSublevelName. testdata/lexemes.json holds rows that both sides' tests run, so the two cannot drift.

// strip_comment is a line without a # and what follows it, outside of quotes. With hash_in_word, as a cutscene's lines
// are read, a # inside a word, after a character that is not a space or a tab, is not a comment, so a possess's path,
// @<scene guid>/<instance>#<entity>, stays whole.
strip_comment :: proc(line: string, hash_in_word := false) -> string {
	quoted := false
	for i := 0; i < len(line); i += 1 {
		switch {
		case quoted && line[i] == '\\':
			// The escaped character does not end the string.
			i += 1
		case line[i] == '"':
			quoted = !quoted
		case line[i] == '#' &&
		     !quoted &&
		     (!hash_in_word || i == 0 || line[i - 1] == ' ' || line[i - 1] == '\t'):
			return line[:i]
		}
	}
	return line
}

// whole_ticks reads a time in ticks: a whole number from 0 to 2147483647, in the digits 0 to 9 alone.
whole_ticks :: proc(text: string) -> (ticks: i32, ok: bool) {
	n := whole_number(text) or_return
	return i32(n), true
}

// whole_id reads an ID: a whole number from 1 to 2147483647, in the digits 0 to 9 alone.
whole_id :: proc(text: string) -> (id: u32, ok: bool) {
	n := whole_number(text) or_return
	if n == 0 {
		return
	}
	return u32(n), true
}

// guid_ref reads an asset's GUID as the text formats write it: $ and 32 hex digits. A format that takes $0 for no asset
// checks for it first.
guid_ref :: proc(text: string) -> (Guid, bool) {
	if len(text) != 1 + 2 * len(Guid) || text[0] != '$' {
		return {}, false
	}
	return guid_parse(text[1:])
}

// whole_number reads digits, with no sign, separator or space, up to max(i32).
@(private = "file")
whole_number :: proc(text: string) -> (n: i64, ok: bool) {
	if text == "" {
		return
	}
	for c in transmute([]byte)text {
		if c < '0' || c > '9' {
			return
		}
		n = n * 10 + i64(c - '0')
		if n > i64(max(i32)) {
			return
		}
	}
	return n, true
}
