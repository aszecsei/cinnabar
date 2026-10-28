package cook

import "core:math"
import "core:testing"

import format "cinnabar:engine/asset/format"

@(test)
effects_parse_into_emitters_with_baked_curves :: proc(t: ^testing.T) {
	text := `effect 1
# Smoke and sparks.
emitter smoke
	capacity = 500
	rate = 30   # a second
	burst = 10 2
	lifetime = 2 4
	speed = 1
	spin = -1 1
	shape = cone 0.2 30
	texture = $00112233445566778899aabbccddeeff
	flipbook = 4 2 12
	softness = 0.3
	module gravity 0 -1 0
	module noise 0.5 2
	curve color = 0:1,1,1,0 0.5:0.5,0.5,0.5 1:0,0,0,0
	curve size = 0:0.1 1:0.9

emitter sparks
	module collide 0.4 0.2
`
	emitters, problems := effect_parse(text, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	testing.expect_value(t, len(emitters), 2)
	if len(emitters) != 2 {
		return
	}
	smoke := emitters[0]
	testing.expect_value(t, smoke.name, "smoke")
	testing.expect_value(t, smoke.emitter.capacity, 500)
	testing.expect_value(t, smoke.emitter.rate, 30)
	testing.expect_value(t, smoke.emitter.burst, 10)
	testing.expect_value(t, smoke.emitter.burst_interval, 2)
	testing.expect_value(t, smoke.emitter.lifetime, [2]f32{2, 4})
	// One value is a range of one.
	testing.expect_value(t, smoke.emitter.speed, [2]f32{1, 1})
	testing.expect_value(t, smoke.emitter.spin, [2]f32{-1, 1})
	testing.expect_value(t, smoke.emitter.shape, format.Effect_Shape.Cone)
	// The cone's angle is in degrees in the text.
	testing.expect(t, math.abs(smoke.emitter.shape_size.y - math.PI / 6) < 1e-6)
	testing.expect_value(t, smoke.emitter.texture, format.guid_parse("00112233445566778899aabbccddeeff") or_else {})
	testing.expect_value(t, smoke.emitter.flipbook, [2]u32{4, 2})
	testing.expect_value(t, len(smoke.modules), 2)
	testing.expect_value(t, smoke.modules[1].kind, format.Effect_Module_Kind.Noise)
	// Curves are linear between their keys: the color's alpha, left out at 0.5, is 1 there.
	color := smoke.curves[.Color]
	testing.expect_value(t, color[0], [4]f32{1, 1, 1, 0})
	testing.expect_value(t, color[63], [4]f32{0, 0, 0, 0})
	middle := color[31] + (color[32] - color[31]) * 0.5
	testing.expect(t, math.abs(middle.x - 0.5) < 0.02 && math.abs(middle.w - 1) < 0.04)
	testing.expect(t, math.abs(smoke.curves[.Size][63].x - 0.9) < 1e-6)
	// An emitter without settings or curves takes the defaults.
	sparks := emitters[1]
	testing.expect_value(t, sparks.emitter.capacity, 256)
	testing.expect_value(t, sparks.curves[.Color][10], [4]f32{1, 1, 1, 1})
	testing.expect_value(t, sparks.curves[.Size][10].x, 0.1)
	testing.expect_value(t, sparks.modules[0].values.xy, [2]f32{0.4, 0.2})
}

@(test)
effect_mistakes_are_problems_at_their_lines :: proc(t: ^testing.T) {
	cases := []struct {
		text: string,
		line: int,
	} {
		{"emitter a\n", 1},
		{"effect 1\n", 1},
		{"effect 1\nemitter a\n\tcapacity = 0\n", 3},
		{"effect 1\nemitter a\n\tlifetime = 2 1\n", 3},
		{"effect 1\nemitter a\n\tshape = sphere\n", 3},
		{"effect 1\nemitter a\n\tmodule wind 1\n", 3},
		{"effect 1\nemitter a\n\tcurve size = 0.5:1 0.2:2\n", 3},
		{"effect 1\nemitter a\n\tcurve color = 0:1,1\n", 3},
		{"effect 1\nemitter a\n\tcolour = 1\n", 3},
		{"effect 1\nemitter a\n\ttexture = abc\n", 3},
		{"effect 1\n\tcapacity = 1\nemitter a\n", 2},
	}
	for c in cases {
		_, problems := effect_parse(c.text, context.temp_allocator)
		testing.expectf(t, len(problems) > 0 && problems[0].line == c.line, "%q: %v", c.text, problems)
	}
}

@(test)
effects_cook_to_effect_blobs :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/effects/smoke.effect", EFFECT_TEMPLATE}, {"content/effects/broken.effect", "effect 1\n"}})
	defer remove_tree(tree)
	options := tree_options(tree)
	pass := cook(options, {.Effect}, log_problems = false)
	// The broken effect fails, and the template cooks.
	testing.expect(t, !pass.ok)
	testing.expect_value(t, pass.cooked[.Effect], 1)
	data := tree_blob(t, tree, tree_guid(t, tree, "effects/smoke.effect"))
	blob, ok := format.effect_view(data)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, len(format.effect_emitters(data, blob)), 1)
	}
	// A second cook finds it up to date.
	pass = cook(options, {.Effect}, log_problems = false)
	testing.expect_value(t, pass.current[.Effect], 1)
}
