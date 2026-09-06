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

/// 令牌文件的读写。三家（ZCode / Cursor / OMP）各自的差别只有默认目录和
/// 收紧权限失败时抛哪个错误，安全检查却是逐行相同的：owner-only 的 lstat、
/// 512 字节上限、写入后 chmod 600。这段代码复制三份最怕的就是漏洞只在
/// 其中一份里被补上，所以检查只留一份，差异用参数带进来。
struct AgentPermissionTokenStore {
    /// 令牌落在哪个目录。与受管集成写入的位置一致——那条路径由
    /// AgentIntegrationScope 决定，固定挂在 home 下，不看环境变量。
    let defaultDirectory: () -> URL
    let fileName: String
    /// 收紧权限失败时抛谁的错误。各家的错误类型会被安装流程分类展示，
    /// 不能合并成一种。
    let writeFailure: (String) -> Error

    static let zcode = AgentPermissionTokenStore(
        defaultDirectory: { zcodeConfigurationDirectoryURL() },
        fileName: ZCodePermissionHookConstants.tokenFileName,
        writeFailure: { ZCodeHookConfigurationError.writeFailed($0) }
    )

    static let cursor = AgentPermissionTokenStore(
        defaultDirectory: { cursorConfigurationDirectoryURL() },
        fileName: CursorPermissionHookConstants.tokenFileName,
        writeFailure: { CursorHookConfigurationError.writeFailed($0) }
    )

    static let omp = AgentPermissionTokenStore(
        defaultDirectory: { ompAgentDirectoryURL() },
        fileName: OMPPermissionHookConstants.tokenFileName,
        writeFailure: { OMPPermissionSettingsError.writeFailed($0) }
    )

    static let antigravity = AgentPermissionTokenStore(
        defaultDirectory: { antigravityConfigurationDirectoryURL() },
        fileName: AntigravityPermissionHookConstants.tokenFileName,
        writeFailure: { AntigravityHookConfigurationError.writeFailed($0) }
    )

    func tokenURL(directory: URL? = nil) -> URL {
        (directory ?? defaultDirectory())
            .appendingPathComponent(fileName)
    }

    /// 只接受 owner-only 的普通文件。放宽这条等于让任何本机进程都能改
    /// 令牌，从而向闸门伪造裁决请求。
    func token(directory: URL? = nil) -> String? {
        let url = tokenURL(directory: directory)
        var statBuffer = stat()
        guard lstat(url.path, &statBuffer) == 0,
              statBuffer.st_uid == geteuid(),
              (statBuffer.st_mode & S_IFMT) == S_IFREG,
              (statBuffer.st_mode & S_IRWXG) == 0,
              (statBuffer.st_mode & S_IRWXO) == 0,
              let data = try? Data(contentsOf: url),
              data.count <= 512,
              let token = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { return nil }
        return token
    }

    @discardableResult
    func ensureToken(directory: URL? = nil) throws -> String {
        let target = directory ?? defaultDirectory()
        if let existing = token(directory: target) { return existing }
        let fresh = AgentPermissionTokenFactory.make()
        let url = tokenURL(directory: target)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )
        // 以 0600 直接创建，杜绝「先 0644 落盘再 chmod」的窗口；收紧失败
        // 时立刻删除，不留一份全局可读的令牌在盘上。
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: Data(fresh.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw writeFailure("无法写入令牌文件")
        }
        guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
            try? FileManager.default.removeItem(at: url)
            throw writeFailure("无法收紧令牌文件权限")
        }
        return fresh
    }

    func removeToken(directory: URL? = nil) {
        try? FileManager.default.removeItem(at: tokenURL(directory: directory))
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
            resolveToken: { AgentPermissionTokenStore.zcode.token() },
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
            resolveToken: { AgentPermissionTokenStore.cursor.token() },
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

    /// agy 的裁决体里 `{}` 等于拒绝，不是「无意见」——所以就地放行必须
    /// 显式写 allow，兜底也必须显式写 ask，这两处都不能沿用 Cursor 那套
    /// 返回空对象的写法。
    ///
    /// 兜底选 ask 而不是自己伪造拒绝：agy 的 hook 本身是 fail-closed 的
    /// （命令非零退出就阻断工具），闸门够不着时不需要我们再补一刀，把
    /// 决定权交回它自己的权限流程才不会把用户锁在工具外面。
    static func antigravity(
        invokerSkipsPermissions: @escaping () -> Bool = {
            antigravityInvokerSkipsPermissions()
        }
    ) -> AgentPermissionHookTransport {
        AgentPermissionHookTransport(
            agentID: .antigravity,
            flag: AntigravityPermissionHookConstants.flag,
            url: AntigravityPermissionHookConstants.url,
            resolveToken: { AgentPermissionTokenStore.antigravity.token() },
            fallback: .handBackToVendor(
                AntigravityPermissionHookConstants.handBackOutput
            ),
            deadline: AntigravityPermissionHookConstants.requestTimeoutSeconds,
            shortCircuit: { body in
                // 共享 hooks.json 也会被 IDE 与 Antigravity 2.0 拉起。
                // 别家的会话不归这道闸门管，交回产品自己的权限流程——
                // 不能 allow（替人放行）也不能拦（把人卡在我们的面板上）。
                guard antigravityHookBodyIsCLISession(body) else {
                    return AntigravityPermissionHookConstants.handBackOutput
                }
                guard antigravityToolNameIsGuarded(in: body) else {
                    return AntigravityPermissionHookConstants.passThroughOutput
                }
                // 会话本身带 --dangerously-skip-permissions 时 agy 自己
                // 一次都不问，闸门再逐条弹只剩打扰——用户已经做过的
                // 决定不该由我们替他反悔。
                return invokerSkipsPermissions()
                    ? AntigravityPermissionHookConstants.passThroughOutput
                    : nil
            }
        )
    }

    static func all() -> [AgentPermissionHookTransport] {
        [.codex(), .zcode(), .cursor(), .antigravity()]
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
    readInput: (TimeInterval) -> Data? = { deadline in
        readAgentPermissionHookInput(deadlineSeconds: deadline)
    },
    postDecision: (
        Data,
        String?,
        AgentPermissionHookTransport
    ) -> AgentPermissionHookOutcome = { body, token, transport in
        postAgentPermissionRequest(
            body: body,
            token: token,
            url: URL(string: transport.url),
            timeout: AgentPermissionHookDeadline.remaining(transport.deadline)
        )
    },
    writeOutput: (String) -> Void = { text in
        FileHandle.standardOutput.write(Data(text.utf8))
    }
) -> Bool {
    let matchingTransports = transports.filter {
        arguments.contains($0.flag)
    }
    guard let transport = matchingTransports.first else {
        return false
    }
    if matchingTransports.count > 1 {
        // 现实里各厂商只带自己的旗标；argv 里同时出现多家说明调用被
        // 污染了。仍按第一家的语义走，但必须在 stderr 留痕便于排查，
        // 不能悄悄选错兜底方向。
        fputs(
            "threadhelm: multiple permission hook flags present;"
                + " using \(transport.agentID.rawValue)\n",
            stderr
        )
    }

    guard let body = readInput(
        AgentPermissionHookDeadline.remaining(transport.deadline)
    ), !body.isEmpty else {
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
        // 200 响应体在写回厂商前必须通过形状校验：面板下线的窗口里，
        // 端口上应答的可能是任何本机进程。校验挡不住伪造的合法 allow
        // （那需要响应签名），但保证写出去的永远是协议里真实存在的
        // 裁决，而不是任意字节——对 ZCode 来说，任意字节等于 hook
        // 失败，工具会被直接放行。
        if AgentPermissionHookDecisionShape.isAcceptable(
            data,
            agentID: transport.agentID
        ) {
            let text = String(data: data, encoding: .utf8) ?? ""
            writeOutput(text)
        } else {
            writeOutput(transport.fallbackOutput)
        }
    case .noDecision:
        writeOutput(transport.fallbackOutput)
    }
    return true
}

/// 读 stdin 直到 EOF。厂商写完 payload 就关 stdin，正常路径毫秒级返回；
/// 截止时间防的是厂商行为变化（写完不关 stdin）让 hook 挂到被墙钟杀掉
/// ——被杀一律 fail-open，所以读阶段也必须受 transport.deadline 约束，
/// 超时返回 nil，由调用方走各家的兜底输出。
func readAgentPermissionHookInput(
    fileHandle: FileHandle = .standardInput,
    limit: Int = CodexHookConstants.maximumInputBytes,
    deadlineSeconds: TimeInterval? = nil
) -> Data? {
    // 阻塞读与超时等待分属两个线程，结果经 box + 锁交接；超时后残留的
    // 阻塞读会随进程退出一起消失（调用方写完兜底输出就 exit）。
    final class ResultBox {
        let lock = NSLock()
        var value: Data?
    }
    let box = ResultBox()
    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        var data = Data()
        while true {
            let chunk = fileHandle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            // 超限直接放弃：截断后的 JSON 只会在服务端解析失败，与其发
            // 一份坏 payload，不如让调用方走兜底。
            if data.count > limit { data = Data(); break }
        }
        box.lock.lock()
        box.value = data.isEmpty ? nil : data
        box.lock.unlock()
        semaphore.signal()
    }
    if let deadlineSeconds {
        guard semaphore.wait(timeout: .now() + deadlineSeconds) == .success
        else { return nil }
    } else {
        semaphore.wait()
    }
    box.lock.lock()
    defer { box.lock.unlock() }
    return box.value
}

/// 闸门命令的墙钟预算。读 stdin 与等 HTTP 裁决两段共享 transport.deadline：
/// 任一段吃掉的时间都从后一段扣除，保证「自己先兜底」永远跑在厂商杀
/// 进程之前——被杀一律 fail-open。
enum AgentPermissionHookDeadline {
    static let processStart = Date()

    static func remaining(_ total: TimeInterval) -> TimeInterval {
        max(1, total - Date().timeIntervalSince(processStart))
    }
}

/// 服务端裁决体的形状白名单，与各 PermissionProtocol.responseBody 一一
/// 对应。协议演进时两边必须同步改——面板与 hook 在同一个二进制里，
/// 不同步只可能是验证器写错了。
enum AgentPermissionHookDecisionShape {
    static func isAcceptable(_ data: Data, agentID: AgentID) -> Bool {
        guard data.count <= ClaudeHookConstants.maximumBodyBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any]
        else { return false }
        switch agentID {
        case .codex, .zcode:
            guard let hookSpecific = payload["hookSpecificOutput"]
                    as? [String: Any],
                  let decision = hookSpecific["decision"] as? [String: Any],
                  let behavior = decision["behavior"] as? String
            else { return false }
            return ["allow", "deny"].contains(behavior)
        case .cursor:
            guard let permission = payload["permission"] as? String
            else { return false }
            return ["allow", "deny", "ask"].contains(permission)
        case .antigravity:
            guard let decision = payload["decision"] as? String
            else { return false }
            return ["allow", "deny", "ask"].contains(decision)
        default:
            return false
        }
    }
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

    // 回调线程与等待线程都可能碰 outcome；超时后回调仍可能晚到，
    // 不能让这两个线程无同步地读写同一份内存。
    final class OutcomeBox {
        let lock = NSLock()
        var value = AgentPermissionHookOutcome.noDecision
    }
    let box = OutcomeBox()
    let semaphore = DispatchSemaphore(value: 0)
    let task = session.dataTask(with: request) { data, response, _ in
        defer { semaphore.signal() }
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let data,
              !data.isEmpty
        else { return }
        // 端口被别的进程抢答时,对方拿得到令牌(就在请求里)却拿不到
        // 签名私钥。公钥在而签名无效/缺失 → 按没拿到裁决处理。
        guard GateDecisionSignatureVerifier.isAuthentic(
            body: data,
            signatureHeaderValue: GateDecisionSignatureVerifier
                .signatureHeaderValue(from: http)
        ) else { return }
        box.lock.lock()
        box.value = .decision(data)
        box.lock.unlock()
    }
    task.resume()
    // 比 URLSession 自身的超时多留一点余量，避免两个时钟同时到点时
    // 信号量先醒、回调后写 outcome 造成竞态。
    if semaphore.wait(timeout: .now() + timeout + 5) == .timedOut {
        task.cancel()
        return .noDecision
    }
    box.lock.lock()
    defer { box.lock.unlock() }
    return box.value
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
