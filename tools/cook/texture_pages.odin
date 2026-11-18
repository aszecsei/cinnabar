// A virtual texture's pages: the cooker cuts each paged mip into tiles of format.TEXTURE_PAGE_TEXELS, a page's 128 texels
// and a border of 4 around them, encodes each tile with the texture's usage and compresses it with LZ4. See
// docs/content/kinds/textures.md#virtual-textures.
package cook

import "base:runtime"
import "core:hash"
import "core:slice"

import "cinnabar:core/lz4"
import format "cinnabar:engine/asset/format"

// texture_is_virtual is whether a texture cooks as pages: it is a single 2D layer of a usage that block-compresses to
// BC7, BC5 or BC4, has mips, and is larger than a page, and its settings do not turn it off.
texture_is_virtual :: proc(
	t: Texture_Cook,
	dimension: format.Texture_Dimension,
	layers: int,
	size: [2]u32,
	mip_count: int,
) -> bool {
	#partial switch t.usage {
	case .Color, .Normal, .Mask:
	case:
		return false
	}
	return(
		t.virtual &&
		dimension == .D2 &&
		layers == 1 &&
		mip_count > 1 &&
		max(size.x, size.y) > format.TEXTURE_PAGE_SIZE \
	)
}

// virtual_tile cuts the tile of page (page_x, page_y) from a mip's texels, before they are encoded: the
// TEXTURE_PAGE_TEXELS square from (page_x * TEXTURE_PAGE_SIZE - TEXTURE_PAGE_BORDER, page_y * TEXTURE_PAGE_SIZE -
// TEXTURE_PAGE_BORDER). A texel past the mip's edge is the one that the sampler's wrap reads there, so the border of a
// page at an edge holds what filtering across the edge reads.
virtual_tile :: proc(
	image: Image,
	page_x, page_y: int,
	wrap: format.Texture_Wrap,
	allocator := context.temp_allocator,
) -> Image {
	tile := Image {
		format.TEXTURE_PAGE_TEXELS,
		format.TEXTURE_PAGE_TEXELS,
		make([][4]f32, format.TEXTURE_PAGE_TEXELS * format.TEXTURE_PAGE_TEXELS, allocator),
	}
	x0 := page_x * format.TEXTURE_PAGE_SIZE - format.TEXTURE_PAGE_BORDER
	y0 := page_y * format.TEXTURE_PAGE_SIZE - format.TEXTURE_PAGE_BORDER
	for j in 0 ..< tile.height {
		row := edge(y0 + j, image.height, wrap) * image.width
		for i in 0 ..< tile.width {
			tile.pixels[j * tile.width + i] = image.pixels[row + edge(x0 + i, image.width, wrap)]
		}
	}
	return tile
}

// cook_virtual_level appends the pages of one paged mip, row by row, each LZ4 compressed. root flags the mip's only
// page as the texture's root.
cook_virtual_level :: proc(
	image: Image,
	tex_format: format.Texture_Format,
	usage: format.Texture_Usage,
	quality: f32,
	gamma: bool,
	wrap: format.Texture_Wrap,
	root: bool,
	pages: ^[dynamic]format.Texture_Page_Contents,
) -> bool {
	grid := [2]int {
		(image.width + format.TEXTURE_PAGE_SIZE - 1) / format.TEXTURE_PAGE_SIZE,
		(image.height + format.TEXTURE_PAGE_SIZE - 1) / format.TEXTURE_PAGE_SIZE,
	}
	payload := make([]byte, format.texture_page_payload_size(tex_format), context.temp_allocator)
	scratch := make([]byte, lz4.bound(len(payload)), context.temp_allocator)
	for y in 0 ..< grid.y {
		for x in 0 ..< grid.x {
			block := encode_page(image, x, y, usage, quality, gamma, wrap, payload, scratch)
			if len(block) == 0 {
				return false
			}
			append(
				pages,
				format.Texture_Page_Contents {
					record = {
						size = u32(len(payload)),
						checksum = hash.fnv32a(block),
						flags = root ? {.Root} : {},
					},
					compressed = slice.clone(block, context.temp_allocator),
				},
			)
		}
	}
	return true
}

// encode_page cuts, encodes and compresses one page. Its working memory is its own, so that a large texture's thousands
// of pages do not each leave their tile behind. The block is in scratch, or empty if the page did not compress.
@(private = "file")
encode_page :: proc(
	image: Image,
	page_x, page_y: int,
	usage: format.Texture_Usage,
	quality: f32,
	gamma: bool,
	wrap: format.Texture_Wrap,
	payload, scratch: []byte,
) -> []byte {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	tile := virtual_tile(image, page_x, page_y, wrap)
	if !encode_mip(tile, usage, quality, payload, gamma) {
		return nil
	}
	return lz4.compress(payload, scratch)
}
