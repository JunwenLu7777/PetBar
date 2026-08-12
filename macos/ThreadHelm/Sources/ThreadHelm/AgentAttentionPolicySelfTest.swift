//
//  AgentAttentionPolicySelfTest.swift
//  ThreadHelm
//
//  模块职责：锁定低噪声注意力规则、60 秒合并和可靠前台抑制边界。
//

import Foundation

func runAgentAttentionPolicySelfTest() {
    let base = Date(timeIntervalSince1970: 1_786_520_000)

    guard [
        AttentionReason.permission,
        .question,
        .planApproval,
        .taskFailure,
    ].allSatisfy({
        AgentAttentionPolicy.shouldInterrupt(
            reason: $0,
            evidenceQuality: .officialHook
        )
    }), !AgentAttentionPolicy.shouldInterrupt(
        reason: .reviewReady,
        evidenceQuality: .officialHook
    ) else {
        failAgentAttentionPolicySelfTest("first-version reason allowlist")
    }

    let verifiedBlocked = makeAttentionPolicySnapshot(
        agentID: .claudeCode,
        nativeID: "blocked-session",
        state: .running,
        reason: .blocked,
        evidence: .nativeState,
        updatedAt: base
    )
    let inferredBlocked = makeAttentionPolicySnapshot(
        agentID: .zcode,
        nativeID: "inferred-blocked",
        state: .running,
        reason: .blocked,
        evidence: .inferred,
        updatedAt: base
    )
    let reviewReady = makeAttentionPolicySnapshot(
        agentID: .cursor,
        nativeID: "review-session",
        state: .completed,
        reason: .reviewReady,
        evidence: .officialHook,
        updatedAt: base
    )
    let ordinaryToolFailure = makeAttentionPolicySnapshot(
        agentID: .cursor,
        nativeID: "tool-failure-session",
        state: .running,
        reason: .none,
        evidence: .officialHook,
        updatedAt: base
    )
    let processChurn = makeAttentionPolicySnapshot(
        agentID: .pi,
        nativeID: "stale-session",
        state: .stale,
        reason: .none,
        evidence: .processObservation,
        updatedAt: base
    )
    let classified = agentAttentionItems(from: [
        verifiedBlocked,
        inferredBlocked,
        reviewReady,
        ordinaryToolFailure,
        processChurn,
    ])
    guard classified.count == 3,
          classified.first(where: {
              $0.identity.key == verifiedBlocked.identity.key
          })?.isInterrupting == true,
          classified.first(where: {
              $0.identity.key == inferredBlocked.identity.key
          })?.isInterrupting == false,
          classified.first(where: {
              $0.identity.key == reviewReady.identity.key
          })?.isInterrupting == false,
          !classified.contains(where: {
              $0.identity.key == ordinaryToolFailure.identity.key
                  || $0.identity.key == processChurn.identity.key
          })
    else {
        failAgentAttentionPolicySelfTest("interrupt classification")
    }

    let question = makeAttentionPolicyItem(
        agentID: .claudeCode,
        nativeID: "question-session",
        reason: .question,
        updatedAt: base
    )
    let gate = AgentAttentionInterruptionGate(coalescingInterval: 60)
    guard gate.evaluate(items: [question], at: base).first?.isInterrupting == true
    else {
        failAgentAttentionPolicySelfTest("first hard attention must interrupt")
    }

    let unresolvedUpdate = makeAttentionPolicyItem(
        agentID: .claudeCode,
        nativeID: "question-session",
        reason: .question,
        updatedAt: base.addingTimeInterval(25)
    )
    guard gate.evaluate(
        items: [unresolvedUpdate],
        at: base.addingTimeInterval(25)
    ).first?.isInterrupting == false else {
        failAgentAttentionPolicySelfTest("unresolved reason repeated")
    }

    _ = gate.evaluate(items: [], at: base.addingTimeInterval(26))
    let quickRecurrence = makeAttentionPolicyItem(
        agentID: .claudeCode,
        nativeID: "question-session",
        reason: .question,
        updatedAt: base.addingTimeInterval(40)
    )
    guard gate.evaluate(
        items: [quickRecurrence],
        at: base.addingTimeInterval(40)
    ).first?.isInterrupting == false else {
        failAgentAttentionPolicySelfTest("same key within 60 seconds")
    }

    _ = gate.evaluate(items: [], at: base.addingTimeInterval(41))
    let laterRecurrence = makeAttentionPolicyItem(
        agentID: .claudeCode,
        nativeID: "question-session",
        reason: .question,
        updatedAt: base.addingTimeInterval(61)
    )
    guard gate.evaluate(
        items: [laterRecurrence],
        at: base.addingTimeInterval(61)
    ).first?.isInterrupting == true else {
        failAgentAttentionPolicySelfTest("same key after 60 seconds")
    }

    let distinctGate = AgentAttentionInterruptionGate(
        coalescingInterval: 60
    )
    let distinctItems = [
        question,
        makeAttentionPolicyItem(
            agentID: .claudeCode,
            nativeID: "question-session",
            reason: .permission,
            updatedAt: base
        ),
        makeAttentionPolicyItem(
            agentID: .claudeCode,
            nativeID: "other-session",
            reason: .question,
            updatedAt: base
        ),
        makeAttentionPolicyItem(
            agentID: .codex,
            nativeID: "question-session",
            reason: .question,
            updatedAt: base
        ),
    ]
    guard distinctGate.evaluate(items: distinctItems, at: base).allSatisfy({
        $0.isInterrupting
    }) else {
        failAgentAttentionPolicySelfTest("agent/session/reason key boundary")
    }

    let foregroundGate = AgentAttentionInterruptionGate(
        coalescingInterval: 60
    )
    let foregroundKey = question.identity.key
    guard foregroundGate.evaluate(
        items: [question],
        foregroundSessionKeys: [foregroundKey],
        at: base
    ).first?.isInterrupting == false,
          foregroundGate.evaluate(
              items: [unresolvedUpdate],
              foregroundSessionKeys: [],
              at: base.addingTimeInterval(10)
          ).first?.isInterrupting == false
    else {
        failAgentAttentionPolicySelfTest("foreground handling suppression")
    }

    let requestID = UUID(uuidString: "110D11B8-5FA0-4B6B-9D8E-25326A8A20D1")!
    let permissionQueue = ClaudePermissionQueueSnapshot(
        current: ClaudePermissionQueueItem(
            requestID: requestID,
            interactionKind: .toolApproval,
            title: "Bounded self-test request",
            sessionID: "NATIVE-SESSION",
            arrivedAt: base
        )
    )
    guard foregroundHandledAgentSessionKeys(
        presentationState: .expanded(.tasks),
        selectedTaskKey: "cursor:selected-session",
        permissionQueue: .empty
    ) == ["cursor:selected-session"],
          foregroundHandledAgentSessionKeys(
              presentationState: .expanded(.confirmation),
              selectedTaskKey: nil,
              permissionQueue: permissionQueue
          ) == ["claudeCode:native-session"],
          foregroundHandledAgentSessionKeys(
              presentationState: .capsule,
              selectedTaskKey: "cursor:selected-session",
              permissionQueue: permissionQueue
          ).isEmpty
    else {
        failAgentAttentionPolicySelfTest("reliable foreground detection")
    }
}

private func makeAttentionPolicySnapshot(
    agentID: AgentID,
    nativeID: String,
    state: ExecutionState,
    reason: AttentionReason,
    evidence: EvidenceQuality,
    updatedAt: Date
) -> AgentSessionSnapshot {
    AgentSessionSnapshot(
        identity: AgentSessionIdentity(agentID: agentID, nativeID: nativeID),
        adapterVersion: "self-test",
        executionState: state,
        attentionReason: reason,
        actionability: .viewOnly,
        evidenceQuality: evidence,
        freshness: Freshness(observedAt: updatedAt, expiresAt: nil),
        title: "Bounded self-test title",
        activitySummary: nil,
        workingDirectory: nil,
        latestEventID: "bounded-self-test-event",
        updatedAt: updatedAt
    )
}

private func makeAttentionPolicyItem(
    agentID: AgentID,
    nativeID: String,
    reason: AttentionReason,
    updatedAt: Date
) -> AgentAttentionItem {
    AgentAttentionItem(
        identity: AgentSessionIdentity(agentID: agentID, nativeID: nativeID),
        reason: reason,
        actionability: .viewOnly,
        evidenceQuality: .officialHook,
        updatedAt: updatedAt,
        isInterrupting: reason.isInterrupting
    )
}

private func failAgentAttentionPolicySelfTest(_ reason: String) -> Never {
    fputs("agent attention policy self-test failed: \(reason)\n", stderr)
    exit(1)
}
