/*
 * The cooker's C interface to Recast (see docs/content/kinds/nav-meshes.md#recast). cn_recast_bake_tile bakes one tile
 * of a navmesh from its triangles: a heightfield, its walkable spans, regions, contours, a mesh of convex polygons and a
 * detail mesh of their surface. Each call has its own memory, so tiles bake on many threads at once. A tile's output is
 * freed with cn_recast_tile_free.
 */
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Matches Recast_Tile_In in tools/cook/recast.odin. */
typedef struct Cn_Recast_Tile_In {
    /* x, y, z for each vertex, and three vertex indices for each triangle. */
    const float *vertices;
    int32_t vertex_count;
    const int32_t *triangles;
    int32_t triangle_count;
    /* The heightfield's bounds, the tile's with its border, and its cells across: the tile's and the border's. */
    float bounds_min[3];
    float bounds_max[3];
    int32_t width;
    int32_t height;
    int32_t border;
    float cell_size;
    float cell_height;
    /* In degrees. */
    float walkable_slope;
    /* In cells: the agent's height and step in cell_height, and its radius in cell_size. */
    int32_t walkable_height;
    int32_t walkable_climb;
    int32_t walkable_radius;
    /* In cells: a region smaller than min_region_area goes, and one smaller than merge_region_area joins another. */
    int32_t min_region_area;
    int32_t merge_region_area;
    /* In cells, and in cells off the region's edge. */
    int32_t max_edge_length;
    float max_simplification_error;
    /* In meters. */
    float detail_sample_distance;
    float detail_sample_max_error;
} Cn_Recast_Tile_In;

/* Matches Recast_Tile_Out in tools/cook/recast.odin. */
typedef struct Cn_Recast_Tile_Out {
    /* x, y, z in cells for each vertex, from bounds_min: the tile's corner, without the border. */
    const uint16_t *vertices;
    int32_t vertex_count;
    /* 2 * max_vertices for each polygon: its vertices, then its neighbors, 0xffff for none, and 0x8000 | side for an
     * edge on the tile's border, as Recast gives them. */
    const uint16_t *polygons;
    int32_t polygon_count;
    int32_t max_vertices;
    float bounds_min[3];
    /* 4 for each polygon: its first detail vertex, their count, its first detail triangle, their count. */
    const uint32_t *detail_meshes;
    /* x, y, z in meters for each detail vertex. */
    const float *detail_vertices;
    int32_t detail_vertex_count;
    /* 4 for each detail triangle: three of its polygon's detail vertices and the edge flags. */
    const uint8_t *detail_triangles;
    int32_t detail_triangle_count;
    /* The Recast meshes that own the arrays. */
    void *internal;
} Cn_Recast_Tile_Out;

/* Bakes a tile. Returns 0, or -1 when Recast fails, and then out holds nothing to free. */
int32_t cn_recast_bake_tile(const Cn_Recast_Tile_In *in, Cn_Recast_Tile_Out *out);

/* Frees a tile's output. Freeing an empty output does nothing. */
void cn_recast_tile_free(Cn_Recast_Tile_Out *out);

#ifdef __cplusplus
} /* extern "C" */
#endif
