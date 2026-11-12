-- The types of the engine's script API (see docs/scripting/README.md). script.definitions adds the rest, which depends on
-- the game: Entity, Key, each exposed component and the game's bindings.

declare extern type WorldPosition with
	function lerp(self, other: WorldPosition, t: number): WorldPosition
	-- For display only. Far from the origin, a number cannot hold every position.
	function to_meters(self): (number, number, number)
	__add: (WorldPosition, vector) -> WorldPosition
	__sub: ((WorldPosition, WorldPosition) -> vector) & ((WorldPosition, vector) -> WorldPosition)
end

declare extern type Quaternion with
	x: number
	y: number
	z: number
	w: number
	function inverse(self): Quaternion
	function normalized(self): Quaternion
	-- Degrees, applied z, then x, then y, as in Unity.
	function euler(self): vector
	function approx(self, other: Quaternion): boolean
	function angle_to(self, other: Quaternion): number
	function rotate_towards(self, to: Quaternion, max_degrees: number): Quaternion
	function slerp(self, to: Quaternion, t: number): Quaternion
	__mul: ((Quaternion, Quaternion) -> Quaternion) & ((Quaternion, vector) -> vector)
end

declare extern type ComponentType with
	name: string
end

declare extern type ComponentRef with
	entity: Entity
end

declare extern type TransformRef extends ComponentRef with
	position: WorldPosition
	rotation: Quaternion
	scale: vector
	-- A child's pose relative to its parent. An entity without a parent has none.
	local_position: vector
	local_rotation: Quaternion
	local_scale: vector
	-- +Z, +Y and +X of the rotation, as in Unity.
	forward: vector
	up: vector
	right: vector
end

declare extern type FieldSpec with
end

-- An action's parameter, from Param (see docs/ai/agents.md#script-actions).
declare extern type ParamSpec with
end

-- A reference to an asset by its GUID, from a behaviour's Field.asset. Two references to one asset are equal.
declare extern type Asset with
	guid: string
end

declare World: {
	spawn: ((position: WorldPosition?, rotation: Quaternion?) -> Entity) & ((prefab: Asset, position: WorldPosition?, rotation: Quaternion?) -> Entity),
	query: (...ComponentType) -> { Entity },
	version: () -> number,
	changed: (since: number, ...ComponentType) -> { Entity },
}

declare Quaternion: {
	identity: Quaternion,
	new: (x: number, y: number, z: number, w: number) -> Quaternion,
	euler: (degrees: vector) -> Quaternion,
	angle_axis: (degrees: number, axis: vector) -> Quaternion,
	look_rotation: (forward: vector, up: vector?) -> Quaternion,
	slerp: (a: Quaternion, b: Quaternion, t: number) -> Quaternion,
	angle: (a: Quaternion, b: Quaternion) -> number,
	rotate_towards: (from: Quaternion, to: Quaternion, max_degrees: number) -> Quaternion,
}

declare WorldPosition: {
	origin: WorldPosition,
	from_meters: (x: number, y: number, z: number) -> WorldPosition,
	lerp: (a: WorldPosition, b: WorldPosition, t: number) -> WorldPosition,
}

declare Time: {
	delta: number,
	time: number,
	real_time: number,
	frame: number,
	fixed_delta: number,
	alpha: number,
	-- True in fixed_update and in what a fixed tick resumes, where delta is the tick's duration.
	in_fixed: boolean,
}

declare Input: {
	is_down: (key: number) -> boolean,
	was_pressed: (key: number) -> boolean,
	was_released: (key: number) -> boolean,
	mouse_position: vector,
	mouse_delta: vector,
	scroll: number,
	-- Pads are in slots 1 to 4. A slot with no pad has nothing down and every axis at 0.
	gamepad_connected: (pad: number) -> boolean,
	gamepad_is_down: (pad: number, button: number) -> boolean,
	gamepad_was_pressed: (pad: number, button: number) -> boolean,
	gamepad_was_released: (pad: number, button: number) -> boolean,
	gamepad_axis: (pad: number, axis: number) -> number,
	-- The characters typed since the last frame, in UTF-8. Backspace and Enter are keys, not text.
	text: string,
	-- What an IME is composing, which is not text yet, and the bytes of it before the cursor.
	composition: string,
	composition_cursor: number,
}

declare Debug: {
	log: (...any) -> (),
	warn: (...any) -> (),
	error: (...any) -> (),
}

-- Zones in the editor's profiler (see docs/scripting/api.md#profile). A zone that is still open when its callback
-- returns or yields is closed there.
declare Profile: {
	begin: (name: string) -> (),
	finish: () -> (),
	zone: <A..., R...>(name: string, fn: (A...) -> R..., A...) -> R...,
}

-- The world's generator (see docs/scripting/api.md#random). One seed gives one sequence. integer includes both ends.
declare Random: {
	value: () -> number,
	range: (min: number, max: number) -> number,
	integer: (min: number, max: number) -> number,
	seed: (seed: number) -> (),
	get_seed: () -> number,
	inside_unit_sphere: () -> vector,
	on_unit_sphere: () -> vector,
	inside_unit_circle: () -> vector,
	rotation: () -> Quaternion,
}

declare Field: {
	number: (default: number?) -> FieldSpec,
	boolean: (default: boolean?) -> FieldSpec,
	string: (default: string?) -> FieldSpec,
	vector: (default: vector?) -> FieldSpec,
	entity: () -> FieldSpec,
	asset: (kind: string?) -> FieldSpec,
}

-- A class is a table, so its methods can be defined on it. Its instances are untyped for now.
declare Behaviour: {
	define: (name: string, fields: { [string]: FieldSpec }?) -> { [any]: any },
}

declare Param: {
	number: (default: number?) -> ParamSpec,
	boolean: (default: boolean?) -> ParamSpec,
	string: (default: string?) -> ParamSpec,
	vector: (default: vector?) -> ParamSpec,
	entity: () -> ParamSpec,
	position: () -> ParamSpec,
}

-- An action class, which an agent's decision starts by its name. Its start, tick and stop are methods, and tick returns
-- "running", "succeeded" or "failed", or nothing for running.
declare Action: {
	define: (name: string, params: { [string]: ParamSpec }?) -> { [any]: any },
}

-- A physics query's hit (see docs/physics/design.md#scripts): the entity whose body it hit, the point, the surface's
-- normal there, and the distance along the ray or the sweep.
type RaycastHit = {
	entity: Entity,
	position: WorldPosition,
	normal: vector,
	distance: number,
}

-- What a character stands on after the last tick: the ground's normal, its velocity under the character, and its
-- entity, which is nil in the air or on a body without one.
type CharacterGround = {
	state: "ground" | "steep" | "air",
	normal: vector,
	velocity: vector,
	entity: Entity?,
}

-- A path on the navmeshes (see docs/ai/navigation.md#scripts): found to the goal, partial to the reachable point
-- nearest it, or failed off every navmesh, and its corners from the start to its end.
type NavPath = {
	status: "found" | "partial" | "failed",
	corners: { WorldPosition },
}

-- How far a straight walk along a navmesh goes: the fraction t of the way, the point that it reaches, and the normal of
-- the wall that stopped it, which is nil when it reached its end.
type NavRaycastHit = {
	t: number,
	position: WorldPosition,
	normal: vector?,
}

declare function wait(seconds: number?): ()
declare function wait_realtime(seconds: number): ()
declare function wait_frames(frames: number?): ()
declare function wait_until(predicate: () -> boolean): ()
declare function wait_event(entity: Entity, name: string): ...any
-- Waits for the end of the next fixed tick, after its physics step, as Unity's WaitForFixedUpdate does.
declare function wait_fixed(): ()

-- The render quality of the Render bindings, which a game defines with project.define_quality_bindings (see
-- docs/scripting/api.md#render): the settings files' quality keys, with the enums' values as strings.
type RenderQuality = {
	preset: string,
	shadows: string,
	ray_traced_shadows: boolean,
	ao: string,
	ao_level: string,
	gi: string,
	gi_level: string,
	fog: string,
	aa: string,
	render_scale: number,
	lod_error: number,
	mesh_pool: number,
	virtual_shadows: boolean,
	reflections: string,
	reflections_level: string,
	clouds: string,
}

-- What Render.set_quality changes: the fields that it gives. A preset sets every feature first.
type RenderQualityChange = {
	preset: string?,
	shadows: string?,
	ray_traced_shadows: boolean?,
	ao: string?,
	ao_level: string?,
	gi: string?,
	gi_level: string?,
	fog: string?,
	aa: string?,
	render_scale: number?,
	lod_error: number?,
	mesh_pool: number?,
	virtual_shadows: boolean?,
	reflections: string?,
	reflections_level: string?,
	clouds: string?,
}

-- What the device can do that the quality depends on. aa lists the anti-aliasing techniques that it runs, gi the
-- global illumination's, and reflections the reflections'.
type RenderCaps = {
	ray_query: boolean,
	vendor: string,
	video_memory: number,
	aa: { string },
	gi: { string },
	reflections: { string },
}
