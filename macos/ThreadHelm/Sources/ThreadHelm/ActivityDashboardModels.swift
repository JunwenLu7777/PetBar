import Foundation

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
    static let omp = TaskSourceFilter(agentID: .omp)

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
        case .needsYou: return "需要你"
        case .running: return "进行中"
        case .review: return "已完成"
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

/// 稳定三通道活动投影。视图只消费这个投影，不再各自猜测 events 数组方向。
struct AgentActivityEventID: Hashable, Equatable {
    let source: AgentID
    let sessionKey: String
    let stableSourceKey: String
}

struct AgentActivityEntry: Equatable {
    let id: AgentActivityEventID
    let occurredAt: Date
    let sourceOrder: UInt64
    let text: String
}

struct AgentActivityProjection: Equatable {
    /// 公开消息，按 occurredAt DESC、sourceOrder DESC 稳定排序。
    var publicMessages: [AgentActivityEntry]
    var currentToolStatus: AgentActivityEntry?
    var terminalEvent: AgentActivityEntry?

    init(
        publicMessages: [AgentActivityEntry] = [],
        currentToolStatus: AgentActivityEntry? = nil,
        terminalEvent: AgentActivityEntry? = nil
    ) {
        self.publicMessages = publicMessages
        self.currentToolStatus = currentToolStatus
        self.terminalEvent = terminalEvent
    }

    static let empty = AgentActivityProjection()

    /// 只读兼容视图：由公共投影唯一派生 `events` 数组（正文已按时间/顺序
    /// 倒序；工具与终态各自独立通道附后）。provider 不得直接写混合数组。
    var displayEvents: [TaskActivityEvent] {
        var rows: [(order: UInt64, occurredAt: Date, kind: TaskActivityEventKind, text: String)] = []
        for entry in publicMessages {
            rows.append((entry.sourceOrder, entry.occurredAt, .commentary, entry.text))
        }
        if let currentToolStatus {
            rows.append((
                currentToolStatus.sourceOrder,
                currentToolStatus.occurredAt,
                .tool,
                currentToolStatus.text
            ))
        }
        if let terminalEvent {
            rows.append((
                terminalEvent.sourceOrder,
                terminalEvent.occurredAt,
                .lifecycle,
                terminalEvent.text
            ))
        }
        return rows.sorted {
            if $0.occurredAt != $1.occurredAt {
                return $0.occurredAt > $1.occurredAt
            }
            return $0.order > $1.order
        }.map {
            TaskActivityEvent(kind: $0.kind, occurredAt: $0.occurredAt, text: $0.text)
        }
    }
}

extension AgentActivityProjection {
    /// 集中应用计划 §4.3 的内存预算与脱敏后截断：正文最多 32 条、单条
    /// 4 KiB、合计 64 KiB；工具状态 512 B；终态 256 B。所有 provider
    /// projection 都必须经此收敛。
    func budgeted() -> AgentActivityProjection {
        // 0) 先按 occurredAt/sourceOrder DESC 排序，保证 prefix 保留最新；
        //    再对正文脱敏（compactMap 丢弃脱敏失败项），最后才截断。
        let sorted = publicMessages.sorted {
            if $0.occurredAt != $1.occurredAt {
                return $0.occurredAt > $1.occurredAt
            }
            return $0.sourceOrder > $1.sourceOrder
        }
        // 1) 脱敏 → 条目数上限 32 → 单条上限 4 KiB。
        var messages = sorted.prefix(
            AgentActivityBudget.maximumPublicMessages
        ).compactMap { entry -> AgentActivityEntry? in
            guard let sanitized = safePublicActivityParagraph(from: entry.text) else {
                return nil
            }
            let text = safeUTF8Truncated(
                sanitized,
                to: AgentActivityBudget.maximumPublicMessageBytes
            )
            return AgentActivityEntry(
                id: entry.id,
                occurredAt: entry.occurredAt,
                sourceOrder: entry.sourceOrder,
                text: text
            )
        }
        // 2) 合计上限 64 KiB：从尾部截断（截断后仍超则丢弃尾部条目）。
        let total = messages.reduce(0) { $0 + $1.text.utf8.count }
        if total > AgentActivityBudget.maximumPublicMessagesTotalBytes {
            var consumed = 0
            var budgeted: [AgentActivityEntry] = []
            for entry in messages {
                let room = AgentActivityBudget.maximumPublicMessagesTotalBytes - consumed
                guard room > 0 else { break }
                let text = safeUTF8Truncated(entry.text, to: room)
                consumed += text.utf8.count
                budgeted.append(
                    AgentActivityEntry(
                        id: entry.id,
                        occurredAt: entry.occurredAt,
                        sourceOrder: entry.sourceOrder,
                        text: text
                    )
                )
            }
            messages = budgeted
        }
        let toolStatus = currentToolStatus.flatMap { entry -> AgentActivityEntry? in
            guard let sanitized = safePublicActivityParagraph(from: entry.text) else {
                return nil
            }
            return AgentActivityEntry(
                id: entry.id,
                occurredAt: entry.occurredAt,
                sourceOrder: entry.sourceOrder,
                text: safeUTF8Truncated(
                    sanitized,
                    to: AgentActivityBudget.maximumToolStatusBytes
                )
            )
        }
        let terminal = terminalEvent.flatMap { entry -> AgentActivityEntry? in
            guard let sanitized = safePublicActivityParagraph(from: entry.text) else {
                return nil
            }
            return AgentActivityEntry(
                id: entry.id,
                occurredAt: entry.occurredAt,
                sourceOrder: entry.sourceOrder,
                text: safeUTF8Truncated(
                    sanitized,
                    to: AgentActivityBudget.maximumTerminalBytes
                )
            )
        }
        return AgentActivityProjection(
            publicMessages: messages,
            currentToolStatus: toolStatus,
            terminalEvent: terminal
        )
    }
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
    if lhs.allowsAgentOpen != rhs.allowsAgentOpen {
        return !lhs.allowsAgentOpen
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
    var agentEventChannelAvailable: Bool? = nil
    var acknowledgedTerminalTaskKeys = Set<String>()
    var isTaskRefreshing = false
    var codexDesktopRunning = false
    var isAutoIntegrationEnabled = false
    var hasConfirmedAutoIntegration = false
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
