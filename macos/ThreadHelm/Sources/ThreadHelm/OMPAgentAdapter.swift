//
//  OMPAgentAdapter.swift
//  ThreadHelm
//
//  模块职责：OMP 的本地发现、隔离 extension 生命周期、状态归一化和会话跳转。
//

import Foundation

struct OMPAgentAdapter: AgentAdapter {
    let metadata: AgentMetadata
    private let discoveryProvider: () -> AgentDiscovery
    private let readEvents: () throws -> [AgentEvent]
    private let executablePath: () -> String
    private let resumeSession: (String) -> Bool
    /// `omp config set` 的副作用跨不出进程边界，隔离 scope 管不住它。
    /// 做成依赖，隔离自测才不会改到本机 OMP 的真实设置。
    private let timeoutStore: OMPToolCallTimeoutStore

    var managedIntegrationRelativePaths: [String] {
        managedRelativePaths(for: OMPProfileScope.defaultTarget)
    }

    /// 每个 profile 都是一套独立的闸门，备份必须覆盖到所有会被写的目录，
    /// 否则回滚只还原默认那一份。
    func managedIntegrationRelativePaths(
        in scope: AgentIntegrationScope
    ) -> [String] {
        OMPProfileScope.agentTargets(in: scope).flatMap(managedRelativePaths)
    }

    private func managedRelativePaths(for target: OMPAgentTarget) -> [String] {
        let agent = target.agentRelativePath
        return [
            target.extensionRelativePath,
            "\(agent)/\(OMPPermissionHookConstants.tokenFileName)",
            "\(agent)/\(OMPManagedSettingsRecord.filename)",
            // 抬高 handler 超时要经 `omp config set`，而它会按 schema
            // 重写整份 config.yml、静默丢弃当前版本不认的值。列进受管
            // 路径是为了让安装前的备份覆盖到它。
            "\(agent)/config.yml",
        ]
    }

    init(
        metadata: AgentMetadata? = builtInAgentMetadata().first {
            $0.id == .omp
        },
        discovery: @escaping () -> AgentDiscovery = makeGenericAgentDiscoveryProvider(
            agentID: .omp
        ) {
            discoverLocalOMPAgent()
        },
        readEvents: @escaping () throws -> [AgentEvent] = { [] },
        executablePath: @escaping () -> String = {
            Bundle.main.executableURL?.path ?? "/usr/bin/true"
        },
        resumeSession: @escaping (String) -> Bool = openOMPSession,
        timeoutStore: OMPToolCallTimeoutStore = OMPConfigCommandTimeoutStore()
    ) {
        self.metadata = metadata!
        discoveryProvider = discovery
        self.readEvents = readEvents
        self.executablePath = executablePath
        self.resumeSession = resumeSession
        self.timeoutStore = timeoutStore
    }

    func discover() -> AgentDiscovery {
        discoveryProvider()
    }

    func integrationStatus(in scope: AgentIntegrationScope) -> AgentIntegrationStatus {
        do {
            return ompAggregatedIntegrationStatus(
                try OMPProfileScope.agentTargets(in: scope).map { target in
                    try OMPExtensionConfiguration.status(
                        in: scope,
                        target: target,
                        executablePath: executablePath()
                    )
                }
            )
        } catch {
            return agentIntegrationStatusForFailedProbe(error)
        }
    }

    func installIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult {
        guard discover().isInstalled else { return .unchanged }
        let changed = try prepareGate(in: scope)
        return changed ? .installed : .unchanged
    }

    func repairIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult {
        guard discover().isInstalled else { return .unchanged }
        let changed = try prepareGate(in: scope)
        return changed ? .repaired : .unchanged
    }

    func uninstallIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult {
        var changed = false
        for target in OMPProfileScope.agentTargets(in: scope) {
            let directory = try ompManagedAgentDirectory(
                in: scope,
                target: target
            )
            // 先撤设置再撤扩展：反过来的话，中途失败会留下一个被我们改过
            // 却没人认领的超时值。
            let restoredTimeout = restoreToolCallTimeout(
                directory: directory,
                profile: target.profile
            )
            OMPPermissionTokenStore.removeToken(directory: directory)
            let removedExtension = try OMPExtensionConfiguration.uninstall(
                in: scope,
                target: target
            )
            changed = changed || restoredTimeout || removedExtension
        }
        return changed ? .uninstalled : .unchanged
    }

    /// 装扩展、备好令牌、并把 handler 超时抬到人能反应过来的量级。
    ///
    /// 每个 profile 都要单独装：装了默认那一套，`--profile` 的会话依旧
    /// 没有闸门，而且不报错。
    private func prepareGate(in scope: AgentIntegrationScope) throws -> Bool {
        var changed = false
        for target in OMPProfileScope.agentTargets(in: scope) {
            changed = try prepareGate(in: scope, target: target) || changed
        }
        return changed
    }

    private func prepareGate(
        in scope: AgentIntegrationScope,
        target: OMPAgentTarget
    ) throws -> Bool {
        let directory = try ompManagedAgentDirectory(in: scope, target: target)
        // 令牌必须先于扩展落盘：扩展一旦被 OMP 加载就会去读它，读不到
        // 只能按拒绝兜底，把用户挡在自己的工具外面。
        //
        // 每个 agent 目录一份令牌：扩展脚本里写的是它自己那份的绝对路径，
        // 而 profile 目录只有 owner 能进，跨目录共用一份并不更安全，却会
        // 让「卸载某个 profile」把别人的令牌一起删掉。
        try OMPPermissionTokenStore.ensureToken(directory: directory)
        let raisedTimeout = raiseToolCallTimeoutIfNeeded(
            directory: directory,
            profile: target.profile
        )
        let changed = try OMPExtensionConfiguration.install(
            in: scope,
            target: target,
            executablePath: executablePath()
        )
        return changed || raisedTimeout
    }

    private func raiseToolCallTimeoutIfNeeded(
        directory: URL,
        profile: String?
    ) -> Bool {
        // 已经记过原值就说明这次是重复安装，不能再记一次——否则第二次
        // 会把我们自己写的值当成用户的原值，卸载时还原不回去。
        guard OMPManagedSettingsRecord.previousTimeout(directory: directory)
            == nil
        else { return false }
        let current = timeoutStore.read(profile: profile)
        guard case .raise(let from, let to) = ompToolCallTimeoutPlan(
            currentValue: current
        ) else { return false }
        guard timeoutStore.write(to, profile: profile) else { return false }
        try? OMPManagedSettingsRecord.write(
            previousTimeout: from,
            directory: directory
        )
        return true
    }

    private func restoreToolCallTimeout(
        directory: URL,
        profile: String?
    ) -> Bool {
        guard let previous = OMPManagedSettingsRecord.previousTimeout(
            directory: directory
        ) else { return false }
        switch previous {
        case .some(let value):
            _ = timeoutStore.write(value, profile: profile)
        case .none:
            // 我们改之前用户根本没设过这个键，还原就是把它清掉，
            // 而不是写回默认值——那会留下一条用户没写过的配置。
            _ = timeoutStore.reset(profile: profile)
        }
        OMPManagedSettingsRecord.remove(directory: directory)
        return true
    }

    func observe() throws -> AgentObservation {
        let events = try readEvents().compactMap(ompStateOnlyEvent)
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
        guard snapshot.executionState == .running || snapshot.executionState == .idle
        else { return snapshot.freshness }
        let expiresAt = snapshot.freshness.expiresAt
            ?? snapshot.updatedAt.addingTimeInterval(OMPAgentDefaults.staleAfter)
        return Freshness(
            observedAt: snapshot.freshness.observedAt,
            expiresAt: expiresAt,
            staleReason: now >= expiresAt ? "omp-session-stale" : nil
        )
    }

    func openValidated(session: AgentSessionSnapshot) -> AgentOpenReport {
        guard session.identity.agentID == .omp,
              normalizedOMPSessionID(session.identity.nativeID) != nil
        else {
            return AgentOpenReport(
                agentID: metadata.id,
                advertisedActionability: session.actionability,
                result: .unavailable,
                invokedExactTarget: false,
                independentlyConfirmedIdentity: false
            )
        }
        let didLaunch = resumeSession(session.identity.nativeID)
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
            summary: discovery.isInstalled ? "已发现 OMP" : "未发现 OMP",
            counters: [:]
        )
    }
}

enum OMPAgentDefaults {
    static let adapterVersion = "omp-extension-v1"
    static let staleAfter: TimeInterval = 30 * 60
}

enum OMPExtensionConfigurationError: Error, Equatable {
    case notOwned
}

enum OMPExtensionConfiguration {
    private static let scriptFilename = "index.ts"
    private static let ownershipFilename = ".threadhelm-owner"
    private static let marker = "threadhelm-managed-state-observer-v1"
    private static let ownershipContent = "\(marker)\n"

    static func status(
        in scope: AgentIntegrationScope,
        target: OMPAgentTarget = OMPProfileScope.defaultTarget,
        executablePath: String,
        fileManager: FileManager = .default
    ) throws -> AgentIntegrationStatus {
        let directoryURL = try extensionDirectoryURL(
            in: scope,
            target: target,
            for: .read
        )
        let scriptURL = directoryURL.appendingPathComponent(scriptFilename)
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return .notInstalled
        }
        guard isOwned(directoryURL: directoryURL) else {
            return .needsRepair
        }
        guard let script = try? String(contentsOf: scriptURL, encoding: .utf8)
        else {
            return .needsRepair
        }
        return script == scriptContent(
            executablePath: executablePath,
            tokenPath: try tokenPath(in: scope, target: target, for: .read)
        )
            ? .installed
            : .needsRepair
    }

    @discardableResult
    static func install(
        in scope: AgentIntegrationScope,
        target: OMPAgentTarget = OMPProfileScope.defaultTarget,
        executablePath: String,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let directoryURL = try extensionDirectoryURL(in: scope, target: target)
        if fileManager.fileExists(atPath: directoryURL.path),
           !isOwned(directoryURL: directoryURL)
        {
            throw OMPExtensionConfigurationError.notOwned
        }
        if try status(
            in: scope,
            target: target,
            executablePath: executablePath,
            fileManager: fileManager
        ) == .installed {
            return false
        }
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        try atomicWrite(
            Data(ownershipContent.utf8),
            to: directoryURL.appendingPathComponent(ownershipFilename),
            fileManager: fileManager
        )
        try atomicWrite(
            Data(scriptContent(
                executablePath: executablePath,
                tokenPath: try tokenPath(in: scope, target: target)
            ).utf8),
            to: directoryURL.appendingPathComponent(scriptFilename),
            fileManager: fileManager
        )
        return true
    }

    @discardableResult
    static func uninstall(
        in scope: AgentIntegrationScope,
        target: OMPAgentTarget = OMPProfileScope.defaultTarget,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let directoryURL = try extensionDirectoryURL(in: scope, target: target)
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return false
        }
        guard isOwned(directoryURL: directoryURL) else {
            throw OMPExtensionConfigurationError.notOwned
        }
        try fileManager.removeItem(at: directoryURL)
        return true
    }

    static func extensionDirectoryURL(
        in scope: AgentIntegrationScope,
        target: OMPAgentTarget = OMPProfileScope.defaultTarget,
        for access: AgentIntegrationAccess = .write
    ) throws -> URL {
        try scope.managedURL(
            relativePath: target.extensionRelativePath,
            for: access
        )
    }

    /// 扩展脚本读的是**自己那个 agent 目录**里的令牌。
    ///
    /// status 与 install 必须用同一套推导，否则装完立刻会被判成 needsRepair：
    /// 内容比对里含这条路径。
    static func tokenPath(
        in scope: AgentIntegrationScope,
        target: OMPAgentTarget,
        for access: AgentIntegrationAccess = .write
    ) throws -> String {
        let agentDirectory = try scope.managedURL(
            relativePath: target.agentRelativePath,
            for: access
        )
        return OMPPermissionTokenStore.tokenURL(directory: agentDirectory).path
    }

    static func generatedFilesForSelfTest(
        executablePath: String = "/tmp/ThreadHelm",
        tokenPath: String = OMPPermissionTokenStore.tokenURL().path
    ) -> [String: String] {
        [
            scriptFilename: scriptContent(
                executablePath: executablePath,
                tokenPath: tokenPath
            ),
            ownershipFilename: ownershipContent,
        ]
    }

    private static func isOwned(directoryURL: URL) -> Bool {
        let ownershipURL = directoryURL.appendingPathComponent(ownershipFilename)
        return (try? String(contentsOf: ownershipURL, encoding: .utf8))
            == ownershipContent
    }

    private static func jsonString(_ value: String, fallback: String) -> String {
        let encoder = JSONEncoder()
        // 默认会把 / 转义成 \/。JSON 层面等价，但生成的脚本里满屏
        // "\/Users\/…" 既难读也难 grep。
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(value))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? fallback
    }

    private static func scriptContent(
        executablePath: String,
        tokenPath: String
    ) -> String {
        let encodedPath = jsonString(executablePath, fallback: "\"/usr/bin/true\"")
        let encodedGateURL = jsonString(
            OMPPermissionHookConstants.url,
            fallback: "\"\""
        )
        // 令牌路径写进脚本，令牌本身不写：轮换时不必重写扩展，
        // 而扩展文件的权限也不必按机密对待。
        let encodedTokenPath = jsonString(tokenPath, fallback: "\"\"")
        return """
        // \(marker)
        import type {
          ExtensionAPI,
          ExtensionContext
        } from "@oh-my-pi/pi-coding-agent";
        import { spawn } from "node:child_process";
        import { readFileSync } from "node:fs";

        const THREADHELM = \(encodedPath);
        const GATE_URL = \(encodedGateURL);
        const TOKEN_PATH = \(encodedTokenPath);
        const EXTENSION_DEADLINE_MS = \(
            OMPPermissionHookConstants.extensionDeadlineMilliseconds
        );
        let sequence = 0;

        function safeText(value: unknown, fallback: string): string {
          const text = typeof value === "string" ? value : "";
          return /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(text)
            ? text
            : fallback;
        }

        function emit(
          kind: string,
          ctx: ExtensionContext,
          outcome?: "success" | "task_failure" | "continuing"
        ): void {
          try {
            const session = safeText(
              ctx.sessionManager.getSessionId(),
              "omp-session-unknown"
            );
            sequence += 1;
            const body = {
              session_id: session,
              event_id: safeText(
                `${kind}:${session}:${sequence}`,
                `omp-event-${sequence}`
              ),
              sequence,
              ...(outcome ? { outcome } : {})
            };
            const child = spawn(
              THREADHELM,
              ["--agent-hook", "omp", kind],
              { stdio: ["pipe", "ignore", "ignore"] }
            );
            child.on("error", () => {});
            child.stdin.on("error", () => {});
            child.stdin.end(JSON.stringify(body));
          } catch (_) {
            // Observation is best-effort and must never affect OMP.
          }
        }

        // 审批闸门。与上面的观测 emit 有本质区别：那条是 best-effort、
        // 出错即算了；这条决定工具跑不跑，任何异常路径都必须显式拦截。
        //
        // OMP 在 handler 超时或抛异常时会自己回落成 block:true，但那条
        // 兜底只在 handler 真的失败时生效。若这里 catch 之后静默返回
        // undefined，工具就直接执行了——闸门形同虚设。所以下面每一条
        // 失败路径都显式 return block。
        async function requestApproval(
          event: { toolName?: string; toolCallId?: string; input?: unknown },
          ctx: ExtensionContext
        ): Promise<{ block: boolean; reason?: string } | undefined> {
          let token: string;
          try {
            token = readFileSync(TOKEN_PATH, "utf8").trim();
            if (!token) throw new Error("empty token");
          } catch (error) {
            return {
              block: true,
              reason:
                "ThreadHelm 审批闸门未就绪（读不到令牌），已按拒绝处理。"
            };
          }

          const controller = new AbortController();
          const timer = setTimeout(
            () => controller.abort(),
            EXTENSION_DEADLINE_MS
          );
          try {
            const response = await fetch(GATE_URL, {
              method: "POST",
              signal: controller.signal,
              headers: {
                "Content-Type": "application/json",
                "X-ThreadHelm-Hook-Token": token
              },
              body: JSON.stringify({
                hook_event_name: "PermissionRequest",
                tool_name: safeText(event.toolName, "UnknownTool"),
                tool_use_id: safeText(event.toolCallId, "omp-tool-call"),
                tool_input: event.input ?? {},
                session_id: safeText(
                  ctx.sessionManager.getSessionId(),
                  "omp-session-unknown"
                ),
                cwd: typeof process.cwd === "function" ? process.cwd() : ""
              })
            });
            if (!response.ok) {
              return {
                block: true,
                reason:
                  "ThreadHelm 未能确认这次操作（闸门返回 " +
                  response.status +
                  "），已按拒绝处理。"
              };
            }
            const verdict = await response.json();
            if (verdict && verdict.block === true) {
              return {
                block: true,
                reason:
                  typeof verdict.reason === "string" && verdict.reason
                    ? verdict.reason
                    : "用户拒绝了这次操作。"
              };
            }
            // 明确放行才放行。裁决体读不懂时不能当成同意。
            if (verdict && verdict.block === false) {
              return undefined;
            }
            return {
              block: true,
              reason: "ThreadHelm 返回了无法解读的裁决，已按拒绝处理。"
            };
          } catch (error) {
            const aborted = controller.signal.aborted;
            return {
              block: true,
              reason: aborted
                ? "等待 ThreadHelm 确认超时，已按拒绝处理。"
                : "无法连接 ThreadHelm 审批闸门，已按拒绝处理。"
            };
          } finally {
            clearTimeout(timer);
          }
        }

        export default function threadHelmStateObserver(omp: ExtensionAPI): void {
          omp.on("session_start", (_event, ctx) => emit("session_start", ctx));
          omp.on("agent_start", (_event, ctx) => emit("agent_start", ctx));
          omp.on("agent_end", (event, ctx) => {
            const last = event.messages[event.messages.length - 1];
            const outcome = event.willContinue
              ? "continuing"
              : last?.role === "assistant" && last.stopReason === "error"
                ? "task_failure"
                : "success";
            emit("agent_end", ctx, outcome);
          });
          omp.on("tool_call", async (event, ctx) => {
            emit("tool_call", ctx);
            return await requestApproval(event, ctx);
          });
          omp.on("tool_result", (_event, ctx) => emit("tool_result", ctx));
          omp.on("session_compact", (_event, ctx) => emit("session_compact", ctx));
          omp.on("session_shutdown", (_event, ctx) => emit("session_shutdown", ctx));
        }
        """
    }

    private static func atomicWrite(
        _ data: Data,
        to url: URL,
        fileManager: FileManager
    ) throws {
        try AgentIntegrationAtomicFileWriter.write(
            data,
            to: url,
            fileManager: fileManager
        )
    }
}

private let ompStateOnlyEventTypes: Set<String> = [
    "session_start",
    "agent_start",
    "agent_end",
    "tool_call",
    "tool_result",
    "session_compact",
    "session_shutdown",
]

private func ompStateOnlyEvent(_ event: AgentEvent) -> AgentEvent? {
    guard event.identity.agentID == .omp,
          ompStateOnlyEventTypes.contains(event.eventType)
    else { return nil }
    let state: ExecutionState
    let reason: AttentionReason
    switch event.eventType {
    case "session_start":
        state = .idle
        reason = .none
    case "agent_end":
        switch event.executionState {
        case .failed:
            state = .failed
            reason = .taskFailure
        case .running:
            state = .running
            reason = .none
        default:
            state = .completed
            reason = .reviewReady
        }
    case "session_shutdown":
        state = .offline
        reason = .none
    default:
        state = .running
        reason = .none
    }
    return AgentEvent(
        identity: event.identity,
        adapterVersion: event.adapterVersion,
        eventID: event.eventID,
        sequence: event.sequence,
        eventType: event.eventType,
        observedAt: event.observedAt,
        monotonicNanoseconds: event.monotonicNanoseconds,
        executionState: state,
        attentionReason: reason,
        actionability: normalizedOMPSessionID(event.identity.nativeID) != nil
            ? .openExactNativeSession
            : .viewOnly,
        evidenceQuality: event.evidenceQuality,
        freshness: event.freshness,
        title: "OMP 会话",
        activitySummary: nil,
        workingDirectory: nil
    )
}

func ompAgentEvent(
    from envelope: AgentTransportEnvelope,
    observedAt: Date
) -> AgentEvent? {
    guard envelope.agentID == .omp else { return nil }
    let state = envelope.redactedPayload["state"].flatMap {
        ExecutionState(rawValue: $0)
    }
        ?? .running
    let rawReason = envelope.redactedPayload["attentionReason"]
        .flatMap { AttentionReason(rawValue: $0) } ?? .none
    let reason: AttentionReason
    if envelope.eventType == "agent_end",
       state == .failed,
       rawReason == .taskFailure
    {
        reason = .taskFailure
    } else if envelope.eventType == "agent_end",
              state == .completed
    {
        reason = .reviewReady
    } else {
        reason = .none
    }
    let actionability: Actionability = envelope.nativeSessionCandidate.flatMap {
        normalizedOMPSessionID($0) != nil ? .openExactNativeSession : nil
    } ?? .viewOnly
    let evidence = envelope.redactedPayload["evidenceQuality"]
        .flatMap { EvidenceQuality(rawValue: $0) } ?? .officialHook
    let freshnessClass = envelope.redactedPayload["freshness"] ?? "fresh"
    let stale = freshnessClass == "stale" || state == .offline || state == .stale
    let nativeID = envelope.nativeSessionCandidate ?? "omp-session-unknown"
    return AgentEvent(
        identity: AgentSessionIdentity(agentID: .omp, nativeID: nativeID),
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
            expiresAt: stale ? observedAt : observedAt.addingTimeInterval(
                OMPAgentDefaults.staleAfter
            ),
            staleReason: stale ? "omp-session-shutdown-or-stale" : nil
        ),
        title: "OMP session",
        activitySummary: nil,
        workingDirectory: nil
    )
}

func discoverLocalOMPAgent(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
) -> AgentDiscovery {
    guard let executable = locateOMPExecutable(
        environment: environment,
        fileManager: fileManager
    ) else {
        return AgentDiscovery(
            isInstalled: false,
            version: nil,
            compatibility: .unknown
        )
    }
    let version = ompVersion(executableURL: executable)
    return versionValidatedAgentDiscovery(
        agentID: .omp,
        isInstalled: true,
        components: version.map {
            [AgentVersionComponent(key: "version", label: "Version", value: $0)]
        } ?? []
    )
}

func locateOMPExecutable(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
) -> URL? {
    if let override = environment["THREADHELM_OMP_EXECUTABLE"],
       !override.isEmpty,
       fileManager.isExecutableFile(atPath: override)
    {
        return URL(fileURLWithPath: override)
    }
    let pathCandidates = (environment["PATH"] ?? "")
        .split(separator: ":")
        .map { String($0) }
        + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    for directory in pathCandidates {
        let candidate = URL(fileURLWithPath: directory)
            .appendingPathComponent("omp")
        if fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}

private func ompVersion(executableURL: URL) -> String? {
    for _ in 0..<2 {
        if let version = probeOMPVersion(executableURL: executableURL) {
            return version
        }
    }
    return nil
}

private func probeOMPVersion(executableURL: URL) -> String? {
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
