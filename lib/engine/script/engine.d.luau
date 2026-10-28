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

-- A reference to an asset by its GUID, from a behaviour's Field.asset. Two references to one asset are equal.
declare extern type Asset with
	guid: string
end

declare World: {
	spawn: ((position: WorldPosition?, rotation: Quaternion?) -> Entity) & ((prefab: Asset, position: WorldPosition?, rotation: Quaternion?) -> Entity),
	query: (...ComponentType) -> { Entity },
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
}

declare Input: {
	is_down: (key: number) -> boolean,
	was_pressed: (key: number) -> boolean,
	was_released: (key: number) -> boolean,
	mouse_position: vector,
	mouse_delta: vector,
	scroll: number,
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

declare function wait(seconds: number?): ()
declare function wait_realtime(seconds: number): ()
declare function wait_frames(frames: number?): ()
declare function wait_until(predicate: () -> boolean): ()
declare function wait_event(entity: Entity, name: string): ...any

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
}

-- What the device can do that the quality depends on. aa lists the anti-aliasing techniques that it runs.
type RenderCaps = {
	ray_query: boolean,
	vendor: string,
	video_memory: number,
	aa: { string },
}
