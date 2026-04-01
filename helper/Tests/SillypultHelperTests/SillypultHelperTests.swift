import Foundation
import Testing
@testable import SillyPultHelperKit

private actor RequestSequence {
    private var responses: [(Data, HTTPURLResponse)]
    private var requests: [URLRequest] = []

    init(responses: [(Data, HTTPURLResponse)]) {
        self.responses = responses
    }

    func next(for request: URLRequest) -> (Data, URLResponse) {
        requests.append(request)
        return responses.removeFirst()
    }

    func receivedRequests() -> [URLRequest] {
        requests
    }
}

private func httpResponse(url: String, statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: url)!,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    )!
}

@Test func defaultSettingsStartWithFocusDisabled() async throws {
    #expect(!Settings.default.focusModeEnabled)
}

@Test func firmwareConfigurationRequiresExplicitStaticHost() async throws {
    let configuration = HelperConfiguration.fromEnvironment([
        "SILLYPULT_HELPER_PORT": "42424",
        "SILLYPULT_FIRMWARE_PORT": "8080",
    ])

    #expect(configuration.firmwareHost == nil)
    #expect(configuration.firmwarePort == 8080)
}

@Test func firmwareConfigurationUsesCanonicalHostWhenProvided() async throws {
    let configuration = HelperConfiguration.fromEnvironment([
        "SILLYPULT_FIRMWARE_HOST": " 192.168.1.50 ",
        "SILLYPULT_FIRMWARE_PORT": "80",
        "SILLYPULT_FIRMWARE_TIMEOUT_SECONDS": "12",
    ])

    #expect(configuration.firmwareHost == "192.168.1.50")
    #expect(configuration.firmwarePort == 80)
    #expect(configuration.firmwareReadyTimeoutSeconds == 12)
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
        metadata: [:]
    )
    let changedContent = ObservedNotification(
        sourceBundleID: "com.tinyspeck.slackmacgap",
        sourceApp: "Slack",
        title: "Standup soon",
        body: "Join in 10 minutes",
        isTest: false,
        metadata: [:]
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

@Test func requestIDDeduplicationPersistsBeyondShortFallbackWindow() async throws {
    let deduper = NotificationDeduper()
    let observed = ObservedNotification(
        sourceBundleID: "com.linkedin.LinkedIn",
        sourceApp: "com.linkedin.LinkedIn",
        title: nil,
        body: nil,
        isTest: false,
        metadata: ["requestID": "59BE-F2A0"]
    )
    let date = Date(timeIntervalSince1970: 1_775_062_000.0)

    let first = await deduper.shouldProcess(observed, at: date)
    let tenSecondsLater = await deduper.shouldProcess(observed, at: date.addingTimeInterval(10))

    #expect(first)
    #expect(!tenSecondsLater)
}

@Test func firmwareActivationReturnsActivatedAfterReadyPoll() async throws {
    let sequence = RequestSequence(responses: [
        (
            Data(#"{"status":"launch triggered"}"#.utf8),
            httpResponse(url: "http://192.168.1.50:80/launch", statusCode: 200)
        ),
        (
            Data(#"{"ready":true,"ip":"192.168.1.50"}"#.utf8),
            httpResponse(url: "http://192.168.1.50:80/status", statusCode: 200)
        ),
    ])
    let controller = FirmwareController(
        host: "192.168.1.50",
        port: 80,
        readyTimeoutSeconds: 1,
        pollIntervalMilliseconds: 1,
        requestExecutor: { request in
            await sequence.next(for: request)
        }
    )

    let result = await controller.activate(cooldownSeconds: 0)
    let requests = await sequence.receivedRequests()

    #expect(result == .activated)
    #expect(await controller.targetDescription() == "http://192.168.1.50:80")
    #expect(await controller.lastErrorDescription() == nil)
    #expect(requests.count == 2)
    #expect(requests[0].httpMethod == "POST")
    #expect(requests[1].httpMethod == "GET")
}

@Test func firmwareActivationReturnsBusyWhenLaunchEndpointRejectsRequest() async throws {
    let sequence = RequestSequence(responses: [
        (
            Data(#"{"error":"launch already in progress"}"#.utf8),
            httpResponse(url: "http://192.168.1.50:80/launch", statusCode: 429)
        ),
    ])
    let controller = FirmwareController(
        host: "192.168.1.50",
        port: 80,
        readyTimeoutSeconds: 1,
        pollIntervalMilliseconds: 1,
        requestExecutor: { request in
            await sequence.next(for: request)
        }
    )

    let result = await controller.activate(cooldownSeconds: 0)

    #expect(result == .suppressedBusy)
    #expect(await controller.lastErrorDescription() == nil)
}

@Test func firmwareActivationFailsWhenStatusPayloadIsMalformed() async throws {
    let sequence = RequestSequence(responses: [
        (
            Data(#"{"status":"launch triggered"}"#.utf8),
            httpResponse(url: "http://192.168.1.50:80/launch", statusCode: 200)
        ),
        (
            Data(#"{"ip":"192.168.1.50"}"#.utf8),
            httpResponse(url: "http://192.168.1.50:80/status", statusCode: 200)
        ),
    ])
    let controller = FirmwareController(
        host: "192.168.1.50",
        port: 80,
        readyTimeoutSeconds: 1,
        pollIntervalMilliseconds: 1,
        requestExecutor: { request in
            await sequence.next(for: request)
        }
    )

    let result = await controller.activate(cooldownSeconds: 0)
    let error = await controller.lastErrorDescription()

    #expect(result == .failed)
    #expect(error?.contains("did not include a boolean ready flag") == true)
}

@Test func firmwareActivationFailsWhenTargetIsUnconfigured() async throws {
    let controller = FirmwareController(host: nil, port: 80, readyTimeoutSeconds: 1)

    let result = await controller.activate(cooldownSeconds: 0)

    #expect(result == .failed)
    #expect(await controller.targetDescription() == "unconfigured")
    #expect(await controller.lastErrorDescription()?.contains("SILLYPULT_FIRMWARE_HOST") == true)
}
