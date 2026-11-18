// The pool of virtual texture pages, as shaders read it (see docs/rendering/assets.md#virtual-textures). A virtual
// texture's mips down to its tail are pages of 128 texels on a side, each in a tile of an atlas while it is resident, with
// a border of 4 texels on each side. The page table has an entry for each page of each texture: the page's slot in its
// texture's atlas, or TEXTURE_PAGE_ABSENT. A material's slot of a virtual texture has VIRTUAL_TEXTURE_BIT set in its
// first word, with the texture's record below it, and a sampler that clamps. Include it after cinnabar.hlsli.
#ifndef TEXTURE_PAGES_HLSLI
#define TEXTURE_PAGES_HLSLI

// Match TEXTURE_PAGE_SIZE, TEXTURE_PAGE_BORDER and TEXTURE_PAGE_TEXELS in lib/engine/asset/format/texture.odin, and
// TEXTURE_PAGE_ABSENT, VIRTUAL_TEXTURE_BIT, MAX_VIRTUAL_LEVELS and TEXTURE_ATLAS_TILES in
// lib/engine/render/texture_pages.odin.
static const uint TEXTURE_PAGE_SIZE = 128;
static const uint TEXTURE_PAGE_BORDER = 4;
static const uint TEXTURE_PAGE_TEXELS = 136;
static const uint TEXTURE_PAGE_ABSENT = 0xffffffff;
static const uint VIRTUAL_TEXTURE_BIT = 0x80000000;
static const uint MAX_VIRTUAL_LEVELS = 12;
// An atlas's layer is TEXTURE_ATLAS_TILES tiles across and down, so 256 slots: a slot's layer is slot / 256, and its
// tile's texel in the layer is ((slot % 16) * 136, (slot / 16 % 16) * 136).
static const uint TEXTURE_ATLAS_TILES = 16;
// A record's size in bytes, and a table entry's.
static const uint VIRTUAL_TEXTURE_RECORD_SIZE = 80;
static const uint TEXTURE_PAGE_ENTRY_SIZE = 4;

// Matches Virtual_Texture_Record in lib/engine/render/texture_pages.odin, at Frame_Constants.texture_records, a
// ByteAddressBuffer with a record for each virtual texture, 80 bytes apart. The paged levels are the texture's mips 0 up
// to `levels`: level i is the size shifted right by i, at least a texel, over TEXTURE_PAGE_SIZE and rounded up on each axis
// pages, row by row. Its page p is the table entry `table + level_first[i] + p`, read from the ByteAddressBuffer at
// Frame_Constants.texture_pages. The mips from `levels` on are the `tail` texture's, a Texture2D whose mip 0 is the
// texture's mip `levels`. `atlas` is a Texture2DArray. `sampler` has the texture's wrap, which the shader applies to its UV
// as the material's sampler clamps, its mip filter and its anisotropy (see material_virtual.hlsli).
struct Virtual_Texture_Record {
	uint2 size;
	uint table;
	uint page_count;
	uint levels;
	uint atlas;
	uint tail;
	uint sampler;
	uint level_first[MAX_VIRTUAL_LEVELS];
};

#endif
