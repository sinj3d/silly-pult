import Foundation
import Testing
@testable import SillypultHelper

@Test func defaultSettingsStartWithFocusDisabled() async throws {
    #expect(Settings.default.focusWindows.isEmpty)
}

@Test func legacyFocusDefaultNeedsMigration() async throws {
    let settings = Settings(
        focusWindows: [
            FocusWindow(
                id: "legacy-default",
                label: "Weekday Focus",
                enabled: true,
                daysOfWeek: [2, 3, 4, 5, 6],
                startMinutes: 9 * 60,
                endMinutes: 17 * 60
            ),
        ],
        workAppAllowlist: ["Slack"],
        distractionDomainDenylist: ["instagram.com"],
        cooldownSeconds: 30,
        distractionThresholdSeconds: 20
    )

    #expect(settings.needsLegacyFocusMigration())
}

@Test func focusWindowsRespectSchedule() async throws {
    let settings = Settings(
        focusWindows: [
            FocusWindow(
                id: "weekday-focus",
                label: "Focus",
                enabled: true,
                daysOfWeek: [4],
                startMinutes: 9 * 60,
                endMinutes: 11 * 60
            ),
        ],
        workAppAllowlist: ["Slack"],
        distractionDomainDenylist: [],
        cooldownSeconds: 10,
        distractionThresholdSeconds: 15
    )

    var components = DateComponents()
    components.year = 2026
    components.month = 4
    components.day = 1
    components.hour = 10
    components.minute = 0
    components.timeZone = TimeZone(secondsFromGMT: 0)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = try #require(calendar.date(from: components))

    #expect(HelperLogic.isFocusActive(on: date, settings: settings, calendar: calendar))
}

@Test func notificationsOutsideFocusAlwaysTrigger() async throws {
    let settings = Settings(
        focusWindows: [],
        workAppAllowlist: ["Slack"],
        distractionDomainDenylist: [],
        cooldownSeconds: 10,
        distractionThresholdSeconds: 15
    )

    let decision = HelperLogic.notificationDecision(for: "Instagram", bundleID: "com.instagram.Instagram", settings: settings, at: Date())
    #expect(decision.classification == .allowed)
    #expect(decision.actionRequired)
}

@Test func notificationsInsideFocusRequireAllowlist() async throws {
    let settings = Settings(
        focusWindows: [
            FocusWindow(
                id: "always",
                label: "Always",
                enabled: true,
                daysOfWeek: [1, 2, 3, 4, 5, 6, 7],
                startMinutes: 0,
                endMinutes: 24 * 60 - 1
            ),
        ],
        workAppAllowlist: ["Slack"],
        distractionDomainDenylist: [],
        cooldownSeconds: 10,
        distractionThresholdSeconds: 15
    )

    var components = DateComponents()
    components.year = 2026
    components.month = 4
    components.day = 1
    components.hour = 12
    components.minute = 0
    components.timeZone = TimeZone(secondsFromGMT: 0)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = try #require(calendar.date(from: components))

    #expect(HelperLogic.isFocusActive(on: date, settings: settings, calendar: calendar))

    let allowed = HelperLogic.notificationDecision(for: "Slack", bundleID: "com.tinyspeck.slackmacgap", settings: settings, at: date)
    let ignored = HelperLogic.notificationDecision(for: "Instagram", bundleID: "com.instagram.Instagram", settings: settings, at: date)

    #expect(allowed.classification == .allowed)
    #expect(allowed.actionRequired)
    #expect(ignored.classification == .ignored)
    #expect(!ignored.actionRequired)
}
