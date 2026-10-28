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
#include <Jolt/Core/UnorderedMap.h>
#include <Jolt/Core/UnorderedSet.h>
#include <Jolt/Physics/Collision/CastResult.h>
#include <Jolt/Physics/Collision/CollideShape.h>
#include <Jolt/Physics/Collision/CollisionCollectorImpl.h>
#include <Jolt/Physics/Collision/ContactListener.h>
#include <Jolt/Physics/Collision/EstimateCollisionResponse.h>
#include <Jolt/Physics/Collision/ShapeCast.h>
#include <Jolt/Physics/Constraints/ConeConstraint.h>
#include <Jolt/Physics/Constraints/DistanceConstraint.h>
#include <Jolt/Physics/Constraints/FixedConstraint.h>
#include <Jolt/Physics/Constraints/HingeConstraint.h>
#include <Jolt/Physics/Constraints/PointConstraint.h>
#include <Jolt/Physics/Constraints/SixDOFConstraint.h>
#include <Jolt/Physics/Constraints/SliderConstraint.h>
#include <Jolt/Physics/Collision/RayCast.h>
#include <Jolt/Physics/Collision/Shape/BoxShape.h>
#include <Jolt/Physics/Collision/Shape/CapsuleShape.h>
#include <Jolt/Physics/Collision/Shape/ConvexHullShape.h>
#include <Jolt/Physics/Collision/Shape/MeshShape.h>
#include <Jolt/Physics/Collision/Shape/CylinderShape.h>
#include <Jolt/Physics/Collision/Shape/RotatedTranslatedShape.h>
#include <Jolt/Physics/Collision/Shape/SphereShape.h>
#include <Jolt/Physics/Collision/Shape/StaticCompoundShape.h>
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

struct World_Impl;

// The pairs of bodies that touch, counted by their touching sub-shape pairs, which is what Jolt reports: a pair begins
// when its count leaves zero and ends when it returns there (see docs/physics/design.md#events). Jolt calls this from
// its threads during the step, so it takes a lock; the events are sorted after the step.
//
// Jolt reports a contact as removed when it is not detected again, and the contacts of sleeping bodies are not
// detected, so the removals wait for the end of the step: a removal between two bodies that are both asleep or static
// is not a separation, and the pair keeps its contact. The touching sub-shape pairs are kept, not only their count,
// since a body that wakes reports its contacts as added again.
class Contact_Listener final : public ContactListener {
public:
    World_Impl* world = nullptr;
    Mutex mutex;
    UnorderedMap<uint64, uint32> pairs;
    UnorderedSet<SubShapeIDPair> touching;
    Array<SubShapeIDPair> removed;
    Array<cn_contact_event> events;

    static uint64 key(const BodyID& a, const BodyID& b)
    {
        uint64 x = a.GetIndexAndSequenceNumber(), y = b.GetIndexAndSequenceNumber();
        return x < y ? (x << 32 | y) : (y << 32 | x);
    }

    // The body pairs that a joint without Collide_Connected keeps from colliding, with how many joints do. Only
    // submit changes it, so the step's threads only read it.
    UnorderedMap<uint64, uint32> joined;

    ValidateResult OnContactValidate(const Body& body1, const Body& body2, RVec3Arg, const CollideShapeResult&) override
    {
        return joined.find(key(body1.GetID(), body2.GetID())) != joined.end() ? ValidateResult::RejectAllContactsForThisBodyPair
                                                                             : ValidateResult::AcceptAllContactsForThisBodyPair;
    }
    void OnContactAdded(const Body& body1, const Body& body2, const ContactManifold& manifold, ContactSettings& settings) override;
    void OnContactRemoved(const SubShapeIDPair& pair) override;
    // end_pairs ends every pair of a body that is destroyed or leaves the simulation, which Jolt does not report.
    void end_pairs(const BodyID& id);
    // apply_removed ends the contacts that Jolt removed in the step and that did not only fall asleep.
    void apply_removed();
    void end_event(uint32 i1, uint32 i2);
};

struct Body_Slot {
    uint32 generation = 0;
    BodyID id;
};

struct Joint_Slot {
    uint32 generation = 0;
    // Null when the joint was destroyed, or went with one of its bodies.
    Ref<TwoBodyConstraint> constraint;
    uint8_t kind = 0;
    bool collide = false;
    bool broken = false;
    float break_force = 0, break_torque = 0;
    BodyID a, b;
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
    Contact_Listener contacts;
    Array<Body_Slot> bodies;
    Array<Shape_Slot> shapes;
    Array<Joint_Slot> joints;
    Array<cn_joint_break> broken;
    // The engine's handle, user value and flags of each Jolt body, by BodyID index.
    Array<cn_body> handles;
    Array<uint64> users;
    Array<uint16> flags;
    Array<cn_body_state> moved;
    uint32 added_since_optimize = 0;
    // Set by a step, so the next submit starts the results again.
    bool stepped = false;

    explicit World_Impl(const cn_world_desc& desc)
        : temp(desc.temp_size)
        , bodies(desc.max_bodies)
        , shapes(desc.max_shapes)
        , handles(desc.max_bodies)
        , users(desc.max_bodies)
        , flags(desc.max_bodies)
        , joints(desc.max_joints)
    {
        system.Init(desc.max_bodies, 0, desc.max_body_pairs, desc.max_contact_constraints, broad_layers, object_vs_broad,
            pairs);
        system.SetBodyActivationListener(&activation);
        contacts.world = this;
        system.SetContactListener(&contacts);
    }
};

bool reports(const World_Impl& w, const Body& body)
{
    return body.IsSensor() || (w.flags[body.GetID().GetIndex()] & CN_BODY_REPORT_CONTACTS);
}

void Contact_Listener::OnContactAdded(const Body& body1, const Body& body2, const ContactManifold& manifold, ContactSettings& settings)
{
    if (!reports(*world, body1) && !reports(*world, body2)) {
        return;
    }
    SubShapeIDPair sub_shapes = body1.GetID() < body2.GetID()
        ? SubShapeIDPair(body1.GetID(), manifold.mSubShapeID1, body2.GetID(), manifold.mSubShapeID2)
        : SubShapeIDPair(body2.GetID(), manifold.mSubShapeID2, body1.GetID(), manifold.mSubShapeID1);
    {
        UniqueLock lock(mutex);
        if (!touching.insert(sub_shapes).second) {
            return;
        }
        if (pairs[key(body1.GetID(), body2.GetID())]++ > 0) {
            return;
        }
    }
    // The pair's first contact. a is the body with the lower handle index, and the normal points from a to b.
    const Body* a = &body1;
    const Body* b = &body2;
    Vec3 normal = manifold.mWorldSpaceNormal;
    if (world->handles[a->GetID().GetIndex()].index > world->handles[b->GetID().GetIndex()].index) {
        std::swap(a, b);
        normal = -normal;
    }
    RVec3 point = manifold.GetWorldSpaceContactPointOn1(0);
    cn_contact_event e = {};
    e.kind = CN_CONTACT_BEGIN;
    e.sensor = body1.IsSensor() || body2.IsSensor();
    e.a = world->handles[a->GetID().GetIndex()];
    e.b = world->handles[b->GetID().GetIndex()];
    e.a_user = world->users[a->GetID().GetIndex()];
    e.b_user = world->users[b->GetID().GetIndex()];
    e.point[0] = double(point.GetX());
    e.point[1] = double(point.GetY());
    e.point[2] = double(point.GetZ());
    Vec3 relative = b->GetPointVelocity(point) - a->GetPointVelocity(point);
    for (int i = 0; i < 3; i++) {
        e.normal[i] = normal[i];
        e.relative_velocity[i] = relative[i];
    }
    if (!e.sensor) {
        CollisionEstimationResult estimate;
        EstimateCollisionResponse(body1, body2, manifold, estimate, settings.mCombinedFriction, settings.mCombinedRestitution);
        for (float impulse : estimate.mContactImpulse) {
            e.impulse += impulse;
        }
    }
    UniqueLock lock(mutex);
    events.push_back(e);
}

void Contact_Listener::OnContactRemoved(const SubShapeIDPair& pair)
{
    UniqueLock lock(mutex);
    removed.push_back(pair);
}

void Contact_Listener::end_event(uint32 i1, uint32 i2)
{
    if (world->handles[i1].index > world->handles[i2].index) {
        std::swap(i1, i2);
    }
    cn_contact_event e = {};
    e.kind = CN_CONTACT_END;
    e.a = world->handles[i1];
    e.b = world->handles[i2];
    e.a_user = world->users[i1];
    e.b_user = world->users[i2];
    e.sensor = (world->flags[i1] & CN_BODY_SENSOR) || (world->flags[i2] & CN_BODY_SENSOR);
    events.push_back(e);
}

void Contact_Listener::apply_removed()
{
    const BodyInterface& bodies = world->system.GetBodyInterfaceNoLock();
    for (const SubShapeIDPair& pair : removed) {
        auto found = touching.find(pair);
        if (found == touching.end()) {
            continue;
        }
        BodyID id1 = pair.GetBody1ID(), id2 = pair.GetBody2ID();
        bool asleep = bodies.IsAdded(id1) && bodies.IsAdded(id2) && !bodies.IsActive(id1) && !bodies.IsActive(id2);
        if (asleep) {
            continue;
        }
        touching.erase(found);
        auto count = pairs.find(key(id1, id2));
        if (count == pairs.end() || --count->second > 0) {
            continue;
        }
        pairs.erase(count);
        end_event(id1.GetIndex(), id2.GetIndex());
    }
    removed.clear();
}

void Contact_Listener::end_pairs(const BodyID& id)
{
    UniqueLock lock(mutex);
    uint64 self = id.GetIndexAndSequenceNumber();
    Array<uint64> ended;
    for (const auto& [k, count] : pairs) {
        if ((k >> 32) == self || (k & 0xffffffff) == self) {
            ended.push_back(k);
        }
    }
    for (uint64 k : ended) {
        pairs.erase(k);
        end_event(BodyID(uint32(k >> 32)).GetIndex(), BodyID(uint32(k & 0xffffffff)).GetIndex());
    }
    Array<SubShapeIDPair> gone;
    for (const SubShapeIDPair& pair : touching) {
        if (pair.GetBody1ID() == id || pair.GetBody2ID() == id) {
            gone.push_back(pair);
        }
    }
    for (const SubShapeIDPair& pair : gone) {
        touching.erase(pair);
    }
}

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
    Vec3 offset = to_vec3(c.offset);
    Quat rotation = to_quat(c.rotation);
    if (offset != Vec3::sZero() || !rotation.IsClose(Quat::sIdentity())) {
        result = RotatedTranslatedShapeSettings(offset, rotation, result.Get()).Create();
        if (result.HasError()) {
            report(CN_LOG_ERROR, "physics: Create_Shape: %s", result.GetError().c_str());
            return false;
        }
    }
    Shape_Slot& slot = w.shapes[c.shape.index];
    slot.generation = c.shape.generation;
    slot.shape = result.Get();
    return true;
}

bool run_create_compound(World_Impl& w, const cn_create_compound& c, const cn_shape* children)
{
    if (c.shape.generation == 0 || c.shape.index >= w.shapes.size() || c.count == 0) {
        report(CN_LOG_ERROR, "physics: Create_Compound: shape (%u, %u) with %u children", c.shape.index, c.shape.generation, c.count);
        return false;
    }
    StaticCompoundShapeSettings settings;
    for (uint32_t i = 0; i < c.count; i++) {
        const Shape* child = find_shape(w, children[i]);
        if (child == nullptr) {
            report(CN_LOG_ERROR, "physics: Create_Compound: no child shape (%u, %u)", children[i].index, children[i].generation);
            return false;
        }
        settings.AddShape(Vec3::sZero(), Quat::sIdentity(), child);
    }
    Shape::ShapeResult result = settings.Create();
    if (result.HasError()) {
        report(CN_LOG_ERROR, "physics: Create_Compound: %s", result.GetError().c_str());
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
    if (c.motion == CN_MOTION_DYNAMIC && shape->MustBeStatic()) {
        report(CN_LOG_ERROR, "physics: Create_Body: a triangle mesh has no mass, so a dynamic body cannot take it");
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
    settings.mCollideKinematicVsNonDynamic = (c.flags & CN_BODY_DETECT_STATIC) != 0;
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
    w.users[id.GetIndex()] = c.user;
    w.flags[id.GetIndex()] = c.flags;
    w.added_since_optimize++;
    return true;
}

void remove_body_joints(World_Impl& w, const BodyID& id);

bool run_destroy_body(World_Impl& w, cn_body body)
{
    BodyID id;
    if (!find_body(w, body, id)) {
        return false;
    }
    BodyInterface& bodies = w.system.GetBodyInterface();
    w.contacts.end_pairs(id);
    remove_body_joints(w, id);
    if (bodies.IsAdded(id)) {
        bodies.RemoveBody(id);
    }
    bodies.DestroyBody(id);
    w.handles[id.GetIndex()] = {};
    w.bodies[body.index] = {};
    return true;
}

template <typename T> const T& read(const uint8_t* data) { return *reinterpret_cast<const T*>(data); }

Joint_Slot* find_joint(World_Impl& w, cn_joint handle)
{
    if (handle.generation == 0 || handle.index >= w.joints.size()) {
        return nullptr;
    }
    Joint_Slot& slot = w.joints[handle.index];
    return slot.generation == handle.generation ? &slot : nullptr;
}

// remove_joint takes a joint out of the system, and lets its bodies collide again if it kept them apart.
void remove_joint(World_Impl& w, Joint_Slot& slot)
{
    if (slot.constraint == nullptr) {
        return;
    }
    w.system.RemoveConstraint(slot.constraint);
    slot.constraint = nullptr;
    if (!slot.collide) {
        auto found = w.contacts.joined.find(Contact_Listener::key(slot.a, slot.b));
        if (found != w.contacts.joined.end() && --found->second == 0) {
            w.contacts.joined.erase(found);
        }
    }
}

// remove_body_joints removes the joints of a body that is destroyed: a constraint holds its bodies. Their handles stay
// valid until the engine destroys them.
void remove_body_joints(World_Impl& w, const BodyID& id)
{
    for (Joint_Slot& slot : w.joints) {
        if (slot.constraint != nullptr && (slot.a == id || slot.b == id)) {
            remove_joint(w, slot);
        }
    }
}

void set_motor(Joint_Slot& slot, uint8_t mode, float target, float max)
{
    EMotorState state = mode == CN_MOTOR_VELOCITY ? EMotorState::Velocity
        : mode == CN_MOTOR_POSITION               ? EMotorState::Position
                                                  : EMotorState::Off;
    float limit = max > 0 ? max : FLT_MAX;
    if (slot.kind == CN_JOINT_HINGE) {
        auto* hinge = static_cast<HingeConstraint*>(slot.constraint.GetPtr());
        hinge->GetMotorSettings().SetTorqueLimit(limit);
        hinge->SetMotorState(state);
        if (state == EMotorState::Velocity) {
            hinge->SetTargetAngularVelocity(target);
        } else if (state == EMotorState::Position) {
            hinge->SetTargetAngle(target);
        }
    } else if (slot.kind == CN_JOINT_SLIDER) {
        auto* slider = static_cast<SliderConstraint*>(slot.constraint.GetPtr());
        slider->GetMotorSettings().SetForceLimit(limit);
        slider->SetMotorState(state);
        if (state == EMotorState::Velocity) {
            slider->SetTargetVelocity(target);
        } else if (state == EMotorState::Position) {
            slider->SetTargetPosition(target);
        }
    }
}

Ref<TwoBodyConstraintSettings> joint_settings(const cn_create_joint& c)
{
    RVec3 pa = to_rvec3(c.position_a), pb = to_rvec3(c.position_b);
    Quat ra = to_quat(c.rotation_a), rb = to_quat(c.rotation_b);
    Vec3 xa = ra.RotateAxisX(), ya = ra.RotateAxisY(), xb = rb.RotateAxisX(), yb = rb.RotateAxisY();
    SpringSettings spring(ESpringMode::FrequencyAndDamping, c.spring_frequency, c.spring_damping);
    // A position motor is a spring: the joint's, or a firm one.
    MotorSettings motor(c.spring_frequency > 0 ? c.spring_frequency : 2.0f, c.spring_frequency > 0 ? c.spring_damping : 1.0f);
    bool limits = (c.flags & CN_JOINT_HAS_LIMITS) != 0;
    switch (c.kind) {
    case CN_JOINT_FIXED: {
        auto* s = new FixedConstraintSettings();
        s->mPoint1 = pa;
        s->mAxisX1 = xa;
        s->mAxisY1 = ya;
        s->mPoint2 = pb;
        s->mAxisX2 = xb;
        s->mAxisY2 = yb;
        return s;
    }
    case CN_JOINT_POINT: {
        auto* s = new PointConstraintSettings();
        s->mPoint1 = pa;
        s->mPoint2 = pb;
        return s;
    }
    case CN_JOINT_HINGE: {
        auto* s = new HingeConstraintSettings();
        s->mPoint1 = pa;
        s->mHingeAxis1 = xa;
        s->mNormalAxis1 = ya;
        s->mPoint2 = pb;
        s->mHingeAxis2 = xb;
        s->mNormalAxis2 = yb;
        if (limits) {
            s->mLimitsMin = c.limit_min;
            s->mLimitsMax = c.limit_max;
            s->mLimitsSpringSettings = spring;
        }
        s->mMotorSettings = motor;
        return s;
    }
    case CN_JOINT_SLIDER: {
        auto* s = new SliderConstraintSettings();
        s->mPoint1 = pa;
        s->mSliderAxis1 = xa;
        s->mNormalAxis1 = ya;
        s->mPoint2 = pb;
        s->mSliderAxis2 = xb;
        s->mNormalAxis2 = yb;
        if (limits) {
            s->mLimitsMin = c.limit_min;
            s->mLimitsMax = c.limit_max;
            s->mLimitsSpringSettings = spring;
        }
        s->mMotorSettings = motor;
        return s;
    }
    case CN_JOINT_DISTANCE: {
        auto* s = new DistanceConstraintSettings();
        s->mPoint1 = pa;
        s->mPoint2 = pb;
        s->mMinDistance = c.limit_min;
        s->mMaxDistance = c.limit_max;
        s->mLimitsSpringSettings = spring;
        return s;
    }
    case CN_JOINT_CONE: {
        auto* s = new ConeConstraintSettings();
        s->mPoint1 = pa;
        s->mTwistAxis1 = xa;
        s->mPoint2 = pb;
        s->mTwistAxis2 = xb;
        s->mHalfConeAngle = c.limit_max;
        return s;
    }
    case CN_JOINT_SIX_DOF: {
        auto* s = new SixDOFConstraintSettings();
        s->mPosition1 = pa;
        s->mAxisX1 = xa;
        s->mAxisY1 = ya;
        s->mPosition2 = pb;
        s->mAxisX2 = xb;
        s->mAxisY2 = yb;
        for (int i = 0; i < 6; i++) {
            s->mLimitMin[i] = c.six_min[i];
            s->mLimitMax[i] = c.six_max[i];
        }
        return s;
    }
    default:
        return nullptr;
    }
}

bool run_create_joint(World_Impl& w, const cn_create_joint& c)
{
    if (c.joint.generation == 0 || c.joint.index >= w.joints.size()) {
        report(CN_LOG_ERROR, "physics: Create_Joint: joint index %u is outside the world's %u", c.joint.index, uint32(w.joints.size()));
        return false;
    }
    Joint_Slot& slot = w.joints[c.joint.index];
    if (slot.constraint != nullptr) {
        report(CN_LOG_ERROR, "physics: Create_Joint: joint index %u is in use", c.joint.index);
        return false;
    }
    BodyID a, b;
    if (!find_body(w, c.a, a) || (c.b.generation != 0 && !find_body(w, c.b, b))) {
        report(CN_LOG_ERROR, "physics: Create_Joint: a body is missing");
        return false;
    }
    Ref<TwoBodyConstraintSettings> settings = joint_settings(c);
    if (settings == nullptr) {
        report(CN_LOG_ERROR, "physics: Create_Joint: unknown kind %u", c.kind);
        return false;
    }
    settings->mEnabled = !(c.flags & CN_JOINT_DISABLED);
    BodyInterface& bodies = w.system.GetBodyInterface();
    TwoBodyConstraint* constraint = bodies.CreateConstraint(settings, a, b);
    if (constraint == nullptr) {
        report(CN_LOG_ERROR, "physics: Create_Joint: Jolt could not make it");
        return false;
    }
    slot = {};
    slot.generation = c.joint.generation;
    slot.constraint = constraint;
    slot.kind = c.kind;
    slot.collide = (c.flags & CN_JOINT_COLLIDE_CONNECTED) != 0;
    slot.break_force = c.break_force;
    slot.break_torque = c.break_torque;
    slot.a = a;
    slot.b = b;
    w.system.AddConstraint(constraint);
    if (!slot.collide) {
        w.contacts.joined[Contact_Listener::key(a, b)]++;
    }
    set_motor(slot, c.motor, c.motor_target, c.motor_max);
    bodies.ActivateConstraint(constraint);
    return true;
}

// check_breaks disables the joints that carried more than their limits in a step of dt, and reports them.
void check_breaks(World_Impl& w, float dt)
{
    for (uint32 i = 0; i < w.joints.size(); i++) {
        Joint_Slot& slot = w.joints[i];
        if (slot.constraint == nullptr || slot.broken || (slot.break_force <= 0 && slot.break_torque <= 0)) {
            continue;
        }
        TwoBodyConstraint* c = slot.constraint;
        float position = 0, rotation = 0;
        switch (slot.kind) {
        case CN_JOINT_FIXED:
            position = static_cast<FixedConstraint*>(c)->GetTotalLambdaPosition().Length();
            rotation = static_cast<FixedConstraint*>(c)->GetTotalLambdaRotation().Length();
            break;
        case CN_JOINT_POINT:
            position = static_cast<PointConstraint*>(c)->GetTotalLambdaPosition().Length();
            break;
        case CN_JOINT_HINGE: {
            auto* h = static_cast<HingeConstraint*>(c);
            position = h->GetTotalLambdaPosition().Length();
            Vector<2> r = h->GetTotalLambdaRotation();
            rotation = sqrt(r[0] * r[0] + r[1] * r[1]) + abs(h->GetTotalLambdaRotationLimits());
            break;
        }
        case CN_JOINT_SLIDER: {
            auto* s = static_cast<SliderConstraint*>(c);
            Vector<2> p = s->GetTotalLambdaPosition();
            position = sqrt(p[0] * p[0] + p[1] * p[1]) + abs(s->GetTotalLambdaPositionLimits());
            rotation = s->GetTotalLambdaRotation().Length();
            break;
        }
        case CN_JOINT_DISTANCE:
            position = abs(static_cast<DistanceConstraint*>(c)->GetTotalLambdaPosition());
            break;
        case CN_JOINT_CONE:
            position = static_cast<ConeConstraint*>(c)->GetTotalLambdaPosition().Length();
            rotation = abs(static_cast<ConeConstraint*>(c)->GetTotalLambdaRotation());
            break;
        case CN_JOINT_SIX_DOF:
            position = static_cast<SixDOFConstraint*>(c)->GetTotalLambdaPosition().Length();
            rotation = static_cast<SixDOFConstraint*>(c)->GetTotalLambdaRotation().Length();
            break;
        }
        float force = position / dt, torque = rotation / dt;
        if ((slot.break_force > 0 && force > slot.break_force) || (slot.break_torque > 0 && torque > slot.break_torque)) {
            c->SetEnabled(false);
            slot.broken = true;
            w.broken.push_back({ { i, slot.generation }, force, torque });
        }
    }
}

const char* command_name(uint16_t kind)
{
    static const char* names[] = { "Set_World", "Create_Shape", "Release_Shape", "Create_Body", "Destroy_Body",
        "Set_Pose", "Move_Kinematic", "Set_Velocity", "Add_Force", "Add_Force_At", "Add_Torque", "Add_Impulse",
        "Add_Angular_Impulse", "Activate", "Deactivate", "Set_Enabled", "Create_Compound", "Create_Joint", "Destroy_Joint",
        "Set_Joint" };
    return kind < sizeof(names) / sizeof(names[0]) ? names[kind] : "unknown";
}

// run_command returns false for an invalid command, which submit logs. size is the payload's, with its padding.
bool run_command(World_Impl& w, uint16_t kind, const uint8_t* data, uint32_t size)
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
    case CN_CMD_CREATE_JOINT:
        return run_create_joint(w, read<cn_create_joint>(data));
    case CN_CMD_DESTROY_JOINT: {
        cn_joint joint = read<cn_destroy_joint>(data).joint;
        Joint_Slot* slot = find_joint(w, joint);
        if (slot == nullptr) {
            return false;
        }
        remove_joint(w, *slot);
        *slot = {};
        return true;
    }
    case CN_CMD_SET_JOINT: {
        const auto& c = read<cn_set_joint>(data);
        Joint_Slot* slot = find_joint(w, c.joint);
        if (slot == nullptr) {
            return false;
        }
        if (slot->constraint != nullptr) {
            slot->constraint->SetEnabled(c.enabled && !slot->broken);
            set_motor(*slot, c.motor, c.motor_target, c.motor_max);
            if (c.enabled) {
                w.system.GetBodyInterface().ActivateConstraint(slot->constraint);
            }
        }
        return true;
    }
    case CN_CMD_CREATE_COMPOUND: {
        const auto& c = read<cn_create_compound>(data);
        if (c.count > CN_PHYSICS_MAX_COMPOUND_CHILDREN || sizeof(c) + c.count * sizeof(cn_shape) > size) {
            report(CN_LOG_ERROR, "physics: Create_Compound: %u children do not fit in the command", c.count);
            return false;
        }
        return run_create_compound(w, c, reinterpret_cast<const cn_shape*>(data + sizeof(cn_create_compound)));
    }
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
    case CN_CMD_SET_ENABLED: {
        const auto& c = read<cn_set_enabled>(data);
        if (!find_body(w, c.body, id)) {
            return false;
        }
        bool added = bodies.IsAdded(id);
        if (c.enabled && !added) {
            bool dynamic = bodies.GetMotionType(id) != EMotionType::Static;
            bodies.AddBody(id, dynamic ? EActivation::Activate : EActivation::DontActivate);
        } else if (!c.enabled && added) {
            w.contacts.end_pairs(id);
            bodies.RemoveBody(id);
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
    uint32_t features = CN_FEATURE_RIGID_BODIES | CN_FEATURE_QUERIES | CN_FEATURE_SENSORS | CN_FEATURE_JOINTS;
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
    desc.max_joints = or_default(desc.max_joints, 16384);
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
    for (Joint_Slot& slot : w->joints) {
        remove_joint(*w, slot);
    }
    BodyInterface& bodies = w->system.GetBodyInterface();
    for (Body_Slot& slot : w->bodies) {
        if (!slot.id.IsInvalid()) {
            if (bodies.IsAdded(slot.id)) {
                bodies.RemoveBody(slot.id);
            }
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
    if (w->stepped) {
        w->stepped = false;
        w->moved.clear();
        w->contacts.events.clear();
        w->broken.clear();
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
        if (!run_command(*w, header.kind, bytes + offset + sizeof(header), header.size - uint32_t(sizeof(header)))) {
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
    // Results last until the next submit or step: a step after a step starts them again, as a submit does.
    if (w->stepped) {
        w->moved.clear();
        w->contacts.events.clear();
        w->broken.clear();
    }
    if (w->added_since_optimize >= OPTIMIZE_AFTER) {
        w->system.OptimizeBroadPhase();
        w->added_since_optimize = 0;
    }
    EPhysicsUpdateError error = w->system.Update(dt, substeps > 0 ? substeps : 1, &w->temp, job_system);
    job_system->WaitForFiberJobs();
    w->contacts.apply_removed();
    check_breaks(*w, dt);
    collect_moved(*w);
    Array<cn_contact_event>& events = w->contacts.events;
    QuickSort(events.begin(), events.end(), [](const cn_contact_event& x, const cn_contact_event& y) {
        if (x.a.index != y.a.index) {
            return x.a.index < y.a.index;
        }
        if (x.b.index != y.b.index) {
            return x.b.index < y.b.index;
        }
        return x.kind < y.kind;
    });
    w->stepped = true;
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
        out->contacts = w->contacts.events.data();
        out->contact_count = uint32_t(w->contacts.events.size());
        out->broken = w->broken.data();
        out->broken_count = uint32_t(w->broken.size());
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

const cn_query_filter FILTER_ALL = { ~0u, 0, 0, 0, {} };

// fill_hit writes a hit at a point on a body. A normal of zero asks for the body's surface normal there.
bool fill_hit(World_Impl& w, const BodyID& id, const SubShapeID& sub_shape, RVec3Arg position, Vec3Arg normal, float distance, cn_ray_hit& hit)
{
    hit = {};
    BodyLockRead lock(w.system.GetBodyLockInterface(), id);
    if (!lock.Succeeded()) {
        return false;
    }
    const Body& body = lock.GetBody();
    hit.body = w.handles[id.GetIndex()];
    hit.user = body.GetUserData();
    from_rvec3(position, hit.position);
    from_vec3(normal == Vec3::sZero() ? body.GetWorldSpaceSurfaceNormal(sub_shape, position) : normal, hit.normal);
    hit.distance = distance;
    hit.sub_shape = sub_shape.GetValue();
    return true;
}

uint32_t create_mesh_shape(cn_world handle, cn_shape shape, uint8_t kind, const float (*vertices)[3], uint32_t vertex_count,
    const uint32_t (*triangles)[3], uint32_t triangle_count, float density)
{
    World_Impl* w = find_world(handle);
    if (w == nullptr || shape.generation == 0 || shape.index >= w->shapes.size() || vertex_count == 0) {
        report(CN_LOG_ERROR, "physics: create_mesh_shape: no world, a bad handle, or no vertices");
        return 0;
    }
    Shape::ShapeResult result;
    if (kind == CN_SHAPE_MESH) {
        VertexList points;
        points.reserve(vertex_count);
        for (uint32_t i = 0; i < vertex_count; i++) {
            points.push_back(Float3(vertices[i][0], vertices[i][1], vertices[i][2]));
        }
        IndexedTriangleList list;
        list.reserve(triangle_count);
        for (uint32_t i = 0; i < triangle_count; i++) {
            const uint32_t* t = triangles[i];
            if (t[0] >= vertex_count || t[1] >= vertex_count || t[2] >= vertex_count) {
                report(CN_LOG_ERROR, "physics: create_mesh_shape: triangle %u names a vertex past %u", i, vertex_count);
                return 0;
            }
            list.push_back(IndexedTriangle(t[0], t[1], t[2]));
        }
        result = MeshShapeSettings(std::move(points), std::move(list)).Create();
    } else if (kind == CN_SHAPE_CONVEX_HULL) {
        Array<Vec3> points;
        points.reserve(vertex_count);
        for (uint32_t i = 0; i < vertex_count; i++) {
            points.push_back(Vec3(vertices[i][0], vertices[i][1], vertices[i][2]));
        }
        ConvexHullShapeSettings settings(points, CONVEX_RADIUS);
        settings.mDensity = density;
        result = settings.Create();
    } else {
        report(CN_LOG_ERROR, "physics: create_mesh_shape: kind %u is not a mesh or a hull", kind);
        return 0;
    }
    if (result.HasError()) {
        report(CN_LOG_ERROR, "physics: create_mesh_shape: %s", result.GetError().c_str());
        return 0;
    }
    Shape_Slot& slot = w->shapes[shape.index];
    slot.generation = shape.generation;
    slot.shape = result.Get();
    return 1;
}

uint32_t raycast(cn_world handle, const cn_ray* ray, const cn_query_filter* in_filter, cn_ray_hit* hit)
{
    *hit = {};
    World_Impl* w = find_world(handle);
    if (w == nullptr || !(ray->max_distance > 0)) {
        return 0;
    }
    const cn_query_filter& filter = in_filter ? *in_filter : FILTER_ALL;
    RRayCast cast { to_rvec3(ray->origin), to_vec3(ray->direction) * ray->max_distance };
    RayCastResult result;
    Layer_Mask_Filter layers(filter.layers);
    Query_Body_Filter bodies(*w, filter);
    if (!w->system.GetNarrowPhaseQuery().CastRay(cast, result, {}, layers, bodies)) {
        return 0;
    }
    return fill_hit(*w, result.mBodyID, result.mSubShapeID2, cast.GetPointOnRay(result.mFraction), Vec3::sZero(),
        result.mFraction * ray->max_distance, *hit);
}

uint32_t raycast_all(cn_world handle, const cn_ray* ray, const cn_query_filter* in_filter, cn_ray_hit* out, uint32_t capacity)
{
    World_Impl* w = find_world(handle);
    if (w == nullptr || !(ray->max_distance > 0)) {
        return 0;
    }
    const cn_query_filter& filter = in_filter ? *in_filter : FILTER_ALL;
    RRayCast cast { to_rvec3(ray->origin), to_vec3(ray->direction) * ray->max_distance };
    AllHitCollisionCollector<CastRayCollector> collector;
    Layer_Mask_Filter layers(filter.layers);
    Query_Body_Filter bodies(*w, filter);
    w->system.GetNarrowPhaseQuery().CastRay(cast, RayCastSettings(), collector, {}, layers, bodies);
    collector.Sort();
    uint32_t count = 0;
    for (const RayCastResult& result : collector.mHits) {
        cn_ray_hit hit;
        if (!fill_hit(*w, result.mBodyID, result.mSubShapeID2, cast.GetPointOnRay(result.mFraction), Vec3::sZero(),
                result.mFraction * ray->max_distance, hit)) {
            continue;
        }
        if (count < capacity) {
            out[count] = hit;
        }
        count++;
    }
    return count;
}

void raycast_batch(cn_world handle, const cn_ray* rays, uint32_t count, const cn_query_filter* filter, cn_ray_hit* out)
{
    for (uint32_t i = 0; i < count; i++) {
        raycast(handle, &rays[i], filter, &out[i]);
    }
}

RefConst<Shape> query_shape(const cn_shape_desc& desc)
{
    cn_create_shape c = {};
    c.kind = desc.kind;
    memcpy(c.size, desc.size, sizeof(c.size));
    c.density = 1000;
    Shape::ShapeResult result = create_shape(c);
    if (result.HasError()) {
        report(CN_LOG_ERROR, "physics: a query's shape: %s", result.GetError().c_str());
        return nullptr;
    }
    return result.Get();
}

uint32_t shape_cast(cn_world handle, const cn_shape_cast* sweep, const cn_query_filter* in_filter, cn_ray_hit* hit)
{
    *hit = {};
    World_Impl* w = find_world(handle);
    RefConst<Shape> shape = w != nullptr ? query_shape(sweep->shape) : nullptr;
    if (shape == nullptr || !(sweep->distance > 0)) {
        return 0;
    }
    const cn_query_filter& filter = in_filter ? *in_filter : FILTER_ALL;
    RVec3 origin = to_rvec3(sweep->origin);
    RShapeCast cast = RShapeCast::sFromWorldTransform(shape, Vec3::sOne(),
        RMat44::sRotationTranslation(to_quat(sweep->rotation), origin), to_vec3(sweep->direction) * sweep->distance);
    ClosestHitCollisionCollector<CastShapeCollector> collector;
    Layer_Mask_Filter layers(filter.layers);
    Query_Body_Filter bodies(*w, filter);
    w->system.GetNarrowPhaseQuery().CastShape(cast, ShapeCastSettings(), origin, collector, {}, layers, bodies);
    if (!collector.HadHit()) {
        return 0;
    }
    const ShapeCastResult& result = collector.mHit;
    Vec3 axis = result.mPenetrationAxis;
    Vec3 normal = axis.IsNearZero() ? -to_vec3(sweep->direction) : -axis.Normalized();
    return fill_hit(*w, result.mBodyID2, result.mSubShapeID2, origin + result.mContactPointOn2, normal,
        result.mFraction * sweep->distance, *hit);
}

uint32_t overlap(cn_world handle, const cn_overlap_query* query, const cn_query_filter* in_filter, cn_overlap_hit* out, uint32_t capacity)
{
    World_Impl* w = find_world(handle);
    RefConst<Shape> shape = w != nullptr ? query_shape(query->shape) : nullptr;
    if (shape == nullptr) {
        return 0;
    }
    const cn_query_filter& filter = in_filter ? *in_filter : FILTER_ALL;
    RVec3 origin = to_rvec3(query->origin);
    AllHitCollisionCollector<CollideShapeCollector> collector;
    Layer_Mask_Filter layers(filter.layers);
    Query_Body_Filter bodies(*w, filter);
    w->system.GetNarrowPhaseQuery().CollideShape(shape, Vec3::sOne(), RMat44::sRotationTranslation(to_quat(query->rotation), origin),
        CollideShapeSettings(), origin, collector, {}, layers, bodies);
    // Each body once, in handle order.
    Array<cn_overlap_hit> hits;
    for (const CollideShapeResult& result : collector.mHits) {
        cn_overlap_hit hit = { w->handles[result.mBodyID2.GetIndex()], w->users[result.mBodyID2.GetIndex()] };
        hits.push_back(hit);
    }
    QuickSort(hits.begin(), hits.end(), [](const cn_overlap_hit& a, const cn_overlap_hit& b) { return a.body.index < b.body.index; });
    auto end = std::unique(hits.begin(), hits.end(), [](const cn_overlap_hit& a, const cn_overlap_hit& b) { return a.body.index == b.body.index; });
    uint32_t count = uint32_t(end - hits.begin());
    for (uint32_t i = 0; i < count && i < capacity; i++) {
        out[i] = hits[i];
    }
    return count;
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
    create_mesh_shape,
    raycast,
    raycast_all,
    raycast_batch,
    shape_cast,
    overlap,
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
