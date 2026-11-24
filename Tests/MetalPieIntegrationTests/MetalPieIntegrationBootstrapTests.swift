import Testing
import MetalPieCore
import MetalPieShaders
import MetalPieCapture
import MetalPieInput

@Suite("MetalPie Integration Bootstrap")
struct MetalPieIntegrationBootstrapTests {
    @Test("All target modules link cleanly")
    func modulesLinkCleanly() {
        #expect(!MetalPieCaptureModule.moduleVersion.isEmpty)
        #expect(!MetalPieInputModule.moduleVersion.isEmpty)
        #expect(MetalPieShadersBundle.shadersDirectoryURL != nil)
    }
}
