// The shader side of the fixed root signature. See docs/gpu.md#binding-model.
#ifndef CINNABAR_HLSLI
#define CINNABAR_HLSLI

// Push constants: up to 128 bytes, set with gpu.cmd_push_constants.
#define CN_PUSH_CONSTANTS(Type, name) ConstantBuffer<Type> name : register(b0, space0)

// Pass constants: the root CBV, set with gpu.cmd_set_pass_constants.
#define CN_PASS_CONSTANTS(Type, name) ConstantBuffer<Type> name : register(b1, space0)

// The draw ID of an indirect draw: the draw_id of its argument record. Portable argument records store the record's
// index, which a Vulkan backend delivers as DrawIndex. Every other draw sees 0.
struct CnDraw {
	uint id;
};
ConstantBuffer<CnDraw> cn_draw : register(b2, space0);
#define CN_DRAW_ID (cn_draw.id)

// Bindless access. Indices come from gpu.read_index, gpu.write_index and gpu.sampler_index.
// Wrap an index in NonUniformResourceIndex when it can differ within a wave.
ByteAddressBuffer cn_buffer(uint index) { return ResourceDescriptorHeap[index]; }
RWByteAddressBuffer cn_rw_buffer(uint index) { return ResourceDescriptorHeap[index]; }
Texture2D<float4> cn_texture(uint index) { return ResourceDescriptorHeap[index]; }
RWTexture2D<float4> cn_rw_texture(uint index) { return ResourceDescriptorHeap[index]; }
SamplerState cn_sampler(uint index) { return SamplerDescriptorHeap[index]; }
// A top-level acceleration structure, from gpu.read_index(accel).
RaytracingAccelerationStructure cn_accel(uint index) { return ResourceDescriptorHeap[index]; }

#endif
