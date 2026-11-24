# MetalPie · 金属派

> **Magpie-Class Real-Time Window Upscaling & Frame Generation — Natively Engineered for Apple Silicon & macOS.**
> **专为 Apple Silicon 与 macOS 原生打造的 Magpie 级实时窗口超分辨率与帧生成工具。**

---

## English Overview

**MetalPie** brings the full multi-pass shader ecosystem and UX polish of Windows' **Magpie** to macOS — engineered from the ground up for **Apple Silicon**, **Metal 3/4**, **MetalFX**, **ScreenCaptureKit**, and **macOS 26+ VideoToolbox Neural Engine ML** (with full macOS 14+ compatibility).

### Why MetalPie? (Surpassing Magpie + MetalDuck + MetalGoose on macOS)

| Capability | MetalPie | MetalDuck | MetalGoose |
| :--- | :---: | :---: | :---: |
| **Multi-Pass Composable Effect Chain (22 Built-in Shaders + 12 Presets)** | ✅ MetalFX + FSR 1.0 + SGSR + Anime4K + FSRCNNX + xBRZ + Lanczos6 + CRT + CAS + Deband | ❌ MetalFX / Linear only | ❌ MetalFX / Linear only |
| **Apple ML Frame Generation (2×/3×/4× VideoToolbox ANE + Metal Optical Flow)** | ✅ Zero GPU contention ANE ML + zero-alloc Metal fallback + Artifact Guard | ⚠️ Slow Vision Rev 1 (~17ms) + 660 allocs/s | ⚠️ Optical Flow |
| **Fullscreen + Resizable Windowed Scaling + Live Toggle** | ✅ Both + 9-Point Alignment + Fit/Fill/Stretch/IntegerFit + Pixel Cropping | ❌ Stuck 1:1 to source rect | ❌ Anamorphic stretch only |
| **Zero-Double-Cursor & Zero-Delta-Drift Confinement** | ✅ Fencepost `(N-1)` math + dynamic `NSCursor.currentSystem` + FPS grab detection | ❌ Double cursor | ⚠️ Hardcoded arrow + 500ms flicker |
| **Safe Focus / Minimize / Close Lifecycle & Crash Watchdog** | ✅ Instant hide on Cmd+Tab/Close, Magpie Auto-Reposition Wait, `⌃⌥⌘⎋` Panic Stop, 8s RunGuard | ❌ Overlay stuck on Cmd+Tab | ❌ Orphan overlay + `maximumWindow+1` |
| **Zero CPU Pixel Readback on Capture Hot Path** | ✅ 100% GPU zero-copy IOSurface + GPU Duplicate Frame Detection + 1× Non-Retina Wine probe | ❌ CPU pixel lock & 4fps stutter | ❌ CPU `IOSurfaceLock` + `memcmp` |
| **10-bit Wide Color & HDR / EDR (`RGBA16F`) + ProMotion VRR Direct-Scanout** | ✅ Full SDR/10-bit/HDR + VRR in-Metal Cursor & HUD compositing | ❌ 8-bit SDR only | ❌ 8-bit SDR only |
| **Interactive Real-Time Metal Before/After Preview & Built-in GPU Benchmark** | ✅ Live draggable curtain preview + 22-shader real GPU benchmark + Bilingual EN/简体中文 | ❌ None | ❌ None |
| **Accessibility Permission Requirement** | ✅ **Strictly Optional** (1:1 scaling & Carbon hotkeys need zero AX) | ❌ Blindly prompts on launch | ❌ Hard gate |

### Built-In Shader Catalog (22 Effects across 10 Runtime MSL Libraries)

All shaders compile on Apple Silicon at runtime and serialize into a hardware- and SHA-256-keyed `MTLBinaryArchive` (`~/Library/Caches/com.metalpie.app/ShaderCache/`) so repeat launches load pipelines in **< 1 ms**:

- **Apple Hardware / ML**: `MetalFX Spatial` (SDR/HDR), `Apple ML Super Resolution` (`VTLowLatencySuperResolutionScaler` 1.5×/2×/4× on macOS 26+)
- **Super Resolution**: `FSR 1.0 EASU` (12-tap anisotropic Lanczos2), `SGSR v1` (Snapdragon single-pass fast upscaler)
- **Anime & Neural CNNs**: `Anime4K Restore` (4-pass CReLU `RGBA16F`), `Anime4K Upscale & Denoise` (2× CNN + Bilateral Mode + Line Thinning), `FSRCNNX 2×` (6-pass `8-0-4-1` Standard & LineArt)
- **Pixel Art & Retro CRT**: `xBRZ Freescale` (2-pass YCbCr), `Sharp Bilinear`, `Pixellate` (area integration), `Nearest Neighbor` (Integer Fit), `CRT-Geom`, `CRT-Lottes`
- **Interpolation & Downscaling**: `Lanczos6 (Anti-Ringing)`, `Bicubic (Mitchell-Netravali / Catmull-Rom)`, `Bilinear`, `SSimDownscaler` (5-pass perceptual downscaler)
- **Sharpening & Utility**: `FSR 1.0 RCAS` (with fixed `max(max3(...))` FP16 math), `CAS (Contrast Adaptive Sharpen)`, `Adaptive Sharpen`, `Deband`, `Image Adjustment`

### Real Apple M4 Pro GPU Benchmarks (`1280×720 → 2560×1440`, 0 NaN/Inf)

| Effect | Avg GPU Time | Effective Throughput |
| :--- | :---: | :---: |
| `Image Adjustment` (720p) | **0.09 ms** | 11,529 FPS |
| `FSR 1.0 RCAS` (720p) | **0.12 ms** | 8,496 FPS |
| `CAS` (720p) | **0.14 ms** | 7,026 FPS |
| `Bilinear` / `Nearest` / `Sharp Bilinear` | **0.32–0.34 ms** | ~2,900–3,130 FPS |
| `Adaptive Sharpen` (720p) | **0.36 ms** | 2,761 FPS |
| `SGSR v1` | **0.64 ms** | 1,572 FPS |
| `Bicubic (Catmull-Rom)` | **0.65 ms** | 1,533 FPS |
| `FSR 1.0 EASU` | **0.69 ms** | 1,445 FPS |
| `Lanczos6 (Anti-Ringing)` | **0.96 ms** | 1,039 FPS |
| `xBRZ Freescale` | **1.20 ms** | 834 FPS |
| `Anime4K Upscale & Denoise` (2× CNN) | **1.39 ms** | 720 FPS |
| `CRT-Geom` | **1.52 ms** | 659 FPS |
| `FSRCNNX 2×` (6-pass CNN) | **1.67 ms** | 599 FPS |
| `MetalFX Spatial` (Hardware) | **2.83 ms** | 353 FPS |
| `Apple ML Super Resolution` (ANE 1.5× → 1080p) | **3.74 ms** | 268 FPS |
| `VideoToolbox ML Frame Gen` (ANE 2× 720p) | **3.8–4.1 ms** | Drives 60 → 120 FPS ProMotion |

### Building, Testing & Packaging (Pure SwiftPM — No Xcode Required)

Requires **macOS 14.0+** (Apple Silicon recommended; macOS 15+ unlocks SCK HDR, macOS 26+ unlocks VideoToolbox Neural Engine ML Frame Gen & Super Resolution) and Xcode or Apple Command Line Tools (`swift` 6.0+).

```bash
# 1. Run full unit + GPU shader + integration test suite
./scripts/test.sh

# 2. Build, generate AppIcon.icns, assemble, and code-sign dist/MetalPie.app
./scripts/build-app.sh

# 3. Optional: Sign with your local certificate so macOS TCC permissions persist across rebuilds
CODESIGN_IDENTITY="Apple Development: Your Name" ./scripts/build-app.sh

# 4. Launch the packaged app
open dist/MetalPie.app
```

> **Note for Command Line Tools users:** `scripts/swiftpm-env.sh` automatically works around CLT `PackageDescription` private interface mismatches and sets `SDKROOT` when building without full Xcode.

### Permissions & Global Shortcuts

- **Screen Recording (Required):** Needed by `ScreenCaptureKit` to capture target windows zero-copy on GPU. Grant in *System Settings → Privacy & Security → Screen & System Audio Recording*.
- **Accessibility (Optional):** Only needed for scaled cursor confinement (`CGEventTap`) and enhanced modal detection in Auto-Scale. **1:1 scaling and all global hotkeys work without Accessibility.**
- **TCC Rebuild Tip:** Ad-hoc signing (`--sign -`) changes the binary hash (`cdhash`) on each rebuild, which may require re-toggling Screen Recording in System Settings. Pass `CODESIGN_IDENTITY` with a stable local certificate to preserve grants across rebuilds.

| Action | Default Shortcut |
| :--- | :--- |
| Toggle Fullscreen Scaling | `⌥⇧A` |
| Toggle Windowed Scaling | `⌥⇧Q` |
| Toggle Floating Toolbar | `⌥⇧D` |
| Capture Cursor-Free PNG Screenshot | `⌥⇧S` |
| **Emergency Panic Stop (Reserved, always active)** | **`⌃⌥⌘⎋`** |

---

## 简体中文说明

**MetalPie（金属派）** 是面向 **Apple Silicon 与 macOS** 原生重构的 **Magpie 级实时窗口超分辨率与帧生成应用**，结合了 Magpie 的多通道着色器生态与 macOS 原生 **Metal / MetalFX / ScreenCaptureKit / VideoToolbox 神经网络引擎（ANE）** 的极致性能。

### 核心特性一览

1. **Magpie 级多通道着色器管线（22 个内置着色器 + 12 个精选预设）**
   - 内置 **MetalFX 空间超分（支持 HDR/EDR）**、**Apple ML 神经网络超分（macOS 26+）**、**AMD FSR 1.0（EASU + 修复版 RCAS）**、**SGSR v1**、**Anime4K 线条修复与 2× 降噪超分**、**FSRCNNX 2×**、**xBRZ 像素矢量平滑**、**锐利双线性 / 整数倍缩放**、**CRT-Geom / CRT-Lottes 复古显像管**、**Lanczos6 抗振铃**、**双三次插值**、**SSIM 降采样**、**CAS / 自适应锐化**、**去色带（Deband）** 与 **色彩调节**。
   - 支持自由串联任意通道、调整顺序与实时参数，并自带 **实时 Metal GPU 左右拖拉对比预览** 与 **一键 22 着色器真实 GPU 基准测试**。
2. **Apple Silicon 神经引擎帧生成（2× / 3× / 4×）**
   - macOS 26+ 自动调用 `VTLowLatencyFrameInterpolationConfiguration` 在神经引擎上执行低延迟 AI 插帧（不抢占 GPU 算力），轻松将 60 FPS 提升至 **120 FPS ProMotion**；旧版系统或 >1080p 分辨率自动无缝回退至零分配 **Metal 计算光流**，并内置 **Artifact Guard** 场景切换防伪影保护。
3. **全屏缩放 + 可调节窗口缩放 + 倒计时启动 + 自动缩放**
   - 支持单屏与多显示器（所在屏 / 相交屏 / 全部屏幕）、等比适应（Fit）/ 填充（Fill）/ 拉伸 / 整数倍缩放、**九宫格对齐**、**源画面像素裁切（64px 安全保护）**、**1–5 秒倒计时启动** 与基于应用配置的 **自动缩放（含系统黑名单、弹窗豁免与手动停止防重触锁）**。
4. **零双光标、零漂移限位与全生命周期安全防护**
   - 采用 `(N-1)` 精确栅栏坐标映射、零增量漂移边界限制、动态 `NSCursor.currentSystem` 同步与 FPS 游戏鼠标锁定识别。
   - **Cmd+Tab 切窗立即隐藏覆盖层并恢复光标**、目标窗口关闭立即清理零残留、最小化自动进入等待恢复状态，配合 **RunGuard 8 秒主线程卡死熔断看门狗** 与始终生效的 **`⌃⌥⌘⎋` 紧急熔断快捷键**，绝不卡死桌面或丢失光标。
5. **10-bit / HDR / ProMotion VRR 直扫与 Wine/CrossOver 优化**
   - 完整支持 8-bit BGRA / 10-bit RGB10A2 / 16-bit 浮点 HDR/EDR，内置 **ProMotion VRR 可变刷新率直扫模式**（光标与性能 HUD 直接在 Metal 通道内合成，零 WindowServer 悬浮子窗）以及面向 Wine/CrossOver 游戏的 **1× 非 Retina GPU 自动检测还原（节省 4× 像素算力）**。
6. **原生 macOS 界面与即时中英双语切换**
   - 采用原生 SwiftUI `NavigationSplitView` + 菜单栏常驻托盘 + 顶部悬停自动隐藏工具栏 + 可拖拽贴边性能监视 HUD + 无光标高清 PNG 截图，支持在设置中一键切换 **跟随系统 / 简体中文 / English**。

### 编译、测试与打包

```bash
# 运行全部单元测试、实机 Metal 着色器测试与集成测试
./scripts/test.sh

# 编译 Release 版本、生成应用图标并打包签名 dist/MetalPie.app
./scripts/build-app.sh

# 启动应用
open dist/MetalPie.app
```

---

## Architecture / 项目模块架构

- **`Sources/MetalPieCore`**: Pure Swift 6 domain models (`AppConfig`, `Profile`, `ScalingMode`, `EffectCatalog`), `ScreenGeometry` (CG Y-down ↔ Cocoa Y-up), `ScalingLayoutCalculator`, `ConfigStore`, `ScreenshotFilenameTemplate`, `PipelineLog`.
- **`Sources/MetalPieShaders`**: Runtime MSL compiler + `MTLBinaryArchive` cache (`ShaderLibraryManager`), zero-alloc `TexturePool`, `MetalFXEffect`, `VideoToolboxMLProcessor` (ANE ML SR + Frame Gen + Metal Optical Flow), `EffectChainRenderer`, and 10 `.metal` shader libraries.
- **`Sources/MetalPieCapture`**: `PermissionsManager`, `WindowEnumerator`, zero-copy `ScreenCaptureEngine`, `OverlayWindowController`, and dedicated-thread `RenderLoopController`.
- **`Sources/MetalPieInput`**: `PointerMapping`, `CursorOverlayController`, Carbon `GlobalHotkeyManager`, `WindowLifecycleWatcher`, `AutoScaleController`, and `RunGuardWatchdog`.
- **`Sources/MetalPieApp`**: Native macOS SwiftUI + AppKit application, `AppCoordinator`, bilingual `L10n`, floating chrome panels (`OverlayToolbarPanel`, `ProfilerHUDPanel`, `ToastOverlayPanel`), live GPU split preview, and benchmark UI.

---

*MetalPie is built with Swift 6, SwiftUI, AppKit, Metal, MetalFX, ScreenCaptureKit, and VideoToolbox.*
