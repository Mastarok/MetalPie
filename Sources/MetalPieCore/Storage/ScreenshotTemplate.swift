import Foundation

/// Validation outcome for a screenshot filename template.
public enum ScreenshotTemplateValidation: Hashable, Sendable {
    case valid
    case invalid(reason: String)

    public var isValid: Bool {
        if case .valid = self { return true }
        return false
    }
}

/// Magpie-compatible screenshot filename template expander and filesystem sanitizer.
///
/// Supported tokens:
/// - `%PN%`, `%PN:n%` — Application / process name (optionally truncated to `n` characters)
/// - `%WT%`, `%WT:n%` — Window title (optionally truncated to `n` characters)
/// - `%Y%` — 4-digit year (`2026`)
/// - `%y%` — 2-digit year (`26`)
/// - `%M%` — 2-digit month (`01`–`12`)
/// - `%D%` — 2-digit day (`01`–`31`)
/// - `%H%` — 2-digit 24-hour (`00`–`23`)
/// - `%m%` — 2-digit minute (`00`–`59`)
/// - `%S%` — 2-digit second (`00`–`59`)
/// - `%MS%` — 3-digit millisecond (`000`–`999`)
/// - `\%` — Literal `%` character
public enum ScreenshotFilenameTemplate: Sendable {
    public static let fallbackFilename = "MetalPie_Screenshot"
    public static let maxFilenameLength = 180

    private static let illegalFilenameScalars: Set<Unicode.Scalar> = [
        "/", "\\", ":", "*", "?", "\"", "<", ">", "|"
    ]

    /// Expands `template` using window/process metadata and timestamp, returning a sanitized filename stem
    /// (without file extension) safe to append directly inside a target directory.
    public static func expand(
        template: String,
        processName: String,
        windowTitle: String,
        date: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: date
        )
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = components.second ?? 0
        let millisecond = min(999, max(0, Int((Double(components.nanosecond ?? 0) / 1_000_000.0).rounded())))

        let sanitizedProcess = sanitizeTokenValue(processName)
        let sanitizedTitle = sanitizeTokenValue(windowTitle)

        var output = ""
        output.reserveCapacity(template.count + 32)

        let chars = Array(template)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\\" && i + 1 < chars.count && chars[i + 1] == "%" {
                output.append("%")
                i += 2
                continue
            }

            if ch == "%" {
                if let closing = findClosingPercent(in: chars, from: i + 1) {
                    let token = String(chars[(i + 1)..<closing])
                    if let replacement = resolveToken(
                        token,
                        processName: sanitizedProcess,
                        windowTitle: sanitizedTitle,
                        year: year,
                        month: month,
                        day: day,
                        hour: hour,
                        minute: minute,
                        second: second,
                        millisecond: millisecond
                    ) {
                        output.append(replacement)
                        i = closing + 1
                        continue
                    }
                }
            }

            output.append(ch)
            i += 1
        }

        return sanitizeFilename(output)
    }

    /// Validates template syntax for UI feedback.
    public static func validate(_ template: String) -> ScreenshotTemplateValidation {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .invalid(reason: "Template cannot be empty.")
        }

        let chars = Array(trimmed)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\" && i + 1 < chars.count && chars[i + 1] == "%" {
                i += 2
                continue
            }
            if chars[i] == "%" {
                guard let closing = findClosingPercent(in: chars, from: i + 1) else {
                    return .invalid(reason: "Unclosed '%' token.")
                }
                let token = String(chars[(i + 1)..<closing])
                if !isRecognizedToken(token) {
                    return .invalid(reason: "Unknown token '%\(token)%'.")
                }
                i = closing + 1
                continue
            }
            i += 1
        }
        return .valid
    }

    /// Sanitizes an arbitrary filename stem against path separators, traversal (`..`), control characters,
    /// leading/trailing dots/spaces, and excessive length.
    public static func sanitizeFilename(_ raw: String) -> String {
        let trimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
        let preTrimmed = raw.trimmingCharacters(in: trimSet)
        guard !preTrimmed.isEmpty else {
            return fallbackFilename
        }

        var result = ""
        result.reserveCapacity(preTrimmed.count)

        for scalar in preTrimmed.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F || illegalFilenameScalars.contains(scalar) {
                result.append("_")
            } else {
                result.unicodeScalars.append(scalar)
            }
        }

        // Neutralize any interior path traversal patterns.
        while result.contains("..") {
            result = result.replacingOccurrences(of: "..", with: "_")
        }

        result = result.trimmingCharacters(in: trimSet)

        if result.count > maxFilenameLength {
            result = String(result.prefix(maxFilenameLength)).trimmingCharacters(in: trimSet)
        }

        // Reject names composed solely of underscores, dots, or whitespace.
        let meaningful = result.trimmingCharacters(
            in: trimSet.union(CharacterSet(charactersIn: "_"))
        )
        return meaningful.isEmpty ? fallbackFilename : result
    }

    /// Resolves a collision-free file URL inside `directory`, appending ` (2)`, ` (3)`, etc. if needed.
    public static func uniqueFileURL(
        in directory: URL,
        baseName: String,
        fileExtension: String = "png",
        fileManager: FileManager = .default
    ) -> URL {
        let safeStem = sanitizeFilename(baseName)
        let ext = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        var candidate = directory.appendingPathComponent(safeStem).appendingPathExtension(ext)
        if !fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }

        var suffix = 2
        while suffix < 10_000 {
            candidate = directory
                .appendingPathComponent("\(safeStem) (\(suffix))")
                .appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }

        return directory
            .appendingPathComponent("\(safeStem)_\(UUID().uuidString.prefix(8))")
            .appendingPathExtension(ext)
    }

    // MARK: - Private Helpers

    private static func sanitizeTokenValue(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F || illegalFilenameScalars.contains(scalar) {
                result.append("_")
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func findClosingPercent(in chars: [Character], from start: Int) -> Int? {
        var idx = start
        while idx < chars.count {
            if chars[idx] == "%" {
                return idx
            }
            idx += 1
        }
        return nil
    }

    private static func isRecognizedToken(_ token: String) -> Bool {
        switch token {
        case "PN", "WT", "Y", "y", "M", "D", "H", "m", "S", "MS":
            return true
        default:
            if token.hasPrefix("PN:") || token.hasPrefix("WT:") {
                let parts = token.split(separator: ":", maxSplits: 1)
                if parts.count == 2, let n = Int(parts[1]), n > 0 {
                    return true
                }
            }
            return false
        }
    }

    private static func resolveToken(
        _ token: String,
        processName: String,
        windowTitle: String,
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int,
        millisecond: Int
    ) -> String? {
        switch token {
        case "PN":
            return processName
        case "WT":
            return windowTitle
        case "Y":
            return String(format: "%04d", year)
        case "y":
            return String(format: "%02d", abs(year) % 100)
        case "M":
            return String(format: "%02d", month)
        case "D":
            return String(format: "%02d", day)
        case "H":
            return String(format: "%02d", hour)
        case "m":
            return String(format: "%02d", minute)
        case "S":
            return String(format: "%02d", second)
        case "MS":
            return String(format: "%03d", millisecond)
        default:
            if token.hasPrefix("PN:") {
                let parts = token.split(separator: ":", maxSplits: 1)
                if parts.count == 2, let n = Int(parts[1]), n > 0 {
                    return String(processName.prefix(n))
                }
            } else if token.hasPrefix("WT:") {
                let parts = token.split(separator: ":", maxSplits: 1)
                if parts.count == 2, let n = Int(parts[1]), n > 0 {
                    return String(windowTitle.prefix(n))
                }
            }
            return nil
        }
    }
}
