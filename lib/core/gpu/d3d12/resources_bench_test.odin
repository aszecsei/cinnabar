package gpu_d3d12

import "core:log"
import "core:testing"
import "core:time"

import "cinnabar:core/gpu"

// The resources that the benchmark creates in each round: buffers from 64 KB to 1 MB, and textures from 64² to 1024²
// with mips, every fourth one a render target.
@(private = "file")
BENCH_BUFFERS :: 4096
@(private = "file")
BENCH_TEXTURES :: 2048
@(private = "file")
BENCH_ROUNDS :: 3

// resource_creation times the creation and destruction of thousands of resources on the real device (see
// docs/gpu/resources-and-pipelines.md#memory). It needs a GPU and the Agility SDK beside the executable, so it is not part
// of just test: just gpu-bench runs it. Without a device it logs and passes.
@(test)
resource_creation :: proc(t: ^testing.T) {
	if !init(nil, {64, 64}, "cinnabar-gpu-bench") {
		log.warn("gpu-bench: no D3D12 device, skipped")
		shutdown()
		return
	}
	defer shutdown()
	log.infof("gpu-bench: %s", cstring(&dev.adapter_info.name[0]))

	buffers := make([]gpu.Buffer, BENCH_BUFFERS)
	defer delete(buffers)
	textures := make([]gpu.Texture, BENCH_TEXTURES)
	defer delete(textures)
	for round in 0 ..< BENCH_ROUNDS {
		start := time.tick_now()
		for &b, i in buffers {
			b = create_buffer({size = u32(64 << 10) << uint(i % 5), usage = {.Storage}}, nil)
			testing.expect(t, b != {})
		}
		buffer_time := time.tick_since(start)

		start = time.tick_now()
		for &tex, i in textures {
			side := u32(64) << uint(i % 5)
			usage: gpu.Texture_Usages = {.Sampled}
			if i % 4 == 0 {
				usage += {.Render_Target}
			}
			tex = create_texture(
				{size = {side, side}, format = .RGBA8_Unorm, mip_count = 1 if i % 4 == 0 else 6, usage = usage},
				nil,
			)
			testing.expect(t, tex != {})
		}
		texture_time := time.tick_since(start)

		start = time.tick_now()
		for b in buffers {
			destroy_buffer(b)
		}
		for tex in textures {
			destroy_texture(tex)
		}
		// A frame would submit the uploads, before its releases.
		flush_uploads()
		wait_idle()
		stamp_releases(dev.fence_value)
		collect_releases()
		destroy_time := time.tick_since(start)

		log.infof(
			"gpu-bench: round %d: %.1f us a buffer, %.1f us a texture, %.1f us a destruction",
			round,
			time.duration_microseconds(buffer_time) / BENCH_BUFFERS,
			time.duration_microseconds(texture_time) / BENCH_TEXTURES,
			time.duration_microseconds(destroy_time) / (BENCH_BUFFERS + BENCH_TEXTURES),
		)
	}
}
