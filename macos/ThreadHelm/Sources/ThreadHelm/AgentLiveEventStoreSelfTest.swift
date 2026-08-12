//
//  AgentLiveEventStoreSelfTest.swift
//  ThreadHelm
//
//  模块职责：验证脱敏 envelope 投影、能力降级、有界归并和 stale 规则。
//

import Foundation

func runAgentLiveEventStoreSelfTest() {
    let base = Date(timeIntervalSince1970: 1_786_510_000)
    let piEscalation = makeLiveStoreEnvelope(
        agentID: .pi,
        eventID: "pi-escalation",
        sequence: 1,
        state: .running,
        reason: .permission,
        actionability: .inApp
    )
    guard let piEvent = AgentTransportEnvelopeProjection.event(
        from: piEscalation,
        receivedAt: base
    ), piEvent.attentionReason == .none,
       piEvent.actionability == .viewOnly,
       piEvent.workingDirectory == nil,
       !piEvent.title.contains("/")
    else {
        failAgentLiveEventStoreSelfTest("Pi state-only capability boundary")
    }

    let invalidFailure = makeLiveStoreEnvelope(
        agentID: .cursor,
        eventID: "cursor-invalid-failure",
        sequence: 1,
        state: .running,
        reason: .taskFailure,
        actionability: .openExactNativeSession
    )
    guard let invalidFailureEvent = AgentTransportEnvelopeProjection.event(
        from: invalidFailure,
        receivedAt: base
    ), invalidFailureEvent.attentionReason == .none,
       invalidFailureEvent.actionability == .openNativeApp
    else {
        failAgentLiveEventStoreSelfTest("Cursor truth downgrade")
    }

    let store = AgentLiveEventStore()
    let running = makeLiveStoreEnvelope(
        agentID: .zcode,
        eventID: "zcode-running",
        sequence: 1,
        state: .running
    )
    let failure = makeLiveStoreEnvelope(
        agentID: .zcode,
        eventID: "zcode-failure",
        sequence: 2,
        state: .failed,
        reason: .taskFailure
    )
    _ = store.ingest(failure, receivedAt: base.addingTimeInterval(1))
    _ = store.ingest(running, receivedAt: base)
    _ = store.ingest(failure, receivedAt: base.addingTimeInterval(1))
    _ = store.ingest(
        makeLiveStoreEnvelope(
            agentID: .zcode,
            eventID: "zcode-failure",
            sequence: 1,
            state: .running
        ),
        receivedAt: base.addingTimeInterval(2)
    )
    let reduced = store.snapshot(at: base.addingTimeInterval(2))
    guard reduced.processedEventCount == 2,
          reduced.snapshots.count == 1,
          reduced.snapshots.first?.executionState == .failed,
          reduced.snapshots.first?.attentionReason == .taskFailure,
          reduced.attentionItems.count == 1
    else {
        failAgentLiveEventStoreSelfTest("duplicate/out-of-order reduction")
    }

    let stale = store.snapshot(
        at: base.addingTimeInterval(
            AgentLiveEventPolicy.terminalFreshness + 2
        )
    )
    guard stale.snapshots.first?.executionState == .stale,
          stale.snapshots.first?.attentionReason == AttentionReason.none,
          stale.snapshots.first?.actionability == .viewOnly,
          stale.attentionItems.isEmpty
    else {
        failAgentLiveEventStoreSelfTest("freshness expiry")
    }

    let boundedStore = AgentLiveEventStore()
    for index in 0..<(AgentLiveEventPolicy.maximumEventsPerAgent + 20) {
        _ = boundedStore.ingest(
            makeLiveStoreEnvelope(
                agentID: .cursor,
                eventID: "bounded-\(index)",
                sequence: index,
                state: .running
            ),
            receivedAt: base.addingTimeInterval(Double(index))
        )
    }
    guard boundedStore.snapshot(
        at: base.addingTimeInterval(100)
    ).processedEventCount == AgentLiveEventPolicy.maximumEventsPerAgent
    else {
        failAgentLiveEventStoreSelfTest("bounded event retention")
    }

    var reductionGate = AgentLiveReductionGate()
    guard reductionGate.shouldApply(revision: 2),
          !reductionGate.shouldApply(revision: 1),
          !reductionGate.shouldApply(revision: 2),
          reductionGate.shouldApply(revision: 3)
    else {
        failAgentLiveEventStoreSelfTest("live reduction revision gate")
    }

    let projection = agentDashboardProjection(
        collection: .displaying([
            TaskProgressItem(
                title: "Codex stays",
                kind: .running,
                startedAt: base,
                source: .codex,
                threadID: "codex-thread"
            ),
            TaskProgressItem(
                title: "ZCode live overlay",
                kind: .running,
                startedAt: base,
                source: .zcode,
                sessionID: "session-one"
            ),
            TaskProgressItem(
                title: "ZCode polling fallback",
                kind: .running,
                startedAt: base,
                source: .zcode,
                sessionID: "polling-only"
            ),
        ]),
        permissionQueue: .empty,
        liveReduction: reduced
    )
    let zcodeItem = projection.taskCollection.items.first {
        $0.identityKey == "zcode:session-one"
    }
    guard projection.taskCollection.items.contains(where: {
        $0.source == .codex
    }), zcodeItem?.kind == .failed,
       zcodeItem?.statusOverride == "任务失败",
       zcodeItem?.canOpen == true,
       projection.taskCollection.items.filter({
           $0.identityKey == "zcode:session-one"
       }).count == 1,
       projection.taskCollection.items.contains(where: {
           $0.identityKey == "zcode:polling-only" && $0.kind == .running
       }),
       projection.snapshots.contains(where: {
           $0.identity.agentID == .zcode
               && $0.evidenceQuality == .officialHook
       })
    else {
        failAgentLiveEventStoreSelfTest(
            "dashboard live overlay must preserve polling fallback"
        )
    }

    let piProjection = taskProgressItem(from: AgentSessionSnapshot(
        identity: AgentSessionIdentity(agentID: .pi, nativeID: "pi-one"),
        adapterVersion: "self-test",
        executionState: .running,
        attentionReason: .none,
        actionability: .viewOnly,
        evidenceQuality: .officialHook,
        freshness: Freshness(observedAt: base, expiresAt: nil),
        title: "Pi 会话",
        activitySummary: "正在执行",
        workingDirectory: nil,
        latestEventID: "pi-event",
        updatedAt: base
    ))
    guard piProjection.kind == .running, !piProjection.canOpen else {
        failAgentLiveEventStoreSelfTest("Pi dashboard remains state-only")
    }
}

private func makeLiveStoreEnvelope(
    agentID: AgentID,
    eventID: String,
    sequence: Int?,
    state: ExecutionState,
    reason: AttentionReason = .none,
    actionability: Actionability = .openNativeApp
) -> AgentTransportEnvelope {
    AgentTransportEnvelope(
        agentID: agentID,
        adapterVersion: "self-test",
        nativeSessionCandidate: "session-one",
        eventID: eventID,
        sequence: sequence,
        eventType: eventID,
        monotonicNanoseconds: UInt64(max(sequence ?? 0, 0)),
        redactedPayload: [
            "state": state.rawValue,
            "attentionReason": reason.rawValue,
            "actionability": actionability.rawValue,
            "evidenceQuality": EvidenceQuality.officialHook.rawValue,
            "freshness": "fresh",
        ]
    )
}

private func failAgentLiveEventStoreSelfTest(_ message: String) -> Never {
    fputs("agent live event store self-test failed: \(message)\n", stderr)
    exit(1)
}
