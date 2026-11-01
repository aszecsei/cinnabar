// Bins the visibility buffer's 2x2 quads by the material pipelines of their pixels (see
// docs/rendering/lighting-and-shadows.md#visibility-buffer), in four phases, a dispatch each:
//   Clear: zeroes each bin's count and cursor.
//   Count: a thread for each quad finds the pipelines of its pixels that the visibility buffer shades, and counts the
//   quad once in each one's bin.
//   Offsets: one thread gives each bin its first quad in the order and its dispatch's arguments.
//   Scatter: a thread for each quad writes it into each of its pipelines' range of the order.
// Each pipeline's material then shades its bin with one indirect dispatch (see material_shade.hlsli).
#include "cinnabar.hlsli"

// Matches Visibility_Bin_Push in lib/engine/render/visibility.odin.
struct Push {
	uint phase;
	uint visibility;
	uint stencil;
	uint bins;
	uint order;
	uint arguments;
	uint2 size;
};
CN_PUSH_CONSTANTS(Push, push);

static const uint PHASE_CLEAR = 0;
static const uint PHASE_COUNT = 1;
static const uint PHASE_OFFSETS = 2;
static const uint PHASE_SCATTER = 3;
// Match visibility.odin and material_common.hlsli: a bin for each material pipeline, its words, the quads of a
// shading group, and a pixel's pipeline.
static const uint BINS = 256;
static const uint BIN_COUNTS = 0;
static const uint BIN_CURSORS = BINS * 4;
static const uint BIN_OFFSETS = 2 * BINS * 4;
static const uint GROUP_QUADS = 64;
static const uint VIS_PIPELINE_SHIFT = 8;
static const uint VISIBILITY_STENCIL = 2;

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	RWByteAddressBuffer bins = cn_rw_buffer(push.bins);
	if (push.phase == PHASE_CLEAR) {
		if (id.y == 0 && id.x < BINS) {
			bins.Store(BIN_COUNTS + id.x * 4, 0);
			bins.Store(BIN_CURSORS + id.x * 4, 0);
		}
		return;
	}
	if (push.phase == PHASE_OFFSETS) {
		if (any(id.xy != 0)) {
			return;
		}
		RWByteAddressBuffer arguments = cn_rw_buffer(push.arguments);
		uint offset = 0;
		for (uint b = 0; b < BINS; b++) {
			uint count = bins.Load(BIN_COUNTS + b * 4);
			bins.Store(BIN_OFFSETS + b * 4, offset);
			arguments.Store3(b * 12, uint3((count + GROUP_QUADS - 1) / GROUP_QUADS, 1, 1));
			offset += count;
		}
		return;
	}
	uint2 quad = id.xy;
	if (any(quad * 2 >= push.size)) {
		return;
	}
	Texture2D<uint4> visibility = ResourceDescriptorHeap[push.visibility];
	Texture2D<uint2> stencil = cn_stencil_texture(push.stencil);
	// The quad's pipelines, each once.
	uint pipelines[4];
	uint count = 0;
	for (uint k = 0; k < 4; k++) {
		uint2 pixel = quad * 2 + uint2(k & 1, k >> 1);
		if (any(pixel >= push.size)) {
			continue;
		}
		uint4 value = visibility.Load(int3(pixel, 0));
		if ((stencil.Load(int3(pixel, 0)).g & VISIBILITY_STENCIL) == 0 || value.x == 0) {
			continue;
		}
		uint pipeline = value.w >> VIS_PIPELINE_SHIFT;
		bool seen = pipeline >= BINS;
		for (uint j = 0; j < count; j++) {
			seen = seen || pipelines[j] == pipeline;
		}
		if (!seen) {
			pipelines[count++] = pipeline;
		}
	}
	for (uint p = 0; p < count; p++) {
		uint bin = pipelines[p];
		if (push.phase == PHASE_COUNT) {
			bins.InterlockedAdd(BIN_COUNTS + bin * 4, 1);
		} else {
			uint index;
			bins.InterlockedAdd(BIN_CURSORS + bin * 4, 1, index);
			cn_rw_buffer(push.order).Store((bins.Load(BIN_OFFSETS + bin * 4) + index) * 4, quad.x | quad.y << 16);
		}
	}
}
