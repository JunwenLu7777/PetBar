//
//  CursorPermissionSelfTest.swift
//  ThreadHelm
//
//  模块职责：锁住 Cursor 审批闸门的契约。这里守的核心与另外三家不同：
//  Cursor 只有 preToolUse 可用，而它每次工具调用都触发——把只读操作也弹
//  成确认框会让用户对确认框脱敏，那比不拦更危险。
//

import Foundation

func runCursorPermissionSelfTest() -> Never {
    func fail(_ message: String) -> Never {
        fputs("cursor-permission-self-test failed: \(message)\n", stderr)
        exit(1)
    }

    // MARK: 负载解析

    // Cursor 的 preToolUse 负载字段名与 Claude 重合，入向复用同一个解析器。
    let fixture = """
    {
      "conversation_id": "conv-7f3a",
      "generation_id": "gen-2",
      "model": "composer-1",
      "session_id": "conv-7f3a",
      "hook_event_name": "preToolUse",
      "cursor_version": "3.17.21",
      "workspace_roots": ["/Users/x/code/app"],
      "cwd": "/Users/x/code/app",
      "tool_name": "Shell",
      "tool_use_id": "toolu-11",
      "tool_input": {
        "command": "rm -rf build",
        "description": "清理构建产物"
      }
    }
    """
    guard let prompt = try? ClaudePermissionProtocol.decodePrompt(
        from: Data(fixture.utf8),
        agentID: .cursor
    ) else {
        fail("preToolUse 负载解析")
    }
    guard prompt.agentID == .cursor,
          prompt.toolName == "Shell",
          prompt.sessionID == "conv-7f3a",
          prompt.workingDirectory == "/Users/x/code/app",
          prompt.message == "清理构建产物",
          prompt.title.contains("Cursor")
    else {
        fail("负载字段未正确落位：\(prompt.title) / \(prompt.message)")
    }

    // MARK: 裁决编码

    func decision(
        _ decision: ClaudePermissionUserDecision
    ) -> [String: Any]? {
        guard let data = CursorPermissionProtocol.responseBody(
            for: decision,
            prompt: prompt
        ),
        let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return object as? [String: Any]
    }

    guard decision(.allowOnce)?["permission"] as? String == "allow" else {
        fail("allow 编码")
    }
    guard let deny = decision(.deny("这条命令会删掉构建产物")),
          deny["permission"] as? String == "deny",
          deny["agent_message"] as? String == "这条命令会删掉构建产物"
    else {
        fail("deny 编码")
    }
    guard let emptyDeny = decision(.deny("   ")),
          (emptyDeny["agent_message"] as? String)?.isEmpty == false
    else {
        fail("空拒绝理由未回落到默认文案")
    }
    // Cursor 有 ask，这是四家里唯一能把决定权原样交回厂商流程的。
    // 编码成 allow 会让「回到 Cursor 处理」变成替用户放行。
    guard decision(.nativeFallback)?["permission"] as? String == "ask" else {
        fail("交还原生应编码为 ask")
    }
    guard let answered = decision(.submitAnswers(["a": "b"])),
          answered["permission"] as? String == "allow",
          answered["updated_input"] is [String: Any]
    else {
        fail("updated_input 编码")
    }

    // MARK: 只拦高风险工具

    func payload(toolName: String) -> Data {
        Data("""
        {"hook_event_name":"preToolUse","tool_name":"\(toolName)",
         "tool_input":{},"session_id":"s","cwd":"/tmp"}
        """.utf8)
    }
    for guarded in ["Shell", "Write"] {
        guard cursorToolNameIsGuarded(in: payload(toolName: guarded)) else {
            fail("\(guarded) 应当需要人来把关")
        }
    }
    // 只读工具不拦。preToolUse 每次调用都触发，把 Read/Grep 也弹出来只会
    // 制造噪音，最终让用户对所有确认框脱敏。
    for readOnly in ["Read", "Grep", "Glob", "WebSearch", "WebFetch"] {
        guard !cursorToolNameIsGuarded(in: payload(toolName: readOnly)) else {
            fail("\(readOnly) 是只读操作，不该打扰用户")
        }
    }
    // 读不懂的负载按「需要把关」处理：可能是新工具，也可能是格式变了，
    // 那时多问一次远好过默认放行。
    guard cursorToolNameIsGuarded(in: Data("not json".utf8)),
          cursorToolNameIsGuarded(in: Data(#"{"tool_name":123}"#.utf8)),
          cursorToolNameIsGuarded(in: Data("{}".utf8))
    else {
        fail("无法解析的负载应保守地要求把关")
    }
    // matcher 是 `new RegExp(m).test(toolName)`，子串语义。不锚定的话
    // "WriteupGenerator" 之类也会被匹配进来。
    guard CursorPermissionHookConstants.matcher.hasPrefix("^"),
          CursorPermissionHookConstants.matcher.hasSuffix("$")
    else {
        fail("matcher 未锚定：\(CursorPermissionHookConstants.matcher)")
    }
    for guarded in CursorPermissionHookConstants.guardedToolNames {
        guard let expression = try? NSRegularExpression(
            pattern: CursorPermissionHookConstants.matcher
        ), expression.firstMatch(
            in: guarded,
            range: NSRange(guarded.startIndex..., in: guarded)
        ) != nil else {
            fail("matcher 漏掉了受管工具 \(guarded)")
        }
    }

    // MARK: 转发进程

    func runHook(
        arguments: [String],
        input: Data?,
        outcome: AgentPermissionHookOutcome
    ) -> (handled: Bool, output: String) {
        var written = ""
        let handled = runAgentPermissionHookCommandIfRequested(
            arguments: arguments,
            transports: [AgentPermissionHookTransport.cursor()],
            readInput: { input },
            postDecision: { _, _, _ in outcome },
            writeOutput: { written += $0 }
        )
        return (handled, written)
    }

    // 只读工具应当就地放行，根本不去联系面板。
    var reachedPanel = false
    var passThrough = ""
    _ = runAgentPermissionHookCommandIfRequested(
        arguments: ["ThreadHelm", CursorPermissionHookConstants.flag],
        transports: [AgentPermissionHookTransport.cursor()],
        readInput: { payload(toolName: "Read") },
        postDecision: { _, _, _ in
            reachedPanel = true
            return .noDecision
        },
        writeOutput: { passThrough += $0 }
    )
    guard !reachedPanel else { fail("只读工具不该惊动面板") }
    guard let passObject = try? JSONSerialization.jsonObject(
        with: Data(passThrough.utf8)
    ) as? [String: Any], passObject["permission"] == nil else {
        fail("就地放行的输出应当不带 permission：\(passThrough)")
    }

    let decided = runHook(
        arguments: ["ThreadHelm", CursorPermissionHookConstants.flag],
        input: payload(toolName: "Shell"),
        outcome: .decision(Data(#"{"permission":"deny"}"#.utf8))
    )
    guard decided.handled, decided.output == #"{"permission":"deny"}"# else {
        fail("裁决应原样写回 stdout")
    }

    // 闸门够不着时交回 Cursor 自己的权限流程。Cursor 配了 failClosed，
    // 真正的失败（进程崩溃、超时）由它判 deny；我们这条只在还能正常
    // 输出时用，所以 ask 比 deny 更贴切——不替用户放行，也不替他否决。
    let transport = AgentPermissionHookTransport.cursor()
    for (label, input) in [
        ("面板离线", payload(toolName: "Shell")),
        ("stdin 为空", Data()),
    ] {
        let result = runHook(
            arguments: ["ThreadHelm", CursorPermissionHookConstants.flag],
            input: input,
            outcome: .noDecision
        )
        guard result.handled, result.output == transport.fallbackOutput else {
            fail("\(label)时的兜底输出不对：\(result.output)")
        }
    }
    guard let fallbackObject = try? JSONSerialization.jsonObject(
        with: Data(transport.fallbackOutput.utf8)
    ) as? [String: Any],
    fallbackObject["permission"] as? String == "ask"
    else {
        fail("兜底输出应为 ask")
    }

    // MARK: hooks.json 装配

    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("threadhelm-cursor-selftest-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let adapter = CursorAgentAdapter(
        discovery: {
            AgentDiscovery(
                isInstalled: true,
                version: "3.17.21",
                compatibility: .validated
            )
        },
        // 用真实形状：观测命令自带 `--agent-hook cursor` 前缀。之前这里
        // 传裸路径，于是漏掉了「审批命令继承了观测前缀」这个缺陷——进程
        // 入口会先匹配 --agent-hook 就 exit，审批转发一行都跑不到。
        hookCommand: "\"/opt/threadhelm/ThreadHelm\" --agent-hook cursor"
    )
    let scope = AgentIntegrationScope.isolated(at: root)
    guard (try? adapter.installIntegration(in: scope)) == .installed else {
        fail("Cursor 集成安装失败")
    }
    guard adapter.integrationStatus(in: scope) == .installed else {
        fail("安装后状态不是 installed")
    }
    guard (try? adapter.installIntegration(in: scope)) == .unchanged else {
        fail("重复安装应报未改动")
    }

    let hooksURL = root.appendingPathComponent(".cursor/hooks.json")
    guard let data = try? Data(contentsOf: hooksURL),
          let object = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any],
          let hooks = object["hooks"] as? [String: Any],
          let preToolUse = hooks["preToolUse"] as? [[String: Any]]
    else {
        fail("读不到 preToolUse 配置")
    }
    // 观测与审批两条并存。Cursor 会跑完同一事件的所有 hook 再按
    // 「任一 deny 即 deny」合并，所以共存是安全的。
    guard preToolUse.count == 2 else {
        fail("preToolUse 下应有观测与审批两条，实际 \(preToolUse.count)")
    }
    guard let permissionEntry = preToolUse.first(where: {
        ($0["threadhelmKind"] as? String) == "permission"
    }) else {
        fail("preToolUse 下缺少审批 entry")
    }
    // 这三项是闸门能不能用的全部前提。timeout 单位是秒，Cursor 内部乘 1000。
    guard permissionEntry["timeout"] as? Int
        == CursorPermissionHookConstants.hookTimeoutSeconds,
        (permissionEntry["timeout"] as? Int ?? 0) >= 300
    else {
        fail("审批 hook 的超时预算过短，人来不及点")
    }
    guard permissionEntry["failClosed"] as? Bool == true else {
        fail("未开启 failClosed，hook 失败时 Cursor 会直接放行")
    }
    guard permissionEntry["matcher"] as? String
        == CursorPermissionHookConstants.matcher
    else {
        fail("审批 hook 的 matcher 不对")
    }
    guard let permissionCommand = permissionEntry["command"] as? String,
          permissionCommand.contains(CursorPermissionHookConstants.flag)
    else {
        fail("审批 hook 的命令没带旗标")
    }
    // 审批命令绝不能继承观测的 --agent-hook 前缀：进程入口先匹配它，
    // 把这次调用当成观测事件处理完就 exit(0)，闸门静默失效。
    guard !permissionCommand.contains("--agent-hook") else {
        fail("审批命令继承了观测前缀，闸门不会被执行：\(permissionCommand)")
    }
    guard permissionCommand
        == "\"/opt/threadhelm/ThreadHelm\" \(CursorPermissionHookConstants.flag)"
    else {
        fail("审批命令形状不对：\(permissionCommand)")
    }
    // 观测那条反过来必须保留前缀。
    guard (observationEntryCommandForSelfTest(preToolUse) ?? "")
        .contains("--agent-hook cursor")
    else {
        fail("观测命令丢了 --agent-hook 前缀")
    }
    // 观测那条必须原样保留自己的形状：1 秒预算、无 matcher。被审批的
    // 形状污染会让它在每次工具调用上多花 600 秒的等待预算。
    guard let observationEntry = preToolUse.first(where: {
        ($0["threadhelmKind"] as? String) != "permission"
    }), observationEntry["timeout"] as? Int == 1,
    observationEntry["matcher"] == nil,
    observationEntry["failClosed"] == nil
    else {
        fail("观测 entry 被审批配置污染了")
    }

    // 令牌
    let tokenDirectory = root.appendingPathComponent(".cursor")
    guard let token = CursorPermissionTokenStore.token(
        directory: tokenDirectory
    ), !token.isEmpty else {
        fail("安装后应写出令牌")
    }
    var tokenStat = stat()
    let tokenPath = CursorPermissionTokenStore.tokenURL(
        directory: tokenDirectory
    ).path
    guard lstat(tokenPath, &tokenStat) == 0,
          (tokenStat.st_mode & S_IRWXG) == 0,
          (tokenStat.st_mode & S_IRWXO) == 0
    else {
        fail("令牌文件权限未收紧到 owner-only")
    }

    // 卸载要连令牌一起清掉。
    guard (try? adapter.uninstallIntegration(in: scope)) == .uninstalled,
          CursorPermissionTokenStore.token(directory: tokenDirectory) == nil
    else {
        fail("卸载未清除令牌")
    }
    if let leftoverData = try? Data(contentsOf: hooksURL),
       let leftover = try? JSONSerialization.jsonObject(with: leftoverData)
        as? [String: Any],
       let leftoverHooks = leftover["hooks"] as? [String: Any],
       let leftoverEntries = leftoverHooks["preToolUse"] as? [[String: Any]],
       leftoverEntries.contains(where: {
           ($0["threadhelmKind"] as? String) == "permission"
       })
    {
        fail("卸载后审批 entry 仍在")
    }

    // MARK: 端口路由

    let cursorRoute = PermissionHookRoute.cursor(token: { "cursor-token" })
    guard cursorRoute.agentID == .cursor else { fail("线路 agentID") }
    for other in [
        PermissionHookRoute.claude(token: { "c" }),
        .codex(token: { "x" }),
        .zcode(token: { "z" }),
        .omp(token: { "o" }),
    ] {
        guard other.path != cursorRoute.path else {
            fail("Cursor 线路路径与 \(other.agentID.rawValue) 冲突")
        }
    }
    for foreign in ["c", "x", "z", "o"] {
        guard !ClaudePermissionHookServer.isAuthenticated(
            headers: [
                ClaudeHookConstants.authenticationHeader.lowercased(): foreign,
            ],
            expectedToken: cursorRoute.expectedToken()
        ) else {
            fail("别家的令牌不应能打开 Cursor 的线路")
        }
    }
    guard let routed = cursorRoute.encode(.deny("不行"), prompt),
          let routedObject = try? JSONSerialization.jsonObject(with: routed)
            as? [String: Any],
          routedObject["permission"] as? String == "deny",
          routedObject["hookSpecificOutput"] == nil
    else {
        fail("Cursor 线路应输出 permission 形状而非 Claude 的")
    }

    print("cursor-permission-self-test ok")
    exit(0)
}

private func observationEntryCommandForSelfTest(
    _ entries: [[String: Any]]
) -> String? {
    entries.first {
        ($0["threadhelmKind"] as? String) != "permission"
    }?["command"] as? String
}
