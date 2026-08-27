//
//  AgentPermissionHookCommand.swift
//  ThreadHelm
//
//  模块职责：Codex 与 ZCode 都只支持「执行一个命令」型的 hook，拿不到
//  Claude 那种直连 HTTP 的能力。ThreadHelm 二进制带对应旗标运行时就充当
//  这段转发：读 stdin 的 PermissionRequest，POST 给常驻面板，阻塞等用户
//  裁决，再把裁决原样写回 stdout。
//
//  两家的失败语义不同，转发层必须区别对待：
//
//  - Codex 收到空裁决会回落到它自己的原生批准 UI，所以「不给裁决」是安全的。
//  - ZCode 不会。它的 hook 一旦失败、超时或返回空，工具**直接执行**。所以
//    ZCode 这条线上任何故障都必须主动写出一份拒绝，否则闸门形同虚设。
//

import Foundation
import Security

enum AgentPermissionTokenFactory {
    static func make() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            == errSecSuccess
        {
            return Data(bytes).base64EncodedString()
        }
        return UUID().uuidString + UUID().uuidString
    }
}

/// 闸门无法给出裁决时该写什么。
enum AgentPermissionHookFallback: Equatable {
    /// 交还厂商自己的批准界面。仅当厂商确实有这么一个界面时才安全。
    case handBackToVendor(String)
    /// 主动拒绝。厂商在 hook 失败时会放行，只能由我们自己兜住。
    case denyWithReason(String)
}

struct AgentPermissionHookTransport {
    let agentID: AgentID
    let flag: String
    let url: String
    let resolveToken: () -> String?
    let fallback: AgentPermissionHookFallback
    /// 自我兜底的截止时间：宁可自己先拒绝，也不能让厂商把 hook 杀掉——
    /// 被杀一律是 fail-open。
    let deadline: TimeInterval
    /// 这次调用要不要真的去打扰用户。Cursor 的 preToolUse 每次工具调用
    /// 都触发，把只读操作也弹成确认框只会让用户对确认框脱敏。返回 nil
    /// 表示照常转发；返回一段输出表示就地放行，不惊动面板。
    var shortCircuit: (Data) -> String? = { _ in nil }

    var fallbackOutput: String {
        switch fallback {
        case .handBackToVendor(let text):
            return text
        case .denyWithReason(let reason):
            return AgentPermissionHookTransport.denyPayload(reason: reason)
        }
    }

    static func denyPayload(reason: String) -> String {
        let payload: [String: Any] = [
            "continue": false,
            "reason": reason,
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": "deny", "message": reason],
            ],
        ]
        // 键序必须稳定：这段输出会被逐字比对（自检、日志排查），
        // 字典的自然顺序每次都可能不同。
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        ),
        let text = String(data: data, encoding: .utf8)
        else {
            // 兜底的兜底。真走到这里说明序列化都坏了，仍然要拒绝。
            return #"{"continue":false,"reason":"ThreadHelm 无法给出裁决"}"#
        }
        return text
    }

    /// Cursor 侧的就地放行输出。permission 缺省即「这条 hook 无意见」，
    /// 由 Cursor 自己的权限流程照常处理。
    static let cursorPassThroughOutput = "{}"

    static func codex() -> AgentPermissionHookTransport {
        AgentPermissionHookTransport(
            agentID: .codex,
            flag: CodexHookConstants.hookCommandFlag,
            url: CodexHookConstants.url,
            resolveToken: { CodexHookConfiguration.authenticationToken() },
            fallback: .handBackToVendor(CodexHookConstants.noDecisionOutput),
            deadline: CodexHookConstants.requestTimeoutSeconds
        )
    }

    static func zcode() -> AgentPermissionHookTransport {
        AgentPermissionHookTransport(
            agentID: .zcode,
            flag: ZCodePermissionHookConstants.flag,
            url: ZCodePermissionHookConstants.url,
            resolveToken: { ZCodePermissionTokenStore.token() },
            fallback: .denyWithReason(
                "ThreadHelm 未能确认这次操作，已按拒绝处理。"
                    + "请在 ThreadHelm 中确认闸门在线后重试。"
            ),
            deadline: ZCodePermissionHookConstants.selfDenyDeadlineSeconds
        )
    }

    static func cursor() -> AgentPermissionHookTransport {
        AgentPermissionHookTransport(
            agentID: .cursor,
            flag: CursorPermissionHookConstants.flag,
            url: CursorPermissionHookConstants.url,
            resolveToken: { CursorPermissionTokenStore.token() },
            // Cursor 支持 ask：闸门够不着时把决定权交回它自己的权限流程，
            // 既不替用户放行，也不把他锁在工具外面。
            fallback: .handBackToVendor(
                #"{"permission":"ask"}"#
            ),
            deadline: CursorPermissionHookConstants.requestTimeoutSeconds,
            shortCircuit: { body in
                cursorToolNameIsGuarded(in: body)
                    ? nil
                    : cursorPassThroughOutput
            }
        )
    }

    static func all() -> [AgentPermissionHookTransport] {
        [.codex(), .zcode(), .cursor()]
    }
}

enum AgentPermissionHookOutcome: Equatable {
    /// 拿到裁决，原样写回厂商。
    case decision(Data)
    /// 没拿到裁决，按该厂商的兜底语义处理。
    case noDecision
}

@discardableResult
func runAgentPermissionHookCommandIfRequested(
    arguments: [String] = CommandLine.arguments,
    transports: [AgentPermissionHookTransport] = AgentPermissionHookTransport.all(),
    readInput: () -> Data? = { readAgentPermissionHookInput() },
    postDecision: (
        Data,
        String?,
        AgentPermissionHookTransport
    ) -> AgentPermissionHookOutcome = { body, token, transport in
        postAgentPermissionRequest(
            body: body,
            token: token,
            url: URL(string: transport.url),
            timeout: transport.deadline
        )
    },
    writeOutput: (String) -> Void = { text in
        FileHandle.standardOutput.write(Data(text.utf8))
    }
) -> Bool {
    guard let transport = transports.first(where: {
        arguments.contains($0.flag)
    }) else {
        return false
    }

    guard let body = readInput(), !body.isEmpty else {
        writeOutput(transport.fallbackOutput)
        return true
    }

    // 先看这次调用值不值得打扰用户。判断只依据 payload，不联网、不落盘，
    // 所以只读工具的开销就是一次进程启动加一次 JSON 解析。
    if let passThrough = transport.shortCircuit(body) {
        writeOutput(passThrough)
        return true
    }

    switch postDecision(body, transport.resolveToken(), transport) {
    case .decision(let data):
        let text = String(data: data, encoding: .utf8) ?? ""
        writeOutput(text.isEmpty ? transport.fallbackOutput : text)
    case .noDecision:
        writeOutput(transport.fallbackOutput)
    }
    return true
}

/// 一直读到 EOF。厂商写完 payload 就关 stdin，所以这里不需要另设读超时——
/// 真正的等待发生在 HTTP 那一段。
func readAgentPermissionHookInput(
    fileHandle: FileHandle = .standardInput,
    limit: Int = CodexHookConstants.maximumInputBytes
) -> Data? {
    var data = Data()
    while true {
        let chunk = fileHandle.availableData
        if chunk.isEmpty { break }
        data.append(chunk)
        // 超限直接放弃：截断后的 JSON 只会在服务端解析失败，与其发一份
        // 坏 payload，不如让调用方走兜底。
        if data.count > limit { return nil }
    }
    return data.isEmpty ? nil : data
}

func postAgentPermissionRequest(
    body: Data,
    token: String?,
    url: URL?,
    timeout: TimeInterval
) -> AgentPermissionHookOutcome {
    guard let url, let token, !token.isEmpty else { return .noDecision }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = body
    request.timeoutInterval = timeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(
        token,
        forHTTPHeaderField: ClaudeHookConstants.authenticationHeader
    )

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    configuration.waitsForConnectivity = false
    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }

    var outcome = AgentPermissionHookOutcome.noDecision
    let semaphore = DispatchSemaphore(value: 0)
    let task = session.dataTask(with: request) { data, response, _ in
        defer { semaphore.signal() }
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let data,
              !data.isEmpty
        else { return }
        outcome = .decision(data)
    }
    task.resume()
    // 比 URLSession 自身的超时多留一点余量，避免两个时钟同时到点时
    // 信号量先醒、回调后写 outcome 造成竞态。
    if semaphore.wait(timeout: .now() + timeout + 5) == .timedOut {
        task.cancel()
        return .noDecision
    }
    return outcome
}

/// 这次 preToolUse 涉及的工具要不要人来把关。
///
/// 解析失败一律按「需要把关」处理：读不懂的负载可能是新工具，也可能是
/// 我们没跟上的格式变化，那时多问一次远好过默认放行。
func cursorToolNameIsGuarded(
    in body: Data,
    guarded: Set<String> = CursorPermissionHookConstants.guardedToolNames
) -> Bool {
    guard let object = try? JSONSerialization.jsonObject(with: body),
          let payload = object as? [String: Any],
          let toolName = payload["tool_name"] as? String
    else { return true }
    return guarded.contains(toolName)
}
