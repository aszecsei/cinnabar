# SMAA

The reference implementation of SMAA (Jimenez et al. 2012), from [iryoku/smaa](https://github.com/iryoku/smaa) at commit `71c806a838bdd7d517df19192a20f0c61b3ca29d`, under its license in `LICENSE.txt`. The engine's SMAA 1x passes include `SMAA.hlsl` as it is (see `lib/engine/content/shaders/smaa.hlsli` and [Anti-aliasing](../../docs/rendering/anti-aliasing.md#smaa)).

| File | From | What it is |
|---|---|---|
| `SMAA.hlsl` | `SMAA.hlsl` | The shader, unchanged |
| `area.bin` | `Textures/AreaTex.h` | The area lookup table: 160x560 `RG8_Unorm`, rows from the top, the bytes of `areaTexBytes` |
| `search.bin` | `Textures/SearchTex.h` | The search lookup table: 64x16 `R8_Unorm`, the bytes of `searchTexBytes` |

`lib/engine/render/spatial_aa.odin` loads the two tables with `#load`. To update them, take the arrays' bytes from the headers at the new commit, in order.
