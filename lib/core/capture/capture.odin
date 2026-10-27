// Package capture turns a frame capture into images on the CPU: an RGB8 image from the frame target's bytes in any
// output mode, a half-size copy for the history ring, and PNG and GIF encodings (see
// docs/editor/capture.md#capture). It has no GPU and no threads of its own: the host's capture worker calls it.
package capture

import "base:runtime"
import "core:math"

import "cinnabar:core/gpu"

// Image is tightly packed RGB8: 3 * size.x bytes per row.
Image :: struct {
	size:   [2]u32,
	pixels: []byte,
}

// The SDR white that the HDR modes use when the display reports none, in nits: scRGB's 1.0, and the reference for
// HDR10 content on a display in its default settings.
DEFAULT_SDR_WHITE :: f32(80)

// to_rgb8 converts a capture to RGB8, walking the capture's row pitch. Sdr bytes are sRGB already and only drop
// their alpha, in RGBA or BGRA order by the format. Hdr10 decodes the PQ curve to nits, turns the Rec. 2020
// primaries into Rec. 709, divides by the SDR white and clamps, so the display's SDR white becomes white. Scrgb
// clamps its linear halves, where 1 is 80 nits, and both encode to sRGB. False for a format it cannot read.
to_rgb8 :: proc(c: gpu.Frame_Capture, allocator: runtime.Allocator) -> (img: Image, ok: bool) {
	w, h := int(c.size.x), int(c.size.y)
	if w == 0 || h == 0 || len(c.pixels) < int(c.row_pitch) * h {
		return
	}
	img = Image {
		size   = c.size,
		pixels = make([]byte, w * h * 3, allocator),
	}
	white := c.sdr_white if c.sdr_white > 0 else DEFAULT_SDR_WHITE
	#partial switch c.format {
	case .RGBA8_Unorm, .RGBA8_Unorm_Srgb, .BGRA8_Unorm, .BGRA8_Unorm_Srgb:
		bgra := c.format == .BGRA8_Unorm || c.format == .BGRA8_Unorm_Srgb
		for y in 0 ..< h {
			row := c.pixels[y * int(c.row_pitch):][:w * 4]
			out := img.pixels[y * w * 3:][:w * 3]
			for x in 0 ..< w {
				p := row[x * 4:][:4]
				if bgra {
					out[x * 3], out[x * 3 + 1], out[x * 3 + 2] = p[2], p[1], p[0]
				} else {
					out[x * 3], out[x * 3 + 1], out[x * 3 + 2] = p[0], p[1], p[2]
				}
			}
		}
	case .RGB10A2_Unorm:
		for y in 0 ..< h {
			row := c.pixels[y * int(c.row_pitch):][:w * 4]
			out := img.pixels[y * w * 3:][:w * 3]
			for x in 0 ..< w {
				v := (^u32le)(&row[x * 4])^
				r := pq_to_nits(f32(v & 0x3ff) / 1023)
				g := pq_to_nits(f32((v >> 10) & 0x3ff) / 1023)
				b := pq_to_nits(f32((v >> 20) & 0x3ff) / 1023)
				r, g, b = rec2020_to_rec709(r, g, b)
				out[x * 3] = srgb_encode(r / white)
				out[x * 3 + 1] = srgb_encode(g / white)
				out[x * 3 + 2] = srgb_encode(b / white)
			}
		}
	case .RGBA16_Float:
		for y in 0 ..< h {
			row := c.pixels[y * int(c.row_pitch):][:w * 8]
			out := img.pixels[y * w * 3:][:w * 3]
			for x in 0 ..< w {
				p := (^[4]f16le)(&row[x * 8])^
				// scRGB's 1 is 80 nits, so the SDR white's fraction of that scales it.
				scale := DEFAULT_SDR_WHITE / white
				out[x * 3] = srgb_encode(f32(p[0]) * scale)
				out[x * 3 + 1] = srgb_encode(f32(p[1]) * scale)
				out[x * 3 + 2] = srgb_encode(f32(p[2]) * scale)
			}
		}
	case:
		delete(img.pixels, allocator)
		return {}, false
	}
	return img, true
}

// downscale_half is a 2x2 box filter. An odd edge repeats its last column or row.
downscale_half :: proc(img: Image, allocator: runtime.Allocator) -> Image {
	w, h := int(img.size.x), int(img.size.y)
	ow, oh := max((w + 1) / 2, 1), max((h + 1) / 2, 1)
	out := Image {
		size   = {u32(ow), u32(oh)},
		pixels = make([]byte, ow * oh * 3, allocator),
	}
	for y in 0 ..< oh {
		y0, y1 := min(y * 2, h - 1), min(y * 2 + 1, h - 1)
		for x in 0 ..< ow {
			x0, x1 := min(x * 2, w - 1), min(x * 2 + 1, w - 1)
			for ch in 0 ..< 3 {
				sum :=
					int(img.pixels[(y0 * w + x0) * 3 + ch]) +
					int(img.pixels[(y0 * w + x1) * 3 + ch]) +
					int(img.pixels[(y1 * w + x0) * 3 + ch]) +
					int(img.pixels[(y1 * w + x1) * 3 + ch])
				out.pixels[(y * ow + x) * 3 + ch] = u8((sum + 2) / 4)
			}
		}
	}
	return out
}

// srgb_encode turns a linear value into an sRGB byte, clamping to white.
srgb_encode :: proc(linear: f32) -> u8 {
	v := clamp(linear, 0, 1)
	encoded := v * 12.92 if v <= 0.0031308 else 1.055 * math.pow(v, 1 / 2.4) - 0.055
	return u8(clamp(encoded * 255 + 0.5, 0, 255))
}

// pq_to_nits decodes the PQ curve of SMPTE ST 2084, where 1 is 10,000 nits.
pq_to_nits :: proc(encoded: f32) -> f32 {
	M1 :: 2610.0 / 16384
	M2 :: 2523.0 / 4096 * 128
	C1 :: 3424.0 / 4096
	C2 :: 2413.0 / 4096 * 32
	C3 :: 2392.0 / 4096 * 32
	e := clamp(encoded, 0, 1)
	p := math.pow(e, 1 / M2)
	return 10000 * math.pow(max(p - C1, 0) / (C2 - C3 * p), 1 / M1)
}

// nits_to_pq is the inverse of pq_to_nits, for tests and tools.
nits_to_pq :: proc(nits: f32) -> f32 {
	M1 :: 2610.0 / 16384
	M2 :: 2523.0 / 4096 * 128
	C1 :: 3424.0 / 4096
	C2 :: 2413.0 / 4096 * 32
	C3 :: 2392.0 / 4096 * 32
	y := math.pow(clamp(nits / 10000, 0, 1), M1)
	return math.pow((C1 + C2 * y) / (1 + C3 * y), M2)
}

// rec2020_to_rec709 converts linear Rec. 2020 primaries to Rec. 709's. Colors outside 709 come out negative, and
// srgb_encode clamps them.
rec2020_to_rec709 :: proc(r, g, b: f32) -> (f32, f32, f32) {
	return 1.6605 * r - 0.5876 * g - 0.0728 * b,
		-0.1246 * r + 1.1329 * g - 0.0083 * b,
		-0.0182 * r - 0.1006 * g + 1.1187 * b
}
