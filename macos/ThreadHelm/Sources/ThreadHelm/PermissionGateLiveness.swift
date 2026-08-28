//
//  PermissionGateLiveness.swift
//  ThreadHelm
//
//  模块职责：记录并呈现「审批闸门是否真的在工作」。
//
//  三家厂商的闸门都可能装上却不生效，而且失效全是静默的：Codex 在用户
//  信任那份 hooks.json 之前完全不加载它；ZCode 的 hooks 段一旦有 schema
//  错误就会丢弃整份用户配置；Claude 那边曾被另一个 command hook 占位。
//  这三种情况下配置文件都在、状态都报 installed，唯一能察觉的时机是某次
//  危险操作没有弹确认框——那时已经晚了。
//
//  所以这里不去解析各家的内部状态（格式会随版本变，解析错了反而更糟），
//  而是记录一个行为事实：常驻面板**收到过**来自某家的审批请求。收到过，
//  就证明「厂商加载了 hook → hook 找到了令牌 → 端到端连通」整条链路成立。
//

import Foundation

struct PermissionGateLivenessRecord: Equatable {
    /// 最近一次收到该 agent 的审批请求。
    var lastRequestAt: Date?
    /// 最近一次把裁决发回去。与 lastRequestAt 分开记：只有请求没有裁决，
    /// 说明请求一直在挂着或被中断，与闸门从未连通是两回事。
    var lastDecisionAt: Date?
    /// 上面这些请求是在哪个本机版本上收到的。
    var observedVersion: String?
    /// 用户亲眼确认「拒绝真的把操作拦住了」的时间，以及当时的版本。
    /// 这件事只有用户能作证：面板这一侧只知道自己发出了 deny，发出不等于
    /// 厂商照办。
    var semanticsVerifiedAt: Date?
    var semanticsVerifiedVersion: String?
    /// 用户报告「拒绝了但照样执行了」。这是闸门失效的直接证据，比任何
    /// 版本推断都强，必须能压过 L1 的连通结论。
    var semanticsRefutedAt: Date?
    var semanticsRefutedVersion: String?
}

enum PermissionGateLiveness: Equatable {
    /// 闸门装好了，也确实收到过请求。
    case verified(lastRequestAt: Date)
    /// 在当前版本上亲测过：拒绝真的拦住了操作。
    case semanticsVerified(confirmedAt: Date)
    /// 用户报告在当前版本上拒绝没生效。
    case ineffective(reportedAt: Date)
    /// 装好了但从未收到过请求。可能是还没触发，也可能是根本没生效。
    case neverObserved
    /// 没装，或该 agent 不支持应用内审批。
    case notApplicable
}

/// 当前版本上的语义证据：用户亲测「拒绝拦住了」还是报告「没拦住」。
enum PermissionGateSemanticsEvidence: Equatable {
    /// 用户报告拒绝没能拦住操作。
    case refuted(at: Date)
    /// 用户确认拒绝确实拦住了操作。
    case verified(at: Date)
    /// 当前版本上没有语义证据。
    case noEvidence
}

/// 把记录里的语义证据收口到当前版本，并做证伪与证实之间的取舍。
///
/// 这条取舍规则只能有一处实现：版本不匹配的证据一律不算（说不清属于哪个
/// 版本的证据不能替当前版本说话），两边都有时以更晚的一次为准，同一时刻
/// 算证伪——闸门失效是那两种结论里更该讲出来的一句。分散在两处实现过，
/// 结果是同一份记录在探测结论和界面文案上给出不同答案。
func permissionGateSemanticsEvidence(
    record: PermissionGateLivenessRecord?,
    currentVersionSignature: String?
) -> PermissionGateSemanticsEvidence {
    guard let record, let signature = currentVersionSignature else {
        return .noEvidence
    }
    let refutedAt = record.semanticsRefutedVersion == signature
        ? record.semanticsRefutedAt
        : nil
    let verifiedAt = record.semanticsVerifiedVersion == signature
        ? record.semanticsVerifiedAt
        : nil
    switch (refutedAt, verifiedAt) {
    case (let refuted?, let verified?):
        return refuted >= verified
            ? .refuted(at: refuted)
            : .verified(at: verified)
    case (let refuted?, nil):
        return .refuted(at: refuted)
    case (nil, let verified?):
        return .verified(at: verified)
    case (nil, nil):
        return .noEvidence
    }
}

/// 从在线记录里读出探测结论。
///
/// 这里刻意是**单向**的：有证据就升级判定，没有证据只回到 `.notProbed`
/// 而绝不报 `.channelBroken`。原因是面板重启、记录文件被清、或者用户
/// 这段时间根本没触发过审批，都会让证据消失——把「没看见」当成「坏了」
/// 会让每次重启都误报一次失效。真正的 `.channelBroken` 只来自用户明确
/// 报告「拒绝没拦住」。
func agentProbeOutcome(
    record: PermissionGateLivenessRecord?,
    currentVersionSignature: String?
) -> AgentProbeOutcome {
    guard let record, let currentVersionSignature else { return .notProbed }
    // 版本一换，旧证据就不再为新版本背书。签名缺失同样按过期处理：
    // 说不清证据属于哪个版本，就不能让它替当前版本说话。
    switch permissionGateSemanticsEvidence(
        record: record,
        currentVersionSignature: currentVersionSignature
    ) {
    case .refuted:
        return .channelBroken(reason: "用户报告拒绝未能拦住操作")
    case .verified:
        return .semanticsVerified
    case .noEvidence:
        break
    }
    if record.observedVersion == currentVersionSignature,
       record.lastRequestAt != nil
    {
        return .channelLive
    }
    return .notProbed
}

/// 用实测证据重算兼容性判定。
///
/// 版本分量原样保留：它仍然是要展示的溯源信息，只是不再单独决定结论。
func probeAdjustedDiscovery(
    _ discovery: AgentDiscovery,
    agentID: AgentID,
    record: PermissionGateLivenessRecord?
) -> AgentDiscovery {
    guard discovery.isInstalled else { return discovery }
    let probe = agentProbeOutcome(
        record: record,
        currentVersionSignature: agentVersionSignature(
            discovery.versionComponents
        )
    )
    guard probe != .notProbed else { return discovery }
    return AgentDiscovery(
        isInstalled: discovery.isInstalled,
        version: discovery.version,
        compatibility: agentCompatibility(
            versionDrift: agentVersionDrift(
                agentID: agentID,
                components: discovery.versionComponents
            ),
            probe: probe
        ),
        versionComponents: discovery.versionComponents
    )
}

final class PermissionGateLivenessStore {
    private let fileURL: URL
    private let now: () -> Date
    private let lock = NSLock()
    private var records: [AgentID: PermissionGateLivenessRecord]
    /// 每次请求都写盘会在连续审批时打出一串同步写。同一 agent 的请求
    /// 时间戳在窗口内只落一次盘——它要回答的是「有没有连通过」，
    /// 不是精确计时。
    private let writeThrottle: TimeInterval
    private var lastWriteAt: Date?
    /// 解析版本要跑 `omp --version` 这类子进程，绝不能发生在审批热路径上。
    /// 所以这里只接一个由常驻面板注入的读快照闭包；没注入时证据不带版本，
    /// 判定会当成过期处理——宁可不下结论，也不让来源不明的证据背书。
    private var versionSignatureProvider: ((AgentID) -> String?)?

    init(
        fileURL: URL = PermissionGateLivenessStore.defaultFileURL(),
        now: @escaping () -> Date = Date.init,
        writeThrottle: TimeInterval = 60,
        versionSignatureProvider: ((AgentID) -> String?)? = nil
    ) {
        self.fileURL = fileURL
        self.now = now
        self.writeThrottle = writeThrottle
        self.versionSignatureProvider = versionSignatureProvider
        records = PermissionGateLivenessStore.load(from: fileURL)
    }

    func setVersionSignatureProvider(
        _ provider: @escaping (AgentID) -> String?
    ) {
        lock.lock()
        versionSignatureProvider = provider
        lock.unlock()
    }

    /// 刻意不放 Library/Caches。那个目录安装时会被整个 rm -rf，系统也
    /// 可能自行清理——而「这套闸门连通过」是应当跨升级留存的事实，被清掉
    /// 就会每次升级都退回「尚未验证」，把一个本该罕见的告警变成噪音。
    static func defaultFileURL() -> URL {
        if let override = ProcessInfo.processInfo.environment[
            "THREADHELM_GATE_LIVENESS_FILE"
        ], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/ThreadHelm"
                    + "/permission-gate-liveness.json"
            )
    }

    func recordRequest(agentID: AgentID) {
        mutate(agentID: agentID) { record, version in
            record.lastRequestAt = self.now()
            record.observedVersion = version
        }
    }

    func recordDecision(agentID: AgentID) {
        // 裁决是低频事件（一次审批最多一条），值得立刻落盘：它是
        // 「闸门不只连通、而且真的完成了一次裁决」的最强证据。
        mutate(agentID: agentID, forceWrite: true) { record, version in
            record.lastDecisionAt = self.now()
            record.observedVersion = version
        }
    }

    /// 用户确认「拒绝真的拦住了操作」。这是唯一能把闸门标成已验证的入口：
    /// 面板发出 deny 只证明自己表了态，厂商有没有照办只有用户看得见。
    func recordSemanticsVerified(agentID: AgentID, versionSignature: String?) {
        mutate(
            agentID: agentID,
            forceWrite: true,
            versionOverride: versionSignature
        ) { record, version in
            record.semanticsVerifiedAt = self.now()
            record.semanticsVerifiedVersion = version
        }
    }

    /// 用户报告「拒绝了但照样执行了」。
    func recordSemanticsRefuted(agentID: AgentID, versionSignature: String?) {
        mutate(
            agentID: agentID,
            forceWrite: true,
            versionOverride: versionSignature
        ) { record, version in
            record.semanticsRefutedAt = self.now()
            record.semanticsRefutedVersion = version
        }
    }

    func record(for agentID: AgentID) -> PermissionGateLivenessRecord? {
        lock.lock()
        defer { lock.unlock() }
        return records[agentID]
    }

    func snapshot() -> [AgentID: PermissionGateLivenessRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    private func mutate(
        agentID: AgentID,
        forceWrite: Bool = false,
        versionOverride: String? = nil,
        _ apply: (inout PermissionGateLivenessRecord, String?) -> Void
    ) {
        // 先在锁外取版本：提供者会去读面板快照，在锁内回调等于把外部代码
        // 拉进临界区。
        lock.lock()
        let provider = versionSignatureProvider
        lock.unlock()
        let version = versionOverride ?? provider?(agentID)

        lock.lock()
        var record = records[agentID] ?? PermissionGateLivenessRecord()
        apply(&record, version)
        records[agentID] = record
        let current = now()
        let shouldWrite = forceWrite
            || lastWriteAt.map { current.timeIntervalSince($0) >= writeThrottle }
                ?? true
        let payload = shouldWrite ? records : nil
        if shouldWrite { lastWriteAt = current }
        lock.unlock()
        guard let payload else { return }
        PermissionGateLivenessStore.persist(payload, to: fileURL)
    }

    // MARK: 持久化

    private static func load(
        from url: URL
    ) -> [AgentID: PermissionGateLivenessRecord] {
        guard let data = try? Data(contentsOf: url),
              data.count <= 64 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any],
              let agents = payload["agents"] as? [String: Any]
        else { return [:] }
        var result: [AgentID: PermissionGateLivenessRecord] = [:]
        for (rawID, rawRecord) in agents {
            guard let entry = rawRecord as? [String: Any] else { continue }
            let agentID = AgentID(rawValue: rawID)
            // AgentID 会把不认识的值折成 unknown。把它们收进来只会让
            // 界面出现一个假的 agent 行。
            guard agentID.rawValue == rawID else { continue }
            // schemaVersion 1 的记录没有版本戳。读进来时保持 nil，判定就会
            // 当成过期证据——升级前收到过请求，不能替升级后的版本背书。
            result[agentID] = PermissionGateLivenessRecord(
                lastRequestAt: date(from: entry["lastRequestAt"]),
                lastDecisionAt: date(from: entry["lastDecisionAt"]),
                observedVersion: versionSignature(from: entry["observedVersion"]),
                semanticsVerifiedAt: date(from: entry["semanticsVerifiedAt"]),
                semanticsVerifiedVersion: versionSignature(
                    from: entry["semanticsVerifiedVersion"]
                ),
                semanticsRefutedAt: date(from: entry["semanticsRefutedAt"]),
                semanticsRefutedVersion: versionSignature(
                    from: entry["semanticsRefutedVersion"]
                )
            )
        }
        return result
    }

    /// 版本签名进来的是用户机器上的字符串，落盘前后都要有界。
    private static func versionSignature(from value: Any?) -> String? {
        guard let text = value as? String,
              !text.isEmpty,
              text.count <= 256
        else { return nil }
        return text
    }

    private static func date(from value: Any?) -> Date? {
        guard let seconds = value as? Double, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func persist(
        _ records: [AgentID: PermissionGateLivenessRecord],
        to url: URL
    ) {
        var agents: [String: Any] = [:]
        for (agentID, record) in records {
            var entry: [String: Any] = [:]
            if let requestedAt = record.lastRequestAt {
                entry["lastRequestAt"] = requestedAt.timeIntervalSince1970
            }
            if let decidedAt = record.lastDecisionAt {
                entry["lastDecisionAt"] = decidedAt.timeIntervalSince1970
            }
            if let observedVersion = versionSignature(
                from: record.observedVersion
            ) {
                entry["observedVersion"] = observedVersion
            }
            if let verifiedAt = record.semanticsVerifiedAt {
                entry["semanticsVerifiedAt"] = verifiedAt.timeIntervalSince1970
            }
            if let verifiedVersion = versionSignature(
                from: record.semanticsVerifiedVersion
            ) {
                entry["semanticsVerifiedVersion"] = verifiedVersion
            }
            if let refutedAt = record.semanticsRefutedAt {
                entry["semanticsRefutedAt"] = refutedAt.timeIntervalSince1970
            }
            if let refutedVersion = versionSignature(
                from: record.semanticsRefutedVersion
            ) {
                entry["semanticsRefutedVersion"] = refutedVersion
            }
            guard !entry.isEmpty else { continue }
            agents[agentID.rawValue] = entry
        }
        let payload: [String: Any] = [
            // 2：加了版本戳与语义验证。旧版本读到未知键会忽略，新版本读到
            // 旧记录会把它当成没有版本戳的证据，两个方向都不会误判。
            "schemaVersion": 2,
            "agents": agents,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        ) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}

/// 把「能力声明」和「观测到的事实」合成一句用户能据以行动的话。
///
/// 只有两者都成立才叫在线：声称支持却从未收到过请求，恰恰是那些静默
/// 失效场景的样子。
func permissionGateLiveness(
    capability: AgentCapabilityStatus,
    integrationStatus: AgentIntegrationStatus?,
    record: PermissionGateLivenessRecord?,
    currentVersionSignature: String? = nil
) -> PermissionGateLiveness {
    // 声明为 unsupported 才真的不适用。`unknown` 现在的常见来源是版本漂移
    // 把能力折叠了一层——那时候恰恰有实测证据要讲，不能因为一个折叠过的
    // 声明就把观测到的事实吞掉。但没有证据时仍报不适用：凭一个折叠状态
    // 生出一条用户处理不了的告警，是另一种噪音。
    guard capability != .unsupported else { return .notApplicable }
    guard integrationStatus == .installed else { return .notApplicable }

    // 语义结论按版本收口：亲测是在某个版本上做的，换了版本就只剩连通性。
    // 它自成证据——用户能确认「拒绝拦住了」，前提就是确实发生过一次审批，
    // 所以这里不再另外要求一条请求记录。尤其是「报告没拦住」：那是最该
    // 讲出来的一句话，绝不能因为记录里缺了别的字段就被吞掉。
    switch permissionGateSemanticsEvidence(
        record: record,
        currentVersionSignature: currentVersionSignature
    ) {
    case .refuted(let reportedAt):
        return .ineffective(reportedAt: reportedAt)
    case .verified(let confirmedAt):
        return .semanticsVerified(confirmedAt: confirmedAt)
    case .noEvidence:
        break
    }

    if capability != .supported, record?.lastRequestAt == nil {
        return .notApplicable
    }
    guard let lastRequestAt = record?.lastRequestAt else {
        return .neverObserved
    }
    return .verified(lastRequestAt: lastRequestAt)
}

func permissionGateLivenessSummary(
    _ liveness: PermissionGateLiveness,
    agentID: AgentID,
    now: Date = Date()
) -> String? {
    switch liveness {
    case .notApplicable:
        return nil
    case .neverObserved:
        // 措辞不能断言「没生效」——也可能只是还没触发过审批。要点是
        // 让用户知道这件事**尚未被证实**，以及去哪儿证实。
        if agentID == .codex {
            return "闸门尚未验证：还没收到过审批请求。"
                + "若 Codex 启动时提示 Hooks need review，请选 Trust 后再试。"
        }
        return "闸门尚未验证：还没收到过审批请求。"
    case .verified(let lastRequestAt):
        let elapsed = max(0, now.timeIntervalSince(lastRequestAt))
        // 「连通」不等于「拦得住」：收到请求只证明厂商把决定权交过来了，
        // 拒绝有没有被照办得由用户亲眼确认。文案要把这一层差别说清楚，
        // 并给出确认的办法。
        return "闸门已连通（最近一次审批 \(elapsedGateText(elapsed))）；"
            + "拒绝是否真的拦住尚未亲测，确认办法见 --print-permission-gate-follow-up。"
    case .semanticsVerified(let confirmedAt):
        let elapsed = max(0, now.timeIntervalSince(confirmedAt))
        return "闸门已验证在线：拒绝确实拦住过操作"
            + "（\(elapsedGateText(elapsed))确认）。"
    case .ineffective(let reportedAt):
        let elapsed = max(0, now.timeIntervalSince(reportedAt))
        return "闸门未生效：你报告过拒绝没能拦住操作"
            + "（\(elapsedGateText(elapsed))）。请改用该 Agent 自己的权限设置。"
    }
}

private func elapsedGateText(_ elapsed: TimeInterval) -> String {
    if elapsed < 60 { return "刚刚" }
    if elapsed < 3_600 { return "\(Int(elapsed / 60)) 分钟前" }
    if elapsed < 86_400 { return "\(Int(elapsed / 3_600)) 小时前" }
    return "\(Int(elapsed / 86_400)) 天前"
}
