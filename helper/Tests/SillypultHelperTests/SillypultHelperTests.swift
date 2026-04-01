import Foundation
import Testing
@testable import SillypultHelper

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
