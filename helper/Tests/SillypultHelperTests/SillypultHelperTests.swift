import Foundation
import Testing
@testable import SillyPultHelperKit

@Test func defaultSettingsStartWithFocusDisabled() async throws {
    #expect(!Settings.default.focusModeEnabled)
}

@Test func settingsDecodeWithoutFocusToggleDefaultsToOff() async throws {
    let legacyJSON = """
    {
      "focusWindows": [
        {
          "id": "legacy-default",
          "label": "Weekday Focus",
          "enabled": true,
          "daysOfWeek": [2, 3, 4, 5, 6],
          "startMinutes": 540,
          "endMinutes": 1020
        }
      ],
      "workAppAllowlist": ["Slack"],
      "distractionDomainDenylist": ["instagram.com"],
      "cooldownSeconds": 30,
      "distractionThresholdSeconds": 20
    }
    """

    let settings = try JSONDecoder().decode(Settings.self, from: Data(legacyJSON.utf8))

    #expect(!settings.focusModeEnabled)
}

@Test func focusToggleControlsMode() async throws {
    let settings = Settings(
        focusModeEnabled: true,
        workAppAllowlist: ["Slack"],
        distractionDomainDenylist: ["instagram.com"],
        cooldownSeconds: 30,
        distractionThresholdSeconds: 20
    )

    #expect(HelperLogic.isFocusActive(on: Date(), settings: settings))
}

@Test func notificationsOutsideFocusAlwaysTrigger() async throws {
    let settings = Settings(
        focusModeEnabled: false,
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
        focusModeEnabled: true,
        workAppAllowlist: ["Slack"],
        distractionDomainDenylist: [],
        cooldownSeconds: 10,
        distractionThresholdSeconds: 15
    )

    let date = Date()
    #expect(HelperLogic.isFocusActive(on: date, settings: settings))

    let allowed = HelperLogic.notificationDecision(for: "Slack", bundleID: "com.tinyspeck.slackmacgap", settings: settings, at: date)
    let ignored = HelperLogic.notificationDecision(for: "Instagram", bundleID: "com.instagram.Instagram", settings: settings, at: date)

    #expect(allowed.classification == .allowed)
    #expect(allowed.actionRequired)
    #expect(ignored.classification == .ignored)
    #expect(!ignored.actionRequired)
}

@Test func duplicateNotificationsFromSameProviderAndContentInSameSecondAreSuppressed() async throws {
    let deduper = NotificationDeduper()
    let observed = ObservedNotification(
        sourceBundleID: "com.tinyspeck.slackmacgap",
        sourceApp: "Slack",
        title: "Standup soon",
        body: "Join in 5 minutes",
        isTest: false,
        metadata: ["requestID": "abc-123"]
    )
    let date = Date(timeIntervalSince1970: 1_775_061_200.25)

    let first = await deduper.shouldProcess(observed, at: date)
    let second = await deduper.shouldProcess(observed, at: date.addingTimeInterval(0.4))

    #expect(first)
    #expect(!second)
}

@Test func notificationsWithDifferentContentOrSecondAreNotSuppressed() async throws {
    let deduper = NotificationDeduper()
    let first = ObservedNotification(
        sourceBundleID: "com.tinyspeck.slackmacgap",
        sourceApp: "Slack",
        title: "Standup soon",
        body: "Join in 5 minutes",
        isTest: false,
        metadata: ["requestID": "abc-123"]
    )
    let changedContent = ObservedNotification(
        sourceBundleID: "com.tinyspeck.slackmacgap",
        sourceApp: "Slack",
        title: "Standup soon",
        body: "Join in 10 minutes",
        isTest: false,
        metadata: ["requestID": "def-456"]
    )
    let date = Date(timeIntervalSince1970: 1_775_061_200.25)

    let original = await deduper.shouldProcess(first, at: date)
    let differentContent = await deduper.shouldProcess(changedContent, at: date.addingTimeInterval(0.2))
    let nextSecond = await deduper.shouldProcess(first, at: date.addingTimeInterval(1.1))

    #expect(original)
    #expect(differentContent)
    #expect(nextSecond)
}

@Test func systemLogCreateRequestIDIsParsed() async throws {
    let line = "2026-04-01 15:35:41.360 Df usernotificationsd[659:bffc1d] [com.apple.usernotificationsd:NotificationsPipeline] [create, [id=EB5B-4A50, time=2026-04-01 22:35:41, bundle=com.amazon.Amazon], Time elapsed=0.005 sec]: Request: Starting"

    let requestID = NotificationLogMonitor.parseRequestID(from: line)

    #expect(requestID == "EB5B-4A50")
}
