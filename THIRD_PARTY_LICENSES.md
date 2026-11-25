# Third-Party Licenses & Shader Provenance

MetalPie is licensed under the [GNU General Public License v3.0](LICENSE) (`GPL-3.0`), which is compatible with all upstream shader licenses listed below.

Every bundled `.metal` library under [`Sources/MetalPieShaders/Resources/Shaders`](Sources/MetalPieShaders/Resources/Shaders) is ported to native Metal Shading Language (MSL) compute kernels—either by extracting upstream pre-trained neural weights from open-source MagpieFX HLSL / GLSL shaders into FP16 MSL compute kernels, or by porting open-source shader algorithms directly to Metal.

## Shader Provenance Matrix

| MetalPie Shader File | Included Effects | Upstream Project / Author | Upstream License | Notes |
|---|---|---|---|---|
| `Anime4K.metal` | Anime4K Restore S / Soft S, Upscale S, Upscale+Denoise S, Thin, Darken, Bilateral Denoise, Clamp Highlights | [bloc97/Anime4K](https://github.com/bloc97/Anime4K) v4.0.1 (via [Blinue/Magpie](https://github.com/Blinue/Magpie)) | MIT / GPL-3.0 | FP16 MSL compute port with upstream weights and clamping passes. |
| `Anime4KRestoreML.metal` | Anime4K Restore M / Soft M / L / Soft L / VL | [bloc97/Anime4K](https://github.com/bloc97/Anime4K) v4.0.1 (via [Blinue/Magpie](https://github.com/Blinue/Magpie)) | MIT / GPL-3.0 | Pre-trained CNN weights ported from MagpieFX HLSL to FP16 `fma` MSL kernels. |
| `Anime4KUpscaleML.metal` | Anime4K Upscale M / L / VL, Upscale+Denoise M / L / VL | [bloc97/Anime4K](https://github.com/bloc97/Anime4K) v4.0.1 (via [Blinue/Magpie](https://github.com/Blinue/Magpie)) | MIT / GPL-3.0 | Pre-trained 2× PixelShuffle CNN weights ported from MagpieFX HLSL to FP16 MSL kernels. |
| `CuNNy.metal` | CuNNy 2× (`veryfast-NVL`, `fast-NVL`, `3x12-NVL`) | [funnyplanter/CuNNy](https://github.com/funnyplanter/CuNNy) (via [Blinue/Magpie](https://github.com/Blinue/Magpie)) | LGPL-3.0 / GPL-3.0 | Pre-trained FP16 weights with ReLU1 `saturate()` activations ported from MagpieFX HLSL. |
| `FSRCNNX.metal` | FSRCNNX 2× (`8-0-4-1`, `8-0-4-1_LineArt`) | [igv/FSRCNN-TensorFlow](https://github.com/igv/FSRCNN-TensorFlow) (via [Blinue/Magpie](https://github.com/Blinue/Magpie)) | GPL-3.0 | Pre-trained 6-pass CNN weights ported to FP16 MSL compute kernels. |
| `FSR1.metal` | AMD FSR 1.0 (EASU + RCAS) | [GPUOpen-Effects/FidelityFX-FSR](https://github.com/GPUOpen-Effects/FidelityFX-FSR) | MIT | Native MSL compute port of EASU 12-tap and RCAS 5-tap filters. |
| `CAS.metal` | AMD FidelityFX CAS; Adaptive Sharpen | [GPUOpen-Effects/FidelityFX-CAS](https://github.com/GPUOpen-Effects/FidelityFX-CAS); [bacondither/Adaptive-sharpen](https://github.com/bacondither/Adaptive-sharpen) | MIT; BSD-2-Clause | Native MSL compute ports (HDR-aware CAS and 2-pass Adaptive Sharpen). |
| `SGSR.metal` | Qualcomm SGSR v1 | [SnapdragonGameStudios/snapdragon-gsr](https://github.com/SnapdragonGameStudios/snapdragon-gsr) | BSD-3-Clause | Native single-pass MSL compute port of Snapdragon Game Super Resolution v1. |
| `FXAA.metal` | FXAA 3.11 | NVIDIA / Timothy Lottes (via [Blinue/Magpie](https://github.com/Blinue/Magpie)) | Public Domain / GPL-3.0 | Native MSL compute port supporting Low/Medium/High/Ultra search presets. |
| `PixelArt.metal` | xBRZ Freescale; CRT-Geom; CRT-Lottes | xBRZ (Zenju / Hyllian / [libretro/slang-shaders](https://github.com/libretro/slang-shaders)); CRT-Geom (cgwg, Themaister, DOLLS); CRT-Lottes (Timothy Lottes) | GPL-3.0; GPL-2.0-or-later; Public Domain | Native MSL compute ports for pixel-art vector smoothing and CRT emulation. |
| `SSimDownscaler.metal` | SSimDownscaler | [igv](https://gist.github.com/igv/36508af3ffc84410fe39761d6969be10) (via [Blinue/Magpie](https://github.com/Blinue/Magpie)) | GPL-3.0 | Native 5-pass structural-similarity downscaling port. |
| `Interpolation.metal` | Lanczos6, Jinc (EWA Lanczos), Bicubic, Sharp Bilinear, Pixellate, Nearest, Bilinear, Deband, Image Adjustment | Standard resampling filters, [libretro/slang-shaders](https://github.com/libretro/slang-shaders), and [Blinue/Magpie](https://github.com/Blinue/Magpie) | MIT / Public Domain / GPL-3.0 | Native MSL compute implementations for interpolation and utility filters. |
| `Common.metal` | Crop/Blit, 1× Demagnify, GPU Duplicate Frame Detection, BGRA↔NV12, Single-Pass TBDR Present & VRR HUD/Cursor Compositing | MetalPie Authors | GPL-3.0 | Original macOS / Apple Silicon Metal compute shaders. |
| `OpticalFlowFallback.metal` | 3-Level Hierarchical Optical Flow Frame Interpolation & Scene-Cut Guard | MetalPie Authors | GPL-3.0 | Original Metal compute fallback for macOS 14–15 or non-VideoToolbox frame generation. |

## System Frameworks

- **MetalFX Spatial Upscaling** and **VideoToolbox ML Super Resolution / Frame Interpolation (macOS 26+)** invoke Apple's native macOS system frameworks directly and do not redistribute third-party shader weights.

## Upstream Copyright Notices

- **Magpie**: Copyright (c) Blinue and contributors — Licensed under GPL-3.0.
- **Anime4K**: Copyright (c) 2019–2021 bloc97 — Licensed under MIT.
- **AMD FidelityFX FSR 1.0 & CAS**: Copyright (c) 2021 Advanced Micro Devices, Inc. — Licensed under MIT.
- **Qualcomm Snapdragon Game Super Resolution (SGSR v1)**: Copyright (c) 2023 Qualcomm Innovation Center, Inc. — Licensed under BSD-3-Clause.
- **Adaptive Sharpen**: Copyright (c) 2015–2018 bacondither — Licensed under BSD-2-Clause.
- **CuNNy**: Copyright (c) funnyplanter — Licensed under LGPL-3.0.
- **FSRCNNX & SSimDownscaler**: Copyright (c) igv — Licensed under GPL-3.0.
- **xBRZ / CRT-Geom / CRT-Lottes / FXAA 3.11**: Copyright (c) respective authors (Zenju, Hyllian, cgwg, Themaister, DOLLS, Timothy Lottes, NVIDIA) — Licensed under GPL-3.0 / GPL-2.0-or-later / Public Domain.
