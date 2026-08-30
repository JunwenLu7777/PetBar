import Foundation

struct ClaudePermissionPresentation {
    let prompt: ClaudePermissionPrompt
    let queue: ClaudePermissionQueueSnapshot
    let onDecision: (ClaudePermissionUserDecision) -> Void
}

protocol ClaudePermissionPresenting: AnyObject {
    func present(_ presentation: ClaudePermissionPresentation)
    func dismiss()
    func reposition()
}

final class ClaudePermissionCoordinator {
    private struct Entry {
        let prompt: ClaudePermissionPrompt
        let arrivedAt: Date
        let agentVersionSignature: String?
        let completion: (ClaudePermissionUserDecision) -> Void
    }

    private let now: () -> Date
    private let openTerminal: (ClaudePermissionPrompt) -> Void
    private let onQueueChange: (ClaudePermissionQueueSnapshot) -> Void
    private let agentVersionSignature: (AgentID) -> String?
    private let onHistoryRecord: (PermissionDecisionHistoryRecord) -> Void
    private weak var presenter: ClaudePermissionPresenting?
    private var currentEntry: Entry?
    private var entries: [Entry] = []
    private var currentEntryWasWaitingForInput = false

    init(
        now: @escaping () -> Date = Date.init,
        openTerminal: @escaping (ClaudePermissionPrompt) -> Void,
        onQueueChange: @escaping (ClaudePermissionQueueSnapshot) -> Void,
        agentVersionSignature: @escaping (AgentID) -> String? = { _ in nil },
        onHistoryRecord: @escaping (PermissionDecisionHistoryRecord) -> Void = { _ in }
    ) {
        self.now = now
        self.openTerminal = openTerminal
        self.onQueueChange = onQueueChange
        self.agentVersionSignature = agentVersionSignature
        self.onHistoryRecord = onHistoryRecord
    }

    func setPresenter(_ presenter: ClaudePermissionPresenting?) {
        self.presenter?.dismiss()
        self.presenter = presenter
        guard currentEntry != nil else { return }
        presenter?.present(presentation())
    }

    func enqueue(
        prompt: ClaudePermissionPrompt,
        completion: @escaping (ClaudePermissionUserDecision) -> Void
    ) {
        let alreadyQueued = currentEntry?.prompt.requestID == prompt.requestID
            || entries.contains { $0.prompt.requestID == prompt.requestID }
        guard !alreadyQueued else { return }

        entries.append(Entry(
            prompt: prompt,
            arrivedAt: now(),
            agentVersionSignature: agentVersionSignature(prompt.agentID),
            completion: completion
        ))
        if currentEntry == nil {
            promoteNext()
        } else {
            publishQueueChange()
        }
    }

    func expire(requestID: UUID) {
        if let entry = currentEntry,
           entry.prompt.requestID == requestID
        {
            currentEntry = nil
            currentEntryWasWaitingForInput = false
            presenter?.dismiss()
            recordHistory(entry, outcome: .expired, decidedAt: now())
            promoteNext()
            return
        }

        if let index = entries.firstIndex(where: {
            $0.prompt.requestID == requestID
        }) {
            let entry = entries.remove(at: index)
            recordHistory(entry, outcome: .expired, decidedAt: now())
            publishQueueChange()
        }
    }

    @discardableResult
    func dismissIfAnsweredInTerminal(in tasks: [TaskProgressItem]) -> Bool {
        guard let entry = currentEntry,
              let task = claudeTaskItem(
                  forSessionID: entry.prompt.sessionID,
                  in: tasks
              )
        else {
            return false
        }
        if task.kind == .waitingForInput {
            currentEntryWasWaitingForInput = true
            return false
        }
        guard currentEntryWasWaitingForInput else { return false }
        finishCurrent(
            requestID: entry.prompt.requestID,
            decision: .nativeFallback,
            openTerminal: false
        )
        return true
    }

    @discardableResult
    func handoffToTerminalIfPresenting(_ task: TaskProgressItem) -> Bool {
        guard let entry = currentEntry,
              claudeTaskItem(
                  forSessionID: entry.prompt.sessionID,
                  in: [task]
              ) != nil
        else {
            return false
        }
        finishCurrent(
            requestID: entry.prompt.requestID,
            decision: .nativeFallback,
            openTerminal: true
        )
        return true
    }

    func cancelAll() {
        let outstanding = [currentEntry].compactMap { $0 } + entries
        guard !outstanding.isEmpty else {
            presenter?.dismiss()
            return
        }
        currentEntry = nil
        entries.removeAll()
        currentEntryWasWaitingForInput = false
        presenter?.dismiss()
        publishQueueChange()
        let decidedAt = now()
        outstanding.forEach {
            $0.completion(.nativeFallback)
            recordHistory($0, outcome: .nativeFallback, decidedAt: decidedAt)
        }
    }

    private func finishCurrent(
        requestID: UUID,
        decision: ClaudePermissionUserDecision,
        openTerminal shouldOpenTerminal: Bool
    ) {
        guard let entry = currentEntry,
              entry.prompt.requestID == requestID
        else { return }
        currentEntry = nil
        currentEntryWasWaitingForInput = false
        presenter?.dismiss()
        publishQueueChange()
        entry.completion(decision)
        recordHistory(
            entry,
            outcome: permissionHistoryOutcome(for: decision),
            decidedAt: now()
        )
        if shouldOpenTerminal {
            openTerminal(entry.prompt)
        }
        promoteNext()
    }

    private func promoteNext() {
        guard currentEntry == nil, !entries.isEmpty else {
            publishQueueChange()
            return
        }
        currentEntry = entries.removeFirst()
        currentEntryWasWaitingForInput = false
        publishQueueChange()
        presenter?.present(presentation())
    }

    private func presentation() -> ClaudePermissionPresentation {
        let entry = currentEntry!
        let requestID = entry.prompt.requestID
        return ClaudePermissionPresentation(
            prompt: entry.prompt,
            queue: queueSnapshot(),
            onDecision: { [weak self] decision in
                self?.finishCurrent(
                    requestID: requestID,
                    decision: decision,
                    openTerminal: {
                        if case .nativeFallback = decision { return true }
                        return false
                    }()
                )
            }
        )
    }

    private func publishQueueChange() {
        onQueueChange(queueSnapshot())
    }

    private func recordHistory(
        _ entry: Entry,
        outcome: PermissionHistoryOutcome,
        decidedAt: Date
    ) {
        onHistoryRecord(PermissionDecisionHistoryRecord(
            agentID: entry.prompt.agentID,
            interactionKind: entry.prompt.interactionKind,
            outcome: outcome,
            receivedAt: entry.arrivedAt,
            decidedAt: decidedAt,
            agentVersionSignature: entry.agentVersionSignature
        ))
    }

    private func queueSnapshot() -> ClaudePermissionQueueSnapshot {
        ClaudePermissionQueueSnapshot(
            current: currentEntry.map(queueItem),
            pending: entries.map(queueItem)
        )
    }

    private func queueItem(for entry: Entry) -> ClaudePermissionQueueItem {
        ClaudePermissionQueueItem(
            requestID: entry.prompt.requestID,
            interactionKind: entry.prompt.interactionKind,
            title: entry.prompt.title,
            sessionID: entry.prompt.sessionID,
            arrivedAt: entry.arrivedAt,
            agentID: entry.prompt.agentID
        )
    }
}
