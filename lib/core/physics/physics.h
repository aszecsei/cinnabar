// The physics boundary in C: the same layouts as lib/core/physics/physics.odin, for backends written in C or C++.
// See docs/physics/design.md#the-boundary. A change on either side must change the other, and both assert the sizes.
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CN_PHYSICS_API_VERSION 7
#define CN_PHYSICS_MAX_COMPOUND_CHILDREN 1024
#define CN_PHYSICS_MAX_LAYERS 32
#define CN_PHYSICS_MAX_QUERY_IGNORE 8

typedef struct cn_handle { uint32_t index, generation; } cn_handle;
typedef cn_handle cn_world;
typedef cn_handle cn_body;
typedef cn_handle cn_shape;
typedef cn_handle cn_joint;

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
    // cn_physics_layout(), which the host compares with its own.
    uint32_t layout, _pad;
    const char* name;
    const char* version;
} cn_backend_info;

typedef struct cn_world_desc {
    uint32_t max_bodies, max_shapes, max_body_pairs, max_contact_constraints, temp_size, max_joints;
} cn_world_desc;

enum cn_motion { CN_MOTION_STATIC, CN_MOTION_KINEMATIC, CN_MOTION_DYNAMIC };
enum cn_shape_kind { CN_SHAPE_BOX, CN_SHAPE_SPHERE, CN_SHAPE_CAPSULE, CN_SHAPE_CYLINDER, CN_SHAPE_MESH, CN_SHAPE_CONVEX_HULL };

enum cn_body_flag {
    CN_BODY_SENSOR = 1u << 0,
    CN_BODY_CCD = 1u << 1,
    CN_BODY_START_ASLEEP = 1u << 2,
    CN_BODY_REPORT_CONTACTS = 1u << 3,
    CN_BODY_DETECT_STATIC = 1u << 4,
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
    CN_CMD_SET_ENABLED,
    CN_CMD_CREATE_COMPOUND,
    CN_CMD_CREATE_JOINT,
    CN_CMD_DESTROY_JOINT,
    CN_CMD_SET_JOINT,
};

enum cn_joint_kind { CN_JOINT_FIXED, CN_JOINT_POINT, CN_JOINT_HINGE, CN_JOINT_SLIDER, CN_JOINT_DISTANCE, CN_JOINT_CONE, CN_JOINT_SIX_DOF };
enum cn_joint_flag { CN_JOINT_COLLIDE_CONNECTED = 1u << 0, CN_JOINT_DISABLED = 1u << 1, CN_JOINT_HAS_LIMITS = 1u << 2 };
enum cn_motor_mode { CN_MOTOR_OFF, CN_MOTOR_VELOCITY, CN_MOTOR_POSITION };

typedef struct cn_command_header { uint16_t kind, size; uint32_t _pad; } cn_command_header;

typedef struct cn_set_world {
    float gravity[3];
    uint32_t _pad;
    uint32_t collides[CN_PHYSICS_MAX_LAYERS];
} cn_set_world;

typedef struct cn_create_shape {
    cn_shape shape;
    uint8_t kind, _pad[3];
    float size[3];
    float density;
    float offset[3];
    float rotation[4];
} cn_create_shape;

typedef struct cn_release_shape { cn_shape shape; } cn_release_shape;
// count cn_shape handles follow.
typedef struct cn_create_compound { cn_shape shape; uint32_t count, _pad; } cn_create_compound;

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

typedef struct cn_create_joint {
    cn_joint joint;
    cn_body a, b;
    uint8_t kind, flags, motor, _pad0;
    float limit_min, limit_max;
    float spring_frequency, spring_damping;
    float motor_target, motor_max;
    float break_force, break_torque;
    uint32_t _pad1;
    double position_a[3];
    float rotation_a[4];
    double position_b[3];
    float rotation_b[4];
    float six_min[6], six_max[6];
} cn_create_joint;

typedef struct cn_destroy_joint { cn_joint joint; } cn_destroy_joint;

typedef struct cn_set_joint {
    cn_joint joint;
    uint32_t enabled;
    uint8_t motor, _pad[3];
    float motor_target, motor_max;
} cn_set_joint;

typedef struct cn_joint_break { cn_joint joint; float force, torque; } cn_joint_break;
typedef struct cn_set_enabled { cn_body body; uint32_t enabled, _pad; } cn_set_enabled;

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

enum cn_contact_kind { CN_CONTACT_BEGIN, CN_CONTACT_END };

typedef struct cn_contact_event {
    uint8_t kind, sensor, _pad0[6];
    cn_body a, b;
    uint64_t a_user, b_user;
    double point[3];
    float normal[3];
    float relative_velocity[3];
    float impulse;
    uint32_t _pad1;
} cn_contact_event;

typedef struct cn_step_results {
    const cn_body_state* moved;
    uint32_t moved_count, contact_count;
    const cn_contact_event* contacts;
    const cn_joint_break* broken;
    uint32_t broken_count, _pad;
} cn_step_results;

typedef struct cn_ray { double origin[3]; float direction[3]; float max_distance; } cn_ray;

enum cn_query_flag { CN_QUERY_INCLUDE_SENSORS = 1u << 0 };

typedef struct cn_query_filter {
    uint32_t layers, flags, ignore_count, _pad;
    cn_body ignore[CN_PHYSICS_MAX_QUERY_IGNORE];
} cn_query_filter;

typedef struct cn_shape_desc { uint8_t kind, _pad[3]; float size[3]; } cn_shape_desc;

typedef struct cn_shape_cast {
    double origin[3];
    float rotation[4];
    float direction[3];
    float distance;
    cn_shape_desc shape;
} cn_shape_cast;

typedef struct cn_overlap_query {
    double origin[3];
    float rotation[4];
    cn_shape_desc shape;
} cn_overlap_query;

typedef struct cn_overlap_hit { cn_body body; uint64_t user; } cn_overlap_hit;

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
    uint32_t (*create_mesh_shape)(cn_world world, cn_shape shape, uint8_t kind, const float (*vertices)[3], uint32_t vertex_count,
        const uint32_t (*triangles)[3], uint32_t triangle_count, float density);
    uint32_t (*raycast)(cn_world world, const cn_ray* ray, const cn_query_filter* filter, cn_ray_hit* hit);
    uint32_t (*raycast_all)(cn_world world, const cn_ray* ray, const cn_query_filter* filter, cn_ray_hit* out, uint32_t capacity);
    void (*raycast_batch)(cn_world world, const cn_ray* rays, uint32_t count, const cn_query_filter* filter, cn_ray_hit* out);
    uint32_t (*shape_cast)(cn_world world, const cn_shape_cast* cast, const cn_query_filter* filter, cn_ray_hit* hit);
    uint32_t (*overlap)(cn_world world, const cn_overlap_query* query, const cn_query_filter* filter, cn_overlap_hit* out, uint32_t capacity);
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

// cn_physics_layout is an FNV-1a hash of the sizes of every type that crosses the boundary, in physics.odin's order,
// for Backend_Info.layout (see docs/physics/backends.md#loading).
static inline uint32_t cn_physics_layout(void)
{
    const uint32_t sizes[] = {
        (uint32_t)sizeof(cn_command_header),
        (uint32_t)sizeof(cn_set_world),
        (uint32_t)sizeof(cn_create_shape),
        (uint32_t)sizeof(cn_release_shape),
        (uint32_t)sizeof(cn_create_body),
        (uint32_t)sizeof(cn_destroy_body),
        (uint32_t)sizeof(cn_set_pose),
        (uint32_t)sizeof(cn_move_kinematic),
        (uint32_t)sizeof(cn_set_velocity),
        (uint32_t)sizeof(cn_add_vector),
        (uint32_t)sizeof(cn_add_force_at),
        (uint32_t)sizeof(cn_body_command),
        (uint32_t)sizeof(cn_set_enabled),
        (uint32_t)sizeof(cn_create_compound),
        (uint32_t)sizeof(cn_create_joint),
        (uint32_t)sizeof(cn_destroy_joint),
        (uint32_t)sizeof(cn_set_joint),
        (uint32_t)sizeof(cn_world_desc),
        (uint32_t)sizeof(cn_backend_info),
        (uint32_t)sizeof(cn_body_state),
        (uint32_t)sizeof(cn_step_results),
        (uint32_t)sizeof(cn_contact_event),
        (uint32_t)sizeof(cn_joint_break),
        (uint32_t)sizeof(cn_ray),
        (uint32_t)sizeof(cn_query_filter),
        (uint32_t)sizeof(cn_ray_hit),
        (uint32_t)sizeof(cn_shape_desc),
        (uint32_t)sizeof(cn_shape_cast),
        (uint32_t)sizeof(cn_overlap_query),
        (uint32_t)sizeof(cn_overlap_hit),
        (uint32_t)sizeof(cn_physics_api),
        (uint32_t)sizeof(cn_physics_host),
    };
    uint32_t h = 0x811c9dc5u;
    for (size_t i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++) {
        for (int b = 0; b < 4; b++) {
            h = (h ^ ((sizes[i] >> (8 * b)) & 0xffu)) * 0x01000193u;
        }
    }
    return h;
}

#ifdef __cplusplus
}

static_assert(sizeof(cn_command_header) == 8);
static_assert(sizeof(cn_set_world) == 144);
static_assert(sizeof(cn_create_shape) == 56);
static_assert(sizeof(cn_set_enabled) == 16);
static_assert(sizeof(cn_create_compound) == 16);
static_assert(sizeof(cn_create_body) == 120);
static_assert(sizeof(cn_set_pose) == 56);
static_assert(sizeof(cn_move_kinematic) == 56);
static_assert(sizeof(cn_set_velocity) == 32);
static_assert(sizeof(cn_add_vector) == 24);
static_assert(sizeof(cn_add_force_at) == 48);
static_assert(sizeof(cn_world_desc) == 24);
static_assert(sizeof(cn_backend_info) == 32);
static_assert(sizeof(cn_body_state) == 88);
static_assert(sizeof(cn_step_results) == 40);
static_assert(sizeof(cn_create_joint) == 192);
static_assert(sizeof(cn_set_joint) == 24);
static_assert(sizeof(cn_joint_break) == 16);
static_assert(sizeof(cn_contact_event) == 96);
static_assert(sizeof(cn_shape_desc) == 16);
static_assert(sizeof(cn_shape_cast) == 72);
static_assert(sizeof(cn_overlap_query) == 56);
static_assert(sizeof(cn_overlap_hit) == 16);
static_assert(sizeof(cn_ray) == 40);
static_assert(sizeof(cn_query_filter) == 80);
static_assert(sizeof(cn_ray_hit) == 64);
static_assert(sizeof(cn_physics_api) == 16 * sizeof(void*));
static_assert(sizeof(cn_physics_host) == 7 * sizeof(void*));
static_assert(sizeof(cn_counter) == 16);
#endif
