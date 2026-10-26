# FidelityFX

The FidelityFX API's loader and FSR's library from the [AMD FSR SDK](https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK), release `v2.3.0`, which the D3D12 backend runs FSR through (see [Upscalers](../../docs/gpu/upscalers.md#fsr)).

| File | From | What it is |
|---|---|---|
| `2.3.0/amd_fidelityfx_loader_dx12.dll` | `Kits/FidelityFX/signedbin` | The FidelityFX API's loader, which finds the effects' libraries and picks the newest version that the device runs |
| `2.3.0/amd_fidelityfx_upscaler_dx12.dll` | `Kits/FidelityFX/signedbin` | The upscalers: FSR 4, FSR 3.1 and FSR 2 |
| `LICENSE.txt` | `docs/license.md` | The MIT license that the SDK's license lists both libraries and the API's headers under |

- **Not committed:** `just install-fidelityfx`, which `just install` runs, downloads the two libraries into `2.3.0/`, and the build copies them next to the executables. Both are signed by Advanced Micro Devices.
- **The headers** are not here: `lib/core/gpu/d3d12/ffx.odin` declares what the backend uses of `ffx_api.h`, `ffx_api_types.h`, `dx12/ffx_api_dx12.h` and `ffx_upscale.h`, with their license.
- **Updating:** change `fidelityfx_version` in the justfile and `FFX_SDK_VERSION` in `ffx.odin`, check `FFX_UPSCALER_VERSION` and the declarations against the new headers, and check in the new release's `docs/license.md` that the two libraries are still under the MIT license.
- **Shipping:** a game that ships the libraries ships `LICENSE.txt` with them; the build copies it next to them as `amd_fidelityfx_LICENSE.txt`.
