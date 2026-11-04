// The audio boundary in C: the same layouts as lib/core/audio/audio.odin, for backends written in C or C++.
// See docs/audio/backends.md#the-contract. A change on either side must change the other, and both assert the sizes.
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CN_AUDIO_API_VERSION 2
#define CN_AUDIO_SAMPLE_RATE 48000
#define CN_AUDIO_MAX_BUS_EFFECTS 4

typedef struct cn_audio_handle { uint32_t index, generation; } cn_audio_handle;
typedef cn_audio_handle cn_sound;
typedef cn_audio_handle cn_voice;
typedef cn_audio_handle cn_bus;

enum cn_audio_feature {
    CN_AUDIO_FEATURE_SPATIAL = 1u << 0,
    CN_AUDIO_FEATURE_STREAMING = 1u << 1,
    CN_AUDIO_FEATURE_BUSES = 1u << 2,
    CN_AUDIO_FEATURE_EFFECTS = 1u << 3,
    CN_AUDIO_FEATURE_STREAM_ADPCM = 1u << 4,
    CN_AUDIO_FEATURE_STREAM_VORBIS = 1u << 5,
    CN_AUDIO_FEATURE_STREAM_OPUS = 1u << 6,
};

enum cn_sound_format {
    CN_SOUND_FORMAT_PCM,
    CN_SOUND_FORMAT_ADPCM,
    CN_SOUND_FORMAT_VORBIS,
    CN_SOUND_FORMAT_OPUS,
};

typedef struct cn_audio_backend_info {
    uint32_t api_version;
    uint32_t features;
    uint32_t layout;
    uint32_t _pad;
    const char* name;
    const char* version;
} cn_audio_backend_info;

typedef struct cn_sound_desc {
    uint64_t frames;
    const int16_t* samples;
    const char* path;
    uint64_t offset;
    uint64_t size;
    uint32_t channels;
    uint32_t format;
    uint32_t skip;
    uint32_t _pad;
} cn_sound_desc;

typedef struct cn_voice_params {
    float position[3];
    float gain;
    float pitch;
    float occlusion;
    float min_distance;
    float max_distance;
    int32_t spatial;
    uint32_t _pad;
} cn_voice_params;

typedef struct cn_voice_desc {
    cn_sound sound;
    cn_bus bus;
    cn_voice_params params;
    int32_t loop;
    uint32_t _pad;
} cn_voice_desc;

enum cn_effect_kind {
    CN_EFFECT_NONE,
    CN_EFFECT_LOW_PASS,
    CN_EFFECT_HIGH_PASS,
    CN_EFFECT_DELAY,
    CN_EFFECT_REVERB,
};

typedef struct cn_effect {
    uint32_t kind;
    float parameters[3];
} cn_effect;

typedef struct cn_audio_stats {
    uint64_t frames_mixed;
    uint64_t stream_starved;
    uint32_t voices;
    uint32_t streams;
    uint32_t sounds;
    uint32_t voices_refused;
} cn_audio_stats;

typedef struct cn_device_status {
    int64_t queued;
    uint64_t played;
    uint64_t starved;
    int32_t open;
    uint32_t _pad;
} cn_device_status;

typedef struct cn_audio_api {
    cn_audio_backend_info (*info)(void);
    void (*update)(void);
    cn_sound (*sound_create)(const cn_sound_desc* desc);
    void (*sound_destroy)(cn_sound sound);
    cn_voice (*voice_play)(const cn_voice_desc* desc);
    void (*voice_set)(cn_voice voice, const cn_voice_params* params);
    void (*voice_stop)(cn_voice voice, float fade);
    int32_t (*voice_playing)(cn_voice voice);
    cn_bus (*bus_create)(const char* name, cn_bus parent);
    void (*bus_set_gain)(cn_bus bus, float gain);
    void (*bus_set_effect)(cn_bus bus, uint32_t slot, const cn_effect* effect);
    void (*set_paused)(int32_t paused);
    void (*stats)(cn_audio_stats* out);
    int32_t (*reset)(void);
    void (*shutdown)(void);
} cn_audio_api;

enum cn_audio_log_level {
    CN_AUDIO_LOG_DEBUG,
    CN_AUDIO_LOG_INFO,
    CN_AUDIO_LOG_WARNING,
    CN_AUDIO_LOG_ERROR,
};

typedef struct cn_audio_host {
    void* (*allocate)(size_t size, size_t align);
    void (*free)(void* ptr);
    void (*log)(int32_t level, const char* message);
    int32_t (*device_write)(const float (*frames)[2], int32_t count);
    void (*device_status)(cn_device_status* out);
    void* (*file_open)(const char* path);
    int64_t (*file_read_at)(void* file, uint64_t offset, void* buffer, uint64_t size);
    int64_t (*file_modified)(void* file);
    void (*file_close)(void* file);
} cn_audio_host;

// The FNV-1a hash of the boundary's sizes, in layout_signature's order in audio.odin, for cn_audio_backend_info.layout.
static inline uint32_t cn_audio_layout(void) {
    const uint32_t sizes[] = {
        sizeof(cn_audio_backend_info),
        sizeof(cn_sound_desc),
        sizeof(cn_voice_params),
        sizeof(cn_voice_desc),
        sizeof(cn_effect),
        sizeof(cn_audio_stats),
        sizeof(cn_device_status),
        sizeof(cn_audio_api),
        sizeof(cn_audio_host),
    };
    uint32_t h = 0x811c9dc5u;
    for (size_t s = 0; s < sizeof(sizes) / sizeof(sizes[0]); s++) {
        for (uint32_t i = 0; i < 4; i++) {
            h = (h ^ ((sizes[s] >> (8 * i)) & 0xff)) * 0x01000193u;
        }
    }
    return h;
}

// A backend's library exports this. The first call sets the backend up, and later calls return the same table.
//   const cn_audio_api* cinnabar_audio_api(const cn_audio_host* host);

#ifdef __cplusplus
}

static_assert(sizeof(cn_audio_handle) == 8);
static_assert(sizeof(cn_audio_backend_info) == 32);
static_assert(sizeof(cn_sound_desc) == 56);
static_assert(sizeof(cn_voice_params) == 40);
static_assert(sizeof(cn_voice_desc) == 64);
static_assert(sizeof(cn_effect) == 16);
static_assert(sizeof(cn_audio_stats) == 32);
static_assert(sizeof(cn_device_status) == 32);
static_assert(sizeof(cn_audio_api) == 15 * sizeof(void*));
static_assert(sizeof(cn_audio_host) == 9 * sizeof(void*));
#endif
