//
//  AntigravityAgentAdapter.swift
//  ThreadHelm
//
//  模块职责：Antigravity CLI（agy）的本地发现、hooks.json 生命周期、
//  状态归一化和会话恢复。
//
//  受管对象是跨产品共享的 `~/.gemini/config/hooks.json`。这份文件的
//  顶层是一张「具名 hook」表，ThreadHelm 只占其中一个键，用户自己的条目
//  与我们互不相干——比 Codex 那种要在事件数组里逐条挑出自家 handler 的
//  结构干净得多。
//
//  位置为什么是 `config/` 而不是 CLI 专属的 `antigravity-cli/`：后者
//  只会被 hooks_manager 计入加载日志，里面的 hook 却一次也不会执行
//  （agy 1.1.22，2026-08-31 本机探针实测；agy 自己的 changelog 也把
//  「/hooks 写进 antigravity-cli」称为已修复的 bug）。代价是 `config/`
//  被 IDE 与 Antigravity 2.0 共享，非 CLI 会话也会拉起我们的 hook——
//  由 hook 进程按 transcriptPath 就地过滤，见
//  antigravityHookPayloadIsCLISession。
//
//  基线：agy 1.1.22，契约由本机实测确定。
//

import AppKit
import Foundation

enum AntigravityAgentDefaults {
    static let adapterVersion = "antigravity-hooks-v1"
    static let staleAfter: TimeInterval = 30 * 60
    /// hooks.json 里我们占用的顶层键。
    static let managedHookName = "threadhelm"
    /// 观测 hook 的超时。它们只是把一份脱敏 envelope 丢进本地 socket，
    /// 拿不到就算了；agy 的 hook 是同步阻塞 agent 循环的，给太长只会在
    /// 面板停摆时把用户的会话一起拖住。
    static let observationTimeoutSeconds = 5
}

struct AntigravityAgentAdapter: AgentAdapter {
    let metadata: AgentMetadata
    private let discoveryProvider: () -> AgentDiscovery
    private let readEvents: () throws -> [AgentEvent]
    private let executablePath: () -> String
    private let resumeSession: (String, String?) -> Bool

    var managedIntegrationRelativePaths: [String] {
        [
            AntigravityHookConfiguration.hooksRelativePath,
            AntigravityHookConfiguration.legacyHooksRelativePath,
            AntigravityHookConfiguration.tokenRelativePath,
        ]
    }

    init(
        metadata: AgentMetadata? = builtInAgentMetadata().first {
            $0.id == .antigravity
        },
        discovery: @escaping () -> AgentDiscovery = makeGenericAgentDiscoveryProvider(
            agentID: .antigravity
        ) {
            discoverLocalAntigravityAgent()
        },
        readEvents: @escaping () throws -> [AgentEvent] = { [] },
        executablePath: @escaping () -> String = {
            Bundle.main.executableURL?.path ?? "/usr/bin/true"
        },
        resumeSession: @escaping (String, String?) -> Bool = {
            openAntigravitySession(sessionID: $0, workingDirectory: $1)
        }
    ) {
        self.metadata = metadata!
        discoveryProvider = discovery
        self.readEvents = readEvents
        self.executablePath = executablePath
        self.resumeSession = resumeSession
    }

    func discover() -> AgentDiscovery {
        discoveryProvider()
    }

    func integrationStatus(
        in scope: AgentIntegrationScope
    ) -> AgentIntegrationStatus {
        do {
            return try AntigravityHookConfiguration.status(
                in: scope,
                executablePath: executablePath()
            )
        } catch {
            return agentIntegrationStatusForFailedProbe(error)
        }
    }

    func installIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult {
        guard discover().isInstalled else { return .unchanged }
        return try prepareGate(in: scope) ? .installed : .unchanged
    }

    func repairIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult {
        guard discover().isInstalled else { return .unchanged }
        return try prepareGate(in: scope) ? .repaired : .unchanged
    }

    func uninstallIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult {
        let removed = try AntigravityHookConfiguration.uninstall(in: scope)
        let directory = try scope.managedURL(
            relativePath: AntigravityHookConfiguration.configurationRelativePath
        )
        AgentPermissionTokenStore.antigravity.removeToken(directory: directory)
        return removed ? .uninstalled : .unchanged
    }

    private func prepareGate(in scope: AgentIntegrationScope) throws -> Bool {
        let directory = try scope.managedURL(
            relativePath: AntigravityHookConfiguration.configurationRelativePath
        )
        // 令牌必须先于配置落盘：hook 一旦被 agy 拉起就会立刻去读它，
        // 读不到就只能按兜底处理。
        try AgentPermissionTokenStore.antigravity.ensureToken(
            directory: directory
        )
        return try AntigravityHookConfiguration.install(
            in: scope,
            executablePath: executablePath()
        )
    }

    func observe() throws -> AgentObservation {
        let events = try readEvents().filter {
            $0.identity.agentID == .antigravity
        }
        return AgentObservation(
            events: events,
            snapshots: AgentEventReducer.reduce(events: events).snapshots
        )
    }

    func freshness(
        for snapshot: AgentSessionSnapshot,
        now: Date
    ) -> Freshness {
        if snapshot.freshness.isStale(at: now) {
            return snapshot.freshness
        }
        guard snapshot.executionState == .running
            || snapshot.executionState == .idle
        else { return snapshot.freshness }
        let expiresAt = snapshot.freshness.expiresAt
            ?? snapshot.updatedAt.addingTimeInterval(
                AntigravityAgentDefaults.staleAfter
            )
        return Freshness(
            observedAt: snapshot.freshness.observedAt,
            expiresAt: expiresAt,
            staleReason: now >= expiresAt ? "antigravity-session-stale" : nil
        )
    }

    func openValidated(session: AgentSessionSnapshot) -> AgentOpenReport {
        guard session.identity.agentID == .antigravity,
              normalizedAntigravitySessionID(session.identity.nativeID) != nil
        else {
            return AgentOpenReport(
                agentID: metadata.id,
                advertisedActionability: session.actionability,
                result: .unavailable,
                invokedExactTarget: false,
                independentlyConfirmedIdentity: false
            )
        }
        let didLaunch = resumeSession(
            session.identity.nativeID,
            session.workingDirectory
        )
        // `--conversation` 实测能把上下文接回来，但落点是一个新开的终端
        // 会话，不是用户原来那个窗口。invokedExactTarget 记 true（我们确实
        // 指名了那条会话），结果只能记 unknown。
        return AgentOpenReport(
            agentID: metadata.id,
            advertisedActionability: session.actionability,
            result: didLaunch ? .unknown : .failed,
            invokedExactTarget: didLaunch,
            independentlyConfirmedIdentity: false
        )
    }

    func diagnostics() -> AgentDiagnostics {
        let discovery = discover()
        return AgentDiagnostics(
            health: discovery.isInstalled ? .healthy : .unavailable,
            summary: discovery.isInstalled
                ? "已发现 Antigravity"
                : "未发现 Antigravity",
            counters: [:]
        )
    }
}

// MARK: - hooks.json 管理

enum AntigravityHookConfiguration {
    /// 令牌所在目录，相对 home。与 antigravityConfigurationDirectoryURL
    /// 指向同一处——那条走 URL、这条走 AgentIntegrationScope，两边必须
    /// 一致，否则备份覆盖不到真正被写的文件。hooks.json 不在这里，
    /// 见 hooksRelativePath。
    static let configurationRelativePath = ".gemini/antigravity-cli"
    /// hooks.json 的受管路径：唯一会被 agy 真正执行的位置（见文件头）。
    static let hooksRelativePath = ".gemini/config/hooks.json"
    /// 早期版本写过的旧位置。agy 只把它计入加载日志、从不执行里面的
    /// hook，留着一份受管键会让状态检测谎报「已安装」。安装、修复、
    /// 卸载都要顺带清掉这里的残留。
    static let legacyHooksRelativePath =
        "\(configurationRelativePath)/hooks.json"
    static let tokenRelativePath =
        "\(configurationRelativePath)/"
            + AntigravityPermissionHookConstants.tokenFileName

    static func status(
        in scope: AgentIntegrationScope,
        executablePath: String,
        fileManager: FileManager = .default
    ) throws -> AgentIntegrationStatus {
        // 旧位置的残留键必须先看：那里的 hook 从不执行，真正危险的不是
        // 它本身，而是它曾让检测谎报「已安装」。只要还在就报 needsRepair，
        // 让修复流程把它清掉。
        let legacyURL = try scope.managedURL(
            relativePath: legacyHooksRelativePath,
            for: .read
        )
        let legacyLingers = fileManager.fileExists(atPath: legacyURL.path)
            && (try? loadConfiguration(at: legacyURL))?[
                AntigravityAgentDefaults.managedHookName
            ] != nil

        let url = try scope.managedURL(
            relativePath: hooksRelativePath,
            for: .read
        )
        guard fileManager.fileExists(atPath: url.path) else {
            return .notInstalled
        }
        let configuration = try loadConfiguration(at: url)
        guard let owned = configuration[
            AntigravityAgentDefaults.managedHookName
        ] else {
            return .notInstalled
        }
        let desired = managedHookSpec(executablePath: executablePath)
        // 逐字比对整份 spec。命令里带着可执行文件的绝对路径，ThreadHelm
        // 被挪过位置后这份配置就指向一个不存在的二进制——那时 agy 的
        // fail-closed 会把用户的每一次工具调用都拦死，必须报出来让人修。
        guard equivalentJSON(owned, desired) else { return .needsRepair }
        return legacyLingers ? .needsRepair : .installed
    }

    @discardableResult
    static func install(
        in scope: AgentIntegrationScope,
        executablePath: String,
        fileManager: FileManager = .default
    ) throws -> Bool {
        // 顺带清掉旧位置的残留。清不动（比如用户手上有一份坏 JSON）就
        // 算了——那份文件 agy 同样读不了，不该拦住正确位置的安装。
        let migrated = (try? scope.managedURL(
            relativePath: legacyHooksRelativePath
        )).flatMap {
            try? removeManagedHook(at: $0, fileManager: fileManager)
        } ?? false

        let url = try scope.managedURL(relativePath: hooksRelativePath)
        var configuration = try loadConfiguration(at: url)
        let desired = managedHookSpec(executablePath: executablePath)
        if let existing = configuration[AntigravityAgentDefaults.managedHookName],
           equivalentJSON(existing, desired)
        {
            return migrated
        }
        configuration[AntigravityAgentDefaults.managedHookName] = desired
        try writeConfiguration(configuration, to: url, fileManager: fileManager)
        return true
    }

    @discardableResult
    static func uninstall(
        in scope: AgentIntegrationScope,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let legacyRemoved = (try? scope.managedURL(
            relativePath: legacyHooksRelativePath
        )).flatMap {
            try? removeManagedHook(at: $0, fileManager: fileManager)
        } ?? false
        let url = try scope.managedURL(relativePath: hooksRelativePath)
        let removed = try removeManagedHook(at: url, fileManager: fileManager)
        return removed || legacyRemoved
    }

    /// 从一份具名 hook 表里摘掉我们那个键。整份只剩空对象时连文件一起
    /// 删——留一个 `{}` 就是卸载没卸干净；用户自己写过的条目会让它非空，
    /// 走不到删除文件那步。
    private static func removeManagedHook(
        at url: URL,
        fileManager: FileManager
    ) throws -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        var configuration = try loadConfiguration(at: url)
        guard configuration
            .removeValue(forKey: AntigravityAgentDefaults.managedHookName) != nil
        else { return false }
        if configuration.isEmpty {
            try? fileManager.removeItem(at: url)
        } else {
            try writeConfiguration(
                configuration,
                to: url,
                fileManager: fileManager
            )
        }
        return true
    }

    /// ThreadHelm 那条具名 hook 的完整内容。
    ///
    /// 事件的取舍：
    /// - PreToolUse 是审批闸门，走独立旗标，绝不能与观测共用一条命令
    ///   （进程入口会先匹配 --agent-hook 就地 exit(0)，审批一行都跑不到）。
    /// - PreInvocation 是最可靠的「这条会话在跑」信号，每轮模型调用前触发。
    /// - PostToolUse 补上工具粒度的活动。
    /// - Stop 是唯一的终态信号：agy 没有 session_start/session_end。
    /// PostInvocation 与 PreInvocation 表达的是同一件事，不重复注册——
    /// 每多一个事件就多一次同步的进程启动，而它是卡在 agent 循环里的。
    static func managedHookSpec(executablePath: String) -> [String: Any] {
        let quoted = shellSingleQuoted(executablePath)
        func observation(_ event: String) -> [String: Any] {
            [
                "type": "command",
                "command": "\(quoted) --agent-hook antigravity \(event)",
                "timeout": AntigravityAgentDefaults.observationTimeoutSeconds,
            ]
        }
        return [
            "PreToolUse": [
                [
                    "matcher": AntigravityPermissionHookConstants.matcher,
                    "hooks": [
                        [
                            "type": "command",
                            "command": "\(quoted) "
                                + AntigravityPermissionHookConstants.flag,
                            "timeout": AntigravityPermissionHookConstants
                                .hookTimeoutSeconds,
                        ],
                    ],
                ],
            ],
            "PostToolUse": [
                [
                    "matcher": "*",
                    "hooks": [observation("post_tool_use")],
                ],
            ],
            "PreInvocation": [observation("pre_invocation")],
            "Stop": [observation("stop")],
        ]
    }

    static func loadConfiguration(at url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return [:]
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let configuration = object as? [String: Any]
        else {
            throw AntigravityHookConfigurationError.invalidConfiguration
        }
        return configuration
    }

    private static func writeConfiguration(
        _ configuration: [String: Any],
        to url: URL,
        fileManager: FileManager
    ) throws {
        guard JSONSerialization.isValidJSONObject(configuration) else {
            throw AntigravityHookConfigurationError
                .writeFailed("配置不是合法的 JSON 对象")
        }
        // 键序稳定：这份文件会被逐字比对（status、自检、排查日志），
        // 字典的自然顺序每次都可能不同。
        let data = try JSONSerialization.data(
            withJSONObject: configuration,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try AgentIntegrationAtomicFileWriter.write(
            data,
            to: url,
            fileManager: fileManager
        )
    }

    /// 两份 JSON 结构是否等价。直接比 NSDictionary 而不是比序列化结果：
    /// 后者会因为键序与数字表示的差异误报不一致。
    private static func equivalentJSON(_ lhs: Any, _ rhs: Any) -> Bool {
        NSDictionary(dictionary: lhs as? [String: Any] ?? [:])
            .isEqual(to: rhs as? [String: Any] ?? [:])
    }
}

// MARK: - 发现与恢复

func discoverLocalAntigravityAgent(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
) -> AgentDiscovery {
    guard let executable = locateAntigravityExecutable(
        environment: environment,
        fileManager: fileManager
    ) else {
        return AgentDiscovery(
            isInstalled: false,
            version: nil,
            compatibility: .unknown
        )
    }
    let version = antigravityVersion(executableURL: executable)
    return versionValidatedAgentDiscovery(
        agentID: .antigravity,
        isInstalled: true,
        components: version.map {
            [AgentVersionComponent(key: "version", label: "Version", value: $0)]
        } ?? []
    )
}

func locateAntigravityExecutable(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
) -> URL? {
    if let override = environment["THREADHELM_ANTIGRAVITY_EXECUTABLE"],
       !override.isEmpty,
       fileManager.isExecutableFile(atPath: override)
    {
        return URL(fileURLWithPath: override)
    }
    // `~/.local/bin` 是 agy 自己的安装位置（`agy install` 往那里放），
    // 而常驻面板由 launchd 拉起、PATH 里通常没有它，所以必须显式兜底。
    let home = fileManager.homeDirectoryForCurrentUser.path
    let pathCandidates = (environment["PATH"] ?? "")
        .split(separator: ":")
        .map { String($0) }
        + [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
        ]
    for directory in pathCandidates {
        let candidate = URL(fileURLWithPath: directory)
            .appendingPathComponent("agy")
        if fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}

private func antigravityVersion(executableURL: URL) -> String? {
    for _ in 0..<2 {
        if let version = probeAntigravityVersion(executableURL: executableURL) {
            return version
        }
    }
    return nil
}

private func probeAntigravityVersion(executableURL: URL) -> String? {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = ["--version"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return nil
    }
    let capture = captureProcessOutput(
        process: process,
        output: output.fileHandleForReading,
        timeout: 2,
        maximumOutputBytes: 4_096
    )
    guard capture.termination == .exited || capture.termination == .outputClosed,
          let text = String(data: capture.data, encoding: .utf8)
    else { return nil }
    let firstLine = text
        .split(whereSeparator: \.isNewline)
        .first
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    return firstLine.flatMap { normalizedAgentVersion(from: $0) }
}

func openAntigravitySession(
    sessionID: String,
    workingDirectory: String?
) -> Bool {
    guard let executablePath = locateAntigravityExecutable()?.path,
          let command = antigravityResumeCommand(
              sessionID: sessionID,
              workingDirectory: workingDirectory,
              executablePath: executablePath
          )
    else { return false }
    return openCommandInPreferredTerminal(command)
}

// MARK: - envelope 投影

func antigravityAgentEvent(
    from envelope: AgentTransportEnvelope,
    observedAt: Date
) -> AgentEvent? {
    guard envelope.agentID == .antigravity else { return nil }
    let state = envelope.redactedPayload["state"].flatMap {
        ExecutionState(rawValue: $0)
    } ?? .running
    let rawReason = envelope.redactedPayload["attentionReason"]
        .flatMap { AttentionReason(rawValue: $0) } ?? .none
    let reason: AttentionReason
    if envelope.eventType == "stop", state == .failed, rawReason == .taskFailure {
        reason = .taskFailure
    } else if envelope.eventType == "stop", state == .completed {
        reason = .reviewReady
    } else {
        reason = .none
    }
    let actionability: Actionability = envelope.nativeSessionCandidate.flatMap {
        normalizedAntigravitySessionID($0) != nil
            ? .openExactNativeSession
            : nil
    } ?? .viewOnly
    let evidence = envelope.redactedPayload["evidenceQuality"]
        .flatMap { EvidenceQuality(rawValue: $0) } ?? .officialHook
    let freshnessClass = envelope.redactedPayload["freshness"] ?? "fresh"
    let stale = freshnessClass == "stale"
        || state == .offline
        || state == .stale
    let nativeID = envelope.nativeSessionCandidate
        ?? "antigravity-session-unknown"
    return AgentEvent(
        identity: AgentSessionIdentity(
            agentID: .antigravity,
            nativeID: nativeID
        ),
        adapterVersion: envelope.adapterVersion,
        eventID: envelope.eventID,
        sequence: envelope.sequence,
        eventType: envelope.eventType,
        observedAt: observedAt,
        monotonicNanoseconds: envelope.monotonicNanoseconds,
        executionState: state,
        attentionReason: reason,
        actionability: actionability,
        evidenceQuality: evidence,
        freshness: Freshness(
            observedAt: observedAt,
            expiresAt: stale
                ? observedAt
                : observedAt.addingTimeInterval(
                    AntigravityAgentDefaults.staleAfter
                ),
            staleReason: stale ? "antigravity-session-stopped-or-stale" : nil
        ),
        title: "Antigravity 会话",
        activitySummary: nil,
        workingDirectory: nil
    )
}
