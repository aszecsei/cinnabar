// The cooker's C interface to TinyEXR, which tools/cook/exr.odin binds: an OpenEXR image's first part, decoded into
// RGBA floats. A single-channel image comes back in all four channels, and an image without alpha with alpha 1.
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Decodes an image from memory into width × height RGBA floats, which cn_exr_free frees. On failure it returns null
// and the reason in error, which cn_exr_free_error frees.
float *cn_exr_decode(const uint8_t *data, size_t size, int32_t *width, int32_t *height, const char **error);
void cn_exr_free(float *pixels);
void cn_exr_free_error(const char *error);

#ifdef __cplusplus
}
#endif
