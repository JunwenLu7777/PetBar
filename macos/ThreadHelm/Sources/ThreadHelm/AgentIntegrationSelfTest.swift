//
//  AgentIntegrationSelfTest.swift
//  ThreadHelm
//
//  模块职责：锁定五 Agent 公共核心、确定性事件归并和本地传输边界。
//

import Foundation

private struct SixthAgentAdapter: AgentAdapter {
    let metadata: AgentMetadata

    init(displayName: String = "Mock Sixth") {
        metadata = AgentMetadata(
            id: AgentID(rawValue: "mockSixth"),
            displayName: displayName,
            shortName: "Mock",
            iconResourceName: "ProviderIcon-mock",
            fallbackSymbolName: "puzzlepiece.extension",
            brandColor: AgentColorComponents(red: 0.5, green: 0.5, blue: 0.5),
            versionSource: "self-test",
            identityPolicy: "synthetic-test-id",
            capabilities: AgentCapabilitySet(
                supported: [.lifecycleObservation],
                unknown: [.stableIdentity, .exactReturn]
            )
        )
    }
}

private enum AgentIntegrationSelfTestError: Error {
    case unavailable
}

func runAgentIntegrationSelfTest() {
    let expectedBuiltIns: [AgentID] = [
        .codex,
        .claudeCode,
        .cursor,
        .zcode,
        .pi,
    ]
    guard AgentID.builtInOrder == expectedBuiltIns,
          expectedBuiltIns.map(\.rawValue) == [
              "codex", "claudeCode", "cursor", "zcode", "pi",
          ]
    else {
        failAgentIntegrationSelfTest("built-in IDs/order")
    }

    let mock = SixthAgentAdapter()
    let duplicate = SixthAgentAdapter(displayName: "Duplicate must lose")
    let registry = AgentRegistry(
        adapters: builtInAgentAdapters() + [mock, duplicate]
    )
    guard registry.agentIDs == expectedBuiltIns + [mock.metadata.id],
          registry.adapter(for: mock.metadata.id)?.metadata.displayName
              == "Mock Sixth",
          registry.count == 6
    else {
        failAgentIntegrationSelfTest("registry extension/deduplication")
    }

    for id in expectedBuiltIns {
        guard let metadata = registry.metadata(for: id),
              !metadata.displayName.isEmpty,
              !metadata.shortName.isEmpty,
              !metadata.iconResourceName.isEmpty,
              !metadata.fallbackSymbolName.isEmpty,
              !metadata.versionSource.isEmpty,
              !metadata.identityPolicy.isEmpty
        else {
            failAgentIntegrationSelfTest("metadata completeness for \(id.rawValue)")
        }
    }

    guard registry.metadata(for: .pi)?.capabilities.status(
        for: .lifecycleObservation
    ) == .supported,
          registry.metadata(for: .pi)?.capabilities.status(
              for: .nativeNavigation
          ) == .unsupported,
          registry.metadata(for: .pi)?.capabilities.status(
              for: .inAppPermission
          ) == .unsupported,
          registry.metadata(for: .pi)?.capabilities.status(
              for: .exactReturn
          ) == .unknown,
          registry.metadata(for: .cursor)?.capabilities.status(
              for: .exactReturn
          ) == .unknown,
          registry.metadata(for: .zcode)?.capabilities.status(
              for: .exactReturn
          ) == .unknown
    else {
        failAgentIntegrationSelfTest("state-only/unknown capability boundary")
    }

    guard QuotaProvider.allCases.map(\.rawValue) == ["codex", "claudeCode"]
    else {
        failAgentIntegrationSelfTest("quota providers remain independent")
    }

    guard TaskSourceFilter.options(for: AgentID.builtInOrder).map(\.rawValue)
        == ["all", "codex", "claudeCode", "cursor", "zcode", "pi"],
          TaskSourceFilter(agentID: mock.metadata.id).agentID == mock.metadata.id
    else {
        failAgentIntegrationSelfTest("source-agnostic filters")
    }

    runAgentTaskProgressRegistrySelfTest(mockAgentID: mock.metadata.id)
    runAgentReducerSelfTest()
}

private func runAgentTaskProgressRegistrySelfTest(mockAgentID: AgentID) {
    let now = Date(timeIntervalSince1970: 1_786_500_000)
    var mockShouldFail = false
    var codexTitle = "Codex first"
    let registry = AgentTaskProgressRegistry(sources: [
        AgentTaskProgressSource(agentID: mockAgentID) {
            if mockShouldFail { throw AgentIntegrationSelfTestError.unavailable }
            return [TaskProgressItem(
                title: "Sixth source",
                kind: .running,
                startedAt: now,
                source: mockAgentID,
                threadID: "mock-session"
            )]
        },
        AgentTaskProgressSource(agentID: .codex) {
            [TaskProgressItem(
                title: codexTitle,
                kind: .running,
                startedAt: now,
                source: .codex,
                threadID: "codex-session"
            )]
        },
        AgentTaskProgressSource(agentID: mockAgentID) {
            throw AgentIntegrationSelfTestError.unavailable
        },
    ])
    let first = registry.readCollection()
    mockShouldFail = true
    codexTitle = "Codex second"
    let second = registry.readCollection()
    guard registry.agentIDs == [.codex, mockAgentID],
          Set(first.items.map(\.source)) == Set([.codex, mockAgentID]),
          Set(second.items.map(\.source)) == Set([.codex, mockAgentID]),
          second.items.contains(where: { $0.title == "Codex second" }),
          second.items.contains(where: { $0.title == "Sixth source" })
    else {
        failAgentIntegrationSelfTest("task registry extension/fail-open")
    }

    let duplicateRunning = TaskProgressItem(
        title: "Same identity",
        kind: .running,
        startedAt: now,
        updatedAt: now,
        source: .cursor,
        sessionID: "cursor-candidate"
    )
    let duplicateWaiting = TaskProgressItem(
        title: "Same identity",
        kind: .waitingForInput,
        startedAt: now,
        updatedAt: now,
        source: .cursor,
        sessionID: "cursor-candidate"
    )
    let forward = TaskProgressCollectionSnapshot.displaying([
        duplicateRunning,
        duplicateWaiting,
    ])
    let reverse = TaskProgressCollectionSnapshot.displaying([
        duplicateWaiting,
        duplicateRunning,
    ])
    guard forward == reverse,
          forward.items.map(\.kind) == [.waitingForInput]
    else {
        failAgentIntegrationSelfTest("deterministic task snapshot deduplication")
    }
}

private func runAgentReducerSelfTest() {
    let base = Date(timeIntervalSince1970: 1_786_500_000)
    let codexIdentity = AgentSessionIdentity(
        agentID: .codex,
        nativeID: "codex-session"
    )
    let oldRunning = makeAgentSelfTestEvent(
        identity: codexIdentity,
        eventID: "event-running",
        sequence: 1,
        observedAt: base,
        state: .running
    )
    let newerWaiting = makeAgentSelfTestEvent(
        identity: codexIdentity,
        eventID: "event-waiting",
        sequence: 2,
        observedAt: base.addingTimeInterval(1),
        state: .running,
        reason: .question,
        actionability: .openExactNativeSession
    )

    let inOrder = AgentEventReducer.reduce(events: [
        oldRunning,
        oldRunning,
        newerWaiting,
    ])
    let outOfOrder = AgentEventReducer.reduce(events: [
        newerWaiting,
        oldRunning,
        oldRunning,
    ])
    guard inOrder == outOfOrder,
          inOrder.processedEventCount == 2,
          inOrder.snapshots.first?.attentionReason == .question,
          inOrder.attentionItems.count == 1
    else {
        failAgentIntegrationSelfTest("dedupe/out-of-order reducer")
    }

    let terminal = makeAgentSelfTestEvent(
        identity: codexIdentity,
        eventID: "event-terminal",
        sequence: 3,
        observedAt: base.addingTimeInterval(2),
        state: .failed,
        reason: .taskFailure,
        actionability: .openExactNativeSession
    )
    let terminalReduction = AgentEventReducer.reduce(events: [
        terminal,
        oldRunning,
        newerWaiting,
    ])
    guard terminalReduction.snapshots.first?.executionState == .failed,
          terminalReduction.snapshots.first?.attentionReason == .taskFailure
    else {
        failAgentIntegrationSelfTest("newer terminal wins over stale events")
    }

    let sameTimestampA = makeAgentSelfTestEvent(
        identity: codexIdentity,
        eventID: "tie-a",
        sequence: nil,
        observedAt: base.addingTimeInterval(3),
        state: .running
    )
    let sameTimestampB = makeAgentSelfTestEvent(
        identity: codexIdentity,
        eventID: "tie-b",
        sequence: nil,
        observedAt: base.addingTimeInterval(3),
        state: .completed,
        reason: .reviewReady
    )
    let tieAB = AgentEventReducer.reduce(events: [sameTimestampA, sameTimestampB])
    let tieBA = AgentEventReducer.reduce(events: [sameTimestampB, sameTimestampA])
    guard tieAB == tieBA,
          tieAB.snapshots.first?.latestEventID == "tie-b",
          tieAB.snapshots.first?.executionState == .completed
    else {
        failAgentIntegrationSelfTest("stable timestamp tie-break")
    }

    let mixedEvents = AgentID.builtInOrder.reversed().enumerated().map {
        index, agentID in
        makeAgentSelfTestEvent(
            identity: AgentSessionIdentity(
                agentID: agentID,
                nativeID: "session-\(agentID.rawValue)"
            ),
            eventID: "mixed-\(index)",
            sequence: 1,
            observedAt: base,
            state: .running
        )
    }
    let mixed = AgentEventReducer.reduce(events: mixedEvents)
    guard mixed.snapshots.map(\.identity.agentID) == AgentID.builtInOrder
    else {
        failAgentIntegrationSelfTest("five-agent stable output order")
    }

    let secondCodexSession = makeAgentSelfTestEvent(
        identity: AgentSessionIdentity(
            agentID: .codex,
            nativeID: "codex-session-two"
        ),
        eventID: oldRunning.eventID,
        sequence: 1,
        observedAt: base,
        state: .running
    )
    let sameEventIDAcrossSessions = AgentEventReducer.reduce(events: [
        oldRunning,
        secondCodexSession,
    ])
    guard sameEventIDAcrossSessions.processedEventCount == 2,
          sameEventIDAcrossSessions.snapshots.count == 2
    else {
        failAgentIntegrationSelfTest("event IDs are scoped to session identity")
    }

    let previousPi = AgentEventReducer.reduce(events: [
        makeAgentSelfTestEvent(
            identity: AgentSessionIdentity(
                agentID: .pi,
                nativeID: "pi-preserved"
            ),
            eventID: "pi-old",
            sequence: 1,
            observedAt: base,
            state: .running,
            actionability: .viewOnly
        ),
    ])
    let failurePreserved = AgentEventReducer.reduce(
        events: [newerWaiting],
        previousSnapshots: previousPi.snapshots,
        preservingAgentIDs: [.pi]
    )
    guard Set(failurePreserved.snapshots.map(\.identity.agentID))
        == Set([.codex, .pi])
    else {
        failAgentIntegrationSelfTest("adapter failure preserves prior frame")
    }
}

func runAgentTransportSelfTest() {
    guard AgentTransportContract.schemaVersion == 1,
          AgentTransportContract.maximumSerializedBytes == 64 * 1_024,
          AgentTransportContract.synchronousTimeout == 0.25
    else {
        failAgentIntegrationSelfTest("transport constants")
    }

    let oversizedSecret = String(repeating: "private-prompt-", count: 8_000)
    let oversized = AgentTransportEnvelope(
        agentID: .cursor,
        adapterVersion: "self-test",
        nativeSessionCandidate: "cursor-session",
        eventID: "oversized",
        sequence: 1,
        eventType: "running",
        monotonicNanoseconds: 42,
        redactedPayload: [
            "state": oversizedSecret,
            "rawPrompt": "must never leave the hook",
        ]
    )
    let encoded: AgentTransportEncoding
    do {
        encoded = try AgentTransportEncoder.encode(oversized)
    } catch {
        failAgentIntegrationSelfTest("oversized envelope encoding")
    }
    let encodedText = String(data: encoded.data, encoding: .utf8) ?? ""
    guard encoded.data.count <= AgentTransportContract.maximumSerializedBytes,
          encoded.wasReducedToMetadata,
          !encodedText.contains("private-prompt"),
          !encodedText.contains("must never leave")
    else {
        failAgentIntegrationSelfTest("metadata-only oversized fallback")
    }

    let normal = AgentTransportEnvelope(
        agentID: .zcode,
        adapterVersion: "self-test",
        nativeSessionCandidate: nil,
        eventID: "normal",
        sequence: nil,
        eventType: "stop",
        monotonicNanoseconds: 43,
        redactedPayload: ["state": "completed"]
    )
    guard let normalEncoding = try? AgentTransportEncoder.encode(normal),
          let normalObject = try? JSONSerialization.jsonObject(
              with: normalEncoding.data
          ) as? [String: Any],
          normalObject["agentID"] as? String == "zcode",
          (normalObject["redactedPayload"] as? [String: String])
              == ["state": "completed"]
    else {
        failAgentIntegrationSelfTest("transport JSON/token contract")
    }

    let rejectedSensitive = AgentTransportEnvelope(
        agentID: .cursor,
        adapterVersion: "private version words",
        nativeSessionCandidate: "private path with spaces",
        eventID: "event with prompt words",
        sequence: nil,
        eventType: "raw prompt",
        monotonicNanoseconds: 44,
        redactedPayload: ["rawPrompt": "do not transport me"]
    )
    guard let rejectedEncoding = try? AgentTransportEncoder.encode(
        rejectedSensitive
    ),
          rejectedEncoding.wasReducedToMetadata,
          let rejectedText = String(
              data: rejectedEncoding.data,
              encoding: .utf8
          ),
          !rejectedText.contains("private"),
          !rejectedText.contains("prompt words"),
          !rejectedText.contains("do not transport")
    else {
        failAgentIntegrationSelfTest("transport rejects non-token/sensitive fields")
    }
    let offline = AgentHookTransport.send(normal) { _ in nil }
    let malformed = AgentHookTransport.send(normal) { _ in Data("not-json".utf8) }
    let started = Date()
    let slow = AgentHookTransport.send(normal) { _ in
        Thread.sleep(forTimeInterval: 0.60)
        return AgentHookTransport.validAcknowledgement
    }
    let elapsed = Date().timeIntervalSince(started)
    guard offline.disposition == .offline,
          malformed.disposition == .malformedResponse,
          slow.disposition == .timedOut,
          offline.vendorResponse.isEmpty,
          malformed.vendorResponse.isEmpty,
          slow.vendorResponse.isEmpty,
          elapsed < 0.50
    else {
        failAgentIntegrationSelfTest("fail-open offline/slow/malformed transport")
    }
}

private func makeAgentSelfTestEvent(
    identity: AgentSessionIdentity,
    eventID: String,
    sequence: Int?,
    observedAt: Date,
    state: ExecutionState,
    reason: AttentionReason = .none,
    actionability: Actionability = .viewOnly
) -> AgentEvent {
    AgentEvent(
        identity: identity,
        adapterVersion: "self-test",
        eventID: eventID,
        sequence: sequence,
        eventType: state.rawValue,
        observedAt: observedAt,
        monotonicNanoseconds: nil,
        executionState: state,
        attentionReason: reason,
        actionability: actionability,
        evidenceQuality: .nativeState,
        freshness: Freshness(
            observedAt: observedAt,
            expiresAt: observedAt.addingTimeInterval(30)
        ),
        title: "Self-test",
        activitySummary: nil
    )
}

private func failAgentIntegrationSelfTest(_ message: String) -> Never {
    fputs("agent integration self-test failed: \(message)\n", stderr)
    exit(1)
}
