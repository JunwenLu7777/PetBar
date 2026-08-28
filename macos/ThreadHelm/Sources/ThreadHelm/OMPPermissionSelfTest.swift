//
//  OMPPermissionSelfTest.swift
//  ThreadHelm
//
//  模块职责：锁住 OMP 审批闸门的契约。这里守的核心是一条容易写错的
//  规则——OMP 只有在 handler 真的失败时才自动 block，而 handler 里一个
//  catch-all 就能把失败变成静默放行。
//

import Foundation

func runOMPPermissionSelfTest() -> Never {
    func fail(_ message: String) -> Never {
        fputs("omp-permission-self-test failed: \(message)\n", stderr)
        exit(1)
    }

    // MARK: 裁决编码

    func decision(
        _ decision: ClaudePermissionUserDecision
    ) -> [String: Any]? {
        guard let data = OMPPermissionProtocol.responseBody(for: decision),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return object as? [String: Any]
    }

    guard let allow = decision(.allowOnce),
          allow["block"] as? Bool == false
    else {
        fail("allow 编码")
    }
    guard let deny = decision(.deny("这条命令会删掉生产目录")),
          deny["block"] as? Bool == true,
          deny["reason"] as? String == "这条命令会删掉生产目录"
    else {
        fail("deny 编码")
    }
    guard let emptyDeny = decision(.deny("  ")),
          (emptyDeny["reason"] as? String)?.isEmpty == false
    else {
        fail("空拒绝理由未回落到默认文案")
    }

    // OMP 没有可回落的原生批准界面。「回到 OMP 处理」若编码成放行，
    // 用户点它反而会让工具直接执行——与他的意图正相反。
    guard let fallback = decision(.nativeFallback),
          fallback["block"] as? Bool == true
    else {
        fail("交还原生在 OMP 上必须仍是拦截")
    }
    // OMP 不接受改写入参与长期授权回执，只能落到最接近的语义。
    guard decision(.submitAnswers(["a": "b"]))?["block"] as? Bool == false,
          decision(.allowWithSuggestion(["type": "addRules"]))?["block"]
            as? Bool == false
    else {
        fail("无对应语义的裁决未落到放行")
    }

    // MARK: 超时决策

    // 默认 30 秒等于要求用户守在屏幕前，必须抬高。
    guard case .raise(let from, let to) = ompToolCallTimeoutPlan(
        currentValue: 30_000
    ), from == 30_000, to >= 300_000 else {
        fail("默认 30 秒未被抬高")
    }
    // 用户没设过这个键时，原值要如实记成「没有」，卸载才知道该清掉而
    // 不是写回一个他从未写过的数字。
    guard case .raise(let missingFrom, _) = ompToolCallTimeoutPlan(
        currentValue: nil
    ), missingFrom == nil else {
        fail("未设置时的原值应为 nil")
    }
    // 用户自己调得更大就别动他的配置。
    guard ompToolCallTimeoutPlan(currentValue: 900_000)
        == .leaveAsIs(current: 900_000)
    else {
        fail("不应覆盖用户已设的更大值")
    }
    // 扩展必须比 OMP 的上限先收手：被 OMP 杀掉时用户只会看到
    // "Extension ... timed out"，由我们自己拒绝才能说清原因。
    guard OMPPermissionHookConstants.extensionDeadlineMilliseconds
        < OMPPermissionHookConstants.desiredToolCallTimeoutMilliseconds
    else {
        fail("扩展截止时间不早于 OMP 超时上限")
    }

    guard OMPConfigCommand.parseTimeoutOutput("\u{1B}[36m600000\u{1B}[39m")
        == 600_000,
        OMPConfigCommand.parseTimeoutOutput("30000\n") == 30_000,
        OMPConfigCommand.parseTimeoutOutput("no digits here") == nil
    else {
        fail("超时读数解析")
    }

    // MARK: 受管设置记录

    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("threadhelm-omp-selftest-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try? FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )

    guard OMPManagedSettingsRecord.previousTimeout(directory: root) == nil else {
        fail("初始不应有受管记录")
    }
    try? OMPManagedSettingsRecord.write(previousTimeout: 30_000, directory: root)
    guard let recorded = OMPManagedSettingsRecord.previousTimeout(
        directory: root
    ), recorded == 30_000 else {
        fail("原值未记录")
    }
    OMPManagedSettingsRecord.remove(directory: root)
    // 「用户没设过」与「我们没改过」是两种状态，还原动作不同：前者要
    // 清掉这个键，后者根本不该动。双层 Optional 就是为了区分它们。
    try? OMPManagedSettingsRecord.write(previousTimeout: nil, directory: root)
    let absent = OMPManagedSettingsRecord.previousTimeout(directory: root)
    guard let unwrapped = absent, unwrapped == nil else {
        fail("未设置状态未被如实记录")
    }
    OMPManagedSettingsRecord.remove(directory: root)
    guard OMPManagedSettingsRecord.previousTimeout(directory: root) == nil else {
        fail("记录未被清除")
    }

    // MARK: 令牌

    guard AgentPermissionTokenStore.omp.token(directory: root) == nil else {
        fail("空目录不应有令牌")
    }
    guard let created = try? AgentPermissionTokenStore.omp.ensureToken(
        directory: root
    ), !created.isEmpty else {
        fail("首次应写出令牌")
    }
    guard (try? AgentPermissionTokenStore.omp.ensureToken(directory: root)) == created
    else {
        fail("重复安装不应轮换令牌")
    }
    var tokenStat = stat()
    let tokenPath = AgentPermissionTokenStore.omp.tokenURL(directory: root).path
    guard lstat(tokenPath, &tokenStat) == 0,
          (tokenStat.st_mode & S_IRWXG) == 0,
          (tokenStat.st_mode & S_IRWXO) == 0
    else {
        fail("令牌文件权限未收紧到 owner-only")
    }
    AgentPermissionTokenStore.omp.removeToken(directory: root)
    guard AgentPermissionTokenStore.omp.token(directory: root) == nil else {
        fail("卸载后应清除令牌")
    }

    // MARK: 扩展脚本

    // 这一段是整个设计的要害。OMP 只有在 handler 真的失败时才自动
    // block；handler 里一个 catch-all 后返回 undefined 就等于放行，而且
    // 完全静默。所以每条失败路径都必须显式写出拦截。
    let scopeRoot = root.appendingPathComponent("scope", isDirectory: true)
    // 超时读写走 `omp config set`，那是跨进程的全局副作用——AgentIntegrationScope
    // 只隔离文件写入，隔离不了它。不注入内存实现的话，跑一次自测就会改掉
    // 本机 OMP 的真实设置。
    let timeoutStore = InMemoryOMPToolCallTimeoutStore(value: 30_000)
    let adapter = OMPAgentAdapter(
        discovery: {
            AgentDiscovery(
                isInstalled: true,
                version: "17.3.5",
                compatibility: .validated
            )
        },
        executablePath: { "/opt/threadhelm/ThreadHelm" },
        resumeSession: { _ in false },
        timeoutStore: timeoutStore
    )
    let scope = AgentIntegrationScope.isolated(at: scopeRoot)
    guard (try? adapter.installIntegration(in: scope)) == .installed else {
        fail("扩展安装失败")
    }

    // 安装应当抬高超时并记下原值。
    guard timeoutStore.value == OMPPermissionHookConstants
        .desiredToolCallTimeoutMilliseconds,
        timeoutStore.writeCount == 1
    else {
        fail("安装未抬高 handler 超时：\(String(describing: timeoutStore.value))")
    }
    // 重复安装不能再记一次原值——否则第二次会把我们自己写的值当成
    // 用户的原值，卸载时就还原不回去了。
    _ = try? adapter.installIntegration(in: scope)
    guard timeoutStore.writeCount == 1 else {
        fail("重复安装重复改写了超时")
    }
    // 卸载要还原。用户原本没设过这个键，还原就是清掉它，而不是写回
    // 一个他从未写过的数字。
    let cleanStore = InMemoryOMPToolCallTimeoutStore(value: nil)
    let cleanRoot = root.appendingPathComponent("clean", isDirectory: true)
    let cleanAdapter = OMPAgentAdapter(
        discovery: {
            AgentDiscovery(
                isInstalled: true,
                version: "17.3.5",
                compatibility: .validated
            )
        },
        executablePath: { "/opt/threadhelm/ThreadHelm" },
        resumeSession: { _ in false },
        timeoutStore: cleanStore
    )
    let cleanScope = AgentIntegrationScope.isolated(at: cleanRoot)
    _ = try? cleanAdapter.installIntegration(in: cleanScope)
    _ = try? cleanAdapter.uninstallIntegration(in: cleanScope)
    guard cleanStore.resetCount == 1, cleanStore.value == nil else {
        fail("卸载未把用户从未设过的键清掉")
    }
    // 用户自己调得更大时，安装不该动它，卸载也不该还原。
    let respectedStore = InMemoryOMPToolCallTimeoutStore(value: 900_000)
    let respectedRoot = root.appendingPathComponent("respect", isDirectory: true)
    let respectedAdapter = OMPAgentAdapter(
        discovery: {
            AgentDiscovery(
                isInstalled: true,
                version: "17.3.5",
                compatibility: .validated
            )
        },
        executablePath: { "/opt/threadhelm/ThreadHelm" },
        resumeSession: { _ in false },
        timeoutStore: respectedStore
    )
    let respectedScope = AgentIntegrationScope.isolated(at: respectedRoot)
    _ = try? respectedAdapter.installIntegration(in: respectedScope)
    _ = try? respectedAdapter.uninstallIntegration(in: respectedScope)
    guard respectedStore.value == 900_000,
          respectedStore.writeCount == 0,
          respectedStore.resetCount == 0
    else {
        fail("不该改动用户自己设的更大值")
    }
    let scriptURL = scopeRoot.appendingPathComponent(
        ".omp/agent/extensions/threadhelm-state-observer/index.ts"
    )
    guard let script = try? String(contentsOf: scriptURL, encoding: .utf8)
    else {
        fail("读不到扩展脚本")
    }

    // tool_call 必须 await 裁决而不是 fire-and-forget。
    guard script.contains("requestApproval"),
          script.contains("await requestApproval")
    else {
        fail("tool_call 未接入审批闸门")
    }
    // 每一条失败路径都要显式拦截：读不到令牌、非 200、裁决读不懂、
    // 超时、连不上。
    let blockOccurrences = script.components(separatedBy: "block: true").count - 1
    guard blockOccurrences >= 5 else {
        fail("失败路径未全部显式拦截，只找到 \(blockOccurrences) 处")
    }
    // 只有明确的 block:false 才放行。裁决体读不懂时当成同意是最危险的
    // 那种错。
    guard script.contains("verdict.block === false") else {
        fail("放行未要求裁决显式为 false")
    }
    // 令牌路径写进脚本，令牌本身不能写进去——扩展文件不是机密文件。
    // 路径必须落在这次安装的 scope 里：写死真实家目录会让隔离安装出来的
    // 扩展去读本机令牌，而每个 profile 也各有自己那一份。
    let expectedTokenPath = AgentPermissionTokenStore.omp.tokenURL(
        directory: scopeRoot.appendingPathComponent(
            OMPProfileScope.defaultAgentRelativePath
        )
    ).path
    guard script.contains(expectedTokenPath) else {
        let tokenLine = script
            .components(separatedBy: "\n")
            .first { $0.contains("TOKEN_PATH") } ?? "(找不到 TOKEN_PATH 行)"
        fail("扩展脚本未写入令牌路径 \(expectedTokenPath)；实际：\(tokenLine)")
    }
    guard !script.contains(created) else {
        fail("扩展脚本里不应内嵌令牌明文")
    }
    guard script.contains(OMPPermissionHookConstants.url) else {
        fail("扩展脚本缺少闸门地址")
    }

    // MARK: 端口路由

    let ompRoute = PermissionHookRoute.omp(token: { "omp-token" })
    guard ompRoute.agentID == .omp else { fail("线路 agentID") }
    for foreign in [
        PermissionHookRoute.claude(token: { "c" }),
        .codex(token: { "x" }),
        .zcode(token: { "z" }),
    ] {
        guard foreign.path != ompRoute.path else {
            fail("OMP 线路路径与 \(foreign.agentID.rawValue) 冲突")
        }
    }
    for foreign in ["c", "x", "z"] {
        guard !ClaudePermissionHookServer.isAuthenticated(
            headers: [
                ClaudeHookConstants.authenticationHeader.lowercased(): foreign,
            ],
            expectedToken: ompRoute.expectedToken()
        ) else {
            fail("别家的令牌不应能打开 OMP 的线路")
        }
    }
    // 入向复用 Claude 的解析器（扩展负责整形），出向必须是 OMP 的形状。
    let payload = """
    {"hook_event_name":"PermissionRequest","tool_name":"Bash",
     "tool_use_id":"omp-1","session_id":"s","cwd":"/tmp",
     "tool_input":{"command":"rm -rf /","description":"清理"}}
    """
    guard let prompt = try? ompRoute.decode(Data(payload.utf8)),
          prompt.agentID == .omp,
          prompt.toolName == "Bash",
          prompt.message == "清理",
          prompt.title.contains("OMP")
    else {
        fail("OMP 线路解析")
    }
    guard let encoded = ompRoute.encode(.deny("不行"), prompt),
          let encodedObject = try? JSONSerialization.jsonObject(with: encoded)
            as? [String: Any],
          encodedObject["block"] as? Bool == true,
          encodedObject["hookSpecificOutput"] == nil
    else {
        fail("OMP 线路编码应是 {block, reason} 而非 Claude 的形状")
    }

    print("omp-permission-self-test ok")
    exit(0)
}
