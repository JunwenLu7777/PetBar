//
//  AgentAdapter.swift
//  ThreadHelm
//
//  模块职责：定义 Agent 发现、集成生命周期、观察、打开和诊断契约。
//

import AppKit
import Foundation

enum AgentCompatibility: String, Equatable {
    case validated
    case unvalidated
    case unknown

    // Source-compatible aliases for isolated mocks that predate the pinned
    // truth-set wording. Production discovery uses validated/unvalidated.
    static let supported = AgentCompatibility.validated
    static let unsupportedVersion = AgentCompatibility.unvalidated
}

struct AgentVersionComponent: Equatable {
    let key: String
    let label: String
    let value: String
}

struct AgentDiscovery: Equatable {
    let isInstalled: Bool
    let version: String?
    let versionComponents: [AgentVersionComponent]
    let compatibility: AgentCompatibility

    init(
        isInstalled: Bool,
        version: String?,
        compatibility: AgentCompatibility,
        versionComponents: [AgentVersionComponent] = []
    ) {
        self.isInstalled = isInstalled
        self.version = version
        self.versionComponents = versionComponents.isEmpty
            ? version.map {
                [AgentVersionComponent(key: "version", label: "Version", value: $0)]
            } ?? []
            : versionComponents
        self.compatibility = compatibility
    }
}

func versionValidatedAgentDiscovery(
    agentID: AgentID,
    isInstalled: Bool,
    components: [AgentVersionComponent]
) -> AgentDiscovery {
    guard isInstalled else {
        return AgentDiscovery(
            isInstalled: false,
            version: nil,
            compatibility: .unknown,
            versionComponents: components
        )
    }

    let profiles = builtInAgentValidationProfiles()
    guard let expected = profiles[agentID]?.testedVersionComponents else {
        return AgentDiscovery(
            isInstalled: true,
            version: components.first?.value,
            compatibility: .unknown,
            versionComponents: components
        )
    }
    let actualValues = Dictionary(
        components.map { ($0.key, $0.value) },
        uniquingKeysWith: { _, latest in latest }
    )
    let expectedValues = Dictionary(
        uniqueKeysWithValues: expected.map { ($0.key, $0.value) }
    )
    let hasUniqueComponents = actualValues.count == components.count
    let isValidated = hasUniqueComponents && actualValues == expectedValues
    return AgentDiscovery(
        isInstalled: true,
        version: components.first?.value,
        compatibility: isValidated ? .validated : .unvalidated,
        versionComponents: components
    )
}

func normalizedAgentVersion(from output: String) -> String? {
    let bounded = String(output.prefix(512))
    guard let expression = try? NSRegularExpression(
        pattern: #"(?:^|[^A-Za-z0-9])v?([0-9]+(?:\.[0-9]+)+(?:-[A-Za-z0-9][A-Za-z0-9._-]*)?)"#
    ) else { return nil }
    let fullRange = NSRange(bounded.startIndex..., in: bounded)
    guard let match = expression.firstMatch(
        in: bounded,
        range: fullRange
    ),
    let versionRange = Range(match.range(at: 1), in: bounded)
    else { return nil }
    return String(bounded[versionRange])
}

enum AgentIntegrationStatus: String, Codable, Equatable {
    case notManaged
    case notInstalled
    case installed
    case disabled
    case needsRepair
    case unsupportedVersion
    /// The local configuration could not be inspected at all. This is a probe
    /// failure, not observed drift: it must never be reported as repairable
    /// state, because repairing it would fail for the same reason.
    case checkFailed
}

/// Distinguishes inspecting a vendor configuration from mutating it. Only
/// mutation is gated by `permitsLiveConfigurationChanges`.
enum AgentIntegrationAccess: Equatable {
    case read
    case write
}

/// Classifies a failed integration probe. Scope/path failures mean the
/// configuration was never read, so they surface as `.checkFailed`; anything
/// else came from parsing real user configuration and stays repairable.
func agentIntegrationStatusForFailedProbe(
    _ error: Error
) -> AgentIntegrationStatus {
    error is AgentIntegrationError ? .checkFailed : .needsRepair
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
    func managedURL(
        relativePath: String,
        for access: AgentIntegrationAccess = .write
    ) throws -> URL {
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
        if access == .write,
           !permitsLiveConfigurationChanges,
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
    /// 配置装没装 ≠ 闸门有没有在工作。三家厂商都可能静默地不加载我们的
    /// hook，这一项记录的是观测到的事实，排在末尾并带默认值，好让既有
    /// 构造点保持不变。
    var permissionGateLiveness: PermissionGateLiveness = .notApplicable
}

func agentRuntimeStatusPlaceholders(
    registry: AgentRegistry = .builtIn
) -> [AgentRuntimeStatus] {
    registry.agentIDs.compactMap { agentID in
        guard let metadata = registry.metadata(for: agentID) else { return nil }
        let discovery = AgentDiscovery(
            isInstalled: false,
            version: nil,
            compatibility: .unknown
        )
        let boundedMetadata = validationBoundedAgentMetadata(
            metadata,
            discovery: discovery
        )
        let integrationStatus: AgentIntegrationStatus? = metadata.capabilities
            .status(for: .managedIntegration) == .unsupported
            ? .notManaged
            : nil
        return AgentRuntimeStatus(
            metadata: boundedMetadata,
            discovery: discovery,
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
        let discovery = adapter.discover()
        let metadata = validationBoundedAgentMetadata(
            adapter.metadata,
            discovery: discovery
        )
        let integrationStatus: AgentIntegrationStatus?
        if metadata.capabilities.status(for: .managedIntegration)
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
            metadata: metadata,
            discovery: discovery,
            integrationStatus: integrationStatus,
            diagnostics: adapter.diagnostics(),
            activeSessionCount: previous?.activeSessionCount ?? 0,
            attentionCount: previous?.attentionCount ?? 0
        )
    }
}

func agentRuntimeStatusesMergingIntegration(
    _ statuses: [AgentRuntimeStatus],
    report: AgentIntegrationRunReport
) -> [AgentRuntimeStatus] {
    let statusByID = Dictionary(
        uniqueKeysWithValues: report.agents.map {
            ($0.agentID, $0.statusAfter)
        }
    )
    return statuses.map { status in
        guard let after = statusByID[status.metadata.id] else {
            return status
        }
        return AgentRuntimeStatus(
            metadata: status.metadata,
            discovery: status.discovery,
            integrationStatus: after,
            diagnostics: status.diagnostics,
            activeSessionCount: status.activeSessionCount,
            attentionCount: status.attentionCount
        )
    }
}

func agentRuntimeStatusesWithGateLiveness(
    _ statuses: [AgentRuntimeStatus],
    records: [AgentID: PermissionGateLivenessRecord]
) -> [AgentRuntimeStatus] {
    statuses.map { status in
        var updated = status
        updated.permissionGateLiveness = permissionGateLiveness(
            capability: status.metadata.capabilities.status(
                for: .inAppPermission
            ),
            integrationStatus: status.integrationStatus,
            record: records[status.metadata.id]
        )
        return updated
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
    func openValidated(session: AgentSessionSnapshot) -> AgentOpenReport
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
        openSessionIfInstalled(session: session) {
            openValidated(session: session)
        }
    }

    func openSessionIfInstalled(
        session: AgentSessionSnapshot,
        perform: () -> AgentOpenReport
    ) -> AgentOpenReport {
        let discovery = discover()
        guard discovery.isInstalled else {
            return AgentOpenReport(
                agentID: metadata.id,
                advertisedActionability: session.actionability,
                result: .unavailable,
                invokedExactTarget: false,
                independentlyConfirmedIdentity: false
            )
        }
        // 用户主动触发的本地导航与自动集成分开授权。版本漂移仍会
        // 降级能力声明、提醒和配置写入，但不能让已有的原生应用、
        // 会话 ID 或工作目录跳转整体失效。
        return perform()
    }

    func openValidated(session: AgentSessionSnapshot) -> AgentOpenReport {
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
        OMPAgentAdapter(metadata: indexed[.omp]!),
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
    private let permissionQueue: () -> ClaudePermissionQueueSnapshot
    private let discoveryProvider: () -> AgentDiscovery
    private let openURL: (URL) -> Bool

    var managedIntegrationRelativePaths: [String] {
        [".codex/hooks.json", ".codex/\(CodexHookConstants.tokenFileName)"]
    }

    init(
        metadata: AgentMetadata? = builtInAgentMetadata().first {
            $0.id == .codex
        },
        reader: CodexTaskProgressReader = CodexTaskProgressReader(),
        permissionQueue: @escaping () -> ClaudePermissionQueueSnapshot = {
            .empty
        },
        discovery: @escaping () -> AgentDiscovery = makeLocalAgentDiscoveryProvider(
            agentID: .codex
        ) {
            locateCodexExecutable()
        },
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.init(
            metadata: metadata,
            readCollection: { reader.readCollection() },
            permissionQueue: permissionQueue,
            discovery: discovery,
            openURL: openURL
        )
    }

    init(
        metadata: AgentMetadata? = builtInAgentMetadata().first {
            $0.id == .codex
        },
        readCollection: @escaping () -> TaskProgressCollectionSnapshot,
        permissionQueue: @escaping () -> ClaudePermissionQueueSnapshot = {
            .empty
        },
        discovery: @escaping () -> AgentDiscovery = makeLocalAgentDiscoveryProvider(
            agentID: .codex
        ) {
            locateCodexExecutable()
        },
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.metadata = metadata!
        self.readCollection = readCollection
        self.permissionQueue = permissionQueue
        discoveryProvider = discovery
        self.openURL = openURL
    }

    func discover() -> AgentDiscovery {
        discoveryProvider()
    }

    func integrationStatus(in scope: AgentIntegrationScope) -> AgentIntegrationStatus {
        do {
            switch try CodexHookConfiguration.status(
                at: codexHooksURL(in: scope, for: .read)
            ) {
            case .installed:
                // 写进 hooks.json 只是第一步：Codex 要求用户在自己那边
                // 信任一次，否则 hook 完全不加载——不报错也不告警。
                // 令牌缺失说明这份配置不是本次安装写的，闸门连不通。
                return CodexHookConfiguration.authenticationToken(
                    for: try codexHooksURL(in: scope, for: .read)
                ) != nil ? .installed : .needsRepair
            case .missing:
                return .notInstalled
            case .conflict:
                return .needsRepair
            }
        } catch {
            return agentIntegrationStatusForFailedProbe(error)
        }
    }

    func installIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult {
        let changed = try CodexHookConfiguration.install(
            at: codexHooksURL(in: scope),
            isCodexAvailable: { discover().isInstalled }
        )
        return changed ? .installed : .unchanged
    }

    func repairIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult {
        let changed = try CodexHookConfiguration.install(
            at: codexHooksURL(in: scope),
            isCodexAvailable: { discover().isInstalled }
        )
        return changed ? .repaired : .unchanged
    }

    func uninstallIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult {
        let changed = try CodexHookConfiguration.uninstall(
            at: codexHooksURL(in: scope)
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

    func openValidated(session: AgentSessionSnapshot) -> AgentOpenReport {
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
        discovery: @escaping () -> AgentDiscovery = makeLocalAgentDiscoveryProvider(
            agentID: .claudeCode
        ) {
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
        discovery: @escaping () -> AgentDiscovery = makeLocalAgentDiscoveryProvider(
            agentID: .claudeCode
        ) {
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
                at: claudeSettingsURL(in: scope, for: .read)
            ) {
            case .installed: return .installed
            case .missing: return .notInstalled
            case .conflict: return .needsRepair
            }
        } catch {
            return agentIntegrationStatusForFailedProbe(error)
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

    func openValidated(session: AgentSessionSnapshot) -> AgentOpenReport {
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
    in scope: AgentIntegrationScope,
    for access: AgentIntegrationAccess = .write
) throws -> URL {
    try scope.managedURL(relativePath: ".claude/settings.json", for: access)
}

private func codexHooksURL(
    in scope: AgentIntegrationScope,
    for access: AgentIntegrationAccess = .write
) throws -> URL {
    try scope.managedURL(relativePath: ".codex/hooks.json", for: access)
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
    let queueReasons = claudeQueueReasons(permissionQueue, agentID: metadata.id)
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
    if agentID == .omp {
        return item.canOpen ? .openExactNativeSession : .viewOnly
    }
    if item.canOpen { return .openExactNativeSession }
    if item.workingDirectory != nil { return .openWorkingDirectory }
    return .viewOnly
}

/// 队列同时排着多家的请求，归因前必须按 agent 过滤：会话 ID 只在
/// 单个 agent 内保证唯一，跨家比对没有意义。
private func claudeQueueReasons(
    _ queue: ClaudePermissionQueueSnapshot,
    agentID: AgentID
) -> [String: AttentionReason] {
    let entries = ([queue.current].compactMap { $0 } + queue.pending)
        .filter { $0.agentID == agentID }
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

private func localAgentDiscovery(
    agentID: AgentID,
    executableURL: URL?
) -> AgentDiscovery {
    guard let executableURL else {
        return AgentDiscovery(
            isInstalled: false,
            version: nil,
            compatibility: .unknown
        )
    }
    let version = localAgentVersion(executableURL: executableURL)
    return versionValidatedAgentDiscovery(
        agentID: agentID,
        isInstalled: true,
        components: version.map {
            [AgentVersionComponent(key: "version", label: "Version", value: $0)]
        } ?? []
    )
}

/// 发现结果缓存的默认存活时间。
///
/// 必须**严格小于** `agentHealthRefreshInterval`（300 秒）：时间戳记在探测发生的
/// 时刻，比定时器唤醒晚一个派发延迟加前序 Agent 的探测耗时（5 个 Agent 顺序探测，
/// 每个最坏 2 秒子进程超时）。若两者相等，下一轮唤醒时缓存往往刚好还差几秒才
/// 过期，本轮探测直接落空，该 Agent 的实际刷新间隔退化成 600 秒。
let agentDiscoveryCacheTTL: TimeInterval = 240

/// Agent 健康与集成状态的后台刷新周期。
let agentHealthRefreshInterval: TimeInterval = 300

final class LocalAgentDiscoveryCache {
    private let lock = NSLock()
    let agentID: AgentID
    let ttl: TimeInterval
    private let now: () -> Date
    private let discoverBlock: () -> AgentDiscovery
    private var cached: AgentDiscovery?
    private var cachedTimestamp: Date?

    init(
        agentID: AgentID,
        ttl: TimeInterval = agentDiscoveryCacheTTL,
        now: @escaping () -> Date = Date.init,
        discover: @escaping () -> AgentDiscovery
    ) {
        self.agentID = agentID
        self.ttl = ttl
        self.now = now
        self.discoverBlock = discover
    }

    convenience init(
        agentID: AgentID,
        ttl: TimeInterval = agentDiscoveryCacheTTL,
        now: @escaping () -> Date = Date.init,
        executableLocator: @escaping () -> URL?
    ) {
        self.init(agentID: agentID, ttl: ttl, now: now) {
            localAgentDiscovery(
                agentID: agentID,
                executableURL: executableLocator()
            )
        }
    }

    func read() -> AgentDiscovery {
        lock.lock()
        defer { lock.unlock() }
        let currentTime = now()
        if let cached,
           let cachedTimestamp,
           currentTime.timeIntervalSince(cachedTimestamp) < ttl
        {
            return cached
        }
        let discovery = discoverBlock()
        cached = discovery
        cachedTimestamp = currentTime
        return discovery
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
        cachedTimestamp = nil
    }
}

func makeLocalAgentDiscoveryProvider(
    agentID: AgentID,
    ttl: TimeInterval = agentDiscoveryCacheTTL,
    now: @escaping () -> Date = Date.init,
    _ executableLocator: @escaping () -> URL?
) -> () -> AgentDiscovery {
    let cache = LocalAgentDiscoveryCache(
        agentID: agentID,
        ttl: ttl,
        now: now,
        executableLocator: executableLocator
    )
    return { cache.read() }
}

func makeGenericAgentDiscoveryProvider(
    agentID: AgentID,
    ttl: TimeInterval = agentDiscoveryCacheTTL,
    now: @escaping () -> Date = Date.init,
    _ discover: @escaping () -> AgentDiscovery
) -> () -> AgentDiscovery {
    let cache = LocalAgentDiscoveryCache(
        agentID: agentID,
        ttl: ttl,
        now: now,
        discover: discover
    )
    return { cache.read() }
}

/// launchd 拉起的常驻面板只有 `/usr/bin:/bin:/usr/sbin:/sbin`。厂商 CLI
/// 里有相当一部分是 `#!/usr/bin/env node` 之类的包装脚本（codex 就是），
/// 在这个 PATH 下连解释器都找不到，`--version` 直接执行失败——于是版本读
/// 不出来、能力被判 unvalidated，受管集成和审批闸门一并静默关闭。补上
/// 常见的用户级 bin 目录，只影响我们自己起的这个探测子进程。
private func agentVersionProbeEnvironment(
    base: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
) -> [String: String] {
    let interpreterDirectories = supplementalExecutableSearchDirectories(
        homeDirectory: homeDirectory
    )
    var environment = base
    let existing = (base["PATH"] ?? "")
        .split(separator: ":", omittingEmptySubsequences: true)
        .map(String.init)
    let missing = interpreterDirectories.filter { !existing.contains($0) }
    guard !missing.isEmpty else { return environment }
    environment["PATH"] = (existing + missing).joined(separator: ":")
    return environment
}

func agentVersionProbeEnvironmentForSelfTest(
    base: [String: String],
    homeDirectory: URL
) -> [String: String] {
    agentVersionProbeEnvironment(base: base, homeDirectory: homeDirectory)
}

private func localAgentVersion(executableURL: URL) -> String? {
    let process = Process()
    let stdout = Pipe()
    process.executableURL = executableURL
    process.arguments = ["--version"]
    process.environment = agentVersionProbeEnvironment()
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
            // 显式根的 key path 当函数用（\Character.isNewline）在 CI runner
            // 的旧 Swift 上推断不出来，报 "key path value type 'Bool' cannot be
            // converted to contextual type 'Bool'"。闭包在所有版本上都成立。
            .split(whereSeparator: { $0.isNewline })
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty
    else { return nil }
    return normalizedAgentVersion(from: String(value.prefix(128)))
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
                    .nativeNavigation,
                    .quota,
                    .managedIntegration,
                    .inAppPermission,
                ],
                // Codex 的 hooks 里没有 AskUserQuestion 与 ExitPlanMode 这类
                // 事件，但平台是否另有途径没验证过——记 unknown 而不是
                // unsupported，后者等于对用户断言平台做不到。
                unknown: [
                    .exactReturn,
                    .inAppQuestion,
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
                // preToolUse 会被 await 且能返回 deny，平台支持拦截；
                // ThreadHelm 尚未接入，且缺运行时实证，故记 unknown。
                unknown: [
                    .stableIdentity,
                    .exactReturn,
                    .inAppPermission,
                    .inAppQuestion,
                ]
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
                    .inAppPermission,
                ],
                // ZCode 的 PermissionRequest 负载与裁决格式与 Claude 同形，
                // 走同一条闸门。问题回答与计划审批没有对应的 hook 事件，
                // 平台是否另有途径没验证过，记 unknown 而非 unsupported。
                unknown: [
                    .stableIdentity,
                    .exactReturn,
                    .inAppQuestion,
                    .inAppPlanApproval,
                ]
            )
        ),
        AgentMetadata(
            id: .omp,
            displayName: "OMP",
            shortName: "OMP",
            iconResourceName: "ProviderIcon-omp",
            fallbackSymbolName: "waveform.path.ecg",
            brandColor: AgentColorComponents(red: 0.96, green: 0.67, blue: 0.22),
            versionSource: "omp --version",
            identityPolicy: "native session ID; resume dispatch unverified",
            capabilities: AgentCapabilitySet(
                supported: [
                    .lifecycleObservation,
                    .nativeNavigation,
                    .managedIntegration,
                    .inAppPermission,
                ],
                // OMP 的扩展事件里没有对应问题回答的入口，平台是否另有
                // 途径没验证过，记 unknown 而非 unsupported。
                unknown: [
                    .stableIdentity,
                    .exactReturn,
                    .inAppQuestion,
                ]
            )
        ),
    ]
}

/// 打印每个 Agent 的本机发现结果与版本判定。放在 CLI 里是因为常驻面板
/// 由 launchd 拉起、PATH 与终端不同，只有在同样的环境里问才有意义。
func printAgentDiscovery() -> Never {
    let profiles = builtInAgentValidationProfiles()
    let livenessRecords = PermissionGateLivenessStore().snapshot()
    let scope = AgentIntegrationScope(
        rootDirectory: FileManager.default.homeDirectoryForCurrentUser,
        permitsLiveConfigurationChanges: true
    )
    for adapter in builtInAgentAdapters() {
        let discovery = adapter.discover()
        let profile = profiles[adapter.metadata.id]
        let bounded = validationBoundedAgentMetadata(
            adapter.metadata,
            discovery: discovery
        )
        let permission = bounded.capabilities.status(for: .inAppPermission)
        let integration = adapter.integrationStatus(in: scope)
        let liveness = permissionGateLiveness(
            capability: permission,
            integrationStatus: integration,
            record: livenessRecords[adapter.metadata.id]
        )
        let gate: String
        switch liveness {
        case .notApplicable: gate = "n/a"
        case .neverObserved: gate = "unverified"
        case .verified: gate = "verified"
        }
        print(
            "\(adapter.metadata.id.rawValue)"
                + " installed=\(discovery.isInstalled)"
                + " version=\(discovery.version ?? "nil")"
                + " pinned=\(profile?.testedVersion ?? "nil")"
                + " compatibility=\(discovery.compatibility.rawValue)"
                + " integration=\(integration.rawValue)"
                + " inAppPermission=\(permission.rawValue)"
                + " gate=\(gate)"
        )
    }
    exit(0)
}

/// 安装后打印一行「还差什么」。装好配置不等于闸门在工作，而这一步
/// 目前对用户完全静默——只有等到某次危险操作没弹确认框才会发现。
func printPermissionGateFollowUp() -> Never {
    let livenessRecords = PermissionGateLivenessStore().snapshot()
    let scope = AgentIntegrationScope(
        rootDirectory: FileManager.default.homeDirectoryForCurrentUser,
        permitsLiveConfigurationChanges: true
    )
    var pending: [String] = []
    for adapter in builtInAgentAdapters() {
        let discovery = adapter.discover()
        let bounded = validationBoundedAgentMetadata(
            adapter.metadata,
            discovery: discovery
        )
        let liveness = permissionGateLiveness(
            capability: bounded.capabilities.status(for: .inAppPermission),
            integrationStatus: adapter.integrationStatus(in: scope),
            record: livenessRecords[adapter.metadata.id]
        )
        guard liveness == .neverObserved else { continue }
        if adapter.metadata.id == .codex {
            pending.append(
                "  \(bounded.shortName)：闸门尚未验证。"
                    + "Codex 启动时若提示 “Hooks need review”，请选 Trust；"
                    + "未信任时 Codex 会静默跳过 hook。"
            )
        } else {
            pending.append(
                "  \(bounded.shortName)：闸门尚未验证——还没收到过审批请求。"
            )
        }
    }
    if !pending.isEmpty {
        print("审批闸门待确认：")
        pending.forEach { print($0) }
    }
    exit(0)
}
