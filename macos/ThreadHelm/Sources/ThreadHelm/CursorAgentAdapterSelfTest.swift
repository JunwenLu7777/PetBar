//
//  CursorAgentAdapterSelfTest.swift
//  ThreadHelm
//
//  模块职责：Cursor adapter 自测。该函数只写临时目录，不读取或写入真实
//  ~/.cursor；后续由共享 self-test aggregator 接入。
//

import Foundation

func runCursorAgentAdapterSelfTest() {
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
