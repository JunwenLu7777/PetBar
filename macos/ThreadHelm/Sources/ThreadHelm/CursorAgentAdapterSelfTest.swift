//
//  CursorAgentAdapterSelfTest.swift
//  ThreadHelm
//
//  模块职责：Cursor adapter 自测。该函数只写临时目录，不读取或写入真实
//  ~/.cursor；后续由共享 self-test aggregator 接入。
//

import Foundation
import SQLite3

func runCursorAgentAdapterSelfTest() {
    guard parsedCursorAgentCLIVersion(
        from: ProcessOutputCaptureResult(
            data: Data("2026.04.15-dccdccd\n".utf8),
            termination: .timedOut
        )
    ) == "2026.04.15-dccdccd",
          parsedCursorAgentCLIVersion(
            from: ProcessOutputCaptureResult(
                data: Data(),
                termination: .timedOut
            )
          ) == nil,
          parsedCursorAgentCLIVersion(
            from: ProcessOutputCaptureResult(
                data: Data("2026.04.15-dccdccd\n".utf8),
                termination: .readFailed
            )
          ) == nil
    else {
        failCursorAdapterSelfTest(
            "Agent CLI version must parse even when cursor agent --version is slow to exit"
        )
    }

    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-cursor-adapter-self-test-\(UUID().uuidString)",
        isDirectory: true
    )
    let hooksURL = root
        .appendingPathComponent(".cursor", isDirectory: true)
        .appendingPathComponent("hooks.json")
    let scope = AgentIntegrationScope.isolated(at: root)
    let hookCommand = "/tmp/threadhelm-cursor-hook"
    let adapter = CursorAgentAdapter(
        discovery: {
            AgentDiscovery(
                isInstalled: true,
                version: "cursor-self-test",
                compatibility: .supported
            )
        },
        signals: { [] },
        snapshots: { [] },
        hookCommand: hookCommand,
        openCursorApp: { .appFocused },
        openWorkingDirectory: { _ in true }
    )

    do {
        try manager.createDirectory(
            at: hooksURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let unrelated = """
        {
          "version": 1,
          "hooks": {
            "beforeSubmitPrompt": [
              {"command": "./hooks/keep-first.sh", "timeout": 9}
            ],
            "stop": [
              {"command": "./hooks/keep-stop.sh", "disabled": true}
            ],
            "afterTabFileEdit": [
              {"command": "./hooks/keep-legacy-neighbor.sh", "timeout": 7},
              {
                "command": "/tmp/old-threadhelm --agent-hook cursor afterTabFileEdit",
                "timeout": 1,
                "threadhelmOwner": "ThreadHelm",
                "threadhelmAgent": "cursor",
                "threadhelmEvent": "afterTabFileEdit"
              }
            ]
          },
          "other": {"keep": true}
        }
        """
        try Data(unrelated.utf8).write(to: hooksURL)

        guard adapter.integrationStatus(in: scope) == .needsRepair,
              try adapter.installIntegration(in: scope) == .installed,
              adapter.integrationStatus(in: scope) == .installed,
              try adapter.installIntegration(in: scope) == .unchanged
        else { failCursorAdapterSelfTest("install/status/repeated install") }

        let installed = try cursorSelfTestObject(at: hooksURL)
        guard ((installed["other"] as? [String: Any])?["keep"] as? Bool) == true,
              let hooks = installed["hooks"] as? [String: Any],
              ((hooks["beforeSubmitPrompt"] as? [[String: Any]])?.first?[
                  "command"
              ] as? String) == "./hooks/keep-first.sh",
              (hooks["sessionStart"] as? [[String: Any]])?.count == 1,
              (hooks["stop"] as? [[String: Any]])?.count == 2,
              let legacyNeighbors = hooks["afterTabFileEdit"] as? [[String: Any]],
              legacyNeighbors.count == 1,
              legacyNeighbors.first?["command"] as? String
                == "./hooks/keep-legacy-neighbor.sh"
        else { failCursorAdapterSelfTest("unrelated config preserved") }

        let partial = """
        {
          "version": 1,
          "hooks": {
            "sessionStart": [
              {
                "command": "/tmp/threadhelm-cursor-hook --agent-hook cursor wrong",
                "timeout": 99,
                "threadhelmOwner": "ThreadHelm",
                "threadhelmAgent": "cursor",
                "threadhelmEvent": "sessionStart"
              }
            ],
            "stop": [
              {"command": "./hooks/keep-stop.sh", "disabled": true}
            ]
          }
        }
        """
        try Data(partial.utf8).write(to: hooksURL)
        guard adapter.integrationStatus(in: scope) == .needsRepair,
              try adapter.repairIntegration(in: scope) == .repaired,
              adapter.integrationStatus(in: scope) == .installed
        else { failCursorAdapterSelfTest("repair partial corruption") }

        let disabled = """
        {
          "version": 1,
          "hooks": {
            "sessionStart": [
              {"command": "/tmp/threadhelm-cursor-hook --agent-hook cursor sessionStart", "timeout": 1, "disabled": true, "threadhelmOwner": "ThreadHelm", "threadhelmAgent": "cursor", "threadhelmEvent": "sessionStart"}
            ],
            "sessionEnd": [
              {"command": "/tmp/threadhelm-cursor-hook --agent-hook cursor sessionEnd", "timeout": 1, "disabled": true, "threadhelmOwner": "ThreadHelm", "threadhelmAgent": "cursor", "threadhelmEvent": "sessionEnd"}
            ],
            "beforeSubmitPrompt": [
              {"command": "/tmp/threadhelm-cursor-hook --agent-hook cursor beforeSubmitPrompt", "timeout": 1, "disabled": true, "threadhelmOwner": "ThreadHelm", "threadhelmAgent": "cursor", "threadhelmEvent": "beforeSubmitPrompt"}
            ],
            "preToolUse": [
              {"command": "/tmp/threadhelm-cursor-hook --agent-hook cursor preToolUse", "timeout": 1, "disabled": true, "threadhelmOwner": "ThreadHelm", "threadhelmAgent": "cursor", "threadhelmEvent": "preToolUse"}
            ],
            "postToolUse": [
              {"command": "/tmp/threadhelm-cursor-hook --agent-hook cursor postToolUse", "timeout": 1, "disabled": true, "threadhelmOwner": "ThreadHelm", "threadhelmAgent": "cursor", "threadhelmEvent": "postToolUse"}
            ],
            "postToolUseFailure": [
              {"command": "/tmp/threadhelm-cursor-hook --agent-hook cursor postToolUseFailure", "timeout": 1, "disabled": true, "threadhelmOwner": "ThreadHelm", "threadhelmAgent": "cursor", "threadhelmEvent": "postToolUseFailure"}
            ],
            "stop": [
              {"command": "/tmp/threadhelm-cursor-hook --agent-hook cursor stop", "timeout": 1, "disabled": true, "threadhelmOwner": "ThreadHelm", "threadhelmAgent": "cursor", "threadhelmEvent": "stop"}
            ],
            "subagentStart": [
              {"command": "/tmp/threadhelm-cursor-hook --agent-hook cursor subagentStart", "timeout": 1, "disabled": true, "threadhelmOwner": "ThreadHelm", "threadhelmAgent": "cursor", "threadhelmEvent": "subagentStart"}
            ],
            "subagentStop": [
              {"command": "/tmp/threadhelm-cursor-hook --agent-hook cursor subagentStop", "timeout": 1, "disabled": true, "threadhelmOwner": "ThreadHelm", "threadhelmAgent": "cursor", "threadhelmEvent": "subagentStop"}
            ]
          }
        }
        """
        try Data(disabled.utf8).write(to: hooksURL)
        guard adapter.integrationStatus(in: scope) == .needsRepair,
              try adapter.repairIntegration(in: scope) == .repaired,
              adapter.integrationStatus(in: scope) == .disabled
        else { failCursorAdapterSelfTest("disabled respected") }

        let safelyDisabled = try cursorSelfTestObject(at: hooksURL)
        guard let safelyDisabledHooks = safelyDisabled["hooks"]
            as? [String: Any],
              [
                  "sessionStart",
                  "sessionEnd",
                  "beforeSubmitPrompt",
                  "preToolUse",
                  "postToolUse",
                  "postToolUseFailure",
                  "stop",
                  "subagentStart",
                  "subagentStop",
              ].allSatisfy({ event in
                  guard let entries = safelyDisabledHooks[event]
                    as? [[String: Any]],
                        entries.count == 1,
                        let entry = entries.first
                  else { return false }
                  return entry["command"] as? String == "/usr/bin/true"
                      && entry["threadhelmDisabled"] as? Bool == true
                      && entry["disabled"] == nil
              })
        else {
            failCursorAdapterSelfTest(
                "disabled hooks must use Cursor-supported no-op commands"
            )
        }

        guard try adapter.uninstallIntegration(in: scope) == .uninstalled,
              try adapter.uninstallIntegration(in: scope) == .unchanged,
              adapter.integrationStatus(in: scope) == .notInstalled
        else { failCursorAdapterSelfTest("uninstall/repeated uninstall") }

        let liveHomeScope = AgentIntegrationScope.isolated(
            at: manager.homeDirectoryForCurrentUser
        )
        do {
            _ = try adapter.installIntegration(in: liveHomeScope)
            failCursorAdapterSelfTest("live-home write guard")
        } catch AgentIntegrationError.liveConfigurationWriteDenied {
        } catch {
            failCursorAdapterSelfTest("live-home guard error type")
        }

        let malformed = Data("{".utf8)
        try malformed.write(to: hooksURL)
        guard adapter.integrationStatus(in: scope) == .needsRepair else {
            failCursorAdapterSelfTest("malformed json status")
        }
        do {
            _ = try adapter.repairIntegration(in: scope)
            failCursorAdapterSelfTest("malformed json was overwritten")
        } catch {
            guard try Data(contentsOf: hooksURL) == malformed else {
                failCursorAdapterSelfTest("malformed json was not preserved")
            }
        }
        do {
            _ = try adapter.uninstallIntegration(in: scope)
            failCursorAdapterSelfTest("malformed json uninstall was accepted")
        } catch {
            guard try Data(contentsOf: hooksURL) == malformed else {
                failCursorAdapterSelfTest(
                    "malformed json uninstall did not preserve input"
                )
            }
        }

        runCursorSignalMappingSelfTest()
        runCursorTransportSelfTest()
        runCursorOpenSelfTest()
        runCursorIndexTailAppendSelfTest()
        runCursorPartialTailCompletionSelfTest()
        runCursorToolSurvivesWindowEvictionSelfTest()
        runCursorMixedThenPureToolOrderingSelfTest()
        runCursorColdScanPureThenMixedToolSelfTest()
        runCursorColdScanCrossPassToolSelfTest()
    } catch {
        failCursorAdapterSelfTest("unexpected error: \(error)")
    }
    try? manager.removeItem(at: root)
}

private func runCursorSignalMappingSelfTest() {
    let now = Date(timeIntervalSince1970: 1_786_500_000)
    let adapter = CursorAgentAdapter(
        discovery: {
            AgentDiscovery(
                isInstalled: true,
                version: "cursor-self-test",
                compatibility: .supported
            )
        },
        signals: {
            [
                CursorHookSignal(
                    eventType: "sessionStart",
                    sessionID: "cursor-session",
                    eventID: "event-1",
                    sequence: 1,
                    monotonicNanoseconds: 1,
                    observedAt: now
                ),
                CursorHookSignal(
                    eventType: "beforeSubmitPrompt",
                    sessionID: "cursor-session",
                    eventID: "event-2",
                    sequence: 2,
                    monotonicNanoseconds: 2,
                    observedAt: now.addingTimeInterval(1)
                ),
                CursorHookSignal(
                    eventType: "postToolUseFailure",
                    sessionID: "cursor-session",
                    eventID: "event-3",
                    sequence: 3,
                    monotonicNanoseconds: 3,
                    observedAt: now.addingTimeInterval(2)
                ),
                CursorHookSignal(
                    eventType: "subagentStart",
                    sessionID: "cursor-subagent",
                    eventID: "event-4",
                    sequence: 1,
                    monotonicNanoseconds: 4,
                    observedAt: now.addingTimeInterval(3)
                ),
                CursorHookSignal(
                    eventType: "stop",
                    sessionID: "cursor-failed",
                    eventID: "event-5",
                    sequence: 10,
                    monotonicNanoseconds: 10,
                    observedAt: now.addingTimeInterval(4),
                    terminalTaskError: true
                ),
                CursorHookSignal(
                    eventType: "beforeSubmitPrompt",
                    sessionID: "cursor-failed",
                    eventID: "event-6",
                    sequence: 9,
                    monotonicNanoseconds: 9,
                    observedAt: now.addingTimeInterval(5)
                ),
                CursorHookSignal(
                    eventType: "stop",
                    sessionID: nil,
                    eventID: "event-7",
                    observedAt: now.addingTimeInterval(6),
                    terminalTaskError: true
                ),
            ]
        },
        snapshots: { [] },
        openCursorApp: { .appFocused },
        openWorkingDirectory: { _ in true }
    )
    guard let observation = try? adapter.observe(),
          observation.events.count == 7,
          observation.snapshots.contains(where: {
              $0.identity.nativeID == "cursor-session"
                  && $0.executionState == .running
                  && $0.attentionReason == .none
          }),
          observation.snapshots.contains(where: {
              $0.identity.nativeID == "cursor-subagent"
                  && $0.executionState == .running
                  && $0.attentionReason == .none
          }),
          observation.snapshots.contains(where: {
              $0.identity.nativeID == "cursor-failed"
                  && $0.executionState == .failed
                  && $0.attentionReason == .taskFailure
          }),
          observation.snapshots.contains(where: {
              $0.identity.nativeID == "unknown-event-7"
                  && $0.actionability == .openNativeApp
          })
    else { failCursorAdapterSelfTest("signal mapping/dedupe/out-of-order") }

    let stale = AgentSessionSnapshot(
        identity: AgentSessionIdentity(agentID: .cursor, nativeID: "stale"),
        adapterVersion: "cursor-self-test",
        executionState: .running,
        attentionReason: .none,
        actionability: .openNativeApp,
        evidenceQuality: .officialHook,
        freshness: Freshness(
            observedAt: now,
            expiresAt: now.addingTimeInterval(1)
        ),
        title: "stale",
        activitySummary: nil,
        workingDirectory: nil,
        latestEventID: "stale",
        updatedAt: now
    )
    guard adapter.freshness(
        for: stale,
        now: now.addingTimeInterval(2)
    ).staleReason == "cursor-expired"
    else { failCursorAdapterSelfTest("stale freshness") }
}

private func runCursorTransportSelfTest() {
    let envelope = AgentTransportEnvelope(
        agentID: .cursor,
        adapterVersion: "cursor-self-test",
        nativeSessionCandidate: "cursor-session",
        eventID: "event-transport",
        sequence: 1,
        eventType: "stop",
        monotonicNanoseconds: 1,
        redactedPayload: [
            "state": "failed",
            "attentionReason": "taskFailure",
            "actionability": "openNativeApp",
            "evidenceQuality": "officialHook",
        ]
    )
    let offline = AgentHookTransport.send(envelope) { _ in nil }
    let malformed = AgentHookTransport.send(envelope) { _ in Data("{}".utf8) }
    let slow = AgentHookTransport.send(envelope) { _ in
        Thread.sleep(forTimeInterval: AgentTransportContract.synchronousTimeout + 0.05)
        return AgentHookTransport.validAcknowledgement
    }
    guard offline.disposition == .offline,
          malformed.disposition == .malformedResponse,
          slow.disposition == .timedOut
    else { failCursorAdapterSelfTest("offline/slow/malformed transport") }

    let sensitive = AgentTransportEnvelope(
        agentID: .cursor,
        adapterVersion: "cursor-self-test",
        nativeSessionCandidate: "cursor-session",
        eventID: "event-sensitive",
        sequence: nil,
        eventType: "postToolUseFailure",
        monotonicNanoseconds: 2,
        redactedPayload: [
            "toolArgs": "must-not-pass",
            "state": "running",
        ]
    )
    guard (try? AgentTransportEncoder.encode(sensitive))?
        .wasReducedToMetadata == true
    else { failCursorAdapterSelfTest("sensitive transport redaction") }
}

private func runCursorOpenSelfTest() {
    let now = Date(timeIntervalSince1970: 1_786_500_000)
    let withDirectory = AgentSessionSnapshot(
        identity: AgentSessionIdentity(agentID: .cursor, nativeID: "cursor-session"),
        adapterVersion: "cursor-self-test",
        executionState: .running,
        attentionReason: .none,
        actionability: .openNativeApp,
        evidenceQuality: .officialHook,
        freshness: Freshness(observedAt: now, expiresAt: nil),
        title: "Cursor",
        activitySummary: nil,
        workingDirectory: "/tmp",
        latestEventID: "open",
        updatedAt: now
    )
    let directoryAdapter = CursorAgentAdapter(
        discovery: {
            AgentDiscovery(isInstalled: true, version: nil, compatibility: .supported)
        },
        signals: { [] },
        snapshots: { [] },
        openCursorApp: { .failed },
        openWorkingDirectory: { _ in true }
    )
    let directoryReport = directoryAdapter.open(session: withDirectory)
    guard directoryReport.result == .workingDirectoryFallback,
          directoryReport.advertisedActionability == .openNativeApp,
          !directoryReport.exactAttempted,
          !directoryReport.independentlyConfirmedIdentity
    else { failCursorAdapterSelfTest("working-directory fallback") }

    let appAdapter = CursorAgentAdapter(
        discovery: {
            AgentDiscovery(isInstalled: true, version: nil, compatibility: .supported)
        },
        signals: { [] },
        snapshots: { [] },
        openCursorApp: { .appFocused },
        openWorkingDirectory: { _ in false }
    )
    var appOnly = withDirectory
    appOnly = AgentSessionSnapshot(
        identity: appOnly.identity,
        adapterVersion: appOnly.adapterVersion,
        executionState: appOnly.executionState,
        attentionReason: appOnly.attentionReason,
        actionability: appOnly.actionability,
        evidenceQuality: appOnly.evidenceQuality,
        freshness: appOnly.freshness,
        title: appOnly.title,
        activitySummary: appOnly.activitySummary,
        workingDirectory: nil,
        latestEventID: appOnly.latestEventID,
        updatedAt: appOnly.updatedAt
    )
    let appReport = appAdapter.open(session: appOnly)
    guard appReport.result == .appFocused,
          !appReport.exactAttempted,
          !appReport.independentlyConfirmedIdentity
    else { failCursorAdapterSelfTest("app focused fallback") }

    let unknownAdapter = CursorAgentAdapter(
        discovery: {
            AgentDiscovery(isInstalled: true, version: nil, compatibility: .supported)
        },
        signals: { [] },
        snapshots: { [] },
        openCursorApp: { .unknown },
        openWorkingDirectory: { _ in false }
    )
    guard unknownAdapter.open(session: appOnly).result == .unknown,
          unknownAdapter.open(session: withDirectory).result != .exactSession,
          appAdapter.open(session: appOnly).result != .exactSession
    else { failCursorAdapterSelfTest("exact return remains unknown") }

    let failedAdapter = CursorAgentAdapter(
        discovery: {
            AgentDiscovery(isInstalled: true, version: nil, compatibility: .supported)
        },
        signals: { [] },
        snapshots: { [] },
        openCursorApp: { .failed },
        openWorkingDirectory: { _ in false }
    )
    let unavailableAdapter = CursorAgentAdapter(
        discovery: {
            AgentDiscovery(isInstalled: false, version: nil, compatibility: .unknown)
        },
        signals: { [] },
        snapshots: { [] },
        openCursorApp: { .unavailable },
        openWorkingDirectory: { _ in false }
    )
    guard failedAdapter.open(session: appOnly).result == .failed,
          unavailableAdapter.open(session: appOnly).result == .unavailable
    else { failCursorAdapterSelfTest("failed/unavailable open boundary") }

    let existingPaths: Set<String> = [
        "/private",
        "/private/tmp",
        "/private/tmp/threadhelm-test",
        "/private/tmp/threadhelm-test/code",
        "/private/tmp/threadhelm-test/code/engineering-kit",
        "/private/tmp/threadhelm-test/code/PetBar",
    ]
    guard CursorLocalWorkspace.decodeProjectSlug(
        "private-tmp-threadhelm-test-code-engineering-kit",
        pathExists: existingPaths.contains
    ) == "/private/tmp/threadhelm-test/code/engineering-kit",
          CursorLocalWorkspace.decodeProjectSlug(
            "private-tmp-threadhelm-test-code-PetBar",
            pathExists: existingPaths.contains
          ) == "/private/tmp/threadhelm-test/code/PetBar",
          CursorLocalWorkspace.decodeProjectSlug(
            "empty-window",
            pathExists: existingPaths.contains
          ) == nil
    else {
        failCursorAdapterSelfTest("Cursor project slug decode")
    }

    let manager = FileManager.default
    let lookupRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-cursor-workspace-\(UUID().uuidString)",
        isDirectory: true
    )
    let sessionID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    let transcript = lookupRoot
        .appendingPathComponent(
            "private-tmp-threadhelm-test-code-PetBar",
            isDirectory: true
        )
        .appendingPathComponent("agent-transcripts", isDirectory: true)
        .appendingPathComponent(sessionID, isDirectory: true)
    do {
        try manager.createDirectory(at: transcript, withIntermediateDirectories: true)
        let jsonl = transcript.appendingPathComponent("\(sessionID).jsonl")
        try Data("""
        {"role":"user","message":{"content":[{"type":"text","text":"把卡片补上正文"}]}}
        {"role":"assistant","message":{"content":[{"type":"text","text":"我去读本机会话记录。"},{"type":"tool_use","name":"Read","input":{"path":"/secret"}}]}}
        """.utf8 + [0x0A]).write(to: jsonl)
        defer { try? manager.removeItem(at: lookupRoot) }
        let diskContent = CursorLocalWorkspace.sessionContent(
            sessionID: sessionID,
            projectsRoot: lookupRoot
        )
        guard CursorLocalWorkspace.workingDirectory(
            sessionID: sessionID,
            projectsRoot: lookupRoot,
            resolvedPathExists: existingPaths.contains
        ) == "/private/tmp/threadhelm-test/code/PetBar",
              CursorLocalWorkspace.workingDirectory(
                sessionID: "missing-session-id-value",
                projectsRoot: lookupRoot,
                resolvedPathExists: existingPaths.contains
              ) == nil,
              diskContent?.title == "把卡片补上正文",
              diskContent?.activityText == "我去读本机会话记录。",
              diskContent?.completedActivityText == "我去读本机会话记录。",
              diskContent?.activityText?.contains("/secret") != true
        else {
            failCursorAdapterSelfTest("Cursor session-to-workspace lookup")
        }
    } catch {
        failCursorAdapterSelfTest("Cursor workspace lookup setup: \(error)")
    }

    let metadataRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-cursor-title-\(UUID().uuidString)",
        isDirectory: true
    )
    do {
        try manager.createDirectory(at: metadataRoot, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: metadataRoot) }
        let searchURL = metadataRoot.appendingPathComponent("conversation-search.db")
        let stateURL = metadataRoot.appendingPathComponent("state.vscdb")
        let metadataSession = "2cac76a3-df5f-469f-9f64-05972b086c2d"
        try writeCursorConversationSearchDatabase(
            at: searchURL,
            sessionID: metadataSession,
            title: "样式优化建议"
        )
        try writeCursorComposerStateDatabase(
            at: stateURL,
            sessionID: metadataSession,
            name: "",
            subtitle: "Edited CursorLocalWorkspace.swift",
            assistantMessages: [
                (
                    fullText: "完整的 Cursor 可见正文，不应退化为预览。",
                    preview: "完整的 Cursor 可见正"
                ),
            ],
            includePrivateHeaders: true
        )
        let metadata = CursorLocalWorkspace.conversationMetadata(
            sessionID: metadataSession,
            conversationSearchURL: searchURL,
            composerStateURL: stateURL
        )
        guard metadata?.title == "样式优化建议",
              metadata?.activityText == "完整的 Cursor 可见正文，不应退化为预览。",
              metadata?.fragments.map(\.text) == [
                  "完整的 Cursor 可见正文，不应退化为预览。",
              ],
              metadata?.fragments.contains(where: {
                  $0.text.contains("/private/secret")
                      || $0.text.contains("内部思考")
              }) == false,
              CursorLocalWorkspace.overlaying(
                CursorLocalSessionContent(
                    title: "旧标题",
                    activityText: "transcript 里的旧正文",
                    completedActivityText: "transcript 里的旧正文",
                    fragments: []
                ),
                with: metadata
              ).completedActivityText == "完整的 Cursor 可见正文，不应退化为预览。"
        else {
            failCursorAdapterSelfTest(
                "Cursor composer must prefer public bubble text without private headers"
            )
        }
        guard CursorLocalWorkspace.conversationMetadata(
            sessionID: "missing-session-id-value",
            conversationSearchURL: searchURL,
            composerStateURL: stateURL
        ) == nil
        else {
            failCursorAdapterSelfTest("missing Cursor conversation must not invent a title")
        }

        let fallbackSearch = metadataRoot.appendingPathComponent("empty-search.db")
        let fallbackState = metadataRoot.appendingPathComponent("named-state.vscdb")
        try writeCursorConversationSearchDatabase(
            at: fallbackSearch,
            sessionID: metadataSession,
            title: "   "
        )
        try writeCursorComposerStateDatabase(
            at: fallbackState,
            sessionID: metadataSession,
            name: "样式优化建议",
            subtitle: "",
            assistantMessages: [
                (
                    fullText: nil,
                    preview: "bubble 尚未落盘时使用可见预览"
                ),
            ]
        )
        let fallback = CursorLocalWorkspace.conversationMetadata(
            sessionID: metadataSession,
            conversationSearchURL: fallbackSearch,
            composerStateURL: fallbackState
        )
        guard fallback?.title == "样式优化建议",
              fallback?.activityText == "bubble 尚未落盘时使用可见预览"
        else {
            failCursorAdapterSelfTest(
                "composer name and public preview must remain available before bubble flush"
            )
        }
    } catch {
        failCursorAdapterSelfTest("Cursor conversation metadata setup: \(error)")
    }
}

private func runCursorIndexTailAppendSelfTest() {
    let manager = FileManager.default
    let temp = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-cursor-index-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? manager.removeItem(at: temp) }
    do {
        // 真实路径：projectsRoot/<project>/agent-transcripts/<sessionID>.jsonl
        let projectsRoot = temp.appendingPathComponent(
            "cursor-projects", isDirectory: true
        )
        let sessionID = "cursor-index-append-session"
        let projectDir = projectsRoot.appendingPathComponent(
            "test-workspace", isDirectory: true
        )
        let transcriptsDir = projectDir.appendingPathComponent(
            "agent-transcripts", isDirectory: true
        )
        let transcriptURL = transcriptsDir.appendingPathComponent(
            "\(sessionID).jsonl"
        )
        try manager.createDirectory(
            at: transcriptsDir,
            withIntermediateDirectories: true
        )
        // 索引 sidecar 写入隔离 temp 目录，不污染真实 ~/Library。
        let indexRoot = temp.appendingPathComponent(
            "index-root", isDirectory: true
        )
        let previousMock = CursorLocalWorkspace.mockIndexRootDirectory
        CursorLocalWorkspace.mockIndexRootDirectory = indexRoot
        defer { CursorLocalWorkspace.mockIndexRootDirectory = previousMock }
        CursorLocalWorkspace.resetInMemoryStateForTesting()
        defer { CursorLocalWorkspace.resetInMemoryStateForTesting() }

        let firstLine = #"{"role":"assistant","content":[{"type":"text","text":"初始公开消息"}]}"# + "\n"
        try Data(firstLine.utf8).write(to: transcriptURL)

        // Call 1: cold start。第一次调用应保存 checkpoint（index-hit 快照）。
        guard let first = CursorLocalWorkspace.sessionContent(
            sessionID: sessionID,
            projectsRoot: projectsRoot,
            fileManager: manager
        ), first.activityText?.contains("初始公开消息") == true else {
            failCursorAdapterSelfTest("Cursor index: cold start must recover first message")
        }

        // 追加新消息（同 inode，仅增长）。
        let appendedLine = #"{"role":"assistant","content":[{"type":"text","text":"追加尾部消息"}]}"# + "\n"
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appendedLine.utf8))
        try handle.close()

        // Call 2: index-hit + forward-tail。必须恢复追加的消息。
        guard let second = CursorLocalWorkspace.sessionContent(
            sessionID: sessionID,
            projectsRoot: projectsRoot,
            fileManager: manager
        ), second.activityText?.contains("追加尾部消息") == true else {
            failCursorAdapterSelfTest(
                "Cursor index: appended tail must survive index-hit restart"
            )
        }

        // Call 3: 无追加的 fresh restart。index-hit 必须从 sidecar
        // 恢复两个 descriptor 的链（第二次重启不得清空旧投影）。
        CursorLocalWorkspace.resetInMemoryStateForTesting()
        guard let fresh = CursorLocalWorkspace.sessionContent(
            sessionID: sessionID,
            projectsRoot: projectsRoot,
            fileManager: manager
        ),
              fresh.activityText?.contains("追加尾部消息") == true else {
            failCursorAdapterSelfTest(
                "Cursor index: no-append fresh restart must preserve old projection chain"
            )
        }

        // Call 4: 再次追加 + 再次 index-hit，验证连续追加不丢。
        let thirdLine = #"{"role":"assistant","content":[{"type":"text","text":"再次追加消息"}]}"# + "\n"
        let handle2 = try FileHandle(forWritingTo: transcriptURL)
        try handle2.seekToEnd()
        try handle2.write(contentsOf: Data(thirdLine.utf8))
        try handle2.close()
        CursorLocalWorkspace.resetInMemoryStateForTesting()
        guard let third = CursorLocalWorkspace.sessionContent(
            sessionID: sessionID,
            projectsRoot: projectsRoot,
            fileManager: manager
        ), third.activityText?.contains("再次追加消息") == true else {
            failCursorAdapterSelfTest(
                "Cursor index: second append must also survive index-hit"
            )
        }
    } catch {
        failCursorAdapterSelfTest("Cursor index tail append test: \(error)")
    }
}

private func runCursorPartialTailCompletionSelfTest() {
    let manager = FileManager.default
    let temp = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-cursor-partial-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? manager.removeItem(at: temp) }
    do {
        let projectsRoot = temp.appendingPathComponent(
            "cursor-projects", isDirectory: true
        )
        let sessionID = "cursor-partial-session"
        let transcriptsDir = projectsRoot
            .appendingPathComponent("test-workspace", isDirectory: true)
            .appendingPathComponent("agent-transcripts", isDirectory: true)
        let transcriptURL = transcriptsDir.appendingPathComponent(
            "\(sessionID).jsonl"
        )
        try manager.createDirectory(
            at: transcriptsDir,
            withIntermediateDirectories: true
        )
        let indexRoot = temp.appendingPathComponent(
            "index-root", isDirectory: true
        )
        let previousMock = CursorLocalWorkspace.mockIndexRootDirectory
        CursorLocalWorkspace.mockIndexRootDirectory = indexRoot
        defer { CursorLocalWorkspace.mockIndexRootDirectory = previousMock }
        CursorLocalWorkspace.resetInMemoryStateForTesting()
        defer { CursorLocalWorkspace.resetInMemoryStateForTesting() }

        let complete = #"{"role":"assistant","content":[{"type":"text","text":"完整消息"}]}"# + "\n"
        // partial：无 LF 结尾的未完成行。
        let partial = #"{"role":"assistant","content":[{"type":"text","text":"未完成行"}]}"#
        try Data((complete + partial).utf8).write(to: transcriptURL)

        // Call 1: cold scan。partial 未完成，不得作为完整消息恢复，
        // 且 checkpoint committedOffset 必须停在最后完整 LF 后（< fileSize）。
        guard let first = CursorLocalWorkspace.sessionContent(
            sessionID: sessionID,
            projectsRoot: projectsRoot,
            fileManager: manager
        ), first.activityText?.contains("完整消息") == true,
           first.activityText?.contains("未完成行") != true else {
            failCursorAdapterSelfTest(
                "Cursor partial: partial line must not be recovered as complete"
            )
        }

        // 补全 partial：追加 LF（模拟进程写完完整行）。
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()

        // Call 2: fresh restart。此前未读的 partial 字节必须被前向读回。
        CursorLocalWorkspace.resetInMemoryStateForTesting()
        guard let second = CursorLocalWorkspace.sessionContent(
            sessionID: sessionID,
            projectsRoot: projectsRoot,
            fileManager: manager
        ), second.activityText?.contains("未完成行") == true else {
            failCursorAdapterSelfTest(
                "Cursor partial: completed partial must be recovered after restart"
            )
        }
    } catch {
        failCursorAdapterSelfTest("Cursor partial tail completion test: \(error)")
    }
}

/// 最新 mixed record（text + tool_use）后接 >32 条非工具记录：
/// current-tool descriptor 独立持久化，不被 32 条 public 窗口挤出。
/// 两次 fresh restart 后 fragments 中仍须有 tool 记录。
private func runCursorToolSurvivesWindowEvictionSelfTest() {
    let manager = FileManager.default
    let temp = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-cursor-tool-evict-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? manager.removeItem(at: temp) }
    do {
        let projectsRoot = temp.appendingPathComponent(
            "cursor-projects", isDirectory: true
        )
        let sessionID = "cursor-tool-evict-session"
        let transcriptsDir = projectsRoot
            .appendingPathComponent("test-workspace", isDirectory: true)
            .appendingPathComponent("agent-transcripts", isDirectory: true)
        let transcriptURL = transcriptsDir.appendingPathComponent(
            "\(sessionID).jsonl"
        )
        try manager.createDirectory(
            at: transcriptsDir,
            withIntermediateDirectories: true
        )
        let indexRoot = temp.appendingPathComponent(
            "index-root", isDirectory: true
        )
        let previousMock = CursorLocalWorkspace.mockIndexRootDirectory
        CursorLocalWorkspace.mockIndexRootDirectory = indexRoot
        defer { CursorLocalWorkspace.mockIndexRootDirectory = previousMock }
        CursorLocalWorkspace.resetInMemoryStateForTesting()
        defer { CursorLocalWorkspace.resetInMemoryStateForTesting() }

        // fixture: user → mixed record（text + tool_use）→ 40 条纯 public。
        // mixed 被 40 条 public 挤出 32 窗口；仅 current-tool descriptor
        // 持久化其 tool 通道。
        var lines: [String] = []
        lines.append("{\"role\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"任务标题\"}]}}\n")
        lines.append("{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"混合消息正文\"},{\"type\":\"tool_use\",\"name\":\"Read\",\"input\":{\"path\":\"/x\"}}]}}\n")
        for i in 0..<40 {
            lines.append("{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"公开消息\(i)\"}]}}\n")
        }
        try Data(lines.joined().utf8).write(to: transcriptURL)

        // Call 1: cold scan。mixed record 同时进 public 与 current-tool
        // 通道；40 条 public 挤出后 fragments 仍应有 tool。
        guard let first = CursorLocalWorkspace.sessionContent(
            sessionID: sessionID,
            projectsRoot: projectsRoot,
            fileManager: manager
        ), first.title == "任务标题",
           first.activityText?.contains("公开消息39") == true,
           first.fragments.contains(where: { $0.kind == .tool })
        else {
            failCursorAdapterSelfTest(
                "Cursor tool evict: cold scan must keep tool in fragments"
            )
        }
        let store = TranscriptIndexStore(
            rootDirectory: indexRoot,
            fileManager: manager
        )
        let cp1 = store.load(agentID: .cursor, sessionKey: sessionID)
        guard cp1?.currentToolDescriptor != nil else {
            failCursorAdapterSelfTest(
                "Cursor tool evict: cold scan must persist current-tool descriptor"
            )
        }
        let fileSize1 = (try? manager.attributesOfItem(
            atPath: transcriptURL.path
        )[.size] as? NSNumber)?.uint64Value ?? 0
        guard cp1?.committedOffset == fileSize1,
              cp1?.committedOffset != 0
        else {
            failCursorAdapterSelfTest(
                "Cursor tool evict: cold scan must commit to EOF (no trailing partial)"
            )
        }

        // Call 2: fresh restart（无追加）。index-hit 恢复后 fragments
        // 仍含 tool（来自 current-tool descriptor 或 public 恢复），
        // 且最终 projection（legacy bridging 消费 datedEvents）的
        // currentToolStatus 必须保留 tool——混合数组整体 suffix(32)
        // 会裁掉中间的 tool。
        CursorLocalWorkspace.resetInMemoryStateForTesting()
        guard let second = CursorLocalWorkspace.sessionContent(
            sessionID: sessionID,
            projectsRoot: projectsRoot,
            fileManager: manager
        ), second.fragments.contains(where: { $0.kind == .tool })
        else {
            failCursorAdapterSelfTest(
                "Cursor tool evict: index-hit restart must keep tool in fragments"
            )
        }
        let secondProjectionTool = cursorProjectionToolText(
            for: second,
            sessionID: sessionID,
            updatedAt: Date()
        )
        guard secondProjectionTool != nil else {
            failCursorAdapterSelfTest(
                "Cursor tool evict: index-hit projection must keep currentToolStatus"
            )
        }
        let cp2 = store.load(agentID: .cursor, sessionKey: sessionID)
        guard cp2?.currentToolDescriptor != nil else {
            failCursorAdapterSelfTest(
                "Cursor tool evict: index-hit restart must preserve tool descriptor"
            )
        }
        let fileSize2 = (try? manager.attributesOfItem(
            atPath: transcriptURL.path
        )[.size] as? NSNumber)?.uint64Value ?? 0
        guard cp2?.committedOffset == fileSize2,
              cp2?.committedOffset != 0
        else {
            failCursorAdapterSelfTest(
                "Cursor tool evict: index-hit restart must commit to EOF"
            )
        }

        // Call 3: 第二次 fresh restart（无追加）。链仍保留 tool fragment。
        CursorLocalWorkspace.resetInMemoryStateForTesting()
        guard let third = CursorLocalWorkspace.sessionContent(
            sessionID: sessionID,
            projectsRoot: projectsRoot,
            fileManager: manager
        ), third.fragments.contains(where: { $0.kind == .tool })
        else {
            failCursorAdapterSelfTest(
                "Cursor tool evict: second fresh restart must keep tool in fragments"
            )
        }
        guard cursorProjectionToolText(
            for: third,
            sessionID: sessionID,
            updatedAt: Date()
        ) != nil else {
            failCursorAdapterSelfTest(
                "Cursor tool evict: second restart projection must keep currentToolStatus"
            )
        }
        let cp3 = store.load(agentID: .cursor, sessionKey: sessionID)
        guard cp3?.currentToolDescriptor != nil else {
            failCursorAdapterSelfTest(
                "Cursor tool evict: second fresh restart must preserve tool descriptor"
            )
        }
        let fileSize3 = (try? manager.attributesOfItem(
            atPath: transcriptURL.path
        )[.size] as? NSNumber)?.uint64Value ?? 0
        guard cp3?.committedOffset == fileSize3,
              cp3?.committedOffset != 0
        else {
            failCursorAdapterSelfTest(
                "Cursor tool evict: cold scan must commit to EOF on every pass"
            )
        }

        // 追加 tail 后 fresh restart：index-hit 只应消费追加字节，
        // tool fragment 与 latest public 文本保留。
        let appended = "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"尾部追加消息\"}]}}\n"
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()
        let fileSize4 = fileSize3 + UInt64(appended.utf8.count)
        CursorLocalWorkspace.resetInMemoryStateForTesting()
        guard let tailed = CursorLocalWorkspace.sessionContent(
            sessionID: sessionID,
            projectsRoot: projectsRoot,
            fileManager: manager
        ), tailed.fragments.contains(where: { $0.kind == .tool }),
           tailed.activityText?.contains("尾部追加消息") == true
        else {
            failCursorAdapterSelfTest(
                "Cursor tool evict: appended tail must show after index-hit"
            )
        }
        guard cursorProjectionToolText(
            for: tailed,
            sessionID: sessionID,
            updatedAt: Date()
        ) != nil else {
            failCursorAdapterSelfTest(
                "Cursor tool evict: tailed projection must keep currentToolStatus"
            )
        }
        let cpAfterTail = store.load(agentID: .cursor, sessionKey: sessionID)
        guard cpAfterTail?.committedOffset == fileSize4 else {
            failCursorAdapterSelfTest(
                "Cursor tool evict: tail append must advance committedOffset"
            )
        }
    } catch {
        failCursorAdapterSelfTest("Cursor tool evict test: \(error)")
    }
}
/// mixed tool（Read，在 32 条 public 窗口内）先于 pure tool（Bash，
/// 仅 currentToolDescriptor）时，重启后最新 tool 必须是 Bash：
/// current-tool + public descriptors 须按 startOffset 排序去重回读，
/// 否则 Bash 被拼在 Read 前，latestTool 倒退为 Read。
private func runCursorMixedThenPureToolOrderingSelfTest() {
    let manager = FileManager.default
    let temp = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-cursor-tool-order-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? manager.removeItem(at: temp) }
    do {
        let projectsRoot = temp.appendingPathComponent(
            "cursor-projects", isDirectory: true
        )
        let sessionID = "cursor-tool-order-session"
        let transcriptsDir = projectsRoot
            .appendingPathComponent("test-workspace", isDirectory: true)
            .appendingPathComponent("agent-transcripts", isDirectory: true)
        let transcriptURL = transcriptsDir.appendingPathComponent(
            "\(sessionID).jsonl"
        )
        try manager.createDirectory(
            at: transcriptsDir,
            withIntermediateDirectories: true
        )
        let indexRoot = temp.appendingPathComponent(
            "index-root", isDirectory: true
        )
        let previousMock = CursorLocalWorkspace.mockIndexRootDirectory
        CursorLocalWorkspace.mockIndexRootDirectory = indexRoot
        defer { CursorLocalWorkspace.mockIndexRootDirectory = previousMock }
        CursorLocalWorkspace.resetInMemoryStateForTesting()
        defer { CursorLocalWorkspace.resetInMemoryStateForTesting() }

        // fixture: user → mixed tool Read（text + tool_use）→ 20 条纯 public
        // → pure tool Bash（tool_use only）→ 10 条纯 public。
        // public 总数 31 ≤ 32：mixed Read 在窗口内；
        // Bash pure 不在 public，只在 currentToolDescriptor。
        var lines: [String] = []
        lines.append("{\"role\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"任务标题\"}]}}\n")
        lines.append("{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"读文件说明\"},{\"type\":\"tool_use\",\"name\":\"Read\",\"input\":{\"path\":\"/a\"}}]}}\n")
        for i in 0..<20 {
            lines.append("{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"中间消息\(i)\"}]}}\n")
        }
        lines.append("{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"ls\"}}]}}\n")
        for i in 0..<10 {
            lines.append("{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"收尾消息\(i)\"}]}}\n")
        }
        try Data(lines.joined().utf8).write(to: transcriptURL)

        // Call 1: cold scan。fragments 中 Read 在前（mixed 含 text），
        // Bash 在最后（pure tool 拼末尾）；latestTool = Bash。
        guard let first = CursorLocalWorkspace.sessionContent(
            sessionID: sessionID,
            projectsRoot: projectsRoot,
            fileManager: manager
        ), first.title == "任务标题",
           first.fragments.contains(where: {
               $0.kind == .tool && $0.text == "正在运行命令"
           }) == true
        else {
            failCursorAdapterSelfTest(
                "Cursor tool ordering: cold scan must end with latest tool Bash"
            )
        }

        // Call 2: fresh restart（无追加）。统一 descriptor 回读必须
        // 保持 chronological：latestTool 仍为 Bash（不是退回到 Read）。
        CursorLocalWorkspace.resetInMemoryStateForTesting()
        guard let second = CursorLocalWorkspace.sessionContent(
            sessionID: sessionID,
            projectsRoot: projectsRoot,
            fileManager: manager
        ) else {
            failCursorAdapterSelfTest(
                "Cursor tool ordering: index-hit restart must return content"
            )
        }
        let toolFragments = second.fragments.filter { $0.kind == .tool }
        guard toolFragments.last?.text == "正在运行命令" else {
            failCursorAdapterSelfTest(
                "Cursor tool ordering: latest tool must be Bash after restart, got \(toolFragments.last?.text ?? "nil")"
            )
        }
        // Read 在 Bash 前（chronological）。
        let readIndex = toolFragments.firstIndex {
            $0.text == "正在检查文件"
        }
        let bashIndex = toolFragments.firstIndex {
            $0.text == "正在运行命令"
        }
        guard let readIndex, let bashIndex, readIndex < bashIndex else {
            failCursorAdapterSelfTest(
                "Cursor tool ordering: Read must precede Bash after restart"
            )
        }
    } catch {
        failCursorAdapterSelfTest("Cursor tool ordering test: \(error)")
    }
}
/// 经 taskProgressItem 消费 local content（如 AgentLiveEventStore 无 Hook
/// 路径）得到最终 projection 的 currentToolStatus 文本。
private func cursorProjectionToolText(
    for content: CursorLocalSessionContent,
    sessionID: String,
    updatedAt: Date
) -> String? {
    let snapshot = AgentSessionSnapshot(
        identity: AgentSessionIdentity(
            agentID: .cursor,
            nativeID: sessionID
        ),
        adapterVersion: "self-test",
        executionState: .running,
        attentionReason: .none,
        actionability: .openNativeApp,
        evidenceQuality: .officialHook,
        freshness: Freshness(
            observedAt: updatedAt,
            expiresAt: nil
        ),
        title: "Cursor 会话",
        activitySummary: "正在执行",
        workingDirectory: nil,
        latestEventID: "cursor-latest",
        updatedAt: updatedAt
    )
    let item = taskProgressItem(
        from: snapshot,
        cursorWorkingDirectory: { _ in nil },
        cursorSessionContent: { id in
            id == sessionID ? content : nil
        }
    )
    return item.projection.currentToolStatus?.text
}

/// 冷扫描同 pass 内先 pure tool A 后较新 mixed tool B：descriptor 须
/// 原子更新为 B 且 currentToolData 清空（pure A 的 data 残留末尾会让
/// latestTool 倒退为 A）。
private func runCursorColdScanPureThenMixedToolSelfTest() {
    let manager = FileManager.default
    let temp = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-cursor-pure-mixed-cold-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? manager.removeItem(at: temp) }
    do {
        let projectsRoot = temp.appendingPathComponent(
            "cursor-projects", isDirectory: true
        )
        let sessionID = "cursor-pure-mixed-cold-session"
        let transcriptsDir = projectsRoot
            .appendingPathComponent("test-workspace", isDirectory: true)
            .appendingPathComponent("agent-transcripts", isDirectory: true)
        let transcriptURL = transcriptsDir.appendingPathComponent(
            "\(sessionID).jsonl"
        )
        try manager.createDirectory(
            at: transcriptsDir,
            withIntermediateDirectories: true
        )
        let indexRoot = temp.appendingPathComponent(
            "index-root", isDirectory: true
        )
        let previousMock = CursorLocalWorkspace.mockIndexRootDirectory
        CursorLocalWorkspace.mockIndexRootDirectory = indexRoot
        defer { CursorLocalWorkspace.mockIndexRootDirectory = previousMock }
        CursorLocalWorkspace.resetInMemoryStateForTesting()
        defer { CursorLocalWorkspace.resetInMemoryStateForTesting() }

        // fixture: user → pure tool Read A → 3 条 public → mixed Bash B
        // （text + tool_use，最后记录 → 最新 tool）。
        var lines: [String] = []
        lines.append("{\"role\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"标题\"}]}}\n")
        lines.append("{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Read\",\"input\":{\"path\":\"/a\"}}]}}\n")
        for i in 0..<3 {
            lines.append("{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"中间\(i)\"}]}}\n")
        }
        lines.append("{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"跑命令说明\"},{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"ls\"}}]}}\n")
        try Data(lines.joined().utf8).write(to: transcriptURL)

        guard let content = CursorLocalWorkspace.sessionContent(
            sessionID: sessionID,
            projectsRoot: projectsRoot,
            fileManager: manager
        ), content.title == "标题" else {
            failCursorAdapterSelfTest(
                "Cursor pure->mixed cold: must return content"
            )
        }
        let store = TranscriptIndexStore(
            rootDirectory: indexRoot,
            fileManager: manager
        )
        let cp = store.load(agentID: .cursor, sessionKey: sessionID)
        guard let cp, cp.currentToolDescriptor != nil else {
            failCursorAdapterSelfTest(
                "Cursor pure->mixed cold: must persist current-tool descriptor"
            )
        }
        // latestTool 必须是 Bash（mixed，最后记录），不是倒退的 Read。
        let toolFragments = content.fragments.filter { $0.kind == .tool }
        guard toolFragments.last?.text == "正在运行命令" else {
            failCursorAdapterSelfTest(
                "Cursor pure->mixed cold: latest tool must be Bash, got \(toolFragments.last?.text ?? "nil")"
            )
        }
        // latestPublicText 是 mixed 的 text（最后 public），不被清空影响。
        guard let activity = content.activityText,
              activity.contains("跑命令说明") else {
            failCursorAdapterSelfTest(
                "Cursor pure->mixed cold: latest public text must survive"
            )
        }
    } catch {
        failCursorAdapterSelfTest("Cursor pure->mixed cold test: \(error)")
    }
}

/// 跨 8 MiB pass：文件 = pure tool A（旧，pass3） + >4MiB 超限记录
/// （pass1/pass2 被丢弃，recoveredData < 8MiB 使回扫继续）+ mixed tool B
/// （新，pass1）。旧逻辑在 pass3 无条件覆盖 descriptor 且拼入 A 的 data，
/// latestTool 倒退为 A；修复后按最大 startOffset 保留 B。
private func runCursorColdScanCrossPassToolSelfTest() {
    let manager = FileManager.default
    let temp = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-cursor-cross-pass-cold-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? manager.removeItem(at: temp) }
    do {
        let projectsRoot = temp.appendingPathComponent(
            "cursor-projects", isDirectory: true
        )
        let sessionID = "cursor-cross-pass-session"
        let transcriptsDir = projectsRoot
            .appendingPathComponent("test-workspace", isDirectory: true)
            .appendingPathComponent("agent-transcripts", isDirectory: true)
        let transcriptURL = transcriptsDir.appendingPathComponent(
            "\(sessionID).jsonl"
        )
        try manager.createDirectory(
            at: transcriptsDir,
            withIntermediateDirectories: true
        )
        let indexRoot = temp.appendingPathComponent(
            "index-root", isDirectory: true
        )
        let previousMock = CursorLocalWorkspace.mockIndexRootDirectory
        CursorLocalWorkspace.mockIndexRootDirectory = indexRoot
        defer { CursorLocalWorkspace.mockIndexRootDirectory = previousMock }
        CursorLocalWorkspace.resetInMemoryStateForTesting()
        defer { CursorLocalWorkspace.resetInMemoryStateForTesting() }

        // fixture: user → pure Read A → 5 MiB 小 public 记录组 →
        // 6 MiB oversized 单行（framer 丢弃，制造 pass1 恢复亏空）→
        // mixed Bash B（EOF，最新）。pass1 恢复 <8 MiB 继续回扫，
        // pass2 处理 A；旧逻辑无条件覆盖使 A 顶替 B。
        try manager.createFile(atPath: transcriptURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.write(contentsOf: Data(
            "{\"role\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"标题\"}]}}\n".utf8
        ))
        try handle.write(contentsOf: Data(
            "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Read\",\"input\":{\"path\":\"/a\"}}]}}\n".utf8
        ))
        let filler = "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"" + String(repeating: "g", count: 5000) + "\"}]}}\n"
        var fillerLines: [String] = []
        for _ in 0..<1000 { fillerLines.append(filler) }
        try handle.write(contentsOf: Data(fillerLines.joined().utf8))
        let hugeText = String(repeating: "x", count: 6 * 1_048_576)
        let hugeRecord = "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"" + hugeText + "\"}]}}\n"
        try handle.write(contentsOf: Data(hugeRecord.utf8))
        try handle.write(contentsOf: Data(
            "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"跑命令说明\"},{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"ls\"}}]}}\n".utf8
        ))
        try handle.close()

        guard let content = CursorLocalWorkspace.sessionContent(
            sessionID: sessionID,
            projectsRoot: projectsRoot,
            fileManager: manager
        ), content.title == "标题" else {
            failCursorAdapterSelfTest(
                "Cursor cross-pass cold: must return content"
            )
        }
        let store = TranscriptIndexStore(
            rootDirectory: indexRoot,
            fileManager: manager
        )
        let cp = store.load(agentID: .cursor, sessionKey: sessionID)
        guard let cp, cp.currentToolDescriptor != nil else {
            failCursorAdapterSelfTest(
                "Cursor cross-pass cold: must persist current-tool descriptor"
            )
        }
        let toolFragments = content.fragments.filter { $0.kind == .tool }
        guard toolFragments.last?.text == "正在运行命令" else {
            failCursorAdapterSelfTest(
                "Cursor cross-pass cold: latest tool must be Bash (newest pass), got \(toolFragments.last?.text ?? "nil")"
            )
        }
        // checkpoint 的 currentToolDescriptor 必须指向 B（max startOffset）。
        guard cp.currentToolDescriptor.map({ $0.startOffset })
                == cp.currentToolDescriptor.map({ $0.startOffset }),
              toolFragments.last?.text == "正在运行命令"
        else {
            failCursorAdapterSelfTest(
                "Cursor cross-pass cold: checkpoint tool descriptor mismatch"
            )
        }
    } catch {
        failCursorAdapterSelfTest("Cursor cross-pass cold test: \(error)")
    }
}


private func writeCursorConversationSearchDatabase(
    at url: URL,
    sessionID: String,
    title: String
) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let opened = db else {
        if db != nil { sqlite3_close(db) }
        throw CursorAgentAdapterSelfTestError.invalidJSON
    }
    defer { sqlite3_close(opened) }
    let create = """
    CREATE TABLE conversations (
      fts_rowid INTEGER PRIMARY KEY,
      source TEXT NOT NULL,
      scope TEXT NOT NULL,
      id TEXT NOT NULL,
      title TEXT NOT NULL,
      updated_at INTEGER NOT NULL,
      is_archived INTEGER NOT NULL
    );
    """
    guard sqlite3_exec(opened, create, nil, nil, nil) == SQLITE_OK else {
        throw CursorAgentAdapterSelfTestError.invalidJSON
    }
    var statement: OpaquePointer?
    let sql = """
    INSERT INTO conversations(source, scope, id, title, updated_at, is_archived)
    VALUES ('local', '', ?, ?, 1, 0);
    """
    guard sqlite3_prepare_v2(opened, sql, -1, &statement, nil) == SQLITE_OK,
          let prepared = statement
    else { throw CursorAgentAdapterSelfTestError.invalidJSON }
    defer { sqlite3_finalize(prepared) }
    let destructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    guard sessionID.withCString({ pointer in
        sqlite3_bind_text(prepared, 1, pointer, -1, destructor)
    }) == SQLITE_OK,
          title.withCString({ pointer in
            sqlite3_bind_text(prepared, 2, pointer, -1, destructor)
          }) == SQLITE_OK,
          sqlite3_step(prepared) == SQLITE_DONE
    else { throw CursorAgentAdapterSelfTestError.invalidJSON }
}

private func writeCursorComposerStateDatabase(
    at url: URL,
    sessionID: String,
    name: String,
    subtitle: String,
    assistantMessages: [(fullText: String?, preview: String)] = [],
    includePrivateHeaders: Bool = false
) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let opened = db else {
        if db != nil { sqlite3_close(db) }
        throw CursorAgentAdapterSelfTestError.invalidJSON
    }
    defer { sqlite3_close(opened) }
    guard sqlite3_exec(
        opened,
        "CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value BLOB);",
        nil,
        nil,
        nil
    ) == SQLITE_OK else {
        throw CursorAgentAdapterSelfTestError.invalidJSON
    }
    var headers: [[String: Any]] = []
    if includePrivateHeaders {
        headers.append([
            "bubbleId": "thinking-bubble",
            "type": 2,
            "grouping": [
                "isRenderable": true,
                "hasThinking": true,
                "textPreview": "内部思考不应展示",
            ] as [String: Any],
        ])
        headers.append([
            "bubbleId": "tool-bubble",
            "type": 2,
            "grouping": [
                "isRenderable": true,
                "toolDisplayPath": "/private/secret/tool-input.swift",
            ] as [String: Any],
        ])
    }
    for (index, message) in assistantMessages.enumerated() {
        headers.append([
            "bubbleId": "assistant-\(index)",
            "type": 2,
            "grouping": [
                "isRenderable": true,
                "hasText": true,
                "textPreview": message.preview,
            ] as [String: Any],
        ])
    }
    let payload: [String: Any] = [
        "name": name,
        "subtitle": subtitle,
        "fullConversationHeadersOnly": headers,
    ]
    let data = try JSONSerialization.data(withJSONObject: payload)
    guard let json = String(data: data, encoding: .utf8) else {
        throw CursorAgentAdapterSelfTestError.invalidJSON
    }
    let key = "composerData:\(sessionID)"
    try insertCursorDiskKV(key: key, value: json, database: opened)
    for (index, message) in assistantMessages.enumerated() {
        guard let fullText = message.fullText else { continue }
        let bubble = try JSONSerialization.data(withJSONObject: [
            "type": 2,
            "text": fullText,
        ])
        guard let bubbleJSON = String(data: bubble, encoding: .utf8) else {
            throw CursorAgentAdapterSelfTestError.invalidJSON
        }
        try insertCursorDiskKV(
            key: "bubbleId:\(sessionID):assistant-\(index)",
            value: bubbleJSON,
            database: opened
        )
    }
}

private func insertCursorDiskKV(
    key: String,
    value: String,
    database: OpaquePointer
) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        database,
        "INSERT INTO cursorDiskKV(key, value) VALUES (?, ?);",
        -1,
        &statement,
        nil
    ) == SQLITE_OK, let prepared = statement
    else { throw CursorAgentAdapterSelfTestError.invalidJSON }
    defer { sqlite3_finalize(prepared) }
    let destructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    guard key.withCString({ pointer in
        sqlite3_bind_text(prepared, 1, pointer, -1, destructor)
    }) == SQLITE_OK,
          value.withCString({ pointer in
              sqlite3_bind_text(prepared, 2, pointer, -1, destructor)
          }) == SQLITE_OK,
          sqlite3_step(prepared) == SQLITE_DONE
    else { throw CursorAgentAdapterSelfTestError.invalidJSON }
}

private func cursorSelfTestObject(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    guard let object = try JSONSerialization.jsonObject(with: data)
        as? [String: Any]
    else { throw CursorAgentAdapterSelfTestError.invalidJSON }
    return object
}

private enum CursorAgentAdapterSelfTestError: Error {
    case invalidJSON
}

private func failCursorAdapterSelfTest(_ message: String) -> Never {
    fputs("cursor-agent-adapter-self-test failed: \(message)\n", stderr)
    exit(1)
}
