import AppKit
import Foundation

enum DynamicIslandPreviewError: LocalizedError {
    case unknownState(String)
    case bitmapCreationFailed
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .unknownState(let state):
            return "未知灵动岛预览状态：\(state)"
        case .bitmapCreationFailed:
            return "无法创建 2x 位图"
        case .pngEncodingFailed:
            return "无法编码 PNG"
        }
    }
}

enum DynamicIslandPreviewState: String, CaseIterable {
    case capsuleConfirmation = "capsule-confirmation"
    case capsuleRunning = "capsule-running"
    case capsuleWaiting = "capsule-waiting"
    case capsuleCompleted = "capsule-completed"
    case capsuleFailed = "capsule-failed"
    case capsuleIdle = "capsule-idle"
    case capsuleCodexExited = "capsule-codex-exited"
    case tasks
    case confirmTool = "confirm-tool"
    case confirmQuestion = "confirm-question"
    case confirmPlan = "confirm-plan"
    case quotaCodex = "quota-codex"
    case quotaClaude = "quota-claude"
    case quotaRefreshing = "quota-refreshing"
    case quotaLoading = "quota-loading"
    case quotaStale = "quota-stale"
    case quotaFirstFailure = "quota-first-failure"
    case quotaUnavailable = "quota-unavailable"
    /// 五个 Agent 的完整渲染矩阵：可安装、可修复、版本未验证、用户已停用、
    /// 读取失败、以及不受管的 Codex。行内控件的 AppKit 翻译层（显隐、配色、
    /// 按钮与文本列的相对位置）只有在这里才能被真正看见。
    case agents
    /// 自动集成开关的待确认态，外加行内的"正在配置…"与失败提示。
    case agentsConfiguring = "agents-configuring"
}

func dynamicIslandPreviewStateNames() -> [String] {
    DynamicIslandPreviewState.allCases.map(\.rawValue)
}

func dynamicIslandPreviewSize(for state: DynamicIslandPreviewState) -> NSSize {
    switch state {
    case .capsuleConfirmation,
         .capsuleRunning,
         .capsuleWaiting,
         .capsuleCompleted,
         .capsuleFailed,
         .capsuleIdle,
         .capsuleCodexExited:
        return dynamicIslandCapsuleSize
    case .tasks:
        return dynamicIslandTaskSize
    case .confirmTool, .confirmQuestion, .confirmPlan:
        return dynamicIslandConfirmationSize
    case .quotaCodex,
         .quotaClaude,
         .quotaRefreshing,
         .quotaLoading,
         .quotaStale,
         .quotaFirstFailure,
         .quotaUnavailable:
        return dynamicIslandQuotaSize
    case .agents, .agentsConfiguring:
        return dynamicIslandTaskSize
    }
}

func renderDynamicIslandPreview(state: String, to outputURL: URL) throws {
    guard let previewState = DynamicIslandPreviewState(rawValue: state) else {
        throw DynamicIslandPreviewError.unknownState(state)
    }
    try renderDynamicIslandPreview(state: previewState, to: outputURL)
}

func renderDynamicIslandPreview(
    state: DynamicIslandPreviewState,
    to outputURL: URL
) throws {
    _ = NSApplication.shared
    let fixedNow = dynamicIslandPreviewReferenceDate
    let previousDateProvider = dynamicIslandCurrentDate
    dynamicIslandCurrentDate = { fixedNow }
    defer { dynamicIslandCurrentDate = previousDateProvider }

    let size = dynamicIslandPreviewSize(for: state)
    let view = dynamicIslandPreviewView(for: state)
    view.frame = NSRect(origin: .zero, size: size)
    view.setFrameSize(size)
    view.needsLayout = true
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()

    let pngData = try pngDataForDynamicIslandPreview(view: view, size: size)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try pngData.write(to: outputURL, options: .atomic)
}

private let dynamicIslandPreviewReferenceDate =
    Date(timeIntervalSince1970: 1_800_000_000)
private let dynamicIslandPreviewWorkingDirectory = "/tmp/threadhelm/PetBar"

private func dynamicIslandPreviewView(
    for state: DynamicIslandPreviewState
) -> NSView {
    let snapshot = dynamicIslandPreviewSnapshot(for: state)
    let root = DynamicIslandRootViewController()
    let presentationState = dynamicIslandPreviewPresentationState(for: state)
    if let presentation = dynamicIslandPreviewConfirmationPresentation(for: state) {
        let confirmationController = DynamicIslandConfirmationViewController()
        root.installConfirmationViewController(confirmationController)
        root.apply(snapshot: snapshot, state: presentationState)
        root.applyConfirmationPresentation(presentation)
    } else {
        // 三种瞬态各占一行，外加待确认的自动集成开关，一张图看全。
        // 必须在 apply 之前设置：瞬态只改字典，真正把行建出来的是 apply 里
        // 那次 reloadData，顺序反过来表格会停在上一次的 0 行状态。
        if state == .agentsConfiguring {
            root.setAgentIntegrationTransientState(.configuring, for: .claudeCode)
            root.setAgentIntegrationTransientState(
                .failed("配置失败：文件只读；原配置已恢复"),
                for: .zcode
            )
            root.setAgentIntegrationTransientState(
                .noop("版本未验证，已跳过"),
                for: .cursor
            )
        }
        root.apply(snapshot: snapshot, state: presentationState)
        if state == .agentsConfiguring {
            root.armAgentAutoIntegrationConfirmationForPreview()
        }
    }
    root.view.frame = NSRect(
        origin: .zero,
        size: dynamicIslandPreviewSize(for: state)
    )
    return root.view
}

private func dynamicIslandPreviewPresentationState(
    for state: DynamicIslandPreviewState
) -> DynamicIslandPresentationState {
    switch state {
    case .capsuleConfirmation,
         .capsuleRunning,
         .capsuleWaiting,
         .capsuleCompleted,
         .capsuleFailed,
         .capsuleIdle,
         .capsuleCodexExited:
        return .capsule
    case .tasks:
        return .expanded(.tasks)
    case .confirmTool, .confirmQuestion, .confirmPlan:
        return .expanded(.confirmation)
    case .quotaCodex,
         .quotaClaude,
         .quotaRefreshing,
         .quotaLoading,
         .quotaStale,
         .quotaFirstFailure,
         .quotaUnavailable:
        return .expanded(.quota)
    case .agents, .agentsConfiguring:
        return .expanded(.agents)
    }
}

/// 覆盖 Agents 页每一条渲染分支的固定夹具。
/// 刻意让五行落在五种不同的控件形态上，任何一种回归都能一眼看出来。
private func dynamicIslandPreviewAgentStatuses() -> [AgentRuntimeStatus] {
    func status(
        _ agentID: AgentID,
        installed: Bool,
        compatibility: AgentCompatibility,
        integrationStatus: AgentIntegrationStatus?,
        version: String?,
        health: AgentHealth,
        summary: String
    ) -> AgentRuntimeStatus? {
        guard let metadata = builtInAgentMetadata().first(where: {
            $0.id == agentID
        }) else { return nil }
        return AgentRuntimeStatus(
            metadata: metadata,
            discovery: AgentDiscovery(
                isInstalled: installed,
                version: version,
                compatibility: compatibility
            ),
            integrationStatus: integrationStatus,
            diagnostics: AgentDiagnostics(
                health: health,
                summary: summary,
                counters: [:]
            ),
            activeSessionCount: agentID == .codex ? 2 : 0,
            attentionCount: agentID == .claudeCode ? 1 : 0
        )
    }

    return [
        // 不受管：纯文本，永远不该出现按钮。
        status(
            .codex,
            installed: true,
            compatibility: .validated,
            integrationStatus: .notManaged,
            version: "0.145.0",
            health: .healthy,
            summary: "本机可用"
        ),
        // 已验证 + 未集成 → [ 一键安装 ]
        status(
            .claudeCode,
            installed: true,
            compatibility: .validated,
            integrationStatus: .notInstalled,
            version: "2.1.226",
            health: .healthy,
            summary: "本机可用"
        ),
        // 已验证 + 配置漂移 → [ 立即修复 ]
        status(
            .zcode,
            installed: true,
            compatibility: .validated,
            integrationStatus: .needsRepair,
            version: "3.7.6",
            health: .degraded,
            summary: "受管配置漂移"
        ),
        // 版本未验证 → 只读 + tooltip，绝不能给按钮
        status(
            .cursor,
            installed: true,
            compatibility: .unvalidated,
            integrationStatus: .notInstalled,
            version: "3.16.0",
            health: .healthy,
            summary: "本机可用"
        ),
        // 用户在厂商配置里显式停用 → 只读，尊重用户意图
        status(
            .omp,
            installed: true,
            compatibility: .validated,
            integrationStatus: .disabled,
            version: "17.3.2",
            health: .healthy,
            summary: "本机可用"
        ),
    ].compactMap { $0 }
}

private func dynamicIslandPreviewSnapshot(
    for state: DynamicIslandPreviewState
) -> ActivityDashboardSnapshot {
    let now = dynamicIslandPreviewReferenceDate
    let tasks = dynamicIslandPreviewTasks(now: now)
    let allQuotaStates = dynamicIslandPreviewQuotaStates(now: now)
    let queueKind: ClaudePermissionInteractionKind? = {
        switch state {
        case .capsuleConfirmation, .confirmTool:
            return .toolApproval
        case .confirmQuestion:
            return .askUserQuestion
        case .confirmPlan:
            return .exitPlanMode
        default:
            return nil
        }
    }()
    let queue = queueKind.map {
        dynamicIslandPreviewQueue(kind: $0, now: now)
    } ?? .empty
    let selectedProvider: QuotaProvider
    switch state {
    case .quotaClaude, .quotaRefreshing, .quotaFirstFailure, .quotaUnavailable:
        selectedProvider = .claudeCode
    default:
        selectedProvider = .codex
    }

    let visibleTasks: [TaskProgressItem]
    let acknowledged: Set<String>
    switch state {
    case .capsuleRunning:
        visibleTasks = [tasks.running]
        acknowledged = []
    case .capsuleWaiting:
        visibleTasks = [tasks.running, tasks.waiting]
        acknowledged = []
    case .capsuleCompleted:
        visibleTasks = [tasks.completed]
        acknowledged = []
    case .capsuleFailed:
        visibleTasks = [tasks.failed, tasks.completed]
        acknowledged = []
    case .capsuleIdle:
        visibleTasks = [tasks.completed]
        acknowledged = Set(
            [terminalTaskAcknowledgementKey(for: tasks.completed)]
                .compactMap { $0 }
        )
    case .capsuleCodexExited:
        visibleTasks = []
        acknowledged = []
    default:
        visibleTasks = [
            tasks.running,
            tasks.waiting,
            tasks.completed,
            tasks.failed,
        ]
        acknowledged = []
    }

    let availableProviders: [QuotaProvider]
    if state == .capsuleCodexExited {
        availableProviders = []
    } else if state == .quotaUnavailable {
        availableProviders = [.codex]
    } else {
        availableProviders = QuotaProvider.allCases
    }
    var snapshot = ActivityDashboardSnapshot(
        taskCollection: TaskProgressCollectionSnapshot.displaying(visibleTasks),
        quotaStates: state == .capsuleCodexExited
            ? [:]
            : quotaStates(for: state, allStates: allQuotaStates),
        availableProviders: availableProviders,
        selectedQuotaProvider: selectedProvider,
        permissionQueue: queue,
        acknowledgedTerminalTaskKeys: acknowledged,
        isTaskRefreshing: state == .quotaLoading,
        codexDesktopRunning: state != .capsuleCodexExited
    )
    switch state {
    case .agents, .agentsConfiguring:
        snapshot.agentStatuses = dynamicIslandPreviewAgentStatuses()
        snapshot.agentEventChannelAvailable = true
        // 已确认过、但当前关闭：预览里由 agentsConfiguring 走待确认态，
        // 所以这里保持未确认，让两张图分别覆盖"未确认"和"待确认"。
        snapshot.isAutoIntegrationEnabled = false
        snapshot.hasConfirmedAutoIntegration = false
    default:
        break
    }
    return snapshot
}

private func quotaStates(
    for state: DynamicIslandPreviewState,
    allStates: [QuotaProvider: QuotaProviderState]
) -> [QuotaProvider: QuotaProviderState] {
    switch state {
    case .quotaRefreshing:
        var refreshing = allStates[.claudeCode] ?? QuotaProviderState()
        refreshing.statusText = "正在更新，继续显示上次数据"
        refreshing.isRefreshing = true
        refreshing.isStale = false
        return [
            .codex: allStates[.codex] ?? QuotaProviderState(),
            .claudeCode: refreshing,
        ]
    case .quotaLoading:
        return [
            .codex: QuotaProviderState(
                rows: [],
                resetCredits: nil,
                statusText: "正在读取额度…",
                errorText: nil,
                updatedAt: nil,
                isRefreshing: true,
                isStale: false
            ),
            .claudeCode: allStates[.claudeCode] ?? QuotaProviderState(),
        ]
    case .quotaStale:
        var stale = allStates[.codex] ?? QuotaProviderState()
        stale.statusText = "8月10日 10:00 更新失败"
        stale.errorText = "网络不可用"
        stale.isStale = true
        stale.isRefreshing = false
        return [.codex: stale, .claudeCode: allStates[.claudeCode] ?? QuotaProviderState()]
    case .quotaFirstFailure:
        return [
            .codex: allStates[.codex] ?? QuotaProviderState(),
            .claudeCode: QuotaProviderState(
                rows: [],
                resetCredits: nil,
                statusText: "登录后点击刷新",
                errorText: "请先登录 Claude Code",
                updatedAt: nil,
                isRefreshing: false,
                isStale: false
            ),
        ]
    case .quotaUnavailable:
        return [.codex: allStates[.codex] ?? QuotaProviderState()]
    default:
        return allStates
    }
}

private func dynamicIslandPreviewTasks(now: Date) -> (
    running: TaskProgressItem,
    waiting: TaskProgressItem,
    completed: TaskProgressItem,
    failed: TaskProgressItem
) {
    func publicMessage(
        _ minutesAgo: TimeInterval,
        _ text: String,
        source: AgentID,
        sessionKey: String
    ) -> AgentActivityEntry {
        AgentActivityEntry(
            id: AgentActivityEventID(
                source: source,
                sessionKey: sessionKey,
                stableSourceKey: "message-\(Int(minutesAgo * 60))"
            ),
            occurredAt: now.addingTimeInterval(-minutesAgo * 60),
            sourceOrder: UInt64(minutesAgo * 60),
            text: text
        )
    }
    let running = TaskProgressItem(
        title: "继续完成 ZCode 退役清单",
        kind: .running,
        startedAt: now.addingTimeInterval(-321),
        updatedAt: now.addingTimeInterval(-20),
        source: .codex,
        activityText: "正在运行验证并整理结果",
        threadID: "thread-threadhelm-dynamic-island",
        workingDirectory: dynamicIslandPreviewWorkingDirectory,
        projection: AgentActivityProjection(publicMessages: [
            publicMessage(
                9,
                "读取 Dynamic Island 计划",
                source: .codex,
                sessionKey: "thread-threadhelm-dynamic-island"
            ),
            publicMessage(
                8,
                "核对 Codex 与 Claude 的公开活动事件映射",
                source: .codex,
                sessionKey: "thread-threadhelm-dynamic-island"
            ),
            publicMessage(
                7,
                "更新任务筛选与运行状态识别",
                source: .codex,
                sessionKey: "thread-threadhelm-dynamic-island"
            ),
            publicMessage(
                6,
                "运行构建检查",
                source: .codex,
                sessionKey: "thread-threadhelm-dynamic-island"
            ),
            publicMessage(
                4,
                "验证长活动内容完整换行显示，不截断公开输出，并保留所有安全事件供滚动查看",
                source: .codex,
                sessionKey: "thread-threadhelm-dynamic-island"
            ),
            publicMessage(
                2,
                "检查模型图标、按钮间距与额度页面布局",
                source: .codex,
                sessionKey: "thread-threadhelm-dynamic-island"
            ),
            publicMessage(
                1,
                "正在整理本地验证摘要，核对构建、自测、隐私检查与界面预览结果；继续检查 Codex 与 Claude 最新公开输出是否及时替换；确认长内容不再按字符截断，并通过滚动区域保留全部细节；最后汇总任务状态、开始时间、持续时间和所有安全事件",
                source: .codex,
                sessionKey: "thread-threadhelm-dynamic-island"
            ),
        ])
    )
    let waiting = TaskProgressItem(
        title: "确认 Claude 操作",
        kind: .waitingForInput,
        startedAt: now.addingTimeInterval(-12 * 60),
        updatedAt: now.addingTimeInterval(-2 * 60),
        source: .claudeCode,
        activityText: "等待工具授权",
        sessionID: "87654321-4321-4321-4321-cba987654321",
        workingDirectory: dynamicIslandPreviewWorkingDirectory,
        projection: AgentActivityProjection(
            publicMessages: [publicMessage(
                2,
                "Claude 请求确认下一步",
                source: .claudeCode,
                sessionKey: "87654321-4321-4321-4321-cba987654321"
            )]
        )
    )
    let completed = TaskProgressItem(
        title: "生成设计快照",
        kind: .completed,
        startedAt: now.addingTimeInterval(-22 * 60),
        updatedAt: now.addingTimeInterval(-14 * 60),
        source: .codex,
        threadID: "thread-threadhelm-preview-done",
        workingDirectory: dynamicIslandPreviewWorkingDirectory,
        projection: AgentActivityProjection(
            publicMessages: [publicMessage(
                14,
                "预览矩阵已生成",
                source: .codex,
                sessionKey: "thread-threadhelm-preview-done"
            )]
        )
    )
    let failed = TaskProgressItem(
        title: "同步远端状态",
        kind: .failed,
        startedAt: now.addingTimeInterval(-18 * 60),
        updatedAt: now.addingTimeInterval(-9 * 60),
        source: .claudeCode,
        activityText: "终端返回错误，等待查看",
        sessionID: "12345678-1234-1234-1234-123456789abc",
        workingDirectory: dynamicIslandPreviewWorkingDirectory,
        projection: AgentActivityProjection(
            publicMessages: [publicMessage(
                9,
                "命令退出，需要人工确认",
                source: .claudeCode,
                sessionKey: "12345678-1234-1234-1234-123456789abc"
            )]
        )
    )
    return (running, waiting, completed, failed)
}

private func dynamicIslandPreviewQueue(
    kind: ClaudePermissionInteractionKind,
    now: Date
) -> ClaudePermissionQueueSnapshot {
    let current = ClaudePermissionQueueItem(
        requestID: dynamicIslandPreviewRequestID(for: kind),
        interactionKind: kind,
        title: dynamicIslandPreviewQueueTitle(for: kind),
        sessionID: "preview-session",
        arrivedAt: now.addingTimeInterval(-90)
    )
    let pending = ClaudePermissionQueueItem(
        requestID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        interactionKind: .askUserQuestion,
        title: "补充验证范围",
        sessionID: "preview-session",
        arrivedAt: now.addingTimeInterval(-30)
    )
    return ClaudePermissionQueueSnapshot(current: current, pending: [pending])
}

private func dynamicIslandPreviewQueueTitle(
    for kind: ClaudePermissionInteractionKind
) -> String {
    switch kind {
    case .toolApproval:
        return "允许读取项目文件"
    case .askUserQuestion:
        return "回答验证问题"
    case .exitPlanMode:
        return "审批执行计划"
    }
}

private func dynamicIslandPreviewRequestID(
    for kind: ClaudePermissionInteractionKind
) -> UUID {
    switch kind {
    case .toolApproval:
        return UUID(uuidString: "aaaaaaaa-1111-2222-3333-444444444444")!
    case .askUserQuestion:
        return UUID(uuidString: "bbbbbbbb-1111-2222-3333-444444444444")!
    case .exitPlanMode:
        return UUID(uuidString: "cccccccc-1111-2222-3333-444444444444")!
    }
}

private func dynamicIslandPreviewQuotaStates(
    now: Date
) -> [QuotaProvider: QuotaProviderState] {
    let resetCredits = CodexResetCreditsSnapshot(
        credits: [
            CodexResetCredit(
                id: "reset-a",
                status: .available,
                expiresAt: now.addingTimeInterval(6 * 3_600)
            ),
            CodexResetCredit(
                id: "reset-b",
                status: .available,
                expiresAt: now.addingTimeInterval(30 * 3_600)
            ),
        ],
        reportedAvailableCount: 2,
        updatedAt: now.addingTimeInterval(-60)
    )
    return [
        .codex: QuotaProviderState(
            rows: [
                QuotaRow(
                    name: "周额度",
                    remainingPercent: 64,
                    resetsAt: now.addingTimeInterval(5 * 24 * 3_600)
                )
            ],
            resetCredits: resetCredits,
            statusText: "今天 10:00 更新",
            errorText: nil,
            updatedAt: now.addingTimeInterval(-60),
            isRefreshing: false,
            isStale: false
        ),
        .claudeCode: QuotaProviderState(
            rows: [
                QuotaRow(
                    name: "5 小时",
                    remainingPercent: 91,
                    resetsAt: now.addingTimeInterval(4 * 3_600)
                ),
                QuotaRow(
                    name: "周额度",
                    remainingPercent: 83,
                    resetsAt: now.addingTimeInterval(6 * 24 * 3_600)
                ),
                QuotaRow(
                    name: "Fable",
                    remainingPercent: 97,
                    resetsAt: nil,
                    resetDescription: "今天 12:00"
                ),
            ],
            resetCredits: nil,
            statusText: "今天 10:00 更新",
            errorText: nil,
            updatedAt: now.addingTimeInterval(-80),
            isRefreshing: false,
            isStale: false
        ),
    ]
}

private func dynamicIslandPreviewConfirmationPresentation(
    for state: DynamicIslandPreviewState
) -> ClaudePermissionPresentation? {
    let kind: ClaudePermissionInteractionKind
    switch state {
    case .confirmTool:
        kind = .toolApproval
    case .confirmQuestion:
        kind = .askUserQuestion
    case .confirmPlan:
        kind = .exitPlanMode
    default:
        return nil
    }
    let prompt = dynamicIslandPreviewPrompt(kind: kind)
    return ClaudePermissionPresentation(
        prompt: prompt,
        queue: dynamicIslandPreviewQueue(
            kind: kind,
            now: dynamicIslandPreviewReferenceDate
        ),
        onDecision: { _ in }
    )
}

private func dynamicIslandPreviewPrompt(
    kind: ClaudePermissionInteractionKind
) -> ClaudePermissionPrompt {
    let requestID = dynamicIslandPreviewRequestID(for: kind)
    switch kind {
    case .toolApproval:
        return ClaudePermissionPrompt(
            requestID: requestID,
            interactionKind: kind,
            toolName: "Read",
            sessionID: "preview-session",
            workingDirectory: dynamicIslandPreviewWorkingDirectory,
            title: "允许读取项目文件",
            message: "Claude 想读取 Dynamic Island 实现文件以完成验证。",
            planText: nil,
            questions: [],
            originalToolInput: [
                "file_path": dynamicIslandPreviewWorkingDirectory
                    + "/macos/ThreadHelm/README.md"
            ],
            suggestions: [
                ClaudePermissionSuggestion(
                    title: "本仓库读取",
                    rawValue: ["allow": "repository-read"]
                ),
                ClaudePermissionSuggestion(
                    title: "本次验证目录",
                    rawValue: ["allow": "dynamic-island-preview"]
                ),
            ]
        )
    case .askUserQuestion:
        return ClaudePermissionPrompt(
            requestID: requestID,
            interactionKind: kind,
            toolName: "AskUserQuestion",
            sessionID: "preview-session",
            workingDirectory: dynamicIslandPreviewWorkingDirectory,
            title: "回答验证问题",
            message: "请选择本轮要优先验证的范围。",
            planText: nil,
            questions: [
                ClaudeQuestion(
                    answerKey: "scope",
                    header: "优先范围",
                    options: [
                        ClaudeQuestionOption(label: "视觉矩阵", detail: "检查 17 张预览"),
                        ClaudeQuestionOption(label: "自测覆盖", detail: "检查 parser 和尺寸"),
                    ],
                    allowsMultipleSelection: false
                ),
                ClaudeQuestion(
                    answerKey: "checks",
                    header: "需要运行的检查",
                    options: [
                        ClaudeQuestionOption(label: "构建", detail: nil),
                        ClaudeQuestionOption(label: "隐私审计", detail: nil),
                        ClaudeQuestionOption(label: "verify-only", detail: nil),
                    ],
                    allowsMultipleSelection: true
                ),
            ],
            originalToolInput: ["questions": []],
            suggestions: []
        )
    case .exitPlanMode:
        return ClaudePermissionPrompt(
            requestID: requestID,
            interactionKind: kind,
            toolName: "ExitPlanMode",
            sessionID: "preview-session",
            workingDirectory: dynamicIslandPreviewWorkingDirectory,
            title: "审批执行计划",
            message: "Claude 已整理一个三步验证计划。",
            planText: """
            1. 生成 Dynamic Island 17 个确定性预览。
            2. 对比任务、确认、额度三组设计目标。
            3. 运行构建、自测、隐私和 verify-only 检查。
            """,
            questions: [],
            originalToolInput: ["plan": "dynamic island verification"],
            suggestions: []
        )
    }
}

private func pngDataForDynamicIslandPreview(
    view: NSView,
    size: NSSize
) throws -> Data {
    let scale = 2
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width) * scale,
        pixelsHigh: Int(size.height) * scale,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw DynamicIslandPreviewError.bitmapCreationFailed
    }
    bitmap.size = size

    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw DynamicIslandPreviewError.bitmapCreationFailed
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()
    view.cacheDisplay(in: view.bounds, to: bitmap)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw DynamicIslandPreviewError.pngEncodingFailed
    }
    return data
}
