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

    // 没装、或平台明确不支持，就不该谈在线与否——那会在界面上凭空多出
    // 一条用户无法处理的告警。
    for (capability, status) in [
        (AgentCapabilityStatus.unsupported, AgentIntegrationStatus.installed),
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
    // capability=unknown 现在最常见的来源是版本漂移把声明折叠了一层。
    // 此时若手里正有实测记录，正是最该讲出来的时候——原来这条会被
    // 一并吞掉，于是 ZCode 升到 3.9.2 之后闸门状态整列消失。没有记录
    // 时仍然不出声：凭一个折叠过的声明生出告警是另一种噪音。
    guard permissionGateLiveness(
        capability: .unknown,
        integrationStatus: .installed,
        record: PermissionGateLivenessRecord(lastRequestAt: observedAt)
    ) == .verified(lastRequestAt: observedAt) else {
        fail("能力被版本折叠时不应吞掉实测记录")
    }
    guard permissionGateLiveness(
        capability: .unknown,
        integrationStatus: .installed,
        record: nil
    ) == .notApplicable else {
        fail("能力被折叠且没有记录时不应报警")
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
    // 「收到过请求」只证明通道通了，不证明拒绝拦得住。文案不能把前者
    // 说成后者，还要指出去哪儿完成最后一步确认。
    guard let live = permissionGateLivenessSummary(
        .verified(lastRequestAt: observedAt),
        agentID: .zcode,
        now: observedAt.addingTimeInterval(120)
    ), live.contains("已连通"), live.contains("2 分钟前"),
    !live.contains("已验证在线") else {
        fail("已连通文案不应自称已验证")
    }
    guard let verified = permissionGateLivenessSummary(
        .semanticsVerified(confirmedAt: observedAt),
        agentID: .zcode,
        now: observedAt.addingTimeInterval(120)
    ), verified.contains("已验证在线"), verified.contains("拦住") else {
        fail("已验证文案")
    }
    guard let ineffective = permissionGateLivenessSummary(
        .ineffective(reportedAt: observedAt),
        agentID: .cursor,
        now: observedAt
    ), ineffective.contains("未生效") else {
        fail("失效文案")
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

    // MARK: 证据带版本

    // 记录不带版本就等于没记：升级之后旧证据会替新版本背书，那还是版本
    // 猜测，只是方向反了。
    let stampedURL = root.appendingPathComponent("stamped.json")
    var stampedClock = Date(timeIntervalSince1970: 1_787_900_000)
    var probedVersions: [AgentID: String] = [.zcode: "version=3.9.2"]
    let stamped = PermissionGateLivenessStore(
        fileURL: stampedURL,
        now: { stampedClock },
        writeThrottle: 0,
        versionSignatureProvider: { probedVersions[$0] }
    )
    stamped.recordRequest(agentID: .zcode)
    guard stamped.record(for: .zcode)?.observedVersion == "version=3.9.2" else {
        fail("请求未带上版本签名")
    }
    // 版本探不到时宁可不带签名，也不要瞎填一个：判定会当成过期证据。
    stamped.recordRequest(agentID: .omp)
    guard stamped.record(for: .omp)?.observedVersion == nil,
          stamped.record(for: .omp)?.lastRequestAt != nil
    else {
        fail("版本未知时不应编造签名")
    }
    stampedClock = stampedClock.addingTimeInterval(30)
    stamped.recordSemanticsVerified(
        agentID: .zcode,
        versionSignature: "version=3.9.2"
    )
    let stampedReloaded = PermissionGateLivenessStore(
        fileURL: stampedURL,
        now: { stampedClock }
    )
    guard let persisted = stampedReloaded.record(for: .zcode),
          persisted.semanticsVerifiedAt == stampedClock,
          persisted.semanticsVerifiedVersion == "version=3.9.2",
          persisted.observedVersion == "version=3.9.2"
    else {
        fail("语义验证未落盘或丢了版本")
    }
    stampedClock = stampedClock.addingTimeInterval(30)
    stamped.recordSemanticsRefuted(
        agentID: .cursor,
        versionSignature: "desktop=3.17.21"
    )
    guard stamped.record(for: .cursor)?.semanticsRefutedVersion
        == "desktop=3.17.21"
    else {
        fail("失效报告未落盘")
    }

    // schemaVersion 1 的旧记录没有版本戳。读进来要保留时间、但版本必须
    // 是 nil，否则升级前的证据会替升级后的版本背书。
    let legacyURL = root.appendingPathComponent("legacy.json")
    try? Data(
        #"{"schemaVersion":1,"agents":{"zcode":{"lastRequestAt":1787800000}}}"#
            .utf8
    ).write(to: legacyURL)
    let legacy = PermissionGateLivenessStore(fileURL: legacyURL)
    guard legacy.record(for: .zcode)?.lastRequestAt != nil,
          legacy.record(for: .zcode)?.observedVersion == nil
    else {
        fail("旧格式记录读取有误")
    }

    // MARK: 证据 → 探测结论

    let signature = "version=3.9.2"
    let requestOnly = PermissionGateLivenessRecord(
        lastRequestAt: observedAt,
        observedVersion: signature
    )
    guard agentProbeOutcome(
        record: requestOnly,
        currentVersionSignature: signature
    ) == .channelLive else {
        fail("同版本上收到过请求应判为通道活着")
    }
    // 单向：证据消失只能回到「未探测」，绝不能报成坏了。面板重启、记录
    // 被清、用户这段时间没触发审批，都会让证据消失；把没看见当成坏了，
    // 每次重启都会误报一次失效。
    for (record, signatureUnderTest) in [
        (nil as PermissionGateLivenessRecord?, signature),
        (requestOnly, "version=3.9.3"),
        (PermissionGateLivenessRecord(lastRequestAt: observedAt), signature),
        (requestOnly, nil as String?),
    ] as [(PermissionGateLivenessRecord?, String?)] {
        guard agentProbeOutcome(
            record: record,
            currentVersionSignature: signatureUnderTest
        ) == .notProbed else {
            fail("缺证据或证据过期时只能回到未探测")
        }
    }
    var verifiedRecord = requestOnly
    verifiedRecord.semanticsVerifiedAt = observedAt
    verifiedRecord.semanticsVerifiedVersion = signature
    guard agentProbeOutcome(
        record: verifiedRecord,
        currentVersionSignature: signature
    ) == .semanticsVerified,
    agentProbeOutcome(
        record: verifiedRecord,
        currentVersionSignature: "version=3.9.3"
    ) == .notProbed
    else {
        fail("语义验证只在被验证过的那个版本上成立")
    }
    var refutedRecord = verifiedRecord
    refutedRecord.semanticsRefutedAt = observedAt.addingTimeInterval(60)
    refutedRecord.semanticsRefutedVersion = signature
    guard case .channelBroken = agentProbeOutcome(
        record: refutedRecord,
        currentVersionSignature: signature
    ) else {
        fail("用户报告失效后应判为通道坏了")
    }
    // 用户先报失效、后来又确认拦住了（比如上游修好了），新的确认要能翻案。
    var reverifiedRecord = refutedRecord
    reverifiedRecord.semanticsVerifiedAt = refutedRecord.semanticsRefutedAt?
        .addingTimeInterval(60)
    guard agentProbeOutcome(
        record: reverifiedRecord,
        currentVersionSignature: signature
    ) == .semanticsVerified else {
        fail("更晚的确认应能翻案")
    }

    // MARK: 证据 → 兼容性

    let driftedZCode = AgentDiscovery(
        isInstalled: true,
        version: "3.9.2",
        compatibility: .unvalidated,
        versionComponents: [
            AgentVersionComponent(key: "version", label: "Version", value: "3.9.2"),
            AgentVersionComponent(key: "build", label: "Build", value: "3.9.2.1"),
        ]
    )
    let zcodeSignature = agentVersionSignature(driftedZCode.versionComponents)
    guard zcodeSignature == "build=3.9.2.1;version=3.9.2" else {
        fail("版本签名不稳定：\(String(describing: zcodeSignature))")
    }
    // 没有证据时按原样返回：这一层只做加强，不改既有判定。
    guard probeAdjustedDiscovery(
        driftedZCode,
        agentID: .zcode,
        record: nil
    ) == driftedZCode else {
        fail("没有证据时不应改动发现结果")
    }
    let liveRecord = PermissionGateLivenessRecord(
        lastRequestAt: observedAt,
        observedVersion: zcodeSignature
    )
    // 闸门真把请求送到过面板，比版本号对不上更能说明这套集成还在工作。
    guard probeAdjustedDiscovery(
        driftedZCode,
        agentID: .zcode,
        record: liveRecord
    ).compatibility == .unknown else {
        fail("活体证据应把版本漂移的结论抬到未知而非未验证")
    }
    var zcodeVerified = liveRecord
    zcodeVerified.semanticsVerifiedAt = observedAt
    zcodeVerified.semanticsVerifiedVersion = zcodeSignature
    guard probeAdjustedDiscovery(
        driftedZCode,
        agentID: .zcode,
        record: zcodeVerified
    ).compatibility == .validated,
    probeAdjustedDiscovery(
        driftedZCode,
        agentID: .zcode,
        record: zcodeVerified
    ).versionComponents == driftedZCode.versionComponents
    else {
        fail("亲测通过应判为已验证，且不能动版本分量")
    }
    // 未安装的不参与：没有宿主就没有通道，谈证据没有意义。
    let absent = AgentDiscovery(
        isInstalled: false,
        version: nil,
        compatibility: .unknown
    )
    guard probeAdjustedDiscovery(
        absent,
        agentID: .zcode,
        record: zcodeVerified
    ) == absent else {
        fail("未安装时不应被证据改写")
    }

    // 语义结论按版本收口：换了版本就只剩连通性，不能让旧确认一直背书。
    guard permissionGateLiveness(
        capability: .supported,
        integrationStatus: .installed,
        record: zcodeVerified,
        currentVersionSignature: zcodeSignature
    ) == .semanticsVerified(confirmedAt: observedAt),
    permissionGateLiveness(
        capability: .supported,
        integrationStatus: .installed,
        record: zcodeVerified,
        currentVersionSignature: "version=9.9.9"
    ) == .verified(lastRequestAt: observedAt)
    else {
        fail("语义结论未按版本收口")
    }
    // 用户能确认「拒绝拦住了」，前提就是确实发生过一次审批。所以语义
    // 结论自成证据，不该因为记录里缺了 lastRequestAt 就退回「尚未验证」。
    // 「报告没拦住」尤其如此：那是最该讲出来的一句话，而它出现时能力
    // 往往正被版本折叠着。
    let refutedOnly = PermissionGateLivenessRecord(
        semanticsRefutedAt: observedAt,
        semanticsRefutedVersion: zcodeSignature
    )
    guard permissionGateLiveness(
        capability: .unknown,
        integrationStatus: .installed,
        record: refutedOnly,
        currentVersionSignature: zcodeSignature
    ) == .ineffective(reportedAt: observedAt) else {
        fail("失效报告不应被吞掉")
    }
    let verifiedOnly = PermissionGateLivenessRecord(
        semanticsVerifiedAt: observedAt,
        semanticsVerifiedVersion: zcodeSignature
    )
    guard permissionGateLiveness(
        capability: .supported,
        integrationStatus: .installed,
        record: verifiedOnly,
        currentVersionSignature: zcodeSignature
    ) == .semanticsVerified(confirmedAt: observedAt) else {
        fail("亲测结论不应要求另有请求记录")
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
