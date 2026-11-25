# MetalPie

适用于 Apple Silicon 与 macOS 的实时窗口超分与补帧工具。

[English](README.md) | 简体中文

---

## 简介

MetalPie 通过 `ScreenCaptureKit` 零拷贝采集目标窗口，在 GPU 上执行多通道 Metal / MetalFX 超分与可选插帧，并将结果以全屏或可调窗口形式叠加显示，同时保持鼠标点击、拖动与滚轮坐标与缩放画面对齐。

## 主要功能

- **超分与着色器**：内置 21 种预设模式与 30 种 GPU 效果（14 个 `.metal` 着色器库），涵盖 MetalFX Spatial、AMD FSR 1.0 (EASU + RCAS)、FXAA 3.11、SGSR、Anime4K v4.0.1 官方模式（`Mode A`、`B`、`C`、`A+A`、`B+B`、`C+A`）、CuNNy 2×、FSRCNNX 2×、xBRZ、CRT-Geom、CRT-Lottes、Jinc、Lanczos6、CAS 以及 Apple ML 超分（macOS 26+）。
- **帧生成**：支持 2× / 3× / 4× 补帧；macOS 26+ 使用 VideoToolbox ML（`VTFrameProcessor`），macOS 14–15 自动回退至 Metal 光流插帧，并内置场景切换与伪影保护。
- **全屏与窗口缩放**：支持全屏叠加（自动避开 MacBook Pro 刘海区域）与可调大小的窗口模式，提供九宫格对齐、边缘裁切和按应用匹配配置文件。
- **输入与光标对齐**：通过 `CGEventTap` 将点击、拖动和滚轮映射到缩放后的窗口坐标，同步绘制缩放光标、识别游戏鼠标锁定，并提供全局强制退出快捷键（`⌃⌥⌘⎋`）与光标异常恢复看门狗。
- **多显示器与色彩**：支持混合 DPI（`@1x` / `@2x`）与任意多屏排列、10-bit 广色域 / HDR（`RGBA16F`）、ProMotion VRR 直出模式以及无光标 PNG 截图。
- **零拷贝管线**：采集热路径直接通过 `IOSurface` → `CVMetalTextureCache` 进入 Metal，无 CPU 像素回读，支持静止帧省电及 Wine / 模拟器 1× 画面自动识别。

## 系统要求

- **macOS 14.0+**（建议使用 Apple Silicon）
- **macOS 15.0+** 支持 HDR 采集（`ScreenCaptureKit` HDR）
- **macOS 26.0+** 支持 VideoToolbox ML 帧生成与超分

## 安装

1. 从 [Releases](https://github.com/Mastarok/MetalPie/releases) 下载最新 `.dmg` 文件，将 `MetalPie.app` 拖入「应用程序」目录。
2. 当前发布包采用本地 ad-hoc 签名。首次打开若被 macOS Gatekeeper 拦截，可在终端执行：
   ```bash
   xattr -dr com.apple.quarantine /Applications/MetalPie.app
   ```
3. 在「**系统设置 → 隐私与安全性**」中授予权限：
   - **录屏与系统录音**（必需）：用于 `ScreenCaptureKit` 采集目标窗口。
   - **辅助功能**（非 1:1 缩放下鼠标对齐必需）：用于 `CGEventTap` 映射与限位鼠标输入。

## 默认快捷键

| 操作 | 快捷键 |
| :--- | :--- |
| 开启 / 退出全屏缩放 | `⌥⇧A` |
| 开启 / 退出窗口缩放 | `⌥⇧Q` |
| 显示 / 隐藏悬浮工具栏 | `⌥⇧D` |
| 无光标截图（PNG） | `⌥⇧S` |
| 强制退出缩放（始终生效） | `⌃⌥⌘⎋` |

## 内置缩放模式

- **3D 游戏**：MetalFX Spatial、FSR 1.0 (EASU + RCAS)、FXAA + FSR 1.0、SGSR
- **动漫与 2D**：Anime4K（`Mode A`、`Mode B`、`Mode C`、`Mode A+A`、`Mode B+B`、`Mode C+A`）、CuNNy 2×、FSRCNNX 2×
- **像素与复古**：整数缩放、锐利双线性、xBRZ、CRT-Geom、CRT-Lottes
- **通用与视频**：Lanczos6、Jinc (EWA Lanczos)、Bicubic + CAS、Apple ML 超分（macOS 26+）

在「缩放模式」页面中可自由编排自定义多通道效果链，并支持 JSON 导入导出。

## 从源码构建

需要 macOS 14+ 与 Swift 6.0+（Xcode 或 Command Line Tools，无需 `.xcodeproj`）。

```bash
# 运行单元测试、Metal 着色器测试与集成测试
./scripts/test.sh

# 编译并签名 dist/MetalPie.app
./scripts/build-app.sh

# 打包压缩 DMG 与 SHA-256 校验文件（dist/MetalPie-1.0.0-arm64.dmg）
./scripts/build-dmg.sh
```

若希望本地重复编译后保留系统隐私权限，可使用本地证书签名：

```bash
CODESIGN_IDENTITY="Apple Development: Your Name" ./scripts/build-dmg.sh
```

## 项目结构

- `Sources/MetalPieCore` — 配置模型（`AppConfig`、`Profile`、`ScalingMode`、`EffectCatalog`）、多显示器坐标变换、缩放布局计算与原子持久化存储。
- `Sources/MetalPieShaders` — 运行时 MSL 编译与 `MTLBinaryArchive` 缓存、纹理池、MetalFX、VideoToolbox ML 与 14 个 `.metal` 着色器库。
- `Sources/MetalPieCapture` — 权限检测、窗口与显示器枚举、`ScreenCaptureKit` 零拷贝采集、叠加窗口管理与独立线程渲染循环。
- `Sources/MetalPieInput` — 指针映射、`CGEventTap` 光标控制、全局热键、窗口生命周期监听、自动缩放与异常恢复看门狗。
- `Sources/MetalPieApp` — SwiftUI / AppKit 界面、会话协调器、悬浮工具栏 / 性能面板 / 提示窗、实时分屏预览与着色器基准测试。

## 致谢

MetalPie 的架构设计与部分着色器算法参考或受益于以下开源项目：

- [Magpie](https://github.com/Blinue/Magpie) — 窗口缩放架构、光标限位模型与着色器生态。
- [Anime4K](https://github.com/bloc97/Anime4K)、[AMD FidelityFX FSR](https://github.com/GPUOpen-Effects/FidelityFX-FSR)、[CuNNy](https://github.com/funnyplanter/CuNNy)、[FSRCNNX](https://github.com/igv/FSRCNN-TensorFlow) — 超分算法与着色器实现。
- [MetalDuck](https://github.com/Nycolazs/MetalDuck) 与 [MetalGoose](https://github.com/Stallion77RepoOfficial/MetalGoose) — macOS Metal 窗口缩放的早期参考实现。
