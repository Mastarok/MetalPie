import Foundation

/// High-level runtime lifecycle state of an active scaling session.
public enum SessionState: String, Codable, Sendable, CaseIterable {
    case idle
    case countingDown
    case starting
    case running
    case suspended
    case waitingForWindow
    case stopping
    case error
}

/// Per-effect or per-pass GPU execution duration shown in the Profiler HUD timeline bar.
public struct PassTiming: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var gpuMilliseconds: Double
    public var colorHex: String

    public init(
        id: String? = nil,
        name: String,
        gpuMilliseconds: Double,
        colorHex: String = "#4DA3FF"
    ) {
        self.id = id ?? name
        self.name = name
        self.gpuMilliseconds = max(0, gpuMilliseconds)
        self.colorHex = colorHex
    }
}

/// Real-time performance and pipeline telemetry snapshot streamed to the HUD & Monitor UI.
public struct SessionTelemetry: Hashable, Codable, Sendable {
    public var state: SessionState
    public var targetWindowName: String
    public var backendName: String
    public var gpuName: String
    public var inputSize: PixelSize
    public var outputSize: PixelSize
    public var sourceFPS: Double
    public var outputFPS: Double
    public var presentedFPS: Double
    public var frameTimeMs: Double
    public var duplicateFramesSkipped: UInt64
    public var droppedFrames: UInt64
    public var frameGenActive: Bool
    public var frameGenMultiplier: Int
    public var hdrActive: Bool
    public var passTimings: [PassTiming]

    public init(
        state: SessionState = .idle,
        targetWindowName: String = "",
        backendName: String = "Metal",
        gpuName: String = "",
        inputSize: PixelSize = .zero,
        outputSize: PixelSize = .zero,
        sourceFPS: Double = 0,
        outputFPS: Double = 0,
        presentedFPS: Double = 0,
        frameTimeMs: Double = 0,
        duplicateFramesSkipped: UInt64 = 0,
        droppedFrames: UInt64 = 0,
        frameGenActive: Bool = false,
        frameGenMultiplier: Int = 1,
        hdrActive: Bool = false,
        passTimings: [PassTiming] = []
    ) {
        self.state = state
        self.targetWindowName = targetWindowName
        self.backendName = backendName
        self.gpuName = gpuName
        self.inputSize = inputSize
        self.outputSize = outputSize
        self.sourceFPS = max(0, sourceFPS)
        self.outputFPS = max(0, outputFPS)
        self.presentedFPS = max(0, presentedFPS)
        self.frameTimeMs = max(0, frameTimeMs)
        self.duplicateFramesSkipped = duplicateFramesSkipped
        self.droppedFrames = droppedFrames
        self.frameGenActive = frameGenActive
        self.frameGenMultiplier = max(1, frameGenMultiplier)
        self.hdrActive = hdrActive
        self.passTimings = passTimings
    }

    public static let idle = SessionTelemetry()

    public var totalGPUMilliseconds: Double {
        passTimings.reduce(0) { $0 + $1.gpuMilliseconds }
    }

    public var scaleFactorX: Double {
        guard inputSize.width > 0 else { return 0 }
        return Double(outputSize.width) / Double(inputSize.width)
    }

    public var scaleFactorY: Double {
        guard inputSize.height > 0 else { return 0 }
        return Double(outputSize.height) / Double(inputSize.height)
    }
}
