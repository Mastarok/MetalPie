import Foundation
import MetalPieCore
import MetalPieShaders
import MetalPieCapture
import MetalPieInput

@main
struct MetalPieBootstrapEntry {
    static func main() {
        // Placeholder entrypoint replaced by ui-engineer with the full SwiftUI + AppKit app.
        let _ = MetalPieCaptureModule.moduleVersion
        let _ = MetalPieInputModule.moduleVersion
        let _ = MetalPieShadersBundle.shadersDirectoryURL
    }
}
