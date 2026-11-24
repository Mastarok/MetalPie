import Foundation
import Metal
import MetalPieCore
import os

/// Key uniquely identifying a pooled intermediate GPU texture layout.
public struct TexturePoolKey: Hashable, Sendable {
    public let width: Int
    public let height: Int
    public let pixelFormatRaw: UInt
    public let usageRaw: UInt
    public let storageModeRaw: UInt

    public init(
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat,
        usage: MTLTextureUsage,
        storageMode: MTLStorageMode
    ) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.pixelFormatRaw = pixelFormat.rawValue
        self.usageRaw = usage.rawValue
        self.storageModeRaw = storageMode.rawValue
    }

    public var pixelFormat: MTLPixelFormat {
        MTLPixelFormat(rawValue: pixelFormatRaw) ?? .bgra8Unorm
    }

    public var usage: MTLTextureUsage {
        MTLTextureUsage(rawValue: usageRaw)
    }

    public var storageMode: MTLStorageMode {
        MTLStorageMode(rawValue: storageModeRaw) ?? .private
    }
}

/// Snapshot of pool reuse metrics useful for verifying zero-allocation steady-state rendering.
public struct TexturePoolStats: Hashable, Sendable {
    public var totalAllocations: UInt64
    public var cacheHits: UInt64
    public var activeLeaseCount: Int
    public var pooledCount: Int

    public init(
        totalAllocations: UInt64 = 0,
        cacheHits: UInt64 = 0,
        activeLeaseCount: Int = 0,
        pooledCount: Int = 0
    ) {
        self.totalAllocations = totalAllocations
        self.cacheHits = cacheHits
        self.activeLeaseCount = activeLeaseCount
        self.pooledCount = pooledCount
    }
}

/// RAII lease over a pooled `MTLTexture` that automatically returns the texture to its
/// `TexturePool` when released (typically inside `MTLCommandBuffer.addCompletedHandler`).
public final class PooledTexture: @unchecked Sendable {
    public let texture: any MTLTexture
    public let key: TexturePoolKey

    private weak var pool: TexturePool?
    private let returned = OSAllocatedUnfairLock(initialState: false)

    fileprivate init(texture: any MTLTexture, key: TexturePoolKey, pool: TexturePool) {
        self.texture = texture
        self.key = key
        self.pool = pool
    }

    /// Explicitly returns this texture to its pool (safe to call multiple times).
    public func releaseNow() {
        let shouldReturn = returned.withLock { already -> Bool in
            if already { return false }
            already = true
            return true
        }
        if shouldReturn {
            pool?.recycle(texture: texture, key: key)
        }
    }

    deinit {
        releaseNow()
    }
}

/// Zero-per-frame-allocation intermediate GPU texture pool with frame-fence recycling.
///
/// Supports `.bgra8Unorm`, `.rgba16Float`, `.bgr10a2Unorm`, `.r8Unorm`, `.rg16Float`, `.rg8Unorm`,
/// and `.r32Float` with `.private` storage for MetalFX & multi-pass compute pipelines.
public final class TexturePool: @unchecked Sendable {
    public let device: any MTLDevice
    public let maxCachedTextures: Int

    private struct BucketEntry {
        var texture: any MTLTexture
        var lastUsedSequence: UInt64
    }

    private struct PoolState {
        var buckets: [TexturePoolKey: [BucketEntry]] = [:]
        var totalPooled: Int = 0
        var activeLeases: Int = 0
        var totalAllocations: UInt64 = 0
        var cacheHits: UInt64 = 0
        var sequence: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: PoolState())

    public init(device: any MTLDevice, maxCachedTextures: Int = 64) {
        self.device = device
        self.maxCachedTextures = max(8, maxCachedTextures)
    }

    /// Acquires a pooled texture matching `(width, height, pixelFormat, usage, storageMode)`.
    /// Retain the returned `PooledTexture` inside `commandBuffer.addCompletedHandler` for frame-fence recycling.
    public func acquire(
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat = .bgra8Unorm,
        usage: MTLTextureUsage = [.shaderRead, .shaderWrite, .renderTarget],
        storageMode: MTLStorageMode = .private,
        label: String? = nil
    ) throws -> PooledTexture {
        let safeW = max(1, width)
        let safeH = max(1, height)
        let key = TexturePoolKey(
            width: safeW,
            height: safeH,
            pixelFormat: pixelFormat,
            usage: usage,
            storageMode: storageMode
        )

        let existing: (any MTLTexture)? = state.withLockUnchecked { s in
            s.sequence &+= 1
            if var list = s.buckets[key], !list.isEmpty {
                let entry = list.removeLast()
                if list.isEmpty {
                    s.buckets.removeValue(forKey: key)
                } else {
                    s.buckets[key] = list
                }
                s.totalPooled -= 1
                s.activeLeases += 1
                s.cacheHits += 1
                return entry.texture
            }
            return nil
        }

        if let existing {
            return PooledTexture(texture: existing, key: key, pool: self)
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: safeW,
            height: safeH,
            mipmapped: false
        )
        desc.usage = usage
        desc.storageMode = storageMode
        if storageMode == .private {
            desc.hazardTrackingMode = .tracked
        }

        guard let created = device.makeTexture(descriptor: desc) else {
            let msg = "MTLDevice.makeTexture failed for \(safeW)x\(safeH) format=\(pixelFormat.rawValue)"
            PipelineLog.shared.error(.shader, msg)
            throw EngineError.metalDeviceUnavailable
        }
        created.label = label ?? "MetalPiePool_\(safeW)x\(safeH)_\(pixelFormat.rawValue)"

        state.withLockUnchecked { s in
            s.totalAllocations += 1
            s.activeLeases += 1
        }
        return PooledTexture(texture: created, key: key, pool: self)
    }

    /// Attaches an array of `PooledTexture` leases to `commandBuffer` so they remain pinned until
    /// GPU execution completes and then automatically return to the pool.
    public func recycleOnCompletion(_ leases: [PooledTexture], of commandBuffer: any MTLCommandBuffer) {
        guard !leases.isEmpty else { return }
        // Retain leases until GPU finishes executing `commandBuffer`, then release them cleanly.
        let holder = LeaseBatch(leases: leases)
        commandBuffer.addCompletedHandler { _ in
            holder.releaseAll()
        }
    }

    /// Returns current allocation and hit statistics.
    public var stats: TexturePoolStats {
        state.withLockUnchecked { s in
            TexturePoolStats(
                totalAllocations: s.totalAllocations,
                cacheHits: s.cacheHits,
                activeLeaseCount: s.activeLeases,
                pooledCount: s.totalPooled
            )
        }
    }

    /// Releases all idle textures currently held in the pool (active in-flight leases finish safely).
    public func drain() {
        state.withLockUnchecked { s in
            s.buckets.removeAll()
            s.totalPooled = 0
        }
    }

    /// Resets cached textures and clears hit/allocation counters.
    public func reset() {
        state.withLockUnchecked { s in
            s.buckets.removeAll()
            s.totalPooled = 0
            s.totalAllocations = 0
            s.cacheHits = 0
        }
    }

    fileprivate func recycle(texture: any MTLTexture, key: TexturePoolKey) {
        state.withLockUnchecked { s in
            s.activeLeases = max(0, s.activeLeases - 1)
            s.sequence &+= 1
            let entry = BucketEntry(texture: texture, lastUsedSequence: s.sequence)
            s.buckets[key, default: []].append(entry)
            s.totalPooled += 1

            while s.totalPooled > maxCachedTextures {
                evictOldestLocked(&s)
            }
        }
    }

    private func evictOldestLocked(_ s: inout PoolState) {
        var oldestKey: TexturePoolKey?
        var oldestIndex = 0
        var oldestSeq = UInt64.max

        for (key, list) in s.buckets {
            for (idx, item) in list.enumerated() where item.lastUsedSequence < oldestSeq {
                oldestSeq = item.lastUsedSequence
                oldestKey = key
                oldestIndex = idx
            }
        }

        guard let key = oldestKey, var list = s.buckets[key] else { return }
        list.remove(at: oldestIndex)
        if list.isEmpty {
            s.buckets.removeValue(forKey: key)
        } else {
            s.buckets[key] = list
        }
        s.totalPooled = max(0, s.totalPooled - 1)
    }

    private final class LeaseBatch: @unchecked Sendable {
        private let leases: [PooledTexture]
        init(leases: [PooledTexture]) { self.leases = leases }
        func releaseAll() {
            for lease in leases {
                lease.releaseNow()
            }
        }
    }
}
