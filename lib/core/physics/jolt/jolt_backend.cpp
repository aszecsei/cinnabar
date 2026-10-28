// The Jolt backend: Physics_API over JPH::PhysicsSystem. It is host code, built into physics_jolt.dll in development
// and linked statically in release, so that no Jolt object points into the game DLL (see
// docs/physics/design.md#where-jolt-lives). It stores nothing of the game's: filters are tables, and what the
// simulation reports goes into arrays that the game reads after the step.
#include <Jolt/Jolt.h>

#include <Jolt/Core/Factory.h>
#include <Jolt/Core/FixedSizeFreeList.h>
#include <Jolt/Core/JobSystemWithBarrier.h>
#include <Jolt/Core/Mutex.h>
#include <Jolt/Core/QuickSort.h>
#include <Jolt/Core/TempAllocator.h>
#include <Jolt/Physics/Body/BodyActivationListener.h>
#include <Jolt/Physics/Body/BodyCreationSettings.h>
#include <Jolt/Physics/Collision/CastResult.h>
#include <Jolt/Physics/Collision/RayCast.h>
#include <Jolt/Physics/Collision/Shape/BoxShape.h>
#include <Jolt/Physics/Collision/Shape/CapsuleShape.h>
#include <Jolt/Physics/Collision/Shape/CylinderShape.h>
#include <Jolt/Physics/Collision/Shape/SphereShape.h>
#include <Jolt/Physics/PhysicsSystem.h>
#include <Jolt/RegisterTypes.h>

#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>

#include "physics.h"

using namespace JPH;

namespace {

constexpr uint32 MAX_WORLDS = 16;
constexpr uint32 MAX_JOBS = 4096;
constexpr uint32 MAX_BARRIERS = 16;
// Jolt rounds sharp corners of convex shapes by this much; a shape smaller than twice it uses half its size.
constexpr float CONVEX_RADIUS = 0.05f;
// A step after this many new bodies optimizes the broad phase first, as Jolt asks after a bulk load.
constexpr uint32 OPTIMIZE_AFTER = 256;

#define CN_STRINGIFY2(x) #x
#define CN_STRINGIFY(x) CN_STRINGIFY2(x)
constexpr const char* JOLT_VERSION =
    CN_STRINGIFY(JPH_VERSION_MAJOR) "." CN_STRINGIFY(JPH_VERSION_MINOR) "." CN_STRINGIFY(JPH_VERSION_PATCH);

const cn_physics_host* host = nullptr;

void report(int32_t level, const char* format, ...)
{
    char message[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(message, sizeof(message), format, args);
    va_end(args);
    host->log(level, message);
}

// Jolt's memory is the host's heap. An unaligned block gets malloc's alignment.
void* allocate(size_t size) { return host->allocate(size, 16); }
void* reallocate(void* block, size_t old_size, size_t new_size) { return host->reallocate(block, old_size, new_size, 16); }
void free_block(void* block) { host->free(block); }
void* aligned_allocate(size_t size, size_t align) { return host->allocate(size, align); }

void trace(const char* format, ...)
{
    char message[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(message, sizeof(message), format, args);
    va_end(args);
    host->log(CN_LOG_INFO, message);
}

#ifdef JPH_ENABLE_ASSERTS
bool assert_failed(const char* expression, const char* message, const char* file, uint line)
{
    report(CN_LOG_ERROR, "physics: Jolt assert %s:%u: (%s) %s", file, line, expression, message ? message : "");
    return true;
}
#endif

// Jolt's jobs run as the host's fiber jobs. A Jolt job runs to completion and never waits, so its fiber never moves
// threads in the middle of one. Only the caller of PhysicsSystem::Update waits, in the barrier, and then for the
// counter, so no fiber job that holds a Jolt job outlives the step (see docs/physics/design.md#where-jolt-lives).
class Fiber_Job_System final : public JobSystemWithBarrier {
public:
    JPH_OVERRIDE_NEW_DELETE

    Fiber_Job_System()
        : JobSystemWithBarrier(MAX_BARRIERS)
    {
        jobs.Init(MAX_JOBS, MAX_JOBS);
    }

    int GetMaxConcurrency() const override { return int(host->worker_count()); }

    JobHandle CreateJob(const char* name, ColorArg color, const JobFunction& function, uint32 dependencies) override
    {
        uint32 index = jobs.ConstructObject(name, color, this, function, dependencies);
        if (index == Jobs::cInvalidObjectIndex) {
            report(CN_LOG_ERROR, "physics: more than %u Jolt jobs at once", MAX_JOBS);
            std::abort();
        }
        Job* job = &jobs.Get(index);
        // The handle keeps a reference: the job may run and finish as soon as it is queued.
        JobHandle handle(job);
        if (dependencies == 0) {
            QueueJob(job);
        }
        return handle;
    }

    void QueueJob(Job* job) override { QueueJobs(&job, 1); }

    void QueueJobs(Job** queued, uint count) override
    {
        for (uint i = 0; i < count; i++) {
            queued[i]->AddRef();
        }
        host->jobs_run(reinterpret_cast<void* const*>(queued), uint32_t(count), &counter);
    }

    void FreeJob(Job* job) override { jobs.DestructObject(job); }

    // A barrier's waiter may have run the job already, which makes Execute do nothing.
    static void Run(void* data)
    {
        Job* job = static_cast<Job*>(data);
        job->Execute();
        job->Release();
    }

    void WaitForFiberJobs() { host->jobs_wait(&counter); }

private:
    using Jobs = FixedSizeFreeList<Job>;
    Jobs jobs;
    cn_counter counter = {};
};

// An object layer is the engine's layer in its low 5 bits, and MOVING for a kinematic or dynamic body, which picks
// the broad phase layer.
constexpr ObjectLayer LAYER_MASK = CN_PHYSICS_MAX_LAYERS - 1;
constexpr ObjectLayer MOVING = CN_PHYSICS_MAX_LAYERS;
constexpr BroadPhaseLayer BROAD_NON_MOVING(0);
constexpr BroadPhaseLayer BROAD_MOVING(1);

class Broad_Phase_Layers final : public BroadPhaseLayerInterface {
public:
    uint GetNumBroadPhaseLayers() const override { return 2; }
    BroadPhaseLayer GetBroadPhaseLayer(ObjectLayer layer) const override
    {
        return (layer & MOVING) ? BROAD_MOVING : BROAD_NON_MOVING;
    }
#if defined(JPH_EXTERNAL_PROFILE) || defined(JPH_PROFILE_ENABLED)
    const char* GetBroadPhaseLayerName(BroadPhaseLayer layer) const override
    {
        return layer == BROAD_MOVING ? "Moving" : "Non-moving";
    }
#endif
};

class Object_Vs_Broad_Phase final : public ObjectVsBroadPhaseLayerFilter {
public:
    bool ShouldCollide(ObjectLayer layer, BroadPhaseLayer broad) const override
    {
        return (layer & MOVING) || broad == BROAD_MOVING;
    }
};

// The collision matrix from Set_World: a pair collides when each layer is in the other's mask. Two non-moving bodies
// never do.
class Layer_Pairs final : public ObjectLayerPairFilter {
public:
    uint32 collides[CN_PHYSICS_MAX_LAYERS];

    Layer_Pairs() { memset(collides, 0xff, sizeof(collides)); }

    bool ShouldCollide(ObjectLayer a, ObjectLayer b) const override
    {
        if (!((a | b) & MOVING)) {
            return false;
        }
        uint32 la = a & LAYER_MASK, lb = b & LAYER_MASK;
        return ((collides[la] >> lb) & 1) && ((collides[lb] >> la) & 1);
    }
};

// A body that falls asleep in a step leaves the active list, so its last pose is reported from here.
class Activation_Listener final : public BodyActivationListener {
public:
    Mutex mutex;
    Array<BodyID> slept;

    void OnBodyActivated(const BodyID&, uint64) override { }
    void OnBodyDeactivated(const BodyID& id, uint64) override
    {
        UniqueLock lock(mutex);
        slept.push_back(id);
    }
};

class Layer_Mask_Filter final : public ObjectLayerFilter {
public:
    uint32 layers;
    explicit Layer_Mask_Filter(uint32 mask)
        : layers(mask)
    {
    }
    bool ShouldCollide(ObjectLayer layer) const override { return (layers >> (layer & LAYER_MASK)) & 1; }
};

struct Body_Slot {
    uint32 generation = 0;
    BodyID id;
};

struct Shape_Slot {
    uint32 generation = 0;
    RefConst<Shape> shape;
};

struct World_Impl {
    JPH_OVERRIDE_NEW_DELETE

    PhysicsSystem system;
    TempAllocatorImpl temp;
    Broad_Phase_Layers broad_layers;
    Object_Vs_Broad_Phase object_vs_broad;
    Layer_Pairs pairs;
    Activation_Listener activation;
    Array<Body_Slot> bodies;
    Array<Shape_Slot> shapes;
    // The engine's handle of each Jolt body, by BodyID index.
    Array<cn_body> handles;
    Array<cn_body_state> moved;
    uint32 added_since_optimize = 0;

    explicit World_Impl(const cn_world_desc& desc)
        : temp(desc.temp_size)
        , bodies(desc.max_bodies)
        , shapes(desc.max_shapes)
        , handles(desc.max_bodies)
    {
        system.Init(desc.max_bodies, 0, desc.max_body_pairs, desc.max_contact_constraints, broad_layers, object_vs_broad,
            pairs);
        system.SetBodyActivationListener(&activation);
    }
};

struct World_Entry {
    uint32 generation = 0;
    World_Impl* world = nullptr;
};

World_Entry worlds[MAX_WORLDS];
Fiber_Job_System* job_system = nullptr;

World_Impl* find_world(cn_world handle)
{
    if (handle.generation == 0 || handle.index >= MAX_WORLDS) {
        return nullptr;
    }
    World_Entry& entry = worlds[handle.index];
    return entry.generation == handle.generation ? entry.world : nullptr;
}

bool find_body(World_Impl& w, cn_body handle, BodyID& id)
{
    if (handle.generation == 0 || handle.index >= w.bodies.size()) {
        return false;
    }
    const Body_Slot& slot = w.bodies[handle.index];
    if (slot.generation != handle.generation || slot.id.IsInvalid()) {
        return false;
    }
    id = slot.id;
    return true;
}

const Shape* find_shape(World_Impl& w, cn_shape handle)
{
    if (handle.generation == 0 || handle.index >= w.shapes.size()) {
        return nullptr;
    }
    const Shape_Slot& slot = w.shapes[handle.index];
    return slot.generation == handle.generation ? slot.shape.GetPtr() : nullptr;
}

RVec3 to_rvec3(const double p[3]) { return RVec3(Real(p[0]), Real(p[1]), Real(p[2])); }
Vec3 to_vec3(const float v[3]) { return Vec3(v[0], v[1], v[2]); }
Quat to_quat(const float q[4]) { return Quat(q[0], q[1], q[2], q[3]).Normalized(); }

void from_rvec3(RVec3Arg v, double out[3])
{
    out[0] = double(v.GetX());
    out[1] = double(v.GetY());
    out[2] = double(v.GetZ());
}

void from_vec3(Vec3Arg v, float out[3])
{
    out[0] = v.GetX();
    out[1] = v.GetY();
    out[2] = v.GetZ();
}

void from_quat(QuatArg q, float out[4])
{
    out[0] = q.GetX();
    out[1] = q.GetY();
    out[2] = q.GetZ();
    out[3] = q.GetW();
}

ObjectLayer object_layer(uint8_t layer, uint8_t motion)
{
    return ObjectLayer(layer & LAYER_MASK) | (motion == CN_MOTION_STATIC ? 0 : MOVING);
}

Shape::ShapeResult create_shape(const cn_create_shape& c)
{
    float x = c.size[0], y = c.size[1], z = c.size[2];
    switch (c.kind) {
    case CN_SHAPE_BOX: {
        BoxShapeSettings settings(Vec3(x, y, z), std::min(CONVEX_RADIUS, 0.5f * std::min({ x, y, z })));
        settings.mDensity = c.density;
        return settings.Create();
    }
    case CN_SHAPE_SPHERE: {
        SphereShapeSettings settings(x);
        settings.mDensity = c.density;
        return settings.Create();
    }
    case CN_SHAPE_CAPSULE: {
        CapsuleShapeSettings settings(y, x);
        settings.mDensity = c.density;
        return settings.Create();
    }
    case CN_SHAPE_CYLINDER: {
        CylinderShapeSettings settings(y, x, std::min(CONVEX_RADIUS, 0.5f * std::min(x, y)));
        settings.mDensity = c.density;
        return settings.Create();
    }
    default: {
        Shape::ShapeResult result;
        result.SetError("unknown shape kind");
        return result;
    }
    }
}

bool run_create_shape(World_Impl& w, const cn_create_shape& c)
{
    if (c.shape.generation == 0 || c.shape.index >= w.shapes.size()) {
        report(CN_LOG_ERROR, "physics: Create_Shape: shape index %u is outside the world's %u", c.shape.index,
            uint32(w.shapes.size()));
        return false;
    }
    if (!(c.size[0] > 0) || (c.kind != CN_SHAPE_SPHERE && !(c.size[1] > 0)) || (c.kind == CN_SHAPE_BOX && !(c.size[2] > 0))) {
        report(CN_LOG_ERROR, "physics: Create_Shape: size (%g, %g, %g) is not positive", c.size[0], c.size[1], c.size[2]);
        return false;
    }
    Shape::ShapeResult result = create_shape(c);
    if (result.HasError()) {
        report(CN_LOG_ERROR, "physics: Create_Shape: %s", result.GetError().c_str());
        return false;
    }
    Shape_Slot& slot = w.shapes[c.shape.index];
    slot.generation = c.shape.generation;
    slot.shape = result.Get();
    return true;
}

bool run_create_body(World_Impl& w, const cn_create_body& c)
{
    if (c.body.generation == 0 || c.body.index >= w.bodies.size()) {
        report(CN_LOG_ERROR, "physics: Create_Body: body index %u is outside the world's %u", c.body.index,
            uint32(w.bodies.size()));
        return false;
    }
    Body_Slot& slot = w.bodies[c.body.index];
    if (!slot.id.IsInvalid()) {
        report(CN_LOG_ERROR, "physics: Create_Body: body index %u is in use", c.body.index);
        return false;
    }
    const Shape* shape = find_shape(w, c.shape);
    if (shape == nullptr) {
        report(CN_LOG_ERROR, "physics: Create_Body: no shape (%u, %u)", c.shape.index, c.shape.generation);
        return false;
    }
    if (c.motion > CN_MOTION_DYNAMIC) {
        report(CN_LOG_ERROR, "physics: Create_Body: unknown motion %u", c.motion);
        return false;
    }

    EMotionType motion = c.motion == CN_MOTION_STATIC ? EMotionType::Static
        : c.motion == CN_MOTION_KINEMATIC             ? EMotionType::Kinematic
                                                      : EMotionType::Dynamic;
    BodyCreationSettings settings(shape, to_rvec3(c.position), to_quat(c.rotation), motion, object_layer(c.layer, c.motion));
    settings.mUserData = c.user;
    settings.mIsSensor = (c.flags & CN_BODY_SENSOR) != 0;
    settings.mMotionQuality = (c.flags & CN_BODY_CCD) ? EMotionQuality::LinearCast : EMotionQuality::Discrete;
    settings.mLinearVelocity = to_vec3(c.linear_velocity);
    settings.mAngularVelocity = to_vec3(c.angular_velocity);
    settings.mFriction = c.friction;
    settings.mRestitution = c.restitution;
    settings.mLinearDamping = c.linear_damping;
    settings.mAngularDamping = c.angular_damping;
    settings.mGravityFactor = c.gravity_factor;
    if (c.mass > 0 && motion == EMotionType::Dynamic) {
        settings.mOverrideMassProperties = EOverrideMassProperties::CalculateInertia;
        settings.mMassPropertiesOverride.mMass = c.mass;
    }

    bool activate = motion != EMotionType::Static && !(c.flags & CN_BODY_START_ASLEEP);
    BodyInterface& bodies = w.system.GetBodyInterface();
    BodyID id = bodies.CreateAndAddBody(settings, activate ? EActivation::Activate : EActivation::DontActivate);
    if (id.IsInvalid()) {
        report(CN_LOG_ERROR, "physics: Create_Body: the world is full");
        return false;
    }
    slot.generation = c.body.generation;
    slot.id = id;
    w.handles[id.GetIndex()] = c.body;
    w.added_since_optimize++;
    return true;
}

bool run_destroy_body(World_Impl& w, cn_body body)
{
    BodyID id;
    if (!find_body(w, body, id)) {
        return false;
    }
    BodyInterface& bodies = w.system.GetBodyInterface();
    bodies.RemoveBody(id);
    bodies.DestroyBody(id);
    w.handles[id.GetIndex()] = {};
    w.bodies[body.index] = {};
    return true;
}

template <typename T> const T& read(const uint8_t* data) { return *reinterpret_cast<const T*>(data); }

const char* command_name(uint16_t kind)
{
    static const char* names[] = { "Set_World", "Create_Shape", "Release_Shape", "Create_Body", "Destroy_Body",
        "Set_Pose", "Move_Kinematic", "Set_Velocity", "Add_Force", "Add_Force_At", "Add_Torque", "Add_Impulse",
        "Add_Angular_Impulse", "Activate", "Deactivate" };
    return kind < sizeof(names) / sizeof(names[0]) ? names[kind] : "unknown";
}

// run_command returns false for an invalid command, which submit logs.
bool run_command(World_Impl& w, uint16_t kind, const uint8_t* data)
{
    BodyInterface& bodies = w.system.GetBodyInterface();
    BodyID id;
    switch (kind) {
    case CN_CMD_SET_WORLD: {
        const auto& c = read<cn_set_world>(data);
        w.system.SetGravity(to_vec3(c.gravity));
        memcpy(w.pairs.collides, c.collides, sizeof(c.collides));
        return true;
    }
    case CN_CMD_CREATE_SHAPE:
        return run_create_shape(w, read<cn_create_shape>(data));
    case CN_CMD_RELEASE_SHAPE: {
        cn_shape shape = read<cn_release_shape>(data).shape;
        if (find_shape(w, shape) == nullptr) {
            return false;
        }
        w.shapes[shape.index] = {};
        return true;
    }
    case CN_CMD_CREATE_BODY:
        return run_create_body(w, read<cn_create_body>(data));
    case CN_CMD_DESTROY_BODY:
        return run_destroy_body(w, read<cn_destroy_body>(data).body);
    case CN_CMD_SET_POSE: {
        const auto& c = read<cn_set_pose>(data);
        if (!find_body(w, c.body, id)) {
            return false;
        }
        bodies.SetPositionAndRotation(id, to_rvec3(c.position), to_quat(c.rotation),
            c.activate ? EActivation::Activate : EActivation::DontActivate);
        return true;
    }
    case CN_CMD_MOVE_KINEMATIC: {
        const auto& c = read<cn_move_kinematic>(data);
        if (!find_body(w, c.body, id)) {
            return false;
        }
        bodies.MoveKinematic(id, to_rvec3(c.position), to_quat(c.rotation), c.dt);
        return true;
    }
    case CN_CMD_SET_VELOCITY: {
        const auto& c = read<cn_set_velocity>(data);
        if (!find_body(w, c.body, id)) {
            return false;
        }
        bodies.SetLinearAndAngularVelocity(id, to_vec3(c.linear), to_vec3(c.angular));
        return true;
    }
    case CN_CMD_ADD_FORCE:
    case CN_CMD_ADD_TORQUE:
    case CN_CMD_ADD_IMPULSE:
    case CN_CMD_ADD_ANGULAR_IMPULSE: {
        const auto& c = read<cn_add_vector>(data);
        if (!find_body(w, c.body, id)) {
            return false;
        }
        Vec3 v = to_vec3(c.vector);
        switch (kind) {
        case CN_CMD_ADD_FORCE: bodies.AddForce(id, v); break;
        case CN_CMD_ADD_TORQUE: bodies.AddTorque(id, v); break;
        case CN_CMD_ADD_IMPULSE: bodies.AddImpulse(id, v); break;
        default: bodies.AddAngularImpulse(id, v); break;
        }
        return true;
    }
    case CN_CMD_ADD_FORCE_AT: {
        const auto& c = read<cn_add_force_at>(data);
        if (!find_body(w, c.body, id)) {
            return false;
        }
        bodies.AddForce(id, to_vec3(c.force), to_rvec3(c.point));
        return true;
    }
    case CN_CMD_ACTIVATE:
    case CN_CMD_DEACTIVATE: {
        if (!find_body(w, read<cn_body_command>(data).body, id)) {
            return false;
        }
        if (kind == CN_CMD_ACTIVATE) {
            bodies.ActivateBody(id);
        } else {
            bodies.DeactivateBody(id);
        }
        return true;
    }
    default:
        return false;
    }
}

void read_state(World_Impl& w, BodyID id, cn_body handle, cn_body_state& out)
{
    const BodyInterface& bodies = w.system.GetBodyInterfaceNoLock();
    out = {};
    out.body = handle;
    out.user = bodies.GetUserData(id);
    RVec3 position;
    Quat rotation;
    bodies.GetPositionAndRotation(id, position, rotation);
    from_rvec3(position, out.position);
    from_quat(rotation, out.rotation);
    Vec3 linear, angular;
    bodies.GetLinearAndAngularVelocity(id, linear, angular);
    from_vec3(linear, out.linear_velocity);
    from_vec3(angular, out.angular_velocity);
    out.flags = bodies.IsActive(id) ? 0 : CN_BODY_STATE_ASLEEP;
}

// The bodies that moved: the active ones and the ones that fell asleep, once each, sorted by handle.
void collect_moved(World_Impl& w)
{
    BodyIDVector ids;
    w.system.GetActiveBodies(EBodyType::RigidBody, ids);
    {
        UniqueLock lock(w.activation.mutex);
        ids.insert(ids.end(), w.activation.slept.begin(), w.activation.slept.end());
        w.activation.slept.clear();
    }
    w.moved.clear();
    for (BodyID id : ids) {
        cn_body handle = w.handles[id.GetIndex()];
        // A body destroyed after it slept has no handle.
        if (handle.generation == 0) {
            continue;
        }
        cn_body_state& state = w.moved.emplace_back();
        read_state(w, id, handle, state);
    }
    QuickSort(w.moved.begin(), w.moved.end(), [](const cn_body_state& a, const cn_body_state& b) {
        return a.body.index < b.body.index;
    });
    auto end = std::unique(w.moved.begin(), w.moved.end(),
        [](const cn_body_state& a, const cn_body_state& b) { return a.body.index == b.body.index; });
    w.moved.erase(end, w.moved.end());
}

cn_backend_info info()
{
    uint32_t features = CN_FEATURE_RIGID_BODIES | CN_FEATURE_QUERIES;
#ifdef JPH_DOUBLE_PRECISION
    features |= CN_FEATURE_DOUBLE_PRECISION;
#endif
#ifdef JPH_CROSS_PLATFORM_DETERMINISTIC
    features |= CN_FEATURE_DETERMINISTIC;
#endif
    return { CN_PHYSICS_API_VERSION, features, "jolt", JOLT_VERSION };
}

uint32_t or_default(uint32_t value, uint32_t fallback) { return value != 0 ? value : fallback; }

cn_world world_create(const cn_world_desc* in)
{
    cn_world_desc desc = in ? *in : cn_world_desc {};
    desc.max_bodies = or_default(desc.max_bodies, 65536);
    desc.max_shapes = or_default(desc.max_shapes, 16384);
    desc.max_body_pairs = or_default(desc.max_body_pairs, 65536);
    desc.max_contact_constraints = or_default(desc.max_contact_constraints, 16384);
    desc.temp_size = or_default(desc.temp_size, 8u << 20);
    if (desc.max_bodies > PhysicsSystem::cMaxBodiesLimit) {
        report(CN_LOG_ERROR, "physics: world_create: %u bodies is over Jolt's limit of %u", desc.max_bodies,
            PhysicsSystem::cMaxBodiesLimit);
        return {};
    }
    for (uint32 i = 0; i < MAX_WORLDS; i++) {
        World_Entry& entry = worlds[i];
        if (entry.world != nullptr) {
            continue;
        }
        entry.world = new World_Impl(desc);
        entry.generation = entry.generation + 1 == 0 ? 1 : entry.generation + 1;
        return { i, entry.generation };
    }
    report(CN_LOG_ERROR, "physics: world_create: more than %u worlds", MAX_WORLDS);
    return {};
}

void destroy(World_Entry& entry)
{
    World_Impl* w = entry.world;
    BodyInterface& bodies = w->system.GetBodyInterface();
    for (Body_Slot& slot : w->bodies) {
        if (!slot.id.IsInvalid()) {
            bodies.RemoveBody(slot.id);
            bodies.DestroyBody(slot.id);
        }
    }
    delete w;
    entry.world = nullptr;
}

void world_destroy(cn_world handle)
{
    if (find_world(handle) == nullptr) {
        report(CN_LOG_ERROR, "physics: world_destroy: no world (%u, %u)", handle.index, handle.generation);
        return;
    }
    destroy(worlds[handle.index]);
}

int32_t world_destroy_all()
{
    int32_t count = 0;
    for (World_Entry& entry : worlds) {
        if (entry.world != nullptr) {
            destroy(entry);
            count++;
        }
    }
    return count;
}

uint32_t submit(cn_world handle, const void* data, uint32_t size)
{
    World_Impl* w = find_world(handle);
    if (w == nullptr) {
        report(CN_LOG_ERROR, "physics: submit: no world (%u, %u)", handle.index, handle.generation);
        return 0;
    }
    bool ok = true;
    const uint8_t* bytes = static_cast<const uint8_t*>(data);
    for (uint32_t offset = 0; offset + sizeof(cn_command_header) <= size;) {
        cn_command_header header;
        memcpy(&header, bytes + offset, sizeof(header));
        if (header.size < sizeof(header) || offset + header.size > size) {
            report(CN_LOG_ERROR, "physics: submit: a command at %u has size %u", offset, header.size);
            return 0;
        }
        if (!run_command(*w, header.kind, bytes + offset + sizeof(header))) {
            report(CN_LOG_ERROR, "physics: submit: %s was invalid, and did nothing", command_name(header.kind));
            ok = false;
        }
        offset += header.size;
    }
    return ok;
}

uint32_t step(cn_world handle, float dt, int32_t substeps)
{
    World_Impl* w = find_world(handle);
    if (w == nullptr) {
        report(CN_LOG_ERROR, "physics: step: no world (%u, %u)", handle.index, handle.generation);
        return 0;
    }
    if (w->added_since_optimize >= OPTIMIZE_AFTER) {
        w->system.OptimizeBroadPhase();
        w->added_since_optimize = 0;
    }
    EPhysicsUpdateError error = w->system.Update(dt, substeps > 0 ? substeps : 1, &w->temp, job_system);
    job_system->WaitForFiberJobs();
    collect_moved(*w);
    if (error != EPhysicsUpdateError::None) {
        report(CN_LOG_WARNING, "physics: step: Jolt ran out of room (error bits %#x); raise the world's limits", uint32(error));
        return 0;
    }
    return 1;
}

void results(cn_world handle, cn_step_results* out)
{
    *out = {};
    if (World_Impl* w = find_world(handle)) {
        out->moved = w->moved.data();
        out->moved_count = uint32_t(w->moved.size());
    }
}

void body_state(cn_world handle, const cn_body* bodies, uint32_t count, cn_body_state* out)
{
    World_Impl* w = find_world(handle);
    for (uint32_t i = 0; i < count; i++) {
        BodyID id;
        if (w != nullptr && find_body(*w, bodies[i], id)) {
            read_state(*w, id, bodies[i], out[i]);
        } else {
            out[i] = {};
        }
    }
}

class Query_Body_Filter final : public BodyFilter {
public:
    const World_Impl& world;
    const cn_query_filter& filter;
    Query_Body_Filter(const World_Impl& w, const cn_query_filter& f)
        : world(w)
        , filter(f)
    {
    }
    bool ShouldCollide(const BodyID& id) const override
    {
        cn_body handle = world.handles[id.GetIndex()];
        for (uint32_t i = 0; i < filter.ignore_count && i < CN_PHYSICS_MAX_QUERY_IGNORE; i++) {
            if (filter.ignore[i].index == handle.index && filter.ignore[i].generation == handle.generation) {
                return false;
            }
        }
        return true;
    }
    bool ShouldCollideLocked(const Body& body) const override
    {
        return !body.IsSensor() || (filter.flags & CN_QUERY_INCLUDE_SENSORS);
    }
};

uint32_t raycast(cn_world handle, const cn_ray* ray, const cn_query_filter* in_filter, cn_ray_hit* hit)
{
    *hit = {};
    World_Impl* w = find_world(handle);
    if (w == nullptr || !(ray->max_distance > 0)) {
        return 0;
    }
    cn_query_filter all = { ~0u, 0, 0, 0, {} };
    const cn_query_filter& filter = in_filter ? *in_filter : all;
    RRayCast cast { to_rvec3(ray->origin), to_vec3(ray->direction) * ray->max_distance };
    RayCastResult result;
    Layer_Mask_Filter layers(filter.layers);
    Query_Body_Filter bodies(*w, filter);
    if (!w->system.GetNarrowPhaseQuery().CastRay(cast, result, {}, layers, bodies)) {
        return 0;
    }
    RVec3 position = cast.GetPointOnRay(result.mFraction);
    BodyLockRead lock(w->system.GetBodyLockInterface(), result.mBodyID);
    if (!lock.Succeeded()) {
        return 0;
    }
    const Body& body = lock.GetBody();
    hit->body = w->handles[result.mBodyID.GetIndex()];
    hit->user = body.GetUserData();
    from_rvec3(position, hit->position);
    from_vec3(body.GetWorldSpaceSurfaceNormal(result.mSubShapeID2, position), hit->normal);
    hit->distance = result.mFraction * ray->max_distance;
    hit->sub_shape = result.mSubShapeID2.GetValue();
    return 1;
}

void run_job(void* data) { Fiber_Job_System::Run(data); }

void shutdown()
{
    world_destroy_all();
    delete job_system;
    job_system = nullptr;
    UnregisterTypes();
    delete Factory::sInstance;
    Factory::sInstance = nullptr;
}

const cn_physics_api api = {
    info,
    world_create,
    world_destroy,
    submit,
    step,
    results,
    body_state,
    raycast,
    run_job,
    world_destroy_all,
    shutdown,
};

} // namespace

// The backend's entry point. The first call sets Jolt up with the host's memory, log and jobs; later calls return the
// same table. host must stay at the same address until shutdown.
CN_PHYSICS_EXPORT const cn_physics_api* cinnabar_physics_api(const cn_physics_host* in_host)
{
    if (Factory::sInstance != nullptr) {
        return &api;
    }
    host = in_host;
    Allocate = allocate;
    Reallocate = reallocate;
    Free = free_block;
    AlignedAllocate = aligned_allocate;
    AlignedFree = free_block;
    Trace = trace;
#ifdef JPH_ENABLE_ASSERTS
    AssertFailed = assert_failed;
#endif
    Factory::sInstance = new Factory();
    RegisterTypes();
    job_system = new Fiber_Job_System();
    return &api;
}
