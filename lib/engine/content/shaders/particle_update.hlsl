// The particles' update (see docs/rendering/particles.md#particles): a dispatch for each emitter of the frame, with a
// thread for each particle of its range. A living particle ages, dies at its lifetime, or moves with the emitter's
// modules and collides with last frame's depth. A dead one takes one of the frame's new particles from the emitter's
// counter, while any are left, and starts in the emitter's shape. Each living particle then appends its sprite, with its
// color, size and emission from the emitter's curves at its age. A ribbon's emitter instead spawns over its oldest
// particles in its range's order, and appends no sprites: ribbon_build.hlsl draws them.
#include "particles.hlsli"
#include "sprites.hlsli"

// The emitter, in the frame's emitters.
struct Push {
	uint emitter;
};
CN_PUSH_CONSTANTS(Push, push);

static const float TAU = 6.28318530718;

// emitter_point is a point, or with w 0 a direction, of the emitter's space in the anchor's.
float3 emitter_point(Emitter_Record e, float4 p) {
	return float3(dot(e.row0, p), dot(e.row1, p), dot(e.row2, p));
}

// random_direction is a direction, evenly over the sphere.
float3 random_direction(inout uint state) {
	float z = random(state) * 2 - 1;
	float phi = random(state) * TAU;
	float r = sqrt(max(1 - z * z, 0));
	return float3(r * cos(phi), z, r * sin(phi));
}

// spawn starts a particle in the emitter's shape, at a random time in the frame's step, so a steady rate does not
// spawn in layers.
Particle spawn(Emitter_Record e, uint index, uint ticket) {
	uint state = e.seed ^ (index * 9781u + ticket * 6271u + 1u);
	random(state);
	float3 local = 0;
	float3 direction = float3(0, 1, 0);
	switch (e.shape) {
	case SHAPE_POINT:
		direction = random_direction(state);
		break;
	case SHAPE_SPHERE:
		direction = random_direction(state);
		local = direction * e.shape_size.x * pow(random(state), 1.0 / 3.0);
		break;
	case SHAPE_BOX:
		local = (float3(random(state), random(state), random(state)) * 2 - 1) * e.shape_size;
		break;
	case SHAPE_CONE: {
		float r = e.shape_size.x * sqrt(random(state));
		float theta = random(state) * TAU;
		local = float3(r * cos(theta), 0, r * sin(theta));
		float cos_angle = lerp(1, cos(e.shape_size.y), random(state));
		float sin_angle = sqrt(max(1 - cos_angle * cos_angle, 0));
		float phi = random(state) * TAU;
		direction = float3(sin_angle * cos(phi), cos_angle, sin_angle * sin(phi));
		break;
	}
	}
	Particle p;
	p.position = emitter_point(e, float4(local, 1));
	float3 world_direction = emitter_point(e, float4(direction, 0));
	float length_squared = dot(world_direction, world_direction);
	world_direction = length_squared > 1e-12 ? world_direction * rsqrt(length_squared) : float3(0, 1, 0);
	p.velocity = world_direction * lerp(e.speed.x, e.speed.y, random(state));
	p.lifetime = lerp(e.lifetime.x, e.lifetime.y, random(state));
	p.spin = lerp(e.spin.x, e.spin.y, random(state));
	p.rotation = random(state) * TAU;
	p.seed = state;
	p.age = random(state) * e.delta;
	p.position += p.velocity * p.age;
	p.padding = 0;
	return p;
}

// collide bounces a particle off the surface that the camera saw last frame where it is, when it went behind that
// surface by less than a thickness, which a fast particle's step widens.
void collide(inout Particle p, Emitter_Record e, float4 values, float dt) {
	if (constants.has_history == 0) {
		return;
	}
	float4 clip = mul(constants.previous_view_projection, float4(p.position + e.previous_anchor, 1));
	if (clip.w <= constants.near) {
		return;
	}
	float2 uv = clip.xy / clip.w * float2(0.5, -0.5) + 0.5;
	if (any(uv < 0) || any(uv >= 1)) {
		return;
	}
	float4 surface = cn_texture(constants.history).Load(int3(uv * constants.history_size, 0));
	float thickness = max(0.3, length(p.velocity) * dt * 2);
	float behind = clip.w - surface.w;
	if (behind < 0 || behind > thickness) {
		return;
	}
	float3 n = normalize(surface.xyz);
	float into = dot(p.velocity, n);
	if (into >= 0) {
		return;
	}
	float3 along = p.velocity - into * n;
	p.velocity = along * (1 - saturate(values.y)) - into * n * values.x;
	// Back out of the surface, along the view ray's depth, as far as it went in.
	p.position += n * behind;
}

// step moves a living particle by the emitter's modules, in their order, then integrates it.
void step(inout Particle p, Emitter_Record e, float dt) {
	bool collides = false;
	float4 collision = 0;
	for (uint i = 0; i < e.module_count; i++) {
		Effect_Module m = load_module(e.modules + i);
		switch (m.kind) {
		case MODULE_GRAVITY:
			p.velocity += m.values.xyz * dt;
			break;
		case MODULE_DRAG:
			p.velocity *= exp(-m.values.x * dt);
			break;
		case MODULE_NOISE: {
			// Each component leaves out its own axis, so the field has no divergence: it swirls without gathering.
			float3 q = p.position * m.values.y + e.time * 0.3 + float(p.seed & 255) * 0.01;
			float3 field = float3(sin(q.y) + cos(q.z), sin(q.z) + cos(q.x), sin(q.x) + cos(q.y));
			p.velocity += field * m.values.x * dt;
			break;
		}
		case MODULE_COLLIDE:
			collides = true;
			collision = m.values;
			break;
		}
	}
	p.position += p.velocity * dt;
	p.rotation += p.spin * dt;
	if (collides) {
		collide(p, e, collision, dt);
	}
}

[numthreads(64, 1, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	Emitter_Record e = load_emitter(push.emitter);
	if (id.x >= e.capacity) {
		return;
	}
	RWByteAddressBuffer pool = cn_rw_buffer(constants.pool);
	uint address = (e.first + id.x) * sizeof(Particle);
	Particle p = pool.Load<Particle>(address);
	float dt = e.delta;
	bool alive = e.reset == 0 && p.lifetime > 0;
	bool ribbon = (e.flags & EMITTER_RIBBON) != 0;
	// A ribbon's new particles take the frame's next places of the range, after head, over the oldest ones.
	uint ring = (id.x + e.capacity - e.head) % e.capacity;
	if (ribbon && ring < e.spawn) {
		p = spawn(e, id.x, ring);
		pool.Store<Particle>(address, p);
		return;
	}
	if (alive) {
		p.age += dt;
		alive = p.age < p.lifetime;
		if (alive) {
			step(p, e, dt);
		}
	}
	if (ribbon) {
		if (!alive && (e.reset != 0 || p.lifetime > 0)) {
			p.lifetime = 0;
		}
		pool.Store<Particle>(address, p);
		return;
	}
	if (!alive) {
		uint ticket = 0xffffffff;
		if (e.spawn > 0) {
			cn_rw_buffer(constants.counters).InterlockedAdd(push.emitter * 4, 1, ticket);
		}
		if (ticket >= e.spawn) {
			if (e.reset != 0 || p.lifetime > 0) {
				p.lifetime = 0;
				pool.Store<Particle>(address, p);
			}
			return;
		}
		p = spawn(e, id.x, ticket);
	}
	pool.Store<Particle>(address, p);

	float t = p.age / p.lifetime;
	Sprite_Record s;
	s.position = p.position + e.anchor;
	s.size = curve_at(e.curves + CURVE_SIZE, t).x;
	s.color = curve_at(e.curves + CURVE_COLOR, t);
	s.emission = curve_at(e.curves + CURVE_EMISSION, t).rgb;
	s.rotation = p.rotation;
	s.uv_rect = float4(0, 0, 1, 1);
	uint frames = e.flipbook.x * e.flipbook.y;
	if (frames > 1) {
		uint frame = uint(p.age * e.flipbook_rate) % frames;
		float2 cell = 1.0 / float2(e.flipbook);
		s.uv_rect = float4(float2(frame % e.flipbook.x, frame / e.flipbook.x) * cell, cell);
	}
	s.texture = e.texture;
	s.softness = e.softness;
	s.padding = 0;
	append_sprite(constants.sprites, constants.sprite_count, s);
}
