// The C API that tools/cook calls to block-compress a texture's mip with Compressonator's CMP_Core, whose own API is
// C++ and compresses one 4x4 block at a time. See docs/content-pipeline.md#textures.

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <thread>
#include <vector>

#include "cmp_core.h"

// Matches Compressed_Format in tools/cook/compressonator.odin.
enum CnFormat : int {
    CN_BC1 = 1,
    CN_BC4 = 4,
    CN_BC5 = 5,
    CN_BC6H = 6,
    CN_BC7 = 7,
};

namespace {

int block_size(int format) { return format == CN_BC1 || format == CN_BC4 ? 8 : 16; }

struct Job {
    int format;
    const void* options;
    // RGBA8 for every format but BC6H, which takes RGBA half floats.
    const uint8_t* pixels;
    unsigned width, height;
    uint8_t* out;
    unsigned blocks_x;
};

// compress_rows compresses the block rows [first, last). A block that reaches past the image's edge repeats its last
// column or row, as a GPU's clamp would.
int compress_rows(const Job& job, unsigned first, unsigned last) {
    const unsigned pixel = job.format == CN_BC6H ? 8 : 4;
    const int size = block_size(job.format);
    for (unsigned by = first; by < last; by++) {
        for (unsigned bx = 0; bx < job.blocks_x; bx++) {
            uint8_t rgba[16 * 4];
            uint8_t red[16], green[16];
            uint16_t rgb_half[16 * 3];
            for (unsigned y = 0; y < 4; y++) {
                for (unsigned x = 0; x < 4; x++) {
                    unsigned sx = std::min(bx * 4 + x, job.width - 1);
                    unsigned sy = std::min(by * 4 + y, job.height - 1);
                    const uint8_t* src = job.pixels + (size_t(sy) * job.width + sx) * pixel;
                    unsigned i = y * 4 + x;
                    if (job.format == CN_BC6H) {
                        std::memcpy(&rgb_half[i * 3], src, 3 * sizeof(uint16_t));
                    } else {
                        std::memcpy(&rgba[i * 4], src, 4);
                        red[i] = src[0];
                        green[i] = src[1];
                    }
                }
            }
            uint8_t* dst = job.out + (size_t(by) * job.blocks_x + bx) * size;
            int result = 0;
            switch (job.format) {
            case CN_BC1: result = CompressBlockBC1(rgba, 16, dst, job.options); break;
            case CN_BC4: result = CompressBlockBC4(red, 4, dst, job.options); break;
            case CN_BC5: result = CompressBlockBC5(red, 4, green, 4, dst, job.options); break;
            case CN_BC6H: result = CompressBlockBC6(rgb_half, 12, dst, job.options); break;
            case CN_BC7: result = CompressBlockBC7(rgba, 16, dst, job.options); break;
            default: return -1;
            }
            if (result != 0) {
                return result;
            }
        }
    }
    return 0;
}

} // namespace

// cn_compressed_size is the size of a mip of the format, in bytes: 4x4 blocks, and a block for a partial one.
extern "C" size_t cn_compressed_size(int format, unsigned width, unsigned height) {
    return size_t((width + 3) / 4) * ((height + 3) / 4) * block_size(format);
}

// cn_compress compresses a mip of width x height pixels into out, which holds cn_compressed_size bytes. pixels are
// RGBA8, or RGBA half floats for BC6H, whose alpha it ignores. BC4 takes red, and BC5 red and green. quality is from 0
// to 1. srgb weighs BC1's error in sRGB. The rows of blocks compress on the CPU's threads. It returns 0, or
// Compressonator's error code.
extern "C" int cn_compress(int format, float quality, bool srgb, const void* pixels, unsigned width, unsigned height, void* out) {
    if (width == 0 || height == 0) {
        return 0;
    }
    void* options = nullptr;
    switch (format) {
    case CN_BC1: CreateOptionsBC1(&options); SetQualityBC1(options, quality); SetSrgbBC1(options, srgb); break;
    case CN_BC4: CreateOptionsBC4(&options); SetQualityBC4(options, quality); break;
    case CN_BC5: CreateOptionsBC5(&options); SetQualityBC5(options, quality); break;
    case CN_BC6H: CreateOptionsBC6(&options); SetQualityBC6(options, quality); SetSignedBC6(options, false); break;
    case CN_BC7: CreateOptionsBC7(&options); SetQualityBC7(options, quality); break;
    default: return -1;
    }
    Job job{format, options, static_cast<const uint8_t*>(pixels), width, height, static_cast<uint8_t*>(out), (width + 3) / 4};
    unsigned rows = (height + 3) / 4;
    unsigned workers = std::max(1u, std::min(std::thread::hardware_concurrency(), rows));
    std::vector<int> results(workers, 0);
    std::vector<std::thread> threads;
    for (unsigned w = 0; w < workers; w++) {
        unsigned first = rows * w / workers, last = rows * (w + 1) / workers;
        threads.emplace_back([&, w, first, last] { results[w] = compress_rows(job, first, last); });
    }
    for (auto& t : threads) {
        t.join();
    }
    switch (format) {
    case CN_BC1: DestroyOptionsBC1(options); break;
    case CN_BC4: DestroyOptionsBC4(options); break;
    case CN_BC5: DestroyOptionsBC5(options); break;
    case CN_BC6H: DestroyOptionsBC6(options); break;
    case CN_BC7: DestroyOptionsBC7(options); break;
    }
    for (int r : results) {
        if (r != 0) {
            return r;
        }
    }
    return 0;
}

// cn_decompress decodes a mip that cn_compress wrote into pixels of the same layout that it took: RGBA8, or RGBA half
// floats for BC6H, with alpha 1. BC4 gives red, and BC5 red and green. The cooker's tests use it. It returns 0, or
// Compressonator's error code.
extern "C" int cn_decompress(int format, const void* data, unsigned width, unsigned height, void* pixels) {
    const int size = block_size(format);
    const unsigned pixel = format == CN_BC6H ? 8 : 4;
    const unsigned blocks_x = (width + 3) / 4, blocks_y = (height + 3) / 4;
    auto* out = static_cast<uint8_t*>(pixels);
    for (unsigned by = 0; by < blocks_y; by++) {
        for (unsigned bx = 0; bx < blocks_x; bx++) {
            const auto* block = static_cast<const uint8_t*>(data) + (size_t(by) * blocks_x + bx) * size;
            uint8_t rgba[64] = {}, red[16] = {}, green[16] = {};
            uint16_t rgb_half[48] = {};
            int result = 0;
            switch (format) {
            case CN_BC1: result = DecompressBlockBC1(block, rgba, nullptr); break;
            case CN_BC4: result = DecompressBlockBC4(block, red, nullptr); break;
            case CN_BC5: result = DecompressBlockBC5(block, red, green, nullptr); break;
            case CN_BC6H: result = DecompressBlockBC6(block, rgb_half, nullptr); break;
            case CN_BC7: result = DecompressBlockBC7(block, rgba, nullptr); break;
            default: return -1;
            }
            if (result != 0) {
                return result;
            }
            for (unsigned y = 0; y < 4; y++) {
                for (unsigned x = 0; x < 4; x++) {
                    unsigned px = bx * 4 + x, py = by * 4 + y, i = y * 4 + x;
                    if (px >= width || py >= height) {
                        continue;
                    }
                    uint8_t* dst = out + (size_t(py) * width + px) * pixel;
                    if (format == CN_BC6H) {
                        // 0x3c00 is 1 as a half float.
                        uint16_t texel[4] = {rgb_half[i * 3], rgb_half[i * 3 + 1], rgb_half[i * 3 + 2], 0x3c00};
                        std::memcpy(dst, texel, sizeof(texel));
                    } else if (format == CN_BC4 || format == CN_BC5) {
                        uint8_t texel[4] = {red[i], green[i], 0, 255};
                        std::memcpy(dst, texel, 4);
                    } else {
                        std::memcpy(dst, &rgba[i * 4], 4);
                    }
                }
            }
        }
    }
    return 0;
}
