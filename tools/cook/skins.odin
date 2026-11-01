// A glTF model's skins and animations are its Skin and Animation sub-assets, beside its meshes. A skin's joints are its
// glTF joints and their ancestors, ordered so each parent comes before its children, in the engine's axes and the
// model's scale; a skinned mesh's joint indices are remapped to that order. Each animation is one clip, for the skin
// whose joints most of its channels move. See docs/content/kinds/skins-and-animations.md.
package cook

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:strings"

import "vendor:cgltf"

import format "cinnabar:engine/asset/format"

// Cubic spline channels are sampled at this rate into linear keys.
ANIMATION_RESAMPLE_RATE :: 30

// Model_Skin is a skin while its model cooks: its joints' nodes in their order, where each of the glTF skin's joints
// went, and the points of the skinned meshes that each joint influences, in its space at bind time.
@(private)
Model_Skin :: struct {
	name:    string,
	gltf:    ^cgltf.skin,
	nodes:   []^cgltf.node,
	parents: []i32,
	// The engine-space inverse bind matrix of each joint; an ancestor that the glTF skin does not list has identity.
	inverse_bind: []matrix[4, 4]f32,
	// For each of the glTF skin's joints, its index in nodes.
	remap:   []u16,
	points:  [][dynamic][3]f32,
}

// Model_Animation is an animation that a model makes, with the skin it is for.
@(private)
Model_Animation :: struct {
	name: string,
	gltf: ^cgltf.animation,
	skin: int,
}

// model_convert is a glTF transform in the engine's axes and the model's scale: conjugated by the mirror of x and the
// scale, so it maps converted points as the glTF one maps glTF points.
@(private)
model_convert :: proc(m: matrix[4, 4]f32, scale: f32) -> matrix[4, 4]f32 {
	s := linalg.matrix4_scale_f32({-scale, scale, scale})
	inverse := linalg.matrix4_scale_f32({-1 / scale, 1 / scale, 1 / scale})
	return s * m * inverse
}

// model_skins lists the skins that a model makes, named as meshes are, and the skin of each mesh: the skin of the first
// node that draws it with one, or -1.
@(private)
model_skins :: proc(data: ^cgltf.data, meshes: []Model_Mesh, problems: ^Problems, path: string) -> (skins: []Model_Skin, mesh_skins: []int) {
	result := make([dynamic]Model_Skin, context.temp_allocator)
	used := make(map[string]int, context.temp_allocator)
	for &skin, i in data.skins {
		if len(skin.joints) == 0 {
			report_warning(problems, path, 0, 0, "skin %d has no joints, and is left out", i)
			continue
		}
		name := unique_name(string(skin.name), fmt.tprintf("skin_%d", i), &used)
		append(&result, build_model_skin(&skin, name, problems, path))
	}
	mesh_skins = make([]int, len(meshes), context.temp_allocator)
	for &m, i in meshes {
		mesh_skins[i] = -1
		if len(m.parts) == 0 {
			continue
		}
		for &n in data.nodes {
			if n.skin == nil || n.mesh == nil || &n.mesh.primitives[0] != m.parts[0].primitive {
				continue
			}
			for s, k in result {
				if s.gltf != n.skin {
					continue
				}
				if mesh_skins[i] < 0 {
					mesh_skins[i] = k
				} else if mesh_skins[i] != k {
					report_warning(problems, path, 0, 0, "mesh %s is drawn with more than one skin, and takes %s's", m.name, result[mesh_skins[i]].name)
				}
			}
		}
	}
	return result[:], mesh_skins
}

// unique_name is a name for a .meta key: the given one or a fallback, on one line, without '=', and with a number if
// another sub-asset of its kind has it.
@(private)
unique_name :: proc(given, fallback: string, used: ^map[string]int) -> string {
	name := strings.trim_space(given)
	if name == "" {
		name = fallback
	}
	name, _ = strings.replace_all(name, "=", "_", context.temp_allocator)
	name, _ = strings.replace_all(name, "\n", " ", context.temp_allocator)
	if n := used[name]; n > 0 {
		used[name] = n + 1
		return fmt.tprintf("%s_%d", name, n + 1)
	}
	used[name] = 1
	return name
}

@(private = "file")
build_model_skin :: proc(skin: ^cgltf.skin, name: string, problems: ^Problems, path: string) -> Model_Skin {
	// The joints and every ancestor of theirs, so each pose is relative to a joint's or to the model's space.
	depth :: proc(n: ^cgltf.node) -> int {
		d := 0
		for p := n.parent; p != nil; p = p.parent {
			d += 1
		}
		return d
	}
	nodes := make([dynamic]^cgltf.node, context.temp_allocator)
	for joint in skin.joints {
		for n := joint; n != nil; n = n.parent {
			if !slice.contains(nodes[:], n) {
				append(&nodes, n)
			}
		}
	}
	// Parents before children: by depth, keeping the file's order among equals.
	Keyed :: struct {
		node:  ^cgltf.node,
		depth: int,
		index: int,
	}
	keyed := make([]Keyed, len(nodes), context.temp_allocator)
	for n, i in nodes {
		keyed[i] = {n, depth(n), i}
	}
	slice.sort_by(keyed, proc(a, b: Keyed) -> bool {
		return a.depth < b.depth || a.depth == b.depth && a.index < b.index
	})
	s := Model_Skin {
		name         = name,
		gltf         = skin,
		nodes        = make([]^cgltf.node, len(keyed), context.temp_allocator),
		parents      = make([]i32, len(keyed), context.temp_allocator),
		inverse_bind = make([]matrix[4, 4]f32, len(keyed), context.temp_allocator),
		remap        = make([]u16, len(skin.joints), context.temp_allocator),
		points       = make([][dynamic][3]f32, len(keyed), context.temp_allocator),
	}
	for k, i in keyed {
		s.nodes[i] = k.node
		s.inverse_bind[i] = linalg.MATRIX4F32_IDENTITY
		s.points[i] = make([dynamic][3]f32, context.temp_allocator)
	}
	for n, i in s.nodes {
		s.parents[i] = -1
		if n.parent != nil {
			p, _ := slice.linear_search(s.nodes, n.parent)
			s.parents[i] = i32(p)
		}
	}
	for joint, j in skin.joints {
		index, _ := slice.linear_search(s.nodes, joint)
		s.remap[j] = u16(index)
	}
	if len(s.nodes) > 65535 {
		report_warning(problems, path, 0, 0, "skin %s has more than 65535 joints", name)
	}
	return s
}

// skin_read_binds reads each skin's inverse bind matrices, once the model's buffers are loaded. A skin without them
// has identity, as glTF says.
@(private)
skin_read_binds :: proc(skins: []Model_Skin, scale: f32) {
	for &s in skins {
		if s.gltf.inverse_bind_matrices == nil {
			continue
		}
		for j in 0 ..< len(s.gltf.joints) {
			m: matrix[4, 4]f32
			_ = cgltf.accessor_read_float(s.gltf.inverse_bind_matrices, uint(j), &(cast(^[16]f32)&m)[0], 16)
			s.inverse_bind[s.remap[j]] = model_convert(m, scale)
		}
	}
}

// skin_point adds a skinned vertex, in the engine's space, to the points of the joints that influence it.
@(private)
skin_point :: proc(s: ^Model_Skin, position: [3]f32, joints: [4]u16, weights: [4]u16) {
	for j, k in joints {
		if weights[k] == 0 || int(j) >= len(s.points) {
			continue
		}
		p := s.inverse_bind[j] * [4]f32{position.x, position.y, position.z, 1}
		append(&s.points[j], p.xyz)
	}
}

// skin_weights keeps a vertex's four largest influences, normalized and in unorm16 adding up to 65535, with each joint
// remapped to its skin's order. The largest takes what rounding leaves.
@(private)
skin_weights :: proc(s: ^Model_Skin, joints: []u32, weights: []f32) -> (out_joints: [4]u16, out_weights: [4]u16) {
	Influence :: struct {
		joint:  u32,
		weight: f32,
	}
	all := make([]Influence, len(joints), context.temp_allocator)
	for j, i in joints {
		all[i] = {j, weights[i] if i < len(weights) else 0}
	}
	slice.sort_by(all, proc(a, b: Influence) -> bool {return a.weight > b.weight})
	sum: f32
	for k in 0 ..< min(4, len(all)) {
		if all[k].weight > 0 && int(all[k].joint) < len(s.remap) {
			sum += all[k].weight
		}
	}
	if sum <= 0 {
		return {}, {65535, 0, 0, 0}
	}
	total: u32
	for k in 0 ..< min(4, len(all)) {
		a := all[k]
		if a.weight <= 0 || int(a.joint) >= len(s.remap) {
			continue
		}
		out_joints[k] = s.remap[a.joint]
		out_weights[k] = u16(math.round(a.weight / sum * 65535))
		total += u32(out_weights[k])
	}
	out_weights[0] = u16(i64(out_weights[0]) + 65535 - i64(total))
	return
}

// skin_contents is a skin's joints for its blob: rest poses from their nodes, and spheres about their points.
@(private)
skin_contents :: proc(s: Model_Skin, scale: f32) -> []format.Skin_Joint_Entry {
	joints := make([]format.Skin_Joint_Entry, len(s.nodes), context.temp_allocator)
	for n, i in s.nodes {
		t, r, sc := node_rest(n, scale)
		ib := s.inverse_bind[i]
		joints[i] = {
			name         = string(n.name),
			parent       = s.parents[i],
			inverse_bind = {
				{ib[0, 0], ib[0, 1], ib[0, 2], ib[0, 3]},
				{ib[1, 0], ib[1, 1], ib[1, 2], ib[1, 3]},
				{ib[2, 0], ib[2, 1], ib[2, 2], ib[2, 3]},
			},
			translation  = t,
			rotation     = r,
			scale        = sc,
			sphere       = {0, 0, 0, -1},
		}
		points := s.points[i]
		if len(points) > 0 {
			sphere := meshopt_computeSphereBounds(&points[0][0], uint(len(points)), size_of([3]f32), nil, 0)
			joints[i].sphere = {sphere.center.x, sphere.center.y, sphere.center.z, sphere.radius}
		}
	}
	return joints
}

// node_rest is a node's local transform as a translation, a rotation and a scale in the engine's axes. A node with a
// matrix is decomposed.
@(private = "file")
node_rest :: proc(n: ^cgltf.node, scale: f32) -> (translation: [3]f32, rotation: [4]f32, sc: [3]f32) {
	translation, rotation, sc = n.translation, n.rotation, n.scale
	if !n.has_translation {
		translation = 0
	}
	if !n.has_rotation {
		rotation = {0, 0, 0, 1}
	}
	if !n.has_scale {
		sc = 1
	}
	if n.has_matrix {
		m := transmute(matrix[4, 4]f32)n.matrix_
		translation = {m[0, 3], m[1, 3], m[2, 3]}
		columns := [3][3]f32{{m[0, 0], m[1, 0], m[2, 0]}, {m[0, 1], m[1, 1], m[2, 1]}, {m[0, 2], m[1, 2], m[2, 2]}}
		for c, i in columns {
			sc[i] = linalg.length(c)
		}
		if linalg.dot(linalg.cross(columns[0], columns[1]), columns[2]) < 0 {
			sc.x = -sc.x
		}
		r: matrix[3, 3]f32
		for c, i in columns {
			axis := c / sc[i] if sc[i] != 0 else 0
			r[0, i], r[1, i], r[2, i] = axis.x, axis.y, axis.z
		}
		q := linalg.quaternion_from_matrix3_f32(r)
		rotation = {imag(q), jmag(q), kmag(q), real(q)}
	}
	return convert_translation(translation, scale), convert_rotation(rotation), sc
}

@(private)
convert_translation :: proc(t: [3]f32, scale: f32) -> [3]f32 {
	return {-t.x, t.y, t.z} * scale
}

// convert_rotation mirrors a rotation in x: the mirror reverses the rotations about y and z.
@(private)
convert_rotation :: proc(q: [4]f32) -> [4]f32 {
	return {q.x, -q.y, -q.z, q.w}
}

// model_animations lists the animations that a model makes: each glTF animation that moves a joint of a skin, for the
// skin whose joints most of its channels move.
@(private)
model_animations :: proc(data: ^cgltf.data, skins: []Model_Skin, problems: ^Problems, path: string) -> []Model_Animation {
	result := make([dynamic]Model_Animation, context.temp_allocator)
	used := make(map[string]int, context.temp_allocator)
	for &animation, i in data.animations {
		votes := make([]int, len(skins), context.temp_allocator)
		for c in animation.channels {
			for s, k in skins {
				if slice.contains(s.nodes, c.target_node) {
					votes[k] += 1
				}
			}
		}
		best, most := -1, 0
		for v, k in votes {
			if v > most {
				best, most = k, v
			}
		}
		if best < 0 {
			report_warning(problems, path, 0, 0, "animation %d moves no joint of a skin, and is left out", i)
			continue
		}
		name := unique_name(string(animation.name), fmt.tprintf("animation_%d", i), &used)
		append(&result, Model_Animation{name = name, gltf = &animation, skin = best})
	}
	return result[:]
}

// animation_contents is an animation's channels and keys for its skin, in the engine's axes. Channels on nodes that
// are not its skin's joints, morph weights, and a second channel of a joint's path are left out with a warning. Cubic
// spline channels are sampled into linear keys.
@(private)
animation_contents :: proc(a: Model_Animation, s: Model_Skin, scale: f32, problems: ^Problems, path: string) -> (channels: []format.Animation_Channel, times: []f32, values: []f32, duration: f32) {
	out_channels := make([dynamic]format.Animation_Channel, context.temp_allocator)
	out_times := make([dynamic]f32, context.temp_allocator)
	out_values := make([dynamic]f32, context.temp_allocator)
	dropped := 0
	for c in a.gltf.channels {
		joint, found := slice.linear_search(s.nodes, c.target_node)
		p: format.Animation_Path
		#partial switch c.target_path {
		case .translation:
			p = .Translation
		case .rotation:
			p = .Rotation
		case .scale:
			p = .Scale
		case:
			found = false
		}
		if !found || c.sampler == nil || c.sampler.input == nil || c.sampler.output == nil {
			dropped += 1
			continue
		}
		duplicate := false
		for o in out_channels {
			duplicate ||= int(o.joint) == joint && o.path == p
		}
		if duplicate {
			report_warning(problems, path, 0, 0, "animation %s moves the %v of %s twice, and keeps the first", a.name, p, s.nodes[joint].name)
			continue
		}
		width := int(format.animation_path_width(p))
		key_count := int(c.sampler.input.count)
		if key_count == 0 {
			dropped += 1
			continue
		}
		input := make([]f32, key_count, context.temp_allocator)
		_ = cgltf.accessor_unpack_floats(c.sampler.input, &input[0], uint(key_count))
		output := make([]f32, int(c.sampler.output.count) * width, context.temp_allocator)
		_ = cgltf.accessor_unpack_floats(c.sampler.output, &output[0], uint(len(output)))

		channel := format.Animation_Channel {
			joint       = u16(joint),
			path        = p,
			first_key   = u32(len(out_times)),
			first_value = u32(len(out_values)),
		}
		key_times: []f32
		key_values: []f32
		switch c.sampler.interpolation {
		case .step, .linear:
			channel.interpolation = c.sampler.interpolation == .step ? .Step : .Linear
			if len(output) < key_count * width {
				dropped += 1
				continue
			}
			key_times, key_values = input, output[:key_count * width]
		case .cubic_spline:
			channel.interpolation = .Linear
			if len(output) < key_count * width * 3 {
				dropped += 1
				continue
			}
			key_times, key_values = resample_cubic(input, output, width)
		}
		for t in key_times {
			append(&out_times, t)
			duration = max(duration, t)
		}
		for k in 0 ..< len(key_times) {
			v := key_values[k * width:][:width]
			switch p {
			case .Translation:
				t := convert_translation({v[0], v[1], v[2]}, scale)
				append(&out_values, t.x, t.y, t.z)
			case .Rotation:
				q := convert_rotation({v[0], v[1], v[2], v[3]})
				append(&out_values, q.x, q.y, q.z, q.w)
			case .Scale:
				append(&out_values, v[0], v[1], v[2])
			}
		}
		channel.key_count = u32(len(key_times))
		append(&out_channels, channel)
	}
	if dropped > 0 {
		report_warning(problems, path, 0, 0, "animation %s leaves out %d channels that do not move a joint of skin %s", a.name, dropped, s.name)
	}
	slice.sort_by(out_channels[:], proc(a, b: format.Animation_Channel) -> bool {
		return a.joint < b.joint || a.joint == b.joint && a.path < b.path
	})
	return out_channels[:], out_times[:], out_values[:], duration
}

// resample_cubic samples a cubic spline channel, whose output is an in-tangent, a value and an out-tangent per key, at
// ANIMATION_RESAMPLE_RATE and at its last key, as glTF's Hermite spline. Rotations are normalized.
@(private = "file")
resample_cubic :: proc(input, output: []f32, width: int) -> (times: []f32, values: []f32) {
	out_times := make([dynamic]f32, context.temp_allocator)
	out_values := make([dynamic]f32, context.temp_allocator)
	first, last := input[0], input[len(input) - 1]
	steps := int(math.ceil((last - first) * ANIMATION_RESAMPLE_RATE))
	key := 0
	for i in 0 ..= steps {
		t := min(first + f32(i) / ANIMATION_RESAMPLE_RATE, last)
		for key + 1 < len(input) - 1 && input[key + 1] <= t {
			key += 1
		}
		next := min(key + 1, len(input) - 1)
		dt := input[next] - input[key]
		u := dt > 0 ? clamp((t - input[key]) / dt, 0, 1) : 0
		u2, u3 := u * u, u * u * u
		h00 := 2 * u3 - 3 * u2 + 1
		h10 := u3 - 2 * u2 + u
		h01 := -2 * u3 + 3 * u2
		h11 := u3 - u2
		value := make([]f32, width, context.temp_allocator)
		length: f32
		for c in 0 ..< width {
			p0 := output[(key * 3 + 1) * width + c]
			m0 := output[(key * 3 + 2) * width + c] * dt
			p1 := output[(next * 3 + 1) * width + c]
			m1 := output[(next * 3 + 0) * width + c] * dt
			value[c] = h00 * p0 + h10 * m0 + h01 * p1 + h11 * m1
			length += value[c] * value[c]
		}
		if width == 4 && length > 0 {
			for &v in value {
				v /= math.sqrt(length)
			}
		}
		append(&out_times, t)
		append(&out_values, ..value)
		if t >= last {
			break
		}
	}
	return out_times[:], out_values[:]
}
