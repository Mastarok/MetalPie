import Testing
import MetalPieCore
import MetalPieShaders

@Suite("MetalPieShaders Bootstrap")
struct MetalPieShadersBootstrapTests {
    @Test("Shaders resource directory is bundled via .copy")
    func shadersResourceDirectoryExists() {
        #expect(MetalPieShadersBundle.shadersDirectoryURL != nil)
    }
}
