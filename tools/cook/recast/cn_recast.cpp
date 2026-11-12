// The cooker's C interface to Recast. See cn_recast.h.
#include "cn_recast.h"

#include <exception>
#include <vector>

#include "Recast.h"

namespace {

// Tile_Meshes owns what a tile's bake gives back.
struct Tile_Meshes {
    rcPolyMesh *poly = nullptr;
    rcPolyMeshDetail *detail = nullptr;

    ~Tile_Meshes() {
        rcFreePolyMesh(poly);
        rcFreePolyMeshDetail(detail);
    }
};

// The intermediate steps' memory, which goes when the bake ends.
struct Scratch {
    rcHeightfield *heightfield = nullptr;
    rcCompactHeightfield *compact = nullptr;
    rcContourSet *contours = nullptr;

    ~Scratch() {
        rcFreeHeightField(heightfield);
        rcFreeCompactHeightfield(compact);
        rcFreeContourSet(contours);
    }
};

// The polygons have at most this many vertices, as the blob's do.
constexpr int MAX_VERTICES = 6;

bool bake(const Cn_Recast_Tile_In &in, Tile_Meshes &meshes) {
    // Without logging or timers, so a context is cheap and each call has its own.
    rcContext context(false);
    Scratch scratch;
    scratch.heightfield = rcAllocHeightfield();
    if (!scratch.heightfield ||
        !rcCreateHeightfield(&context, *scratch.heightfield, in.width, in.height, in.bounds_min, in.bounds_max, in.cell_size, in.cell_height)) {
        return false;
    }
    std::vector<unsigned char> areas(static_cast<size_t>(in.triangle_count), RC_NULL_AREA);
    rcMarkWalkableTriangles(&context, in.walkable_slope, in.vertices, in.vertex_count, in.triangles, in.triangle_count, areas.data());
    if (!rcRasterizeTriangles(&context, in.vertices, in.vertex_count, in.triangles, areas.data(), in.triangle_count, *scratch.heightfield, in.walkable_climb)) {
        return false;
    }
    rcFilterLowHangingWalkableObstacles(&context, in.walkable_climb, *scratch.heightfield);
    rcFilterLedgeSpans(&context, in.walkable_height, in.walkable_climb, *scratch.heightfield);
    rcFilterWalkableLowHeightSpans(&context, in.walkable_height, *scratch.heightfield);

    scratch.compact = rcAllocCompactHeightfield();
    if (!scratch.compact ||
        !rcBuildCompactHeightfield(&context, in.walkable_height, in.walkable_climb, *scratch.heightfield, *scratch.compact)) {
        return false;
    }
    rcFreeHeightField(scratch.heightfield);
    scratch.heightfield = nullptr;
    if (!rcErodeWalkableArea(&context, in.walkable_radius, *scratch.compact) ||
        !rcBuildDistanceField(&context, *scratch.compact) ||
        !rcBuildRegions(&context, *scratch.compact, in.border, in.min_region_area, in.merge_region_area)) {
        return false;
    }

    scratch.contours = rcAllocContourSet();
    if (!scratch.contours ||
        !rcBuildContours(&context, *scratch.compact, in.max_simplification_error, in.max_edge_length, *scratch.contours)) {
        return false;
    }
    meshes.poly = rcAllocPolyMesh();
    if (!meshes.poly || !rcBuildPolyMesh(&context, *scratch.contours, MAX_VERTICES, *meshes.poly)) {
        return false;
    }
    meshes.detail = rcAllocPolyMeshDetail();
    if (!meshes.detail ||
        !rcBuildPolyMeshDetail(&context, *meshes.poly, *scratch.compact, in.detail_sample_distance, in.detail_sample_max_error, *meshes.detail)) {
        return false;
    }
    return true;
}

} // namespace

extern "C" {

int32_t cn_recast_bake_tile(const Cn_Recast_Tile_In *in, Cn_Recast_Tile_Out *out) {
    *out = {};
    Tile_Meshes *meshes = nullptr;
    try {
        meshes = new Tile_Meshes();
        if (!bake(*in, *meshes)) {
            delete meshes;
            return -1;
        }
    } catch (const std::exception &) {
        delete meshes;
        return -1;
    }
    const rcPolyMesh &poly = *meshes->poly;
    const rcPolyMeshDetail &detail = *meshes->detail;
    out->vertices = poly.verts;
    out->vertex_count = poly.nverts;
    out->polygons = poly.polys;
    out->polygon_count = poly.npolys;
    out->max_vertices = poly.nvp;
    for (int i = 0; i < 3; i++) {
        out->bounds_min[i] = poly.bmin[i];
    }
    out->detail_meshes = detail.meshes;
    out->detail_vertices = detail.verts;
    out->detail_vertex_count = detail.nverts;
    out->detail_triangles = detail.tris;
    out->detail_triangle_count = detail.ntris;
    out->internal = meshes;
    return 0;
}

void cn_recast_tile_free(Cn_Recast_Tile_Out *out) {
    delete static_cast<Tile_Meshes *>(out->internal);
    *out = {};
}

} // extern "C"
