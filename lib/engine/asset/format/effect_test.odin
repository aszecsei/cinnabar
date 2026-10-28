package asset_format

import "core:testing"

@(test)
effect_blobs_round_trip :: proc(t: ^testing.T) {
	guid, _ := guid_parse(TEST_GUID)
	smoke: [Effect_Curve]Effect_Curve_Row
	smoke[.Size][63] = {0.5, 0, 0, 0}
	emitters := []Effect_Emitter_Contents {
		{
			emitter = {capacity = 100, rate = 5, lifetime = {1, 2}, shape = .Cone, shape_size = {0.1, 0.3, 0}, texture = guid, flipbook = {4, 4}},
			name = "smoke",
			modules = {{kind = .Gravity, values = {0, -9.8, 0, 0}}, {kind = .Collide, values = {0.5, 0.1, 0, 0}}},
			curves = smoke,
		},
		{emitter = {capacity = 7}, name = "sparks"},
	}
	data := aligned(effect_write({guid = guid, key = 42, emitters = emitters, source_path = "game/effects/smoke.effect"}, context.temp_allocator))
	blob, ok := effect_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, blob.header.key, 42)
	testing.expect_value(t, string(blob_bytes(data, blob.source_path)), "game/effects/smoke.effect")
	read := effect_emitters(data, blob)
	testing.expect_value(t, len(read), 2)
	testing.expect_value(t, string(blob_bytes(data, read[0].name)), "smoke")
	testing.expect_value(t, read[0].capacity, 100)
	testing.expect_value(t, read[0].shape, Effect_Shape.Cone)
	testing.expect_value(t, read[0].texture, guid)
	modules := effect_modules(data, read[0])
	testing.expect_value(t, len(modules), 2)
	testing.expect_value(t, modules[1].kind, Effect_Module_Kind.Collide)
	testing.expect_value(t, len(effect_modules(data, read[1])), 0)
	// Each emitter has a row for each curve.
	curves := effect_curves(data, blob)
	testing.expect_value(t, len(curves), 2 * len(Effect_Curve))
	testing.expect_value(t, curves[read[0].curves + u32(Effect_Curve.Size)][63], [4]f32{0.5, 0, 0, 0})
	testing.expect_value(t, read[1].curves, u32(len(Effect_Curve)))

	// A blob whose emitter claims more particles than an emitter holds is rejected.
	read[1].capacity = MAX_EMITTER_CAPACITY + 1
	_, ok = effect_view(data)
	testing.expect(t, !ok)
	_, ok = effect_view(data[:size_of(Effect_Blob) - 1])
	testing.expect(t, !ok)
}
