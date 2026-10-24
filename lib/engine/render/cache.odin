package render

import "core:hash"
import "core:log"

import "cinnabar:core"
import "cinnabar:core/gpu"

MAX_CACHED_TEXTURES :: 64
// A cached texture is destroyed after this many frames without use.
CACHE_LIFETIME :: 8

// Texture_Cache keeps the graph's transient textures between frames. It lives in Game_State, so it holds
// no pointers or strings: a label is kept as a hash.
Texture_Cache :: struct {
	entries: [MAX_CACHED_TEXTURES]Cache_Entry,
	frame:   u64,
}

@(private)
Cache_Entry :: struct {
	texture:    gpu.Texture,
	desc:       gpu.Texture_Desc,
	label_hash: u64,
	last_used:  u64,
}

// cache_destroy destroys every cached texture. Call it from the game's shutdown.
cache_destroy :: proc(cache: ^Texture_Cache, platform: ^core.Platform_API) {
	for &entry in cache.entries {
		if entry.texture != {} {
			platform.gpu_destroy_texture(entry.texture)
		}
	}
	cache^ = {}
}

// cache_begin_frame starts a frame and destroys the textures that were not used for CACHE_LIFETIME frames.
@(private)
cache_begin_frame :: proc(cache: ^Texture_Cache, platform: ^core.Platform_API) {
	cache.frame += 1
	for &entry in cache.entries {
		if entry.texture != {} && cache.frame - entry.last_used > CACHE_LIFETIME {
			platform.gpu_destroy_texture(entry.texture)
			entry = {}
		}
	}
}

// cache_acquire returns a texture that matches the description and is not used yet in this frame.
// It returns the nil handle when the cache is full or the backend cannot create the texture.
@(private)
cache_acquire :: proc(cache: ^Texture_Cache, platform: ^core.Platform_API, desc: gpu.Texture_Desc) -> gpu.Texture {
	key := desc
	key.label = ""
	label_hash := hash.fnv64a(transmute([]byte)desc.label)
	free_slot := -1
	for &entry, i in cache.entries {
		if entry.texture == {} {
			if free_slot < 0 {
				free_slot = i
			}
			continue
		}
		if entry.desc == key && entry.label_hash == label_hash && entry.last_used != cache.frame {
			entry.last_used = cache.frame
			return entry.texture
		}
	}
	if free_slot < 0 {
		log.errorf("render: texture %q: more than %d cached textures", desc.label, MAX_CACHED_TEXTURES)
		return {}
	}
	texture := platform.gpu_create_texture(desc, nil)
	if texture != {} {
		cache.entries[free_slot] = {
			texture    = texture,
			desc       = key,
			label_hash = label_hash,
			last_used  = cache.frame,
		}
	}
	return texture
}
