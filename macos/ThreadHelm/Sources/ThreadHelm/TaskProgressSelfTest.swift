//
//  TaskProgressSelfTest.swift
//  ThreadHelm
//
//  模块职责：--self-test-task-progress 自测（阶段一与入口）——Codex 任务
//  生命周期解析、安全活动摘要、列表排序/去重/滚动数据源、标题解析、
//  深度链接、点击/滚动/刷新命中测试、活动预览与悬停回调、已完成任务
//  可见性过滤。阶段二见 TaskProgressSelfTestPhase2.swift。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

func runTaskProgressSelfTest() -> Never {
    let now = Date()
    let started = #"{"type":"event_msg","payload":{"type":"task_started"}}"#
    runAgentIntegrationSelfTest()
    runTaskProgressSelfTestPhase1(now: now, started: started)
    runCodexTailMetadataBackfillSelfTest(now: now, started: started)
    runTaskProgressSelfTestPhase2(now: now, started: started)
    runTaskProgressRefreshGateSelfTest()
    guard runTaskProgressRefreshStabilityRegressionSelfTest() else {
        fputs("task progress refresh reader stability failed\n", stderr)
        exit(1)
    }
    runClaudeAgentsCommandTimeoutSelfTest()
    runRuntimeHealthWriterFailureSelfTest()
    print("task-progress-self-test: agent-core=5+builtin+sixth; agent-registry=dedupe+fail-open; agent-reducer=duplicate+out-of-order+stable-tie; lifecycle=7/7; safe-activity=pass; updated-sort=pass; active-scroll=pass; terminal-backfill=pass; title=1/1; index=1/1; deep-link=2/2; click-hit=pass; scroll-hit=pass; refresh-hit=pass; hover-live=pass; completed-unread=pass; read-state=6/6; top-level-filter=explicit-visible+automation-safe; task-dedup=pass; full-collection=pass; codex-cwd=tail-metadata-backfill; events=all-safe; privacy=pass; refresh-gate=single-flight+generation; refresh-reader=reuse; claude-agents-timeout=bounded; runtime-health-failure=logged-once; system-symbols=6/6; claude-source=pass; claude-public-output=pass; claude-agent-merge=order-independent+dead-pid; claude-navigation=identity-first; claude-entry-points=same-cwd; claude-terminal-focus=pid-chain+3-hosts; claude-iterm-resume=2/2; claude-otty=3/3; claude-resume=2/2")
    exit(0)
}

private func runCodexTailMetadataBackfillSelfTest(now: Date, started: String) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "threadhelm-codex-tail-metadata-\(UUID().uuidString)",
        isDirectory: true
    )
    let rolloutURL = directory.appendingPathComponent(
        "rollout-2026-08-11T00-00-00-00000000-0000-0000-0000-000000000001.jsonl"
    )
    let environmentKey = "THREADHELM_TASK_ROLLOUT_FILE"
    let previousValue = getenv(environmentKey).map { String(cString: $0) }
    defer {
        if let previousValue {
            setenv(environmentKey, previousValue, 1)
        } else {
            unsetenv(environmentKey)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    let sessionMeta = #"{"type":"session_meta","payload":{"cwd":"/tmp/threadhelm-tail-project","thread_source":"root"}}"#
    let publicUpdate = #"{"timestamp":"2026-08-11T00:00:01Z","type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"正在验证大型会话"}}"#
    let filler = String(repeating: "x", count: 1_100_000)
    do {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data(
            [sessionMeta, filler, started, publicUpdate]
                .joined(separator: "\n")
                .appending("\n")
                .utf8
        ).write(to: rolloutURL)
    } catch {
        fputs("Codex tail metadata fixture failed\n", stderr)
        exit(1)
    }

    setenv(environmentKey, rolloutURL.path, 1)
    let item = CodexTaskProgressReader().readCollection().items.first
    guard item?.workingDirectory == "/tmp/threadhelm-tail-project",
          item?.activityText == "正在验证大型会话"
    else {
        fputs("Codex tail metadata cwd backfill failed\n", stderr)
        exit(1)
    }
}

private func runTaskProgressRefreshGateSelfTest() {
    var gate = TaskProgressRefreshGate()
    guard let slowGeneration = gate.begin() else {
        fputs("task progress refresh gate did not start first read\n", stderr)
        exit(1)
    }
    guard gate.begin() == nil else {
        fputs("task progress refresh gate allowed an overlapping read\n", stderr)
        exit(1)
    }
    guard gate.begin() == nil else {
        fputs("task progress refresh gate replaced a still-running read\n", stderr)
        exit(1)
    }
    guard gate.complete(generation: slowGeneration),
          let freshGeneration = gate.begin(),
          freshGeneration != slowGeneration
    else {
        fputs("task progress refresh gate did not resume after completion\n", stderr)
        exit(1)
    }
    guard !gate.complete(generation: slowGeneration),
          gate.complete(generation: freshGeneration),
          gate.begin() != nil
    else {
        fputs("task progress refresh gate accepted a stale completion\n", stderr)
        exit(1)
    }
}

private func runClaudeAgentsCommandTimeoutSelfTest() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "threadhelm-claude-agents-timeout-\(UUID().uuidString)",
        isDirectory: true
    )
    let executable = directory.appendingPathComponent("claude")
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data(
            """
            #!/bin/sh
            trap '' TERM
            printf '[{"sessionId":"00000000-0000-0000-0000-000000000001"}]'
            exec /bin/sleep 30
            """.utf8
        ).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
    } catch {
        fputs("Claude agents timeout fixture failed\n", stderr)
        exit(1)
    }

    let startedAt = Date()
    let output = captureClaudeAgentsJSON(
        executableURL: executable,
        timeout: 0.1,
        terminationGracePeriod: 0.1
    )
    guard output == nil, Date().timeIntervalSince(startedAt) < 1 else {
        fputs("Claude agents command did not stop after timeout\n", stderr)
        exit(1)
    }
}

private func runRuntimeHealthWriterFailureSelfTest() {
    let blockedURL = URL(fileURLWithPath: "/tmp/threadhelm-health-blocked/panel-health.json")
    var messages: [String] = []
    let writer = RuntimeHealthWriter(
        fileURL: blockedURL,
        createDirectory: { _, _ in
            throw NSError(domain: "RuntimeHealthWriterSelfTest", code: 1)
        },
        writeData: { _, _ in
            throw NSError(domain: "RuntimeHealthWriterSelfTest", code: 2)
        },
        logFailure: { message in
            messages.append(message)
        }
    )
    writer.write(
        status: "following-pet",
        panelVisible: true,
        locationSource: "self-test",
        force: true
    )
    writer.write(
        status: "following-pet",
        panelVisible: true,
        locationSource: "self-test",
        force: true
    )
    guard messages.count == 1,
          messages[0].contains("ThreadHelm health write failed")
    else {
        fputs("runtime health writer failure logging failed\n", stderr)
        exit(1)
    }
}

private func runTaskProgressSelfTestPhase1(now: Date, started: String) {
    let completed = #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
    let failed = #"{"type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}"#
    let request = #"{"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"call-1"}}"#
    let response = #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call-1"}}"#
    let cases: [(String, [String], Date, TaskProgressKind)] = [
        ("running", [started], now, .running),
        ("waiting", [started, request], now, .waitingForInput),
        ("resumed", [started, request, response], now, .running),
        ("completed", [started, completed], now, .completed),
        ("failed", [started, failed], now, .failed),
        ("fresh-tail-fallback", [], now, .running),
        ("idle", [], now.addingTimeInterval(-31 * 60), .idle),
    ]

    for test in cases {
        let result = CodexTaskProgressReader.parse(
            lines: test.1,
            modificationDate: test.2,
            now: now
        )
        guard result.kind == test.3 else {
            fputs("task progress case \(test.0) failed: \(result.kind.rawValue)\n", stderr)
            exit(1)
        }
    }

    let timestampedStarted = #"{"timestamp":"2026-07-25T10:00:00Z","type":"event_msg","payload":{"type":"task_started"}}"#
    let publicCommentary = #"{"timestamp":"2026-07-25T10:02:00Z","type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"**第一行会被后续输出覆盖。**\n第二行。\n第三行。\n第四行覆盖第一行。","agent_reasoning":"隐藏推理绝不显示"}}"#
    let continuedCommentary = #"{"timestamp":"2026-07-25T10:06:00Z","type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"继续检查最终构建与安装状态。"}}"#
    let finalAnswer = #"{"timestamp":"2026-07-25T10:07:00Z","type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"最终结果已经准备完成。"}}"#
    let commandStarted = #"{"timestamp":"2026-07-25T10:03:00Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"tool-1","arguments":"secret command"}}"#
    let commandFinished = #"{"timestamp":"2026-07-25T10:04:00Z","type":"response_item","payload":{"type":"function_call_output","call_id":"tool-1","output":"secret output"}}"#
    let hiddenReasoning = #"{"timestamp":"2026-07-25T10:05:00Z","type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"隐藏推理绝不显示"}]}}"#
    let sessionMeta = #"{"type":"session_meta","payload":{"cwd":"/tmp/threadhelm","thread_source":"root"}}"#
    let openAITestCredential = ["sk", "proj", "ABCDEFGHIJKLMNOPQRSTUV"]
        .joined(separator: "-")
    guard let gitHubCredentialData = Data(
        base64Encoded: "Z2hwX0FCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaMTIzNDU2Nzg5MA=="
    ),
          let gitHubTestCredential = String(
              data: gitHubCredentialData,
              encoding: .utf8
          )
    else {
        fputs("task progress credential fixture decode failed\n", stderr)
        exit(1)
    }
    let codexCommentaryCredential = ["sk", "proj", "CODEXCOMMENTARYSECRET"]
        .joined(separator: "-")
    let slackTestCredential = ["xoxb", "123456789012", "abcdefghijklmnop"]
        .joined(separator: "-")
    let publicCredentialText = "Authorization: Bearer codex-bearer-secret-1234567890 "
        + "api_key=\(openAITestCredential) "
        + "password=correct-horse-battery-staple "
        + "\(gitHubTestCredential) "
        + slackTestCredential
    guard let redactedCredentialText = safePublicActivityParagraph(
        from: publicCredentialText
    ),
          redactedCredentialText.contains("[已隐藏]"),
          !redactedCredentialText.contains("codex-bearer-secret-1234567890"),
          !redactedCredentialText.contains(openAITestCredential),
          !redactedCredentialText.contains("correct-horse-battery-staple"),
          !redactedCredentialText.contains(gitHubTestCredential),
          !redactedCredentialText.contains(slackTestCredential),
          safePublicActivityParagraph(
              from: #"{"access_token":"raw-json-secret-123456"}"#
          ) == nil,
          safePublicActivityParagraph(
              from: "-----BEGIN PRIVATE KEY-----\nprivate-key-secret\n-----END PRIVATE KEY-----"
          ) == nil
    else {
        fputs("public activity credential sanitizer failed\n", stderr)
        exit(1)
    }
    let codexCredentialCommentary = #"{"timestamp":"2026-07-25T10:07:00Z","type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"Authorization: Bearer codex-commentary-secret-1234567890 api_key=\#(codexCommentaryCredential)"}}"#
    let codexRawJSONCommentary = #"{"timestamp":"2026-07-25T10:08:00Z","type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"{\"refresh_token\":\"codex-json-secret-123456\"}"}}"#
    let codexCredentialSnapshot = CodexTaskProgressReader.parse(
        lines: [
            timestampedStarted,
            codexCredentialCommentary,
            codexRawJSONCommentary,
        ],
        modificationDate: now,
        now: now
    )
    let codexCredentialSurface = ([
        codexCredentialSnapshot.items.first?.activityText,
    ] + (codexCredentialSnapshot.items.first?.events.map(\.text) ?? []))
        .compactMap { $0 }
        .joined(separator: " ")
    guard codexCredentialSurface.contains("[已隐藏]"),
          !codexCredentialSurface.contains("codex-commentary-secret-1234567890"),
          !codexCredentialSurface.contains(codexCommentaryCredential),
          !codexCredentialSurface.contains("codex-json-secret-123456")
    else {
        fputs("Codex public commentary credential filtering failed\n", stderr)
        exit(1)
    }
    let parsedWithDirectory = CodexTaskProgressReader.parse(
        lines: [
            sessionMeta,
            timestampedStarted,
            publicCommentary,
            commandStarted,
            continuedCommentary,
            finalAnswer,
        ],
        modificationDate: now,
        now: now
    )
    guard parsedWithDirectory.items.first?.workingDirectory == "/tmp/threadhelm",
          parsedWithDirectory.items.first?.events.count == 5,
          parsedWithDirectory.items.first?.events.last?.text
            == "最终结果已经准备完成。",
          parsedWithDirectory.items.first?.events.allSatisfy({
              !$0.text.contains("secret")
                  && !$0.text.contains("隐藏推理")
          }) == true
    else {
        fputs("Codex cwd or complete safe events failed\n", stderr)
        exit(1)
    }

    let longEventText = String(repeating: "完整公开活动内容", count: 64)
    let completeEvents = (1...5).reduce(into: [TaskActivityEvent]()) { result, index in
        result = appendingTaskActivityEvent(
            TaskActivityEvent(
                kind: .commentary,
                occurredAt: now.addingTimeInterval(TimeInterval(index)),
                text: index == 5 ? longEventText : "安全事件 \(index)"
            ),
            to: result
        )
    }
    guard completeEvents.count == 5,
          completeEvents.last?.text == longEventText,
          (completeEvents.last?.text.count ?? 0) > 280
    else {
        fputs("complete activity event preservation failed\n", stderr)
        exit(1)
    }
    let firstLongParagraph = String(repeating: "甲", count: 5_000)
    let secondLongParagraph = String(repeating: "乙", count: 5_000)
    let completeParagraph = appendingTaskActivityParagraph(
        secondLongParagraph,
        to: firstLongParagraph
    )
    guard completeParagraph == "\(firstLongParagraph) \(secondLongParagraph)",
          completeParagraph.count == 10_001
    else {
        fputs("complete activity paragraph preservation failed\n", stderr)
        exit(1)
    }

    let secondStarted = #"{"timestamp":"2026-07-25T10:05:30Z","type":"event_msg","payload":{"type":"task_started"}}"#
    let currentTurnOnly = CodexTaskProgressReader.parse(
        lines: [
            timestampedStarted,
            publicCommentary,
            secondStarted,
            continuedCommentary,
        ],
        modificationDate: now,
        now: now
    )
    guard currentTurnOnly.items.first?.events.map(\.text)
        == ["任务开始", "继续检查最终构建与安装状态。"]
    else {
        fputs("Codex current-turn activity reset failed\n", stderr)
        exit(1)
    }

    let full = TaskProgressCollectionSnapshot.displaying(
        (0..<7).map {
            TaskProgressItem(
                title: "Run \($0)",
                kind: .running,
                startedAt: now,
                updatedAt: now.addingTimeInterval(TimeInterval($0))
            )
        } + [
            TaskProgressItem(title: "Failed", kind: .failed, startedAt: now)
        ]
    )
    guard full.items.count == 8,
          full.compactProjection().items.count == 7,
          full.filtered(source: .all, state: .failed).count == 1
    else {
        fputs("full task collection projection or filtering failed\n", stderr)
        exit(1)
    }

    let claudeSessionID = "b687a9ef-4535-4bb4-a9d5-e692bbcdb0a6"
    let namedSessionMetadataOnly = #"{"type":"user","timestamp":"2026-08-12T06:22:05.276Z","message":{"role":"user","content":"<system-reminder>\nThe user named this session \"Pi验证\". This may indicate the session's focus or intent.\n</system-reminder>"}}"#
    let inactiveNamedSession = ClaudeTaskProgressReader.parseTranscript(
        lines: [namedSessionMetadataOnly],
        sessionID: claudeSessionID,
        fallbackTitle: "Claude 会话",
        workingDirectory: "/tmp/claude-project",
        activeKind: nil,
        startedAt: now,
        modificationDate: now
    )
    guard inactiveNamedSession == nil else {
        fputs("inactive Claude metadata transcript reported as running\n", stderr)
        exit(1)
    }

    let claudePublicText = #"{"type":"assistant","timestamp":"2026-07-25T10:01:00.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"隐藏推理绝不显示"},{"type":"text","text":"正在检查 Claude 任务"}],"stop_reason":null}}"#
    let claudeToolUse = #"{"type":"assistant","timestamp":"2026-07-25T10:02:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tool-claude-1","name":"Bash","input":{"command":"echo secret"}}],"stop_reason":null}}"#
    let claudeToolResult = #"{"type":"user","timestamp":"2026-07-25T10:03:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool-claude-1","content":"secret output"}]}}"#
    let claudeSecondPublicText = #"{"type":"assistant","timestamp":"2026-07-25T10:04:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"继续整理公开状态"}],"stop_reason":null}}"#
    let claudeLongPublicTextValue = String(repeating: "完整 Claude 输出内容", count: 40)
    let claudeLongPublicText = #"{"type":"assistant","timestamp":"2026-07-25T10:04:30.000Z","message":{"role":"assistant","content":[{"type":"text","text":"\#(claudeLongPublicTextValue)"}],"stop_reason":null}}"#
    let claudeGitHubTestCredential = "gh" + "o_" + "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890"
    let claudeCredentialText = #"{"type":"assistant","timestamp":"2026-07-25T10:05:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"client_secret=claude-client-secret-123456 access_token=\#(claudeGitHubTestCredential)"}],"stop_reason":null}}"#
    let claudeRawJSONText = #"{"type":"assistant","timestamp":"2026-07-25T10:06:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"{\"password\":\"claude-json-secret-123456\"}"}],"stop_reason":null}}"#
    let claudeWithEvents = ClaudeTaskProgressReader.parseTranscript(
        lines: [
            claudePublicText,
            claudeToolUse,
            claudeToolResult,
            claudeSecondPublicText,
            claudeLongPublicText,
        ],
        sessionID: claudeSessionID,
        fallbackTitle: "Claude 会话",
        workingDirectory: "/tmp/claude-project",
        activeKind: .running,
        startedAt: now.addingTimeInterval(-30),
        modificationDate: now
    )
    let claudeEvents = claudeWithEvents?.events ?? []
    guard claudeEvents.count == 4,
          claudeEvents.map(\.kind) == [
              .commentary,
              .tool,
              .commentary,
              .commentary,
          ],
          claudeEvents.last?.text == claudeLongPublicTextValue,
          (claudeEvents.last?.text.count ?? 0) > 280,
          claudeEvents.allSatisfy({
              !$0.text.contains("secret")
                  && !$0.text.contains("隐藏推理")
          }) == true
    else {
        fputs("Claude complete safe events or privacy filtering failed\n", stderr)
        exit(1)
    }

    let claudeCredentialSnapshot = ClaudeTaskProgressReader.parseTranscript(
        lines: [claudeCredentialText, claudeRawJSONText],
        sessionID: claudeSessionID,
        fallbackTitle: "Claude 会话",
        workingDirectory: "/tmp/claude-project",
        activeKind: .running,
        startedAt: now.addingTimeInterval(-30),
        modificationDate: now
    )
    let claudeCredentialSurface = ([
        claudeCredentialSnapshot?.activityText,
    ] + (claudeCredentialSnapshot?.events.map(\.text) ?? []))
        .compactMap { $0 }
        .joined(separator: " ")
    guard claudeCredentialSurface.contains("[已隐藏]"),
          !claudeCredentialSurface.contains("claude-client-secret-123456"),
          !claudeCredentialSurface.contains(claudeGitHubTestCredential),
          !claudeCredentialSurface.contains("claude-json-secret-123456")
    else {
        fputs("Claude public text credential filtering failed\n", stderr)
        exit(1)
    }

    let toolActive = CodexTaskProgressReader.parse(
        lines: [timestampedStarted, publicCommentary, commandStarted, hiddenReasoning],
        modificationDate: now,
        now: now
    )
    let expectedToolUpdate = ISO8601DateFormatter().date(from: "2026-07-25T10:03:00Z")
    guard toolActive.items.first?.updatedAt == expectedToolUpdate,
          toolActive.items.first?.activityText
            == "正在运行命令 · 第一行会被后续输出覆盖。 第二行。 第三行。 第四行覆盖第一行。",
          toolActive.items.first?.activityText?.contains("secret") == false,
          toolActive.items.first?.activityText?.contains("隐藏推理") == false
    else {
        fputs("safe active tool summary or updatedAt failed\n", stderr)
        exit(1)
    }

    let commentaryFallback = CodexTaskProgressReader.parse(
        lines: [
            timestampedStarted,
            publicCommentary,
            commandStarted,
            commandFinished,
            hiddenReasoning,
        ],
        modificationDate: now,
        now: now
    )
    let expectedCommentaryUpdate = ISO8601DateFormatter().date(from: "2026-07-25T10:04:00Z")
    guard commentaryFallback.items.first?.updatedAt == expectedCommentaryUpdate,
          commentaryFallback.items.first?.activityText
            == "第一行会被后续输出覆盖。 第二行。 第三行。 第四行覆盖第一行。",
          commentaryFallback.items.first?.activityText?.contains("secret") == false,
          commentaryFallback.items.first?.activityText?.contains("隐藏推理") == false
    else {
        fputs("public commentary fallback or privacy filtering failed\n", stderr)
        exit(1)
    }

    let rollingCommentary = CodexTaskProgressReader.parse(
        lines: [
            timestampedStarted,
            publicCommentary,
            commandStarted,
            commandFinished,
            continuedCommentary,
            continuedCommentary,
            hiddenReasoning,
        ],
        modificationDate: now,
        now: now
    )
    let expectedAccumulatedUpdate = ISO8601DateFormatter().date(
        from: "2026-07-25T10:06:00Z"
    )
    guard rollingCommentary.items.first?.updatedAt == expectedAccumulatedUpdate,
          rollingCommentary.items.first?.activityText
            == "第一行会被后续输出覆盖。 第二行。 第三行。 第四行覆盖第一行。 继续检查最终构建与安装状态。"
    else {
        fputs("single-paragraph public commentary accumulation failed\n", stderr)
        exit(1)
    }

    let sortingBase = Date(timeIntervalSince1970: 10_000)
    let scrollingPresentation = TaskProgressSnapshot.displaying((0..<7).map { index in
        TaskProgressItem(
            title: "活跃任务 \(index + 1)",
            kind: index == 1 ? .waitingForInput : .running,
            startedAt: sortingBase.addingTimeInterval(Double(index)),
            updatedAt: sortingBase.addingTimeInterval(Double(index))
        )
    })
    guard scrollingPresentation.isScrollable,
          scrollingPresentation.items.count == 7,
          scrollingPresentation.items.first?.title == "活跃任务 7",
          scrollingPresentation.items.last?.title == "活跃任务 1",
          scrollingPresentation.items.contains(where: { $0.kind == .waitingForInput })
    else {
        fputs("active task scrolling selection or updatedAt sorting failed\n", stderr)
        exit(1)
    }

    let mixedPresentation = TaskProgressSnapshot.displaying([
        TaskProgressItem(
            title: "运行任务",
            kind: .running,
            startedAt: sortingBase,
            updatedAt: sortingBase.addingTimeInterval(60)
        ),
        TaskProgressItem(
            title: "等待输入",
            kind: .waitingForInput,
            startedAt: sortingBase,
            updatedAt: sortingBase.addingTimeInterval(50)
        ),
        TaskProgressItem(
            title: "完成 A",
            kind: .completed,
            startedAt: sortingBase,
            updatedAt: sortingBase.addingTimeInterval(40)
        ),
        TaskProgressItem(
            title: "失败 B",
            kind: .failed,
            startedAt: sortingBase,
            updatedAt: sortingBase.addingTimeInterval(30)
        ),
        TaskProgressItem(
            title: "完成 C",
            kind: .completed,
            startedAt: sortingBase,
            updatedAt: sortingBase.addingTimeInterval(20)
        ),
        TaskProgressItem(
            title: "完成 D",
            kind: .completed,
            startedAt: sortingBase,
            updatedAt: sortingBase.addingTimeInterval(10)
        ),
    ])
    guard !mixedPresentation.isScrollable,
          mixedPresentation.items.map(\.title)
            == ["运行任务", "等待输入", "完成 A", "失败 B", "完成 C"]
    else {
        fputs("active-first terminal backfill failed\n", stderr)
        exit(1)
    }

    let titledUserMessage = ##"{"type":"event_msg","payload":{"type":"user_message","message":"# Files mentioned by the user:\n/a.png\n## My request for Codex:\n列出具体任务名称"}}"##
    let titled = CodexTaskProgressReader.parse(
        lines: [titledUserMessage, started],
        modificationDate: now,
        now: now
    )
    guard titled.items.first?.title == "列出具体任务名称" else {
        fputs("task title extraction failed\n", stderr)
        exit(1)
    }

    let indexedThreadID = "12345678-1234-4abc-8def-1234567890ab"
    let indexedRollout = URL(fileURLWithPath:
        "/tmp/rollout-2026-07-16T16-52-47-\(indexedThreadID).jsonl"
    )
    let indexedTitle = CodexTaskProgressReader.resolvedTitle(
        for: indexedRollout,
        indexedTitles: [indexedThreadID: "正式任务名称"],
        fallback: "Codex 任务"
    )
    guard indexedTitle == "正式任务名称" else {
        fputs("task index title mapping failed\n", stderr)
        exit(1)
    }

    guard panelSizeForTaskRows(1) == NSSize(width: 388, height: 226),
          panelSizeForTaskRows(maximumVisibleTaskRows).width
            > panelSizeForTaskRows(maximumVisibleTaskRows).height,
          abs(presentedPanelScale(243 / 356) - 0.95) <= 0.001,
          abs(
              scaledPanelSize(
                  panelSizeForTaskRows(1),
                  scale: presentedPanelScale(243 / 356)
              ).width - 368.6
          ) <= 0.1,
          codexThreadURL(threadID: indexedThreadID)?.absoluteString
            == "codex://threads/\(indexedThreadID)",
          codexThreadURL(threadID: "not-a-thread") == nil
    else {
        fputs("wide-panel or Codex thread deep-link validation failed\n", stderr)
        exit(1)
    }

    _ = NSApplication.shared
    let clickView = QuotaPanelView(
        frame: NSRect(origin: .zero, size: panelSizeForTaskRows(1))
    )
    let clickWindow = NSWindow(
        contentRect: clickView.frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    clickWindow.contentView = clickView
    clickView.pointerSide = .bottom
    clickView.taskProgress = TaskProgressSnapshot(items: [
        TaskProgressItem(
            title: "可点击任务",
            kind: .running,
            startedAt: now,
            threadID: indexedThreadID
        ),
    ])
    var openedThreadID: String?
    clickView.onOpenTask = { openedThreadID = $0.threadID }
    let rowPointInWindow = clickView.convert(NSPoint(x: 200, y: 66), to: nil)
    guard let clickEvent = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: rowPointInWindow,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: clickWindow.windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 1
    ) else {
        fputs("task click event creation failed\n", stderr)
        exit(1)
    }
    clickView.mouseDown(with: clickEvent)
    guard openedThreadID == indexedThreadID else {
        fputs("task row click hit testing failed\n", stderr)
        exit(1)
    }

    let scrollingView = QuotaPanelView(
        frame: NSRect(origin: .zero, size: panelSizeForTaskRows(maximumVisibleTaskRows))
    )
    let scrollingWindow = NSWindow(
        contentRect: scrollingView.frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    scrollingWindow.contentView = scrollingView
    scrollingView.pointerSide = .bottom
    scrollingView.taskProgress = TaskProgressSnapshot.displaying((0..<7).map { index in
        let threadID = String(
            format: "12345678-1234-4abc-8def-%012d",
            index + 1
        )
        return TaskProgressItem(
            title: "滚动任务 \(index + 1)",
            kind: index == 1 ? .waitingForInput : .running,
            startedAt: now,
            updatedAt: now.addingTimeInterval(Double(index)),
            threadID: threadID
        )
    })
    var scrolledThreadID: String?
    scrollingView.onOpenTask = { scrolledThreadID = $0.threadID }
    let scrollingPointInWindow = scrollingView.convert(NSPoint(x: 200, y: 66), to: nil)
    guard let scrolledClickEvent = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: scrollingPointInWindow,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: scrollingWindow.windowNumber,
        context: nil,
        eventNumber: 2,
        clickCount: 1,
        pressure: 1
    ) else {
        fputs("task scroll event creation failed\n", stderr)
        exit(1)
    }
    scrollingView.scrollTaskList(by: 1)
    scrollingView.mouseDown(with: scrolledClickEvent)
    guard scrolledThreadID == "12345678-1234-4abc-8def-000000000006" else {
        fputs("task scrolled click hit testing failed\n", stderr)
        exit(1)
    }

    let refreshView = QuotaPanelView(
        frame: NSRect(origin: .zero, size: panelSizeForTaskRows(1))
    )
    let refreshWindow = NSWindow(
        contentRect: refreshView.frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    refreshWindow.contentView = refreshView
    refreshView.pointerSide = .bottom
    var refreshRequestCount = 0
    refreshView.onRequestQuotaRefresh = { refreshRequestCount += 1 }
    let refreshPointInWindow = refreshView.convert(NSPoint(x: 148, y: 194), to: nil)
    guard let refreshClickEvent = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: refreshPointInWindow,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: refreshWindow.windowNumber,
        context: nil,
        eventNumber: 3,
        clickCount: 1,
        pressure: 1
    ) else {
        fputs("quota refresh click event creation failed\n", stderr)
        exit(1)
    }
    refreshView.mouseDown(with: refreshClickEvent)
    guard refreshRequestCount == 1 else {
        fputs("quota refresh click hit testing failed\n", stderr)
        exit(1)
    }

    let runningPreviewItem = TaskProgressItem(
        title: "运行任务",
        kind: .running,
        startedAt: now,
        updatedAt: now,
        activityText: "正在编辑文件",
        threadID: indexedThreadID
    )
    let completedPreviewItem = TaskProgressItem(
        title: "完成任务",
        kind: .completed,
        startedAt: now,
        updatedAt: now,
        activityText: "这段内容不应显示",
        threadID: indexedThreadID
    )
    guard taskActivityPreviewPayload(for: runningPreviewItem)?.body == "正在编辑文件",
          taskActivityPreviewPayload(for: completedPreviewItem) == nil
    else {
        fputs("task activity preview eligibility failed\n", stderr)
        exit(1)
    }

    let tailWindowFont = NSFont.monospacedSystemFont(
        ofSize: 10,
        weight: .regular
    )
    let sevenCharacterWidth = ("abcdefg" as NSString).size(
        withAttributes: [.font: tailWindowFont]
    ).width + 0.5
    let firstTailWindow = taskActivityVisibleTailText(
        from: "abcdefghijklmnopqrstuv",
        width: sevenCharacterWidth,
        font: tailWindowFont,
        lineSpacing: 0,
        maximumLineCount: 3
    )
    let nextTailWindow = taskActivityVisibleTailText(
        from: "abcdefghijklmnopqrstuvw",
        width: sevenCharacterWidth,
        font: tailWindowFont,
        lineSpacing: 0,
        maximumLineCount: 3
    )
    guard firstTailWindow == "bcdefghijklmnopqrstuv",
          nextTailWindow == "cdefghijklmnopqrstuvw"
    else {
        fputs("task activity character tail window failed\n", stderr)
        exit(1)
    }

    let previewController = TaskActivityPreviewController()
    previewController.show(
        item: runningPreviewItem,
        anchorRect: NSRect(x: 100, y: 100, width: 180, height: 26),
        visibleFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
    )
    let compactPreviewHeight = previewController.currentPanelHeight
    guard previewController.isVisible,
          previewController.currentBody == "正在编辑文件"
    else {
        fputs("task activity preview presentation failed\n", stderr)
        exit(1)
    }
    previewController.update(item: TaskProgressItem(
        title: "运行任务",
        kind: .running,
        startedAt: now,
        updatedAt: now.addingTimeInterval(2),
        activityText: "正在运行命令",
        threadID: indexedThreadID
    ))
    guard previewController.isVisible,
          previewController.currentBody == "正在运行命令"
    else {
        fputs("task activity preview live update failed\n", stderr)
        exit(1)
    }
    previewController.update(item: TaskProgressItem(
        title: "运行任务",
        kind: .running,
        startedAt: now,
        updatedAt: now.addingTimeInterval(3),
        activityText: "第一句。 第二句。 第三句。 第四句。 继续检查最终状态。",
        threadID: indexedThreadID
    ))
    guard previewController.isVisible,
          previewController.currentBody
            == "第一句。 第二句。 第三句。 第四句。 继续检查最终状态。",
          previewController.currentPanelHeight == compactPreviewHeight
    else {
        fputs("task activity preview single-paragraph window failed\n", stderr)
        exit(1)
    }
    previewController.update(item: completedPreviewItem)
    guard !previewController.isVisible else {
        fputs("task activity preview terminal dismissal failed\n", stderr)
        exit(1)
    }

    let hoverView = QuotaPanelView(
        frame: NSRect(origin: .zero, size: panelSizeForTaskRows(1))
    )
    let hoverWindow = NSWindow(
        contentRect: hoverView.frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    hoverWindow.contentView = hoverView
    hoverView.pointerSide = .bottom
    hoverView.taskProgress = TaskProgressSnapshot(items: [runningPreviewItem])
    var hoveredActivity: String?
    var hoveredAnchor: NSRect?
    hoverView.onHoverRunningTask = { item, anchor in
        hoveredActivity = item?.activityText
        hoveredAnchor = anchor
    }
    hoverView.updateTaskHover(index: 0)
    guard hoveredActivity == "正在编辑文件", hoveredAnchor != nil else {
        fputs("task hover callback presentation failed\n", stderr)
        exit(1)
    }
    hoverView.taskProgress = TaskProgressSnapshot(items: [TaskProgressItem(
        title: "运行任务",
        kind: .running,
        startedAt: now,
        updatedAt: now.addingTimeInterval(2),
        activityText: "正在搜索或检查网页",
        threadID: indexedThreadID
    )])
    guard hoveredActivity == "正在搜索或检查网页" else {
        fputs("task hover callback segmented update failed\n", stderr)
        exit(1)
    }
    hoverView.taskProgress = TaskProgressSnapshot(items: [completedPreviewItem])
    guard hoveredActivity == nil, hoveredAnchor == nil else {
        fputs("task hover callback terminal dismissal failed\n", stderr)
        exit(1)
    }

    let unreadState = CodexTaskProgressReader.UnreadThreadState(
        ids: [indexedThreadID],
        isAvailable: true
    )
    let readState = CodexTaskProgressReader.UnreadThreadState(
        ids: [],
        isAvailable: true
    )
    let unavailableState = CodexTaskProgressReader.UnreadThreadState(
        ids: [],
        isAvailable: false
    )
    let completedVisibilityCases = [
        CodexTaskProgressReader.shouldDisplay(
            kind: .completed,
            threadID: indexedThreadID,
            modificationDate: now.addingTimeInterval(-3600),
            now: now,
            unreadState: unreadState
        ),
        !CodexTaskProgressReader.shouldDisplay(
            kind: .completed,
            threadID: indexedThreadID,
            modificationDate: now,
            now: now,
            unreadState: readState
        ),
        CodexTaskProgressReader.shouldDisplay(
            kind: .completed,
            threadID: indexedThreadID,
            modificationDate: now,
            now: now,
            unreadState: unavailableState,
            fallbackVisibility: 120
        ),
        CodexTaskProgressReader.shouldDisplay(
            kind: .failed,
            threadID: indexedThreadID,
            modificationDate: now.addingTimeInterval(-3600),
            now: now,
            unreadState: unreadState
        ),
        !CodexTaskProgressReader.shouldDisplay(
            kind: .completed,
            threadID: indexedThreadID,
            modificationDate: now.addingTimeInterval(
                -(completedTaskPanelRetention + 1)
            ),
            now: now,
            unreadState: unreadState
        ),
        !CodexTaskProgressReader.shouldDisplay(
            kind: .failed,
            threadID: indexedThreadID,
            modificationDate: now,
            now: now,
            unreadState: readState
        ),
        !CodexTaskProgressReader.shouldDisplay(
            kind: .completed,
            threadID: indexedThreadID,
            modificationDate: now.addingTimeInterval(-180),
            now: now,
            unreadState: unavailableState,
            fallbackVisibility: 120
        ),
        CodexTaskProgressReader.shouldDisplay(
            kind: .completed,
            threadID: indexedThreadID,
            modificationDate: now.addingTimeInterval(
                -(completedTaskPanelRetention - 1)
            ),
            now: now,
            unreadState: unavailableState
        ),
        !CodexTaskProgressReader.shouldDisplay(
            kind: .completed,
            threadID: indexedThreadID,
            modificationDate: now.addingTimeInterval(
                -(completedTaskPanelRetention + 1)
            ),
            now: now,
            unreadState: unavailableState
        ),
        CodexTaskProgressReader.shouldDisplay(
            kind: .running,
            threadID: indexedThreadID,
            modificationDate: now,
            now: now,
            unreadState: readState,
            terminalDate: now.addingTimeInterval(
                -(completedTaskPanelRetention + 1)
            )
        ),
        !CodexTaskProgressReader.shouldDisplay(
            kind: .completed,
            threadID: indexedThreadID,
            modificationDate: now,
            now: now,
            unreadState: unreadState,
            terminalDate: now.addingTimeInterval(
                -(completedTaskPanelRetention + 1)
            )
        ),
    ]
    guard completedVisibilityCases.allSatisfy({ $0 }),
          CodexTaskProgressReader.shouldDisplay(
            kind: .running,
            threadID: indexedThreadID,
            modificationDate: now,
            now: now,
            unreadState: readState
          )
    else {
        fputs("completed task filtering failed\n", stderr)
        exit(1)
    }
}
