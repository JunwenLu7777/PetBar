import Foundation

enum PresentationMode: String, CaseIterable {
    case petPanel = "pet-panel"
    case dynamicIsland = "dynamic-island"
}

enum DynamicIslandTab: String, CaseIterable {
    case tasks
    case agents
    case confirmation
    case quota
}

struct TaskSourceFilter: RawRepresentable, Hashable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(agentID: AgentID) {
        rawValue = agentID.rawValue
    }

    static let all = TaskSourceFilter(rawValue: "all")
    static let codex = TaskSourceFilter(agentID: .codex)
    static let claudeCode = TaskSourceFilter(agentID: .claudeCode)
    static let cursor = TaskSourceFilter(agentID: .cursor)
    static let zcode = TaskSourceFilter(agentID: .zcode)
    static let pi = TaskSourceFilter(agentID: .pi)

    var agentID: AgentID? {
        self == .all ? nil : AgentID(rawValue: rawValue)
    }

    static func options(for agentIDs: [AgentID]) -> [TaskSourceFilter] {
        [.all] + agentIDs.map(TaskSourceFilter.init(agentID:))
    }
}

enum TaskStateFilter: String, CaseIterable {
    case all
    case running
    case waitingForInput
    case completed
    case failed
}

enum TaskQueueGroup: String, CaseIterable, Equatable {
    case needsYou
    case running
    case review

    var title: String {
        switch self {
        case .needsYou: return "Needs you"
        case .running: return "Running"
        case .review: return "Review"
        }
    }

    fileprivate func contains(_ kind: TaskProgressKind) -> Bool {
        switch self {
        case .needsYou:
            return kind == .waitingForInput || kind == .failed
        case .running:
            return kind == .running || kind == .reading || kind == .idle
        case .review:
            return kind == .completed
        }
    }
}

struct TaskQueueSection: Equatable {
    let group: TaskQueueGroup
    let items: [TaskProgressItem]
}

func taskQueueSections(for items: [TaskProgressItem]) -> [TaskQueueSection] {
    TaskQueueGroup.allCases.compactMap { group in
        let groupedItems = items.filter { group.contains($0.kind) }
        guard !groupedItems.isEmpty else { return nil }
        return TaskQueueSection(group: group, items: groupedItems)
    }
}

enum TaskActivityEventKind: String, Equatable {
    case commentary
    case tool
    case lifecycle
}

struct TaskActivityEvent: Equatable {
    let kind: TaskActivityEventKind
    let occurredAt: Date
    let text: String
}

struct TaskProgressCollectionSnapshot: Equatable {
    let items: [TaskProgressItem]

    static func displaying(
        _ sourceItems: [TaskProgressItem]
    ) -> TaskProgressCollectionSnapshot {
        let sorted = sourceItems.sorted(by: taskProgressItemIsOrderedBefore)
        var seenKeys = Set<String>()
        return TaskProgressCollectionSnapshot(items: sorted.filter {
            seenKeys.insert($0.deduplicationKey).inserted
        })
    }

    func compactProjection(
        maximumVisibleRows: Int = maximumVisibleTaskRows
    ) -> TaskProgressSnapshot {
        guard maximumVisibleRows > 0, !items.isEmpty else { return .idle }
        let active = items.filter(\.kind.isActive)
        if active.count > maximumVisibleRows {
            return TaskProgressSnapshot(items: active, isScrollable: true)
        }
        let terminal = items.filter {
            $0.kind == .completed || $0.kind == .failed
        }
        let rows = Array((active + terminal).prefix(maximumVisibleRows))
        return rows.isEmpty ? .idle : TaskProgressSnapshot(items: rows)
    }

    func filtered(
        source: TaskSourceFilter,
        state: TaskStateFilter
    ) -> [TaskProgressItem] {
        items.filter { item in
            let sourceMatches = source.agentID.map { item.source == $0 } ?? true
            let stateMatches: Bool
            switch state {
            case .all:
                stateMatches = true
            case .running:
                stateMatches = item.kind == .running
            case .waitingForInput:
                stateMatches = item.kind == .waitingForInput
            case .completed:
                stateMatches = item.kind == .completed
            case .failed:
                stateMatches = item.kind == .failed
            }
            return sourceMatches && stateMatches
        }
    }

    func count(state: TaskStateFilter) -> Int {
        filtered(source: .all, state: state).count
    }
}

private func taskProgressItemIsOrderedBefore(
    _ lhs: TaskProgressItem,
    _ rhs: TaskProgressItem
) -> Bool {
    if lhs.updatedAt != rhs.updatedAt {
        return lhs.updatedAt > rhs.updatedAt
    }
    let lhsPriority = taskProgressKindDeterministicPriority(lhs.kind)
    let rhsPriority = taskProgressKindDeterministicPriority(rhs.kind)
    if lhsPriority != rhsPriority {
        return lhsPriority > rhsPriority
    }
    if lhs.identityKey != rhs.identityKey {
        return lhs.identityKey < rhs.identityKey
    }
    if lhs.title != rhs.title {
        return lhs.title < rhs.title
    }
    let lhsTieBreak = [
        lhs.statusOverride,
        lhs.activityText,
        lhs.threadID,
        lhs.sessionID,
        lhs.workingDirectory,
        lhs.processStartIdentity,
    ].compactMap { $0 }.joined(separator: "|")
    let rhsTieBreak = [
        rhs.statusOverride,
        rhs.activityText,
        rhs.threadID,
        rhs.sessionID,
        rhs.workingDirectory,
        rhs.processStartIdentity,
    ].compactMap { $0 }.joined(separator: "|")
    return lhsTieBreak < rhsTieBreak
}

private func taskProgressKindDeterministicPriority(
    _ kind: TaskProgressKind
) -> Int {
    switch kind {
    case .waitingForInput: return 6
    case .failed: return 5
    case .running: return 4
    case .completed: return 3
    case .reading: return 2
    case .idle: return 1
    }
}

struct QuotaProviderState: Equatable {
    var rows: [QuotaRow] = []
    var resetCredits: CodexResetCreditsSnapshot?
    var statusText = "正在读取额度…"
    var errorText: String?
    var updatedAt: Date?
    var isRefreshing = false
    var isStale = false
}

func quotaProviderStateRefreshing(
    _ previous: QuotaProviderState
) -> QuotaProviderState {
    let hasCachedValues = !previous.rows.isEmpty
        || previous.resetCredits != nil
    var next = previous
    next.statusText = hasCachedValues
        ? "正在更新…"
        : "正在读取额度…"
    next.errorText = nil
    next.isRefreshing = true
    return next
}

func quotaProviderStateAfterSuccess(
    _ previous: QuotaProviderState,
    rows: [QuotaRow],
    resetCredits: CodexResetCreditsSnapshot?,
    provider: QuotaProvider,
    updatedAt: Date
) -> QuotaProviderState {
    var next = previous
    next.rows = rows
    next.resetCredits = provider == .codex ? resetCredits : nil
    next.statusText = rows.isEmpty
        ? "没有可确认的额度数据"
        : quotaSuccessStatusText(
            provider: provider,
            rows: rows,
            updatedAt: updatedAt
        )
    next.errorText = nil
    next.updatedAt = updatedAt
    next.isRefreshing = false
    next.isStale = false
    return next
}

func quotaProviderStateAfterFailure(
    _ previous: QuotaProviderState,
    error: Error,
    provider: QuotaProvider
) -> QuotaProviderState {
    let hasCachedValues = !previous.rows.isEmpty
        || previous.resetCredits != nil
    let presentation = quotaFailurePresentation(
        for: error,
        hasExistingRows: hasCachedValues,
        provider: provider
    )
    var next = previous
    next.statusText = presentation.statusText
    next.errorText = presentation.errorText
    next.isRefreshing = false
    next.isStale = hasCachedValues
    return next
}

struct ClaudePermissionQueueItem: Equatable {
    let requestID: UUID
    let interactionKind: ClaudePermissionInteractionKind
    let title: String
    let sessionID: String?
    let arrivedAt: Date
}

struct ClaudePermissionQueueSnapshot: Equatable {
    var current: ClaudePermissionQueueItem? = nil
    var pending: [ClaudePermissionQueueItem] = []
    static let empty = ClaudePermissionQueueSnapshot()
    var count: Int { (current == nil ? 0 : 1) + pending.count }
}

struct ActivityDashboardSnapshot: Equatable {
    var taskCollection = TaskProgressCollectionSnapshot(
        items: TaskProgressSnapshot.reading.items
    )
    var quotaStates: [QuotaProvider: QuotaProviderState] = [:]
    var availableProviders: [QuotaProvider] = [.codex]
    var availableAgentIDs: [AgentID] = AgentID.builtInOrder
    var selectedQuotaProvider: QuotaProvider = .codex
    var permissionQueue = ClaudePermissionQueueSnapshot.empty
    var agentSnapshots: [AgentSessionSnapshot] = []
    var attentionItems: [AgentAttentionItem] = []
    var agentStatuses: [AgentRuntimeStatus] = []
    var personalSessionEvidence = AgentPersonalSessionEvidenceSnapshot.zero
    var personalReadinessReviews = AgentPersonalReadinessReviewSnapshot.none
    var agentEventChannelAvailable: Bool? = nil
    var acknowledgedTerminalTaskKeys = Set<String>()
    var isTaskRefreshing = false
    var codexDesktopRunning = false
    var petEnabled = true
}

func terminalTaskAcknowledgementKey(
    for item: TaskProgressItem
) -> String? {
    guard item.kind == .completed || item.kind == .failed else { return nil }
    let updatedMilliseconds = Int64(
        (item.updatedAt.timeIntervalSince1970 * 1_000).rounded()
    )
    return "\(item.identityKey)|\(item.kind.rawValue)|\(updatedMilliseconds)"
}
