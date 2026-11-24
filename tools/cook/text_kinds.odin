package cook

import "core:fmt"
import "core:hash"

import format "cinnabar:engine/asset/format"

// Text_Cook is what the one skeleton of a simple text kind needs: its kind, its cook version and its blob's layout.
// Each of these kinds parses one text file into one blob, with no settings or tools in the key.
Text_Cook :: struct {
	kind:    format.Asset_Kind,
	version: string,
	layout:  u64,
}

// Text_Step is a kind's own part of a cook: it parses the asset, reports its problems, records what it depends on,
// checks what it names, and builds its blob with the GUID, the key and the source path. It gives ok = false on any
// problem. It runs even when the asset's settings are bad, so its problems are reported at every cook.
Text_Step :: #type proc(
	a: ^Asset_Source,
	key: u64,
	data: rawptr,
	pass: ^Pass,
) -> (
	blob: []byte,
	ok: bool,
)

// text_key is a simple text kind's cache key, which its blob's header holds: its version, name and layout, then its
// source, then its GUID.
text_key :: proc(c: Text_Cook, a: Asset_Source) -> u64 {
	key := hash.fnv64a(
		transmute([]byte)fmt.tprintf("%s\x00%s\x00%x\x00", c.version, a.name, c.layout),
	)
	key = hash.fnv64a(source_of(a), key)
	guid := a.meta.guid
	return hash.fnv64a(guid[:], key)
}

// cook_text_kind cooks the assets of a simple text kind that the pass looks at, each through step, which data is
// passed to. It reports every failure, and returns false if any.
cook_text_kind :: proc(
	options: Cook_Options,
	pass: ^Pass,
	c: Text_Cook,
	data: rawptr,
	step: Text_Step,
) -> bool {
	out_dir := config_dir(options)
	indices := carry_kind(pass, {c.kind})
	if len(indices) > 0 && !make_output_dir(pass, out_dir, {c.kind}) {
		return false
	}
	ok := true
	step_begin(pass, c.kind, "", len(indices))
	for i in indices {
		defer step_advance(pass)
		asset_source(pass, i)
		result := cook_text_asset(&pass.assets[i], out_dir, pass, c, data, step)
		settle(pass, i, result)
		ok &&= !asset_failed(result)
	}
	return ok
}

@(private = "file")
cook_text_asset :: proc(
	a: ^Asset_Source,
	out_dir: string,
	pass: ^Pass,
	c: Text_Cook,
	data: rawptr,
	step: Text_Step,
) -> Asset_Result {
	settings_ok := check_settings(a^, &pass.problems)
	key := text_key(c, a^)
	blob, step_ok := step(a, key, data, pass)
	// An asset with errors keeps its old blob, so the running game keeps the last good version.
	if !step_ok || !settings_ok {
		return .Failed
	}
	guid := a.meta.guid
	output := fmt.tprintf("%s/%s.blob", out_dir, guid_text(guid))
	if cooked_key(output, c.kind, c.layout) == key && !pass.force[guid] {
		return .Current
	}
	if !write_blob(output, blob) {
		return .Failed
	}
	return .Cooked
}
