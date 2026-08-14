//
//  AgentHookCommandSelfTest.swift
//  ThreadHelm
//
//  模块职责：验证 hook CLI 只输出分类信息并在离线时快速放行。
//

import Darwin
import Foundation

func runAgentHookCommandSelfTest() {
    let arbitraryOverride = "/tmp/threadhelm-arbitrary-redirect.sock"
    guard agentEventSocketURL(environment: [
        "THREADHELM_AGENT_EVENT_SOCKET": arbitraryOverride,
    ]).path != arbitraryOverride else {
        failAgentHookCommandSelfTest("arbitrary socket override was accepted")
    }

    let raw: [String: Any] = [
        "session_id": "session-one",
        "event_id": "event-one",
        "sequence": 4,
        "outcome": "taskError",
        "prompt": "private prompt",
        "tool_args": ["secret": "value"],
        "tool_output": "private output",
        "cwd": "/private/project",
        "title": "private title",
    ]
    guard let zcode = agentHookEnvelope(
        agentID: .zcode,
        eventType: "Stop",
        input: .object(raw),
        monotonicNanoseconds: 42
    ), zcode.nativeSessionCandidate == "session-one",
       zcode.sequence == 4,
       zcode.redactedPayload["state"] == "failed",
       zcode.redactedPayload["attentionReason"] == "taskFailure",
       zcode.redactedPayload["actionability"] == "openNativeApp",
       let encoded = try? AgentTransportEncoder.encode(zcode).data,
       let encodedText = String(data: encoded, encoding: .utf8),
       !encodedText.contains("private prompt"),
       !encodedText.contains("private output"),
       !encodedText.contains("/private/project"),
       !encodedText.contains("private title"),
       !encodedText.contains("secret")
    else {
        failAgentHookCommandSelfTest("redaction/task failure mapping")
    }

    guard let cursorToolFailure = agentHookEnvelope(
        agentID: .cursor,
        eventType: "postToolUseFailure",
        input: .object(raw),
        monotonicNanoseconds: 43
    ), cursorToolFailure.redactedPayload["state"] == "running",
       cursorToolFailure.redactedPayload["attentionReason"] == "none"
    else {
        failAgentHookCommandSelfTest("ordinary Cursor tool failure")
    }

    guard let omp = agentHookEnvelope(
        agentID: .omp,
        eventType: "agent_end",
        input: .object(raw),
        monotonicNanoseconds: 44
    ), omp.redactedPayload["state"] == "failed",
       omp.redactedPayload["attentionReason"] == "taskFailure",
       omp.redactedPayload["actionability"] == "viewOnly"
    else {
        failAgentHookCommandSelfTest("OMP state-only mapping")
    }

    var continuing = raw
    continuing["outcome"] = "continuing"
    guard let intermediateOMP = agentHookEnvelope(
        agentID: .omp,
        eventType: "agent_end",
        input: .object(continuing),
        monotonicNanoseconds: 45
    ), intermediateOMP.redactedPayload["state"] == "running",
       intermediateOMP.redactedPayload["attentionReason"] == "none",
       agentHookEnvelope(
           agentID: .omp,
           eventType: "permission",
           input: .object(raw)
       ) == nil,
       agentHookEnvelope(
           agentID: .cursor,
           eventType: "stop",
           input: .malformed
       ) == nil
    else {
        failAgentHookCommandSelfTest("OMP intermediate/unsupported/malformed")
    }

    guard let oversized = agentHookEnvelope(
        agentID: .cursor,
        eventType: "stop",
        input: .oversized(AgentHookCommandContract.inputReadLimit + 1),
        monotonicNanoseconds: 46
    ), oversized.redactedPayload["payloadDisposition"] == "metadataOnly",
       oversized.redactedPayload["payloadSizeBucket"] == "64-128KiB",
       oversized.redactedPayload["state"] == "running"
    else {
        failAgentHookCommandSelfTest("oversized metadata-only")
    }

    var sent: AgentTransportEnvelope?
    let handled = runAgentHookCommandIfRequested(
        arguments: ["ThreadHelm", "--agent-hook", "cursor", "sessionStart"],
        environment: [
            "THREADHELM_AGENT_EVENT_SOCKET": "/tmp/threadhelm-self-test.sock",
        ],
        resolveSocketURL: { _ in
            URL(fileURLWithPath: "/tmp/threadhelm-self-test.sock")
        },
        readInput: { _ in
            .object([
                "session_id": "session-two",
                "event_id": "event-two",
            ])
        },
        send: { envelope, socketURL, timeout in
            sent = envelope
            guard socketURL.path == "/tmp/threadhelm-self-test.sock",
                  timeout > 0,
                  timeout <= AgentHookCommandContract.synchronousBudget
            else {
                failAgentHookCommandSelfTest("socket override")
            }
            return AgentTransportAttempt(
                disposition: .offline,
                vendorResponse: Data(),
                usedMetadataOnlyEnvelope: false
            )
        },
        persistUndelivered: { _ in }
    )
    guard handled,
          sent?.agentID == .cursor,
          sent?.nativeSessionCandidate == "session-two",
          runAgentHookCommandIfRequested(
              arguments: ["ThreadHelm", "--unrelated"],
              readInput: { _ in .malformed },
              send: { _, _, _ in
                  failAgentHookCommandSelfTest("unrelated command sent event")
              },
              persistUndelivered: { _ in
                  failAgentHookCommandSelfTest("unrelated command persisted")
              }
          ) == false
    else {
        failAgentHookCommandSelfTest("CLI dispatch/fail-open")
    }

    var inputBudget: TimeInterval = 0
    var sendBudget: TimeInterval = 0
    let sharedDeadlineHandled = runAgentHookCommandIfRequested(
        arguments: ["ThreadHelm", "--agent-hook", "cursor", "sessionStart"],
        readInput: { timeout in
            inputBudget = timeout
            usleep(120_000)
            return .object([
                "session_id": "session-budget",
                "event_id": "event-budget",
            ])
        },
        send: { _, _, timeout in
            sendBudget = timeout
            return AgentTransportAttempt(
                disposition: .offline,
                vendorResponse: Data(),
                usedMetadataOnlyEnvelope: false
            )
        },
        persistUndelivered: { _ in }
    )
    guard sharedDeadlineHandled,
          inputBudget > 0.15,
          inputBudget <= AgentHookCommandContract.synchronousBudget,
          sendBudget > 0,
          sendBudget < inputBudget - 0.08
    else {
        failAgentHookCommandSelfTest("stdin and socket must share one deadline")
    }

    runAgentHookInputDeadlineSelfTest()
    runAgentHookDropSelfTest()
}

private func runAgentHookInputDeadlineSelfTest() {
    var descriptors: [CInt] = [0, 0]
    guard pipe(&descriptors) == 0 else {
        failAgentHookCommandSelfTest("stdin deadline pipe")
    }
    let originalStandardInput = dup(STDIN_FILENO)
    guard originalStandardInput >= 0,
          dup2(descriptors[0], STDIN_FILENO) >= 0
    else {
        close(descriptors[0])
        close(descriptors[1])
        failAgentHookCommandSelfTest("stdin deadline setup")
    }
    close(descriptors[0])
    let writer = descriptors[1]
    let writerClosed = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.60) {
        close(writer)
        writerClosed.signal()
    }
    defer {
        _ = writerClosed.wait(timeout: .now() + 1.0)
        _ = dup2(originalStandardInput, STDIN_FILENO)
        close(originalStandardInput)
    }

    let started = DispatchTime.now().uptimeNanoseconds
    let input = readStandardAgentHookInput()
    let elapsed = Double(
        DispatchTime.now().uptimeNanoseconds - started
    ) / 1_000_000_000
    guard case .malformed = input,
          elapsed <= AgentTransportContract.synchronousTimeout + 0.05
    else {
        failAgentHookCommandSelfTest("stdin must fail open within 250ms")
    }
}

private func runAgentHookDropSelfTest() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "threadhelm-hook-drop-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? FileManager.default.removeItem(at: directory) }
    guard let envelope = agentHookEnvelope(
        agentID: .cursor,
        eventType: "beforeSubmitPrompt",
        input: .object([
            "session_id": "drop-session",
            "event_id": "drop-event",
        ]),
        monotonicNanoseconds: 99
    ) else {
        failAgentHookCommandSelfTest("drop envelope")
    }
    var persisted: AgentTransportEnvelope?
    let handled = runAgentHookCommandIfRequested(
        arguments: ["ThreadHelm", "--agent-hook", "cursor", "beforeSubmitPrompt"],
        readInput: { _ in
            .object([
                "session_id": "drop-session",
                "event_id": "drop-event",
            ])
        },
        send: { _, _, _ in
            AgentTransportAttempt(
                disposition: .delivered,
                vendorResponse: Data(),
                usedMetadataOnlyEnvelope: false
            )
        },
        persistUndelivered: { persisted = $0 }
    )
    guard handled,
          persisted?.eventID == "drop-event",
          persistUndeliveredAgentHookEnvelope(
              envelope,
              directory: directory
          ),
          let drained = drainAgentHookDropInbox(directory: directory).first,
          drained.eventID == envelope.eventID,
          drained.nativeSessionCandidate == "drop-session",
          drainAgentHookDropInbox(directory: directory).isEmpty
    else {
        failAgentHookCommandSelfTest("hook must persist a drop file even if the socket is delivered")
    }
}

private func failAgentHookCommandSelfTest(_ message: String) -> Never {
    fputs("agent hook command self-test failed: \(message)\n", stderr)
    exit(1)
}
