package asset_format

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

// INSTANCES_TEXT_TEMPLATE is the start of an .instances file: its header and what a line holds.
INSTANCES_TEXT_TEMPLATE :: `instances 1
# Each line is an instance: its position x y z in meters, its rotation as a quaternion x y z w, and its scale x y z,
# relative to the entity whose Instanced_Mesh_Renderer names the set.
`

// Instances_Problem is an error in an instance set's text, at a line from 1.
Instances_Problem :: struct {
	line:    int,
	message: string,
}

// instances_text_parse parses an instance set's text into its poses, each rotation normalized. It gives every problem
// that it finds, with the line that has it, and the set is good only without any.
instances_text_parse :: proc(
	text: string,
	allocator := context.allocator,
) -> (
	poses: []Instance_Pose,
	problems: []Instances_Problem,
) {
	context.allocator = allocator
	found := make([dynamic]Instances_Problem)
	result := make([dynamic]Instance_Pose)
	header := false
	for raw, index in strings.split_lines(text) {
		line := index + 1
		trimmed := raw
		if hash := strings.index_byte(trimmed, '#'); hash >= 0 {
			trimmed = trimmed[:hash]
		}
		fields := strings.fields(trimmed)
		if len(fields) == 0 {
			continue
		}
		if !header {
			if len(fields) == 2 && fields[0] == "instances" && fields[1] == "1" {
				header = true
				continue
			}
			append(&found, Instances_Problem{line, "an instance set starts with `instances 1`"})
			return nil, found[:]
		}
		if fields[0] != "i" || len(fields) != 11 {
			append(
				&found,
				Instances_Problem {
					line,
					"an instance is `i` and 10 numbers: x y z, a rotation x y z w, and a scale x y z",
				},
			)
			continue
		}
		numbers: [10]f32
		bad := ""
		for field, i in fields[1:] {
			value, ok := strconv.parse_f32(field)
			if !ok {
				bad = fmt.aprintf("%q is not a number", field)
				break
			}
			if math.is_nan(value) || math.is_inf(value) {
				bad = fmt.aprintf("%q is not a finite number", field)
				break
			}
			numbers[i] = value
		}
		if bad != "" {
			append(&found, Instances_Problem{line, bad})
			continue
		}
		q := [4]f32{numbers[3], numbers[4], numbers[5], numbers[6]}
		length := math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w)
		if !(length > 0) || math.is_inf(length) {
			append(&found, Instances_Problem{line, "a rotation has a length above zero"})
			continue
		}
		// A rotation that is unit within the digits that the file holds stays as it is, so a file round trips.
		if abs(length - 1) > 1e-6 {
			q /= length
		}
		append(
			&result,
			Instance_Pose {
				position = {numbers[0], numbers[1], numbers[2]},
				rotation = quaternion(x = q.x, y = q.y, z = q.z, w = q.w),
				scale = {numbers[7], numbers[8], numbers[9]},
			},
		)
	}
	if !header {
		append(&found, Instances_Problem{1, "an instance set starts with `instances 1`"})
	}
	return result[:], found[:]
}

// instances_text_write writes poses as an instance set's text: the shortest digits that read back as the same floats.
instances_text_write :: proc(poses: []Instance_Pose, allocator := context.allocator) -> string {
	context.allocator = allocator
	b := strings.builder_make()
	strings.write_string(&b, INSTANCES_TEXT_TEMPLATE)
	number :: proc(b: ^strings.Builder, v: f32) {
		buffer: [32]byte
		strings.write_byte(b, ' ')
		strings.write_string(b, strconv.write_float(buffer[:], f64(v), 'g', -1, 32))
	}
	for pose in poses {
		strings.write_byte(&b, 'i')
		for v in pose.position {
			number(&b, v)
		}
		number(&b, imag(pose.rotation))
		number(&b, jmag(pose.rotation))
		number(&b, kmag(pose.rotation))
		number(&b, real(pose.rotation))
		for v in pose.scale {
			number(&b, v)
		}
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}
