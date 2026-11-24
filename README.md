# MetalPie · 金属派

> **Magpie-Class Real-Time Window Upscaling & Frame Generation — Natively Engineered for Apple Silicon & macOS.**
> **专为 Apple Silicon 与 macOS 原生打造的 Magpie 级实时窗口高清放大与流畅补帧工具。**

---

## English Overview

**MetalPie** brings the full multi-pass shader ecosystem and UX polish of Windows' **Magpie** to macOS — engineered from the ground up for **Apple Silicon**, **Metal 3/4**, **MetalFX**, **ScreenCaptureKit**, and **macOS 26+ VideoToolbox Neural Engine ML** (with full macOS 14+ compatibility).

### Why MetalPie?

| Capability | MetalPie | MetalDuck | MetalGoose |
| :--- | :---: | :---: | :---: |
| **30 Built-In Shaders (14 `.metal` Libraries) + 21 Curated Presets** | ✅ MetalFX + FSR 1.0 + FXAA + SGSR + Official 6 Anime4K Modes + CuNNy + FSRCNNX + Jinc + xBRZ + Lanczos6 + CRT-Geom/Lottes + CAS + Deband | ❌ MetalFX / Linear only | ❌ MetalFX / Linear only |
| **Apple ML Frame Generation (2×/3×/4× Hardware ANE + Metal Optical Flow)** | ✅ Zero GPU contention ANE ML + zero-alloc Metal fallback + Anti-Ghosting | ⚠️ Slow Vision Rev 1 (~17ms) + 660 allocs/s | ⚠️ Optical Flow |
| **Fullscreen + Resizable Windowed Scaling + Multi-Monitor Support** | ✅ Both + Mixed-DPI (`@2x`/`@1x`) & negative-coordinate displays + 9-Point Alignment + Pixel Cropping | ❌ Stuck 1:1 to source rect | ❌ Anamorphic stretch only |
| **Zero-Double-Cursor & Click Alignment Confinement** | ✅ Synchronized click/scroll mapping + dynamic `NSCursor.currentSystem` + FPS grab detection + live Accessibility upgrade | ❌ Double cursor | ⚠️ Hardcoded arrow + 500ms flicker |
| **Cooperative Focus Handoff & Crash Watchdog** | ✅ Clean `yieldActivation` + exact window raise, instant hide on Cmd+Tab/Close, `⌃⌥⌘⎋` Force Exit, 8s RunGuard | ❌ Overlay stuck on Cmd+Tab | ❌ Orphan overlay + `maximumWindow+1` |
| **Zero CPU Pixel Readback on Capture Hot Path** | ✅ 100% GPU zero-copy IOSurface + Static Frame Power-Saving + Wine/Emulator 1× Auto Detection | ❌ CPU pixel lock & 4fps stutter | ❌ CPU `IOSurfaceLock` + `memcmp` |
| **10-bit Wide Color & HDR / EDR (`RGBA16F`) + ProMotion VRR Direct-Scanout** | ✅ Full SDR/10-bit/HDR + VRR in-Metal Cursor & HUD compositing | ❌ 8-bit SDR only | ❌ 8-bit SDR only |
| **Interactive Real-Time Metal Before/After Preview & 30-Shader GPU Benchmark** | ✅ Live draggable curtain preview + 30-shader GPU benchmark + Bilingual EN/简体中文 | ❌ None | ❌ None |

### Built-In Presets (21 Curated Modes across 4 Scenarios) & 30 Shaders

All **14 runtime `.metal` libraries** compile on Apple Silicon and cache into a hardware- & SHA-256-keyed `MTLBinaryArchive` (`~/Library/Caches/com.metalpie.app/ShaderCache/`) so warm launches load in **< 1 ms**:

- **3D Games**:
  - `MetalFX Spatial` (Apple Silicon hardware upscaler with HDR), `FSR 1.0 (EASU + RCAS)`, `FXAA + FSR 1.0` (FXAA 3.11 anti-aliasing + FSR 1.0), `SGSR Fast Upscaler` (ultra-low power single-pass)
- **Anime & 2D (Exact 6 Official Anime4K v4.0.1 Modes + CuNNy + FSRCNNX)**:
  - **Anime4K Mode A (Recommended · Restore)** — best all-rounder for 1080p blurry/compressed anime
  - **Anime4K Mode B (Soft · Balanced Denoise)** — gentle restoration for 720p or soft-art anime
  - **Anime4K Mode C (Blu-ray · Pure Upscale)** — clean 2× neural upscaling for sharp high-bitrate sources
  - **Anime4K Mode A+A (Heavy Restore)** — two-pass restoration for low-bitrate blurry anime
  - **Anime4K Mode B+B (Soft Double Restore)** — deeper gentle restoration + denoising
  - **Anime4K Mode C+A (Blu-ray Refined)** — pure 2× upscaling + light line refinement
  - **CuNNy 2× Neural** (Magpie's crisp compact 2× CNN for anime, visual novels & 2D games)
  - **FSRCNNX 2× Neural** (6-pass `8-0-4-1` Standard / LineArt / Enhanced Detail)
  - Plus building-block passes in Advanced Custom Chain: `Anime4K Line Thinning`, `Anime4K Line Darkening`, `Anime4K Bilateral Denoise`, `Anime4K Clamp Highlights`
- **Pixel & Retro**:
  - `Integer Scale (Crisp Pixels)`, `Sharp Bilinear`, `xBRZ Pixel Art`, `CRT-Geom Retro`, `CRT-Lottes Arcade`
- **General & Video**:
  - `Lanczos6 Anti-Ringing`, `Jinc EWA Lanczos (2D Circular)`, `Bicubic Catmull-Rom + CAS`, `Apple ML Super Resolution` (macOS 26+ Neural Engine `1.5×/2×/4×`)
- **Additional Utility Shaders (30 Total)**: `Pixellate`, `Bilinear`, `Adaptive Sharpen`, `SSimDownscaler`, `Deband`, `Image Adjustment`

### Real Apple M4 Pro GPU Benchmarks (`1280×720 → 2560×1440`, 0 NaN/Inf)

| Effect | Avg GPU Time | Effective Throughput |
| :--- | :---: | :---: |
| `Anime4K Clamp Highlights` (720p) | **0.08 ms** | 12,346 FPS |
| `Image Adjustment` (720p) | **0.09 ms** | 11,529 FPS |
| `FSR 1.0 RCAS` (720p) | **0.12 ms** | 8,496 FPS |
| `FXAA 3.11` (High, 720p) | **0.14 ms** | 7,213 FPS |
| `Anime4K Line Darkening` (720p) | **0.18 ms** | 5,719 FPS |
| `Anime4K Line Thinning` (720p) | **0.28 ms** | 3,609 FPS |
| `Bilinear` / `Nearest` / `Sharp Bilinear` | **0.32–0.34 ms** | ~2,900–3,130 FPS |
| `SGSR v1` / `Bicubic` / `FSR 1.0 EASU` | **0.64–0.69 ms** | ~1,445–1,572 FPS |
| `Anime4K Bilateral Denoise` (720p) | **0.80 ms** | 1,249 FPS |
| `Lanczos6` / `Jinc 2D EWA` | **0.96–1.01 ms** | ~995–1,039 FPS |
| `CuNNy 2× Neural` (Balanced) | **1.15 ms** | 874 FPS |
| `xBRZ Freescale` | **1.20 ms** | 834 FPS |
| `Anime4K Restore` (M, 720p) / `CRT-Geom` | **1.52–1.53 ms** | ~655–659 FPS |
| `FSRCNNX 2×` / `Anime4K 2× Pure Upscale` (L) | **1.70–1.74 ms** | ~574–588 FPS |
| `MetalFX Spatial` (Hardware) | **2.83 ms** | 353 FPS |
| `Anime4K 2× Upscale + Denoise` (L) | **3.83 ms** | 261 FPS |
| `VideoToolbox ML Frame Gen` (ANE 2× 720p) | **3.8–4.1 ms** | Drives 60 → 120 FPS ProMotion |

### Multi-Monitor Support

MetalPie supports multi-monitor setups natively across mixed DPIs (`@2x` Retina + `@1x` external displays) and arbitrary display arrangements (including external displays placed above or left of the primary screen with negative CG coordinates):

- **Window's Display (Recommended):** Scales onto whichever display currently holds the target window, with proper per-monitor DPI, refresh rate, color space (`Display P3` / `sRGB`), and anchored toolbar/HUD/toast chrome.
- **Displays Crossed by Window / Span All Displays:** Available in **Profiles → Multi-Monitor Target** for ultra-wide multi-screen spans.
- **Display Inspector:** Open the **Benchmark (`显卡测速`)** tab to inspect every connected monitor's name, relative multi-monitor position, physical resolution, `@1x/@2x` DPI, refresh rate, and HDR headroom.

### Permissions & Global Shortcuts

- **Screen Recording (Required):** Needed by `ScreenCaptureKit` to read target window frames zero-copy on GPU. Grant in *System Settings → Privacy & Security → Screen & System Audio Recording*.
- **Accessibility (Required for Scaled Click Alignment — only optional for 1:1 scaling):** macOS requires Accessibility trust so MetalPie's `CGEventTap` can keep scaled mouse clicks aligned with enlarged UI buttons and keep the pointer inside the target window (preventing stray clicks on the desktop that would exit scaling). If you start non-1:1 scaling without Accessibility, MetalPie alerts you clearly and **automatically live-upgrades cursor alignment the moment you grant permission — without restarting scaling**.
- **TCC Rebuild Tip:** Ad-hoc signing (`--sign -`) changes the binary hash (`cdhash`) on each rebuild, which may require re-toggling permissions in System Settings. Pass `CODESIGN_IDENTITY` with a stable local certificate to preserve grants across rebuilds.

| Action | Default Shortcut |
| :--- | :--- |
| Fullscreen Scale / Exit | `⌥⇧A` |
| Windowed Scale / Exit | `⌥⇧Q` |
| Show / Hide Floating Toolbar | `⌥⇧D` |
| Capture Cursor-Free PNG Screenshot | `⌥⇧S` |
| **Force Exit Scaling (System Reserved, Always Active)** | **`⌃⌥⌘⎋`** |

### Building, Testing & Packaging (Pure SwiftPM — No Xcode Required)

Requires **macOS 14.0+** (Apple Silicon recommended; macOS 15+ unlocks SCK HDR, macOS 26+ unlocks VideoToolbox Neural Engine ML Frame Gen & Super Resolution) and Xcode or Apple Command Line Tools (`swift` 6.0+).

```bash
# 1. Run full unit + GPU shader + integration test suite
./scripts/test.sh

# 2. Build, generate AppIcon.icns, assemble, and code-sign dist/MetalPie.app
./scripts/build-app.sh

# 3. Optional: Sign with your local certificate so macOS permissions persist across rebuilds
CODESIGN_IDENTITY="Apple Development: Your Name" ./scripts/build-app.sh

# 4. Launch the packaged app
open dist/MetalPie.app
```

---

## 简体中文使用说明

**MetalPie（金属派）** 是面向 **Apple Silicon 与 macOS** 原生打造的 **Magpie 级实时窗口高清放大与流畅补帧应用**。无需折腾复杂参数，三步即可把小窗口游戏、番剧动画、像素复古游戏或视频一键放大到全屏或大窗口。

### 三步快速上手

1. **选中窗口**：在「开始缩放」页面选中下方任意已打开窗口（或先切到你想放大的游戏/视频窗口）。
2. **选择缩放模式**：按场景一键挑好模式（**3D 游戏** / **动漫番剧** / **像素复古** / **通用高清**）。
3. **开始放大**：点击「**全屏放大**」（或按全局快捷键 **`⌥⇧A`**）即可放大；任何时候按 **`⌃⌥⌘⎋`** 都能一键强制退出缩放。

### 核心功能一览

1. **精简直观的五大页面，告别晦涩术语**
   - **开始缩放**：三步上手引导、清晰权限状态条、场景快捷选择、带显示器标记的实时窗口列表。
   - **缩放模式**：内置 **21 种场景精选模式** 与 **30 种 Metal GPU 画质算法**，自带 **原画 / 放大后** 实时拖动对比预览；内置预设只展示最常用的「画质微调」，完整的自定义多步效果链折叠在进阶区，新手也能轻松上手。
   - **配置文件**：支持全局默认配置与按应用自动匹配的专属规则（全屏/窗口、多显示器目标、画面对齐、去黑边裁切、自动放大、3D 游戏防误触模式）。
   - **设置**：常用快捷键、鼠标对齐与限位、流畅补帧、界面语言（跟随系统 / 简体中文 / English）与截图设置在首页一目了然；HDR/10-bit、高刷 ProMotion VRR 直出、Wine/模拟器低清自动还原与静止省电等进阶选项收纳在「高级设置」中。
   - **显卡测速**：查看本机 Apple 芯片加速能力、所有外接显示器分辨率/DPI/刷新率/多屏位置，并支持 **一键 30 种算法显卡实测** 与运行日志导出。
2. **完整的 Anime4K 官方六大模式 + Magpie 招牌画质算法**
   - **动漫番剧**：内置完整的官方 **Anime4K Mode A / Mode B / Mode C / Mode A+A / Mode B+B / Mode C+A** 六大模式（只需选「画质档位」与「抑制白边」，零复杂调参），以及广受好评的 **CuNNy 2× 轻量神经超分** 与 **FSRCNNX 2×**。
   - **3D 游戏**：**MetalFX 硬件超分（支持 HDR）**、**FSR 1.0 超分锐化**、**FXAA 抗锯齿 + FSR 1.0**、**SGSR 低功耗快速超分**。
   - **像素复古与通用高清**：**整数倍原味像素**、**锐利双线性（全屏防闪烁）**、**xBRZ 矢量像素平滑**、**CRT-Geom / CRT-Lottes 显像管**、**Lanczos6 抗振铃**、**Jinc 圆形滤波**、**双三次 + CAS** 与 **Apple 神经引擎超分（macOS 26+）**。
3. **流畅补帧（2× / 3× / 4×）**
   - macOS 26+ 自动调用 Apple 芯片硬件神经引擎补帧，低占用将 30/60 帧提升至高刷流畅观感；旧版系统自动无缝使用 Metal 光流补帧并具备防鬼影保护。
4. **多显示器支持与精准鼠标点击对齐**
   - 完整兼容内置 Retina 与各类外接显示器（支持混合 `@2x`/`@1x` DPI 及上方/左侧等任意多屏排列），默认自动在「**窗口所在显示器**」上放大。
   - **关于权限说明**：
     - **屏幕录制（必需）**：用于实时读取目标窗口画面。
     - **辅助功能（缩放后鼠标精准点击必需，仅 1:1 缩放可不开）**：开启后，放大画面时鼠标点击按钮指哪打哪、并锁定在画面内防止误点桌面退出；如果在缩放过程中才去系统设置开启，MetalPie 会自动完成鼠标对齐，无需重启缩放。

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

- **`Sources/MetalPieCore`**: Pure Swift 6 domain models (`AppConfig`, `Profile`, `ScalingMode`, `ScenarioTag`, `EffectCatalog`), `ScreenGeometry` (CG Y-down ↔ Cocoa Y-up), `ScalingLayoutCalculator`, `ConfigStore`, `ScreenshotFilenameTemplate`, `PipelineLog`.
- **`Sources/MetalPieShaders`**: Runtime MSL compiler + `MTLBinaryArchive` cache (`ShaderLibraryManager`), zero-alloc `TexturePool`, `MetalFXEffect`, `VideoToolboxMLProcessor` (ANE ML SR + Frame Gen + Metal Optical Flow), `EffectChainRenderer`, and 14 `.metal` shader libraries (30 built-in effects).
- **`Sources/MetalPieCapture`**: `PermissionsManager`, `WindowEnumerator`, zero-copy `ScreenCaptureEngine`, `OverlayWindowController`, and dedicated-thread `RenderLoopController`.
- **`Sources/MetalPieInput`**: `PointerMapping`, `CursorOverlayController`, Carbon `GlobalHotkeyManager`, `WindowLifecycleWatcher`, `AutoScaleController`, and `RunGuardWatchdog`.
- **`Sources/MetalPieApp`**: Native macOS SwiftUI + AppKit application (5 streamlined tabs), `AppCoordinator`, bilingual `L10n`, floating chrome panels (`OverlayToolbarPanel`, `ProfilerHUDPanel`, `ToastOverlayPanel`), live GPU split preview, and 30-shader benchmark UI.

---

*MetalPie is built with Swift 6, SwiftUI, AppKit, Metal, MetalFX, ScreenCaptureKit, and VideoToolbox.*
