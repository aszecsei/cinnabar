// The pool of mesh pages, as shaders read it (see docs/rendering/assets.md#mesh-pages). A paged mesh's meshlets and
// vertices are in pages, each in a slot of the pool while it is resident. The page table has an entry for each page of
// each mesh, from the mesh's first entry: the page's slot, or MESH_PAGE_ABSENT, and the page's first meshlet in its
// mesh. Include it after cinnabar.hlsli.
#ifndef MESH_PAGES_HLSLI
#define MESH_PAGES_HLSLI

// Match MESH_PAGE_SIZE and MESH_PAGE_NONE in lib/engine/asset/format/mesh.odin, and MESH_PAGE_ABSENT and
// MESH_PAGE_SLOT_SHIFT in lib/engine/render/mesh_pages.odin.
static const uint MESH_PAGE_SIZE = 131072;
static const uint MESH_PAGE_NONE = 0xffffffff;
static const uint MESH_PAGE_ABSENT = 0xffffffff;
static const uint MESH_PAGE_SLOT_SHIFT = 12;
static const uint MESH_PAGE_LOCAL_MASK = (1u << MESH_PAGE_SLOT_SHIFT) - 1;
// A table entry's size, and how many halvings find a page among the most pages that the table has, 2^16.
static const uint MESH_PAGE_ENTRY_SIZE = 8;
static const uint MESH_PAGE_SEARCH_STEPS = 17;

// Matches Mesh_Page_Header in lib/engine/asset/format/mesh.odin: what starts a page. Its Meshlet records follow it,
// and its streams are at these offsets in bytes from the page's start.
struct Mesh_Page_Header {
	uint meshlet_count;
	uint vertex_count;
	uint vertex_refs;
	uint triangles;
	uint positions;
	uint attributes;
	uint ref_words;
	uint triangle_words;
};

// mesh_page_slot is a table entry's slot, or MESH_PAGE_ABSENT for a page that is not resident.
uint mesh_page_slot(uint table, uint entry) {
	return cn_buffer(table).Load(entry * MESH_PAGE_ENTRY_SIZE);
}

// mesh_page_packed is a meshlet of a page in a slot as one word: the slot above MESH_PAGE_SLOT_SHIFT, and the
// meshlet's index in its page below.
uint mesh_page_packed(uint slot, uint local) {
	return slot << MESH_PAGE_SLOT_SHIFT | local;
}

// mesh_page_base is where a packed meshlet's page starts in the pool, in bytes.
uint mesh_page_base(uint packed) {
	return (packed >> MESH_PAGE_SLOT_SHIFT) * MESH_PAGE_SIZE;
}

// mesh_page_meshlet is where a packed meshlet's record is in the pool, in bytes: after its page's header.
uint mesh_page_meshlet(uint packed) {
	return mesh_page_base(packed) + 32 + (packed & MESH_PAGE_LOCAL_MASK) * 72;
}

// mesh_page_find packs a meshlet of a mesh, by its index among the mesh's meshlets, or gives MESH_PAGE_ABSENT when its
// page is not resident. The mesh's pages are `count` entries of the table from `first`, in the order of their
// meshlets, so it halves them to the last page that starts at or before the meshlet. A draw without a selection
// finds its meshlets this way.
uint mesh_page_find(uint table, uint first, uint count, uint meshlet) {
	uint low = 0;
	uint high = count;
	for (uint step = 0; step < MESH_PAGE_SEARCH_STEPS && high - low > 1; step++) {
		uint middle = (low + high) / 2;
		if (cn_buffer(table).Load((first + middle) * MESH_PAGE_ENTRY_SIZE + 4) <= meshlet) {
			low = middle;
		} else {
			high = middle;
		}
	}
	uint2 entry = cn_buffer(table).Load2((first + low) * MESH_PAGE_ENTRY_SIZE);
	if (count == 0 || entry.x == MESH_PAGE_ABSENT || meshlet < entry.y) {
		return MESH_PAGE_ABSENT;
	}
	return mesh_page_packed(entry.x, meshlet - entry.y);
}

#endif
