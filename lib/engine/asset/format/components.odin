package asset_format

// The engine components that the cooker reads from a scene's text, by their stable IDs and field names, since it cannot
// lay out the native components (see docs/content/kinds/nav-meshes.md#input). Their defaults are here, so the registry
// and the cooker read the same values: lib/engine/ecs, lib/engine/volume, lib/engine/physics, lib/engine/nav and
// lib/engine/cut register them with these.

// Stable IDs, as the engine registers them (see docs/world/ecs.md#component-registry).
SCENE_VOLUME_ID :: 42
SCENE_RIGID_BODY_ID :: 64
SCENE_COLLIDER_ID :: 65
SCENE_SURFACE_RENDERER_ID :: 51
SCENE_CHARACTER_ID :: 75
SCENE_NAV_MESH_VOLUME_ID :: 128
SCENE_MESH_CUTTER_ID :: 176
SCENE_CUT_TARGET_ID :: 177

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
	// The height map of the entity's Surface_Renderer, over its rectangle, with its holes. Only a static or kinematic
	// body can take one.
	Height_Field,
}

// Collider is its entity's shape, scaled by its Transform: a box of size meters, a sphere of radius, a capsule or
// cylinder of radius and height, its whole height along y, or a mesh asset's collision triangles or their hull, which
// the cooker writes unless the mesh's collision import setting is false, or the height map of its entity's
// Surface_Renderer (see docs/physics/design.md#shapes). offset and
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

// DEFAULT_SURFACE_CELL is a Surface_Renderer's cell, in meters, when its cell is 0.
DEFAULT_SURFACE_CELL :: 1

// Surface_Renderer draws a patch surface (see docs/rendering/surfaces.md#surfaces): a rectangle of size meters along its
// entity's x and z, about its position, as grid patches that the GPU picks by their distance from the camera, with
// its material, which must draw patches (geometry = patches), or the engine's default surface material without one.
// The surface has a hole where hole_mask, a mask texture over the rectangle, reads 0. cell is the finest quad's size
// in meters (0 means DEFAULT_SURFACE_CELL), and height_range how far below and above its plane the material's
// displacement reaches, which culling allows for. height_map is the height texture that the material displaces by, from
// height_range.x where it reads 0 to height_range.y where it reads 1, which a Height_Field Collider and the editor's
// landscape tools read (see docs/rendering/surfaces.md#collision). layer_map is the data texture whose red, green, blue
// and alpha are the weights of the four layers that the material blends, which the landscape tools paint (see
// docs/rendering/surfaces.md#layers). It is here, not in lib/engine/render, since physics reads it too.
Surface_Renderer :: struct {
	size:         [2]f32,
	material:     Guid `asset:"material"`,
	hole_mask:    Guid `asset:"texture"`,
	cell:         f32 `editor:"range=0,100"`,
	height_range: [2]f32,
	cast_shadows: bool,
	height_map:   Guid `asset:"texture"`,
	layer_map:    Guid `asset:"texture"`,
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

Mesh_Cutter_Shape :: enum u8 {
	// A box along the entity's axes, extents times its scale.
	Box,
	// The mesh asset, a .mesh that the editor edits, at the entity's pose. It must be solid.
	Mesh,
}

// Mesh_Cutter is the volume that a cut removes from the meshes that it overlaps (see
// docs/editor/mesh-editing.md#cutters-and-cut-targets), such as a door's opening in its wall. It cuts an entity whose
// Cut_Target's layer is in layers and whose Mesh_Renderer names a .mesh, and never the entities of its own prefab
// instance. The editor does the cut, and the game ignores the component.
Mesh_Cutter :: struct {
	shape:          Mesh_Cutter_Shape,
	// Half the box's size along each of the entity's axes, in meters, times its scale. 0 gives 0.5, a box of 1 m.
	extents:        [3]f32 `editor:"range=0,100"`,
	mesh:           Guid `asset:"mesh"`,
	// The material of the faces that the cut makes, such as a doorway's jambs.
	cap_material:   Guid `asset:"material"`,
	// Bit i cuts the targets of layer i. 0 cuts every layer.
	layers:         u32,
	// The cut also sets the target's Collider to its result.
	cuts_collision: bool,
}

// In meters, for a Mesh_Cutter's extent of 0.
MESH_CUTTER_DEFAULT_EXTENT :: 0.5

DEFAULT_MESH_CUTTER :: Mesh_Cutter {
	extents        = MESH_CUTTER_DEFAULT_EXTENT,
	cuts_collision = true,
}

// Cut_Target lets Mesh_Cutters cut its entity's mesh (see docs/editor/mesh-editing.md#cutters-and-cut-targets). An
// entity opts in by having it. A cutter cuts it when its layer is in the cutter's layers.
Cut_Target :: struct {
	layer: u8 `editor:"range=0,31"`,
}
