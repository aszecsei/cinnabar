package cook

import "core:fmt"
import "core:hash"
import "core:os"

import format "cinnabar:engine/asset/format"

// UI documents are .ui text files: a tree of boxes, text and images in a pseudo-XML with named styles (see
// docs/content/kinds/ui-documents.md#ui-documents). The cooker checks one with format.ui_parse, checks that its fonts and
// images are fonts and textures, and writes a Ui blob.
UI_COOK_VERSION :: "ui 1"

// UI_TEMPLATE is a new UI document's text: a panel in the middle of the screen with a title and a button. Its text has
// no font until the author gives the root one.
UI_TEMPLATE :: `ui 1
<!-- Give <ui> a font, such as font=$<the font's GUID>, for its text to draw. -->
<ui size="20" color="#ffffff">
	<style name="button" fill="#1c2030e0" radius="6" padding="10 16"/>
	<style name="button:focus" fill="#e2423a"/>
	<style name="button:hover" fill="#2a3048"/>

	<column id="panel" anchor="center" fill="#0b0d14e0" radius="12" padding="24" gap="12" cross="stretch">
		<text size="28" text_align="center">Title</text>
		<button id="ok" click="ok">OK</button>
	</column>
</ui>
`

cook_ui_documents :: proc(options: Cook_Options, assets: []Asset_Source, pass: ^Pass) -> bool {
	problems := &pass.problems
	out_dir := config_dir(options)
	documents := assets_of(assets, .Ui)
	if len(documents) > 0 {
		if err := os.make_directory_all(out_dir); err != nil && err != .Exist {
			report_error(problems, out_dir, 0, 0, "%v", err)
			return false
		}
	}
	kinds := make(map[format.Guid]format.Asset_Kind, len(assets), context.temp_allocator)
	for a in assets {
		kinds[a.meta.guid] = a.kind
		for s in a.meta.subassets {
			kinds[s.guid] = format.subasset_kind_of(s.kind)
		}
	}
	ok := true
	step_begin(pass, .Ui, "", len(documents))
	for i in documents {
		defer step_advance(pass)
		if !cook_ui_document(&assets[i], out_dir, kinds, pass) {
			assets[i].failed = true
			ok = false
		}
	}
	return ok
}

@(private = "file")
cook_ui_document :: proc(a: ^Asset_Source, out_dir: string, kinds: map[format.Guid]format.Asset_Kind, pass: ^Pass) -> bool {
	problems := &pass.problems
	settings_ok := check_settings(a^, problems)
	document, parse_problems, parsed := format.ui_parse(string(a.source))
	for p in parse_problems {
		if p.error {
			report_error(problems, a.path, p.line, p.column, "%s", p.message)
		} else {
			report_warning(problems, a.path, p.line, p.column, "%s", p.message)
		}
	}
	// A font is a font, and an image a texture. An asset that is not in the roots may come later, so it only warns.
	for n in document.nodes {
		check_ui_assets(a, n.props, kinds, problems, &parsed)
	}
	for s in document.styles {
		check_ui_assets(a, s.props, kinds, problems, &parsed)
	}
	// A document with errors keeps its old blob, so the running game keeps the last good version.
	if !parsed || !settings_ok {
		return false
	}
	key := hash.fnv64a(transmute([]byte)fmt.tprintf("%s\x00%s\x00%x\x00", UI_COOK_VERSION, a.name, format.ui_layout()))
	key = hash.fnv64a(a.source, key)
	guid := a.meta.guid
	key = hash.fnv64a(guid[:], key)
	output := fmt.tprintf("%s/%s.blob", out_dir, guid_text(guid))
	if cooked_key(output, .Ui, format.ui_layout()) == key && !pass.force[guid] {
		pass.current[.Ui] += 1
		return true
	}
	blob := format.ui_write({guid = guid, key = key, document = document, source_path = a.name}, context.temp_allocator)
	if !write_blob(output, blob) {
		return false
	}
	pass.cooked[.Ui] += 1
	return true
}

// check_ui_assets checks the fonts and images that attributes name, and adds them to the document's dependencies.
@(private = "file")
check_ui_assets :: proc(a: ^Asset_Source, props: []format.Ui_Prop_Contents, kinds: map[format.Guid]format.Asset_Kind, problems: ^Problems, ok: ^bool) {
	for p in props {
		want: format.Asset_Kind
		#partial switch p.attr {
		case .Font:
			want = .Font
		case .Image:
			want = .Texture
		case:
			continue
		}
		guid, valid := format.ui_parse_guid(p.value)
		if !valid {
			continue
		}
		kind, found := kinds[guid]
		switch {
		case !found:
			report_warning(problems, a.path, p.line, p.column, "%s %s is not an asset in the content roots", format.UI_ATTRS[p.attr].name, p.value)
		case kind != want:
			report_error(problems, a.path, p.line, p.column, "%s %s is a %v, not a %v", format.UI_ATTRS[p.attr].name, p.value, kind, want)
			ok^ = false
		}
		append(&a.dependencies, guid)
	}
}
