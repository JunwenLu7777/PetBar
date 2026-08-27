//
//  CodexHookSelfTest.swift
//  ThreadHelm
//
//  模块职责：锁住 Codex 审批闸门的契约。fixture 全部取自 codex-cli 0.150.1
//  本机实测的真实 payload 与真实响应，不是照文档手写的。
//

import Foundation

func runCodexHookSelfTest() -> Never {
    func fail(_ message: String) -> Never {
        fputs("codex-hook-self-test failed: \(message)\n", stderr)
        exit(1)
    }

    // MARK: 线协议——入向

    // 原样取自实测：CODEX_HOME 隔离目录下 approval_policy=on-request
    // 的 TUI 会话，模型请求执行 touch 时 hook 收到的 stdin。
    let permissionFixture = """
    {
      "session_id": "01a041e1-9121-71f0-a5ad-971fe26c94d1",
      "turn_id": "01a041e1-9154-76a1-9072-aa90ea5d522b",
      "transcript_path": "/private/tmp/th-codex-gate/home/sessions/2026/08/27/rollout-2026-08-27T14-21-36-01a041e1-9121-71f0-a5ad-971fe26c94d1.jsonl",
      "cwd": "/private/tmp/th-codex-gate/work",
      "hook_event_name": "PermissionRequest",
      "model": "gpt-5.6-sol",
      "permission_mode": "default",
      "tool_name": "Bash",
      "tool_input": {
        "command": "touch /private/tmp/th-codex-gate-sentinel",
        "description": "Allow creating the requested sentinel file at /private/tmp/th-codex-gate-sentinel?"
      }
    }
    """
    guard let prompt = try? CodexPermissionProtocol.decodePrompt(
        from: Data(permissionFixture.utf8)
    ) else {
        fail("PermissionRequest 解析")
    }
    guard prompt.agentID == .codex else { fail("agentID 未标为 codex") }
    guard prompt.interactionKind == .toolApproval else {
        fail("interactionKind 应为 toolApproval")
    }
    guard prompt.toolName == "Bash" else { fail("tool_name") }
    guard prompt.sessionID == "01a041e1-9121-71f0-a5ad-971fe26c94d1" else {
        fail("session_id")
    }
    guard prompt.workingDirectory == "/private/tmp/th-codex-gate/work" else {
        fail("cwd")
    }
    // 模型自己写的说明比工具名有用，必须直接呈现给用户。
    guard prompt.message.hasPrefix("Allow creating the requested sentinel") else {
        fail("description 未用作提示正文")
    }
    guard prompt.title.contains("Codex") else { fail("标题未标明来源是 Codex") }
    // Codex 没有 suggestion 机制，也没有 AskUserQuestion / ExitPlanMode。
    guard prompt.suggestions.isEmpty, prompt.questions.isEmpty,
          prompt.planText == nil
    else {
        fail("Codex 不应带 suggestion/question/plan")
    }

    // 事件名不对就必须拒收：同一个端口上还挂着 Claude 的线路，
    // 放行错事件等于让一方的 payload 走另一方的解码器。
    let wrongEvent = permissionFixture.replacingOccurrences(
        of: "\"PermissionRequest\"",
        with: "\"PreToolUse\""
    )
    if (try? CodexPermissionProtocol.decodePrompt(
        from: Data(wrongEvent.utf8)
    )) != nil {
        fail("PreToolUse 事件不应被当成审批请求")
    }
    if (try? CodexPermissionProtocol.decodePrompt(
        from: Data("{\"hook_event_name\":\"PermissionRequest\"}".utf8)
    )) != nil {
        fail("缺少 tool_name 时不应解析成功")
    }

    // MARK: 线协议——出向

    func decision(_ decision: ClaudePermissionUserDecision) -> [String: Any]? {
        guard let data = CodexPermissionProtocol.responseBody(for: decision),
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any],
              let specific = payload["hookSpecificOutput"] as? [String: Any]
        else { return nil }
        guard specific["hookEventName"] as? String == "PermissionRequest" else {
            return nil
        }
        return specific["decision"] as? [String: Any]
    }

    guard let allow = decision(.allowOnce),
          allow["behavior"] as? String == "allow"
    else {
        fail("allow 编码")
    }
    // Codex 对 updatedInput / updatedPermissions 一律 fail-closed，
    // 出现在裁决里会让整次批准失败，所以放行体必须干净。
    guard allow["updatedInput"] == nil,
          allow["updatedPermissions"] == nil,
          allow["interrupt"] == nil
    else {
        fail("放行裁决混入了 Codex 会 fail-closed 的字段")
    }

    guard let deny = decision(.deny("命令会删除生产数据")),
          deny["behavior"] as? String == "deny",
          deny["message"] as? String == "命令会删除生产数据"
    else {
        fail("deny 编码")
    }
    // 空理由不能原样发：Codex 对没有理由的拒绝会另做处理。
    guard let emptyDeny = decision(.deny("   ")),
          let fallbackMessage = emptyDeny["message"] as? String,
          !fallbackMessage.isEmpty
    else {
        fail("空拒绝理由未回落到默认文案")
    }

    // 交还原生 UI = 不给裁决。Codex 收到空响应会自己弹批准框，
    // 不是放行。
    guard CodexPermissionProtocol.responseBody(for: .nativeFallback) == nil else {
        fail("nativeFallback 应当不给裁决")
    }
    guard CodexPermissionProtocol.responseBody(
        for: .submitAnswers(["a": "b"])
    ) == nil else {
        fail("submitAnswers 会触发 Codex 的 updatedInput fail-closed，必须交还原生")
    }

    // MARK: hooks.json 管理

    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("threadhelm-codex-hook-selftest-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let hooksURL = root.appendingPathComponent("hooks.json")

    func status() -> CodexHookConfigurationStatus {
        (try? CodexHookConfiguration.status(at: hooksURL)) ?? .missing
    }

    guard status() == .missing else { fail("空目录应报 missing") }

    let command = "/opt/threadhelm/ThreadHelm \(CodexHookConstants.hookCommandFlag)"
    guard (try? CodexHookConfiguration.install(
        at: hooksURL,
        hookCommand: command,
        isCodexAvailable: { true }
    )) == true else {
        fail("首次安装应返回已改动")
    }
    guard status() == .installed else { fail("安装后应报 installed") }

    // 令牌必须是 owner-only 的普通文件，否则任何本机进程都能伪造裁决。
    let tokenURL = CodexHookConfiguration.authenticationTokenURL(for: hooksURL)
    guard let token = CodexHookConfiguration.authenticationToken(for: hooksURL),
          !token.isEmpty
    else {
        fail("安装后应写出令牌")
    }
    var tokenStat = stat()
    guard lstat(tokenURL.path, &tokenStat) == 0,
          (tokenStat.st_mode & S_IRWXG) == 0,
          (tokenStat.st_mode & S_IRWXO) == 0
    else {
        fail("令牌文件权限未收紧到 owner-only")
    }

    // 幂等：配置没变就不该反复重写，否则每次探测都会让 Codex 那边
    // 已建立的信任作废，用户要一遍遍重新授信。
    guard (try? CodexHookConfiguration.install(
        at: hooksURL,
        hookCommand: command,
        isCodexAvailable: { true }
    )) == false else {
        fail("重复安装应报未改动")
    }
    guard CodexHookConfiguration.authenticationToken(for: hooksURL) == token else {
        fail("幂等安装不应轮换令牌")
    }

    // 写好的配置必须真的能被 Codex 读懂：结构是
    // hooks.PermissionRequest[].hooks[]，handler 是 command 类型。
    guard let written = try? Data(contentsOf: hooksURL),
          let root0 = try? JSONSerialization.jsonObject(with: written) as? [String: Any],
          let hooks = root0["hooks"] as? [String: Any],
          let entries = hooks["PermissionRequest"] as? [[String: Any]],
          entries.count == 1,
          let nested = entries[0]["hooks"] as? [[String: Any]],
          nested.count == 1,
          nested[0]["type"] as? String == "command",
          nested[0]["command"] as? String == command
    else {
        fail("hooks.json 结构不符合 Codex 的契约")
    }

    // 别人的 handler 必须被认成冲突而不是覆盖掉。
    var withForeign = root0
    var foreignHooks = hooks
    foreignHooks["PermissionRequest"] = entries + [[
        "matcher": "",
        "hooks": [["type": "command", "command": "/opt/other/gate"]],
    ]]
    withForeign["hooks"] = foreignHooks
    guard let foreignData = try? JSONSerialization.data(
        withJSONObject: withForeign
    ), (try? foreignData.write(to: hooksURL)) != nil else {
        fail("写入冲突 fixture 失败")
    }
    guard case .conflict(let descriptions) = status(),
          descriptions.count == 1,
          descriptions[0].contains("/opt/other/gate")
    else {
        fail("第三方 handler 应报冲突")
    }
    guard (try? CodexHookConfiguration.install(
        at: hooksURL,
        hookCommand: command,
        isCodexAvailable: { true }
    )) == false else {
        fail("有冲突时不应改写配置")
    }

    // 卸载只摘自家那条，第三方的必须原样留下。
    guard (try? CodexHookConfiguration.uninstall(at: hooksURL)) == true else {
        fail("卸载应返回已改动")
    }
    guard let after = try? Data(contentsOf: hooksURL),
          let afterRoot = try? JSONSerialization.jsonObject(with: after) as? [String: Any],
          let afterHooks = afterRoot["hooks"] as? [String: Any],
          let afterEntries = afterHooks["PermissionRequest"] as? [[String: Any]],
          afterEntries.count == 1,
          let afterNested = afterEntries[0]["hooks"] as? [[String: Any]],
          afterNested[0]["command"] as? String == "/opt/other/gate"
    else {
        fail("卸载误伤了第三方 handler")
    }
    guard CodexHookConfiguration.authenticationToken(for: hooksURL) == nil else {
        fail("卸载后应清除令牌")
    }

    // Codex 未安装时不该往用户目录写任何东西。
    let untouchedURL = root.appendingPathComponent("absent.json")
    guard (try? CodexHookConfiguration.install(
        at: untouchedURL,
        hookCommand: command,
        isCodexAvailable: { false }
    )) == false,
    !FileManager.default.fileExists(atPath: untouchedURL.path)
    else {
        fail("Codex 缺席时不应写配置")
    }

    // MARK: hook 命令行

    // 路径含空白无法在按空白切分的 command 里安全表达，宁可不装。
    guard codexHookCommand(
        executableURL: URL(fileURLWithPath: "/opt/Thread Helm/ThreadHelm")
    ) == nil else {
        fail("含空白的可执行路径不应生成 hook 命令")
    }

    // 令牌的读写两端必须落在同一个文件上。写入端是受管 scope
    // （固定 <home>/.codex），读取端若跟着 CODEX_HOME 走就会错位：
    // hook 继承 Codex 的环境、常驻面板由 launchd 拉起看不到该变量，
    // 两边读不同文件 → 403 → 闸门静默失效。
    let fakeHome = URL(fileURLWithPath: "/var/threadhelm-selftest-home")
    guard CodexHookConfiguration.defaultHooksURL(homeDirectory: fakeHome).path
        == "/var/threadhelm-selftest-home/.codex/hooks.json"
    else {
        fail("默认 hooks 路径应固定挂在 home 下")
    }
    setenv("CODEX_HOME", "/var/threadhelm-selftest-elsewhere", 1)
    defer { unsetenv("CODEX_HOME") }
    guard CodexHookConfiguration.defaultHooksURL(homeDirectory: fakeHome).path
        == "/var/threadhelm-selftest-home/.codex/hooks.json"
    else {
        fail("CODEX_HOME 不应改变令牌与配置的读取位置")
    }

    // MARK: 转发进程

    func runHook(
        arguments: [String],
        input: Data?,
        token: String?,
        outcome: CodexPermissionHookOutcome
    ) -> (handled: Bool, output: String) {
        var written = ""
        let handled = runCodexPermissionHookCommandIfRequested(
            arguments: arguments,
            readInput: { input },
            postDecision: { _, _ in outcome },
            resolveToken: { token },
            writeOutput: { written += $0 }
        )
        return (handled, written)
    }

    guard runHook(
        arguments: ["ThreadHelm"],
        input: Data("{}".utf8),
        token: "t",
        outcome: .noDecision
    ).handled == false else {
        fail("没有旗标时不应接管进程")
    }

    let decided = runHook(
        arguments: ["ThreadHelm", CodexHookConstants.hookCommandFlag],
        input: Data(permissionFixture.utf8),
        token: "t",
        outcome: .decision(Data("{\"ok\":1}".utf8))
    )
    guard decided.handled, decided.output == "{\"ok\":1}" else {
        fail("裁决应原样写回 stdout")
    }

    // 闸门连不上时输出空裁决而不是空字符串：Codex 需要一份可解析的
    // 输出才会干净地回落到自己的批准 UI。
    for (label, input, outcome) in [
        ("面板离线", Data(permissionFixture.utf8), CodexPermissionHookOutcome.noDecision),
        ("stdin 为空", Data(), .noDecision),
        ("stdin 缺失", nil as Data?, .noDecision),
    ] as [(String, Data?, CodexPermissionHookOutcome)] {
        let result = runHook(
            arguments: ["ThreadHelm", CodexHookConstants.hookCommandFlag],
            input: input,
            token: "t",
            outcome: outcome
        )
        guard result.handled,
              result.output == CodexHookConstants.noDecisionOutput
        else {
            fail("\(label)时未输出空裁决")
        }
    }

    // 没有令牌就不该把 payload 发出去——端口上可能是别的进程。
    var postWasAttempted = false
    _ = runCodexPermissionHookCommandIfRequested(
        arguments: ["ThreadHelm", CodexHookConstants.hookCommandFlag],
        readInput: { Data(permissionFixture.utf8) },
        postDecision: { _, token in
            postWasAttempted = true
            return token == nil ? .noDecision : .decision(Data("{}".utf8))
        },
        resolveToken: { nil },
        writeOutput: { _ in }
    )
    guard postWasAttempted,
          postCodexPermissionRequest(
              body: Data(permissionFixture.utf8),
              token: nil
          ) == .noDecision
    else {
        fail("缺少令牌时不应发出请求")
    }

    // MARK: 端口路由

    // 两条线路各用各的令牌：任一方配置泄漏都不能让攻击者向另一方
    // 伪造裁决请求。
    let claudeRoute = PermissionHookRoute.claude(token: { "claude-token" })
    let codexRoute = PermissionHookRoute.codex(token: { "codex-token" })
    guard claudeRoute.path != codexRoute.path else { fail("两条线路路径相同") }
    guard claudeRoute.agentID == .claudeCode, codexRoute.agentID == .codex else {
        fail("线路 agentID")
    }
    guard ClaudePermissionHookServer.isAuthenticated(
        headers: [ClaudeHookConstants.authenticationHeader.lowercased(): "codex-token"],
        expectedToken: codexRoute.expectedToken()
    ), !ClaudePermissionHookServer.isAuthenticated(
        headers: [ClaudeHookConstants.authenticationHeader.lowercased(): "claude-token"],
        expectedToken: codexRoute.expectedToken()
    ) else {
        fail("Claude 的令牌不应能打开 Codex 的线路")
    }
    // Codex 的线路必须用 Codex 的编码器：Claude 的 responseBody 会带上
    // Codex 会 fail-closed 的字段。
    guard let routed = codexRoute.encode(.allowOnce, prompt),
          let routedObject = try? JSONSerialization.jsonObject(with: routed)
              as? [String: Any],
          let routedSpecific = routedObject["hookSpecificOutput"] as? [String: Any],
          (routedSpecific["decision"] as? [String: Any])?["updatedInput"] == nil
    else {
        fail("Codex 线路编码")
    }

    // MARK: 版本探测环境

    // codex 是 `#!/usr/bin/env node` 包装脚本。launchd 给的 PATH 里没有
    // node，`--version` 会直接失败 → 版本读不到 → unvalidated → 闸门关闭。
    // 探测子进程必须补上常见的用户级 bin 目录。
    let probeEnvironment = agentVersionProbeEnvironmentForSelfTest(
        base: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
        homeDirectory: URL(fileURLWithPath: "/var/threadhelm-selftest-home")
    )
    let probePaths = (probeEnvironment["PATH"] ?? "").split(separator: ":")
        .map(String.init)
    guard probePaths.contains("/opt/homebrew/bin"),
          probePaths.contains("/usr/local/bin"),
          probePaths.contains("/var/threadhelm-selftest-home/.local/bin"),
          // 原有条目必须保留且仍在前面，不能被我们的补丁挤掉。
          probePaths.prefix(4) == ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    else {
        fail("版本探测 PATH 未补上解释器目录：\(probeEnvironment["PATH"] ?? "nil")")
    }
    // 已有的目录不重复追加，避免 PATH 无限膨胀。
    let alreadyComplete = agentVersionProbeEnvironmentForSelfTest(
        base: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/x/.local/bin"],
        homeDirectory: URL(fileURLWithPath: "/x")
    )
    guard alreadyComplete["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/x/.local/bin"
    else {
        fail("版本探测 PATH 重复追加了已存在的目录")
    }

    // MARK: 呈现闸门

    // Codex 的审批请求不该被「Codex Desktop 是否在跑」挡住：请求来自
    // Codex 自身，纯 CLI 用户同样要能在面板里批。挡住的表现是静默回落
    // 原生 UI，用户只会觉得功能没生效。
    guard shouldPresentPermissionPanel(
        agentID: .codex,
        cachedCodexDesktopRunning: false,
        liveCodexDesktopRunning: false,
        agentCompatibility: .validated
    ) else {
        fail("Codex 审批在 Desktop 未运行时被挡住")
    }
    // 版本未验证仍然不弹：没在这个版本上验过，就不该替它做裁决。
    guard !shouldPresentPermissionPanel(
        agentID: .codex,
        cachedCodexDesktopRunning: true,
        liveCodexDesktopRunning: true,
        agentCompatibility: .unvalidated
    ) else {
        fail("版本未验证时不应接管 Codex 审批")
    }
    // Claude 一侧的既有行为不能被这次改动带偏。
    guard !shouldPresentPermissionPanel(
        agentID: .claudeCode,
        cachedCodexDesktopRunning: false,
        liveCodexDesktopRunning: false,
        agentCompatibility: .validated
    ), shouldPresentPermissionPanel(
        agentID: .claudeCode,
        cachedCodexDesktopRunning: true,
        liveCodexDesktopRunning: true,
        agentCompatibility: .validated
    ) else {
        fail("Claude 的呈现闸门行为被改动带偏")
    }

    // MARK: 队列归属

    // 队列里两家的项要能分开，否则用户不知道自己在批谁的请求。
    let codexItem = ClaudePermissionQueueItem(
        requestID: prompt.requestID,
        interactionKind: .toolApproval,
        title: prompt.title,
        sessionID: prompt.sessionID,
        arrivedAt: Date(),
        agentID: .codex
    )
    let claudeItem = ClaudePermissionQueueItem(
        requestID: UUID(),
        interactionKind: .toolApproval,
        title: "Claude 等你确认",
        sessionID: "87654321-4321-4321-4321-cba987654321",
        arrivedAt: Date()
    )
    guard claudeItem.agentID == .claudeCode else {
        fail("队列项默认应归属 Claude")
    }
    guard codexItem.agentID == .codex else { fail("队列项 agentID") }

    // 归因必须按 agent 过滤：Codex 的待批准请求不能把同名会话 ID 的
    // Claude 任务也标成待确认。
    let queue = ClaudePermissionQueueSnapshot(
        current: codexItem,
        pending: [claudeItem]
    )
    let codexTask = TaskProgressItem(
        title: "Codex 会话",
        kind: .running,
        source: .codex,
        sessionID: prompt.sessionID,
        workingDirectory: prompt.workingDirectory
    )
    guard let codexMetadata = builtInAgentMetadata().first(where: {
        $0.id == .codex
    }),
    let codexSnapshot = agentSessionSnapshot(
        from: codexTask,
        metadata: codexMetadata,
        permissionQueue: queue
    ),
    codexSnapshot.attentionReason == .permission
    else {
        fail("Codex 会话未因待批准而进入 permission 状态")
    }

    let claudeTaskSharingID = TaskProgressItem(
        title: "Claude 会话",
        kind: .running,
        source: .claudeCode,
        sessionID: prompt.sessionID,
        workingDirectory: prompt.workingDirectory
    )
    guard let claudeMetadata = builtInAgentMetadata().first(where: {
        $0.id == .claudeCode
    }),
    let claudeSnapshot = agentSessionSnapshot(
        from: claudeTaskSharingID,
        metadata: claudeMetadata,
        permissionQueue: queue
    ),
    claudeSnapshot.attentionReason != .permission
    else {
        fail("Codex 的待批准请求串到了 Claude 会话上")
    }

    print("codex-hook-self-test ok")
    exit(0)
}
