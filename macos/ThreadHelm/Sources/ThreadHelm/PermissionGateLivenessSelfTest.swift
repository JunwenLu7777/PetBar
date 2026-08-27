//
//  PermissionGateLivenessSelfTest.swift
//  ThreadHelm
//
//  模块职责：锁住「闸门在线」的判定与呈现。这里守的核心是一条反直觉的
//  规则——配置装好了不等于闸门在工作，界面不能把前者说成后者。
//

import Foundation

func runPermissionGateLivenessSelfTest() -> Never {
    func fail(_ message: String) -> Never {
        fputs("permission-gate-liveness-self-test failed: \(message)\n", stderr)
        exit(1)
    }

    // MARK: 判定

    // 装好了但从未收到过请求——正是 Codex 未信任、ZCode 配置被丢弃那些
    // 静默失效场景的样子。绝不能报成在线。
    guard permissionGateLiveness(
        capability: .supported,
        integrationStatus: .installed,
        record: nil
    ) == .neverObserved else {
        fail("装好但无观测记录时应报尚未验证")
    }
    guard permissionGateLiveness(
        capability: .supported,
        integrationStatus: .installed,
        record: PermissionGateLivenessRecord(lastRequestAt: nil)
    ) == .neverObserved else {
        fail("空记录应等同于无记录")
    }

    let observedAt = Date(timeIntervalSince1970: 1_787_800_000)
    guard permissionGateLiveness(
        capability: .supported,
        integrationStatus: .installed,
        record: PermissionGateLivenessRecord(lastRequestAt: observedAt)
    ) == .verified(lastRequestAt: observedAt) else {
        fail("收到过请求应报已验证")
    }

    // 没装、或平台不支持，就不该谈在线与否——那会在界面上凭空多出一条
    // 用户无法处理的告警。
    for (capability, status) in [
        (AgentCapabilityStatus.unknown, AgentIntegrationStatus.installed),
        (.unsupported, .installed),
        (.supported, .notInstalled),
        (.supported, .needsRepair),
        (.supported, .notManaged),
    ] as [(AgentCapabilityStatus, AgentIntegrationStatus)] {
        guard permissionGateLiveness(
            capability: capability,
            integrationStatus: status,
            record: PermissionGateLivenessRecord(lastRequestAt: observedAt)
        ) == .notApplicable else {
            fail("capability=\(capability) status=\(status) 不应参与在线判定")
        }
    }
    guard permissionGateLiveness(
        capability: .supported,
        integrationStatus: nil,
        record: nil
    ) == .notApplicable else {
        fail("集成状态未知时不应下结论")
    }

    // MARK: 文案

    guard permissionGateLivenessSummary(.notApplicable, agentID: .cursor) == nil
    else {
        fail("不适用时不应产出文案")
    }
    // 措辞必须是「尚未验证」而不是「未生效」：也可能只是还没触发过审批，
    // 把没证实说成已失效同样是误导。
    guard let never = permissionGateLivenessSummary(
        .neverObserved,
        agentID: .zcode
    ), never.contains("尚未验证"), !never.contains("未生效") else {
        fail("尚未验证的文案措辞不当")
    }
    // Codex 有一个用户能立刻执行的动作，文案要说出来。
    guard let codexNever = permissionGateLivenessSummary(
        .neverObserved,
        agentID: .codex
    ), codexNever.contains("Trust") else {
        fail("Codex 未验证时应提示去信任")
    }
    guard let verified = permissionGateLivenessSummary(
        .verified(lastRequestAt: observedAt),
        agentID: .zcode,
        now: observedAt.addingTimeInterval(120)
    ), verified.contains("已验证在线"), verified.contains("2 分钟前") else {
        fail("已验证文案")
    }

    // MARK: 存储位置

    // 安装脚本会 rm -rf 掉 Library/Caches 下的整个产品目录。记录落在那里
    // 就会每次升级归零，把「尚未验证」从罕见告警变成每次升级都出现的噪音。
    let defaultPath = PermissionGateLivenessStore.defaultFileURL().path
    guard !defaultPath.contains("/Library/Caches/") else {
        fail("在线记录不能放在安装时会被清空的缓存目录：\(defaultPath)")
    }
    guard defaultPath.hasSuffix(".json") else {
        fail("默认记录路径异常：\(defaultPath)")
    }

    // MARK: 存储

    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("threadhelm-gate-liveness-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("liveness.json")

    var clock = Date(timeIntervalSince1970: 1_787_800_000)
    let store = PermissionGateLivenessStore(
        fileURL: fileURL,
        now: { clock },
        writeThrottle: 60
    )
    guard store.record(for: .codex) == nil else { fail("初始应为空") }

    store.recordRequest(agentID: .codex)
    guard store.record(for: .codex)?.lastRequestAt == clock else {
        fail("请求未记录")
    }

    // 节流窗口内的第二次请求仍要更新内存，只是不重复落盘。
    clock = clock.addingTimeInterval(5)
    store.recordRequest(agentID: .codex)
    guard store.record(for: .codex)?.lastRequestAt == clock else {
        fail("节流不应阻止内存更新")
    }

    // 裁决是低频且最有说服力的证据，必须立刻落盘。
    clock = clock.addingTimeInterval(5)
    store.recordDecision(agentID: .codex)
    let reloaded = PermissionGateLivenessStore(
        fileURL: fileURL,
        now: { clock }
    )
    guard reloaded.record(for: .codex)?.lastDecisionAt == clock,
          reloaded.record(for: .codex)?.lastRequestAt != nil
    else {
        fail("裁决未立即落盘或重载丢失请求时间")
    }

    // 各家互不干扰。
    store.recordRequest(agentID: .zcode)
    guard store.record(for: .zcode)?.lastRequestAt != nil,
          store.record(for: .claudeCode) == nil
    else {
        fail("不同 agent 的记录串了")
    }

    // 坏文件不能让面板崩，也不能被当成有效记录——那会把没连通的闸门
    // 说成在线。
    try? Data("not json".utf8).write(to: fileURL)
    guard PermissionGateLivenessStore(fileURL: fileURL).record(for: .codex)
        == nil
    else {
        fail("损坏的记录文件不应被采信")
    }
    // 不认识的 agent 名会被 AgentID 折成 unknown，收进来会在界面上多出
    // 一行假 agent。
    try? Data(
        #"{"schemaVersion":1,"agents":{"bogus!!":{"lastRequestAt":1}}}"#.utf8
    ).write(to: fileURL)
    let bogus = PermissionGateLivenessStore(fileURL: fileURL)
    guard bogus.snapshot().isEmpty else {
        fail("无效 agent 名不应进入记录：\(bogus.snapshot())")
    }

    // MARK: 合入运行时状态

    let metadata = builtInAgentMetadata().first { $0.id == .codex }!
    let base = AgentRuntimeStatus(
        metadata: metadata,
        discovery: AgentDiscovery(
            isInstalled: true,
            version: "0.150.1",
            compatibility: .validated
        ),
        integrationStatus: .installed,
        diagnostics: AgentDiagnostics(
            health: .healthy,
            summary: "已发现 Codex",
            counters: [:]
        ),
        activeSessionCount: 0,
        attentionCount: 0
    )
    guard base.permissionGateLiveness == .notApplicable else {
        fail("默认值应为不适用，避免既有构造点凭空声称在线")
    }
    let merged = agentRuntimeStatusesWithGateLiveness(
        [base],
        records: [.codex: PermissionGateLivenessRecord(
            lastRequestAt: observedAt
        )]
    )
    guard merged.first?.permissionGateLiveness
        == .verified(lastRequestAt: observedAt)
    else {
        fail("运行时状态未合入在线记录")
    }
    let withoutRecord = agentRuntimeStatusesWithGateLiveness([base], records: [:])
    guard withoutRecord.first?.permissionGateLiveness == .neverObserved else {
        fail("无记录时运行时状态应报尚未验证")
    }

    print("permission-gate-liveness-self-test ok")
    exit(0)
}
