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
}

enum PermissionGateLiveness: Equatable {
    /// 闸门装好了，也确实收到过请求。
    case verified(lastRequestAt: Date)
    /// 装好了但从未收到过请求。可能是还没触发，也可能是根本没生效。
    case neverObserved
    /// 没装，或该 agent 不支持应用内审批。
    case notApplicable
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

    init(
        fileURL: URL = PermissionGateLivenessStore.defaultFileURL(),
        now: @escaping () -> Date = Date.init,
        writeThrottle: TimeInterval = 60
    ) {
        self.fileURL = fileURL
        self.now = now
        self.writeThrottle = writeThrottle
        records = PermissionGateLivenessStore.load(from: fileURL)
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
        mutate(agentID: agentID) { $0.lastRequestAt = self.now() }
    }

    func recordDecision(agentID: AgentID) {
        // 裁决是低频事件（一次审批最多一条），值得立刻落盘：它是
        // 「闸门不只连通、而且真的完成了一次裁决」的最强证据。
        mutate(agentID: agentID, forceWrite: true) {
            $0.lastDecisionAt = self.now()
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
        _ apply: (inout PermissionGateLivenessRecord) -> Void
    ) {
        lock.lock()
        var record = records[agentID] ?? PermissionGateLivenessRecord()
        apply(&record)
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
            result[agentID] = PermissionGateLivenessRecord(
                lastRequestAt: date(from: entry["lastRequestAt"]),
                lastDecisionAt: date(from: entry["lastDecisionAt"])
            )
        }
        return result
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
            guard !entry.isEmpty else { continue }
            agents[agentID.rawValue] = entry
        }
        let payload: [String: Any] = [
            "schemaVersion": 1,
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
    record: PermissionGateLivenessRecord?
) -> PermissionGateLiveness {
    guard capability == .supported else { return .notApplicable }
    guard integrationStatus == .installed else { return .notApplicable }
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
        return "闸门已验证在线（最近一次审批 \(elapsedGateText(elapsed))）。"
    }
}

private func elapsedGateText(_ elapsed: TimeInterval) -> String {
    if elapsed < 60 { return "刚刚" }
    if elapsed < 3_600 { return "\(Int(elapsed / 60)) 分钟前" }
    if elapsed < 86_400 { return "\(Int(elapsed / 3_600)) 小时前" }
    return "\(Int(elapsed / 86_400)) 天前"
}
