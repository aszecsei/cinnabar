package asset_format

import "core:mem/virtual"

// blob_references is the assets that a blob names, which the runtime loads when it uses the blob: a script's requires,
// a scene's or prefab's behaviours and asset fields, a material's textures, an instance's material and textures, an
// effect's materials, meshes and textures, an animation's skin, an animation graph's clips, a font's or sprite sheet's
// atlas, and a UI document's fonts and images. A GUID appears once, and the zero GUID never. ok is false for a blob
// that does not check.
blob_references :: proc(data: []byte, allocator := context.allocator) -> (references: []Guid, ok: bool) {
	header := blob_header(data) or_return
	list := make([dynamic]Guid, allocator)
	defer if !ok {
		delete(list)
	}
	add :: proc(list: ^[dynamic]Guid, guid: Guid) {
		if guid == {} {
			return
		}
		for g in list {
			if g == guid {
				return
			}
		}
		append(list, guid)
	}
	#partial switch header.kind {
	case .Script:
		blob := script_view(data) or_return
		for r in script_requires(data, blob) {
			add(&list, r.target)
		}
	case .Scene, .Prefab:
		arena: virtual.Arena
		if virtual.arena_init_growing(&arena) != nil {
			return
		}
		defer virtual.arena_destroy(&arena)
		scene := scene_read(data, virtual.arena_allocator(&arena)) or_return
		for e in scene.entities {
			for c in e.components {
				for f in c.fields {
					if f.value.kind == .Asset {
						add(&list, f.value.asset)
					}
				}
			}
			for b in e.behaviours {
				add(&list, b.script)
				for f in b.fields {
					if f.value.kind == .Asset {
						add(&list, f.value.asset)
					}
				}
			}
		}
	case .Material:
		blob := material_view(data) or_return
		for t in material_textures(data, blob) {
			add(&list, t.guid)
		}
	case .Material_Instance:
		blob := material_instance_view(data) or_return
		add(&list, blob.material)
		for t in instance_textures(data, blob) {
			add(&list, t.guid)
		}
	case .Effect:
		blob := effect_view(data) or_return
		for e in effect_emitters(data, blob) {
			add(&list, e.material)
			add(&list, e.mesh)
			add(&list, e.texture)
		}
	case .Animation:
		blob := animation_view(data) or_return
		add(&list, blob.skin)
	case .Animation_Graph:
		blob := animation_graph_view(data) or_return
		for c in animation_graph_clips(data, blob) {
			add(&list, c.clip)
		}
	case .Font:
		blob := font_view(data) or_return
		add(&list, blob.atlas)
	case .Sprite_Sheet:
		blob := sprite_sheet_view(data) or_return
		add(&list, blob.atlas)
	case .Ui:
		blob := ui_view(data) or_return
		for p in ui_props(data, blob) {
			if UI_ATTRS[p.attr].kind == .Guid {
				if guid, parsed := ui_parse_guid(blob_string(data, p.value)); parsed {
					add(&list, guid)
				}
			}
		}
	}
	return list[:], true
}
