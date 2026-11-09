package render

import "core:hash"
import "core:log"

import "cinnabar:core"
import "cinnabar:core/gpu"

// A frame's transient textures each take one, since no two share a texture in a frame: about 35 for a frame at High,
// about 65 with every feature on, and each of the editor's previews adds its own targets. Each extra view (see
// docs/rendering/frame.md#views) draws the full pipeline and takes as many of its own, so the frame's own view and three
// extra ones fit.
MAX_CACHED_TEXTURES :: 320
MAX_HISTORY_TEXTURES :: 16
// A cached texture or history is destroyed after this many frames without use.
CACHE_LIFETIME :: 8

// Texture_Cache keeps the graph's transient textures between frames, which every view of a frame shares. It lives in
// Game_State, so it holds no pointers or strings: a label is kept as a hash. Its frame counts the frames, one for each
// graph that begin starts. histories is the set of the graphs that name none (see begin).
Texture_Cache :: struct {
	entries:   [MAX_CACHED_TEXTURES]Cache_Entry,
	histories: History_Set,
	frame:     u64,
}

// History_Set is the history textures' pairs of one view (see history_texture and View_State). A view that is not drawn
// in a frame has no valid history in the next.
History_Set :: struct {
	entries: [MAX_HISTORY_TEXTURES]History_Entry,
}

@(private)
Cache_Entry :: struct {
	texture:    gpu.Texture,
	desc:       gpu.Texture_Desc,
	label_hash: u64,
	last_used:  u64,
}

// History_Entry is a history texture's pair (see history_texture). textures[current] is the one that the frame that
// last used it writes. written is the last frame that used it and executed, so its texture holds what that frame wrote.
@(private)
History_Entry :: struct {
	textures:   [2]gpu.Texture,
	desc:       gpu.Texture_Desc,
	label_hash: u64,
	current:    int,
	last_used:  u64,
	written:    u64,
}

// cache_destroy destroys every cached texture. Call it from the game's shutdown.
cache_destroy :: proc(cache: ^Texture_Cache, platform: ^core.Platform_API) {
	for &entry in cache.entries {
		if entry.texture != {} {
			platform.gpu_destroy_texture(entry.texture)
		}
	}
	history_set_destroy(&cache.histories, platform)
	cache^ = {}
}

// history_set_destroy destroys every history of a set at once.
history_set_destroy :: proc(set: ^History_Set, platform: ^core.Platform_API) {
	for &entry in set.entries {
		destroy_history(&entry, platform)
	}
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

// history_set_trim destroys the histories of a set that were not used for CACHE_LIFETIME frames, as of the cache's frame.
@(private)
history_set_trim :: proc(cache: ^Texture_Cache, set: ^History_Set, platform: ^core.Platform_API) {
	for &entry in set.entries {
		if entry.textures[0] != {} && cache.frame - entry.last_used > CACHE_LIFETIME {
			destroy_history(&entry, platform)
		}
	}
}

// cache_acquire returns a texture that matches the description and is not used yet in this frame. A full cache
// destroys its least recently used texture that this frame does not use, as a window that is resized every frame
// needs. It returns the nil handle when this frame uses every texture or the backend cannot create one.
@(private)
cache_acquire :: proc(cache: ^Texture_Cache, platform: ^core.Platform_API, desc: gpu.Texture_Desc) -> gpu.Texture {
	key := desc
	key.label = ""
	label_hash := hash.fnv64a(transmute([]byte)desc.label)
	free_slot := -1
	oldest := -1
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
		if entry.last_used != cache.frame && (oldest < 0 || entry.last_used < cache.entries[oldest].last_used) {
			oldest = i
		}
	}
	if free_slot < 0 && oldest >= 0 {
		platform.gpu_destroy_texture(cache.entries[oldest].texture)
		cache.entries[oldest] = {}
		free_slot = oldest
	}
	if free_slot < 0 {
		log.errorf("render: texture %q: more than %d cached textures in one frame", desc.label, MAX_CACHED_TEXTURES)
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

// cache_history returns the history texture of a label for this frame: the texture to write and the one that holds
// last frame's contents, which are valid only if the history was used in the last frame with the same description, and
// that frame executed.
// A new description, as a new view size gives, makes the pair again. It returns ok false when every history is in use
// or the backend cannot create the textures.
@(private)
cache_history :: proc(cache: ^Texture_Cache, set: ^History_Set, platform: ^core.Platform_API, desc: gpu.Texture_Desc) -> (current, previous: gpu.Texture, valid, ok: bool) {
	key := desc
	key.label = ""
	key.usage += {.Sampled, .Storage}
	label_hash := hash.fnv64a(transmute([]byte)desc.label)
	entry: ^History_Entry
	free_slot := -1
	for &e, i in set.entries {
		if e.textures[0] == {} {
			if free_slot < 0 {
				free_slot = i
			}
		} else if e.label_hash == label_hash {
			entry = &e
		}
	}
	if entry != nil {
		assert(entry.last_used != cache.frame, "render: a history texture is used twice in a frame")
		if entry.desc == key {
			valid = entry.written == cache.frame - 1
			entry.current = 1 - entry.current
			entry.last_used = cache.frame
			return entry.textures[entry.current], entry.textures[1 - entry.current], valid, true
		}
		destroy_history(entry, platform)
	} else if free_slot >= 0 {
		entry = &set.entries[free_slot]
	} else {
		log.errorf("render: history %q: more than %d history textures", desc.label, MAX_HISTORY_TEXTURES)
		return
	}
	create := key
	create.label = desc.label
	textures := [2]gpu.Texture{platform.gpu_create_texture(create, nil), platform.gpu_create_texture(create, nil)}
	entry^ = {
		textures   = textures,
		desc       = key,
		label_hash = label_hash,
		last_used  = cache.frame,
	}
	if textures[0] == {} || textures[1] == {} {
		destroy_history(entry, platform)
		return
	}
	return textures[0], textures[1], false, true
}

// cache_commit_frame marks the histories of a set that this frame used as written. execute calls it once the graph is
// submitted.
@(private)
cache_commit_frame :: proc(cache: ^Texture_Cache, set: ^History_Set) {
	for &entry in set.entries {
		if entry.textures[0] != {} && entry.last_used == cache.frame {
			entry.written = cache.frame
		}
	}
}

@(private = "file")
destroy_history :: proc(entry: ^History_Entry, platform: ^core.Platform_API) {
	for t in entry.textures {
		if t != {} {
			platform.gpu_destroy_texture(t)
		}
	}
	entry^ = {}
}
