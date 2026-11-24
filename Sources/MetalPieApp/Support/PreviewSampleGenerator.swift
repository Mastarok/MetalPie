import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Metal
import MetalPieCore
import UniformTypeIdentifiers

/// Built-in procedural test scenes for the real-time Metal Before/After Effect Chain Preview.
public enum PreviewSampleScene: String, CaseIterable, Identifiable, Sendable {
    case pixelArtAnime
    case textAndEdges
    case gradientDeband

    public var id: String { rawValue }

    public func title(_ l10n: L10n) -> String {
        switch self {
        case .pixelArtAnime:
            return l10n.tr("Pixel Art & Anime Lines", "像素画与动漫线条")
        case .textAndEdges:
            return l10n.tr("Sharp Text & Diagonals", "清晰文字与斜线边缘")
        case .gradientDeband:
            return l10n.tr("Dark Gradients & Deband", "暗部渐变与去色带")
        }
    }
}

/// Generates rich, crisp procedural test images (and GPU/PNG conversion helpers) for live shader previews.
public enum PreviewSampleGenerator {
    @MainActor private static var cache: [PreviewSampleScene: CGImage] = [:]

    @MainActor
    public static func sampleImage(for scene: PreviewSampleScene) -> CGImage {
        if let existing = cache[scene] {
            return existing
        }
        let generated = renderScene(scene, width: 480, height: 270)
        cache[scene] = generated
        return generated
    }

    /// Loads any user-supplied PNG/JPG/TIFF/HEIC image and normalizes to a compact preview resolution if huge.
    public static func loadUserImage(from url: URL, maxDimension: Int = 960) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        let maxSide = max(full.width, full.height)
        guard maxSide > maxDimension else { return full }

        let scale = Double(maxDimension) / Double(maxSide)
        let targetW = max(64, Int((Double(full.width) * scale).rounded()))
        let targetH = max(64, Int((Double(full.height) * scale).rounded()))
        return resizeCGImage(full, width: targetW, height: targetH, interpolation: .high) ?? full
    }

    /// Encodes a `CGImage` to lossless PNG `Data`.
    public static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw EngineError.screenshotExportFailed("Failed to initialize PNG encoder.")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw EngineError.screenshotExportFailed("Failed to finalize PNG screenshot.")
        }
        return data as Data
    }

    /// Uploads a `CGImage` into a `.bgra8Unorm` Metal texture (used for VRR GPU cursor and HUD compositing).
    public static func makeMetalTexture(from image: CGImage, device: any MTLDevice) -> (any MTLTexture)? {
        let w = max(1, image.width)
        let h = max(1, image.height)
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: &pixels,
                  width: w,
                  height: h,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else {
            return nil
        }

        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Un-premultiply RGB by alpha because RenderLoopController's sprite pipeline blends
        // with straight-alpha (.sourceAlpha / .oneMinusSourceAlpha), preventing dark fringes.
        let pixelCount = w * h
        for i in 0..<pixelCount {
            let base = i * 4
            let a = Int(pixels[base + 3])
            if a > 0 && a < 255 {
                pixels[base + 0] = UInt8(min(255, (Int(pixels[base + 0]) * 255 + (a / 2)) / a))
                pixels[base + 1] = UInt8(min(255, (Int(pixels[base + 1]) * 255 + (a / 2)) / a))
                pixels[base + 2] = UInt8(min(255, (Int(pixels[base + 2]) * 255 + (a / 2)) / a))
            }
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: w,
            height: h,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(
            region: MTLRegionMake2D(0, 0, w, h),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: bytesPerRow
        )
        return tex
    }

    /// Resizes a `CGImage` with specified CoreGraphics interpolation (`.none` for crisp original comparison).
    public static func resizeCGImage(
        _ image: CGImage,
        width: Int,
        height: Int,
        interpolation: CGInterpolationQuality
    ) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        ctx.interpolationQuality = interpolation
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    // MARK: - Procedural Scene Rendering

    private static func renderScene(_ scene: PreviewSampleScene, width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            fatalError("Failed to create CGContext for PreviewSampleGenerator.")
        }

        // Use Y-down drawing coordinates for clean pixel-exact layout.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        switch scene {
        case .pixelArtAnime:
            drawPixelArtAndAnimeScene(in: ctx, width: width, height: height)
        case .textAndEdges:
            drawTextAndEdgesScene(in: ctx, width: width, height: height)
        case .gradientDeband:
            drawGradientDebandScene(in: ctx, width: width, height: height)
        }

        return ctx.makeImage()!
    }

    private static func drawPixelArtAndAnimeScene(in ctx: CGContext, width: Int, height: Int) {
        let w = CGFloat(width)
        let h = CGFloat(height)

        // Left half: Retro 16-bit Pixel Art World (sky, clouds, mountains, hero sprite, checkerboard stone)
        let leftW = w * 0.5
        ctx.setFillColor(CGColor(srgbRed: 0.09, green: 0.14, blue: 0.28, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: leftW, height: h))

        // Pixelated sunset gradient stripes (8px blocks)
        let skyColors: [(CGFloat, CGFloat, CGFloat)] = [
            (0.08, 0.11, 0.24),
            (0.13, 0.17, 0.36),
            (0.24, 0.22, 0.48),
            (0.45, 0.26, 0.52),
            (0.75, 0.34, 0.44),
            (0.95, 0.56, 0.32),
            (0.99, 0.78, 0.38)
        ]
        for (idx, c) in skyColors.enumerated() {
            ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fill(CGRect(x: 0, y: CGFloat(idx) * 24, width: leftW, height: 24))
        }

        // Pixel sun & stepped mountain silhouette
        let px: CGFloat = 6
        let sunCenter = CGPoint(x: 68, y: 74)
        for gy in -6...6 {
            for gx in -6...6 where gx * gx + gy * gy <= 34 {
                ctx.setFillColor(CGColor(srgbRed: 1.0, green: 0.94, blue: 0.62, alpha: 1))
                ctx.fill(CGRect(
                    x: sunCenter.x + CGFloat(gx) * px,
                    y: sunCenter.y + CGFloat(gy) * px,
                    width: px,
                    height: px
                ))
            }
        }

        // Diagonal stepped mountain ridge (classic xBRZ / Sharp-Bilinear / Nearest stress test)
        ctx.setFillColor(CGColor(srgbRed: 0.16, green: 0.14, blue: 0.30, alpha: 1))
        for col in 0..<Int(leftW / px) {
            let dist = abs(col - 26)
            let peakH = max(4, 18 - dist)
            let yTop = h - 72 - CGFloat(peakH) * px
            ctx.fill(CGRect(x: CGFloat(col) * px, y: yTop, width: px, height: h - 72 - yTop))
        }

        // Brick/tile pixel floor
        for row in 0..<12 {
            for col in 0..<Int(leftW / px) {
                let even = (row + col) % 2 == 0
                if row == 0 {
                    ctx.setFillColor(CGColor(srgbRed: 0.24, green: 0.80, blue: 0.42, alpha: 1))
                } else if row == 1 {
                    ctx.setFillColor(CGColor(srgbRed: 0.16, green: 0.60, blue: 0.32, alpha: 1))
                } else {
                    ctx.setFillColor(
                        even
                            ? CGColor(srgbRed: 0.34, green: 0.22, blue: 0.18, alpha: 1)
                            : CGColor(srgbRed: 0.26, green: 0.17, blue: 0.14, alpha: 1)
                    )
                }
                ctx.fill(CGRect(x: CGFloat(col) * px, y: h - 72 + CGFloat(row) * px, width: px, height: px))
            }
        }

        // 12×12 crisp pixel-art crystal / shield sprite
        let sprite: [String] = [
            "....KKKK....",
            "...KCCCCK...",
            "..KCCWWCCK..",
            ".KCCWWWWCCK.",
            "KCCWWBBWWCCK",
            "KCCWBBBBWCCK",
            "KCCWBBBBWCCK",
            "KCCWWBBWWCCK",
            ".KCCWWWWCCK.",
            "..KCCDDCCK..",
            "...KDDDDK...",
            "....KKKK...."
        ]
        let spOriginX: CGFloat = 114
        let spOriginY: CGFloat = 116
        for (ry, row) in sprite.enumerated() {
            for (rx, ch) in row.enumerated() {
                let color: CGColor?
                switch ch {
                case "K": color = CGColor(srgbRed: 0.05, green: 0.06, blue: 0.12, alpha: 1)
                case "C": color = CGColor(srgbRed: 0.18, green: 0.86, blue: 0.98, alpha: 1)
                case "W": color = CGColor(srgbRed: 0.92, green: 0.98, blue: 1.0, alpha: 1)
                case "B": color = CGColor(srgbRed: 0.32, green: 0.44, blue: 0.98, alpha: 1)
                case "D": color = CGColor(srgbRed: 0.10, green: 0.50, blue: 0.78, alpha: 1)
                default: color = nil
                }
                if let color {
                    ctx.setFillColor(color)
                    ctx.fill(CGRect(x: spOriginX + CGFloat(rx) * px, y: spOriginY + CGFloat(ry) * px, width: px, height: px))
                }
            }
        }

        // Right half: Crisp Cel-Shaded Anime & Fine Linework Zone (Anime4K / FSRCNNX / FSR / MetalFX test)
        let rightX = leftW
        ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.97, blue: 1.0, alpha: 1))
        ctx.fill(CGRect(x: rightX, y: 0, width: leftW, height: h))

        // Cel-shaded sky & curved horizon band
        ctx.saveGState()
        ctx.clip(to: CGRect(x: rightX, y: 0, width: leftW, height: h))

        let bgColors = [
            CGColor(srgbRed: 0.16, green: 0.42, blue: 0.88, alpha: 1),
            CGColor(srgbRed: 0.44, green: 0.78, blue: 0.98, alpha: 1)
        ] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: bgColors, locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: rightX, y: 0), end: CGPoint(x: rightX, y: h * 0.72), options: [])
        }

        // Cel-shaded diagonal geometric crystal ribbons with sharp dark anime outlines
        ctx.setLineWidth(1.6)
        ctx.setLineJoin(.miter)

        let poly1 = CGMutablePath()
        poly1.move(to: CGPoint(x: rightX + 26, y: 215))
        poly1.addLine(to: CGPoint(x: rightX + 94, y: 42))
        poly1.addLine(to: CGPoint(x: rightX + 162, y: 122))
        poly1.addLine(to: CGPoint(x: rightX + 114, y: 230))
        poly1.closeSubpath()
        ctx.addPath(poly1)
        ctx.setFillColor(CGColor(srgbRed: 0.99, green: 0.38, blue: 0.55, alpha: 1))
        ctx.fillPath()
        ctx.addPath(poly1)
        ctx.setStrokeColor(CGColor(srgbRed: 0.08, green: 0.08, blue: 0.15, alpha: 1))
        ctx.strokePath()

        // Inner cel highlight
        let poly2 = CGMutablePath()
        poly2.move(to: CGPoint(x: rightX + 94, y: 42))
        poly2.addLine(to: CGPoint(x: rightX + 128, y: 84))
        poly2.addLine(to: CGPoint(x: rightX + 76, y: 162))
        poly2.addLine(to: CGPoint(x: rightX + 58, y: 132))
        poly2.closeSubpath()
        ctx.addPath(poly2)
        ctx.setFillColor(CGColor(srgbRed: 1.0, green: 0.80, blue: 0.86, alpha: 0.9))
        ctx.fillPath()

        // Crisp concentric anime hair/lens arcs
        ctx.setStrokeColor(CGColor(srgbRed: 0.07, green: 0.09, blue: 0.18, alpha: 1))
        for i in 0..<7 {
            let r = CGFloat(24 + i * 11)
            ctx.setLineWidth(i % 2 == 0 ? 1.5 : 1.0)
            ctx.addArc(
                center: CGPoint(x: rightX + 188, y: 174),
                radius: r,
                startAngle: .pi * 1.05,
                endAngle: .pi * 1.92,
                clockwise: false
            )
            ctx.strokePath()
        }

        // Sharp specular starburst lines
        ctx.setStrokeColor(CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.95))
        ctx.setLineWidth(1.25)
        let starCenter = CGPoint(x: rightX + 188, y: 64)
        for k in 0..<12 {
            let angle = Double(k) * (.pi / 6.0)
            let len: Double = (k % 3 == 0) ? 34.0 : 18.0
            ctx.move(to: starCenter)
            ctx.addLine(to: CGPoint(
                x: starCenter.x + CGFloat(cos(angle) * len),
                y: starCenter.y + CGFloat(sin(angle) * len)
            ))
            ctx.strokePath()
        }

        // Thin vertical separator
        ctx.restoreGState()
        ctx.setFillColor(CGColor(srgbRed: 0.04, green: 0.05, blue: 0.09, alpha: 1))
        ctx.fill(CGRect(x: leftW - 1, y: 0, width: 2, height: h))
    }

    private static func drawTextAndEdgesScene(in ctx: CGContext, width: Int, height: Int) {
        let w = CGFloat(width)
        let h = CGFloat(height)

        ctx.setFillColor(CGColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Subtle grid
        ctx.setStrokeColor(CGColor(srgbRed: 0.18, green: 0.20, blue: 0.26, alpha: 1))
        ctx.setLineWidth(1)
        stride(from: CGFloat(0), to: w, by: 24).forEach { x in
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: h))
        }
        stride(from: CGFloat(0), to: h, by: 24).forEach { y in
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: w, y: y))
        }
        ctx.strokePath()

        // High-contrast radial edge fan (top-right)
        let fanCenter = CGPoint(x: w - 92, y: 84)
        for i in 0..<24 {
            let angle = Double(i) * (.pi * 2.0 / 24.0)
            ctx.setStrokeColor(
                i % 2 == 0
                    ? CGColor(srgbRed: 0.32, green: 0.84, blue: 1.0, alpha: 1)
                    : CGColor(srgbRed: 0.98, green: 0.98, blue: 1.0, alpha: 0.9)
            )
            ctx.setLineWidth(i % 3 == 0 ? 1.8 : 1.0)
            ctx.move(to: CGPoint(x: fanCenter.x + CGFloat(cos(angle) * 10), y: fanCenter.y + CGFloat(sin(angle) * 10)))
            ctx.addLine(to: CGPoint(x: fanCenter.x + CGFloat(cos(angle) * 66), y: fanCenter.y + CGFloat(sin(angle) * 66)))
            ctx.strokePath()
        }

        // Fine 1px / 2px / 4px resolution checker swatches (bottom-right)
        let swatchY = h - 84
        for (idx, cell) in [2, 4, 8].enumerated() {
            let startX = w - 186 + CGFloat(idx * 58)
            let size = 48
            for y in stride(from: 0, to: size, by: cell) {
                for x in stride(from: 0, to: size, by: cell) {
                    let isWhite = ((x / cell) + (y / cell)) % 2 == 0
                    ctx.setFillColor(isWhite ? CGColor(gray: 0.95, alpha: 1) : CGColor(gray: 0.08, alpha: 1))
                    ctx.fill(CGRect(x: startX + CGFloat(x), y: swatchY + CGFloat(y), width: CGFloat(cell), height: CGFloat(cell)))
                }
            }
        }

        // Crisp multi-scale UI typography drawn via NSGraphicsContext
        ctx.saveGState()
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        NSString(string: "MetalPie 4K Ultra").draw(at: CGPoint(x: 20, y: 20), withAttributes: titleAttrs)

        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor(calibratedRed: 0.42, green: 0.86, blue: 1.0, alpha: 1)
        ]
        NSString(string: "金属派 Apple Silicon 超分与帧生成").draw(at: CGPoint(x: 20, y: 52), withAttributes: subAttrs)

        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(white: 0.88, alpha: 1)
        ]
        NSString(string: "720p -> 1440p • 120.0 FPS • 0.69 ms").draw(at: CGPoint(x: 20, y: 84), withAttributes: bodyAttrs)

        let smallAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: NSColor(white: 0.75, alpha: 1)
        ]
        NSString(string: "The quick brown fox jumps over 1234567890.")
            .draw(at: CGPoint(x: 20, y: 110), withAttributes: smallAttrs)
        NSString(string: "抗振铃文字锐度测试 • Sharp HUD & UI Typography")
            .draw(at: CGPoint(x: 20, y: 128), withAttributes: smallAttrs)

        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()

        // Diagonal contrast bars (bottom-left)
        let colors: [CGColor] = [
            CGColor(srgbRed: 0.98, green: 0.28, blue: 0.36, alpha: 1),
            CGColor(srgbRed: 0.99, green: 0.72, blue: 0.16, alpha: 1),
            CGColor(srgbRed: 0.22, green: 0.84, blue: 0.46, alpha: 1),
            CGColor(srgbRed: 0.18, green: 0.68, blue: 0.99, alpha: 1),
            CGColor(srgbRed: 0.68, green: 0.40, blue: 0.98, alpha: 1)
        ]
        for (i, col) in colors.enumerated() {
            let x0 = CGFloat(22 + i * 44)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x0, y: h - 22))
            p.addLine(to: CGPoint(x: x0 + 26, y: h - 22))
            p.addLine(to: CGPoint(x: x0 + 48, y: h - 102))
            p.addLine(to: CGPoint(x: x0 + 22, y: h - 102))
            p.closeSubpath()
            ctx.addPath(p)
            ctx.setFillColor(col)
            ctx.fillPath()
        }
    }

    private static func drawGradientDebandScene(in ctx: CGContext, width: Int, height: Int) {
        let w = CGFloat(width)
        let h = CGFloat(height)

        // Intentionally 5-bit quantized dark twilight bands (makes Deband / ImageAdjustment / CRT super clear!)
        let bandCount = 24
        for i in 0..<bandCount {
            let t = CGFloat(i) / CGFloat(bandCount - 1)
            let r = 0.03 + t * 0.24
            let g = 0.04 + t * 0.14
            let b = 0.09 + t * 0.36
            ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
            let y0 = (CGFloat(i) / CGFloat(bandCount)) * h
            let bh = h / CGFloat(bandCount) + 1
            ctx.fill(CGRect(x: 0, y: y0, width: w, height: bh))
        }

        // Quantized radial moonlight halo (concentric stepped bands)
        let moonCenter = CGPoint(x: w * 0.68, y: h * 0.38)
        for ring in stride(from: 12, through: 1, by: -1) {
            let frac = 1.0 - (CGFloat(ring) / 13.0)
            let radius = CGFloat(ring) * 14.0
            ctx.setFillColor(CGColor(
                srgbRed: 0.18 + frac * 0.78,
                green: 0.24 + frac * 0.72,
                blue: 0.42 + frac * 0.56,
                alpha: 0.26
            ))
            ctx.fillEllipse(in: CGRect(
                x: moonCenter.x - radius,
                y: moonCenter.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }

        // Bright crisp moon disc
        ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.98, blue: 1.0, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: moonCenter.x - 24, y: moonCenter.y - 24, width: 48, height: 48))

        // Foreground silhouette with subtle rim edge
        let sil = CGMutablePath()
        sil.move(to: CGPoint(x: 0, y: h))
        sil.addLine(to: CGPoint(x: 0, y: h * 0.66))
        sil.addLine(to: CGPoint(x: w * 0.28, y: h * 0.54))
        sil.addLine(to: CGPoint(x: w * 0.55, y: h * 0.74))
        sil.addLine(to: CGPoint(x: w * 0.82, y: h * 0.62))
        sil.addLine(to: CGPoint(x: w, y: h * 0.70))
        sil.addLine(to: CGPoint(x: w, y: h))
        sil.closeSubpath()
        ctx.addPath(sil)
        ctx.setFillColor(CGColor(srgbRed: 0.03, green: 0.04, blue: 0.08, alpha: 1))
        ctx.fillPath()
    }
}
