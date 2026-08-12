//
//  ZCodeAgentAdapter.swift
//  ThreadHelm
//
//  模块职责：ZCode 本地生命周期适配器。只做状态观察、配置生命周期和安全打开
//  fallback；不注册 PermissionRequest，不声明 exact return。
//

import AppKit
import Darwin
import Foundation

struct ZCodeHookEnvelope: Codable, Equatable {
    let eventID: String?
    let sessionID: String?
    let sequence: Int?
    let eventType: String
    let observedAt: Date?
    let monotonicNanoseconds: UInt64?
    let outcome: String?

    init(
        eventID: String? = nil,
        sessionID: String? = nil,
        sequence: Int? = nil,
        eventType: String,
        observedAt: Date? = nil,
        monotonicNanoseconds: UInt64? = nil,
        outcome: String? = nil
    ) {
        self.eventID = eventID
        self.sessionID = sessionID
        self.sequence = sequence
        self.eventType = eventType
        self.observedAt = observedAt
        self.monotonicNanoseconds = monotonicNanoseconds
        self.outcome = outcome
    }
}

enum ZCodeHookConfigurationError: Error, Equatable {
    case invalidConfig
}

enum ZCodeHookConfiguration {
    static let managedStatusMessage = "ThreadHelm state observer"
    static let managedEvents = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PostToolUseFailure",
        "Stop",
    ]

    static func status(
        at configURL: URL,
        executablePath: String
    ) throws -> AgentIntegrationStatus {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return .notInstalled
        }
        let config = try loadConfig(at: configURL)
        guard let rawHooks = config["hooks"] else {
            return .notInstalled
        }
        guard let hooks = rawHooks as? [String: Any] else {
            throw ZCodeHookConfigurationError.invalidConfig
        }
        let events: [String: Any]
        if let rawEvents = hooks["events"] {
            guard let parsedEvents = rawEvents as? [String: Any] else {
                throw ZCodeHookConfigurationError.invalidConfig
            }
            events = parsedEvents
        } else {
            events = [:]
        }
        let installedEvents = managedEvents.filter { eventName in
            let matchers = events[eventName] as? [[String: Any]] ?? []
            return ownedHooks(in: matchers).count == 1
                && ownedHooks(in: matchers).allSatisfy {
                    isExpectedHook(
                        $0,
                        eventName: eventName,
                        executablePath: executablePath
                    )
                }
        }
        for eventName in managedEvents where events[eventName] != nil {
            guard events[eventName] is [[String: Any]] else {
                throw ZCodeHookConfigurationError.invalidConfig
            }
        }
        let ownedEventNames = Set(events.compactMap { eventName, value -> String? in
            guard let matchers = value as? [[String: Any]],
                  !ownedHooks(in: matchers).isEmpty
            else { return nil }
            return eventName
        })
        let hasAnyOwnedHook = !ownedEventNames.isEmpty || hasLegacyOwnedHook(in: hooks)
        if !hasAnyOwnedHook {
            if hooks["enabled"] as? Bool == false {
                return .disabled
            }
            return .notInstalled
        }
        guard installedEvents == managedEvents,
              ownedEventNames.isSubset(of: Set(managedEvents)),
              !hasLegacyOwnedHook(in: hooks)
        else {
            return .needsRepair
        }
        return hooks["enabled"] as? Bool == true ? .installed : .disabled
    }

    @discardableResult
    static func install(
        at configURL: URL,
        executablePath: String,
        isZCodeAvailable: () -> Bool
    ) throws -> Bool {
        guard isZCodeAvailable() else { return false }
        var config = try loadConfig(at: configURL)
        var hooks: [String: Any]
        if let rawHooks = config["hooks"] {
            guard let parsedHooks = rawHooks as? [String: Any] else {
                throw ZCodeHookConfigurationError.invalidConfig
            }
            hooks = parsedHooks
        } else {
            hooks = [:]
        }
        if hooks["enabled"] as? Bool == false {
            return false
        }
        if hooks["events"] != nil,
           hooks["events"] as? [String: Any] == nil
        {
            throw ZCodeHookConfigurationError.invalidConfig
        }
        var events = hooks["events"] as? [String: Any] ?? [:]

        var changed = false
        for eventName in managedEvents {
            let hook = managedHook(
                eventName: eventName,
                executablePath: executablePath
            )
            let matchersValue = events[eventName]
            if matchersValue != nil, !(matchersValue is [[String: Any]]) {
                throw ZCodeHookConfigurationError.invalidConfig
            }
            var matchers = matchersValue as? [[String: Any]] ?? []
            if replaceOwnedHook(hook, in: &matchers) {
                changed = true
            }
            events[eventName] = matchers
        }
        for eventName in Array(events.keys) where !managedEvents.contains(eventName) {
            if removeOwnedHooks(from: &events, eventName: eventName) {
                changed = true
            }
        }
        if removeLegacyOwnedHooks(from: &hooks) { changed = true }
        guard changed else { return false }
        hooks["events"] = events
        config["hooks"] = hooks
        try writeConfig(config, to: configURL)
        return true
    }

    @discardableResult
    static func uninstall(at configURL: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return false
        }
        var config = try loadConfig(at: configURL)
        guard var hooks = config["hooks"] as? [String: Any] else {
            return false
        }
        if hooks["events"] != nil,
           hooks["events"] as? [String: Any] == nil
        {
            throw ZCodeHookConfigurationError.invalidConfig
        }
        var events = hooks["events"] as? [String: Any] ?? [:]
        var changed = false
        for eventName in Array(events.keys) {
            if removeOwnedHooks(from: &events, eventName: eventName) {
                changed = true
            }
        }
        if removeLegacyOwnedHooks(from: &hooks) { changed = true }
        guard changed else { return false }
        if events.isEmpty {
            hooks.removeValue(forKey: "events")
        } else {
            hooks["events"] = events
        }
        if hooks.isEmpty {
            config.removeValue(forKey: "hooks")
        } else {
            config["hooks"] = hooks
        }
        try writeConfig(config, to: configURL)
        return true
    }

    private static func loadConfig(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }
        let data = try Data(contentsOf: url)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let config = object as? [String: Any]
        else {
            throw ZCodeHookConfigurationError.invalidConfig
        }
        return config
    }

    private static func writeConfig(
        _ config: [String: Any],
        to url: URL
    ) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let originalData = manager.fileExists(atPath: url.path)
            ? try Data(contentsOf: url)
            : nil
        let data = try ZCodeOrderedJSON.data(
            withJSONObject: config,
            preservingOrderFrom: originalData
        )
        try AgentIntegrationAtomicFileWriter.write(data, to: url)
    }

    private static func managedHook(
        eventName: String,
        executablePath: String
    ) -> [String: Any] {
        [
            "type": "process",
            "command": executablePath,
            "args": ["--agent-hook", "zcode", eventName],
            "timeoutMs": 250,
            "statusMessage": managedStatusMessage,
        ]
    }

    private static func replaceOwnedHook(
        _ replacement: [String: Any],
        in matchers: inout [[String: Any]]
    ) -> Bool {
        var changed = false
        var outputMatchers: [[String: Any]] = []
        var replaced = false
        for originalMatcher in matchers {
            guard let originalHooks = originalMatcher["hooks"]
                as? [[String: Any]]
            else {
                outputMatchers.append(originalMatcher)
                continue
            }
            var matcher = originalMatcher
            var outputHooks: [[String: Any]] = []
            for hook in originalHooks {
                if isOwnedHook(hook) {
                    if !replaced {
                        outputHooks.append(replacement)
                        replaced = true
                        if !jsonObjectsEqual(hook, replacement) {
                            changed = true
                        }
                    } else {
                        changed = true
                    }
                } else {
                    outputHooks.append(hook)
                }
            }
            matcher["hooks"] = outputHooks
            outputMatchers.append(matcher)
        }
        if !replaced {
            outputMatchers.append(["hooks": [replacement]])
            changed = true
        }
        matchers = outputMatchers
        return changed
    }

    private static func removeOwnedHooks(
        from events: inout [String: Any],
        eventName: String
    ) -> Bool {
        guard let matchers = events[eventName] as? [[String: Any]] else {
            return false
        }
        var changed = false
        var outputMatchers: [[String: Any]] = []
        for originalMatcher in matchers {
            guard let originalHooks = originalMatcher["hooks"]
                as? [[String: Any]]
            else {
                outputMatchers.append(originalMatcher)
                continue
            }
            let remainingHooks = originalHooks.filter { !isOwnedHook($0) }
            if remainingHooks.count != originalHooks.count { changed = true }
            guard !remainingHooks.isEmpty else { continue }
            var matcher = originalMatcher
            matcher["hooks"] = remainingHooks
            outputMatchers.append(matcher)
        }
        guard changed else { return false }
        if outputMatchers.isEmpty {
            events.removeValue(forKey: eventName)
        } else {
            events[eventName] = outputMatchers
        }
        return true
    }

    private static func ownedHooks(
        in matchers: [[String: Any]]
    ) -> [[String: Any]] {
        matchers.flatMap { matcher in
            (matcher["hooks"] as? [[String: Any]] ?? []).filter(isOwnedHook)
        }
    }

    private static func isOwnedHook(_ hook: [String: Any]) -> Bool {
        let args = hook["args"] as? [String] ?? []
        return hook["type"] as? String == "process"
            && hook["statusMessage"] as? String == managedStatusMessage
            && Array(args.prefix(2)) == ["--agent-hook", "zcode"]
    }

    private static func isExpectedHook(
        _ hook: [String: Any],
        eventName: String,
        executablePath: String
    ) -> Bool {
        Set(hook.keys) == Set([
            "type",
            "command",
            "args",
            "timeoutMs",
            "statusMessage",
        ])
            && hook["type"] as? String == "process"
            && hook["command"] as? String == executablePath
            && hook["args"] as? [String]
                == ["--agent-hook", "zcode", eventName]
            && hook["timeoutMs"] as? Int == 250
            && hook["statusMessage"] as? String == managedStatusMessage
    }

    private static func hasLegacyOwnedHook(
        in hooks: [String: Any]
    ) -> Bool {
        hooks.contains { key, value in
            guard key != "events" else { return false }
            let entries = value as? [[String: Any]] ?? []
            return entries.contains(where: isLegacyOwnedEntry)
        }
    }

    @discardableResult
    private static func removeLegacyOwnedHooks(
        from hooks: inout [String: Any]
    ) -> Bool {
        var changed = false
        for eventName in Array(hooks.keys) where eventName != "events" {
            guard let entries = hooks[eventName] as? [[String: Any]] else {
                continue
            }
            let remaining = entries.filter { !isLegacyOwnedEntry($0) }
            guard remaining.count != entries.count else { continue }
            changed = true
            if remaining.isEmpty {
                hooks.removeValue(forKey: eventName)
            } else {
                hooks[eventName] = remaining
            }
        }
        return changed
    }

    private static func isLegacyOwnedEntry(_ entry: [String: Any]) -> Bool {
        guard let marker = entry["threadHelm"] as? [String: Any] else {
            return false
        }
        return marker["owned"] as? Bool == true
            && marker["adapter"] as? String == "zcode"
    }

    private static func jsonObjectsEqual(
        _ lhs: [String: Any],
        _ rhs: [String: Any]
    ) -> Bool {
        guard JSONSerialization.isValidJSONObject(lhs),
              JSONSerialization.isValidJSONObject(rhs),
              let lhsData = try? JSONSerialization.data(
                  withJSONObject: lhs,
                  options: [.sortedKeys]
              ),
              let rhsData = try? JSONSerialization.data(
                  withJSONObject: rhs,
                  options: [.sortedKeys]
              )
        else { return false }
        return lhsData == rhsData
    }

}

struct ZCodeAgentAdapter: AgentAdapter {
    let metadata: AgentMetadata
    private let discoveryProvider: () -> AgentDiscovery
    private let readEnvelopeData: () throws -> [Data]
    private let now: () -> Date
    private let executablePath: () -> String
    private let activateApplication: () -> OpenResult
    private let openWorkingDirectory: (String) -> Bool

    var managedIntegrationRelativePaths: [String] {
        [".zcode/cli/config.json"]
    }

    init(
        metadata: AgentMetadata? = builtInAgentMetadata().first {
            $0.id == .zcode
        },
        discovery: @escaping () -> AgentDiscovery = {
            zcodeLocalDiscovery(executableURL: locateZCodeExecutable())
        },
        readEnvelopeData: @escaping () throws -> [Data] = { [] },
        now: @escaping () -> Date = Date.init,
        executablePath: @escaping () -> String = {
            Bundle.main.executableURL?.path ?? "/usr/bin/true"
        },
        activateApplication: @escaping () -> OpenResult = openZCodeApplication,
        openWorkingDirectory: @escaping (String) -> Bool = openDirectoryInFinder
    ) {
        self.metadata = metadata!
        discoveryProvider = discovery
        self.readEnvelopeData = readEnvelopeData
        self.now = now
        self.executablePath = executablePath
        self.activateApplication = activateApplication
        self.openWorkingDirectory = openWorkingDirectory
    }

    func discover() -> AgentDiscovery {
        discoveryProvider()
    }

    func integrationStatus(in scope: AgentIntegrationScope) -> AgentIntegrationStatus {
        do {
            return try ZCodeHookConfiguration.status(
                at: zcodeConfigURL(in: scope),
                executablePath: executablePath()
            )
        } catch {
            return .needsRepair
        }
    }

    func installIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult {
        let changed = try ZCodeHookConfiguration.install(
            at: zcodeConfigURL(in: scope),
            executablePath: executablePath(),
            isZCodeAvailable: { discover().isInstalled }
        )
        return changed ? .installed : .unchanged
    }

    func repairIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult {
        let changed = try ZCodeHookConfiguration.install(
            at: zcodeConfigURL(in: scope),
            executablePath: executablePath(),
            isZCodeAvailable: { discover().isInstalled }
        )
        return changed ? .repaired : .unchanged
    }

    func uninstallIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult {
        let changed = try ZCodeHookConfiguration.uninstall(
            at: zcodeConfigURL(in: scope)
        )
        return changed ? .uninstalled : .unchanged
    }

    func observe() throws -> AgentObservation {
        let envelopes = (try? readEnvelopeData()) ?? []
        let events = envelopes.compactMap { data -> AgentEvent? in
            guard let envelope = try? JSONDecoder.threadHelmAgent
                .decode(ZCodeHookEnvelope.self, from: data)
            else { return nil }
            return normalizedEvent(from: envelope)
        }
        let reduction = AgentEventReducer.reduce(events: events)
        let snapshots = reduction.snapshots.map { snapshot in
            staleAdjusted(snapshot)
        }.sorted(by: agentSnapshotIsOrderedBefore)
        return AgentObservation(events: events, snapshots: snapshots)
    }

    func freshness(
        for snapshot: AgentSessionSnapshot,
        now: Date
    ) -> Freshness {
        if snapshot.freshness.isStale(at: now) {
            return Freshness(
                observedAt: snapshot.freshness.observedAt,
                expiresAt: snapshot.freshness.expiresAt,
                staleReason: snapshot.freshness.staleReason
                    ?? "zcode-session-expired"
            )
        }
        return snapshot.freshness
    }

    func open(session: AgentSessionSnapshot) -> AgentOpenReport {
        guard session.identity.agentID == .zcode else {
            return AgentOpenReport(
                agentID: metadata.id,
                advertisedActionability: session.actionability,
                result: .unavailable,
                invokedExactTarget: false,
                independentlyConfirmedIdentity: false
            )
        }
        let appResult = activateApplication()
        let result: OpenResult
        switch appResult {
        case .appFocused, .unknown:
            result = appResult
        case .exactSession, .workingDirectoryFallback:
            result = appResult
        case .unavailable, .failed, .notAttempted:
            if let workingDirectory = session.workingDirectory,
               openWorkingDirectory(workingDirectory)
            {
                result = .workingDirectoryFallback
            } else {
                result = appResult == .unavailable ? .unavailable : .failed
            }
        }
        return AgentOpenReport(
            agentID: metadata.id,
            advertisedActionability: session.actionability,
            result: result,
            invokedExactTarget: false,
            independentlyConfirmedIdentity: false
        )
    }

    func diagnostics() -> AgentDiagnostics {
        let discovery = discover()
        return AgentDiagnostics(
            health: discovery.isInstalled ? .healthy : .unavailable,
            summary: discovery.isInstalled ? "已发现 ZCode" : "未发现 ZCode",
            counters: [:]
        )
    }

    private func normalizedEvent(from envelope: ZCodeHookEnvelope) -> AgentEvent? {
        let observedAt = envelope.observedAt ?? now()
        let eventType = envelope.eventType
        guard ZCodeHookConfiguration.managedEvents.contains(eventType) else {
            return nil
        }
        let nativeID = sanitizedIdentity(envelope.sessionID)
            ?? "zcode-event-\((envelope.eventID ?? UUID().uuidString).prefix(32))"
        let stateAndReason = normalizedZCodeStateAndReason(
            eventType: eventType,
            outcome: envelope.outcome
        )
        return AgentEvent(
            identity: AgentSessionIdentity(
                agentID: .zcode,
                nativeID: nativeID
            ),
            adapterVersion: discover().version ?? "unknown",
            eventID: envelope.eventID
                ?? "\(nativeID):\(eventType):\(Int(observedAt.timeIntervalSince1970))",
            sequence: envelope.sequence,
            eventType: eventType,
            observedAt: observedAt,
            monotonicNanoseconds: envelope.monotonicNanoseconds,
            executionState: stateAndReason.state,
            attentionReason: stateAndReason.reason,
            actionability: stateAndReason.actionability,
            evidenceQuality: stateAndReason.evidence,
            freshness: Freshness(
                observedAt: observedAt,
                expiresAt: stateAndReason.state == .running
                    || stateAndReason.state == .idle
                    ? observedAt.addingTimeInterval(15 * 60)
                    : nil
            ),
            title: "ZCode",
            activitySummary: nil,
            workingDirectory: nil
        )
    }

    private func staleAdjusted(
        _ snapshot: AgentSessionSnapshot
    ) -> AgentSessionSnapshot {
        guard snapshot.freshness.isStale(at: now()),
              snapshot.executionState != .completed,
              snapshot.executionState != .failed
        else { return snapshot }
        let freshness = Freshness(
            observedAt: snapshot.freshness.observedAt,
            expiresAt: snapshot.freshness.expiresAt,
            staleReason: snapshot.freshness.staleReason
                ?? "zcode-session-expired"
        )
        return AgentSessionSnapshot(
            identity: snapshot.identity,
            adapterVersion: snapshot.adapterVersion,
            executionState: .stale,
            attentionReason: .none,
            actionability: .viewOnly,
            evidenceQuality: .inferred,
            freshness: freshness,
            title: snapshot.title,
            activitySummary: snapshot.activitySummary,
            workingDirectory: snapshot.workingDirectory,
            latestEventID: snapshot.latestEventID,
            updatedAt: snapshot.updatedAt
        )
    }
}

private func normalizedZCodeStateAndReason(
    eventType: String,
    outcome: String?
) -> (
    state: ExecutionState,
    reason: AttentionReason,
    actionability: Actionability,
    evidence: EvidenceQuality
) {
    let normalizedOutcome = outcome?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    switch eventType {
    case "SessionStart":
        return (.idle, .none, .openNativeApp, .officialHook)
    case "UserPromptSubmit", "PreToolUse", "PostToolUse":
        return (.running, .none, .openNativeApp, .officialHook)
    case "PostToolUseFailure":
        return (.running, .none, .openNativeApp, .inferred)
    case "Stop":
        switch normalizedOutcome {
        case "taskerror", "task_error", "task-failure", "taskfailure",
             "failed", "failure", "error":
            return (.failed, .taskFailure, .openNativeApp, .inferred)
        case "success", "succeeded", "completed", "complete":
            return (.completed, .reviewReady, .openNativeApp, .officialHook)
        default:
            return (.running, .none, .openNativeApp, .inferred)
        }
    default:
        return (.running, .none, .openNativeApp, .inferred)
    }
}

private func zcodeConfigURL(in scope: AgentIntegrationScope) throws -> URL {
    try scope.managedURL(relativePath: ".zcode/cli/config.json")
}

private func zcodeLocalDiscovery(executableURL: URL?) -> AgentDiscovery {
    guard executableURL != nil else {
        return AgentDiscovery(
            isInstalled: false,
            version: nil,
            compatibility: .unknown
        )
    }
    return AgentDiscovery(
        isInstalled: true,
        version: nil,
        compatibility: .supported
    )
}

private func sanitizedIdentity(_ value: String?) -> String? {
    guard let value = value?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !value.isEmpty
    else { return nil }
    return String(value.prefix(128))
}

private func locateZCodeExecutable(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    isExecutableFile: (String) -> Bool = {
        FileManager.default.isExecutableFile(atPath: $0)
    }
) -> URL? {
    let pathCandidates = executablePathsForZCode(
        named: "zcode",
        pathEnvironment: environment["PATH"]
    )
    let candidatePaths: [String?] = [
        environment["ZCODE_BIN"],
    ] + pathCandidates.map(Optional.some) + [
        homeDirectory.appendingPathComponent(".local/bin/zcode").path,
        homeDirectory
            .appendingPathComponent("Applications/ZCode.app/Contents/MacOS/ZCode")
            .path,
        "/Applications/ZCode.app/Contents/MacOS/ZCode",
        "/opt/homebrew/bin/zcode",
        "/usr/local/bin/zcode",
    ]
    let candidates = candidatePaths.compactMap { path -> String? in
        guard let path, !path.isEmpty else { return nil }
        return path
    }
    return candidates.first(where: isExecutableFile)
        .map(URL.init(fileURLWithPath:))
}

private func executablePathsForZCode(
    named executableName: String,
    pathEnvironment: String?
) -> [String] {
    guard let pathEnvironment, !pathEnvironment.isEmpty else { return [] }
    return pathEnvironment
        .split(separator: ":", omittingEmptySubsequences: true)
        .map {
            URL(fileURLWithPath: String($0), isDirectory: true)
                .appendingPathComponent(executableName)
                .path
        }
}

private func openZCodeApplication() -> OpenResult {
    let bundleIdentifier = "dev.zcode.app"
    if let running = NSRunningApplication.runningApplications(
        withBundleIdentifier: bundleIdentifier
    ).first {
        return running.activate(options: [
            .activateAllWindows,
            .activateIgnoringOtherApps,
        ]) ? .appFocused : .failed
    }
    if let appURL = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: bundleIdentifier
    ) {
        // Launch dispatch cannot prove that a specific ZCode window focused.
        return NSWorkspace.shared.open(appURL) ? .unknown : .failed
    }
    return .unavailable
}

private func openDirectoryInFinder(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(
        atPath: path,
        isDirectory: &isDirectory
    ), isDirectory.boolValue
    else { return false }
    return NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
}

private extension JSONDecoder {
    static var threadHelmAgent: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
