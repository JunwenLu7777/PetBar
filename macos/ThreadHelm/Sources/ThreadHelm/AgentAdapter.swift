//
//  AgentAdapter.swift
//  ThreadHelm
//
//  模块职责：定义 Agent 发现、集成生命周期、观察、打开和诊断契约。
//

import AppKit
import Foundation

enum AgentCompatibility: String, Equatable {
    case supported
    case unsupportedVersion
    case unknown
}

struct AgentDiscovery: Equatable {
    let isInstalled: Bool
    let version: String?
    let compatibility: AgentCompatibility
}

enum AgentIntegrationStatus: String, Codable, Equatable {
    case notManaged
    case notInstalled
    case installed
    case disabled
    case needsRepair
    case unsupportedVersion
}

enum AgentIntegrationOperationResult: String, Codable, Equatable {
    case notManaged
    case unchanged
    case installed
    case repaired
    case uninstalled
}

struct AgentIntegrationScope: Equatable {
    let rootDirectory: URL
    let permitsLiveConfigurationChanges: Bool

    static func isolated(at rootDirectory: URL) -> AgentIntegrationScope {
        AgentIntegrationScope(
            rootDirectory: rootDirectory,
            permitsLiveConfigurationChanges: false
        )
    }
}

enum AgentIntegrationError: Error, Equatable {
    case liveConfigurationWriteDenied
    case invalidManagedPath
}

extension AgentIntegrationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .liveConfigurationWriteDenied:
            return "隔离操作不能写入真实主目录"
        case .invalidManagedPath:
            return "受管配置路径不安全"
        }
    }
}

extension AgentIntegrationScope {
    func managedURL(relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..")
        else {
            throw AgentIntegrationError.invalidManagedPath
        }
        let root = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard root.path != "/" else {
            throw AgentIntegrationError.invalidManagedPath
        }
        if !permitsLiveConfigurationChanges,
           root == FileManager.default.homeDirectoryForCurrentUser
                .standardizedFileURL
                .resolvingSymlinksInPath()
        {
            throw AgentIntegrationError.liveConfigurationWriteDenied
        }
        let candidate = root.appendingPathComponent(relativePath)
            .standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else {
            throw AgentIntegrationError.invalidManagedPath
        }
        return candidate
    }
}

struct AgentObservation: Equatable {
    let events: [AgentEvent]
    let snapshots: [AgentSessionSnapshot]
}

enum AgentHealth: String, Equatable {
    case healthy
    case degraded
    case unavailable
    case unknown
}

struct AgentDiagnostics: Equatable {
    let health: AgentHealth
    let summary: String
    let counters: [String: Int]
}

struct AgentRuntimeStatus: Equatable {
    let metadata: AgentMetadata
    let discovery: AgentDiscovery
    let integrationStatus: AgentIntegrationStatus?
    let diagnostics: AgentDiagnostics
    let activeSessionCount: Int
    let attentionCount: Int
}

func agentRuntimeStatusPlaceholders(
    registry: AgentRegistry = .builtIn
) -> [AgentRuntimeStatus] {
    registry.agentIDs.compactMap { agentID in
        guard let metadata = registry.metadata(for: agentID) else { return nil }
        let integrationStatus: AgentIntegrationStatus? = metadata.capabilities
            .status(for: .managedIntegration) == .unsupported
            ? .notManaged
            : nil
        return AgentRuntimeStatus(
            metadata: metadata,
            discovery: AgentDiscovery(
                isInstalled: false,
                version: nil,
                compatibility: .unknown
            ),
            integrationStatus: integrationStatus,
            diagnostics: AgentDiagnostics(
                health: .unknown,
                summary: "尚未检查",
                counters: [:]
            ),
            activeSessionCount: 0,
            attentionCount: 0
        )
    }
}

func probedAgentRuntimeStatuses(
    registry: AgentRegistry = .builtIn,
    preserving previousStatuses: [AgentRuntimeStatus] = []
) -> [AgentRuntimeStatus] {
    let previousByID = Dictionary(
        uniqueKeysWithValues: previousStatuses.map { ($0.metadata.id, $0) }
    )
    return registry.agentIDs.compactMap { agentID in
        guard let adapter = registry.adapter(for: agentID) else { return nil }
        let previous = previousByID[agentID]
        let integrationStatus: AgentIntegrationStatus?
        if adapter.metadata.capabilities.status(for: .managedIntegration)
            == .unsupported
        {
            integrationStatus = .notManaged
        } else {
            // Reading a live vendor configuration is deliberately deferred to
            // the explicit integration lifecycle. Discovery must not silently
            // become permission to inspect or mutate user configuration.
            integrationStatus = previous?.integrationStatus
        }
        return AgentRuntimeStatus(
            metadata: adapter.metadata,
            discovery: adapter.discover(),
            integrationStatus: integrationStatus,
            diagnostics: adapter.diagnostics(),
            activeSessionCount: previous?.activeSessionCount ?? 0,
            attentionCount: previous?.attentionCount ?? 0
        )
    }
}

func agentRuntimeStatusesWithActivity(
    _ statuses: [AgentRuntimeStatus],
    snapshots: [AgentSessionSnapshot],
    attentionItems: [AgentAttentionItem]
) -> [AgentRuntimeStatus] {
    statuses.map { status in
        let agentID = status.metadata.id
        let activeCount = snapshots.filter {
            $0.identity.agentID == agentID
                && ($0.executionState == .discovering
                    || $0.executionState == .running)
        }.count
        let attentionCount = attentionItems.filter {
            $0.identity.agentID == agentID
                && AgentAttentionPolicy.shouldInterrupt(
                    reason: $0.reason,
                    evidenceQuality: $0.evidenceQuality
                )
        }.count
        return AgentRuntimeStatus(
            metadata: status.metadata,
            discovery: status.discovery,
            integrationStatus: status.integrationStatus,
            diagnostics: status.diagnostics,
            activeSessionCount: activeCount,
            attentionCount: attentionCount
        )
    }
}

protocol AgentAdapter {
    var metadata: AgentMetadata { get }
    var managedIntegrationRelativePaths: [String] { get }
    func discover() -> AgentDiscovery
    func integrationStatus(in scope: AgentIntegrationScope) -> AgentIntegrationStatus
    func installIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult
    func repairIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult
    func uninstallIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult
    func observe() throws -> AgentObservation
    func freshness(
        for snapshot: AgentSessionSnapshot,
        now: Date
    ) -> Freshness
    func open(session: AgentSessionSnapshot) -> AgentOpenReport
    func diagnostics() -> AgentDiagnostics
}

extension AgentAdapter {
    var managedIntegrationRelativePaths: [String] { [] }

    func discover() -> AgentDiscovery {
        AgentDiscovery(
            isInstalled: false,
            version: nil,
            compatibility: .unknown
        )
    }

    func integrationStatus(in scope: AgentIntegrationScope) -> AgentIntegrationStatus {
        .notManaged
    }

    func installIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult {
        .notManaged
    }

    func repairIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult {
        .notManaged
    }

    func uninstallIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult {
        .notManaged
    }

    func observe() throws -> AgentObservation {
        AgentObservation(events: [], snapshots: [])
    }

    func freshness(
        for snapshot: AgentSessionSnapshot,
        now: Date
    ) -> Freshness {
        snapshot.freshness
    }

    func open(session: AgentSessionSnapshot) -> AgentOpenReport {
        AgentOpenReport(
            agentID: metadata.id,
            advertisedActionability: session.actionability,
            result: .unavailable,
            invokedExactTarget: false,
            independentlyConfirmedIdentity: false
        )
    }

    func diagnostics() -> AgentDiagnostics {
        AgentDiagnostics(
            health: .unknown,
            summary: "尚未检查",
            counters: [:]
        )
    }
}

struct DescriptorAgentAdapter: AgentAdapter {
    let metadata: AgentMetadata
}

func builtInAgentAdapters() -> [any AgentAdapter] {
    let metadata = builtInAgentMetadata()
    let indexed = Dictionary(uniqueKeysWithValues: metadata.map { ($0.id, $0) })
    return [
        CodexAgentAdapter(metadata: indexed[.codex]!),
        ClaudeCodeAgentAdapter(metadata: indexed[.claudeCode]!),
        CursorAgentAdapter(metadata: indexed[.cursor]!),
        ZCodeAgentAdapter(metadata: indexed[.zcode]!),
        PiAgentAdapter(metadata: indexed[.pi]!),
    ]
}

func claudeAttentionReason(
    for interactionKind: ClaudePermissionInteractionKind
) -> AttentionReason {
    switch interactionKind {
    case .toolApproval: return .permission
    case .askUserQuestion: return .question
    case .exitPlanMode: return .planApproval
    }
}

struct CodexAgentAdapter: AgentAdapter {
    let metadata: AgentMetadata
    private let readCollection: () -> TaskProgressCollectionSnapshot
    private let discoveryProvider: () -> AgentDiscovery
    private let openURL: (URL) -> Bool

    init(
        metadata: AgentMetadata? = builtInAgentMetadata().first {
            $0.id == .codex
        },
        reader: CodexTaskProgressReader = CodexTaskProgressReader(),
        discovery: @escaping () -> AgentDiscovery = makeLocalAgentDiscoveryProvider {
            locateCodexExecutable()
        },
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.init(
            metadata: metadata,
            readCollection: { reader.readCollection() },
            discovery: discovery,
            openURL: openURL
        )
    }

    init(
        metadata: AgentMetadata? = builtInAgentMetadata().first {
            $0.id == .codex
        },
        readCollection: @escaping () -> TaskProgressCollectionSnapshot,
        discovery: @escaping () -> AgentDiscovery = makeLocalAgentDiscoveryProvider {
            locateCodexExecutable()
        },
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.metadata = metadata!
        self.readCollection = readCollection
        discoveryProvider = discovery
        self.openURL = openURL
    }

    func discover() -> AgentDiscovery {
        discoveryProvider()
    }

    func observe() throws -> AgentObservation {
        observation(
            from: readCollection().items,
            permissionQueue: .empty
        )
    }

    func readTaskProgressCollection() -> TaskProgressCollectionSnapshot {
        readCollection()
    }

    func open(session: AgentSessionSnapshot) -> AgentOpenReport {
        guard session.identity.agentID == .codex,
              let url = codexThreadURL(threadID: session.identity.nativeID)
        else {
            return AgentOpenReport(
                agentID: metadata.id,
                advertisedActionability: session.actionability,
                result: .unavailable,
                invokedExactTarget: false,
                independentlyConfirmedIdentity: false
            )
        }
        // NSWorkspace only confirms dispatch of the deep link. A future
        // independent destination check may upgrade this result to exact.
        return AgentOpenReport(
            agentID: metadata.id,
            advertisedActionability: session.actionability,
            result: openURL(url) ? .unknown : .failed,
            invokedExactTarget: true,
            independentlyConfirmedIdentity: false
        )
    }

    func diagnostics() -> AgentDiagnostics {
        let discovery = discover()
        return AgentDiagnostics(
            health: discovery.isInstalled ? .healthy : .unavailable,
            summary: discovery.isInstalled ? "已发现 Codex" : "未发现 Codex",
            counters: [:]
        )
    }
}

struct ClaudeCodeAgentAdapter: AgentAdapter {
    let metadata: AgentMetadata
    private let readCollection: () -> TaskProgressCollectionSnapshot
    private let permissionQueue: () -> ClaudePermissionQueueSnapshot
    private let discoveryProvider: () -> AgentDiscovery
    private let openTerminal: (ClaudeTerminalOpenRequest) -> OpenResult

    var managedIntegrationRelativePaths: [String] {
        [".claude/settings.json"]
    }

    init(
        metadata: AgentMetadata? = builtInAgentMetadata().first {
            $0.id == .claudeCode
        },
        reader: ClaudeTaskProgressReader = ClaudeTaskProgressReader(),
        permissionQueue: @escaping () -> ClaudePermissionQueueSnapshot = {
            .empty
        },
        discovery: @escaping () -> AgentDiscovery = makeLocalAgentDiscoveryProvider {
            locateClaudeExecutable()
        },
        openTerminal: @escaping (ClaudeTerminalOpenRequest) -> OpenResult = {
            openClaudeTerminal(request: $0)
        }
    ) {
        self.init(
            metadata: metadata,
            readCollection: { reader.readCollection() },
            permissionQueue: permissionQueue,
            discovery: discovery,
            openTerminal: openTerminal
        )
    }

    init(
        metadata: AgentMetadata? = builtInAgentMetadata().first {
            $0.id == .claudeCode
        },
        readCollection: @escaping () -> TaskProgressCollectionSnapshot,
        permissionQueue: @escaping () -> ClaudePermissionQueueSnapshot = {
            .empty
        },
        discovery: @escaping () -> AgentDiscovery = makeLocalAgentDiscoveryProvider {
            locateClaudeExecutable()
        },
        openTerminal: @escaping (ClaudeTerminalOpenRequest) -> OpenResult = {
            openClaudeTerminal(request: $0)
        }
    ) {
        self.metadata = metadata!
        self.readCollection = readCollection
        self.permissionQueue = permissionQueue
        discoveryProvider = discovery
        self.openTerminal = openTerminal
    }

    func discover() -> AgentDiscovery {
        discoveryProvider()
    }

    func integrationStatus(in scope: AgentIntegrationScope) -> AgentIntegrationStatus {
        do {
            switch try ClaudeHookConfiguration.status(
                at: claudeSettingsURL(in: scope)
            ) {
            case .installed: return .installed
            case .missing: return .notInstalled
            case .conflict: return .needsRepair
            }
        } catch {
            return .needsRepair
        }
    }

    func installIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult {
        let settingsURL = try claudeSettingsURL(in: scope)
        let changed = try ClaudeHookConfiguration.install(
            at: settingsURL,
            isClaudeAvailable: { discover().isInstalled }
        )
        return changed ? .installed : .unchanged
    }

    func repairIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult {
        let settingsURL = try claudeSettingsURL(in: scope)
        let changed = try ClaudeHookConfiguration.install(
            at: settingsURL,
            isClaudeAvailable: { discover().isInstalled }
        )
        return changed ? .repaired : .unchanged
    }

    func uninstallIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult {
        let changed = try ClaudeHookConfiguration.uninstall(
            at: claudeSettingsURL(in: scope)
        )
        return changed ? .uninstalled : .unchanged
    }

    func observe() throws -> AgentObservation {
        observation(
            from: readCollection().items,
            permissionQueue: permissionQueue()
        )
    }

    func readTaskProgressCollection() -> TaskProgressCollectionSnapshot {
        readCollection()
    }

    func open(session: AgentSessionSnapshot) -> AgentOpenReport {
        guard session.identity.agentID == .claudeCode else {
            return AgentOpenReport(
                agentID: metadata.id,
                advertisedActionability: session.actionability,
                result: .unavailable,
                invokedExactTarget: false,
                independentlyConfirmedIdentity: false
            )
        }
        let request = ClaudeTerminalOpenRequest(
            sessionID: session.identity.nativeID,
            workingDirectory: session.workingDirectory,
            processID: session.identity.processID,
            processStartIdentity: session.identity.processStartIdentity
        )
        let result = openTerminal(request)
        let hasVerifiedProcessTarget = request.processID != nil
            && request.processStartIdentity != nil
        let hasResumeTarget = request.sessionID != nil
            && request.workingDirectory != nil
        return AgentOpenReport(
            agentID: metadata.id,
            advertisedActionability: session.actionability,
            result: result,
            invokedExactTarget: hasVerifiedProcessTarget || hasResumeTarget,
            independentlyConfirmedIdentity: result == .exactSession
                && hasVerifiedProcessTarget
        )
    }

    func diagnostics() -> AgentDiagnostics {
        let discovery = discover()
        return AgentDiagnostics(
            health: discovery.isInstalled ? .healthy : .unavailable,
            summary: discovery.isInstalled ? "已发现 Claude Code" : "未发现 Claude Code",
            counters: [:]
        )
    }
}

private func claudeSettingsURL(
    in scope: AgentIntegrationScope
) throws -> URL {
    try scope.managedURL(relativePath: ".claude/settings.json")
}

private extension AgentAdapter {
    func observation(
        from items: [TaskProgressItem],
        permissionQueue: ClaudePermissionQueueSnapshot
    ) -> AgentObservation {
        let adapterVersion = discover().version ?? "unknown"
        let snapshots = items.compactMap {
            agentSessionSnapshot(
                from: $0,
                metadata: metadata,
                permissionQueue: permissionQueue,
                adapterVersion: adapterVersion
            )
        }.sorted(by: agentSnapshotIsOrderedBefore)
        return AgentObservation(events: [], snapshots: snapshots)
    }
}

func agentSessionSnapshot(
    from item: TaskProgressItem,
    metadata: AgentMetadata,
    permissionQueue: ClaudePermissionQueueSnapshot = .empty,
    adapterVersion: String = "unknown"
) -> AgentSessionSnapshot? {
    guard item.source == metadata.id,
          let nativeID = item.threadID ?? item.sessionID
    else { return nil }
    let queueReasons = claudeQueueReasons(permissionQueue)
    let queuedReason = queueReasons[item.sessionID?.lowercased() ?? ""]
    let reason = queuedReason ?? normalizedAttentionReason(for: item)
    let actionability = normalizedActionability(
        for: item,
        agentID: metadata.id,
        reason: reason,
        hasInAppAction: queuedReason != nil
    )
    return AgentSessionSnapshot(
        identity: AgentSessionIdentity(
            agentID: metadata.id,
            nativeID: nativeID,
            processID: item.processID,
            processStartIdentity: item.processStartIdentity
        ),
        adapterVersion: adapterVersion,
        executionState: normalizedExecutionState(for: item.kind),
        attentionReason: reason,
        actionability: actionability,
        evidenceQuality: .nativeState,
        freshness: Freshness(
            observedAt: item.updatedAt,
            expiresAt: item.kind.isActive
                ? item.updatedAt.addingTimeInterval(30 * 60)
                : nil
        ),
        title: item.title,
        activitySummary: item.activityText,
        workingDirectory: item.workingDirectory,
        latestEventID: "snapshot:\(item.identityKey):\(Int64(item.updatedAt.timeIntervalSince1970 * 1_000))",
        updatedAt: item.updatedAt
    )
}

private func normalizedAttentionReason(
    for item: TaskProgressItem
) -> AttentionReason {
    switch item.kind {
    case .waitingForInput:
        if item.statusOverride == "已阻塞" { return .blocked }
        return .question
    case .completed:
        return .reviewReady
    case .failed:
        return .taskFailure
    case .reading, .running, .idle:
        return .none
    }
}

private func normalizedActionability(
    for item: TaskProgressItem,
    agentID: AgentID,
    reason: AttentionReason,
    hasInAppAction: Bool
) -> Actionability {
    if agentID == .claudeCode,
       hasInAppAction,
       [.permission, .question, .planApproval].contains(reason) {
        return .inApp
    }
    if agentID == .cursor || agentID == .zcode {
        return item.canOpen ? .openNativeApp : .viewOnly
    }
    if agentID == .pi {
        return .viewOnly
    }
    if item.canOpen { return .openExactNativeSession }
    if item.workingDirectory != nil { return .openWorkingDirectory }
    return .viewOnly
}

private func claudeQueueReasons(
    _ queue: ClaudePermissionQueueSnapshot
) -> [String: AttentionReason] {
    let entries = [queue.current].compactMap { $0 } + queue.pending
    var result: [String: AttentionReason] = [:]
    for entry in entries {
        guard let sessionID = entry.sessionID?.lowercased() else { continue }
        let reason = claudeAttentionReason(for: entry.interactionKind)
        if result[sessionID] == nil {
            result[sessionID] = reason
        }
    }
    return result
}

private func normalizedExecutionState(
    for kind: TaskProgressKind
) -> ExecutionState {
    switch kind {
    case .reading: return .discovering
    case .running, .waitingForInput: return .running
    case .completed: return .completed
    case .failed: return .failed
    case .idle: return .idle
    }
}

private func localAgentDiscovery(executableURL: URL?) -> AgentDiscovery {
    guard let executableURL else {
        return AgentDiscovery(
            isInstalled: false,
            version: nil,
            compatibility: .unknown
        )
    }
    return AgentDiscovery(
        isInstalled: true,
        version: localAgentVersion(executableURL: executableURL),
        compatibility: .supported
    )
}

private final class LocalAgentDiscoveryCache {
    private let lock = NSLock()
    private let executableLocator: () -> URL?
    private var cached: AgentDiscovery?

    init(executableLocator: @escaping () -> URL?) {
        self.executableLocator = executableLocator
    }

    func read() -> AgentDiscovery {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let discovery = localAgentDiscovery(
            executableURL: executableLocator()
        )
        cached = discovery
        return discovery
    }
}

private func makeLocalAgentDiscoveryProvider(
    _ executableLocator: @escaping () -> URL?
) -> () -> AgentDiscovery {
    let cache = LocalAgentDiscoveryCache(
        executableLocator: executableLocator
    )
    return { cache.read() }
}

private func localAgentVersion(executableURL: URL) -> String? {
    let process = Process()
    let stdout = Pipe()
    process.executableURL = executableURL
    process.arguments = ["--version"]
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return nil
    }
    let capture = captureProcessOutput(
        process: process,
        output: stdout.fileHandleForReading,
        timeout: 2,
        maximumOutputBytes: 4_096
    )
    guard capture.termination == .exited,
          let value = String(data: capture.data, encoding: .utf8)?
            .split(whereSeparator: \Character.isNewline)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty
    else { return nil }
    return String(value.prefix(128))
}

func normalizedBuiltInAgentState(
    collection: TaskProgressCollectionSnapshot,
    permissionQueue: ClaudePermissionQueueSnapshot,
    registry: AgentRegistry = .builtIn
) -> (snapshots: [AgentSessionSnapshot], attentionItems: [AgentAttentionItem]) {
    var snapshots: [AgentSessionSnapshot] = collection.items.compactMap {
        item -> AgentSessionSnapshot? in
        guard let metadata = registry.metadata(for: item.source) else {
            return nil
        }
        return agentSessionSnapshot(
            from: item,
            metadata: metadata,
            permissionQueue: permissionQueue
        )
    }
    let existingClaudeSessionIDs = Set(snapshots.compactMap {
        $0.identity.agentID == .claudeCode
            ? $0.identity.nativeID.lowercased()
            : nil
    })
    let queueEntries = [permissionQueue.current].compactMap { $0 }
        + permissionQueue.pending
    var synthesizedSessionIDs = existingClaudeSessionIDs
    for entry in queueEntries {
        let nativeID = entry.sessionID?.lowercased()
            ?? "request-\(entry.requestID.uuidString.lowercased())"
        guard synthesizedSessionIDs.insert(nativeID).inserted else { continue }
        let reason = claudeAttentionReason(for: entry.interactionKind)
        snapshots.append(AgentSessionSnapshot(
            identity: AgentSessionIdentity(
                agentID: .claudeCode,
                nativeID: nativeID
            ),
            adapterVersion: "unknown",
            executionState: .running,
            attentionReason: reason,
            actionability: .inApp,
            evidenceQuality: .officialHook,
            freshness: Freshness(
                observedAt: entry.arrivedAt,
                expiresAt: nil
            ),
            title: entry.title,
            activitySummary: nil,
            workingDirectory: nil,
            latestEventID: "permission:\(entry.requestID.uuidString.lowercased())",
            updatedAt: entry.arrivedAt
        ))
    }
    snapshots.sort(by: agentSnapshotIsOrderedBefore)
    let attentionItems = agentAttentionItems(from: snapshots)
    return (snapshots, attentionItems)
}

func builtInAgentMetadata() -> [AgentMetadata] {
    [
        AgentMetadata(
            id: .codex,
            displayName: "Codex",
            shortName: "Codex",
            iconResourceName: "ProviderIcon-codex",
            fallbackSymbolName: "sparkles",
            brandColor: AgentColorComponents(red: 0.06, green: 0.64, blue: 0.50),
            versionSource: "codex --version",
            identityPolicy: "native thread ID",
            capabilities: AgentCapabilitySet(
                supported: [
                    .lifecycleObservation,
                    .stableIdentity,
                    .exactReturn,
                    .nativeNavigation,
                    .quota,
                ]
            )
        ),
        AgentMetadata(
            id: .claudeCode,
            displayName: "Claude Code",
            shortName: "Claude",
            iconResourceName: "ProviderIcon-claude",
            fallbackSymbolName: "terminal",
            brandColor: AgentColorComponents(red: 0.85, green: 0.47, blue: 0.34),
            versionSource: "claude --version",
            identityPolicy: "session ID plus verified live process",
            capabilities: AgentCapabilitySet(
                supported: [
                    .lifecycleObservation,
                    .stableIdentity,
                    .exactReturn,
                    .nativeNavigation,
                    .inAppPermission,
                    .inAppQuestion,
                    .inAppPlanApproval,
                    .quota,
                    .managedIntegration,
                ]
            )
        ),
        AgentMetadata(
            id: .cursor,
            displayName: "Cursor",
            shortName: "Cursor",
            iconResourceName: "ProviderIcon-cursor",
            fallbackSymbolName: "cursorarrow.rays",
            brandColor: AgentColorComponents(red: 0.48, green: 0.72, blue: 1.00),
            versionSource: "Cursor.app and cursor agent --version",
            identityPolicy: "candidate session ID; exact return unverified",
            capabilities: AgentCapabilitySet(
                supported: [
                    .lifecycleObservation,
                    .nativeNavigation,
                    .subagentEvents,
                    .managedIntegration,
                ],
                unknown: [.stableIdentity, .exactReturn]
            )
        ),
        AgentMetadata(
            id: .zcode,
            displayName: "ZCode",
            shortName: "ZCode",
            iconResourceName: "ProviderIcon-zcode",
            fallbackSymbolName: "terminal.fill",
            brandColor: AgentColorComponents(red: 0.64, green: 0.45, blue: 0.96),
            versionSource: "ZCode.app version metadata",
            identityPolicy: "exact session and hot reload unverified",
            capabilities: AgentCapabilitySet(
                supported: [
                    .lifecycleObservation,
                    .nativeNavigation,
                    .managedIntegration,
                ],
                unknown: [
                    .stableIdentity,
                    .exactReturn,
                ]
            )
        ),
        AgentMetadata(
            id: .pi,
            displayName: "Pi",
            shortName: "Pi",
            iconResourceName: "ProviderIcon-pi",
            fallbackSymbolName: "waveform.path.ecg",
            brandColor: AgentColorComponents(red: 0.96, green: 0.67, blue: 0.22),
            versionSource: "pi --version",
            identityPolicy: "state-only; native session return unverified",
            capabilities: AgentCapabilitySet(
                supported: [.lifecycleObservation, .managedIntegration],
                unknown: [.stableIdentity, .exactReturn]
            )
        ),
    ]
}
