//
//  CursorAgentAdapter.swift
//  ThreadHelm
//
//  模块职责：Cursor 本地 hooks 的只读发现、隔离配置生命周期、
//  脱敏事件归一化和非精确打开 fallback。
//

import AppKit
import Foundation

struct CursorHookSignal: Equatable {
    let eventType: String
    let sessionID: String?
    let eventID: String
    let sequence: Int?
    let monotonicNanoseconds: UInt64?
    let observedAt: Date
    let terminalTaskError: Bool

    init(
        eventType: String,
        sessionID: String?,
        eventID: String,
        sequence: Int? = nil,
        monotonicNanoseconds: UInt64? = nil,
        observedAt: Date,
        terminalTaskError: Bool = false
    ) {
        self.eventType = eventType
        self.sessionID = sessionID
        self.eventID = eventID
        self.sequence = sequence
        self.monotonicNanoseconds = monotonicNanoseconds
        self.observedAt = observedAt
        self.terminalTaskError = terminalTaskError
    }
}

struct CursorAgentAdapter: AgentAdapter {
    let metadata: AgentMetadata
    private let discoveryProvider: () -> AgentDiscovery
    private let signalReader: () throws -> [CursorHookSignal]
    private let snapshotReader: () throws -> [AgentSessionSnapshot]
    private let openCursorApp: () -> Bool
    private let openWorkingDirectory: (String) -> Bool
    private let hookCommand: String

    init(
        metadata: AgentMetadata? = builtInAgentMetadata().first {
            $0.id == .cursor
        },
        discovery: @escaping () -> AgentDiscovery = makeCursorDiscoveryProvider(),
        signals: @escaping () throws -> [CursorHookSignal] = { [] },
        snapshots: @escaping () throws -> [AgentSessionSnapshot] = { [] },
        hookCommand: String = CursorAgentAdapter.defaultHookCommand(),
        openCursorApp: @escaping () -> Bool = {
            if let running = NSWorkspace.shared.runningApplications.first(
                where: { $0.bundleIdentifier == "com.todesktop.230313mzl4w4u92" }
            ) {
                return running.activate(options: [.activateIgnoringOtherApps])
            }
            return NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Cursor.app"))
        },
        openWorkingDirectory: @escaping (String) -> Bool = {
            NSWorkspace.shared.open(URL(fileURLWithPath: $0, isDirectory: true))
        }
    ) {
        self.metadata = metadata!
        discoveryProvider = discovery
        signalReader = signals
        snapshotReader = snapshots
        self.openCursorApp = openCursorApp
        self.openWorkingDirectory = openWorkingDirectory
        self.hookCommand = hookCommand
    }

    func discover() -> AgentDiscovery {
        discoveryProvider()
    }

    func integrationStatus(in scope: AgentIntegrationScope) -> AgentIntegrationStatus {
        do {
            switch try CursorHookConfiguration.status(
                at: cursorHooksURL(in: scope),
                command: hookCommand
            ) {
            case .installed: return .installed
            case .missing: return .notInstalled
            case .disabled: return .disabled
            case .conflict: return .needsRepair
            }
        } catch {
            return .needsRepair
        }
    }

    func installIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult {
        guard discover().isInstalled else { return .unchanged }
        let url = try cursorHooksURL(in: scope)
        let result = try CursorHookConfiguration.install(
            at: url,
            command: hookCommand
        )
        switch result {
        case .changed: return .installed
        case .unchanged, .disabledRespected: return .unchanged
        }
    }

    func repairIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult {
        guard discover().isInstalled else { return .unchanged }
        let url = try cursorHooksURL(in: scope)
        let result = try CursorHookConfiguration.install(
            at: url,
            command: hookCommand
        )
        switch result {
        case .changed: return .repaired
        case .unchanged, .disabledRespected: return .unchanged
        }
    }

    func uninstallIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult {
        let changed = try CursorHookConfiguration.uninstall(
            at: cursorHooksURL(in: scope)
        )
        return changed ? .uninstalled : .unchanged
    }

    func observe() throws -> AgentObservation {
        let snapshots = try snapshotReader()
        let events = try signalReader().map {
            cursorAgentEvent(
                from: $0,
                adapterVersion: discover().version ?? "unknown"
            )
        }
        guard !events.isEmpty else {
            return AgentObservation(events: [], snapshots: snapshots)
        }
        let reduced = AgentEventReducer.reduce(
            events: events,
            previousSnapshots: snapshots,
            preservingAgentIDs: [metadata.id]
        )
        return AgentObservation(events: events, snapshots: reduced.snapshots)
    }

    func freshness(
        for snapshot: AgentSessionSnapshot,
        now: Date
    ) -> Freshness {
        guard snapshot.identity.agentID == .cursor,
              snapshot.freshness.isStale(at: now)
        else { return snapshot.freshness }
        return Freshness(
            observedAt: snapshot.freshness.observedAt,
            expiresAt: snapshot.freshness.expiresAt,
            staleReason: snapshot.freshness.staleReason ?? "cursor-expired"
        )
    }

    func open(session: AgentSessionSnapshot) -> OpenResult {
        guard session.identity.agentID == .cursor else { return .unavailable }
        if let path = session.workingDirectory,
           openWorkingDirectory(path)
        {
            return .workingDirectoryFallback
        }
        return openCursorApp() ? .appFocused : .unknown
    }

    func diagnostics() -> AgentDiagnostics {
        let discovery = discover()
        return AgentDiagnostics(
            health: discovery.isInstalled ? .healthy : .unavailable,
            summary: discovery.isInstalled ? "已发现 Cursor" : "未发现 Cursor",
            counters: [:]
        )
    }

    private static func defaultHookCommand() -> String {
        let executablePath = Bundle.main.executableURL?.path ?? "ThreadHelm"
        return "\"\(executablePath)\" --agent-hook cursor"
    }
}

private enum CursorHookConfigurationStatus {
    case missing
    case installed
    case disabled
    case conflict
}

private enum CursorHookInstallResult {
    case changed
    case unchanged
    case disabledRespected
}

private enum CursorHookConfiguration {
    static let markerOwner = "ThreadHelm"
    static let markerAgent = "cursor"
    static let ownedEvents = [
        "sessionStart",
        "sessionEnd",
        "beforeSubmitPrompt",
        "preToolUse",
        "postToolUse",
        "postToolUseFailure",
        "stop",
        "subagentStart",
        "subagentStop",
    ]

    static func status(
        at url: URL,
        command: String
    ) throws -> CursorHookConfigurationStatus {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        guard let config = try? readObject(at: url) else {
            return .conflict
        }
        let hooks: [String: Any]
        if let rawHooks = config["hooks"] {
            guard let parsedHooks = rawHooks as? [String: Any] else {
                return .conflict
            }
            hooks = parsedHooks
        } else {
            hooks = [:]
        }
        var foundOwned = false
        var complete = true
        var disabledMode: Bool?
        for event in ownedEvents {
            let entries: [[String: Any]]
            if let rawEntries = hooks[event] {
                guard let parsedEntries = rawEntries as? [[String: Any]] else {
                    complete = false
                    continue
                }
                entries = parsedEntries
            } else {
                entries = []
            }
            let owned = entries.filter(isOwnedEntry)
            if owned.isEmpty {
                complete = false
                continue
            }
            foundOwned = true
            guard owned.count == 1, let entry = owned.first else {
                complete = false
                continue
            }
            let isDisabled = isDisabledEntry(entry)
            if let disabledMode, disabledMode != isDisabled {
                complete = false
            } else {
                disabledMode = isDisabled
            }
            if isDisabled {
                if !isExpectedDisabledEntry(entry, event: event) {
                    complete = false
                }
            } else if !isExpectedEntry(
                entry,
                event: event,
                command: command
            ) {
                complete = false
            }
        }
        let hasUnexpectedOwnedEntry = hooks.contains { event, value in
            guard !ownedEvents.contains(event),
                  let entries = value as? [[String: Any]]
            else { return false }
            return entries.contains(where: isOwnedEntry)
        }
        if hasUnexpectedOwnedEntry {
            foundOwned = true
            complete = false
        }
        if !foundOwned { return .missing }
        guard complete else { return .conflict }
        return disabledMode == true ? .disabled : .installed
    }

    @discardableResult
    static func install(
        at url: URL,
        command: String
    ) throws -> CursorHookInstallResult {
        var config = FileManager.default.fileExists(atPath: url.path)
            ? try readObject(at: url)
            : [:]
        var hooks: [String: Any]
        if let rawHooks = config["hooks"] {
            guard let parsedHooks = rawHooks as? [String: Any] else {
                throw CursorHookConfigurationError.invalidJSON
            }
            hooks = parsedHooks
        } else {
            hooks = [:]
        }
        var changed = config["version"] == nil
        config["version"] = config["version"] ?? 1
        let disabledRequested = hooks.values.contains { value in
            guard let entries = value as? [[String: Any]] else { return false }
            return entries.contains(where: {
                isOwnedEntry($0) && isDisabledEntry($0)
            })
        }

        for event in Array(hooks.keys) where !ownedEvents.contains(event) {
            guard var entries = hooks[event] as? [[String: Any]] else {
                if ownedEvents.contains(event) {
                    throw CursorHookConfigurationError.invalidJSON
                }
                continue
            }
            let previous = entries
            entries.removeAll(where: isOwnedEntry)
            guard !cursorHookEntriesAreEqual(previous, entries) else { continue }
            changed = true
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }

        for event in ownedEvents {
            var entries: [[String: Any]]
            if let rawEntries = hooks[event] {
                guard let parsedEntries = rawEntries as? [[String: Any]] else {
                    throw CursorHookConfigurationError.invalidJSON
                }
                entries = parsedEntries
            } else {
                entries = []
            }
            let previous = entries
            entries.removeAll(where: isOwnedEntry)
            entries.append(
                disabledRequested
                    ? expectedDisabledEntry(for: event)
                    : expectedEntry(for: event, command: command)
            )
            if !cursorHookEntriesAreEqual(previous, entries) {
                changed = true
            }
            hooks[event] = entries
        }

        if disabledRequested && !changed {
            return .disabledRespected
        }
        guard changed else { return .unchanged }
        config["hooks"] = hooks
        try writeObject(config, to: url)
        return .changed
    }

    @discardableResult
    static func uninstall(at url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              var config = try? readObject(at: url)
        else { return false }
        var hooks = config["hooks"] as? [String: Any] ?? [:]
        var changed = false
        for event in Array(hooks.keys) {
            guard var entries = hooks[event] as? [[String: Any]] else {
                continue
            }
            let previous = entries
            entries.removeAll(where: isOwnedEntry)
            if !cursorHookEntriesAreEqual(previous, entries) {
                changed = true
                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }
        }
        guard changed else { return false }
        config["hooks"] = hooks
        try writeObject(config, to: url)
        return true
    }

    private static func expectedEntry(
        for event: String,
        command: String
    ) -> [String: Any] {
        [
            "command": "\(command) \(event)",
            "timeout": 1,
            "threadhelmOwner": markerOwner,
            "threadhelmAgent": markerAgent,
            "threadhelmEvent": event,
        ]
    }

    private static func expectedDisabledEntry(
        for event: String
    ) -> [String: Any] {
        [
            "command": "/usr/bin/true",
            "timeout": 1,
            "threadhelmOwner": markerOwner,
            "threadhelmAgent": markerAgent,
            "threadhelmEvent": event,
            "threadhelmDisabled": true,
        ]
    }

    private static func isExpectedEntry(
        _ entry: [String: Any],
        event: String,
        command: String
    ) -> Bool {
        (entry["command"] as? String) == "\(command) \(event)"
            && (entry["timeout"] as? Int) == 1
            && (entry["threadhelmOwner"] as? String) == markerOwner
            && (entry["threadhelmAgent"] as? String) == markerAgent
            && (entry["threadhelmEvent"] as? String) == event
            && entry["threadhelmDisabled"] == nil
            && !isDisabledEntry(entry)
    }

    private static func isExpectedDisabledEntry(
        _ entry: [String: Any],
        event: String
    ) -> Bool {
        (entry["command"] as? String) == "/usr/bin/true"
            && (entry["timeout"] as? Int) == 1
            && (entry["threadhelmOwner"] as? String) == markerOwner
            && (entry["threadhelmAgent"] as? String) == markerAgent
            && (entry["threadhelmEvent"] as? String) == event
            && (entry["threadhelmDisabled"] as? Bool) == true
            && entry["disabled"] == nil
    }

    private static func isOwnedEntry(_ entry: [String: Any]) -> Bool {
        (entry["threadhelmOwner"] as? String) == markerOwner
            && (entry["threadhelmAgent"] as? String) == markerAgent
    }

    private static func isDisabledEntry(_ entry: [String: Any]) -> Bool {
        entry["threadhelmDisabled"] as? Bool == true
            || entry["disabled"] as? Bool == true
    }

    private static func readObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        else { throw CursorHookConfigurationError.invalidJSON }
        return object
    }

    private static func writeObject(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

private enum CursorHookConfigurationError: Error {
    case invalidJSON
}

private func cursorAgentEvent(
    from signal: CursorHookSignal,
    adapterVersion: String
) -> AgentEvent {
    let mapped = cursorStateMapping(for: signal)
    let nativeID = signal.sessionID.flatMap(cursorToken)
        ?? cursorToken(signal.eventID).map { "unknown-\($0)" }
        ?? "unknown-session"
    return AgentEvent(
        identity: AgentSessionIdentity(
            agentID: .cursor,
            nativeID: nativeID
        ),
        adapterVersion: adapterVersion,
        eventID: cursorToken(signal.eventID) ?? "cursor-event",
        sequence: signal.sequence,
        eventType: cursorToken(signal.eventType) ?? "unknown",
        observedAt: signal.observedAt,
        monotonicNanoseconds: signal.monotonicNanoseconds,
        executionState: mapped.state,
        attentionReason: mapped.reason,
        actionability: mapped.actionability,
        evidenceQuality: mapped.evidence,
        freshness: Freshness(
            observedAt: signal.observedAt,
            expiresAt: signal.observedAt.addingTimeInterval(30 * 60),
            staleReason: mapped.state == .stale ? "cursor-stale" : nil
        ),
        title: "Cursor 会话",
        activitySummary: mapped.summary,
        workingDirectory: nil
    )
}

private func cursorStateMapping(
    for signal: CursorHookSignal
) -> (
    state: ExecutionState,
    reason: AttentionReason,
    actionability: Actionability,
    evidence: EvidenceQuality,
    summary: String?
) {
    if signal.terminalTaskError {
        return (
            .failed,
            .taskFailure,
            .openNativeApp,
            signal.eventType == "stop" ? .officialHook : .inferred,
            "Cursor 报告任务级失败"
        )
    }
    switch signal.eventType {
    case "sessionStart":
        return (.idle, .none, .openNativeApp, .officialHook, "Cursor 会话开始")
    case "sessionEnd":
        return (.completed, .reviewReady, .openNativeApp, .officialHook, "Cursor 会话结束")
    case "beforeSubmitPrompt":
        return (.running, .none, .openNativeApp, .officialHook, "Cursor 已提交任务")
    case "preToolUse", "postToolUse", "postToolUseFailure",
         "beforeShellExecution", "afterShellExecution",
         "beforeMCPExecution", "afterMCPExecution",
         "beforeReadFile", "afterFileEdit":
        return (.running, .none, .openNativeApp, .officialHook, "Cursor 工具事件")
    case "stop":
        return (.completed, .reviewReady, .openNativeApp, .officialHook, "Cursor 已停止")
    case "subagentStart", "subagentStop":
        return (.running, .none, .openNativeApp, .officialHook, "Cursor 子代理事件")
    default:
        return (.running, .none, .openNativeApp, .unknown, "Cursor 未知事件")
    }
}

private func cursorHooksURL(in scope: AgentIntegrationScope) throws -> URL {
    try scope.managedURL(relativePath: ".cursor/hooks.json")
}

private func makeCursorDiscoveryProvider() -> () -> AgentDiscovery {
    let cache = CursorDiscoveryCache()
    return { cache.read() }
}

private final class CursorDiscoveryCache {
    private let lock = NSLock()
    private var cached: AgentDiscovery?

    func read() -> AgentDiscovery {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let version = cursorBundleVersion()
        let installed = version != nil || FileManager.default.fileExists(
            atPath: "/Applications/Cursor.app"
        )
        let discovery = AgentDiscovery(
            isInstalled: installed,
            version: version,
            compatibility: installed ? .supported : .unknown
        )
        cached = discovery
        return discovery
    }

    private func cursorBundleVersion() -> String? {
        let infoURL = URL(fileURLWithPath: "/Applications/Cursor.app")
            .appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any]
        else { return nil }
        return (plist["CFBundleShortVersionString"] as? String)
            ?? (plist["CFBundleVersion"] as? String)
    }
}

private func cursorToken(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 192,
          trimmed.range(
              of: #"^[A-Za-z0-9][A-Za-z0-9._:-]*$"#,
              options: .regularExpression
          ) != nil
    else { return nil }
    return trimmed
}

private func cursorHookEntriesAreEqual(
    _ lhs: [[String: Any]],
    _ rhs: [[String: Any]]
) -> Bool {
    (try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]))
        == (try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys]))
}
