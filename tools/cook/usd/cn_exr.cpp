// The cooker's OpenEXR decoder: TinyEXR, from vendor/lightusd's src/external, with the miniz that LightUSD's library
// already holds. See cn_exr.h.
#include "cn_exr.h"

#define TINYEXR_IMPLEMENTATION
#define TINYEXR_USE_MINIZ 1
#define TINYEXR_USE_OPENMP 0
#define TINYEXR_USE_THREAD 1
#include "external/tinyexr.h"

extern "C" float *cn_exr_decode(const uint8_t *data, size_t size, int32_t *width, int32_t *height, const char **error) {
	float *rgba = nullptr;
	int w = 0;
	int h = 0;
	const char *message = nullptr;
	if (LoadEXRFromMemory(&rgba, &w, &h, data, size, &message) != TINYEXR_SUCCESS) {
		*error = message;
		return nullptr;
	}
	*width = w;
	*height = h;
	*error = nullptr;
	return rgba;
}

extern "C" void cn_exr_free(float *pixels) {
	free(pixels);
}

extern "C" void cn_exr_free_error(const char *error) {
	FreeEXRErrorMessage(error);
}
