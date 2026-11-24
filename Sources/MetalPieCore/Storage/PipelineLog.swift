import Foundation
import os

/// Severity level for entries stored in `PipelineLog`.
public enum LogLevel: Int, Codable, Sendable, Comparable, CaseIterable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var tag: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        }
    }
}

/// Functional subsystem category for structured pipeline diagnostics.
public enum LogCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case capture
    case render
    case shader
    case cursor
    case input
    case profile
    case app

    public var id: String { rawValue }
}

/// Single immutable log record inside `PipelineLog`.
public struct LogEntry: Identifiable, Hashable, Codable, Sendable {
    public var id: UInt64
    public var timestamp: Date
    public var level: LogLevel
    public var category: LogCategory
    public var message: String

    public init(
        id: UInt64,
        timestamp: Date = Date(),
        level: LogLevel,
        category: LogCategory,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
    }
}

/// Thread-safe, bounded ring-buffer diagnostic log shared across all MetalPie subsystems.
public final class PipelineLog: Sendable {
    public static let defaultMaxEntries = 2000
    public static let shared = PipelineLog()

    private struct RingState: Sendable {
        var buffer: [LogEntry?]
        var head: Int = 0
        var count: Int = 0
        var nextID: UInt64 = 1

        init(capacity: Int) {
            self.buffer = Array(repeating: nil, count: max(1, capacity))
        }
    }

    public let maxEntries: Int
    private let state: OSAllocatedUnfairLock<RingState>

    public init(maxEntries: Int = PipelineLog.defaultMaxEntries) {
        let safeCap = max(1, maxEntries)
        self.maxEntries = safeCap
        self.state = OSAllocatedUnfairLock(initialState: RingState(capacity: safeCap))
    }

    /// Appends a log entry to the ring buffer, overwriting the oldest entry when full.
    public func log(
        _ level: LogLevel,
        category: LogCategory,
        _ message: String,
        timestamp: Date = Date()
    ) {
        state.withLock { ring in
            let entry = LogEntry(
                id: ring.nextID,
                timestamp: timestamp,
                level: level,
                category: category,
                message: message
            )
            ring.nextID &+= 1

            let capacity = ring.buffer.count
            if ring.count < capacity {
                let writeIdx = (ring.head + ring.count) % capacity
                ring.buffer[writeIdx] = entry
                ring.count += 1
            } else {
                ring.buffer[ring.head] = entry
                ring.head = (ring.head + 1) % capacity
            }
        }
    }

    public func debug(_ category: LogCategory, _ message: String) {
        log(.debug, category: category, message)
    }

    public func info(_ category: LogCategory, _ message: String) {
        log(.info, category: category, message)
    }

    public func warning(_ category: LogCategory, _ message: String) {
        log(.warning, category: category, message)
    }

    public func error(_ category: LogCategory, _ message: String) {
        log(.error, category: category, message)
    }

    /// Current number of retained log entries.
    public var count: Int {
        state.withLock(\.count)
    }

    /// Returns entries in chronological order (oldest first), optionally filtered by level and category.
    public func entries(
        minimumLevel: LogLevel = .debug,
        category: LogCategory? = nil,
        limit: Int? = nil
    ) -> [LogEntry] {
        let all: [LogEntry] = state.withLock { ring in
            guard ring.count > 0 else { return [] }
            let capacity = ring.buffer.count
            var result: [LogEntry] = []
            result.reserveCapacity(ring.count)
            for offset in 0..<ring.count {
                if let entry = ring.buffer[(ring.head + offset) % capacity] {
                    result.append(entry)
                }
            }
            return result
        }

        let filtered = all.filter { entry in
            entry.level >= minimumLevel && (category == nil || entry.category == category)
        }

        if let limit, limit >= 0, filtered.count > limit {
            return Array(filtered.suffix(limit))
        }
        return filtered
    }

    /// Clears all buffered log entries.
    public func clear() {
        state.withLock { ring in
            for i in ring.buffer.indices {
                ring.buffer[i] = nil
            }
            ring.head = 0
            ring.count = 0
        }
    }

    /// Formats retained log entries as a human-readable diagnostic report string.
    public func formattedExport(
        minimumLevel: LogLevel = .debug,
        category: LogCategory? = nil
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let selected = entries(minimumLevel: minimumLevel, category: category)
        return selected.map { entry in
            let ts = formatter.string(from: entry.timestamp)
            return "\(ts) [\(entry.level.tag)] [\(entry.category.rawValue)] \(entry.message)"
        }.joined(separator: "\n")
    }

    /// Atomically exports formatted diagnostic logs to a file URL.
    public func export(
        to url: URL,
        minimumLevel: LogLevel = .debug,
        category: LogCategory? = nil
    ) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = formattedExport(minimumLevel: minimumLevel, category: category)
        guard let data = text.data(using: .utf8) else { return }
        try data.write(to: url, options: [.atomic])
    }
}
