package asset_format

// The engine components that the cooker reads from a scene's text, by their stable IDs and field names, since it cannot
// lay out the native components (see docs/content/kinds/nav-meshes.md#input). Their defaults are here, so the registry
// and the cooker read the same values: lib/engine/ecs, lib/engine/physics and lib/engine/nav register them with these.

// Stable IDs, as the engine registers them (see docs/world/ecs.md#component-registry).
SCENE_VOLUME_ID :: 42
SCENE_RIGID_BODY_ID :: 64
SCENE_COLLIDER_ID :: 65
SCENE_CHARACTER_ID :: 75
SCENE_NAV_MESH_VOLUME_ID :: 128

// The rotation and scale of a Transform or a Local_Transform that a scene leaves out.
DEFAULT_ROTATION :: quaternion128(1)
DEFAULT_SCALE :: [3]f32{1, 1, 1}

// Motion is how a body moves. It matches Motion in lib/core/physics, which lib/engine/physics checks.
Motion :: enum u8 {
	Static,
	Kinematic,
	Dynamic,
}

// Rigid_Body makes its entity a body that the simulation moves, or that moves by its Transform: a dynamic body falls
// and is pushed, a kinematic one follows its Transform and pushes, and a static one never moves. Its shape is the
// entity's Collider. An entity with a Collider and no Rigid_Body is a static body.
Rigid_Body :: struct {
	motion:          Motion,
	// In kg. 0 takes the mass from the collider's density.
	mass:            f32 `editor:"range=0,10000"`,
	linear_damping:  f32 `editor:"range=0,1"`,
	angular_damping: f32 `editor:"range=0,1"`,
	gravity_factor:  f32 `editor:"range=-10,10"`,
	// Continuous collision detection, for a fast body that would pass through thin ones.
	ccd:             bool,
	start_asleep:    bool,
	// Its contacts reach Physics_Events and its entity's behaviours (see docs/physics/design.md#events).
	report_contacts: bool,
}

DEFAULT_RIGID_BODY :: Rigid_Body {
	motion          = .Dynamic,
	linear_damping  = 0.05,
	angular_damping = 0.05,
	gravity_factor  = 1,
	report_contacts = true,
}

Collider_Shape :: enum u8 {
	Box,
	Sphere,
	// Along the entity's y.
	Capsule,
	// Along the entity's y.
	Cylinder,
	// The triangles of the mesh asset's collision data. A dynamic body takes their convex hull instead, since a mesh
	// has no mass.
	Mesh,
	// The convex hull of the mesh asset's collision data.
	Convex_Mesh,
}

// Collider is its entity's shape, scaled by its Transform: a box of size meters, a sphere of radius, a capsule or
// cylinder of radius and height, its whole height along y, or a mesh asset's collision triangles or their hull, which
// the cooker writes unless the mesh's collision import setting is false (see docs/physics/design.md#shapes). offset and
// rotation place it in the entity. A Collider on a descendant of a Rigid_Body, with no Rigid_Body between them, is a
// part of that body's shape, and the body takes its friction, restitution, layer and sensor from its own Collider, or
// its first part's.
Collider :: struct {
	shape:         Collider_Shape,
	size:          [3]f32 `editor:"range=0,1000"`,
	radius:        f32 `editor:"range=0,1000"`,
	height:        f32 `editor:"range=0,1000"`,
	mesh:          Guid `asset:"mesh"`,
	offset:        [3]f32,
	rotation:      quaternion128,
	friction:      f32 `editor:"range=0,2"`,
	restitution:   f32 `editor:"range=0,1"`,
	// In kg/m³, which gives a dynamic body's mass when its Rigid_Body's is 0.
	density:       f32 `editor:"range=1,20000"`,
	// A sensor detects bodies and does not touch them (see docs/physics/design.md#events).
	sensor:        bool,
	// A sensor that does not move detects only bodies that move, unless this is set.
	detect_static: bool,
	// The object layer, an index into the project's physics.layers (see docs/physics/design.md#layers).
	layer:         u8 `editor:"range=0,31"`,
}

DEFAULT_COLLIDER :: Collider {
	shape    = .Box,
	size     = 1,
	radius   = 0.5,
	height   = 2,
	rotation = 1,
	friction = 0.5,
	density  = 1000,
}

// Nav_Mesh_Volume asks the cooker to bake navmeshes inside its entity's Volume, which must be a Box (see
// docs/content/kinds/nav-meshes.md#the-volume). Each agent type that it bakes for makes one navmesh, a sub-asset of the
// scene.
Nav_Mesh_Volume :: struct {
	// Bit i bakes for the i-th agent type of the project's nav.agents. 0 bakes for every type.
	agents:      u32,
	// The size of a cell of the bake's grid across, in meters. Smaller cells follow edges closer and bake slower.
	cell_size:   f32 `editor:"range=0.01,2"`,
	// The size of a cell up, in meters, which the agents' step height and height are rounded to.
	cell_height: f32 `editor:"range=0.01,2"`,
	// The cells along a tile's edge. Each tile bakes on its own and has its own cache key.
	tile_size:   u32 `editor:"range=8,1024"`,
}

DEFAULT_NAV_MESH_VOLUME :: Nav_Mesh_Volume {
	cell_size   = 0.2,
	cell_height = 0.1,
	tile_size   = 64,
}

// In meters, for a Volume's extent of 0, as a component added in the editor leaves it.
VOLUME_DEFAULT_EXTENT :: 5

Volume_Shape :: enum u8 {
	// Everywhere, as a base that local volumes go over.
	Global,
	// A box along the entity's axes, extents times its scale.
	Box,
	// A sphere, a radius of extents.x times the largest of its scale.
	Sphere,
}

// Volume gives its entity's settings components a shape (see docs/world/volumes.md#volumes). Inside it, its settings
// have its weight, and outside it they fall off to 0 over the blend distance. Where volumes overlap, a higher priority
// goes on top, then a smaller volume. To turn a volume off, deactivate its entity.
Volume :: struct {
	shape:          Volume_Shape,
	// Half the box's size along each of the entity's axes, or the sphere's radius in x, in meters. 0 gives
	// VOLUME_DEFAULT_EXTENT.
	extents:        [3]f32 `editor:"range=0,100"`,
	// In meters outside the shape. 0 is a hard edge.
	blend_distance: f32 `editor:"range=0,100"`,
	priority:       f32 `editor:"range=-100,100"`,
	// The settings' share where the volume is whole, up to 1. 0 means 1.
	weight:         f32 `editor:"range=0,1"`,
}
