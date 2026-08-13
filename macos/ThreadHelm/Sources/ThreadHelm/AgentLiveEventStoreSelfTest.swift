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
                nativeSessionCandidate: "bounded-\(index)",
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

    let reviewReady = makeLiveStoreEnvelope(
        agentID: .cursor,
        eventID: "review-ready",
        nativeSessionCandidate: "review-ready",
        sequence: 1,
        state: .completed,
        reason: .reviewReady
    )
    let oldChurn = makeLiveStoreEnvelope(
        agentID: .cursor,
        eventID: "old-churn",
        nativeSessionCandidate: "old-churn",
        sequence: 1,
        state: .running
    )
    let newChurn = makeLiveStoreEnvelope(
        agentID: .cursor,
        eventID: "new-churn",
        nativeSessionCandidate: "new-churn",
        sequence: 1,
        state: .running
    )
    let retainedByteLimit = serializedLiveStoreEnvelopeByteCount(reviewReady)
        + serializedLiveStoreEnvelopeByteCount(newChurn)
    let byteBoundedStore = AgentLiveEventStore(
        maximumEventsPerAgent: AgentLiveEventPolicy.maximumEventsPerAgent,
        maximumBytesPerAgent: retainedByteLimit
    )
    _ = byteBoundedStore.ingest(reviewReady, receivedAt: base)
    _ = byteBoundedStore.ingest(
        oldChurn,
        receivedAt: base.addingTimeInterval(1)
    )
    _ = byteBoundedStore.ingest(
        newChurn,
        receivedAt: base.addingTimeInterval(2)
    )
    _ = byteBoundedStore.ingest(
        makeLiveStoreEnvelope(
            agentID: .zcode,
            eventID: "zcode-independent",
            nativeSessionCandidate: "zcode-independent",
            sequence: 1,
            state: .running
        ),
        receivedAt: base
    )
    let byteBounded = byteBoundedStore.snapshot(
        at: base.addingTimeInterval(3)
    )
    let retainedKeys = Set(byteBounded.snapshots.map(\.identity.nativeID))
    guard AgentLiveEventPolicy.maximumBytesPerAgent
            == AgentTransportContract.maximumQueuedBytes,
          byteBounded.processedEventCount == 3,
          retainedKeys.contains("review-ready"),
          retainedKeys.contains("new-churn"),
          !retainedKeys.contains("old-churn"),
          retainedKeys.contains("zcode-independent"),
          byteBoundedStore.retainedSerializedByteCount(for: .cursor)
            <= retainedByteLimit
    else {
        failAgentLiveEventStoreSelfTest(
            "per-adapter byte bound and attention-first retention"
        )
    }

    var reductionGate = AgentLiveReductionGate()
    guard reductionGate.shouldApply(revision: 2),
          !reductionGate.shouldApply(revision: 1),
          !reductionGate.shouldApply(revision: 2),
          reductionGate.shouldApply(revision: 3)
    else {
        failAgentLiveEventStoreSelfTest("live reduction revision gate")
    }

    let revisionStore = AgentLiveEventStore()
    guard let delayedIngest = revisionStore.ingestUpdate(
        makeLiveStoreEnvelope(
            agentID: .pi,
            eventID: "revision-running",
            nativeSessionCandidate: "revision-session",
            sequence: 1,
            state: .running,
            actionability: .viewOnly
        ),
        receivedAt: base
    ) else {
        failAgentLiveEventStoreSelfTest("live revision ingest")
    }
    let supersedingSnapshot = revisionStore.snapshotUpdate(
        at: base.addingTimeInterval(1)
    )
    var supersedingGate = AgentLiveReductionGate()
    guard supersedingSnapshot.revision > delayedIngest.revision,
          supersedingGate.shouldApply(revision: supersedingSnapshot.revision),
          supersedingSnapshot.reduction.snapshots.contains(where: {
              $0.identity.nativeID == "revision-session"
                  && $0.executionState == .running
          }),
          !supersedingGate.shouldApply(revision: delayedIngest.revision)
    else {
        failAgentLiveEventStoreSelfTest(
            "higher snapshot must safely supersede delayed ingest"
        )
    }

    let validatedCompatibilities = Dictionary(
        uniqueKeysWithValues: AgentID.builtInOrder.map {
            ($0, AgentCompatibility.validated)
        }
    )
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
        liveReduction: reduced,
        agentCompatibilities: validatedCompatibilities
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

    let unvalidatedProjection = agentDashboardProjection(
        collection: .displaying([
            TaskProgressItem(
                title: "Codex waiting on drifted version",
                kind: .waitingForInput,
                startedAt: base,
                source: .codex,
                threadID: "codex-drifted"
            ),
            TaskProgressItem(
                title: "Claude waiting on drifted version",
                kind: .waitingForInput,
                startedAt: base,
                source: .claudeCode,
                sessionID: "2d61280e-b4f1-4db7-a326-19f9f0dd804c",
                workingDirectory: "/tmp/threadhelm-claude"
            ),
            TaskProgressItem(
                title: "ZCode live overlay",
                kind: .running,
                startedAt: base,
                source: .zcode,
                sessionID: "session-one"
            ),
        ]),
        permissionQueue: .empty,
        liveReduction: reduced,
        agentCompatibilities: [
            .codex: .unvalidated,
            .claudeCode: .unvalidated,
            .zcode: .unvalidated,
        ]
    )
    let driftedCodexItem = unvalidatedProjection.taskCollection.items.first {
        $0.identityKey == "codex:codex-drifted"
    }
    let driftedZCodeItem = unvalidatedProjection.taskCollection.items.first {
        $0.identityKey == "zcode:session-one"
    }
    let driftedClaudeItem = unvalidatedProjection.taskCollection.items.first {
        $0.source == .claudeCode
    }
    guard driftedCodexItem?.kind == .running,
          driftedCodexItem?.statusOverride == "版本未验证，仅显示状态",
          driftedCodexItem?.canOpen == false,
          driftedZCodeItem?.kind == .failed,
          driftedZCodeItem?.canOpen == false,
          driftedClaudeItem?.canOpen == false,
          driftedClaudeItem?.openButtonTitle == "仅查看状态",
          unvalidatedProjection.snapshots.allSatisfy({
              $0.attentionReason == .none && $0.actionability == .viewOnly
          }),
          unvalidatedProjection.attentionItems.isEmpty
    else {
        failAgentLiveEventStoreSelfTest(
            "unvalidated versions must stay visible without actions or alerts"
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
    nativeSessionCandidate: String = "session-one",
    sequence: Int?,
    state: ExecutionState,
    reason: AttentionReason = .none,
    actionability: Actionability = .openNativeApp
) -> AgentTransportEnvelope {
    AgentTransportEnvelope(
        agentID: agentID,
        adapterVersion: "self-test",
        nativeSessionCandidate: nativeSessionCandidate,
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

private func serializedLiveStoreEnvelopeByteCount(
    _ envelope: AgentTransportEnvelope
) -> Int {
    guard let encoding = try? AgentTransportEncoder.encode(envelope),
          !encoding.wasReducedToMetadata
    else {
        failAgentLiveEventStoreSelfTest("valid envelope byte count")
    }
    return encoding.data.count
}

private func failAgentLiveEventStoreSelfTest(_ message: String) -> Never {
    fputs("agent live event store self-test failed: \(message)\n", stderr)
    exit(1)
}
