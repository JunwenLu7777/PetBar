//
//  AgentLiveEventStoreSelfTest.swift
//  ThreadHelm
//
//  模块职责：验证脱敏 envelope 投影、能力降级、有界归并和 stale 规则。
//

import Foundation

func runAgentLiveEventStoreSelfTest() {
    let base = Date(timeIntervalSince1970: 1_786_510_000)
    let ompEscalation = makeLiveStoreEnvelope(
        agentID: .omp,
        eventID: "omp-escalation",
        sequence: 1,
        state: .running,
        reason: .permission,
        actionability: .inApp
    )
    guard let ompEvent = AgentTransportEnvelopeProjection.event(
        from: ompEscalation,
        receivedAt: base
    ), ompEvent.attentionReason == .none,
       ompEvent.actionability == .openExactNativeSession,
       ompEvent.workingDirectory == nil,
       !ompEvent.title.contains("/")
    else {
        failAgentLiveEventStoreSelfTest("OMP navigation/control boundary")
    }

    let ompWithoutSession = makeLiveStoreEnvelope(
        agentID: .omp,
        eventID: "omp-without-session",
        nativeSessionCandidate: nil,
        sequence: 2,
        state: .running,
        actionability: .openExactNativeSession
    )
    guard let ompWithoutSessionEvent = AgentTransportEnvelopeProjection.event(
        from: ompWithoutSession,
        receivedAt: base
    ), ompWithoutSessionEvent.actionability == .viewOnly
    else {
        failAgentLiveEventStoreSelfTest("OMP navigation requires safe session ID")
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
            agentID: .omp,
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
    // 版本漂移不再吞掉提醒。原来这里断言 attentionReason 被清零、
    // attentionItems 为空，可同一张卡片写着「等你确认」而"需你"计数是 0，
    // 本身就自相矛盾；而上游发版是常态，把常态做成降级等于在最需要提醒的
    // 时候闭嘴。是否打扰用户由 AgentAttentionPolicy 按证据质量判，那才是
    // 对的轴。
    guard driftedCodexItem?.kind == .waitingForInput,
          driftedCodexItem?.statusText == "等你确认",
          driftedCodexItem?.canOpen == true,
          driftedZCodeItem?.kind == .failed,
          driftedZCodeItem?.canOpen == true,
          driftedClaudeItem?.canOpen == true,
          driftedClaudeItem?.kind == .waitingForInput,
          driftedClaudeItem?.openButtonTitle == "回到终端",
          unvalidatedProjection.taskCollection.items.filter({
              $0.kind == .waitingForInput
          }).count == 2,
          unvalidatedProjection.snapshots.allSatisfy({
              $0.actionability != .viewOnly
          }),
          unvalidatedProjection.snapshots.contains(where: {
              $0.attentionReason != .none
          }),
          !unvalidatedProjection.attentionItems.isEmpty
    else {
        failAgentLiveEventStoreSelfTest(
            "unvalidated versions must keep waiting state and its alerts"
        )
    }

    let ompFirstOutputAt = base.addingTimeInterval(-5)
    let ompSecondOutputAt = base.addingTimeInterval(-1)
    let ompProjection = taskProgressItem(from: AgentSessionSnapshot(
        identity: AgentSessionIdentity(agentID: .omp, nativeID: "omp-one"),
        adapterVersion: "self-test",
        executionState: .running,
        attentionReason: .none,
        actionability: .openExactNativeSession,
        evidenceQuality: .officialHook,
        freshness: Freshness(observedAt: base, expiresAt: nil),
        title: "OMP 会话",
        activitySummary: "正在执行",
        workingDirectory: nil,
        latestEventID: "omp-event",
        updatedAt: base
    ), events: [
        makeLiveStoreAgentEvent(
            agentID: .omp,
            nativeID: "omp-one",
            eventID: "omp-tool-call-one",
            eventType: "tool_call",
            observedAt: base.addingTimeInterval(-4),
            state: .running
        ),
        makeLiveStoreAgentEvent(
            agentID: .omp,
            nativeID: "omp-one",
            eventID: "omp-tool-result-one",
            eventType: "tool_result",
            observedAt: base.addingTimeInterval(-3),
            state: .running
        ),
        makeLiveStoreAgentEvent(
            agentID: .omp,
            nativeID: "omp-one",
            eventID: "omp-tool-call-two",
            eventType: "tool_call",
            observedAt: base.addingTimeInterval(-2),
            state: .running
        ),
        makeLiveStoreAgentEvent(
            agentID: .omp,
            nativeID: "omp-one",
            eventID: "omp-tool-result-two",
            eventType: "tool_result",
            observedAt: base,
            state: .running
        ),
    ], ompSessionContent: { sessionID in
        guard sessionID == "omp-one" else { return nil }
        return OMPLocalSessionContent(
            workingDirectory: "/private/tmp/omp-project",
            projection: makeLocalProjection(
                agentID: .omp,
                sessionKey: sessionID,
                messages: [
                    (ompFirstOutputAt, "OMP 已完成第一轮检查"),
                    (ompSecondOutputAt, "OMP 正在整理最终结果"),
                ]
            )
        )
    })
    guard ompProjection.kind == .running,
          ompProjection.canOpen,
          ompProjection.openButtonTitle == "打开 OMP",
          ompProjection.workingDirectory == "/private/tmp/omp-project",
          ompProjection.projection.publicMessages.map(\.text) == [
              "OMP 正在整理最终结果",
              "OMP 已完成第一轮检查",
          ],
          ompProjection.projection.currentToolStatus?.text == "工具调用完成",
          ompProjection.projection.currentToolStatus?.id.stableSourceKey
            == "hook:omp-tool-result-two",
          ompProjection.projection.terminalEvent == nil,
          ompProjection.events.map(\.text) == [
              "工具调用完成",
              "OMP 正在整理最终结果",
              "OMP 已完成第一轮检查",
          ],
          ompProjection.activityText == "工具调用完成"
    else {
        failAgentLiveEventStoreSelfTest(
            "OMP dashboard navigation/public output"
        )
    }

    let completedOMPProjection = taskProgressItem(from: AgentSessionSnapshot(
        identity: AgentSessionIdentity(agentID: .omp, nativeID: "omp-done"),
        adapterVersion: "self-test",
        executionState: .completed,
        attentionReason: .none,
        actionability: .openExactNativeSession,
        evidenceQuality: .officialHook,
        freshness: Freshness(observedAt: base, expiresAt: nil),
        title: "OMP 会话",
        activitySummary: nil,
        workingDirectory: nil,
        latestEventID: "omp-agent-end",
        updatedAt: base
    ), events: [
        makeLiveStoreAgentEvent(
            agentID: .omp,
            nativeID: "omp-done",
            eventID: "omp-done-tool-result",
            eventType: "tool_result",
            observedAt: base.addingTimeInterval(-2),
            state: .running
        ),
        makeLiveStoreAgentEvent(
            agentID: .omp,
            nativeID: "omp-done",
            eventID: "omp-agent-end",
            eventType: "agent_end",
            observedAt: base,
            state: .completed
        ),
    ], ompSessionContent: { sessionID in
        guard sessionID == "omp-done" else { return nil }
        return OMPLocalSessionContent(
            workingDirectory: "/private/tmp/omp-project",
            projection: makeLocalProjection(
                agentID: .omp,
                sessionKey: sessionID,
                messages: [
                    (base.addingTimeInterval(-1), "OMP 已完成全部工作"),
                ]
            )
        )
    })
    guard completedOMPProjection.events.map(\.text) == [
              "本轮结束",
              "OMP 已完成全部工作",
          ],
          completedOMPProjection.projection.terminalEvent?.text == "本轮结束",
          completedOMPProjection.projection.currentToolStatus == nil,
          completedOMPProjection.activityText == nil
    else {
        failAgentLiveEventStoreSelfTest(
            "OMP local output keeps only the latest terminal hook event"
        )
    }

    let repeatedOMPContent = OMPLocalSession.content(fromJSONL: """
    {"type":"message","timestamp":"2026-08-17T03:45:24.944Z","message":{"role":"assistant","content":[{"type":"text","text":"重复输出"}]}}
    {"type":"message","timestamp":"2026-08-17T03:45:25.944Z","message":{"role":"assistant","content":[{"type":"text","text":"重复输出"}]}}
    """)
    guard repeatedOMPContent.projection.publicMessages.map(\.text) == [
              "重复输出",
              "重复输出",
          ],
          Set(repeatedOMPContent.projection.publicMessages.map {
              $0.id.stableSourceKey
          }).count == 2
    else {
        failAgentLiveEventStoreSelfTest(
            "OMP projection must retain legitimate repeated public messages"
        )
    }

    let cursorSession = "2cac76a3-df5f-469f-9f64-05972b086c2d"
    let cursorStart = base.addingTimeInterval(-40)
    let cursorSnapshot = AgentSessionSnapshot(
        identity: AgentSessionIdentity(agentID: .cursor, nativeID: cursorSession),
        adapterVersion: "self-test",
        executionState: .running,
        attentionReason: .none,
        actionability: .openNativeApp,
        evidenceQuality: .officialHook,
        freshness: Freshness(observedAt: base, expiresAt: nil),
        title: "Cursor 会话",
        activitySummary: "正在执行",
        workingDirectory: nil,
        latestEventID: "cursor-latest",
        updatedAt: base
    )
    let cursorItem = taskProgressItem(
        from: cursorSnapshot,
        events: [
            makeLiveStoreAgentEvent(
                agentID: .cursor,
                nativeID: cursorSession,
                eventID: "cursor-start",
                eventType: "sessionStart",
                observedAt: cursorStart,
                state: .idle
            ),
            makeLiveStoreAgentEvent(
                agentID: .cursor,
                nativeID: cursorSession,
                eventID: "cursor-tool",
                eventType: "postToolUse",
                observedAt: base,
                state: .running
            ),
            makeLiveStoreAgentEvent(
                agentID: .zcode,
                nativeID: "other-session",
                eventID: "ignored",
                eventType: "postToolUse",
                observedAt: base,
                state: .running
            ),
        ],
        cursorWorkingDirectory: { id in
            id == cursorSession ? "/private/tmp/threadhelm-test/code/PetBar" : nil
        },
        cursorSessionContent: { _ in nil }
    )
    guard cursorItem.title == "PetBar",
          cursorItem.workingDirectory == "/private/tmp/threadhelm-test/code/PetBar",
          cursorItem.startedAt == cursorStart,
          cursorItem.events.map(\.text) == ["工具调用完成"],
          cursorItem.projection.currentToolStatus?.text == "工具调用完成",
          cursorItem.projection.terminalEvent == nil,
          cursorItem.projection.publicMessages.isEmpty,
          cursorItem.activityText == "工具调用完成"
    else {
        failAgentLiveEventStoreSelfTest(
            "Cursor live card must resolve local cwd and safe events"
        )
    }

    let transcriptContent = CursorLocalWorkspace.sessionContent(
        fromJSONL: """
        {"role":"user","message":{"content":[{"type":"text","text":"帮我看看监听为什么是空的"}]}}
        {"role":"assistant","message":{"content":[{"type":"text","text":"路径没填上，我去本机记录里读正文。"},{"type":"tool_use","name":"Read","input":{"path":"/secret/do-not-show"}}]}}
        """
    )
    guard transcriptContent.title == "帮我看看监听为什么是空的",
          transcriptContent.activityText == "路径没填上，我去本机记录里读正文。",
          transcriptContent.completedActivityText == "路径没填上，我去本机记录里读正文。",
          transcriptContent.fragments.map(\.text) == [
              "路径没填上，我去本机记录里读正文。",
              "正在检查文件",
          ],
          transcriptContent.activityText?.contains("/secret") != true,
          !transcriptContent.fragments.contains(where: { $0.text.contains("/secret") })
    else {
        failAgentLiveEventStoreSelfTest(
            "Cursor transcript must expose public assistant output without tool paths"
        )
    }

    let repeatedCursorContent = CursorLocalWorkspace.sessionContent(
        fromJSONL: """
        {"role":"assistant","message":{"content":[{"type":"text","text":"重复 Cursor 输出"}]}}
        {"role":"assistant","message":{"content":[{"type":"text","text":"重复 Cursor 输出"}]}}
        """
    )
    guard repeatedCursorContent.projection.publicMessages.map(\.text) == [
              "重复 Cursor 输出",
              "重复 Cursor 输出",
          ],
          Set(repeatedCursorContent.projection.publicMessages.map {
              $0.id.stableSourceKey
          }).count == 2
    else {
        failAgentLiveEventStoreSelfTest(
            "Cursor projection must retain legitimate repeated public messages"
        )
    }

    let laterQuery = CursorLocalWorkspace.sessionContent(
        fromJSONL: """
        {"role":"user","message":{"content":[{"type":"text","text":"<user_query>当前的样式感觉怪怪的,你用你专业的审美帮我看看?如何优化?</user_query>"}]}}
        {"role":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}
        {"role":"user","message":{"content":[{"type":"text","text":"[Image]\\n<user_query>\\ncursor的当前活动不对\\n</user_query>"}]}}
        {"role":"assistant","message":{"content":[{"type":"text","text":"左侧已经变成「样式优化建议」，右侧也有文件名，但你要的不是这个。"},{"type":"tool_use","name":"Shell"},{"type":"tool_use","name":"StrReplace"}]}}
        """
    )
    guard laterQuery.title == "当前的样式感觉怪怪的,你用你专业的审美帮我看看?如何优化?",
          laterQuery.activityText
            == "左侧已经变成「样式优化建议」，右侧也有文件名，但你要的不是这个。",
          laterQuery.completedActivityText
            == "左侧已经变成「样式优化建议」，右侧也有文件名，但你要的不是这个。"
    else {
        failAgentLiveEventStoreSelfTest(
            "Cursor title must keep the first user query, not the latest message"
        )
    }

    let wrappedTitle = CursorLocalWorkspace.sessionContent(
        fromJSONL: """
        {"role":"user","message":{"content":[{"type":"text","text":"[Image]\\n<user_query>\\ncursor的当前活动不对\\n</user_query>"}]}}
        """
    )
    guard wrappedTitle.title == "cursor的当前活动不对" else {
        failAgentLiveEventStoreSelfTest(
            "Cursor title must use the user query, not image metadata"
        )
    }

    let namedContent = CursorLocalWorkspace.overlaying(
        laterQuery,
        with: CursorConversationMetadata(
            title: "样式优化建议"
        )
    )
    guard namedContent.title == "样式优化建议",
          namedContent.activityText
            == "左侧已经变成「样式优化建议」，右侧也有文件名，但你要的不是这个。",
          namedContent.completedActivityText
            == "左侧已经变成「样式优化建议」，右侧也有文件名，但你要的不是这个。"
    else {
        failAgentLiveEventStoreSelfTest(
            "Cursor card title must use the sidebar conversation name"
        )
    }

    let runningContentItem = taskProgressItem(
        from: cursorSnapshot,
        events: [
            makeLiveStoreAgentEvent(
                agentID: .cursor,
                nativeID: cursorSession,
                eventID: "cursor-tool",
                eventType: "postToolUse",
                observedAt: base,
                state: .running
            ),
        ],
        cursorWorkingDirectory: { _ in "/private/tmp/threadhelm-test/code/PetBar" },
        cursorSessionContent: { id in
            id == cursorSession ? transcriptContent : nil
        }
    )
    guard runningContentItem.title == "帮我看看监听为什么是空的",
          runningContentItem.activityText == "工具调用完成",
          runningContentItem.events.map(\.text) == [
              "工具调用完成",
              "路径没填上，我去本机记录里读正文。",
          ],
          runningContentItem.projection.currentToolStatus?.text == "工具调用完成",
          runningContentItem.projection.publicMessages.map(\.text) == [
              "路径没填上，我去本机记录里读正文。",
          ]
    else {
        failAgentLiveEventStoreSelfTest(
            "running Cursor activity must summarize the latest hook without output body"
        )
    }

    let thinkingContentItem = taskProgressItem(
        from: cursorSnapshot,
        events: [
            makeLiveStoreAgentEvent(
                agentID: .cursor,
                nativeID: cursorSession,
                eventID: "cursor-prompt",
                eventType: "beforeSubmitPrompt",
                observedAt: base,
                state: .running
            ),
        ],
        cursorWorkingDirectory: { _ in "/private/tmp/threadhelm-test/code/PetBar" },
        cursorSessionContent: { id in
            id == cursorSession ? transcriptContent : nil
        }
    )
    guard thinkingContentItem.activityText == "正在思考",
          thinkingContentItem.events.contains(where: {
              $0.text == "路径没填上，我去本机记录里读正文。"
          }),
          thinkingContentItem.activityText != transcriptContent.activityText
    else {
        failAgentLiveEventStoreSelfTest(
            "Cursor thinking activity must stay concise while history keeps public events"
        )
    }

    let runningNamedItem = taskProgressItem(
        from: cursorSnapshot,
        events: [
            makeLiveStoreAgentEvent(
                agentID: .cursor,
                nativeID: cursorSession,
                eventID: "cursor-tool",
                eventType: "postToolUse",
                observedAt: base,
                state: .running
            ),
        ],
        cursorWorkingDirectory: { _ in "/private/tmp/threadhelm-test/code/PetBar" },
        cursorSessionContent: { id in
            id == cursorSession ? namedContent : nil
        }
    )
    guard runningNamedItem.title == "样式优化建议",
          runningNamedItem.activityText == "工具调用完成"
    else {
        failAgentLiveEventStoreSelfTest(
            "running Cursor card must keep its title and concise activity summary"
        )
    }

    let completedSnapshot = AgentSessionSnapshot(
        identity: AgentSessionIdentity(agentID: .cursor, nativeID: cursorSession),
        adapterVersion: "self-test",
        executionState: .completed,
        attentionReason: .reviewReady,
        actionability: .openNativeApp,
        evidenceQuality: .officialHook,
        freshness: Freshness(observedAt: base, expiresAt: nil),
        title: "Cursor 会话",
        activitySummary: "本轮结束",
        workingDirectory: nil,
        latestEventID: "cursor-stop",
        updatedAt: base
    )
    let completedContentItem = taskProgressItem(
        from: completedSnapshot,
        events: [
            makeLiveStoreAgentEvent(
                agentID: .cursor,
                nativeID: cursorSession,
                eventID: "cursor-stop",
                eventType: "stop",
                observedAt: base,
                state: .completed
            ),
        ],
        cursorWorkingDirectory: { _ in "/private/tmp/threadhelm-test/code/PetBar" },
        cursorSessionContent: { id in
            id == cursorSession ? transcriptContent : nil
        }
    )
    guard completedContentItem.activityText == "本轮已完成",
          completedContentItem.events.map(\.text) == [
              "本轮结束",
              "路径没填上，我去本机记录里读正文。",
          ],
          completedContentItem.projection.terminalEvent?.text == "本轮结束",
          completedContentItem.projection.currentToolStatus == nil,
          completedContentItem.projection.publicMessages.map(\.text) == [
              "路径没填上，我去本机记录里读正文。",
          ],
          !completedContentItem.events.contains(where: { $0.text.contains("/secret") }),
          !(completedContentItem.activityText ?? "").contains("/secret")
    else {
        failAgentLiveEventStoreSelfTest(
            "completed Cursor activity must not repeat the assistant output body"
        )
    }

    let completedNamedItem = taskProgressItem(
        from: completedSnapshot,
        events: [
            makeLiveStoreAgentEvent(
                agentID: .cursor,
                nativeID: cursorSession,
                eventID: "cursor-stop",
                eventType: "stop",
                observedAt: base,
                state: .completed
            ),
        ],
        cursorWorkingDirectory: { _ in "/private/tmp/threadhelm-test/code/PetBar" },
        cursorSessionContent: { id in
            id == cursorSession ? namedContent : nil
        }
    )
    guard completedNamedItem.title == "样式优化建议",
          completedNamedItem.activityText == "本轮已完成",
          completedNamedItem.projection.terminalEvent?.text == "本轮结束",
          completedNamedItem.events.first?.text == "本轮结束"
    else {
        failAgentLiveEventStoreSelfTest(
            "completed Cursor card must show sidebar title and terminal summary"
        )
    }

    let projectedCursor = AgentSessionSnapshot(
        identity: AgentSessionIdentity(
            agentID: .cursor,
            nativeID: "cursor-projection-session"
        ),
        adapterVersion: "self-test",
        executionState: .running,
        attentionReason: .none,
        actionability: .openNativeApp,
        evidenceQuality: .officialHook,
        freshness: Freshness(observedAt: base, expiresAt: nil),
        title: "Cursor 会话",
        activitySummary: "正在执行",
        workingDirectory: nil,
        latestEventID: "cursor-prompt",
        updatedAt: base
    )
    let unidentifiedCursor = AgentSessionSnapshot(
        identity: AgentSessionIdentity(
            agentID: .cursor,
            nativeID: "unidentified"
        ),
        adapterVersion: "self-test",
        executionState: .running,
        attentionReason: .none,
        actionability: .openNativeApp,
        evidenceQuality: .officialHook,
        freshness: Freshness(observedAt: base, expiresAt: nil),
        title: "Cursor 会话",
        activitySummary: "正在执行",
        workingDirectory: nil,
        latestEventID: "cursor-unidentified",
        updatedAt: base
    )
    let cursorProjection = agentDashboardProjection(
        collection: .displaying([]),
        permissionQueue: .empty,
        liveReduction: AgentReductionResult(
            snapshots: [projectedCursor, unidentifiedCursor],
            attentionItems: [],
            processedEventCount: 1,
            events: [
                makeLiveStoreAgentEvent(
                    agentID: .cursor,
                    nativeID: "cursor-projection-session",
                    eventID: "cursor-prompt",
                    eventType: "beforeSubmitPrompt",
                    observedAt: base,
                    state: .running
                ),
                makeLiveStoreAgentEvent(
                    agentID: .cursor,
                    nativeID: "unidentified",
                    eventID: "cursor-unidentified",
                    eventType: "beforeSubmitPrompt",
                    observedAt: base,
                    state: .running
                ),
            ]
        ),
        agentCompatibilities: [.cursor: .validated]
    )
    let projectedItem = cursorProjection.taskCollection.items.first {
        $0.sessionID == "cursor-projection-session"
    }
    guard projectedItem?.events.map(\.text) == ["提交提示"],
          projectedItem?.activityText == "正在思考",
          projectedItem?.workingDirectory == nil,
          cursorProjection.taskCollection.items.count == 1,
          !cursorProjection.snapshots.contains(where: {
              $0.identity.nativeID == "unidentified"
          })
    else {
        failAgentLiveEventStoreSelfTest(
            "dashboard must keep identified Cursor events without duplicate generic cards"
        )
    }

    var readUnvalidatedCursorDirectory = false
    var readUnvalidatedCursorContent = false
    let unvalidatedCursorProjection = agentDashboardProjection(
        collection: .displaying([]),
        permissionQueue: .empty,
        liveReduction: AgentReductionResult(
            snapshots: [projectedCursor, unidentifiedCursor],
            attentionItems: [],
            processedEventCount: 1,
            events: [
                makeLiveStoreAgentEvent(
                    agentID: .cursor,
                    nativeID: "cursor-projection-session",
                    eventID: "cursor-prompt",
                    eventType: "beforeSubmitPrompt",
                    observedAt: base,
                    state: .running
                ),
            ]
        ),
        agentCompatibilities: [.cursor: .unvalidated],
        cursorWorkingDirectory: { _ in
            readUnvalidatedCursorDirectory = true
            return "/private/tmp/threadhelm-test/private-project"
        },
        cursorSessionContent: { _ in
            readUnvalidatedCursorContent = true
            return CursorLocalSessionContent(
                title: "不应读取的本地标题",
                activityText: "不应读取的本地正文",
                completedActivityText: "不应读取的本地正文",
                fragments: [],
                projection: .empty
            )
        }
    )
    // Cursor 这条例外保留：读本机工作区是在**推断**这张卡片属于哪个目录、
    // 哪个会话，格式一变就可能把别的项目的路径挂到这条会话上，那是错的
    // 信息而不是缺的信息。摘要不再被替换（钩子事件本身给的文案照用），
    // 但本机私有内容仍然一个字都不读。
    let boundedCursor = unvalidatedCursorProjection.taskCollection.items.first
    guard !readUnvalidatedCursorDirectory,
          !readUnvalidatedCursorContent,
          boundedCursor?.title == "Cursor 会话",
          boundedCursor?.activityText == "正在思考",
          boundedCursor?.workingDirectory == nil,
          boundedCursor?.canOpen == true,
          unvalidatedCursorProjection.taskCollection.items.count == 1
    else {
        failAgentLiveEventStoreSelfTest(
            "unvalidated Cursor navigation must not read local private content"
        )
    }

    let mainThreadProjection = agentDashboardProjection(
        collection: .displaying([]),
        permissionQueue: .empty,
        liveReduction: AgentReductionResult(
            snapshots: [
                AgentSessionSnapshot(
                    identity: AgentSessionIdentity(
                        agentID: .cursor,
                        nativeID: "cursor-main-cache-only"
                    ),
                    adapterVersion: "self-test",
                    executionState: .running,
                    attentionReason: .none,
                    actionability: .openNativeApp,
                    evidenceQuality: .officialHook,
                    freshness: Freshness(observedAt: base, expiresAt: nil),
                    title: "Cursor 会话",
                    activitySummary: "正在执行",
                    workingDirectory: nil,
                    latestEventID: "cursor-main-hook",
                    updatedAt: base
                ),
                AgentSessionSnapshot(
                    identity: AgentSessionIdentity(
                        agentID: .omp,
                        nativeID: "01a00f00-f7ab-7000-9273-9c7707ab6193"
                    ),
                    adapterVersion: "self-test",
                    executionState: .running,
                    attentionReason: .none,
                    actionability: .openExactNativeSession,
                    evidenceQuality: .officialHook,
                    freshness: Freshness(observedAt: base, expiresAt: nil),
                    title: "OMP 会话",
                    activitySummary: "正在执行",
                    workingDirectory: nil,
                    latestEventID: "omp-main-hook",
                    updatedAt: base
                ),
            ],
            attentionItems: [],
            processedEventCount: 2,
            events: [
                makeLiveStoreAgentEvent(
                    agentID: .cursor,
                    nativeID: "cursor-main-cache-only",
                    eventID: "cursor-main-hook",
                    eventType: "postToolUse",
                    observedAt: base,
                    state: .running
                ),
                makeLiveStoreAgentEvent(
                    agentID: .omp,
                    nativeID: "01a00f00-f7ab-7000-9273-9c7707ab6193",
                    eventID: "omp-main-hook",
                    eventType: "tool_result",
                    observedAt: base,
                    state: .running
                ),
            ]
        ),
        agentCompatibilities: [
            .cursor: .validated,
            .omp: .validated,
        ]
    )
    guard mainThreadProjection.taskCollection.items.count == 2,
          mainThreadProjection.taskCollection.items.allSatisfy({
              $0.projection.currentToolStatus?.text == "工具调用完成"
                  && $0.projection.publicMessages.isEmpty
          })
    else {
        failAgentLiveEventStoreSelfTest(
            "main-thread dashboard projection must be hook/cache-only"
        )
    }
}

private func makeLiveStoreAgentEvent(
    agentID: AgentID,
    nativeID: String,
    eventID: String,
    eventType: String,
    observedAt: Date,
    state: ExecutionState
) -> AgentEvent {
    AgentEvent(
        identity: AgentSessionIdentity(agentID: agentID, nativeID: nativeID),
        adapterVersion: "self-test",
        eventID: eventID,
        sequence: nil,
        eventType: eventType,
        observedAt: observedAt,
        monotonicNanoseconds: nil,
        executionState: state,
        attentionReason: .none,
        actionability: agentID == .omp ? .viewOnly : .openNativeApp,
        evidenceQuality: .officialHook,
        freshness: Freshness(observedAt: observedAt, expiresAt: nil),
        title: "会话",
        activitySummary: "正在执行",
        workingDirectory: nil
    )
}

private func makeLocalProjection(
    agentID: AgentID,
    sessionKey: String,
    messages: [(Date, String)]
) -> AgentActivityProjection {
    AgentActivityProjection(
        publicMessages: messages.enumerated().map { index, message in
            AgentActivityEntry(
                id: AgentActivityEventID(
                    source: agentID,
                    sessionKey: sessionKey,
                    stableSourceKey: "self-test-local:\(index)"
                ),
                occurredAt: message.0,
                sourceOrder: UInt64(index),
                text: message.1
            )
        }
    )
}

private func makeLiveStoreEnvelope(
    agentID: AgentID,
    eventID: String,
    nativeSessionCandidate: String? = "session-one",
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
