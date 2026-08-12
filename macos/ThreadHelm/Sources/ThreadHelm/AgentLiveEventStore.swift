//
//  AgentLiveEventStore.swift
//  ThreadHelm
//
//  模块职责：把本地 endpoint 收到的脱敏 envelope 投影成受能力约束的事件，
//  并在内存中做有界、确定性的归并和过期处理。
//

import Foundation

enum AgentLiveEventPolicy {
    static let maximumEventsPerAgent = 256
    static let activeFreshness: TimeInterval = 5 * 60
    static let idleFreshness: TimeInterval = 30 * 60
    static let terminalFreshness: TimeInterval = 24 * 60 * 60
}

let hookObservedAgentIDs: Set<AgentID> = [.cursor, .zcode, .pi]

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
                metadata: metadata
            )
        let evidence = envelope.redactedPayload["evidenceQuality"]
            .flatMap(EvidenceQuality.init(rawValue:)) ?? .officialHook

        enforceCapabilityBoundary(
            agentID: envelope.agentID,
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
        metadata: AgentMetadata
    ) -> Actionability {
        guard agentID != .pi else { return .viewOnly }
        return metadata.capabilities.supports(.nativeNavigation)
            ? .openNativeApp
            : .viewOnly
    }

    private static func enforceCapabilityBoundary(
        agentID: AgentID,
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
        case .pi:
            if ![.taskFailure, .reviewReady, .none].contains(reason) {
                reason = .none
            }
            actionability = .viewOnly
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
    registry: AgentRegistry = .builtIn
) -> AgentDashboardProjection {
    let polledCollection = collection
    let polled = normalizedBuiltInAgentState(
        collection: polledCollection,
        permissionQueue: permissionQueue,
        registry: registry
    )
    let liveSnapshots = liveReduction.snapshots.filter {
        hookObservedAgentIDs.contains($0.identity.agentID)
    }
    var snapshotsByKey = Dictionary(
        uniqueKeysWithValues: polled.snapshots.map { ($0.identity.key, $0) }
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
    let attentionItems = snapshots.compactMap {
        snapshot -> AgentAttentionItem? in
        guard snapshot.attentionReason != .none else { return nil }
        return AgentAttentionItem(
            identity: snapshot.identity,
            reason: snapshot.attentionReason,
            actionability: snapshot.actionability,
            evidenceQuality: snapshot.evidenceQuality,
            updatedAt: snapshot.updatedAt,
            isInterrupting: snapshot.attentionReason.isInterrupting
        )
    }
    let fallbackItems = polledCollection.items.filter {
        !overlaidLiveKeys.contains($0.identityKey)
    }
    let liveItems = liveSnapshots.filter {
        overlaidLiveKeys.contains($0.identity.key)
    }.map(taskProgressItem(from:))
    return AgentDashboardProjection(
        taskCollection: .displaying(fallbackItems + liveItems),
        snapshots: snapshots,
        attentionItems: attentionItems
    )
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

func taskProgressItem(from snapshot: AgentSessionSnapshot) -> TaskProgressItem {
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
    return TaskProgressItem(
        title: snapshot.title,
        kind: kind,
        startedAt: snapshot.freshness.observedAt,
        updatedAt: snapshot.updatedAt,
        source: snapshot.identity.agentID,
        activityText: snapshot.activitySummary,
        statusOverride: status,
        sessionID: snapshot.identity.nativeID,
        workingDirectory: snapshot.workingDirectory,
        processID: snapshot.identity.processID,
        processStartIdentity: snapshot.identity.processStartIdentity
    )
}

final class AgentLiveEventStore {
    private let lock = NSLock()
    private var eventsByAgentID: [AgentID: [String: AgentEvent]] = [:]
    private var revision: UInt64 = 0

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
        guard let event = AgentTransportEnvelopeProjection.event(
            from: envelope,
            receivedAt: receivedAt,
            registry: registry
        ) else { return nil }

        lock.lock()
        var indexed = eventsByAgentID[event.identity.agentID] ?? [:]
        let storageKey = agentLiveEventStorageKey(event)
        if let existing = indexed[storageKey] {
            indexed[storageKey] = agentLiveEventIsEarlier(existing, event)
                ? event
                : existing
        } else {
            indexed[storageKey] = event
        }
        if indexed.count > AgentLiveEventPolicy.maximumEventsPerAgent {
            let orderedKeys = indexed.sorted {
                eventEvictionComesFirst($0.value, $1.value)
            }.map(\.key)
            for key in orderedKeys.prefix(
                indexed.count - AgentLiveEventPolicy.maximumEventsPerAgent
            ) {
                indexed.removeValue(forKey: key)
            }
        }
        eventsByAgentID[event.identity.agentID] = indexed
        let events = eventsByAgentID.values.flatMap { $0.values }
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
        let events = eventsByAgentID.values.flatMap { $0.values }
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
        let attentionItems = snapshots.compactMap {
            snapshot -> AgentAttentionItem? in
            guard snapshot.attentionReason != .none else { return nil }
            return AgentAttentionItem(
                identity: snapshot.identity,
                reason: snapshot.attentionReason,
                actionability: snapshot.actionability,
                evidenceQuality: snapshot.evidenceQuality,
                updatedAt: snapshot.updatedAt,
                isInterrupting: snapshot.attentionReason.isInterrupting
            )
        }
        return AgentReductionResult(
            snapshots: snapshots,
            attentionItems: attentionItems,
            processedEventCount: reduction.processedEventCount
        )
    }
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
    if lhs.attentionReason.isInterrupting != rhs.attentionReason.isInterrupting {
        return !lhs.attentionReason.isInterrupting
    }
    if lhs.observedAt != rhs.observedAt {
        return lhs.observedAt < rhs.observedAt
    }
    if lhs.identity.key != rhs.identity.key {
        return lhs.identity.key < rhs.identity.key
    }
    return lhs.eventID < rhs.eventID
}
