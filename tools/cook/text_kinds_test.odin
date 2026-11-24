package cook

import "core:fmt"
import "core:hash"
import "core:testing"

import format "cinnabar:engine/asset/format"

// old_text_key is the key that each simple text kind computed for itself before cook_text_kind, as it was written in
// each kind's file. A blob cooked before keeps its key, so it is not cooked again.
@(private = "file")
old_text_key :: proc(version: string, layout: u64, a: Asset_Source) -> u64 {
	key := hash.fnv64a(transmute([]byte)fmt.tprintf("%s\x00%s\x00%x\x00", version, a.name, layout))
	key = hash.fnv64a(source_of(a), key)
	guid := a.meta.guid
	return hash.fnv64a(guid[:], key)
}

@(private = "file")
key_asset :: proc() -> Asset_Source {
	a: Asset_Source
	a.name = "game:ai/guard.text"
	a.source = transmute([]byte)string("a source\n")
	a.meta.guid = format.Guid{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
	return a
}

@(test)
text_keys_match_each_kinds_old_key :: proc(t: ^testing.T) {
	a := key_asset()
	cooks := [?]struct {
		c:       Text_Cook,
		version: string,
		layout:  u64,
	} {
		{blackboard_text_cook(), BLACKBOARD_COOK_VERSION, format.blackboard_layout()},
		{perception_text_cook(), PERCEPTION_COOK_VERSION, format.perception_layout()},
		{effect_text_cook(), EFFECT_COOK_VERSION, format.effect_layout()},
		{world_text_cook(), WORLD_COOK_VERSION, format.world_layout()},
		{instance_set_text_cook(), INSTANCE_SET_COOK_VERSION, format.instance_set_layout()},
		{ui_text_cook(), UI_COOK_VERSION, format.ui_layout()},
		{
			animation_graph_text_cook(),
			ANIMATION_GRAPH_COOK_VERSION,
			format.animation_graph_layout(),
		},
	}
	for k in cooks {
		testing.expectf(
			t,
			text_key(k.c, a) == old_text_key(k.version, k.layout, a),
			"%v keeps its key",
			k.c.kind,
		)
	}
	testing.expect_value(t, blackboard_key(a), text_key(blackboard_text_cook(), a))
}

// The key of a made-up kind, which no change of a real layout moves, as the cooker computed it before cook_text_kind.
@(test)
text_key_is_the_same_bytes :: proc(t: ^testing.T) {
	c := Text_Cook{.Blackboard, "test 1", 0x1234}
	testing.expect_value(t, text_key(c, key_asset()), 1985055368101540819)
}
