//
//  ZCodePermissionSelfTest.swift
//  ThreadHelm
//
//  模块职责：锁住 ZCode 审批闸门的契约。负载 fixture 按 zcode.cjs 里
//  构造 hook 输入的那段代码逐字段还原（同时带原生 camelCase 与
//  snake_case 兼容键），裁决格式取自同一 bundle 的运行时 schema。
//

import Foundation

func runZCodePermissionSelfTest() -> Never {
    func fail(_ message: String) -> Never {
        fputs("zcode-permission-self-test failed: \(message)\n", stderr)
        exit(1)
    }

    // MARK: 负载解析

    // ZCode 的 hook 输入由一个函数统一构造：先摊平原生 camelCase 字段，
    // 再补上一层 Claude 兼容的 snake_case 键，PermissionRequest 分支
    // 额外挂 permission_suggestions。所以 Claude 的解析器能直接吃。
    let fixture = """
    {
      "cwd": "/private/tmp/zcode-work",
      "hookEventName": "PermissionRequest",
      "mode": "build",
      "riskLevel": "high",
      "sessionId": "sess_900904ad-9455-4c85-b624-ac10991b5c2d",
      "sideEffectScope": "system",
      "toolCallId": "call_a8649cbe96af4e0ea0bef21b",
      "toolInput": {
        "command": "rm -rf /tmp/scratch",
        "description": "清理临时目录"
      },
      "toolName": "Bash",
      "turnId": "turn_673eebbf-59b5-407b-a9b3-d020e117e53b",
      "hook_event_name": "PermissionRequest",
      "permission_mode": "build",
      "session_id": "sess_900904ad-9455-4c85-b624-ac10991b5c2d",
      "transcript_path": "/var/folders/x/zcode-claude-hook-ZZBjJs/transcript.jsonl",
      "tool_name": "Bash",
      "tool_input": {
        "command": "rm -rf /tmp/scratch",
        "description": "清理临时目录"
      },
      "tool_use_id": "call_a8649cbe96af4e0ea0bef21b",
      "permission_suggestions": [
        {
          "type": "addRules",
          "behavior": "allow",
          "rules": [{"toolName": "Bash", "ruleContent": "rm -rf /tmp/*"}]
        }
      ]
    }
    """
    guard let prompt = try? ClaudePermissionProtocol.decodePrompt(
        from: Data(fixture.utf8),
        agentID: .zcode
    ) else {
        fail("PermissionRequest 负载解析")
    }
    guard prompt.agentID == .zcode else { fail("agentID 未标为 zcode") }
    guard prompt.interactionKind == .toolApproval else { fail("interactionKind") }
    guard prompt.toolName == "Bash" else { fail("tool_name") }
    guard prompt.sessionID == "sess_900904ad-9455-4c85-b624-ac10991b5c2d" else {
        fail("session_id")
    }
    guard prompt.workingDirectory == "/private/tmp/zcode-work" else { fail("cwd") }
    guard prompt.message == "清理临时目录" else {
        fail("description 未用作提示正文：\(prompt.message)")
    }
    // 界面文案必须说出是谁在问，否则用户不知道自己在批哪家的请求。
    guard prompt.title.contains("ZCode") else {
        fail("标题未标明来源是 ZCode：\(prompt.title)")
    }
    guard !prompt.title.contains("Claude") else {
        fail("ZCode 的请求被标成了 Claude")
    }
    // ZCode 与 Claude 一样支持长期授权建议，这条不能在解析时丢掉。
    guard prompt.suggestions.count == 1,
          prompt.suggestions[0].title.contains("Bash")
    else {
        fail("permission_suggestions 未被解析")
    }

    // Claude 自己的负载不能被这次泛化带偏。
    guard let claudePrompt = try? ClaudePermissionProtocol.decodePrompt(
        from: Data(fixture.utf8)
    ), claudePrompt.agentID == .claudeCode,
    claudePrompt.title.contains("Claude")
    else {
        fail("默认 agentID 应仍是 Claude")
    }

    // MARK: 裁决编码

    func decision(
        _ decision: ClaudePermissionUserDecision
    ) -> [String: Any]? {
        guard let data = ClaudePermissionProtocol.responseBody(
            for: decision,
            prompt: prompt
        ),
        let object = try? JSONSerialization.jsonObject(with: data),
        let payload = object as? [String: Any],
        let specific = payload["hookSpecificOutput"] as? [String: Any],
        specific["hookEventName"] as? String == "PermissionRequest"
        else { return nil }
        return specific["decision"] as? [String: Any]
    }

    guard let allow = decision(.allowOnce),
          allow["behavior"] as? String == "allow"
    else {
        fail("allow 编码")
    }
    guard let deny = decision(.deny("这条命令会删掉生产目录")),
          deny["behavior"] as? String == "deny",
          deny["message"] as? String == "这条命令会删掉生产目录"
    else {
        fail("deny 编码")
    }
    // ZCode 的 allow 变体接受 updatedPermissions 与 updatedInput，
    // 所以长期授权与问题回答这两条路都能走通。
    guard let suggested = decision(
        .allowWithSuggestion(prompt.suggestions[0].rawValue)
    ),
    suggested["behavior"] as? String == "allow",
    (suggested["updatedPermissions"] as? [[String: Any]])?.count == 1
    else {
        fail("长期授权建议编码")
    }
    guard let answered = decision(.submitAnswers(["a": "b"])),
          answered["behavior"] as? String == "allow",
          answered["updatedInput"] is [String: Any]
    else {
        fail("updatedInput 编码")
    }

    // MARK: 失败语义——这条是 ZCode 与 Codex 的根本差别

    // ZCode 在 hook 超时、崩溃、连不上时**执行工具**。所以闸门够不着
    // 用户时必须自己写出一份拒绝；沿用 Codex 那套「交还原生 UI」会让
    // 工具直接跑掉。
    let zcodeTransport = AgentPermissionHookTransport.zcode()
    guard case .denyWithReason = zcodeTransport.fallback else {
        fail("ZCode 的兜底必须是主动拒绝")
    }
    guard let fallbackData = zcodeTransport.fallbackOutput.data(using: .utf8),
          let fallbackObject = try? JSONSerialization.jsonObject(
              with: fallbackData
          ) as? [String: Any],
          fallbackObject["continue"] as? Bool == false,
          let fallbackSpecific = fallbackObject["hookSpecificOutput"]
            as? [String: Any],
          let fallbackDecision = fallbackSpecific["decision"] as? [String: Any],
          fallbackDecision["behavior"] as? String == "deny",
          (fallbackDecision["message"] as? String)?.isEmpty == false
    else {
        fail("ZCode 兜底输出不是一份可解析的拒绝：\(zcodeTransport.fallbackOutput)")
    }
    // Codex 相反：它收到空裁决会回到自己的批准界面，主动拒绝反而
    // 会替用户否决掉本可以批准的操作。
    guard case .handBackToVendor = AgentPermissionHookTransport.codex().fallback
    else {
        fail("Codex 的兜底应交还原生 UI")
    }

    func runHook(
        arguments: [String],
        input: Data?,
        outcome: AgentPermissionHookOutcome,
        token: String? = "t"
    ) -> (handled: Bool, output: String) {
        var written = ""
        let handled = runAgentPermissionHookCommandIfRequested(
            arguments: arguments,
            transports: [AgentPermissionHookTransport(
                agentID: .zcode,
                flag: ZCodePermissionHookConstants.flag,
                url: ZCodePermissionHookConstants.url,
                resolveToken: { token },
                fallback: zcodeTransport.fallback,
                deadline: 1
            )],
            readInput: { input },
            postDecision: { _, _, _ in outcome },
            writeOutput: { written += $0 }
        )
        return (handled, written)
    }

    guard runHook(
        arguments: ["ThreadHelm"],
        input: Data("{}".utf8),
        outcome: .noDecision
    ).handled == false else {
        fail("没有旗标时不应接管进程")
    }

    let decided = runHook(
        arguments: ["ThreadHelm", ZCodePermissionHookConstants.flag],
        input: Data(fixture.utf8),
        outcome: .decision(Data("{\"ok\":1}".utf8))
    )
    guard decided.handled, decided.output == "{\"ok\":1}" else {
        fail("裁决应原样写回 stdout")
    }

    for (label, input, outcome) in [
        ("面板离线", Data(fixture.utf8), AgentPermissionHookOutcome.noDecision),
        ("stdin 为空", Data(), .noDecision),
        ("stdin 缺失", nil as Data?, .noDecision),
        ("裁决为空", Data(fixture.utf8), .decision(Data())),
    ] as [(String, Data?, AgentPermissionHookOutcome)] {
        let result = runHook(
            arguments: ["ThreadHelm", ZCodePermissionHookConstants.flag],
            input: input,
            outcome: outcome
        )
        guard result.handled,
              result.output == zcodeTransport.fallbackOutput
        else {
            fail("\(label)时未写出拒绝，工具会被放行")
        }
    }

    // MARK: 超时预算

    // 观测 hook 的 250ms 预算套到审批上是灾难：ZCode 会在四分之一秒后
    // 杀掉 hook，而被杀一律 fail-open。
    guard ZCodePermissionHookConstants.hookTimeoutMilliseconds >= 300_000 else {
        fail("审批 hook 超时预算过短，人来不及点")
    }
    // 我们必须比 ZCode 的上限先收手：由自己返回拒绝才是 fail-closed，
    // 被 ZCode 杀掉就是 fail-open。
    guard ZCodePermissionHookConstants.selfDenyDeadlineSeconds
        < Double(ZCodePermissionHookConstants.hookTimeoutMilliseconds) / 1_000
    else {
        fail("自我拒绝截止时间不早于 ZCode 的超时上限")
    }

    // MARK: 端口路由

    let zcodeRoute = PermissionHookRoute.zcode(token: { "zcode-token" })
    let claudeRoute = PermissionHookRoute.claude(token: { "claude-token" })
    let codexRoute = PermissionHookRoute.codex(token: { "codex-token" })
    guard Set([zcodeRoute.path, claudeRoute.path, codexRoute.path]).count == 3
    else {
        fail("三条线路的路径必须互不相同")
    }
    guard zcodeRoute.agentID == .zcode else { fail("线路 agentID") }
    // 令牌不共享：任一方配置泄漏都不能让攻击者向另一方伪造裁决。
    for foreign in ["claude-token", "codex-token"] {
        guard !ClaudePermissionHookServer.isAuthenticated(
            headers: [
                ClaudeHookConstants.authenticationHeader.lowercased(): foreign,
            ],
            expectedToken: zcodeRoute.expectedToken()
        ) else {
            fail("\(foreign) 不应能打开 ZCode 的线路")
        }
    }
    guard ClaudePermissionHookServer.isAuthenticated(
        headers: [
            ClaudeHookConstants.authenticationHeader.lowercased(): "zcode-token",
        ],
        expectedToken: zcodeRoute.expectedToken()
    ) else {
        fail("ZCode 自己的令牌应能通过")
    }
    guard let routed = zcodeRoute.encode(.allowOnce, prompt),
          let routedObject = try? JSONSerialization.jsonObject(with: routed)
              as? [String: Any],
          routedObject["hookSpecificOutput"] != nil
    else {
        fail("ZCode 线路编码")
    }

    // MARK: 令牌落盘

    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("threadhelm-zcode-token-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    guard ZCodePermissionTokenStore.token(directory: root) == nil else {
        fail("空目录不应有令牌")
    }
    guard let created = try? ZCodePermissionTokenStore.ensureToken(
        directory: root
    ), !created.isEmpty else {
        fail("首次应写出令牌")
    }
    // 幂等：重复安装不能轮换令牌，否则正在等待裁决的 hook 会突然 403。
    guard (try? ZCodePermissionTokenStore.ensureToken(directory: root))
        == created,
        ZCodePermissionTokenStore.token(directory: root) == created
    else {
        fail("重复安装不应轮换令牌")
    }
    var tokenStat = stat()
    let tokenPath = ZCodePermissionTokenStore.tokenURL(directory: root).path
    guard lstat(tokenPath, &tokenStat) == 0,
          (tokenStat.st_mode & S_IRWXG) == 0,
          (tokenStat.st_mode & S_IRWXO) == 0
    else {
        fail("令牌文件权限未收紧到 owner-only")
    }
    ZCodePermissionTokenStore.removeToken(directory: root)
    guard ZCodePermissionTokenStore.token(directory: root) == nil else {
        fail("卸载后应清除令牌")
    }

    print("zcode-permission-self-test ok")
    exit(0)
}
