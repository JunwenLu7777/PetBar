//
//  AgentHookCommand.swift
//  ThreadHelm
//
//  模块职责：作为 Cursor、ZCode、OMP hook/extension 的快速 fail-open 入口，
//  只从 stdin 提取身份和状态分类，再送入 owner-only Unix socket。
//

import Darwin
import Foundation

enum AgentHookCommandContract {
    static let flag = "--agent-hook"
    static let inputReadLimit = 64 * 1_024
    static let adapterVersion = "threadhelm-hook-v1"
    // 观测 hook 只上报状态，绝不该拖住厂商。各家给的预算其实不小
    // （Cursor 默认 60 秒且可配，ZCode 默认 60 秒），但那是给审批用的；
    // 观测这条自己收紧到亚秒级，超时即放弃本次上报。
    static let synchronousBudget: TimeInterval = 0.75
    /// 观测 hook 在厂商配置里注册的超时，必须严格大于 synchronousBudget
    /// 加上进程启动。到点放弃是 hook 自己的事，厂商这道超时只是兜底；
    /// 注册值小于自身预算等于让厂商在 hook 自愿退出前把它杀掉，那次上报
    /// 就永久丢失，而且两边都不会报错。
    ///
    /// 本机 2026-08-22 的 8 次 UserPromptSubmit 全部失败，耗时 258–320ms，
    /// 正好压在当时注册的 250ms 上——温启动只要几毫秒，冷启动却要付
    /// 二进制换页和运行时初始化，250ms 连启动都盖不住。
    static let observationHookTimeoutMilliseconds = 2_000
}

enum AgentHookInput {
    case object([String: Any])
    case oversized(Int)
    case malformed
}

@discardableResult
func runAgentHookCommandIfRequested(
    arguments: [String] = CommandLine.arguments,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    resolveSocketURL: ([String: String]) -> URL = agentEventSocketURL,
    readInput: (TimeInterval) -> AgentHookInput = readStandardAgentHookInput,
    send: (AgentTransportEnvelope, URL, TimeInterval) -> AgentTransportAttempt = {
        AgentEventSocketClient.send($0, to: $1, timeout: $2)
    },
    persistUndelivered: (AgentTransportEnvelope) -> Void = {
        persistUndeliveredAgentHookEnvelope($0)
    }
) -> Bool {
    let startedAt = DispatchTime.now().uptimeNanoseconds
    guard let flagIndex = arguments.firstIndex(
        of: AgentHookCommandContract.flag
    ) else { return false }
    guard arguments.indices.contains(flagIndex + 2) else { return true }
    let agentID = AgentID(rawValue: arguments[flagIndex + 1])
    guard [.cursor, .zcode, .omp, .antigravity].contains(agentID) else {
        return true
    }
    let eventType = arguments[flagIndex + 2]
    guard let envelope = agentHookEnvelope(
        agentID: agentID,
        eventType: eventType,
        input: readInput(agentHookRemainingTime(startedAt: startedAt))
    ) else { return true }
    persistUndelivered(envelope)
    let remaining = agentHookRemainingTime(startedAt: startedAt)
    if remaining > 0 {
        _ = send(
            envelope,
            resolveSocketURL(environment),
            remaining
        )
    }
    return true
}

func readStandardAgentHookInput(
    timeout: TimeInterval = AgentTransportContract.synchronousTimeout
) -> AgentHookInput {
    readAgentHookInput(
        from: STDIN_FILENO,
        timeout: timeout
    )
}

private func readAgentHookInput(
    from descriptor: CInt,
    timeout: TimeInterval
) -> AgentHookInput {
    let originalFlags = fcntl(descriptor, F_GETFL)
    guard originalFlags >= 0,
          fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0
    else { return .malformed }
    defer { _ = fcntl(descriptor, F_SETFL, originalFlags) }

    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(
        max(0, timeout) * 1_000_000_000
    )
    let maximumBytes = AgentHookCommandContract.inputReadLimit + 1
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)

    while true {
        let remainingCapacity = maximumBytes - data.count
        guard remainingCapacity > 0 else {
            return .oversized(data.count)
        }
        let requestedCount = min(buffer.count, remainingCapacity)
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(descriptor, bytes.baseAddress, requestedCount)
        }
        if count > 0 {
            data.append(contentsOf: buffer.prefix(count))
            if data.count > AgentHookCommandContract.inputReadLimit {
                return .oversized(data.count)
            }
            if let object = agentHookJSONObject(from: data) {
                return .object(object)
            }
            continue
        }
        if count == 0 {
            return agentHookInput(from: data)
        }
        if errno == EINTR { continue }
        guard errno == EAGAIN || errno == EWOULDBLOCK else {
            return .malformed
        }

        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { return agentHookInput(from: data) }
        let remainingMilliseconds = Int32(min(
            UInt64(Int32.max),
            max(1, (deadline - now + 999_999) / 1_000_000)
        ))
        var descriptorState = pollfd(
            fd: descriptor,
            events: Int16(POLLIN | POLLHUP),
            revents: 0
        )
        let pollResult = poll(&descriptorState, 1, remainingMilliseconds)
        if pollResult == 0 { return agentHookInput(from: data) }
        if pollResult < 0, errno != EINTR { return .malformed }
    }
}

private func agentHookInput(from data: Data) -> AgentHookInput {
    guard !data.isEmpty,
          let object = agentHookJSONObject(from: data)
    else { return .malformed }
    return .object(object)
}

private func agentHookJSONObject(from data: Data) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func agentHookRemainingTime(startedAt: UInt64) -> TimeInterval {
    let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - startedAt
    let elapsed = Double(elapsedNanoseconds) / 1_000_000_000
    return max(0, AgentHookCommandContract.synchronousBudget - elapsed)
}

func agentHookEnvelope(
    agentID: AgentID,
    eventType: String,
    input: AgentHookInput,
    monotonicNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
) -> AgentTransportEnvelope? {
    guard [.cursor, .zcode, .omp, .antigravity].contains(agentID),
          let safeEventType = agentHookToken(eventType, maximumLength: 96)
    else { return nil }

    switch input {
    case .malformed:
        return nil
    case .oversized(let byteCount):
        // 按会话精确跳转的两家在这条路径上都拿不到会话 ID——负载超限时
        // 我们只保留元数据，跳转落点无从谈起，只能降到仅查看。
        let nativeAction: Actionability = agentHookResumesExactSession(agentID)
            ? .viewOnly
            : .openNativeApp
        return AgentTransportEnvelope(
            agentID: agentID,
            adapterVersion: AgentHookCommandContract.adapterVersion,
            nativeSessionCandidate: nil,
            eventID: "oversized-\(monotonicNanoseconds)",
            sequence: nil,
            eventType: safeEventType,
            monotonicNanoseconds: monotonicNanoseconds,
            redactedPayload: [
                "state": ExecutionState.running.rawValue,
                "attentionReason": AttentionReason.none.rawValue,
                "actionability": nativeAction.rawValue,
                "evidenceQuality": EvidenceQuality.officialHook.rawValue,
                "freshness": "fresh",
                "payloadDisposition": "metadataOnly",
                "payloadSizeBucket": agentHookPayloadSizeBucket(byteCount),
            ]
        )
    case .object(let object):
        let mapping = agentHookStateMapping(
            agentID: agentID,
            eventType: safeEventType,
            object: object
        )
        guard let mapping else { return nil }
        let sessionID = agentHookFirstToken(
            in: object,
            keys: ["session_id", "sessionId", "conversation_id", "conversationId"],
            maximumLength: 192
        )
        let actionability = agentHookResumesExactSession(agentID)
            && sessionID == nil
            ? Actionability.viewOnly
            : mapping.actionability
        let eventID = agentHookFirstToken(
            in: object,
            keys: ["event_id", "eventId", "hook_event_id", "hookEventId"],
            maximumLength: 192
        ) ?? "\(agentID.rawValue)-\(safeEventType)-\(monotonicNanoseconds)"
        let sequence = agentHookFirstInteger(
            in: object,
            keys: ["sequence", "sequence_number", "sequenceNumber"]
        )
        return AgentTransportEnvelope(
            agentID: agentID,
            adapterVersion: AgentHookCommandContract.adapterVersion,
            nativeSessionCandidate: sessionID,
            eventID: eventID,
            sequence: sequence,
            eventType: safeEventType,
            monotonicNanoseconds: monotonicNanoseconds,
            redactedPayload: [
                "state": mapping.state.rawValue,
                "attentionReason": mapping.reason.rawValue,
                "actionability": actionability.rawValue,
                "evidenceQuality": mapping.evidence.rawValue,
                "freshness": mapping.freshness,
            ]
        )
    }
}

func agentEventSocketURL(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> URL {
    let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent("ThreadHelm", isDirectory: true)
        .appendingPathComponent("AgentEvents", isDirectory: true)
        .standardizedFileURL
    let defaultURL = directory.appendingPathComponent("events.sock")
    guard let override = environment["THREADHELM_AGENT_EVENT_SOCKET"],
          override.hasPrefix("/")
    else { return defaultURL }
    let candidate = URL(fileURLWithPath: override).standardizedFileURL
    guard candidate.deletingLastPathComponent() == directory,
          candidate.pathExtension == "sock"
    else { return defaultURL }
    return candidate
}

/// 这家的跳转是不是按会话 ID 精确恢复，而不是把应用带到前台。
///
/// OMP 走 resume，Antigravity 走 `agy --conversation <id>`——两者都需要
/// 事件里带上会话 ID 才谈得上落点，拿不到就得降级成仅查看。
private func agentHookResumesExactSession(_ agentID: AgentID) -> Bool {
    agentID == .omp || agentID == .antigravity
}

private func agentHookStateMapping(
    agentID: AgentID,
    eventType: String,
    object: [String: Any]
) -> (
    state: ExecutionState,
    reason: AttentionReason,
    actionability: Actionability,
    evidence: EvidenceQuality,
    freshness: String
)? {
    let normalized = eventType.lowercased()
    let taskFailed = agentHookTerminalFailureIsExplicit(object)
    let nativeAction: Actionability = agentHookResumesExactSession(agentID)
        ? .openExactNativeSession
        : .openNativeApp

    if agentID == .antigravity {
        // 共享的 config/hooks.json 会被 IDE 与 Antigravity 2.0 一并加载，
        // 它们的会话不归 ThreadHelm 管——事件进面板只会变成无法跳转的
        // 噪音，就地丢弃。oversized 负载走不到这里，无从判断产品，那条
        // 路径上的漏网按可容忍的边角处理。
        guard antigravityHookPayloadIsCLISession(object) else { return nil }
        switch normalized {
        case "pre_invocation", "post_invocation", "pre_tool_use",
             "post_tool_use":
            return (.running, .none, nativeAction, .officialHook, "fresh")
        case "stop":
            // agy 没有 session_start / session_end：一次 `agy -p` 就是一
            // 条会话的全部，Stop 是唯一的终态信号。fullyIdle 为假说明还
            // 有后台任务在跑，这时收不了尾，仍按运行中记。
            if let fullyIdle = object["fullyIdle"] as? Bool, !fullyIdle {
                return (.running, .none, nativeAction, .officialHook, "fresh")
            }
            return antigravityStopIsFailure(object)
                ? (.failed, .taskFailure, nativeAction, .officialHook, "fresh")
                : (.completed, .reviewReady, nativeAction, .officialHook, "fresh")
        default:
            return nil
        }
    }

    if agentID == .cursor {
        switch normalized {
        case "sessionstart":
            return (.idle, .none, nativeAction, .officialHook, "fresh")
        case "sessionend", "stop":
            return taskFailed
                ? (.failed, .taskFailure, nativeAction, .officialHook, "fresh")
                : (.completed, .reviewReady, nativeAction, .officialHook, "fresh")
        case "beforesubmitprompt", "pretooluse", "posttooluse",
             "posttoolusefailure", "subagentstart", "subagentstop":
            return (.running, .none, nativeAction, .officialHook, "fresh")
        default:
            return nil
        }
    }

    if agentID == .zcode {
        switch normalized {
        case "sessionstart":
            return (.idle, .none, nativeAction, .officialHook, "fresh")
        case "stop":
            return taskFailed
                ? (.failed, .taskFailure, nativeAction, .officialHook, "fresh")
                : (.completed, .reviewReady, nativeAction, .officialHook, "fresh")
        case "userpromptsubmit", "pretooluse", "posttooluse",
             "posttoolusefailure":
            return (.running, .none, nativeAction, .officialHook, "fresh")
        default:
            return nil
        }
    }

    switch normalized {
    case "session_start":
        return (.idle, .none, nativeAction, .officialHook, "fresh")
    case "agent_start", "tool_call", "tool_result", "session_compact":
        return (.running, .none, nativeAction, .officialHook, "fresh")
    case "agent_end":
        if agentHookContinuationIsExplicit(object) {
            return (.running, .none, nativeAction, .officialHook, "fresh")
        }
        return taskFailed
            ? (.failed, .taskFailure, nativeAction, .officialHook, "fresh")
            : (.completed, .reviewReady, nativeAction, .officialHook, "fresh")
    case "session_shutdown":
        return (.offline, .none, .viewOnly, .officialHook, "stale")
    default:
        return nil
    }
}

private func agentHookContinuationIsExplicit(
    _ object: [String: Any]
) -> Bool {
    let values = ["outcome", "result", "terminal_status", "terminalStatus"]
        .compactMap { object[$0] as? String }
        .map { $0.lowercased() }
    return values.contains("continuing")
}

/// agy 的 Stop 负载自成一套：失败写在 `error`（空串表示没出错）与
/// `terminationReason` 上，没有别家那个 outcome/terminal_status 字段。
///
/// 判据保持保守——只有明确说了出错才记失败。实测正常收尾时
/// terminationReason 是 "NO_TOOL_CALL"，把「不认识的收尾理由」一律当成
/// 失败会把绝大多数正常会话染红。
private func antigravityStopIsFailure(_ object: [String: Any]) -> Bool {
    if let error = object["error"] as? String,
       !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
        return true
    }
    let reason = (object["terminationReason"] as? String)?
        .lowercased()
        .filter { $0.isLetter }
    return reason == "error"
}

private func agentHookTerminalFailureIsExplicit(
    _ object: [String: Any]
) -> Bool {
    let values = ["outcome", "result", "terminal_status", "terminalStatus"]
        .compactMap { object[$0] as? String }
        .map { $0.lowercased() }
    return values.contains(where: {
        ["taskerror", "task_error", "taskfailure", "task_failure"].contains($0)
    })
}

private func agentHookFirstToken(
    in object: [String: Any],
    keys: [String],
    maximumLength: Int
) -> String? {
    for key in keys {
        if let value = object[key] as? String,
           let token = agentHookToken(value, maximumLength: maximumLength)
        {
            return token
        }
    }
    return nil
}

private func agentHookFirstInteger(
    in object: [String: Any],
    keys: [String]
) -> Int? {
    for key in keys {
        if let value = object[key] as? Int { return value }
        if let value = object[key] as? NSNumber { return value.intValue }
    }
    return nil
}

private func agentHookToken(
    _ value: String,
    maximumLength: Int
) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= maximumLength,
          trimmed.range(
              of: #"^[A-Za-z0-9][A-Za-z0-9._:-]*$"#,
              options: .regularExpression
          ) != nil
    else { return nil }
    return trimmed
}

private func agentHookPayloadSizeBucket(_ byteCount: Int) -> String {
    switch byteCount {
    case ..<(128 * 1_024): return "64-128KiB"
    case ..<(512 * 1_024): return "128-512KiB"
    default: return "512KiB+"
    }
}
