// A material's samples of a virtual texture (see docs/rendering/materials.md#virtual-textures). A slot of a material's
// parameter block whose first word has VIRTUAL_TEXTURE_BIT names the texture's record, not a texture (see
// texture_pages.hlsli). cn_sample and its kin in material_common.hlsli call virtual_sample for it.
//
// The shader finds the level itself, as a sampler does for a texture of mips: from the gradients and the record's size,
// or from the level that the caller gives. A level is a grid of pages. A page that is not resident is replaced by the
// coarser page that covers it, up to the root, which is resident while the texture is. Levels from the record's `levels`
// on are the tail texture's own mips. A sample between two levels blends the two, as a trilinear filter does.
//
// Included by material_common.hlsli, after the frame's constants and Cn_Texture.
#ifndef MATERIAL_VIRTUAL_HLSLI
#define MATERIAL_VIRTUAL_HLSLI

#include "texture_pages.hlsli"

// Match VIRTUAL_SAMPLER_WRAP_MASK, VIRTUAL_SAMPLER_MIP_NEAREST and VIRTUAL_SAMPLER_ANISOTROPY_SHIFT in
// lib/engine/render/texture_pages.odin: the record's `sampler` word has the texture's wrap in its low 2 bits (Repeat 0,
// Clamp 1, Mirror 2), 1 in bit 2 for a nearest mip filter, and the anisotropy that its sampler takes, under the quality's
// cap, from bit 8.
static const uint VIRTUAL_SAMPLER_WRAP_MASK = 3;
static const uint VIRTUAL_SAMPLER_MIP_NEAREST = 4;
static const uint VIRTUAL_SAMPLER_ANISOTROPY_SHIFT = 8;

// The anisotropy that picks a level, at most. A tap of the filter along the footprint's long axis reaches half the axis
// from the sample, and bilinear filtering half a texel more, so a long axis of VIRTUAL_FOOTPRINT texels, in the level's
// texels, stays in the page's border of 4: 3.5 + 0.5. Each sampled level scales a longer axis down to it, which for an
// anisotropy of 8 at a short axis of 1 texel is exactly the long axis, and gives up a little sharpness when the short
// axis is longer.
static const float VIRTUAL_MAX_ANISOTROPY = 8;
static const float VIRTUAL_FOOTPRINT = 7;
// A blend weight below this takes one level, which is a difference of under 1/255 of the colors' range.
static const float VIRTUAL_BLEND_MIN = 1.0 / 256.0;

// The part of a record that a sample needs before it finds a page: see Virtual_Texture_Record. The words that follow it,
// the first page of each level, are read when a level needs one.
struct Virtual_Header {
	uint2 size;
	uint table;
	uint page_count;
	uint levels;
	uint atlas;
	uint tail;
	uint sampler;
};

Virtual_Header virtual_header(uint record) {
	ByteAddressBuffer records = cn_buffer(frame.texture_records);
	uint4 a = records.Load4(record * VIRTUAL_TEXTURE_RECORD_SIZE);
	uint4 b = records.Load4(record * VIRTUAL_TEXTURE_RECORD_SIZE + 16);
	Virtual_Header h;
	h.size = a.xy;
	h.table = a.z;
	h.page_count = a.w;
	h.levels = b.x;
	h.atlas = b.y;
	h.tail = b.z;
	h.sampler = b.w;
	return h;
}

// virtual_wrap applies the texture's wrap to a UV, since the sampler of the atlas and the tail clamp.
float2 virtual_wrap(float2 uv, uint wrap) {
	if (wrap == 1) {
		return saturate(uv);
	}
	if (wrap == 2) {
		float2 m = uv - 2 * floor(uv * 0.5);
		return 1 - abs(1 - m);
	}
	return frac(uv);
}

// virtual_lod is the level of detail of a footprint of UV gradients, as a sampler of `anisotropy` takes it: the short
// axis' level, unless the long axis is more than `anisotropy` times as long, which the level follows then.
float virtual_lod(Virtual_Header h, float2 dx, float2 dy) {
	float2 gx = dx * float2(h.size);
	float2 gy = dy * float2(h.size);
	float lx = dot(gx, gx);
	float ly = dot(gy, gy);
	float major = sqrt(max(lx, ly));
	float minor = sqrt(min(lx, ly));
	float anisotropy = min(float(max(h.sampler >> VIRTUAL_SAMPLER_ANISOTROPY_SHIFT, 1)), VIRTUAL_MAX_ANISOTROPY);
	return max(log2(max(max(minor, major / anisotropy), 1e-8)), 0);
}

// The pixel's feedback: the feedback buffer's write index plus 1, or 0 for a pixel that writes none. A pixel shader
// that writes it calls cn_feedback_begin first, and no other does, so the vertex stages, the depth passes and a ray's
// hit write none.
static uint cn_feedback = 0;

// cn_feedback_begin picks the pixel's share of the feedback: one pixel of each 4x4 block, a different one each frame, in
// a frame that has the feedback (see Frame_Constants.texture_feedback). The pixel's samples of virtual textures then
// write which pages they wanted and used.
void cn_feedback_begin(float4 position) {
	uint2 pixel = uint2(position.xy);
	uint cell = (pixel.x & 3) | (pixel.y & 3) << 2;
	if (frame.texture_feedback != 0 && cell == ((frame.texture_frame * 7) & 15)) {
		cn_feedback = frame.texture_feedback;
	}
}

// virtual_feedback raises a table entry's word to a value, which is the entry's priority as a float's bits or 1 for a page
// that the sample used. A float over 0 orders as its bits do, and its bits are over 1.
void virtual_feedback(uint entry, uint value) {
	uint previous;
	cn_rw_buffer(cn_feedback - 1).InterlockedMax(entry * TEXTURE_PAGE_ENTRY_SIZE, value, previous);
}

// virtual_entry is the table entry of the page of a level that holds a UV in [0, 1], and the UV's texel in the page's
// payload. The level's size is the texture's shifted right, at least a texel, and its pages are grid.x by grid.y.
uint virtual_entry(Virtual_Header h, uint record, uint level, float2 uv, out float2 local) {
	uint2 level_size = max(h.size >> level, uint2(1, 1));
	uint2 grid = (level_size + (TEXTURE_PAGE_SIZE - 1)) / TEXTURE_PAGE_SIZE;
	float2 texel = clamp(uv * float2(level_size), 0, float2(level_size));
	uint2 page = min(uint2(texel / TEXTURE_PAGE_SIZE), grid - 1);
	local = texel - float2(page * TEXTURE_PAGE_SIZE);
	uint first = cn_buffer(frame.texture_records).Load(record * VIRTUAL_TEXTURE_RECORD_SIZE + 32 + level * 4);
	return h.table + first + page.y * grid.x + page.x;
}

// virtual_tail samples the tail texture, whose mip 0 is the texture's mip `levels`: with the gradients, whose own level
// clamps at 0 for a UV that is finer, or at a level.
float4 virtual_tail(Virtual_Header h, SamplerState s, float2 uv, float2 dx, float2 dy, float lod, bool grad) {
	Texture2D<float4> tail = cn_texture(h.tail);
	if (grad) {
		return tail.SampleGrad(s, uv, dx, dy);
	}
	return tail.SampleLevel(s, uv, max(lod - float(h.levels), 0));
}

// A page that a sample found: its slot, or TEXTURE_PAGE_ABSENT, the level that it is of, the UV's texel in its payload,
// and its table entry.
struct Virtual_Found {
	uint slot;
	uint level;
	float2 local;
	uint entry;
	uint wanted;
};

// virtual_find finds the page of a level that holds a UV, or the first resident page that covers it among the coarser
// levels, whose texels are the larger, up to the root, which a ready texture always has. `wanted` is the table entry of
// the page that was asked for.
Virtual_Found virtual_find(Virtual_Header h, uint record, float2 uv, uint level) {
	ByteAddressBuffer table = cn_buffer(frame.texture_pages);
	Virtual_Found page;
	page.level = level;
	page.entry = virtual_entry(h, record, level, uv, page.local);
	page.wanted = page.entry;
	page.slot = table.Load(page.entry * TEXTURE_PAGE_ENTRY_SIZE);
	// At most MAX_VIRTUAL_LEVELS levels: a record has no more.
	[loop]
	while (page.slot == TEXTURE_PAGE_ABSENT && page.level + 1 < h.levels) {
		page.level++;
		page.entry = virtual_entry(h, record, page.level, uv, page.local);
		page.slot = table.Load(page.entry * TEXTURE_PAGE_ENTRY_SIZE);
	}
	return page;
}

// virtual_level samples a paged level at a UV in [0, 1]: its page, or the first coarser page that is resident. Past the
// root, it takes the tail. With a gradient, the filter takes the level's texels from the gradients' footprint, clamped to
// the page's border; without, the level's own texels.
float4 virtual_level(
	Virtual_Header h,
	uint record,
	SamplerState s,
	float2 uv,
	uint level,
	float2 dx,
	float2 dy,
	float lod,
	bool grad
) {
	Virtual_Found page = virtual_find(h, record, uv, level);
	if (page.slot == TEXTURE_PAGE_ABSENT) {
		return virtual_tail(h, s, uv, dx, dy, lod, grad);
	}
	if (cn_feedback != 0) {
		// A page that the sample wanted and did not find is wanted by how many levels of detail it is short, which is
		// at least 1, so a float at least 2. The page that it used is used, unless it is the root, which stays.
		if (page.level != level) {
			virtual_feedback(page.wanted, asuint(exp2(float(page.level - level))));
		}
		if (page.level + 1 < h.levels) {
			virtual_feedback(page.entry, 1);
		}
	}
	uint slot = page.slot;
	float2 tile = float2(slot % TEXTURE_ATLAS_TILES, (slot / TEXTURE_ATLAS_TILES) % TEXTURE_ATLAS_TILES) * TEXTURE_PAGE_TEXELS;
	float atlas_size = TEXTURE_ATLAS_TILES * TEXTURE_PAGE_TEXELS;
	float3 atlas_uv = float3((tile + TEXTURE_PAGE_BORDER + page.local) / atlas_size, slot / (TEXTURE_ATLAS_TILES * TEXTURE_ATLAS_TILES));
	Texture2DArray<float4> atlas = cn_texture_array(h.atlas);
	if (!grad) {
		return atlas.SampleLevel(s, atlas_uv, 0);
	}
	// The atlas has one mip, so the level's texels are its own: the gradients in the level's texels over the atlas's
	// size are what the sampler's anisotropic filter takes its taps from.
	float2 level_size = float2(max(h.size >> page.level, uint2(1, 1)));
	float2 gx = dx * level_size;
	float2 gy = dy * level_size;
	gx *= min(1, VIRTUAL_FOOTPRINT / max(length(gx), 1e-8));
	gy *= min(1, VIRTUAL_FOOTPRINT / max(length(gy), 1e-8));
	return atlas.SampleGrad(s, atlas_uv, gx / atlas_size, gy / atlas_size);
}

// virtual_sample samples a virtual texture of a material's slot at a UV. With grad, the level comes from the UV's
// gradients dx and dy and the sampler's anisotropy; without, it is `level`, a mip of the texture. A nearest mip filter
// takes the level nearest to it, and a linear one blends the two around it.
float4 virtual_sample(Cn_Texture t, float2 uv, float2 dx, float2 dy, float level, bool grad) {
	uint record = t.index & ~VIRTUAL_TEXTURE_BIT;
	Virtual_Header h = virtual_header(record);
	SamplerState s = cn_sampler(t.sampler);
	uv = virtual_wrap(uv, h.sampler & VIRTUAL_SAMPLER_WRAP_MASK);
	float lod = grad ? virtual_lod(h, dx, dy) : max(level, 0);
	bool nearest = (h.sampler & VIRTUAL_SAMPLER_MIP_NEAREST) != 0;
	float base = nearest ? floor(lod + 0.5) : floor(lod);
	float blend = nearest ? 0 : lod - base;
	if (base >= float(h.levels)) {
		return virtual_tail(h, s, uv, dx, dy, lod, grad);
	}
	uint l0 = uint(base);
	float4 c = virtual_level(h, record, s, uv, l0, dx, dy, lod, grad);
	if (blend > VIRTUAL_BLEND_MIN) {
		float4 c1;
		if (l0 + 1 >= h.levels) {
			c1 = virtual_tail(h, s, uv, dx, dy, lod, grad);
		} else {
			c1 = virtual_level(h, record, s, uv, l0 + 1, dx, dy, lod, grad);
		}
		c = lerp(c, c1, blend);
	}
	return c;
}

#endif
