import AppKit
import Dispatch
import Foundation
import Network
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct HelperConfiguration {
    let port: UInt16
    let databasePath: String
    let logPredicate: String

    static func fromEnvironment() -> HelperConfiguration {
        let env = ProcessInfo.processInfo.environment
        let port = UInt16(env["SILLYPLUT_HELPER_PORT"] ?? "") ?? 42424
        let databasePath = env["SILLYPLUT_DB_PATH"] ?? "\(FileManager.default.homeDirectoryForCurrentUser.path)/Library/Application Support/SillyPlut/sillyplut.sqlite3"

        return HelperConfiguration(
            port: port,
            databasePath: databasePath,
            logPredicate: #"subsystem == "com.apple.usernotificationsd""#
        )
    }
}

struct FocusWindow: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var label: String
    var enabled: Bool
    var daysOfWeek: [Int]
    var startMinutes: Int
    var endMinutes: Int

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else {
            return false
        }

        let weekday = calendar.component(.weekday, from: date)
        let minutes = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        guard daysOfWeek.contains(weekday) else {
            return false
        }

        if startMinutes <= endMinutes {
            return minutes >= startMinutes && minutes < endMinutes
        }

        return minutes >= startMinutes || minutes < endMinutes
    }
}

struct Settings: Codable, Sendable {
    var focusWindows: [FocusWindow]
    var workAppAllowlist: [String]
    var distractionDomainDenylist: [String]
    var cooldownSeconds: Int
    var distractionThresholdSeconds: Int

    static let `default` = Settings(
        focusWindows: [
            FocusWindow(
                id: UUID().uuidString,
                label: "Weekday Focus",
                enabled: true,
                daysOfWeek: [2, 3, 4, 5, 6],
                startMinutes: 9 * 60,
                endMinutes: 17 * 60
            ),
        ],
        workAppAllowlist: ["Slack", "Mail", "Calendar", "Messages", "Teams"],
        distractionDomainDenylist: ["instagram.com", "www.instagram.com", "coolmathgames.com", "www.coolmathgames.com"],
        cooldownSeconds: 30,
        distractionThresholdSeconds: 20
    )
}

enum EventClassification: String, Codable, Sendable {
    case allowed
    case ignored
    case distraction
    case unknown
}

enum TriggerReason: String, Codable, Sendable {
    case notification
    case distraction
}

enum ActionTaken: String, Codable, Sendable {
    case activated
    case ignored
    case suppressedBusy = "suppressed_busy"
    case suppressedCooldown = "suppressed_cooldown"
    case failed
}

struct NotificationEvent: Codable, Identifiable, Sendable {
    var id: String
    var receivedAt: String
    var sourceApp: String
    var title: String?
    var body: String?
    var isTest: Bool
    var classification: EventClassification
    var triggerReason: TriggerReason
    var actionTaken: ActionTaken
    var metadata: [String: String]
}

struct DashboardSnapshot: Codable, Sendable {
    var totalNotifications: Int
    var focusedNotifications: Int
    var ignoredNotifications: Int
    var distractionEvents: Int
    var distractionRate: Double
    var focusModeActive: Bool
}

struct HelperStatus: Codable, Sendable {
    var helperStartedAt: String
    var notificationMonitorRunning: Bool
    var firmwareBusy: Bool
    var lastActivationResult: ActionTaken?
    var lastDetectedAt: String?
    var currentBrowserDomain: String?
    var databasePath: String
    var helperPid: Int32
    var captureMode: String
    var lastError: String?
}

struct BrowserActivityPayload: Codable, Sendable {
    var url: String
    var domain: String
    var title: String
    var tabId: Int
    var windowId: Int
    var observedAt: String
}

struct SettingsPayload: Codable, Sendable {
    var settings: Settings
}

struct TestNotificationPayload: Codable, Sendable {
    var variant: String
}

struct ObservedNotification: Sendable {
    var sourceBundleID: String?
    var sourceApp: String
    var title: String?
    var body: String?
    var isTest: Bool
    var metadata: [String: String]
}

struct RuleDecision: Sendable {
    var classification: EventClassification
    var actionRequired: Bool
}

enum HelperLogic {
    static func isFocusActive(on date: Date, settings: Settings, calendar: Calendar = .current) -> Bool {
        settings.focusWindows.contains { $0.contains(date, calendar: calendar) }
    }

    static func notificationDecision(
        for sourceApp: String,
        bundleID: String?,
        settings: Settings,
        at date: Date
    ) -> RuleDecision {
        guard isFocusActive(on: date, settings: settings) else {
            return RuleDecision(classification: .allowed, actionRequired: true)
        }

        let normalizedSource = sourceApp.lowercased()
        let normalizedBundle = bundleID?.lowercased()
        let matched = settings.workAppAllowlist.contains { candidate in
            let normalizedCandidate = candidate.lowercased()
            return normalizedCandidate == normalizedSource || normalizedCandidate == normalizedBundle
        }

        if matched {
            return RuleDecision(classification: .allowed, actionRequired: true)
        }

        return RuleDecision(classification: .ignored, actionRequired: false)
    }

    static func normalizedDomain(_ rawDomain: String) -> String {
        rawDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum HTTPMethod: String {
    case GET
    case POST
    case PUT
    case OPTIONS
}

struct HTTPRequest {
    var method: HTTPMethod
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data
}

struct HTTPResponse {
    var statusCode: Int
    var contentType: String = "application/json; charset=utf-8"
    var body: Data
    var extraHeaders: [String: String] = [:]

    static func json<T: Encodable>(_ value: T, encoder: JSONEncoder = .helperEncoder) throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: try encoder.encode(value))
    }

    static func empty(statusCode: Int = 204) -> HTTPResponse {
        HTTPResponse(statusCode: statusCode, body: Data())
    }

    static func error(_ message: String, statusCode: Int) -> HTTPResponse {
        let payload = ["error": message]
        let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return HTTPResponse(statusCode: statusCode, body: body ?? Data("{\"error\":\"\(message)\"}".utf8))
    }
}

extension JSONEncoder {
    static let helperEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let helperDecoder = JSONDecoder()
}

final class SQLiteStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let encoder = JSONEncoder.helperEncoder
    private let decoder = JSONDecoder.helperDecoder
    private let queue = DispatchQueue(label: "sillyplut.sqlite")

    init(path: String) throws {
        let fileManager = FileManager.default
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw NSError(domain: "SQLiteStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open database"])
        }

        try execute("""
        CREATE TABLE IF NOT EXISTS settings (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            json TEXT NOT NULL
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS events (
            id TEXT PRIMARY KEY,
            received_at TEXT NOT NULL,
            source_app TEXT NOT NULL,
            title TEXT,
            body TEXT,
            is_test INTEGER NOT NULL,
            classification TEXT NOT NULL,
            trigger_reason TEXT NOT NULL,
            action_taken TEXT NOT NULL,
            metadata_json TEXT NOT NULL
        );
        """)

        if try loadSettings() == nil {
            try saveSettings(.default)
        }
    }

    deinit {
        sqlite3_close(db)
    }

    func loadSettings() throws -> Settings? {
        try queue.sync {
            let statement = try prepare("SELECT json FROM settings WHERE id = 1;")
            defer { sqlite3_finalize(statement) }

            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }

            guard let cString = sqlite3_column_text(statement, 0) else {
                return nil
            }

            let data = Data(String(cString: cString).utf8)
            return try decoder.decode(Settings.self, from: data)
        }
    }

    func saveSettings(_ settings: Settings) throws {
        let json = String(decoding: try encoder.encode(settings), as: UTF8.self)
        try queue.sync {
            let statement = try prepare("INSERT INTO settings (id, json) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET json = excluded.json;")
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, json, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw lastError()
            }
        }
    }

    func insertEvent(_ event: NotificationEvent) throws {
        let metadataJSON = String(decoding: try encoder.encode(event.metadata), as: UTF8.self)
        try queue.sync {
            let statement = try prepare("""
            INSERT INTO events (
                id, received_at, source_app, title, body, is_test, classification, trigger_reason, action_taken, metadata_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(statement) }

            bind(statement, value: event.id, index: 1)
            bind(statement, value: event.receivedAt, index: 2)
            bind(statement, value: event.sourceApp, index: 3)
            bind(statement, value: event.title, index: 4)
            bind(statement, value: event.body, index: 5)
            sqlite3_bind_int(statement, 6, event.isTest ? 1 : 0)
            bind(statement, value: event.classification.rawValue, index: 7)
            bind(statement, value: event.triggerReason.rawValue, index: 8)
            bind(statement, value: event.actionTaken.rawValue, index: 9)
            bind(statement, value: metadataJSON, index: 10)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw lastError()
            }
        }
    }

    func recentEvents(limit: Int) throws -> [NotificationEvent] {
        try queue.sync {
            let statement = try prepare("""
            SELECT id, received_at, source_app, title, body, is_test, classification, trigger_reason, action_taken, metadata_json
            FROM events
            ORDER BY received_at DESC
            LIMIT ?;
            """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(limit))

            var events: [NotificationEvent] = []

            while sqlite3_step(statement) == SQLITE_ROW {
                let metadataText = String(cString: sqlite3_column_text(statement, 9))
                let metadataData = Data(metadataText.utf8)
                let metadata = (try? decoder.decode([String: String].self, from: metadataData)) ?? [:]

                events.append(
                    NotificationEvent(
                        id: string(statement, index: 0),
                        receivedAt: string(statement, index: 1),
                        sourceApp: string(statement, index: 2),
                        title: optionalString(statement, index: 3),
                        body: optionalString(statement, index: 4),
                        isTest: sqlite3_column_int(statement, 5) == 1,
                        classification: EventClassification(rawValue: string(statement, index: 6)) ?? .unknown,
                        triggerReason: TriggerReason(rawValue: string(statement, index: 7)) ?? .notification,
                        actionTaken: ActionTaken(rawValue: string(statement, index: 8)) ?? .failed,
                        metadata: metadata
                    )
                )
            }

            return events
        }
    }

    func dashboardSnapshot(focusModeActive: Bool) throws -> DashboardSnapshot {
        let events = try recentEvents(limit: 500)
        let total = events.count
        let focused = events.filter { $0.classification == .allowed && $0.triggerReason == .notification }.count
        let ignored = events.filter { $0.classification == .ignored }.count
        let distractions = events.filter { $0.triggerReason == .distraction }.count
        let distractionRate = total == 0 ? 0 : Double(distractions) / Double(total)

        return DashboardSnapshot(
            totalNotifications: total,
            focusedNotifications: focused,
            ignoredNotifications: ignored,
            distractionEvents: distractions,
            distractionRate: distractionRate,
            focusModeActive: focusModeActive
        )
    }

    private func execute(_ sql: String) throws {
        try queue.sync {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw lastError()
            }
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError()
        }
        return statement
    }

    private func string(_ statement: OpaquePointer?, index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else {
            return ""
        }

        return String(cString: pointer)
    }

    private func optionalString(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else {
            return nil
        }

        return String(cString: pointer)
    }

    private func bind(_ statement: OpaquePointer?, value: String?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }

        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func lastError() -> NSError {
        NSError(domain: "SQLiteStore", code: 2, userInfo: [
            NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db)),
        ])
    }
}

actor FirmwareController {
    private var busy = false
    private var lastActivationAt: Date?
    private var lastResult: ActionTaken?

    func activate(cooldownSeconds: Int) async -> ActionTaken {
        if busy {
            lastResult = .suppressedBusy
            return .suppressedBusy
        }

        if let lastActivationAt, Date().timeIntervalSince(lastActivationAt) < Double(cooldownSeconds) {
            lastResult = .suppressedCooldown
            return .suppressedCooldown
        }

        busy = true
        defer { busy = false }

        do {
            try await Task.sleep(for: .seconds(1.5))
            lastActivationAt = Date()
            lastResult = .activated
            return .activated
        } catch {
            lastResult = .failed
            return .failed
        }
    }

    func isBusy() -> Bool {
        busy
    }

    func lastActivationResult() -> ActionTaken? {
        lastResult
    }
}

actor BrowserTracker {
    struct State: Sendable {
        var domain: String
        var url: String
        var title: String
        var observedAt: Date
        var firstObservedAt: Date
        var lastTriggeredAt: Date?
    }

    private var state: State?

    func update(_ payload: BrowserActivityPayload) {
        let parsedDate = HelperRuntime.parseDate(payload.observedAt) ?? Date()
        let normalizedDomain = HelperLogic.normalizedDomain(payload.domain)

        if var existing = state, existing.domain == normalizedDomain {
            existing.url = payload.url
            existing.title = payload.title
            existing.observedAt = parsedDate
            state = existing
            return
        }

        state = State(
            domain: normalizedDomain,
            url: payload.url,
            title: payload.title,
            observedAt: parsedDate,
            firstObservedAt: parsedDate,
            lastTriggeredAt: nil
        )
    }

    func currentDomain() -> String? {
        state?.domain
    }

    func shouldTriggerDistraction(settings: Settings, now: Date = Date()) -> State? {
        guard let state else {
            return nil
        }

        let blocked = settings.distractionDomainDenylist.map(HelperLogic.normalizedDomain)
        guard blocked.contains(state.domain) else {
            return nil
        }

        let elapsed = now.timeIntervalSince(state.firstObservedAt)
        guard elapsed >= Double(settings.distractionThresholdSeconds) else {
            return nil
        }

        if let lastTriggeredAt = state.lastTriggeredAt,
           now.timeIntervalSince(lastTriggeredAt) < Double(settings.cooldownSeconds) {
            return nil
        }

        return state
    }

    func markTriggered(at date: Date) {
        guard var state else {
            return
        }

        state.lastTriggeredAt = date
        self.state = state
    }
}

final class NotificationLogMonitor: @unchecked Sendable {
    private let predicate: String
    private let onNotification: @Sendable (ObservedNotification) async -> Void
    private let onError: @Sendable (String) async -> Void
    private let process = Process()
    private var readTask: Task<Void, Never>?

    init(
        predicate: String,
        onNotification: @escaping @Sendable (ObservedNotification) async -> Void,
        onError: @escaping @Sendable (String) async -> Void
    ) {
        self.predicate = predicate
        self.onNotification = onNotification
        self.onError = onError
    }

    func start() {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "compact", "--predicate", predicate]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            readTask = Task {
                await onError("Could not start notification monitor: \(error.localizedDescription)")
            }
            return
        }

        guard let output = process.standardOutput as? Pipe else {
            return
        }

        readTask = Task {
            do {
                for try await line in output.fileHandleForReading.bytes.lines {
                    guard let observed = Self.parse(line) else {
                        continue
                    }

                    await onNotification(observed)
                }
            } catch {
                await onError("Notification monitor stream error: \(error.localizedDescription)")
            }
        }
    }

    func isRunning() -> Bool {
        process.isRunning
    }

    private static func parse(_ line: String) -> ObservedNotification? {
        guard line.contains("[create, [id="), line.contains("bundle=") else {
            return nil
        }

        guard let bundleStart = line.range(of: "bundle=")?.upperBound else {
            return nil
        }

        let bundleSuffix = line[bundleStart...]
        guard let bundleEnd = bundleSuffix.firstIndex(of: "]") else {
            return nil
        }

        let bundleID = String(bundleSuffix[..<bundleEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else {
            return nil
        }

        let sourceApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?
            .deletingPathExtension()
            .lastPathComponent ?? bundleID

        return ObservedNotification(
            sourceBundleID: bundleID,
            sourceApp: sourceApp,
            title: nil,
            body: nil,
            isTest: false,
            metadata: ["bundleID": bundleID, "captureSource": "system-log"]
        )
    }
}

actor HelperRuntime {
    private let configuration: HelperConfiguration
    private let store: SQLiteStore
    private let firmware = FirmwareController()
    private let browserTracker = BrowserTracker()
    private let startedAt = Date()
    private var lastDetectedAt: Date?
    private var lastError: String?
    private var server: LocalHTTPServer?
    private var logMonitor: NotificationLogMonitor?
    private var distractionTask: Task<Void, Never>?

    init(configuration: HelperConfiguration, store: SQLiteStore) {
        self.configuration = configuration
        self.store = store
    }

    func start() async throws {
        logMonitor = NotificationLogMonitor(
            predicate: configuration.logPredicate,
            onNotification: { [weak self] observed in
                await self?.handleObservedNotification(observed)
            },
            onError: { [weak self] message in
                await self?.setLastError(message)
            }
        )
        logMonitor?.start()

        let server = try LocalHTTPServer(port: configuration.port) { [weak self] request in
            guard let self else {
                return HTTPResponse.error("Helper unavailable", statusCode: 500)
            }

            return await self.handle(request: request)
        }
        try server.start()
        self.server = server

        distractionTask = Task {
            while !Task.isCancelled {
                await self.evaluateDistractions()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func handle(request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case (.OPTIONS, _):
            return .empty()
        case (.GET, "/api/status"):
            return await tryOrError { try .json(await status()) }
        case (.GET, "/api/dashboard"):
            return await tryOrError {
                let settings = try currentSettings()
                let focusActive = HelperLogic.isFocusActive(on: Date(), settings: settings)
                return try .json(try store.dashboardSnapshot(focusModeActive: focusActive))
            }
        case (.GET, "/api/events"):
            let limit = Int(request.query["limit"] ?? "50") ?? 50
            return await tryOrError {
                try .json(try store.recentEvents(limit: max(1, min(limit, 200))))
            }
        case (.GET, "/api/settings"):
            return await tryOrError { try .json(try currentSettings()) }
        case (.PUT, "/api/settings"):
            do {
                let payload = try JSONDecoder.helperDecoder.decode(SettingsPayload.self, from: request.body)
                try store.saveSettings(payload.settings)
                return try .json(payload.settings)
            } catch {
                return .error("Invalid settings payload: \(error.localizedDescription)", statusCode: 400)
            }
        case (.POST, "/api/browser-activity"):
            do {
                let payload = try JSONDecoder.helperDecoder.decode(BrowserActivityPayload.self, from: request.body)
                await browserTracker.update(payload)
                return .empty(statusCode: 202)
            } catch {
                return .error("Invalid browser activity payload", statusCode: 400)
            }
        case (.POST, "/api/test-notification"):
            do {
                let payload = try JSONDecoder.helperDecoder.decode(TestNotificationPayload.self, from: request.body)
                let event = try await emitTestNotification(variant: payload.variant)
                return try .json(event)
            } catch {
                return .error(error.localizedDescription, statusCode: 400)
            }
        default:
            return .error("Not found", statusCode: 404)
        }
    }

    func status() async -> HelperStatus {
        HelperStatus(
            helperStartedAt: Self.formatDate(startedAt),
            notificationMonitorRunning: logMonitor?.isRunning() ?? false,
            firmwareBusy: await firmware.isBusy(),
            lastActivationResult: await firmware.lastActivationResult(),
            lastDetectedAt: lastDetectedAt.map(Self.formatDate),
            currentBrowserDomain: await browserTracker.currentDomain(),
            databasePath: configuration.databasePath,
            helperPid: ProcessInfo.processInfo.processIdentifier,
            captureMode: "best_effort_system_log",
            lastError: lastError
        )
    }

    private func currentSettings() throws -> Settings {
        try store.loadSettings() ?? .default
    }

    private func handleObservedNotification(_ observed: ObservedNotification) async {
        lastDetectedAt = Date()

        do {
            let settings = try currentSettings()
            let decision = HelperLogic.notificationDecision(
                for: observed.sourceApp,
                bundleID: observed.sourceBundleID,
                settings: settings,
                at: Date()
            )
            let action = await resolveAction(for: decision, settings: settings)
            let event = NotificationEvent(
                id: UUID().uuidString,
                receivedAt: Self.formatDate(Date()),
                sourceApp: observed.sourceApp,
                title: observed.title,
                body: observed.body,
                isTest: observed.isTest,
                classification: decision.classification,
                triggerReason: .notification,
                actionTaken: action,
                metadata: observed.metadata
            )
            try store.insertEvent(event)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func evaluateDistractions() async {
        do {
            let settings = try currentSettings()
            guard HelperLogic.isFocusActive(on: Date(), settings: settings) else {
                return
            }

            guard let state = await browserTracker.shouldTriggerDistraction(settings: settings) else {
                return
            }

            let action = await firmware.activate(cooldownSeconds: settings.cooldownSeconds)
            await browserTracker.markTriggered(at: Date())

            let event = NotificationEvent(
                id: UUID().uuidString,
                receivedAt: Self.formatDate(Date()),
                sourceApp: "Chrome: \(state.domain)",
                title: "Distraction detected",
                body: state.title,
                isTest: false,
                classification: .distraction,
                triggerReason: .distraction,
                actionTaken: action,
                metadata: [
                    "domain": state.domain,
                    "url": state.url,
                    "captureSource": "chrome-extension",
                ]
            )
            try store.insertEvent(event)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func resolveAction(for decision: RuleDecision, settings: Settings) async -> ActionTaken {
        guard decision.actionRequired else {
            return .ignored
        }

        return await firmware.activate(cooldownSeconds: settings.cooldownSeconds)
    }

    private func emitTestNotification(variant: String) async throws -> NotificationEvent {
        let sourceApp: String
        let title: String
        let body: String

        switch variant {
        case "allowed-work":
            let settings = try currentSettings()
            sourceApp = settings.workAppAllowlist.first ?? "Slack"
            title = "Allowed work notification"
            body = "This test should activate the catapult."
        case "ignored-nonwork":
            sourceApp = "Instagram"
            title = "Ignored non-work notification"
            body = "This test should be recorded but ignored in focus mode."
        default:
            throw NSError(domain: "HelperRuntime", code: 400, userInfo: [NSLocalizedDescriptionKey: "Unknown test notification variant"])
        }

        let escapedBody = body.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let script = #"display notification "\#(escapedBody)" with title "\#(escapedTitle)" subtitle "SillyPlut Test""#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()

        let settings = try currentSettings()
        let decision = HelperLogic.notificationDecision(for: sourceApp, bundleID: nil, settings: settings, at: Date())
        let action = await resolveAction(for: decision, settings: settings)
        let event = NotificationEvent(
            id: UUID().uuidString,
            receivedAt: Self.formatDate(Date()),
            sourceApp: sourceApp,
            title: title,
            body: body,
            isTest: true,
            classification: decision.classification,
            triggerReason: .notification,
            actionTaken: action,
            metadata: ["captureSource": "synthetic-test-fallback", "variant": variant]
        )
        try store.insertEvent(event)
        return event
    }

    private func setLastError(_ message: String) {
        lastError = message
    }

    private func tryOrError(_ work: () async throws -> HTTPResponse) async -> HTTPResponse {
        do {
            return try await work()
        } catch {
            return .error(error.localizedDescription, statusCode: 500)
        }
    }

    static func formatDate(_ date: Date) -> String {
        ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
    }

    static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}

final class LocalHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let router: @Sendable (HTTPRequest) async -> HTTPResponse

    init(port: UInt16, router: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) throws {
        guard let endpoint = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "LocalHTTPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid port"])
        }

        listener = try NWListener(using: .tcp, on: endpoint)
        self.router = router
    }

    func start() throws {
        listener.newConnectionHandler = { [router] connection in
            connection.start(queue: .global())
            Self.receiveRequest(on: connection) { request in
                guard let request else {
                    connection.cancel()
                    return
                }

                Task {
                    let response = await router(request)
                    Self.send(response: response, over: connection)
                }
            }
        }

        listener.start(queue: .global())
    }

    private static func receiveRequest(on connection: NWConnection, completion: @escaping (HTTPRequest?) -> Void) {
        func loop(_ buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if error != nil {
                    completion(nil)
                    return
                }

                var merged = buffer
                if let data {
                    merged.append(data)
                }

                if let request = parseRequest(from: merged) {
                    completion(request)
                    return
                }

                if isComplete {
                    completion(nil)
                    return
                }

                loop(merged)
            }
        }

        loop(Data())
    }

    private static func parseRequest(from data: Data) -> HTTPRequest? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }

        let headerData = data[..<headerRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, let method = HTTPMethod(rawValue: String(parts[0])) else {
            return nil
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }

            let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            headers[name.lowercased()] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        guard data.count - bodyStart >= contentLength else {
            return nil
        }

        let body = Data(data[bodyStart..<(bodyStart + contentLength)])
        let pathWithQuery = String(parts[1])
        let components = URLComponents(string: "http://localhost\(pathWithQuery)")
        let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        return HTTPRequest(
            method: method,
            path: components?.path ?? pathWithQuery,
            query: query,
            headers: headers,
            body: body
        )
    }

    private static func send(response: HTTPResponse, over connection: NWConnection) {
        let statusText: String
        switch response.statusCode {
        case 200: statusText = "OK"
        case 202: statusText = "Accepted"
        case 204: statusText = "No Content"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        default: statusText = "Internal Server Error"
        }

        var headers = [
            "HTTP/1.1 \(response.statusCode) \(statusText)",
            "Content-Type: \(response.contentType)",
            "Content-Length: \(response.body.count)",
            "Connection: close",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: GET,POST,PUT,OPTIONS",
            "Access-Control-Allow-Headers: Content-Type",
        ]

        for (name, value) in response.extraHeaders.sorted(by: { $0.key < $1.key }) {
            headers.append("\(name): \(value)")
        }

        let headerBlob = headers.joined(separator: "\r\n") + "\r\n\r\n"
        var payload = Data(headerBlob.utf8)
        payload.append(response.body)

        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

@main
struct SillypultHelperMain {
    static func main() async {
        let configuration = HelperConfiguration.fromEnvironment()
        let store: SQLiteStore

        do {
            store = try SQLiteStore(path: configuration.databasePath)
        } catch {
            fputs("Could not open store: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }

        let runtime = HelperRuntime(configuration: configuration, store: store)

        do {
            try await runtime.start()
            print("Sillypult helper listening on \(configuration.port)")
            dispatchMain()
        } catch {
            fputs("Helper startup failed: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }
}
