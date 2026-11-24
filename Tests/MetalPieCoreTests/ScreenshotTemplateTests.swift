import Foundation
import Testing
@testable import MetalPieCore

@Suite("ScreenshotFilenameTemplate Expansion & Sanitization")
struct ScreenshotTemplateTests {
    private static func makeUTCDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int,
        millisecond: Int
    ) -> (Date, Calendar) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second,
            nanosecond: millisecond * 1_000_000
        )
        return (calendar.date(from: components)!, calendar)
    }

    @Test("Default template expands %PN%, %Y%, %M%, %D%, %H%, %m%, %S% accurately")
    func defaultTemplateExpansion() {
        let (date, calendar) = Self.makeUTCDate(
            year: 2026,
            month: 4,
            day: 7,
            hour: 9,
            minute: 5,
            second: 3,
            millisecond: 42
        )

        let expanded = ScreenshotFilenameTemplate.expand(
            template: AppConfig.defaultScreenshotFilenameTemplate,
            processName: "HollowKnight",
            windowTitle: "Hollow Knight",
            date: date,
            calendar: calendar
        )
        #expect(expanded == "MetalPie_HollowKnight_20260407_090503")
    }

    @Test("All tokens including %WT%, truncation (:n), %y%, %MS%, and escaped percent")
    func allTokensExpansion() {
        let (date, calendar) = Self.makeUTCDate(
            year: 2026,
            month: 11,
            day: 24,
            hour: 21,
            minute: 8,
            second: 59,
            millisecond: 7
        )

        let expanded = ScreenshotFilenameTemplate.expand(
            template: "%PN:5%_%WT:6%_%y%%M%%D%_%H%%m%%S%_%MS%_100\\%",
            processName: "RetroArch",
            windowTitle: "Chrono Trigger (USA)",
            date: date,
            calendar: calendar
        )
        #expect(expanded == "Retro_Chrono_261124_210859_007_100%")
    }

    @Test("Path sanitization strips illegal characters, traversal, control chars, and empty names")
    func pathSanitization() {
        let (date, calendar) = Self.makeUTCDate(
            year: 2026,
            month: 1,
            day: 2,
            hour: 3,
            minute: 4,
            second: 5,
            millisecond: 0
        )

        let unsafeExpanded = ScreenshotFilenameTemplate.expand(
            template: "%PN%_%WT%",
            processName: "../../evil/app",
            windowTitle: "Boss: Level 1/2 *?\"<>|\n\t",
            date: date,
            calendar: calendar
        )
        #expect(!unsafeExpanded.contains("/"))
        #expect(!unsafeExpanded.contains("\\"))
        #expect(!unsafeExpanded.contains(".."))
        #expect(!unsafeExpanded.contains(":"))
        #expect(!unsafeExpanded.contains("*"))
        #expect(!unsafeExpanded.contains("?"))
        #expect(!unsafeExpanded.contains("\n"))
        #expect(!unsafeExpanded.hasPrefix("."))

        // Pure dots / whitespace fall back to safe default
        #expect(ScreenshotFilenameTemplate.sanitizeFilename("...   ...") == ScreenshotFilenameTemplate.fallbackFilename)
        #expect(ScreenshotFilenameTemplate.sanitizeFilename("") == ScreenshotFilenameTemplate.fallbackFilename)
    }

    @Test("Template validation catches empty, unclosed, and unknown tokens")
    func templateValidation() {
        #expect(ScreenshotFilenameTemplate.validate(AppConfig.defaultScreenshotFilenameTemplate).isValid)
        #expect(ScreenshotFilenameTemplate.validate("%PN:8%_%WT:12%_%MS%_\\%").isValid)
        #expect(!ScreenshotFilenameTemplate.validate("   ").isValid)
        #expect(!ScreenshotFilenameTemplate.validate("Shot_%PN").isValid)
        #expect(!ScreenshotFilenameTemplate.validate("Shot_%UNKNOWN%").isValid)
        #expect(!ScreenshotFilenameTemplate.validate("Shot_%PN:0%").isValid)
    }

    @Test("Collision-free uniqueFileURL appends (2), (3) suffixes")
    func uniqueFileURLCollisionHandling() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetalPieScreenshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = ScreenshotFilenameTemplate.uniqueFileURL(in: dir, baseName: "Capture_01")
        #expect(first.lastPathComponent == "Capture_01.png")
        try Data().write(to: first)

        let second = ScreenshotFilenameTemplate.uniqueFileURL(in: dir, baseName: "Capture_01")
        #expect(second.lastPathComponent == "Capture_01 (2).png")
        try Data().write(to: second)

        let third = ScreenshotFilenameTemplate.uniqueFileURL(in: dir, baseName: "Capture_01")
        #expect(third.lastPathComponent == "Capture_01 (3).png")
    }
}
