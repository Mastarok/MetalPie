import Foundation
import MetalPieCore

/// Crash-safe resource bundle lookup for `MetalPieShaders` across `swift test`, `swift run`,
/// and packaged `.app/Contents/Resources/` bundles.
public enum MetalPieShadersBundle {
    private static let bundleName = "MetalPie_MetalPieShaders"

    public static var safeModule: Bundle {
        let candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle(for: BundleAnchor.self).resourceURL,
            Bundle(for: BundleAnchor.self).bundleURL
        ]

        for candidate in candidates {
            guard let baseURL = candidate else { continue }
            let bundleURL = baseURL.appendingPathComponent("\(bundleName).bundle")
            if let bundle = Bundle(url: bundleURL) {
                return bundle
            }
        }

        return Bundle.module
    }

    public static var shadersDirectoryURL: URL? {
        safeModule.url(forResource: "Shaders", withExtension: nil)
    }

    private final class BundleAnchor {}
}
