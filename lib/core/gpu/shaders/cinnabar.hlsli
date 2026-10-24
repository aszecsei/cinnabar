// The shader side of the fixed root signature. See docs/gpu.md#binding-model.
#ifndef CINNABAR_HLSLI
#define CINNABAR_HLSLI

// Push constants: up to 128 bytes, set with gpu.cmd_push_constants.
#define CN_PUSH_CONSTANTS(Type, name) ConstantBuffer<Type> name : register(b0, space0)

// Pass constants: the root CBV, set with gpu.cmd_set_pass_constants.
#define CN_PASS_CONSTANTS(Type, name) ConstantBuffer<Type> name : register(b1, space0)

// Bindless access. Indices come from gpu.read_index, gpu.write_index and gpu.sampler_index.
// Wrap an index in NonUniformResourceIndex when it can differ within a wave.
ByteAddressBuffer cn_buffer(uint index) { return ResourceDescriptorHeap[index]; }
RWByteAddressBuffer cn_rw_buffer(uint index) { return ResourceDescriptorHeap[index]; }
Texture2D<float4> cn_texture(uint index) { return ResourceDescriptorHeap[index]; }
RWTexture2D<float4> cn_rw_texture(uint index) { return ResourceDescriptorHeap[index]; }
SamplerState cn_sampler(uint index) { return SamplerDescriptorHeap[index]; }

#endif
