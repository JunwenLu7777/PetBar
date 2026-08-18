//
//  AgentLiveEventStore.swift
//  ThreadHelm
//
//  模块职责：把本地 endpoint 收到的脱敏 envelope 投影成受能力约束的事件，
//  并在内存中做有界、确定性的归并和过期处理。
//

import Foundation

enum AgentLiveEventPolicy {
    static let maximumEventsPerAgent = AgentTransportContract.maximumQueuedEvents
    static let maximumBytesPerAgent = AgentTransportContract.maximumQueuedBytes
    static let activeFreshness: TimeInterval = 5 * 60
    static let idleFreshness: TimeInterval = 30 * 60
    static let terminalFreshness: TimeInterval = 24 * 60 * 60
}

let hookObservedAgentIDs: Set<AgentID> = [.cursor, .zcode, .omp]

enum AgentTransportEnvelopeProjection {
    static func event(
        from envelope: AgentTransportEnvelope,
        receivedAt: Date = Date(),
        registry: AgentRegistry = .builtIn
    ) -> AgentEvent? {
        guard envelope.schemaVersion == AgentTransportContract.schemaVersion,
              hookObservedAgentIDs.contains(envelope.agentID),
              let metadata = registry.metadata(for: envelope.agentID),
              let stateValue = envelope.redactedPayload["state"],
              var state = ExecutionState(rawValue: stateValue)
        else { return nil }

        var reason = envelope.redactedPayload["attentionReason"]
            .flatMap(AttentionReason.init(rawValue:)) ?? .none
        var actionability = envelope.redactedPayload["actionability"]
            .flatMap(Actionability.init(rawValue:)) ?? defaultActionability(
                for: envelope.agentID,
                metadata: metadata,
                nativeSessionCandidate: envelope.nativeSessionCandidate
            )
        let evidence = envelope.redactedPayload["evidenceQuality"]
            .flatMap(EvidenceQuality.init(rawValue:)) ?? .officialHook

        enforceCapabilityBoundary(
            agentID: envelope.agentID,
            nativeSessionCandidate: envelope.nativeSessionCandidate,
            state: &state,
            reason: &reason,
            actionability: &actionability
        )

        let isExplicitlyStale = envelope.redactedPayload["freshness"] == "stale"
        if isExplicitlyStale {
            state = .stale
            reason = .none
            actionability = .viewOnly
        }
        let expiresAt = isExplicitlyStale
            ? receivedAt
            : receivedAt.addingTimeInterval(freshnessInterval(for: state))
        let nativeID = envelope.nativeSessionCandidate ?? "unidentified"
        return AgentEvent(
            identity: AgentSessionIdentity(
                agentID: envelope.agentID,
                nativeID: nativeID
            ),
            adapterVersion: envelope.adapterVersion,
            eventID: envelope.eventID,
            sequence: envelope.sequence,
            eventType: envelope.eventType,
            observedAt: receivedAt,
            monotonicNanoseconds: envelope.monotonicNanoseconds,
            executionState: state,
            attentionReason: reason,
            actionability: actionability,
            evidenceQuality: evidence,
            freshness: Freshness(
                observedAt: receivedAt,
                expiresAt: expiresAt,
                staleReason: isExplicitlyStale ? "adapter-reported-stale" : nil
            ),
            title: "\(metadata.displayName) 会话",
            activitySummary: safeActivitySummary(state: state, reason: reason),
            workingDirectory: nil
        )
    }

    private static func defaultActionability(
        for agentID: AgentID,
        metadata: AgentMetadata,
        nativeSessionCandidate: String?
    ) -> Actionability {
        if agentID == .omp {
            return nativeSessionCandidate.flatMap(normalizedOMPSessionID) != nil
                ? .openExactNativeSession
                : .viewOnly
        }
        return metadata.capabilities.supports(.nativeNavigation)
            ? .openNativeApp
            : .viewOnly
    }

    private static func enforceCapabilityBoundary(
        agentID: AgentID,
        nativeSessionCandidate: String?,
        state: inout ExecutionState,
        reason: inout AttentionReason,
        actionability: inout Actionability
    ) {
        if state == .stale || state == .offline {
            reason = .none
            actionability = .viewOnly
            return
        }

        if reason == .taskFailure, state != .failed {
            reason = .none
        }
        if reason == .reviewReady, state != .completed {
            reason = .none
        }

        switch agentID {
        case .cursor, .zcode:
            if ![.taskFailure, .reviewReady, .none].contains(reason) {
                reason = .none
            }
            if actionability == .inApp
                || actionability == .openExactNativeSession
            {
                actionability = .openNativeApp
            }
        case .omp:
            if ![.taskFailure, .reviewReady, .none].contains(reason) {
                reason = .none
            }
            actionability = nativeSessionCandidate
                .flatMap(normalizedOMPSessionID) != nil
                ? .openExactNativeSession
                : .viewOnly
        case .codex, .claudeCode:
            break
        default:
            if actionability == .inApp {
                actionability = .viewOnly
            }
        }
    }

    private static func freshnessInterval(
        for state: ExecutionState
    ) -> TimeInterval {
        switch state {
        case .completed, .failed:
            return AgentLiveEventPolicy.terminalFreshness
        case .idle:
            return AgentLiveEventPolicy.idleFreshness
        case .discovering, .running:
            return AgentLiveEventPolicy.activeFreshness
        case .stale, .offline:
            return 0
        }
    }

    private static func safeActivitySummary(
        state: ExecutionState,
        reason: AttentionReason
    ) -> String? {
        switch reason {
        case .taskFailure: return "任务失败，等待查看"
        case .reviewReady: return "任务结束，可查看结果"
        case .permission: return "等待权限确认"
        case .question: return "等待回答"
        case .planApproval: return "等待计划确认"
        case .blocked: return "任务已阻塞"
        case .none:
            switch state {
            case .discovering: return "正在发现会话"
            case .idle: return "会话空闲"
            case .running: return "正在执行"
            case .completed: return "任务已结束"
            case .failed: return "任务失败"
            case .stale: return "状态已过期"
            case .offline: return "会话已离线"
            }
        }
    }
}

struct AgentDashboardProjection: Equatable {
    let taskCollection: TaskProgressCollectionSnapshot
    let snapshots: [AgentSessionSnapshot]
    let attentionItems: [AgentAttentionItem]
}

func agentDashboardProjection(
    collection: TaskProgressCollectionSnapshot,
    permissionQueue: ClaudePermissionQueueSnapshot,
    liveReduction: AgentReductionResult,
    agentCompatibilities: [AgentID: AgentCompatibility],
    registry: AgentRegistry = .builtIn,
    cursorWorkingDirectory: (String) -> String? = {
        Thread.isMainThread
            ? CursorLocalWorkspace.cachedWorkingDirectory(sessionID: $0)
            : CursorLocalWorkspace.workingDirectory(sessionID: $0)
    },
    cursorSessionContent: (String) -> CursorLocalSessionContent? = {
        Thread.isMainThread
            ? CursorLocalWorkspace.cachedSessionContent(sessionID: $0)
            : CursorLocalWorkspace.sessionContent(sessionID: $0)
    },
    ompSessionContent: (String) -> OMPLocalSessionContent? = {
        Thread.isMainThread
            ? OMPLocalSession.cachedContent(sessionID: $0)
            : OMPLocalSession.content(sessionID: $0)
    }
) -> AgentDashboardProjection {
    let polledCollection = collection
    let polled = normalizedBuiltInAgentState(
        collection: polledCollection,
        permissionQueue: permissionQueue,
        registry: registry
    )
    let polledSnapshots = polled.snapshots.map {
        validationBoundedSnapshot(
            $0,
            compatibility: agentCompatibilities[$0.identity.agentID]
        )
    }
    let liveSnapshots = liveReduction.snapshots.filter {
        hookObservedAgentIDs.contains($0.identity.agentID)
            && isDisplayableLiveSnapshot($0)
    }.map {
        validationBoundedSnapshot(
            $0,
            compatibility: agentCompatibilities[$0.identity.agentID]
        )
    }
    var snapshotsByKey = Dictionary(
        uniqueKeysWithValues: polledSnapshots.map { ($0.identity.key, $0) }
    )
    var overlaidLiveKeys = Set<String>()
    for snapshot in liveSnapshots {
        let existing = snapshotsByKey[snapshot.identity.key]
        let liveCanOverlay = existing == nil || (
            snapshot.executionState != .stale
                && snapshot.updatedAt >= existing!.updatedAt
        )
        if liveCanOverlay {
            snapshotsByKey[snapshot.identity.key] = snapshot
            overlaidLiveKeys.insert(snapshot.identity.key)
        }
    }
    let snapshots = snapshotsByKey.values.sorted(by: agentSnapshotIsOrderedBefore)
    let attentionItems = agentAttentionItems(from: snapshots)
    let fallbackItems = polledCollection.items.filter {
        !overlaidLiveKeys.contains($0.identityKey)
    }.map {
        validationBoundedTaskProgressItem(
            $0,
            compatibility: agentCompatibilities[$0.source]
        )
    }
    let eventsByIdentity = Dictionary(
        grouping: liveReduction.events,
        by: \.identity.key
    )
    let liveItems = liveSnapshots.filter {
        overlaidLiveKeys.contains($0.identity.key)
    }.map { snapshot in
        let compatibility = agentCompatibilities[snapshot.identity.agentID]
        let events = eventsByIdentity[snapshot.identity.key] ?? []
        let item: TaskProgressItem
        if snapshot.identity.agentID == .cursor,
           compatibility != .validated
        {
            item = taskProgressItem(
                from: snapshot,
                events: events,
                cursorWorkingDirectory: { _ in nil },
                cursorSessionContent: { _ in nil },
                ompSessionContent: ompSessionContent
            )
        } else {
            item = taskProgressItem(
                from: snapshot,
                events: events,
                cursorWorkingDirectory: cursorWorkingDirectory,
                cursorSessionContent: cursorSessionContent,
                ompSessionContent: ompSessionContent
            )
        }
        return validationBoundedTaskProgressItem(
            item,
            compatibility: compatibility
        )
    }
    return AgentDashboardProjection(
        taskCollection: .displaying(fallbackItems + liveItems),
        snapshots: snapshots,
        attentionItems: attentionItems
    )
}

private func isDisplayableLiveSnapshot(_ snapshot: AgentSessionSnapshot) -> Bool {
    guard snapshot.identity.agentID == .cursor else { return true }
    let nativeID = snapshot.identity.nativeID
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return nativeID.count >= 8
        && nativeID != "unidentified"
        && nativeID != "unknown-session"
        && !nativeID.hasPrefix("unknown-")
}

private func validationBoundedSnapshot(
    _ snapshot: AgentSessionSnapshot,
    compatibility: AgentCompatibility?
) -> AgentSessionSnapshot {
    guard compatibility == .validated else {
        return AgentSessionSnapshot(
            identity: snapshot.identity,
            adapterVersion: snapshot.adapterVersion,
            executionState: snapshot.executionState,
            attentionReason: .none,
            actionability: snapshot.actionability,
            evidenceQuality: snapshot.evidenceQuality,
            freshness: snapshot.freshness,
            title: snapshot.title,
            activitySummary: validationBoundedActivitySummary(
                for: snapshot.executionState
            ),
            workingDirectory: snapshot.workingDirectory,
            latestEventID: snapshot.latestEventID,
            updatedAt: snapshot.updatedAt
        )
    }
    return snapshot
}

private func validationBoundedTaskProgressItem(
    _ item: TaskProgressItem,
    compatibility: AgentCompatibility?
) -> TaskProgressItem {
    guard compatibility == .validated else {
        return TaskProgressItem(
            title: item.title,
            kind: item.kind,
            startedAt: item.startedAt,
            updatedAt: item.updatedAt,
            source: item.source,
            activityText: validationBoundedTaskActivityText(for: item.kind),
            statusOverride: item.statusOverride,
            threadID: item.threadID,
            sessionID: item.sessionID,
            workingDirectory: item.workingDirectory,
            processID: item.processID,
            processStartIdentity: item.processStartIdentity,
            projection: item.projection,
            allowsAgentOpen: item.canOpen
        )
    }
    return item
}

private func validationBoundedActivitySummary(
    for state: ExecutionState
) -> String? {
    switch state {
    case .discovering: return "正在发现会话"
    case .idle: return "会话空闲"
    case .running: return "正在执行"
    case .completed: return "任务已结束"
    case .failed: return "任务失败"
    case .stale: return "状态已过期"
    case .offline: return "会话已离线"
    }
}

private func validationBoundedTaskActivityText(
    for kind: TaskProgressKind
) -> String? {
    switch kind {
    case .reading: return "正在读取状态"
    case .running: return "正在执行"
    case .completed: return "任务已结束"
    case .failed: return "任务失败"
    case .idle: return "会话空闲"
    case .waitingForInput: return nil
    }
}

struct AgentLiveReductionUpdate {
    let revision: UInt64
    let reduction: AgentReductionResult
}

struct AgentLiveReductionGate {
    private(set) var latestAppliedRevision: UInt64?

    mutating func shouldApply(revision: UInt64) -> Bool {
        if let latestAppliedRevision,
           revision <= latestAppliedRevision
        {
            return false
        }
        latestAppliedRevision = revision
        return true
    }
}

func taskProgressItem(
    from snapshot: AgentSessionSnapshot,
    events: [AgentEvent] = [],
    cursorWorkingDirectory: (String) -> String? = {
        Thread.isMainThread
            ? CursorLocalWorkspace.cachedWorkingDirectory(sessionID: $0)
            : CursorLocalWorkspace.workingDirectory(sessionID: $0)
    },
    cursorSessionContent: (String) -> CursorLocalSessionContent? = {
        Thread.isMainThread
            ? CursorLocalWorkspace.cachedSessionContent(sessionID: $0)
            : CursorLocalWorkspace.sessionContent(sessionID: $0)
    },
    ompSessionContent: (String) -> OMPLocalSessionContent? = {
        Thread.isMainThread
            ? OMPLocalSession.cachedContent(sessionID: $0)
            : OMPLocalSession.content(sessionID: $0)
    }
) -> TaskProgressItem {
    let kind: TaskProgressKind
    switch snapshot.attentionReason {
    case .permission, .question, .planApproval, .blocked:
        kind = .waitingForInput
    case .taskFailure:
        kind = .failed
    case .reviewReady:
        kind = .completed
    case .none:
        switch snapshot.executionState {
        case .discovering: kind = .reading
        case .idle, .stale, .offline: kind = .idle
        case .running: kind = .running
        case .completed: kind = .completed
        case .failed: kind = .failed
        }
    }
    let status: String?
    switch snapshot.attentionReason {
    case .permission: status = "等待权限确认"
    case .question: status = "等待回答"
    case .planApproval: status = "等待计划确认"
    case .blocked: status = "已阻塞"
    case .reviewReady: status = "可查看结果"
    case .taskFailure: status = "任务失败"
    case .none:
        switch snapshot.executionState {
        case .stale: status = "状态已过期"
        case .offline: status = "已离线"
        default: status = nil
        }
    }
    let sessionEvents = events.filter { $0.identity.key == snapshot.identity.key }
    let startedAt = sessionEvents.map(\.observedAt).min()
        ?? snapshot.freshness.observedAt
    let localContent = snapshot.identity.agentID == .cursor
        ? cursorSessionContent(snapshot.identity.nativeID)
        : nil
    let localOMPContent = snapshot.identity.agentID == .omp
        ? ompSessionContent(snapshot.identity.nativeID)
        : nil
    let hookEvents = CursorLocalWorkspace.activityEvents(from: sessionEvents)
    let hookProjection = liveHookProjection(
        from: sessionEvents,
        source: snapshot.identity.agentID,
        sessionKey: snapshot.identity.nativeID,
        kind: kind
    )
    let localProjection: AgentActivityProjection?
    if snapshot.identity.agentID == .cursor, localContent != nil {
        localProjection = localContent?.projection
    } else if snapshot.identity.agentID == .omp, localOMPContent != nil {
        localProjection = localOMPContent?.projection
    } else {
        localProjection = nil
    }
    let projection = mergeAgentActivityProjection(
        local: localProjection,
        hook: hookProjection,
        kind: kind
    ).budgeted()
    let resolvedDirectory: String?
    if let existing = snapshot.workingDirectory {
        resolvedDirectory = existing
    } else if snapshot.identity.agentID == .cursor {
        resolvedDirectory = cursorWorkingDirectory(snapshot.identity.nativeID)
    } else if snapshot.identity.agentID == .omp {
        resolvedDirectory = localOMPContent?.workingDirectory
    } else {
        resolvedDirectory = nil
    }
    let title: String
    if let localTitle = localContent?.title, !localTitle.isEmpty {
        title = localTitle
    } else if let resolvedDirectory,
              snapshot.identity.agentID == .cursor
    {
        let projectName = URL(fileURLWithPath: resolvedDirectory).lastPathComponent
        title = projectName.isEmpty ? snapshot.title : projectName
    } else {
        title = snapshot.title
    }
    return TaskProgressItem(
        title: title,
        kind: kind,
        startedAt: startedAt,
        updatedAt: snapshot.updatedAt,
        source: snapshot.identity.agentID,
        activityText: liveCardActivityText(
            kind: kind,
            agentID: snapshot.identity.agentID,
            hookEvents: hookEvents,
            projection: projection,
            snapshotSummary: snapshot.activitySummary
        ),
        statusOverride: status,
        sessionID: snapshot.identity.nativeID,
        workingDirectory: resolvedDirectory,
        processID: snapshot.identity.processID,
        processStartIdentity: snapshot.identity.processStartIdentity,
        projection: projection,
        allowsAgentOpen: snapshot.actionability != .viewOnly
    )
}

private func liveCardActivityText(
    kind: TaskProgressKind,
    agentID: AgentID,
    hookEvents: [TaskActivityEvent],
    projection: AgentActivityProjection,
    snapshotSummary: String?
) -> String? {
    if agentID == .cursor {
        switch kind {
        case .completed:
            return "本轮已完成"
        case .failed:
            return "任务执行失败"
        case .waitingForInput:
            return "等待你的输入"
        case .reading:
            return "正在读取"
        case .idle:
            return "等待任务"
        case .running:
            if let latestStatusEvent = hookEvents.last {
                switch latestStatusEvent.kind {
                case .tool:
                    return latestStatusEvent.text
                case .commentary:
                    return "正在思考"
                case .lifecycle:
                    switch latestStatusEvent.text {
                    case "会话开始": return "等待任务"
                    case "启动子任务": return "正在处理子任务"
                    case "子任务结束": return "正在整理结果"
                    default: return snapshotSummary ?? "正在执行"
                    }
                }
            }
            return projection.currentToolStatus?.text
                ?? projection.publicMessages.first?.text
                ?? snapshotSummary
                ?? "正在执行"
        }
    }
    return kind.isActive
        ? (projection.currentToolStatus?.text
            ?? projection.publicMessages.first?.text
            ?? snapshotSummary)
        : nil
}

private func liveHookProjection(
    from events: [AgentEvent],
    source: AgentID,
    sessionKey: String,
    kind: TaskProgressKind
) -> AgentActivityProjection {
    var publicMessages: [AgentActivityEntry] = []
    var currentToolStatus: AgentActivityEntry?
    var terminalEvent: AgentActivityEntry?
    let hasTerminalKind = kind == .completed || kind == .failed
    for event in events.sorted(by: agentEventIsOrderedBefore) {
        guard let activity = CursorLocalWorkspace.activityEvent(from: event)
        else { continue }
        let sourceOrder = UInt64(event.sequence ?? 0)
        let entry = AgentActivityEntry(
            id: AgentActivityEventID(
                source: source,
                sessionKey: sessionKey,
                stableSourceKey: liveHookStableSourceKey(event)
            ),
            occurredAt: event.observedAt,
            sourceOrder: sourceOrder,
            text: activity.text
        )
        switch activity.kind {
        case .commentary:
            publicMessages.append(entry)
        case .tool:
            currentToolStatus = entry
        case .lifecycle:
            if hasTerminalKind {
                terminalEvent = entry
                currentToolStatus = nil
            }
        }
    }
    return AgentActivityProjection(
        publicMessages: publicMessages,
        currentToolStatus: currentToolStatus,
        terminalEvent: terminalEvent
    )
}

private func mergeAgentActivityProjection(
    local: AgentActivityProjection?,
    hook: AgentActivityProjection,
    kind: TaskProgressKind
) -> AgentActivityProjection {
    var projection = local ?? AgentActivityProjection(
        publicMessages: hook.publicMessages,
        currentToolStatus: nil,
        terminalEvent: nil
    )
    if projection.publicMessages.isEmpty {
        projection.publicMessages = hook.publicMessages
    }
    if kind.isActive {
        if let hookTool = hook.currentToolStatus {
            projection.currentToolStatus = hookTool
        } else if projection.currentToolStatus == nil {
            projection.currentToolStatus = local?.currentToolStatus
        }
        projection.terminalEvent = nil
    } else {
        projection.terminalEvent = hook.terminalEvent ?? local?.terminalEvent
        projection.currentToolStatus = nil
    }
    return projection
}

private func agentEventIsOrderedBefore(
    _ lhs: AgentEvent,
    _ rhs: AgentEvent
) -> Bool {
    if let lhsSequence = lhs.sequence,
       let rhsSequence = rhs.sequence,
       lhsSequence != rhsSequence
    {
        return lhsSequence < rhsSequence
    }
    if let lhsMonotonic = lhs.monotonicNanoseconds,
       let rhsMonotonic = rhs.monotonicNanoseconds,
       lhsMonotonic != rhsMonotonic
    {
        return lhsMonotonic < rhsMonotonic
    }
    if lhs.observedAt != rhs.observedAt {
        return lhs.observedAt < rhs.observedAt
    }
    return lhs.eventID < rhs.eventID
}

private func liveHookStableSourceKey(_ event: AgentEvent) -> String {
    if let sequence = event.sequence {
        return "hook:\(event.eventID):sequence:\(sequence)"
    }
    return "hook:\(event.eventID)"
}

final class AgentLiveEventStore {
    private let lock = NSLock()
    private let maximumEventsPerAgent: Int
    private let maximumBytesPerAgent: Int
    private var eventsByAgentID: [AgentID: [String: RetainedAgentLiveEvent]] = [:]
    private var revision: UInt64 = 0

    init(
        maximumEventsPerAgent: Int = AgentLiveEventPolicy.maximumEventsPerAgent,
        maximumBytesPerAgent: Int = AgentLiveEventPolicy.maximumBytesPerAgent
    ) {
        precondition(maximumEventsPerAgent > 0)
        precondition(maximumBytesPerAgent > 0)
        self.maximumEventsPerAgent = maximumEventsPerAgent
        self.maximumBytesPerAgent = maximumBytesPerAgent
    }

    @discardableResult
    func ingest(
        _ envelope: AgentTransportEnvelope,
        receivedAt: Date = Date(),
        registry: AgentRegistry = .builtIn
    ) -> AgentReductionResult? {
        ingestUpdate(
            envelope,
            receivedAt: receivedAt,
            registry: registry
        )?.reduction
    }

    @discardableResult
    func ingestUpdate(
        _ envelope: AgentTransportEnvelope,
        receivedAt: Date = Date(),
        registry: AgentRegistry = .builtIn
    ) -> AgentLiveReductionUpdate? {
        let normalizedEnvelope = AgentTransportEnvelope(
            agentID: envelope.agentID,
            adapterVersion: envelope.adapterVersion,
            nativeSessionCandidate: envelope.nativeSessionCandidate,
            eventID: envelope.eventID,
            sequence: envelope.sequence,
            eventType: envelope.eventType,
            monotonicNanoseconds: envelope.monotonicNanoseconds,
            redactedPayload: envelope.redactedPayload
        )
        guard let encoding = try? AgentTransportEncoder.encode(normalizedEnvelope),
              !encoding.wasReducedToMetadata,
              encoding.data.count <= AgentTransportContract.maximumSerializedBytes,
              let event = AgentTransportEnvelopeProjection.event(
                  from: normalizedEnvelope,
                  receivedAt: receivedAt,
                  registry: registry
              )
        else { return nil }

        lock.lock()
        var indexed = eventsByAgentID[event.identity.agentID] ?? [:]
        let storageKey = agentLiveEventStorageKey(event)
        let retained = RetainedAgentLiveEvent(
            event: event,
            serializedByteCount: encoding.data.count
        )
        if let existing = indexed[storageKey] {
            indexed[storageKey] = agentLiveEventIsEarlier(existing.event, event)
                ? retained
                : existing
        } else {
            indexed[storageKey] = retained
        }
        var retainedByteCount = indexed.values.reduce(0) {
            $0 + $1.serializedByteCount
        }
        if indexed.count > maximumEventsPerAgent
            || retainedByteCount > maximumBytesPerAgent
        {
            let orderedKeys = indexed.sorted {
                eventEvictionComesFirst($0.value.event, $1.value.event)
            }.map(\.key)
            for key in orderedKeys where indexed.count > maximumEventsPerAgent
                || retainedByteCount > maximumBytesPerAgent
            {
                if let removed = indexed.removeValue(forKey: key) {
                    retainedByteCount -= removed.serializedByteCount
                }
            }
        }
        eventsByAgentID[event.identity.agentID] = indexed
        let events = eventsByAgentID.values.flatMap { values in
            values.values.map(\.event)
        }
        revision &+= 1
        let updateRevision = revision
        lock.unlock()
        return AgentLiveReductionUpdate(
            revision: updateRevision,
            reduction: freshened(
                AgentEventReducer.reduce(events: events),
                at: receivedAt
            )
        )
    }

    func snapshot(at now: Date = Date()) -> AgentReductionResult {
        snapshotUpdate(at: now).reduction
    }

    func snapshotUpdate(at now: Date = Date()) -> AgentLiveReductionUpdate {
        lock.lock()
        let events = eventsByAgentID.values.flatMap { values in
            values.values.map(\.event)
        }
        revision &+= 1
        let updateRevision = revision
        lock.unlock()
        return AgentLiveReductionUpdate(
            revision: updateRevision,
            reduction: freshened(
                AgentEventReducer.reduce(events: events),
                at: now
            )
        )
    }

    func retainedSerializedByteCount(for agentID: AgentID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return eventsByAgentID[agentID]?.values.reduce(0) {
            $0 + $1.serializedByteCount
        } ?? 0
    }

    private func freshened(
        _ reduction: AgentReductionResult,
        at now: Date
    ) -> AgentReductionResult {
        let snapshots = reduction.snapshots.map { snapshot in
            guard snapshot.freshness.isStale(at: now),
                  snapshot.executionState != .offline
            else { return snapshot }
            return AgentSessionSnapshot(
                identity: snapshot.identity,
                adapterVersion: snapshot.adapterVersion,
                executionState: .stale,
                attentionReason: .none,
                actionability: .viewOnly,
                evidenceQuality: snapshot.evidenceQuality,
                freshness: Freshness(
                    observedAt: snapshot.freshness.observedAt,
                    expiresAt: snapshot.freshness.expiresAt,
                    staleReason: snapshot.freshness.staleReason
                        ?? "adapter-freshness-expired"
                ),
                title: snapshot.title,
                activitySummary: "状态已过期",
                workingDirectory: nil,
                latestEventID: snapshot.latestEventID,
                updatedAt: snapshot.updatedAt
            )
        }.sorted(by: agentSnapshotIsOrderedBefore)
        let attentionItems = agentAttentionItems(from: snapshots)
        return AgentReductionResult(
            snapshots: snapshots,
            attentionItems: attentionItems,
            processedEventCount: reduction.processedEventCount,
            events: reduction.events
        )
    }
}

private struct RetainedAgentLiveEvent {
    let event: AgentEvent
    let serializedByteCount: Int
}

private func agentLiveEventStorageKey(_ event: AgentEvent) -> String {
    let identity = event.identity.key
    return "\(identity.utf8.count):\(identity)\(event.eventID)"
}

private func agentLiveEventIsEarlier(_ lhs: AgentEvent, _ rhs: AgentEvent) -> Bool {
    if let lhsSequence = lhs.sequence,
       let rhsSequence = rhs.sequence,
       lhsSequence != rhsSequence
    {
        return lhsSequence < rhsSequence
    }
    if let lhsMonotonic = lhs.monotonicNanoseconds,
       let rhsMonotonic = rhs.monotonicNanoseconds,
       lhsMonotonic != rhsMonotonic
    {
        return lhsMonotonic < rhsMonotonic
    }
    if lhs.observedAt != rhs.observedAt {
        return lhs.observedAt < rhs.observedAt
    }
    if lhs.executionState.rawValue != rhs.executionState.rawValue {
        return lhs.executionState.rawValue < rhs.executionState.rawValue
    }
    if lhs.attentionReason.rawValue != rhs.attentionReason.rawValue {
        return lhs.attentionReason.rawValue < rhs.attentionReason.rawValue
    }
    return lhs.eventType < rhs.eventType
}

private func eventEvictionComesFirst(
    _ lhs: AgentEvent,
    _ rhs: AgentEvent
) -> Bool {
    let lhsHasAttention = lhs.attentionReason != .none
    let rhsHasAttention = rhs.attentionReason != .none
    if lhsHasAttention != rhsHasAttention {
        return !lhsHasAttention
    }
    if lhs.observedAt != rhs.observedAt {
        return lhs.observedAt < rhs.observedAt
    }
    if lhs.identity.key != rhs.identity.key {
        return lhs.identity.key < rhs.identity.key
    }
    return lhs.eventID < rhs.eventID
}
