#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Generates MetalPie's native macOS squircle AppIcon.icns (and optional PNG via `--png <path> [size]`)
// using pure CoreGraphics + iconutil (zero Xcode / actool dependency).

var outputPath = "dist/AppIcon.icns"
var pngOutputPath: String? = nil
var pngPixelSize = 512

var argIdx = 1
while argIdx < CommandLine.arguments.count {
    let arg = CommandLine.arguments[argIdx]
    if arg == "--png", argIdx + 1 < CommandLine.arguments.count {
        pngOutputPath = CommandLine.arguments[argIdx + 1]
        argIdx += 2
        if argIdx < CommandLine.arguments.count, let sz = Int(CommandLine.arguments[argIdx]), sz >= 32, sz <= 2048 {
            pngPixelSize = sz
            argIdx += 1
        }
    } else if arg == "--png-only", argIdx + 1 < CommandLine.arguments.count {
        pngOutputPath = CommandLine.arguments[argIdx + 1]
        outputPath = ""
        argIdx += 2
        if argIdx < CommandLine.arguments.count, let sz = Int(CommandLine.arguments[argIdx]), sz >= 32, sz <= 2048 {
            pngPixelSize = sz
            argIdx += 1
        }
    } else {
        outputPath = arg
        argIdx += 1
    }
}

let tempDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("MetalPieIcon-\(UUID().uuidString)", isDirectory: true)
let iconsetURL = tempDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)

if !outputPath.isEmpty {
    let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
    try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
}

defer {
    try? FileManager.default.removeItem(at: tempDir)
}

func renderIcon(size px: Int) -> CGImage {
    let s = CGFloat(px)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

    guard let ctx = CGContext(
        data: nil,
        width: px,
        height: px,
        bitsPerComponent: 8,
        bytesPerRow: px * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        fatalError("Failed to create CGContext for size \(px)")
    }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Flip to Y-down coordinates for clean geometric math
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: 1, y: -1)

    // macOS Big Sur / Sequoia / Tahoe standard squircle canvas inset (~9.8% margin for shadow & icon alignment)
    let inset = s * 0.095
    let box = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let cornerRadius = box.width * 0.225
    let squircle = CGPath(
        roundedRect: box,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )

    // 1. Ambient drop shadow beneath squircle
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.025),
        blur: s * 0.045,
        color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45)
    )
    ctx.addPath(squircle)
    ctx.setFillColor(CGColor(srgbRed: 0.06, green: 0.08, blue: 0.14, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // 2. Deep Obsidian Glass Backdrop Gradient clipped to squircle
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    let bgColors = [
        CGColor(srgbRed: 0.05, green: 0.08, blue: 0.17, alpha: 1),
        CGColor(srgbRed: 0.09, green: 0.12, blue: 0.24, alpha: 1),
        CGColor(srgbRed: 0.13, green: 0.09, blue: 0.26, alpha: 1)
    ] as CFArray
    if let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.55, 1.0]) {
        ctx.drawLinearGradient(
            bgGrad,
            start: CGPoint(x: box.minX, y: box.minY),
            end: CGPoint(x: box.maxX, y: box.maxY),
            options: []
        )
    }

    // Subtle radial Apple Silicon cyan-violet aurora glow behind the prism
    let glowColors = [
        CGColor(srgbRed: 0.10, green: 0.78, blue: 0.98, alpha: 0.34),
        CGColor(srgbRed: 0.38, green: 0.36, blue: 0.96, alpha: 0.18),
        CGColor(srgbRed: 0.08, green: 0.10, blue: 0.20, alpha: 0.0)
    ] as CFArray
    if let glow = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 0.48, 1.0]) {
        let glowCenter = CGPoint(x: box.midX, y: box.minY + box.height * 0.38)
        ctx.drawRadialGradient(
            glow,
            startCenter: glowCenter,
            startRadius: 0,
            endCenter: glowCenter,
            endRadius: box.width * 0.62,
            options: []
        )
    }

    // 3. Upscaling Pixel-to-HD Grid Motif (left lower pixels sharpening into fine vector lines on right)
    ctx.saveGState()
    let gridStep = box.width / 8.0
    ctx.setStrokeColor(CGColor(srgbRed: 0.45, green: 0.85, blue: 1.0, alpha: 0.11))
    ctx.setLineWidth(max(1.0, s * 0.0028))
    for i in 1..<8 {
        let offset = CGFloat(i) * gridStep
        ctx.move(to: CGPoint(x: box.minX + offset, y: box.minY))
        ctx.addLine(to: CGPoint(x: box.minX + offset, y: box.maxY))
        ctx.move(to: CGPoint(x: box.minX, y: box.minY + offset))
        ctx.addLine(to: CGPoint(x: box.maxX, y: box.minY + offset))
    }
    ctx.strokePath()

    // Crisp illuminated "upscaled" micro-pixels in bottom-left quadrant transitioning to sharp prism
    let cell = gridStep * 0.56
    let pixelCoords: [(CGFloat, CGFloat, CGFloat)] = [
        (0.18, 0.76, 0.25), (0.28, 0.76, 0.42), (0.18, 0.66, 0.34),
        (0.74, 0.22, 0.45), (0.82, 0.22, 0.62), (0.82, 0.30, 0.38)
    ]
    for (fx, fy, alpha) in pixelCoords {
        let rx = box.minX + box.width * fx - cell * 0.5
        let ry = box.minY + box.height * fy - cell * 0.5
        let p = CGPath(roundedRect: CGRect(x: rx, y: ry, width: cell, height: cell), cornerWidth: cell * 0.22, cornerHeight: cell * 0.22, transform: nil)
        ctx.addPath(p)
        ctx.setFillColor(CGColor(srgbRed: 0.22, green: 0.88, blue: 1.0, alpha: alpha))
        ctx.fillPath()
    }
    ctx.restoreGState()

    // 4. Layered Metallic Prism "M" Emblem (Vibrant Cyan -> Electric Blue -> Violet)
    let cx = box.midX
    let cy = box.midY + box.height * 0.02
    let mw = box.width * 0.62
    let mh = box.height * 0.50
    let strokeW = box.width * 0.115

    // Back translucent glass prism diamond behind the M
    let prism = CGMutablePath()
    prism.move(to: CGPoint(x: cx, y: box.minY + box.height * 0.14))
    prism.addLine(to: CGPoint(x: box.maxX - box.width * 0.14, y: cy))
    prism.addLine(to: CGPoint(x: cx, y: box.maxY - box.height * 0.14))
    prism.addLine(to: CGPoint(x: box.minX + box.width * 0.14, y: cy))
    prism.closeSubpath()

    ctx.saveGState()
    ctx.addPath(prism)
    ctx.setFillColor(CGColor(srgbRed: 0.30, green: 0.52, blue: 1.0, alpha: 0.13))
    ctx.fillPath()
    ctx.addPath(prism)
    ctx.setStrokeColor(CGColor(srgbRed: 0.45, green: 0.88, blue: 1.0, alpha: 0.32))
    ctx.setLineWidth(max(1.0, s * 0.006))
    ctx.strokePath()
    ctx.restoreGState()

    // Main geometric "M" path with crisp angled facets
    let leftX = cx - mw * 0.5
    let rightX = cx + mw * 0.5
    let topY = cy - mh * 0.5
    let botY = cy + mh * 0.5
    let valleyY = cy + mh * 0.12

    let mStrokePath = CGMutablePath()
    mStrokePath.move(to: CGPoint(x: leftX, y: botY))
    mStrokePath.addLine(to: CGPoint(x: leftX, y: topY))
    mStrokePath.addLine(to: CGPoint(x: cx, y: valleyY))
    mStrokePath.addLine(to: CGPoint(x: rightX, y: topY))
    mStrokePath.addLine(to: CGPoint(x: rightX, y: botY))

    let strokedM = mStrokePath.copy(
        strokingWithWidth: strokeW,
        lineCap: .round,
        lineJoin: .round,
        miterLimit: 4.0
    )

    // Glow shadow under the metallic M
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.018),
        blur: s * 0.04,
        color: CGColor(srgbRed: 0.02, green: 0.65, blue: 1.0, alpha: 0.55)
    )
    ctx.addPath(strokedM)
    ctx.setFillColor(CGColor(srgbRed: 0.16, green: 0.72, blue: 0.98, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Gradient fill inside the metallic M
    ctx.saveGState()
    ctx.addPath(strokedM)
    ctx.clip()
    let mGradColors = [
        CGColor(srgbRed: 0.30, green: 0.96, blue: 1.00, alpha: 1),
        CGColor(srgbRed: 0.24, green: 0.62, blue: 1.00, alpha: 1),
        CGColor(srgbRed: 0.58, green: 0.34, blue: 0.98, alpha: 1)
    ] as CFArray
    if let mGrad = CGGradient(colorsSpace: colorSpace, colors: mGradColors, locations: [0.0, 0.5, 1.0]) {
        ctx.drawLinearGradient(
            mGrad,
            start: CGPoint(x: leftX - strokeW, y: topY - strokeW),
            end: CGPoint(x: rightX + strokeW, y: botY + strokeW),
            options: []
        )
    }

    // Crisp metallic top specular highlight bevel across the upper half of the M
    let highlightColors = [
        CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.42),
        CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.0)
    ] as CFArray
    if let hiGrad = CGGradient(colorsSpace: colorSpace, colors: highlightColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            hiGrad,
            start: CGPoint(x: cx, y: topY - strokeW),
            end: CGPoint(x: cx, y: cy + mh * 0.1),
            options: []
        )
    }
    ctx.restoreGState()

    // Subtle crisp inner glass rim stroke on the squircle
    let innerBox = box.insetBy(dx: max(1.0, s * 0.006), dy: max(1.0, s * 0.006))
    let innerPath = CGPath(
        roundedRect: innerBox,
        cornerWidth: cornerRadius * 0.95,
        cornerHeight: cornerRadius * 0.95,
        transform: nil
    )
    ctx.addPath(innerPath)
    ctx.setStrokeColor(CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.22))
    ctx.setLineWidth(max(1.0, s * 0.009))
    ctx.strokePath()

    ctx.restoreGState()

    return ctx.makeImage()!
}

func savePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "MetalPieIconGen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG destination"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "MetalPieIconGen", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize PNG"])
    }
}

let iconSpecs: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

if let pngPath = pngOutputPath {
    let pngURL = URL(fileURLWithPath: pngPath).standardizedFileURL
    try FileManager.default.createDirectory(
        at: pngURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try savePNG(renderIcon(size: pngPixelSize), to: pngURL)
    print("Generated AppIcon PNG (\(pngPixelSize)x\(pngPixelSize)) -> \(pngURL.path)")
}

if !outputPath.isEmpty {
    let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
    for spec in iconSpecs {
        let img = renderIcon(size: spec.pixels)
        try savePNG(img, to: iconsetURL.appendingPathComponent(spec.name))
    }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    proc.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
    try proc.run()
    proc.waitUntilExit()

    guard proc.terminationStatus == 0 else {
        fputs("error: iconutil failed with exit status \(proc.terminationStatus)\n", stderr)
        exit(proc.terminationStatus)
    }

    print("Generated AppIcon.icns -> \(outputURL.path)")
}
