// The cooker's C interface to LightUSD (vendor/lightusd), which tools/cook/usd.odin binds. One handle holds one composed
// stage, converted to render data by Tydra: nodes, triangulated meshes, UsdPreviewSurface materials and the textures
// they read. Strings and arrays stay valid until cn_usd_close, except a mesh's, which stay valid until the next
// cn_usd_mesh call. See docs/content/kinds/stages.md.
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Cn_Usd Cn_Usd;

typedef struct {
	const char *ptr;
	size_t len;
} Cn_Usd_String;

typedef enum {
	CN_USD_UP_Y = 0,
	CN_USD_UP_Z = 1,
} Cn_Usd_Up;

typedef struct {
	int32_t up; // Cn_Usd_Up
	double meters_per_unit;
	int32_t node_count;
	int32_t mesh_count;
	int32_t material_count;
	int32_t texture_count;
	int32_t instance_count;
	int32_t light_count;
	int32_t layer_count;
} Cn_Usd_Info;

typedef enum {
	CN_USD_NODE_GROUP = 0,
	CN_USD_NODE_MESH = 1,
	CN_USD_NODE_CAMERA = 2,
	CN_USD_NODE_LIGHT = 3,
	CN_USD_NODE_OTHER = 4,
} Cn_Usd_Node_Kind;

// A prim in pre-order: a node's parent comes before it.
typedef struct {
	int32_t parent; // -1 for a root
	int32_t kind;   // Cn_Usd_Node_Kind
	int32_t mesh;   // index of the mesh for CN_USD_NODE_MESH, else -1
	int32_t visible;
	Cn_Usd_String name;
	Cn_Usd_String path;
	// Row-major, for row vectors, as USD stores it: p' = p * local.
	double local[16];
	double world[16];
} Cn_Usd_Node;

// A point instancer's point, or an instance of a prototype: a mesh placed by a world matrix.
typedef struct {
	int32_t mesh;
	int32_t material; // overrides the mesh's material when >= 0
	int32_t visible;
	Cn_Usd_String path;
	double world[16];
} Cn_Usd_Instance;

// A run of a mesh's corners that one material draws.
typedef struct {
	int32_t material; // -1 when nothing is bound
	int32_t first;    // first corner
	int32_t count;    // corners, 3 per triangle
	Cn_Usd_String name;
} Cn_Usd_Subset;

// A triangulated mesh as corners, 3 per triangle, in the stage's units and axes, grouped by subset. Arrays a mesh does
// not have are null.
typedef struct {
	Cn_Usd_String name;
	Cn_Usd_String path;
	int32_t double_sided;
	int32_t left_handed; // orientation = "leftHanded"
	int32_t corner_count;
	const float *positions; // 3 per corner
	const float *normals;   // 3 per corner
	const float *uv0;       // 2 per corner, v up as USD has it
	const float *uv1;       // 2 per corner
	const float *colors;    // 3 per corner, displayColor
	int32_t subset_count;
	const Cn_Usd_Subset *subsets;
} Cn_Usd_Mesh;

typedef enum {
	CN_USD_CHANNEL_R = 0,
	CN_USD_CHANNEL_G = 1,
	CN_USD_CHANNEL_B = 2,
	CN_USD_CHANNEL_A = 3,
	CN_USD_CHANNEL_RGB = 4,
	CN_USD_CHANNEL_RGBA = 5,
} Cn_Usd_Channel;

// A UsdPreviewSurface input: a texture when texture >= 0, else value.
typedef struct {
	int32_t texture;
	int32_t channel; // Cn_Usd_Channel that the input reads
	float value[3];
} Cn_Usd_Input;

typedef struct {
	Cn_Usd_String name;
	Cn_Usd_String path;
	int32_t preview_surface; // 0 when the material has no UsdPreviewSurface
	int32_t specular_workflow;
	Cn_Usd_Input diffuse;
	Cn_Usd_Input emissive;
	Cn_Usd_Input metallic;
	Cn_Usd_Input roughness;
	Cn_Usd_Input opacity;
	Cn_Usd_Input normal;
	Cn_Usd_Input occlusion;
	float opacity_threshold;
} Cn_Usd_Material;

typedef enum {
	CN_USD_COLOR_AUTO = 0,
	CN_USD_COLOR_SRGB = 1,
	CN_USD_COLOR_RAW = 2,
} Cn_Usd_Color_Space;

typedef enum {
	CN_USD_WRAP_REPEAT = 0,
	CN_USD_WRAP_CLAMP = 1,
	CN_USD_WRAP_MIRROR = 2,
	CN_USD_WRAP_BLACK = 3,
} Cn_Usd_Wrap;

// A UsdUVTexture: the image file it reads, and how.
typedef struct {
	Cn_Usd_String asset;    // as authored
	Cn_Usd_String resolved; // a file path, or empty when the file was not found
	int32_t color_space;    // Cn_Usd_Color_Space
	int32_t wrap_s;         // Cn_Usd_Wrap
	int32_t wrap_t;
	Cn_Usd_String uv_name; // the primvar the texture reads its coordinates from
	float scale[4];
	float bias[4];
	int32_t has_transform;
	float transform_scale[2];
	float transform_rotation; // degrees
	float transform_translation[2];
} Cn_Usd_Texture;

typedef struct {
	// Expand point instancers into instances. Off, they are left out.
	int32_t point_instancers;
} Cn_Usd_Options;

// Opens, composes and converts the stage at path. It returns a handle even when it fails: check cn_usd_error.
Cn_Usd *cn_usd_open(const char *path, const Cn_Usd_Options *options);
void cn_usd_close(Cn_Usd *usd);
// Empty when the stage opened.
Cn_Usd_String cn_usd_error(Cn_Usd *usd);
Cn_Usd_String cn_usd_warnings(Cn_Usd *usd);
void cn_usd_info(Cn_Usd *usd, Cn_Usd_Info *info);
// A layer the stage was composed from, as a file path.
Cn_Usd_String cn_usd_layer(Cn_Usd *usd, int32_t index);
void cn_usd_node(Cn_Usd *usd, int32_t index, Cn_Usd_Node *node);
void cn_usd_instance(Cn_Usd *usd, int32_t index, Cn_Usd_Instance *instance);
// False when the mesh cannot be made into corners.
int32_t cn_usd_mesh(Cn_Usd *usd, int32_t index, Cn_Usd_Mesh *mesh);
void cn_usd_material(Cn_Usd *usd, int32_t index, Cn_Usd_Material *material);
void cn_usd_texture(Cn_Usd *usd, int32_t index, Cn_Usd_Texture *texture);

#ifdef __cplusplus
}
#endif
