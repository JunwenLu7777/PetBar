import Foundation

enum PresentationMode: String, CaseIterable {
    case petPanel = "pet-panel"
    case dynamicIsland = "dynamic-island"
}

enum DynamicIslandTab: String, CaseIterable {
    case tasks
    case confirmation
    case quota
}

enum TaskSourceFilter: String, CaseIterable {
    case all
    case codex
    case claudeCode
}

enum TaskStateFilter: String, CaseIterable {
    case all
    case running
    case waitingForInput
    case completed
    case failed
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
        let sorted = sourceItems.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.title < $1.title }
            return $0.updatedAt > $1.updatedAt
        }
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
            let sourceMatches: Bool
            switch source {
            case .all:
                sourceMatches = true
            case .codex:
                sourceMatches = item.source == .codex
            case .claudeCode:
                sourceMatches = item.source == .claudeCode
            }
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
    var selectedQuotaProvider: QuotaProvider = .codex
    var permissionQueue = ClaudePermissionQueueSnapshot.empty
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
