// The physics boundary in C: the same layouts as lib/core/physics/physics.odin, for backends written in C or C++.
// See docs/physics/design.md#the-boundary. A change on either side must change the other, and both assert the sizes.
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CN_PHYSICS_API_VERSION 1
#define CN_PHYSICS_MAX_LAYERS 32
#define CN_PHYSICS_MAX_QUERY_IGNORE 8

typedef struct cn_handle { uint32_t index, generation; } cn_handle;
typedef cn_handle cn_world;
typedef cn_handle cn_body;
typedef cn_handle cn_shape;

enum cn_feature {
    CN_FEATURE_RIGID_BODIES = 1u << 0,
    CN_FEATURE_JOINTS = 1u << 1,
    CN_FEATURE_QUERIES = 1u << 2,
    CN_FEATURE_SENSORS = 1u << 3,
    CN_FEATURE_CHARACTERS = 1u << 4,
    CN_FEATURE_VEHICLES = 1u << 5,
    CN_FEATURE_SOFT_BODIES = 1u << 6,
    CN_FEATURE_CLOTH = 1u << 7,
    CN_FEATURE_HAIR = 1u << 8,
    CN_FEATURE_BUOYANCY = 1u << 9,
    CN_FEATURE_DETERMINISTIC = 1u << 10,
    CN_FEATURE_DOUBLE_PRECISION = 1u << 11,
    CN_FEATURE_SAVE_STATE = 1u << 12,
};

typedef struct cn_backend_info {
    uint32_t api_version;
    uint32_t features;
    const char* name;
    const char* version;
} cn_backend_info;

typedef struct cn_world_desc {
    uint32_t max_bodies, max_shapes, max_body_pairs, max_contact_constraints, temp_size, _pad;
} cn_world_desc;

enum cn_motion { CN_MOTION_STATIC, CN_MOTION_KINEMATIC, CN_MOTION_DYNAMIC };
enum cn_shape_kind { CN_SHAPE_BOX, CN_SHAPE_SPHERE, CN_SHAPE_CAPSULE, CN_SHAPE_CYLINDER };

enum cn_body_flag {
    CN_BODY_SENSOR = 1u << 0,
    CN_BODY_CCD = 1u << 1,
    CN_BODY_START_ASLEEP = 1u << 2,
};

enum cn_command_kind {
    CN_CMD_SET_WORLD,
    CN_CMD_CREATE_SHAPE,
    CN_CMD_RELEASE_SHAPE,
    CN_CMD_CREATE_BODY,
    CN_CMD_DESTROY_BODY,
    CN_CMD_SET_POSE,
    CN_CMD_MOVE_KINEMATIC,
    CN_CMD_SET_VELOCITY,
    CN_CMD_ADD_FORCE,
    CN_CMD_ADD_FORCE_AT,
    CN_CMD_ADD_TORQUE,
    CN_CMD_ADD_IMPULSE,
    CN_CMD_ADD_ANGULAR_IMPULSE,
    CN_CMD_ACTIVATE,
    CN_CMD_DEACTIVATE,
};

typedef struct cn_command_header { uint16_t kind, size; uint32_t _pad; } cn_command_header;

typedef struct cn_set_world {
    float gravity[3];
    uint32_t _pad;
    uint32_t collides[CN_PHYSICS_MAX_LAYERS];
} cn_set_world;

typedef struct cn_create_shape {
    cn_shape shape;
    uint8_t kind, _pad0[3];
    float size[3];
    float density;
    uint32_t _pad1;
} cn_create_shape;

typedef struct cn_release_shape { cn_shape shape; } cn_release_shape;

typedef struct cn_create_body {
    cn_body body;
    cn_shape shape;
    double position[3];
    float rotation[4];
    float linear_velocity[3];
    float angular_velocity[3];
    uint64_t user;
    uint8_t motion, layer;
    uint16_t flags;
    float mass, friction, restitution, linear_damping, angular_damping, gravity_factor;
    uint32_t _pad;
} cn_create_body;

typedef struct cn_destroy_body { cn_body body; } cn_destroy_body;

typedef struct cn_set_pose {
    cn_body body;
    double position[3];
    float rotation[4];
    uint32_t activate, _pad;
} cn_set_pose;

typedef struct cn_move_kinematic {
    cn_body body;
    double position[3];
    float rotation[4];
    float dt;
    uint32_t _pad;
} cn_move_kinematic;

typedef struct cn_set_velocity { cn_body body; float linear[3], angular[3]; } cn_set_velocity;
typedef struct cn_add_vector { cn_body body; float vector[3]; uint32_t _pad; } cn_add_vector;
typedef struct cn_add_force_at { cn_body body; float force[3]; uint32_t _pad; double point[3]; } cn_add_force_at;
typedef struct cn_body_command { cn_body body; } cn_body_command;

enum cn_body_state_flag { CN_BODY_STATE_ASLEEP = 1u << 0 };

typedef struct cn_body_state {
    cn_body body;
    uint64_t user;
    double position[3];
    float rotation[4];
    float linear_velocity[3];
    float angular_velocity[3];
    uint32_t flags, _pad;
} cn_body_state;

typedef struct cn_step_results {
    const cn_body_state* moved;
    uint32_t moved_count, _pad;
} cn_step_results;

typedef struct cn_ray { double origin[3]; float direction[3]; float max_distance; } cn_ray;

enum cn_query_flag { CN_QUERY_INCLUDE_SENSORS = 1u << 0 };

typedef struct cn_query_filter {
    uint32_t layers, flags, ignore_count, _pad;
    cn_body ignore[CN_PHYSICS_MAX_QUERY_IGNORE];
} cn_query_filter;

typedef struct cn_ray_hit {
    cn_body body;
    uint64_t user;
    double position[3];
    float normal[3];
    float distance;
    uint32_t sub_shape, _pad;
} cn_ray_hit;

typedef struct cn_physics_api {
    cn_backend_info (*info)(void);
    cn_world (*world_create)(const cn_world_desc* desc);
    void (*world_destroy)(cn_world world);
    uint32_t (*submit)(cn_world world, const void* data, uint32_t size);
    uint32_t (*step)(cn_world world, float dt, int32_t substeps);
    void (*results)(cn_world world, cn_step_results* out);
    void (*body_state)(cn_world world, const cn_body* bodies, uint32_t count, cn_body_state* out);
    uint32_t (*raycast)(cn_world world, const cn_ray* ray, const cn_query_filter* filter, cn_ray_hit* hit);
    void (*run_job)(void* data);
    int32_t (*world_destroy_all)(void);
    void (*shutdown)(void);
} cn_physics_api;

// The host's jobs.Counter: zero-initialized, and touched only by the host.
typedef struct cn_counter { intptr_t value; void* waiters; } cn_counter;

enum cn_log_level { CN_LOG_DEBUG, CN_LOG_INFO, CN_LOG_WARNING, CN_LOG_ERROR };

typedef struct cn_physics_host {
    void* (*allocate)(size_t size, size_t align);
    void* (*reallocate)(void* ptr, size_t old_size, size_t new_size, size_t align);
    void (*free)(void* ptr);
    void (*jobs_run)(void* const* data, uint32_t count, cn_counter* counter);
    void (*jobs_wait)(cn_counter* counter);
    uint32_t (*worker_count)(void);
    void (*log)(int32_t level, const char* message);
} cn_physics_host;

#ifdef __cplusplus
}

static_assert(sizeof(cn_command_header) == 8);
static_assert(sizeof(cn_set_world) == 144);
static_assert(sizeof(cn_create_shape) == 32);
static_assert(sizeof(cn_create_body) == 120);
static_assert(sizeof(cn_set_pose) == 56);
static_assert(sizeof(cn_move_kinematic) == 56);
static_assert(sizeof(cn_set_velocity) == 32);
static_assert(sizeof(cn_add_vector) == 24);
static_assert(sizeof(cn_add_force_at) == 48);
static_assert(sizeof(cn_world_desc) == 24);
static_assert(sizeof(cn_backend_info) == 24);
static_assert(sizeof(cn_body_state) == 88);
static_assert(sizeof(cn_step_results) == 16);
static_assert(sizeof(cn_ray) == 40);
static_assert(sizeof(cn_query_filter) == 80);
static_assert(sizeof(cn_ray_hit) == 64);
static_assert(sizeof(cn_physics_api) == 11 * sizeof(void*));
static_assert(sizeof(cn_physics_host) == 7 * sizeof(void*));
static_assert(sizeof(cn_counter) == 16);
#endif
