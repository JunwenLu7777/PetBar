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
    case writeFailed(String)
}

extension ZCodeHookConfigurationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidConfig:
            return "ZCode Hook 配置格式无效"
        case .writeFailed(let reason):
            return "写入 ZCode Hook 配置失败：\(reason)"
        }
    }
}

enum ZCodeHookConfiguration {
    private enum ConfigOwnership: String {
        case created
        case existing
    }

    private enum ConfigOwnershipMarker: Equatable {
        case missing
        case current(ConfigOwnership)
        case legacyCreated
        case invalid

        var exists: Bool {
            self != .missing
        }

        var ownership: ConfigOwnership? {
            switch self {
            case .current(let ownership):
                return ownership
            case .legacyCreated:
                return .created
            case .missing, .invalid:
                return nil
            }
        }
    }

    static let managedStatusMessage = "ThreadHelm state observer"
    private static let configOwnershipFilename =
        ".threadhelm-config-owner"
    private static let configOwnershipPrefix =
        "threadhelm-managed-zcode-config-v2:"
    private static let legacyConfigOwnershipContent = Data(
        "threadhelm-managed-zcode-config-v1\n".utf8
    )
    /// 只观测、不干预的事件。它们走 --agent-hook 快速通道，hook 自己以
    /// 亚秒预算为限，到点即放弃上报；注册超时只是兜底。
    static let observationEvents = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PostToolUseFailure",
        "Stop",
    ]

    /// 审批事件走完全不同的形状：另一个旗标、另一套超时预算，而且会
    /// 一直阻塞到用户裁决。混进观测列表会让它按观测那点秒级预算被杀掉，
    /// 然后 fail-open——工具照跑，用户什么都看不到。
    static let permissionEvent = "PermissionRequest"

    static let managedEvents = observationEvents + [permissionEvent]

    static func isPermissionEvent(_ eventName: String) -> Bool {
        eventName == permissionEvent
    }

    static func status(
        at configURL: URL,
        executablePath: String
    ) throws -> AgentIntegrationStatus {
        let manager = FileManager.default
        let ownershipURL = configOwnershipURL(for: configURL)
        let marker = configOwnershipMarker(at: ownershipURL)
        if marker == .legacyCreated || marker == .invalid {
            return .needsRepair
        }
        let markerExists = marker.exists
        let ownership = marker.ownership
        guard manager.fileExists(atPath: configURL.path) else {
            return markerExists ? .needsRepair : .notInstalled
        }
        let config = try loadConfig(at: configURL)
        guard let rawHooks = config["hooks"] else {
            return markerExists ? .needsRepair : .notInstalled
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
            return markerExists ? .needsRepair : .notInstalled
        }
        guard installedEvents == managedEvents,
              ownedEventNames.isSubset(of: Set(managedEvents)),
              !hasLegacyOwnedHook(in: hooks)
        else {
            return .needsRepair
        }
        guard ownership != nil else { return .needsRepair }
        return hooks["enabled"] as? Bool == true ? .installed : .disabled
    }

    @discardableResult
    static func install(
        at configURL: URL,
        executablePath: String,
        isZCodeAvailable: () -> Bool
    ) throws -> Bool {
        guard isZCodeAvailable() else { return false }
        // 令牌必须先于配置落盘：hook 进程一旦被 ZCode 拉起就会立刻去读它，
        // 读不到就只能按拒绝兜底，把用户挡在自己的工具外面。
        try ZCodePermissionTokenStore.ensureToken(
            directory: configURL.deletingLastPathComponent()
        )
        let manager = FileManager.default
        let configurationExisted = manager.fileExists(
            atPath: configURL.path
        )
        let originalConfigData = configurationExisted
            ? try Data(contentsOf: configURL)
            : nil
        let ownershipURL = configOwnershipURL(for: configURL)
        let marker = configOwnershipMarker(at: ownershipURL)
        var config = try loadConfig(at: configURL)
        let legacyOwnedConfiguration = configurationExisted
            && isLegacyFullyOwnedConfiguration(config)
        let desiredOwnership: ConfigOwnership
        switch marker {
        case .current(let ownership):
            desiredOwnership = ownership
        case .legacyCreated:
            desiredOwnership = .created
        case .missing:
            desiredOwnership = (!configurationExisted
                || legacyOwnedConfiguration) ? .created : .existing
        case .invalid:
            desiredOwnership = configurationExisted ? .existing : .created
        }
        var hooks: [String: Any]
        if let rawHooks = config["hooks"] {
            guard let parsedHooks = rawHooks as? [String: Any] else {
                throw ZCodeHookConfigurationError.invalidConfig
            }
            hooks = parsedHooks
        } else {
            hooks = [:]
        }
        if hooks["events"] != nil,
           hooks["events"] as? [String: Any] == nil
        {
            throw ZCodeHookConfigurationError.invalidConfig
        }
        var events = hooks["events"] as? [String: Any] ?? [:]
        let hasAnyOwnedHook = events.values.contains { value in
            guard let matchers = value as? [[String: Any]] else {
                return false
            }
            return !ownedHooks(in: matchers).isEmpty
        } || hasLegacyOwnedHook(in: hooks)

        if hooks["enabled"] as? Bool == false, !hasAnyOwnedHook {
            guard marker == .legacyCreated || marker == .invalid else {
                return false
            }
            try AgentIntegrationAtomicFileWriter.write(
                configOwnershipContent(for: desiredOwnership),
                to: ownershipURL
            )
            return true
        }

        var configChanged = false
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
                configChanged = true
            }
            events[eventName] = matchers
        }
        for eventName in Array(events.keys) where !managedEvents.contains(eventName) {
            if removeOwnedHooks(from: &events, eventName: eventName) {
                configChanged = true
            }
        }
        if removeLegacyOwnedHooks(from: &hooks) { configChanged = true }
        if legacyOwnedConfiguration {
            hooks["enabled"] = true
            configChanged = true
        }
        if desiredOwnership == .created, hooks["enabled"] == nil {
            hooks["enabled"] = true
            configChanged = true
        }
        if !configurationExisted {
            hooks["enabled"] = true
        }
        let markerChanged = marker != .current(desiredOwnership)
        guard configChanged || markerChanged else { return false }
        if configChanged {
            hooks["events"] = events
            config["hooks"] = hooks
            try writeConfig(config, to: configURL)
        }
        if markerChanged {
            do {
                try AgentIntegrationAtomicFileWriter.write(
                    configOwnershipContent(for: desiredOwnership),
                    to: ownershipURL
                )
            } catch {
                if configChanged {
                    if let originalConfigData {
                        try? AgentIntegrationAtomicFileWriter.write(
                            originalConfigData,
                            to: configURL
                        )
                    } else {
                        try? manager.removeItem(at: configURL)
                    }
                }
                throw error
            }
        }
        return true
    }

    @discardableResult
    static func uninstall(at configURL: URL) throws -> Bool {
        let manager = FileManager.default
        ZCodePermissionTokenStore.removeToken(
            directory: configURL.deletingLastPathComponent()
        )
        let ownershipURL = configOwnershipURL(for: configURL)
        let marker = configOwnershipMarker(at: ownershipURL)
        let markerExists = marker.exists
        let ownership = marker.ownership
        let ownsConfig = ownership == .created
        guard manager.fileExists(atPath: configURL.path) else {
            guard markerExists else { return false }
            try manager.removeItem(at: ownershipURL)
            return true
        }
        var config = try loadConfig(at: configURL)
        guard var hooks = config["hooks"] as? [String: Any] else {
            if markerExists, config["hooks"] != nil {
                throw ZCodeHookConfigurationError.invalidConfig
            }
            guard markerExists else { return false }
            if ownsConfig, config.isEmpty {
                try manager.removeItem(at: configURL)
            }
            try manager.removeItem(at: ownershipURL)
            return true
        }
        var configChanged = false
        if ownsConfig, hooks["enabled"] as? Bool == true {
            hooks.removeValue(forKey: "enabled")
            configChanged = true
        }
        if hooks["events"] != nil,
           hooks["events"] as? [String: Any] == nil
        {
            throw ZCodeHookConfigurationError.invalidConfig
        }
        var events = hooks["events"] as? [String: Any] ?? [:]
        for eventName in Array(events.keys) {
            if removeOwnedHooks(from: &events, eventName: eventName) {
                configChanged = true
            }
        }
        if removeLegacyOwnedHooks(from: &hooks) { configChanged = true }
        guard configChanged || markerExists else {
            return false
        }
        if configChanged {
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
            if ownsConfig, config.isEmpty {
                try manager.removeItem(at: configURL)
            } else {
                try writeConfig(config, to: configURL)
            }
        }
        if markerExists {
            try manager.removeItem(at: ownershipURL)
        }
        return true
    }

    private static func configOwnershipURL(for configURL: URL) -> URL {
        configURL.deletingLastPathComponent().appendingPathComponent(
            configOwnershipFilename
        )
    }

    private static func configOwnershipMarker(
        at ownershipURL: URL
    ) -> ConfigOwnershipMarker {
        guard FileManager.default.fileExists(atPath: ownershipURL.path) else {
            return .missing
        }
        guard let data = try? Data(contentsOf: ownershipURL) else {
            return .invalid
        }
        if data == legacyConfigOwnershipContent {
            return .legacyCreated
        }
        guard
              let text = String(data: data, encoding: .utf8),
              text.hasPrefix(configOwnershipPrefix),
              text.hasSuffix("\n")
        else { return .invalid }
        let rawValue = String(
            text.dropFirst(configOwnershipPrefix.count).dropLast()
        )
        guard let ownership = ConfigOwnership(rawValue: rawValue) else {
            return .invalid
        }
        return .current(ownership)
    }

    private static func configOwnershipContent(
        for ownership: ConfigOwnership
    ) -> Data {
        Data("\(configOwnershipPrefix)\(ownership.rawValue)\n".utf8)
    }

    private static func isLegacyFullyOwnedConfiguration(
        _ config: [String: Any]
    ) -> Bool {
        guard Set(config.keys) == ["hooks"],
              let hooks = config["hooks"] as? [String: Any],
              Set(hooks.keys) == ["events"],
              let events = hooks["events"] as? [String: Any],
              // 接入审批闸门之前的 ThreadHelm 只写六个观测事件。那份配置
              // 同样是我们自己写的，卸载时照样该整份移除——只认新形态会
              // 让老用户的配置永远删不干净。
              [Set(observationEvents), Set(managedEvents)]
                  .contains(Set(events.keys))
        else { return false }

        return events.keys.allSatisfy { eventName in
            guard let matchers = events[eventName] as? [[String: Any]],
                  matchers.count == 1,
                  Set(matchers[0].keys) == ["hooks"],
                  let eventHooks = matchers[0]["hooks"] as? [[String: Any]],
                  eventHooks.count == 1,
                  let hook = eventHooks.first,
                  isOwnedHook(hook),
                  let command = hook["command"] as? String,
                  jsonObjectsEqual(
                      hook,
                      managedHook(
                          eventName: eventName,
                          executablePath: command
                      )
                  )
            else { return false }
            return true
        }
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
        if isPermissionEvent(eventName) {
            return [
                "type": "process",
                "command": executablePath,
                "args": [ZCodePermissionHookConstants.flag],
                "timeoutMs": ZCodePermissionHookConstants.hookTimeoutMilliseconds,
                "statusMessage": ZCodePermissionHookConstants.statusMessage,
            ]
        }
        return [
            "type": "process",
            "command": executablePath,
            "args": ["--agent-hook", "zcode", eventName],
            "timeoutMs": AgentHookCommandContract
                .observationHookTimeoutMilliseconds,
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
        guard hook["type"] as? String == "process" else { return false }
        if args == [ZCodePermissionHookConstants.flag] {
            return hook["statusMessage"] as? String
                == ZCodePermissionHookConstants.statusMessage
        }
        return hook["statusMessage"] as? String == managedStatusMessage
            && Array(args.prefix(2)) == ["--agent-hook", "zcode"]
    }

    private static func isExpectedHook(
        _ hook: [String: Any],
        eventName: String,
        executablePath: String
    ) -> Bool {
        guard Set(hook.keys) == Set([
            "type",
            "command",
            "args",
            "timeoutMs",
            "statusMessage",
        ]),
        hook["type"] as? String == "process",
        hook["command"] as? String == executablePath
        else { return false }
        return jsonObjectsEqual(
            hook,
            managedHook(eventName: eventName, executablePath: executablePath)
        )
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
        [
            ".zcode/cli/config.json",
            ".zcode/cli/.threadhelm-config-owner",
            ".zcode/cli/\(ZCodePermissionHookConstants.tokenFileName)",
        ]
    }

    init(
        metadata: AgentMetadata? = builtInAgentMetadata().first {
            $0.id == .zcode
        },
        discovery: @escaping () -> AgentDiscovery = makeGenericAgentDiscoveryProvider(
            agentID: .zcode
        ) {
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
                at: zcodeConfigURL(in: scope, for: .read),
                executablePath: executablePath()
            )
        } catch {
            return agentIntegrationStatusForFailedProbe(error)
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

    func openValidated(session: AgentSessionSnapshot) -> AgentOpenReport {
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
        // 审批事件不走观测通道：它有独立的旗标与阻塞语义，出现在这里
        // 只可能是伪造或错配的信封。
        guard ZCodeHookConfiguration.observationEvents.contains(eventType)
        else {
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

private func zcodeConfigURL(
    in scope: AgentIntegrationScope,
    for access: AgentIntegrationAccess = .write
) throws -> URL {
    try scope.managedURL(relativePath: ".zcode/cli/config.json", for: access)
}

private func zcodeLocalDiscovery(
    executableURL: URL?,
    fileManager: FileManager = .default
) -> AgentDiscovery {
    let bundleURL = zcodeBundleURL(
        executableURL: executableURL,
        fileManager: fileManager
    )
    let info = zcodeBundleVersions(
        bundleURL: bundleURL,
        fileManager: fileManager
    )
    let components = [
        info.version.map {
            AgentVersionComponent(
                key: "version",
                label: "Version",
                value: $0
            )
        },
        info.build.map {
            AgentVersionComponent(
                key: "build",
                label: "build",
                value: $0
            )
        },
    ].compactMap { $0 }
    return versionValidatedAgentDiscovery(
        agentID: .zcode,
        isInstalled: executableURL != nil || bundleURL != nil,
        components: components
    )
}

private func zcodeBundleURL(
    executableURL: URL?,
    fileManager: FileManager
) -> URL? {
    if var candidate = executableURL?.resolvingSymlinksInPath() {
        while candidate.path != "/" {
            if candidate.pathExtension.lowercased() == "app" {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
    }
    let candidates = [
        URL(fileURLWithPath: "/Applications/ZCode.app"),
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/ZCode.app"),
    ]
    return candidates.first { fileManager.fileExists(atPath: $0.path) }
}

private func zcodeBundleVersions(
    bundleURL: URL?,
    fileManager: FileManager
) -> (version: String?, build: String?) {
    guard let bundleURL else { return (nil, nil) }
    let infoURL = bundleURL.appendingPathComponent("Contents/Info.plist")
    guard fileManager.fileExists(atPath: infoURL.path),
          let data = try? Data(contentsOf: infoURL),
          let plist = try? PropertyListSerialization.propertyList(
              from: data,
              options: [],
              format: nil
          ) as? [String: Any]
    else { return (nil, nil) }
    let version = (plist["CFBundleShortVersionString"] as? String)
        .flatMap { normalizedAgentVersion(from: $0) }
    let build = (plist["CFBundleVersion"] as? String)
        .flatMap { normalizedAgentVersion(from: $0) }
    return (version, build)
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
