//
//  AppDelegate.swift
//  ThreadHelm
//
//  模块职责：应用委托——灵动岛/状态栏项生命周期、窗口层级调整、
//  额度刷新编排（Codex/Claude/重置额度）、任务进度定时刷新、
//  Claude 权限 Hook 启动与终端打开回退。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

let threadHelmStatusItemLength = NSStatusItem.variableLength

func threadHelmActivationPolicy(
    panelHidden: Bool
) -> NSApplication.ActivationPolicy {
    _ = panelHidden
    return .regular
}

func configureThreadHelmStatusButton(_ button: NSStatusBarButton?) {
    guard let button else { return }
    button.title = "ThreadHelm"
    // Keep the recovery entry short and unambiguous. On crowded menu bars,
    // an icon plus title is often compressed back to an unidentified icon.
    button.image = nil
    button.imagePosition = .noImage
    button.toolTip = "ThreadHelm · \(threadHelmVisibilityHotKeyDisplayName) 显示/隐藏"
    button.setAccessibilityLabel("ThreadHelm")
    button.setAccessibilityHelp(
        "打开 ThreadHelm 菜单；隐藏后可选择“显示”或按 \(threadHelmVisibilityHotKeyDisplayName) 恢复面板"
    )
}

func makeThreadHelmDockIcon(bundle: Bundle = .main) -> NSImage? {
    let image = bundle.url(
        forResource: "ThreadHelm",
        withExtension: "icns"
    ).flatMap(NSImage.init(contentsOf:))
        ?? NSImage(
            systemSymbolName: "bird.fill",
            accessibilityDescription: "ThreadHelm"
        )
    image?.isTemplate = false
    image?.accessibilityDescription = "ThreadHelm"
    return image
}

struct AgentAutoIntegrationBackoffKey: Hashable {
    let agentID: AgentID
    let version: String
}

/// 一次集成操作的记账结论。抽成独立类型是为了让"结果如何影响退避"这条
/// 规则可以被单独断言——它曾经把不收敛的成功记成成功，直接导致无界写盘循环。
enum AgentIntegrationAccountingOutcome: Equatable {
    /// 真正收敛：清失败计数。
    case succeeded
    /// 版本门禁跳过。不写盘，但要退避，否则每个周期都会重试同一个未验证版本。
    case skippedUnvalidated
    /// 抛错，或写入报告成功但重新探测未收敛。
    case failed
}

/// - Parameter statusAfter: 操作后**重新探测**到的状态。报告 `.installed` 但
///   这里不是 `.installed`，说明写入与状态探测判断不一致，必须按失败记账。
func agentIntegrationAccountingOutcome(
    result: AgentIntegrationOperationResult?,
    statusAfter: AgentIntegrationStatus?,
    threw: Bool
) -> AgentIntegrationAccountingOutcome {
    if threw { return .failed }
    if result == .unchanged {
        // `.unchanged` 有两个来源：版本门禁跳过，以及配置其实已就位的幂等
        // no-op。后者是成功语义，记成失败会让真正需要的自动集成被退避压制。
        return statusAfter == .installed ? .succeeded : .skippedUnvalidated
    }
    if result == .installed || result == .repaired {
        return statusAfter == .installed ? .succeeded : .failed
    }
    return .failed
}

struct AgentAutoIntegrationCandidate: Equatable {
    let agentID: AgentID
    let version: String
}

/// 自动集成的候选选取。双门禁、候选过滤与"一轮只处理一个"都在这里，
/// 便于自测在不驱动 AppKit 与磁盘的前提下断言。
func agentAutoIntegrationCandidate(
    statuses: [AgentRuntimeStatus],
    isEnabled: Bool,
    hasConfirmed: Bool,
    canAttempt: (AgentID, String) -> Bool
) -> AgentAutoIntegrationCandidate? {
    guard isEnabled, hasConfirmed else { return nil }
    for status in statuses {
        guard status.discovery.isInstalled,
              status.discovery.compatibility == .validated,
              status.integrationStatus == .notInstalled
        else {
            continue
        }
        let version = agentAutoIntegrationBackoffVersion(for: status)
        guard canAttempt(status.metadata.id, version) else { continue }
        // 一轮只处理一个：全局互斥本就串行，其余候选交给下一个刷新周期。
        return AgentAutoIntegrationCandidate(
            agentID: status.metadata.id,
            version: version
        )
    }
    return nil
}

/// 退避键里的版本。所有路径必须共用这一个实现，否则记账键与门禁键会错开。
func agentAutoIntegrationBackoffVersion(for status: AgentRuntimeStatus) -> String {
    status.discovery.version
        ?? status.discovery.versionComponents.first?.value
        ?? "default"
}

/// 自动集成的节流门。
///
/// 关键设计：**每一次自动尝试都记时间戳，无论成败**。只按失败退避是不够的——
/// 写入报告 `.installed`、但随后重新探测仍是 `.notInstalled`（适配器写入与状态
/// 探测判断不一致，或外部进程把配置改了回去）时，成功会立即销账，而成功又会
/// 触发下一轮评估，于是形成没有任何延迟的写盘循环。最小间隔让这条路径也有界。
final class AgentAutoIntegrationBackoffGate {
    /// 无论上一次结果如何，同一 (agentID, version) 两次自动尝试之间的下限。
    /// 与刷新周期同量级即可，目的是让不收敛的"成功"也无法紧密重试。
    static let minimumAttemptInterval: TimeInterval = 300

    private let lock = NSLock()
    private var failureCounts: [AgentAutoIntegrationBackoffKey: Int] = [:]
    private var lastAttemptTimestamps: [AgentAutoIntegrationBackoffKey: Date] = [:]
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func canAttempt(agentID: AgentID, version: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = AgentAutoIntegrationBackoffKey(agentID: agentID, version: version)
        guard let last = lastAttemptTimestamps[key] else { return true }
        let failureDelay: TimeInterval
        switch failureCounts[key] ?? 0 {
        case 0: failureDelay = 0
        case 1: failureDelay = 300       // 5 min
        case 2: failureDelay = 900       // 15 min
        default: failureDelay = 3600     // 60 min
        }
        let delay = max(failureDelay, Self.minimumAttemptInterval)
        return now().timeIntervalSince(last) >= delay
    }

    /// 每次自动尝试**发起时**调用，是最小间隔的唯一来源。
    func recordAttempt(agentID: AgentID, version: String) {
        lock.lock()
        defer { lock.unlock() }
        lastAttemptTimestamps[
            AgentAutoIntegrationBackoffKey(agentID: agentID, version: version)
        ] = now()
    }

    func recordFailure(agentID: AgentID, version: String) {
        lock.lock()
        defer { lock.unlock() }
        let key = AgentAutoIntegrationBackoffKey(agentID: agentID, version: version)
        failureCounts[key, default: 0] += 1
        lastAttemptTimestamps[key] = now()
    }

    /// 只清失败计数，**保留最近尝试时间**——否则不收敛的成功会立刻解锁重试。
    func recordSuccess(agentID: AgentID, version: String) {
        lock.lock()
        defer { lock.unlock() }
        failureCounts.removeValue(
            forKey: AgentAutoIntegrationBackoffKey(agentID: agentID, version: version)
        )
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let quotaClient = CodexQuotaClient()
    private let claudeQuotaClient = ClaudeQuotaClient()
    private let quotaProviderPreference = QuotaProviderPreference()
    private let healthWriter = RuntimeHealthWriter()
    private let dashboardStore = ActivityDashboardStore()
    private let agentRegistry = AgentRegistry.builtIn
    private let agentLiveEventStore = AgentLiveEventStore()
    private let agentOpenMeasurementStore = AgentOpenMeasurementStore()
    private let agentAttentionInterruptionGate =
        AgentAttentionInterruptionGate()
    private var agentLiveReductionGate = AgentLiveReductionGate()
    private var agentEventChannelAvailable = false
    private var lastClaudePermissionOpenResult: OpenResult?
    private var lastPolledTaskCollection = TaskProgressCollectionSnapshot
        .displaying([])
    private var claudePermissionCoordinator: ClaudePermissionCoordinator!
    private var dynamicIslandController: DynamicIslandWindowController!
    private var dynamicIslandConfirmationPresenter:
        DynamicIslandConfirmationPresenter!
    private var claudePermissionHookServer: ClaudePermissionHookServer?
    private var agentEventSocketServer: AgentEventSocketServer?
    private var agentHookDropTimer: Timer?
    private var screenParametersObserver: NSObjectProtocol?
    private var statusItem: NSStatusItem?
    private var visibilityHotKey: ThreadHelmVisibilityHotKey?
    private var refreshTimer: Timer?
    private var taskProgressTimer: Timer?
    private var windowStackRefreshTimer: Timer?
    private var agentHealthRefreshTimer: Timer?
    private var isPerformingIntegration = false
    private let autoIntegrationDefaultsKey = "dev.threadhelm.agent-auto-integration.enabled"
    /// 一次性确认。开关本身可以随时开关，但在用户显式确认过"会写入厂商配置"
    /// 之前，自动路径一律不落盘。
    private let autoIntegrationConfirmedDefaultsKey =
        "dev.threadhelm.agent-auto-integration.confirmed"
    private let autoIntegrationBackoffGate = AgentAutoIntegrationBackoffGate()
    private var agentRuntimeRefreshGate = TaskProgressRefreshGate()
    private var pendingAgentRuntimeRefreshCompletions: [() -> Void] = []
    private let integrationSerialQueue = DispatchQueue(label: "dev.threadhelm.agent-integration-serial")
    private let taskProgressReaderStore = TaskProgressRefreshReaderStore()
    private var refreshingQuotaProviders = Set<QuotaProvider>()
    private var taskProgressRefreshGate = TaskProgressRefreshGate()
    private var isPanelHiddenByUser = false
    private var cachedCodexDesktopRunning = false
    private lazy var codexOverlayNotificationSynchronizer: CodexOverlayNotificationSynchronizer = {
        let paths = CodexOverlayNotificationPaths.current()
        return CodexOverlayNotificationSynchronizer(
            isCodexRunning: { [weak self] in
                self?.cachedCodexDesktopRunning ?? true
            },
            readSnapshot: {
                try paths.readSnapshot()
            },
            synchronize: { [weak self] in
                try paths.synchronize {
                    self?.cachedCodexDesktopRunning == false
                }
            },
            schedule: { delay, check in
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + delay,
                    execute: check
                )
            },
            log: { message in
                fputs("\(message)\n", stderr)
            }
        )
    }()
    private lazy var nativeActivityPillSuppressionMonitor: NativeActivityPillSuppressionMonitor = {
        let suppressor = NativeActivityPillSuppressor()
        let queue = DispatchQueue(
            label: "\(threadHelmBundleIdentifier).native-activity",
            qos: .utility
        )
        return NativeActivityPillSuppressionMonitor(
            interval: taskProgressRefreshInterval,
            shouldSuppress: {
                suppressor.isTrusted
            },
            suppress: {
                if case .muted = suppressor.suppressActivityPillsIfNeeded() {
                    fputs("ThreadHelm 已自动静音新出现的 Codex 原生任务气泡。\n", stderr)
                }
            },
            schedule: { delay, check in
                queue.asyncAfter(
                    deadline: .now() + delay,
                    execute: check
                )
            }
        )
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateLegacyThreadHelmPreferencesIfNeeded()
        NSApp.applicationIconImage = makeThreadHelmDockIcon()
        NSApp.setActivationPolicy(.regular)
        let availableProviders = synchronizeQuotaProviderAvailability()
        makeDynamicIslandController()
        startCodexDesktopMonitoring()
        startClaudePermissionHook()
        agentEventChannelAvailable = startAgentEventSocket()
        startAgentHookDropInbox()
        let isAutoIntegrationEnabledInitial = UserDefaults.standard.bool(
            forKey: autoIntegrationDefaultsKey
        )
        let hasConfirmedAutoIntegrationInitial = UserDefaults.standard.bool(
            forKey: autoIntegrationConfirmedDefaultsKey
        )
        dashboardStore.update { snapshot in
            snapshot.agentEventChannelAvailable = agentEventChannelAvailable
            snapshot.isAutoIntegrationEnabled = isAutoIntegrationEnabledInitial
            snapshot.hasConfirmedAutoIntegration =
                hasConfirmedAutoIntegrationInitial
            snapshot.agentStatuses = agentRuntimeStatusPlaceholders(
                registry: agentRegistry
            )
        }
        refreshAgentRuntimeStatuses()
        startScreenParameterMonitoring()
        makeStatusItem()
        makeVisibilityHotKey()
        dynamicIslandConfirmationPresenter.setPresentationActive(true)
        claudePermissionCoordinator.setPresenter(
            dynamicIslandConfirmationPresenter
        )
        showCurrentPresentation()
        updateStatusMenu()
        healthWriter.write(
            status: "started",
            panelVisible: true,
            agentEventChannelAvailable: agentEventChannelAvailable,
            force: true
        )
        availableProviders.forEach { refreshQuota(provider: $0) }
        refreshTaskProgress()
        nativeActivityPillSuppressionMonitor.start()

        windowStackRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: overlayStateRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            self?.reconcileDynamicIslandWindowLevel()
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshQuota()
        }
        taskProgressTimer = Timer.scheduledTimer(
            withTimeInterval: taskProgressRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            self?.refreshTaskProgress()
        }
        agentHealthRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: agentHealthRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            self?.refreshAgentRuntimeStatuses()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if isPanelHiddenByUser {
            showPanelFromStatusItem()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        nativeActivityPillSuppressionMonitor.stop()
        codexOverlayNotificationSynchronizer.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
        dynamicIslandConfirmationPresenter?.setPresentationActive(false)
        claudePermissionCoordinator?.cancelAll()
        claudePermissionHookServer?.stop()
        agentEventSocketServer?.stop()
        agentEventSocketServer = nil
        agentHookDropTimer?.invalidate()
        agentHookDropTimer = nil
        dynamicIslandController?.hide()
        refreshTimer?.invalidate()
        taskProgressTimer?.invalidate()
        windowStackRefreshTimer?.invalidate()
        agentHealthRefreshTimer?.invalidate()
        agentHealthRefreshTimer = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        visibilityHotKey = nil
        healthWriter.write(
            status: "terminated",
            panelVisible: false,
            agentEventChannelAvailable: agentEventChannelAvailable,
            force: true
        )
    }

    private func makeDynamicIslandController() {
        let controller = DynamicIslandWindowController(store: dashboardStore)
        controller.onRequestHide = { [weak self] in
            self?.hidePanelByUser()
        }
        controller.onOpenTask = { [weak self] item in
            self?.openTask(item) ?? .failed
        }
        controller.onCopyWorkingDirectory = { [weak self] path in
            self?.copyWorkingDirectoryToPasteboard(path) ?? false
        }
        controller.onTaskDetailOpened = { [weak self] item in
            self?.acknowledgeTerminalTaskInStore(item)
        }
        bindDynamicIslandDashboardActions(to: controller)
        dynamicIslandController = controller

        let confirmationController = DynamicIslandConfirmationViewController()
        dynamicIslandConfirmationPresenter = controller.makeConfirmationPresenter(
            viewController: confirmationController
        )
        dynamicIslandConfirmationPresenter.onReturnToPriorTab = {
            [weak self, weak controller] tab in
            guard let self,
                  !self.isPanelHiddenByUser
            else { return }
            controller?.expand(tab)
        }
    }

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: threadHelmStatusItemLength)
        configureThreadHelmStatusButton(item.button)
        item.menu = makeStatusMenu()
        item.isVisible = true
        statusItem = item
    }

    private func makeVisibilityHotKey() {
        visibilityHotKey = ThreadHelmVisibilityHotKey { [weak self] in
            self?.handlePresentationCommand(.toggleVisibility)
        }
        if visibilityHotKey == nil {
            fputs(
                "ThreadHelm 无法注册全局快捷键 \(threadHelmVisibilityHotKeyDisplayName)\n",
                stderr
            )
        }
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu(title: "ThreadHelm")
        menu.delegate = self
        menu.addItem(menuItem(command: .toggleVisibility))
        menu.addItem(menuItem(command: .moveToCurrentDisplay))
        menu.addItem(.separator())
        menu.addItem(menuItem(command: .quit))
        return menu
    }

    private func menuItem(command: PresentationCommand) -> NSMenuItem {
        let item = NSMenuItem(
            title: "",
            action: #selector(handlePresentationMenuItem(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = command
        configure(menuItem: item, command: command)
        return item
    }

    private func configure(
        menuItem item: NSMenuItem,
        command: PresentationCommand
    ) {
        item.isEnabled = true
        item.state = .off
        item.keyEquivalent = ""
        item.keyEquivalentModifierMask = []
        switch command {
        case .toggleVisibility:
            item.title = isPanelHiddenByUser ? "显示 ThreadHelm" : "隐藏 ThreadHelm"
            item.keyEquivalent = threadHelmVisibilityHotKeyKeyEquivalent
            item.keyEquivalentModifierMask = threadHelmVisibilityHotKeyModifierMask
        case .moveToCurrentDisplay:
            item.title = "移到当前显示器"
        case .quit:
            item.title = "退出 ThreadHelm"
        }
    }

    @objc private func handlePresentationMenuItem(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? PresentationCommand
        else { return }
        handlePresentationCommand(command)
    }

    private func handlePresentationCommand(_ command: PresentationCommand) {
        switch command {
        case .toggleVisibility:
            if isPanelHiddenByUser {
                showPanelFromStatusItem()
            } else {
                hidePanelByUser()
            }
        case .moveToCurrentDisplay:
            dynamicIslandController?.moveToScreenContainingMouse()
        case .quit:
            NSApp.terminate(nil)
        }
    }

    private func startCodexDesktopMonitoring() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        notificationCenter.addObserver(
            self,
            selector: #selector(codexDesktopApplicationStateDidChange(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(codexDesktopApplicationStateDidChange(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        cachedCodexDesktopRunning = isCodexDesktopRunning()
        dashboardStore.update { $0.codexDesktopRunning = cachedCodexDesktopRunning }
        codexOverlayNotificationSynchronizer.codexRunningStateDidChange(
            cachedCodexDesktopRunning
        )
    }

    @objc private func codexDesktopApplicationStateDidChange(
        _ notification: Notification
    ) {
        guard let application = notification.userInfo?[
            NSWorkspace.applicationUserInfoKey
        ] as? NSRunningApplication else { return }
        let bundleIdentifier = application.bundleIdentifier
        let isCodexApplication =
            isKnownCodexDesktopBundleIdentifier(bundleIdentifier)
            || isCodexDesktopApplication(
                bundleIdentifier: bundleIdentifier,
                localizedName: application.localizedName,
                bundleURL: application.bundleURL,
                activationPolicy: application.activationPolicy
            )
        guard isCodexApplication else { return }

        let isRunning = notification.name
            == NSWorkspace.didLaunchApplicationNotification
            ? true
            : isCodexDesktopRunning()
        updateCodexDesktopRunningState(isRunning)
    }

    private func updateCodexDesktopRunningState(_ isRunning: Bool) {
        guard isRunning != cachedCodexDesktopRunning else { return }
        cachedCodexDesktopRunning = isRunning
        dashboardStore.update { $0.codexDesktopRunning = isRunning }
        codexOverlayNotificationSynchronizer.codexRunningStateDidChange(
            isRunning
        )
        if !isRunning {
            claudePermissionCoordinator?.cancelAll()
        }
        reconcilePresentationAfterCodexLifecycleChange(
            codexDesktopRunning: isRunning
        )
        if !isRunning {
            // DynamicIslandConfirmationPresenter returns to its prior tab on
            // the next main-loop turn after dismissal. Reconcile once more
            // after that callback so a lifecycle cancel ends in the requested
            // capsule/hidden state instead of reopening the prior workspace.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.cachedCodexDesktopRunning else { return }
                self.reconcilePresentationAfterCodexLifecycleChange(
                    codexDesktopRunning: false
                )
            }
        }
    }

    private func reconcilePresentationAfterCodexLifecycleChange(
        codexDesktopRunning: Bool
    ) {
        _ = codexDesktopRunning
        showCurrentPresentation()
    }

    private func startClaudePermissionHook() {
        claudePermissionCoordinator = ClaudePermissionCoordinator(
            openTerminal: { [weak self] prompt in
                guard let self else { return }
                self.lastClaudePermissionOpenResult =
                    self.openTerminalForClaudePermission(prompt)
            },
            onQueueChange: { [weak self] queue in
                guard let self else { return }
                self.dashboardStore.update { snapshot in
                    snapshot.permissionQueue = queue
                    let liveUpdate = self.agentLiveEventStore.snapshotUpdate()
                    guard self.agentLiveReductionGate.shouldApply(
                        revision: liveUpdate.revision
                    ) else { return }
                    let projected = self.makeAgentDashboardProjection(
                        collection: self.lastPolledTaskCollection,
                        permissionQueue: queue,
                        liveReduction: liveUpdate.reduction,
                        agentStatuses: snapshot.agentStatuses
                    )
                    snapshot.taskCollection = projected.taskCollection
                    snapshot.agentSnapshots = projected.snapshots
                    snapshot.attentionItems = projected.attentionItems
                    self.updateAgentRuntimeActivity(in: &snapshot)
                }
            }
        )
        let server = ClaudePermissionHookServer()
        server.onPrompt = { [weak self] prompt, completion in
            guard let self else {
                completion(.nativeFallback)
                return
            }
            let cachedCodexDesktopRunning = self.cachedCodexDesktopRunning
            let liveCodexDesktopRunning = isCodexDesktopRunning()
            let claudeCompatibility = self.dashboardStore.snapshot.agentStatuses
                .first { $0.metadata.id == .claudeCode }?
                .discovery.compatibility ?? .unknown
            let shouldPresent = shouldPresentClaudePermissionPanel(
                cachedCodexDesktopRunning: cachedCodexDesktopRunning,
                liveCodexDesktopRunning: liveCodexDesktopRunning,
                claudeCompatibility: claudeCompatibility
            )
            if liveCodexDesktopRunning != cachedCodexDesktopRunning {
                self.updateCodexDesktopRunningState(liveCodexDesktopRunning)
            }
            guard shouldPresent else {
                completion(.nativeFallback)
                return
            }
            self.claudePermissionCoordinator.enqueue(
                prompt: prompt,
                completion: completion
            )
        }
        server.onRequestExpired = { [weak self] requestID in
            self?.claudePermissionCoordinator.expire(requestID: requestID)
        }
        server.onStateChange = { state in
            switch state {
            case .ready:
                fputs("ThreadHelm Claude Hook 已监听 \(ClaudeHookConstants.url)\n", stderr)
            case .failed(let reason):
                fputs("ThreadHelm Claude Hook 启动失败：\(reason)\n", stderr)
            case .starting, .stopped:
                break
            }
        }
        do {
            try server.start()
            claudePermissionHookServer = server
        } catch {
            fputs("ThreadHelm Claude Hook 启动失败：\(error.localizedDescription)\n", stderr)
        }
    }

    private func startScreenParameterMonitoring() {
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.dynamicIslandController?.screenParametersDidChange()
            self.reconcileDynamicIslandWindowLevel()
        }
    }

    @discardableResult
    private func openTerminalForClaudePermission(
        _ prompt: ClaudePermissionPrompt
    ) -> OpenResult {
        let request = claudeTerminalOpenRequest(
            for: prompt,
            taskItems: dashboardStore.snapshot.taskCollection.items
        )
        let result = openClaudeTerminal(request: request)
        switch result {
        case .exactSession, .appFocused, .workingDirectoryFallback, .unknown:
            return result
        case .unavailable, .failed, .notAttempted:
            break
        }
        // A generic activation can expose an unrelated tab. It is only safe
        // when the prompt contains no process, session, or directory target.
        guard allowsGenericTerminalFallback(for: request) else { return result }
        let supportedBundleIdentifiers = [
            "io.appmakes.otty",
            "com.googlecode.iterm2",
            "com.apple.Terminal",
        ]
        let runningBundleIdentifiers = Set(
            supportedBundleIdentifiers.filter {
                NSRunningApplication.runningApplications(
                    withBundleIdentifier: $0
                ).isEmpty == false
            }
        )
        let hasActiveOttyTab: Bool
        if runningBundleIdentifiers.contains("io.appmakes.otty"),
           let data = runOttyCLI(arguments: ["--json", "tab", "list"])
        {
            hasActiveOttyTab = ottyHasActiveTab(from: data)
        } else {
            hasActiveOttyTab = false
        }
        if let bundleIdentifier = preferredClaudeTerminalBundleIdentifier(
            frontmostBundleIdentifier: NSWorkspace.shared
                .frontmostApplication?
                .bundleIdentifier,
            runningBundleIdentifiers: runningBundleIdentifiers,
            ottyHasActiveTab: hasActiveOttyTab
        ), activateRunningApplication(bundleIdentifier: bundleIdentifier) {
            return .appFocused
        }
        let terminalURL = URL(
            fileURLWithPath: "/System/Applications/Utilities/Terminal.app",
            isDirectory: true
        )
        NSWorkspace.shared.openApplication(
            at: terminalURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
        return .unknown
    }

    private func updateStatusMenu() {
        statusItem?.length = threadHelmStatusItemLength
        configureThreadHelmStatusButton(statusItem?.button)
        statusItem?.isVisible = true
        statusItem?.menu.map(menuNeedsUpdate)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            guard let command = item.representedObject as? PresentationCommand
            else { continue }
            configure(menuItem: item, command: command)
        }
    }

    private func hidePanelByUser() {
        isPanelHiddenByUser = true
        dynamicIslandController?.hide()
        updateRecoveryActivationPolicy()
        updateStatusMenu()
        healthWriter.write(
            status: "hidden-by-user",
            panelVisible: false,
            agentEventChannelAvailable: agentEventChannelAvailable,
            force: true
        )
    }

    @objc private func showPanelFromStatusItem() {
        isPanelHiddenByUser = false
        updateRecoveryActivationPolicy()
        updateStatusMenu()
        showCurrentPresentation()
    }

    private func updateRecoveryActivationPolicy() {
        NSApp.setActivationPolicy(.regular)
        NSApp.dockTile.badgeLabel = nil
        NSApp.dockTile.display()
    }

    private func showCurrentPresentation() {
        switch dynamicIslandVisibilityAction(
            hiddenByUser: isPanelHiddenByUser,
            hasCurrentPermissionRequest:
                dashboardStore.snapshot.permissionQueue.current != nil
        ) {
        case .hidden:
            dynamicIslandController?.hide()
        case .capsule:
            dynamicIslandController?.showCapsule()
        case .confirmation:
            dynamicIslandController?.expand(.confirmation)
        }
    }

    private func reconcileDynamicIslandWindowLevel() {
        dynamicIslandController?.reconcileWindowLevel(
            entries: currentWindowStackEntries()
        )
    }

    @discardableResult
    private func synchronizeQuotaProviderAvailability() -> [QuotaProvider] {
        let availableProviders = quotaProviders(
            claudeCodeAvailable: locateClaudeExecutable() != nil
        )
        let preferredProvider = quotaProviderPreference.selectedProvider
        let resolvedProvider = resolvedQuotaProvider(
            preferred: preferredProvider,
            availableProviders: availableProviders
        )
        if preferredProvider != resolvedProvider {
            quotaProviderPreference.selectedProvider = resolvedProvider
        }
        dashboardStore.update {
            $0.availableProviders = availableProviders
            $0.selectedQuotaProvider = resolvedProvider
        }
        return availableProviders
    }

    private func refreshQuota(provider requestedProvider: QuotaProvider? = nil) {
        let availableProviders = synchronizeQuotaProviderAvailability()
        let provider = requestedProvider
            ?? dashboardStore.snapshot.selectedQuotaProvider
        guard availableProviders.contains(provider),
              refreshingQuotaProviders.insert(provider).inserted
        else { return }

        dashboardStore.update {
            let previous = $0.quotaStates[provider] ?? QuotaProviderState()
            $0.quotaStates[provider] = quotaProviderStateRefreshing(previous)
        }

        switch provider {
        case .codex:
            quotaClient.fetch { [weak self] result in
                let payloadResult = result.map { response in
                    QuotaRefreshPayload(
                        rows: Self.makeRows(from: response),
                        resetCredits: makeCodexResetCreditsSnapshot(
                            from: response,
                            now: Date()
                        )
                    )
                }
                DispatchQueue.main.async {
                    self?.completeQuotaRefresh(
                        provider: provider,
                        result: payloadResult
                    )
                }
            }
        case .claudeCode:
            claudeQuotaClient.fetch { [weak self] result in
                let payloadResult = result.map {
                    QuotaRefreshPayload(rows: $0.rows, resetCredits: nil)
                }
                DispatchQueue.main.async {
                    self?.completeQuotaRefresh(
                        provider: provider,
                        result: payloadResult
                    )
                }
            }
        }
    }

    private func completeQuotaRefresh(
        provider: QuotaProvider,
        result: Result<QuotaRefreshPayload, Error>
    ) {
        refreshingQuotaProviders.remove(provider)
        let previous = dashboardStore.snapshot.quotaStates[provider]
            ?? QuotaProviderState()
        let next: QuotaProviderState
        switch result {
        case .success(let payload):
            next = quotaProviderStateAfterSuccess(
                previous,
                rows: payload.rows,
                resetCredits: payload.resetCredits,
                provider: provider,
                updatedAt: Date()
            )
        case .failure(let error):
            next = quotaProviderStateAfterFailure(
                previous,
                error: error,
                provider: provider
            )
        }
        dashboardStore.update {
            $0.quotaStates[provider] = next
        }
    }

    private func selectQuotaProvider(_ provider: QuotaProvider) {
        guard dashboardStore.snapshot.availableProviders.contains(provider)
        else { return }
        quotaProviderPreference.selectedProvider = provider
        dashboardStore.update { $0.selectedQuotaProvider = provider }
        refreshQuota(provider: provider)
    }

    private func openTask(_ item: TaskProgressItem) -> OpenResult {
        guard let adapter = agentRegistry.adapter(for: item.source),
              let snapshot = agentSessionSnapshot(
                  from: item,
                  metadata: adapter.metadata,
                  permissionQueue: dashboardStore.snapshot.permissionQueue
              )
        else { return .unavailable }
        let report = adapter.openSessionForValidatedVersion(session: snapshot) {
            if item.source == .claudeCode {
                lastClaudePermissionOpenResult = nil
                if claudePermissionCoordinator?
                    .handoffToTerminalIfPresenting(item) == true
                {
                    let result = lastClaudePermissionOpenResult ?? .unknown
                    let request = claudeTerminalOpenRequest(for: item)
                    let hasVerifiedProcessTarget = request.processID != nil
                        && request.processStartIdentity != nil
                    let hasResumeTarget = request.sessionID != nil
                        && request.workingDirectory != nil
                    return AgentOpenReport(
                        agentID: .claudeCode,
                        advertisedActionability: snapshot.actionability,
                        result: result,
                        invokedExactTarget: hasVerifiedProcessTarget
                            || hasResumeTarget,
                        independentlyConfirmedIdentity: result == .exactSession
                            && hasVerifiedProcessTarget
                    )
                }
            }
            return adapter.openValidated(session: snapshot)
        }
        return recordOpenReport(report)
    }

    private func recordOpenReport(_ report: AgentOpenReport) -> OpenResult {
        if !agentOpenMeasurementStore.record(report) {
            fputs("ThreadHelm 无法写入本地打开结果计数。\n", stderr)
        }
        return report.result
    }

    private func copyWorkingDirectoryToPasteboard(_ path: String) -> Bool {
        guard let normalizedPath = normalizedAbsolutePath(path) else {
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([normalizedPath as NSString])
    }

    private func acknowledgeTerminalTaskInStore(_ item: TaskProgressItem) {
        dashboardStore.update {
            acknowledgeTerminalTask(item, in: &$0.acknowledgedTerminalTaskKeys)
        }
    }

    func bindDynamicIslandDashboardActions(
        to controller: DynamicIslandWindowController
    ) {
        DynamicIslandDashboardActionBinding(
            refreshDashboard: { [weak self] in
                self?.refreshDashboard()
            },
            selectQuotaProvider: { [weak self] provider in
                self?.selectQuotaProvider(provider)
            },
            performIntegration: { [weak self] agentID, operation in
                self?.performAgentIntegration(for: agentID, operation: operation)
            },
            toggleAutoIntegration: { [weak self] enabled in
                self?.toggleAutoIntegration(enabled)
            }
        ).bind(to: controller)
    }

    /// UI 只在用户完成二次确认后才会用 `enabled == true` 调到这里，
    /// 但门禁不依赖 UI：确认标记同样落在 defaults 上，并由
    /// `evaluateAutoIntegration` 独立复核。
    private func toggleAutoIntegration(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: autoIntegrationDefaultsKey)
        if enabled {
            UserDefaults.standard.set(
                true,
                forKey: autoIntegrationConfirmedDefaultsKey
            )
        }
        dashboardStore.update {
            $0.isAutoIntegrationEnabled = enabled
            $0.hasConfirmedAutoIntegration = UserDefaults.standard.bool(
                forKey: self.autoIntegrationConfirmedDefaultsKey
            )
        }
        if enabled {
            evaluateAutoIntegration(on: dashboardStore.snapshot.agentStatuses)
        }
    }

    private func performAgentIntegration(
        for agentID: AgentID,
        operation: AgentIntegrationOperation,
        version: String? = nil,
        completion: (() -> Void)? = nil
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !self.isPerformingIntegration else { return }
            self.isPerformingIntegration = true
            self.dynamicIslandController?.setAgentIntegrationTransientState(
                .configuring,
                for: agentID
            )

            self.integrationSerialQueue.async { [weak self] in
                guard let self else { return }
                let scope = AgentIntegrationScope(
                    rootDirectory: FileManager.default.homeDirectoryForCurrentUser,
                    permitsLiveConfigurationChanges: true
                )
                let manager = AgentIntegrationManager(registry: self.agentRegistry)
                do {
                    let report = try manager.perform(
                        operation,
                        targetAgentID: agentID,
                        in: scope
                    )
                    let record = report.agents.first { $0.agentID == agentID }
                    let result = record?.result

                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.isPerformingIntegration = false
                        let activeVersion = version
                            ?? self.dashboardStore.snapshot.agentStatuses
                                .first(where: { $0.metadata.id == agentID })
                                .map(agentAutoIntegrationBackoffVersion(for:))
                            ?? "default"
                        let outcome = agentIntegrationAccountingOutcome(
                            result: result,
                            statusAfter: record?.statusAfter,
                            threw: false
                        )
                        self.recordAutoIntegrationOutcome(
                            outcome,
                            agentID: agentID,
                            version: activeVersion
                        )
                        if result == .unchanged {
                            // 版本门禁未通过时 perform 静默返回 .unchanged，
                            // 绝不能当成功处理。但 .unchanged 还有第二个来源：
                            // 状态已过期、配置其实已就位时的幂等 no-op —— 两者
                            // 要给出不同的提示，否则会误导用户去查版本。
                            let message = outcome == .succeeded
                                ? "已是最新，无需操作"
                                : "版本未验证，已跳过"
                            self.dynamicIslandController?
                                .setAgentIntegrationTransientState(
                                    .noop(message),
                                    for: agentID
                                )
                            completion?()
                            return
                        }
                        // 记账已在上方按 agentIntegrationAccountingOutcome 完成：
                        // 报告 .installed 但重新探测未收敛的情况会被记为失败，
                        // 否则退避被销账、成功又立刻触发下一轮评估，形成写盘循环。
                        //
                        // .installed / .repaired 以及任何非预期结果都重新探测真实状态，
                        // 并在刷新落地后显式解除 .configuring —— 不依赖快照比较，
                        // 因为 dashboardStore.update 在快照相等时会静默跳过通知。
                        // 这次刷新由集成操作自身触发，绝不能再回头驱动自动集成，
                        // 否则 evaluate → perform → refresh → evaluate 会自我循环。
                        self.refreshAgentRuntimeStatuses(
                            suppressAutoIntegration: true
                        ) { [weak self] in
                            self?.dynamicIslandController?
                                .setAgentIntegrationTransientState(
                                    .idle,
                                    for: agentID
                                )
                            completion?()
                        }
                    }
                } catch {
                    let message: String
                    if let managerError = error as? AgentIntegrationManagerError {
                        let rollbackNote = managerError.didRollback
                            ? "原配置已恢复"
                            : "自动恢复未完成"
                        message = "配置失败：\(managerError.reason)；\(rollbackNote)"
                    } else {
                        message = "配置失败：\(error.localizedDescription)"
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.isPerformingIntegration = false
                        let activeVersion = version
                            ?? self.dashboardStore.snapshot.agentStatuses
                                .first(where: { $0.metadata.id == agentID })
                                .map(agentAutoIntegrationBackoffVersion(for:))
                            ?? "default"
                        self.recordAutoIntegrationOutcome(
                            agentIntegrationAccountingOutcome(
                                result: nil,
                                statusAfter: nil,
                                threw: true
                            ),
                            agentID: agentID,
                            version: activeVersion
                        )
                        self.dynamicIslandController?.setAgentIntegrationTransientState(
                            .failed(message),
                            for: agentID
                        )
                        completion?()
                    }
                }
            }
        }
    }

    private func recordAutoIntegrationOutcome(
        _ outcome: AgentIntegrationAccountingOutcome,
        agentID: AgentID,
        version: String
    ) {
        switch outcome {
        case .succeeded:
            autoIntegrationBackoffGate.recordSuccess(
                agentID: agentID,
                version: version
            )
        case .skippedUnvalidated, .failed:
            autoIntegrationBackoffGate.recordFailure(
                agentID: agentID,
                version: version
            )
        }
    }

    private func evaluateAutoIntegration(on statuses: [AgentRuntimeStatus]) {
        // 双门禁：显式开关 + 一次性确认。缺任何一个都不得写厂商配置。
        // 这里独立复核 defaults，不依赖 UI 状态。
        guard let candidate = agentAutoIntegrationCandidate(
            statuses: statuses,
            isEnabled: UserDefaults.standard.bool(
                forKey: autoIntegrationDefaultsKey
            ),
            hasConfirmed: UserDefaults.standard.bool(
                forKey: autoIntegrationConfirmedDefaultsKey
            ),
            canAttempt: { [autoIntegrationBackoffGate] agentID, version in
                autoIntegrationBackoffGate.canAttempt(
                    agentID: agentID,
                    version: version
                )
            }
        ) else {
            return
        }
        // 发起即记时间戳：最小间隔必须覆盖"成功但不收敛"的路径，
        // 不能只依赖失败记账。
        autoIntegrationBackoffGate.recordAttempt(
            agentID: candidate.agentID,
            version: candidate.version
        )
        performAgentIntegration(
            for: candidate.agentID,
            operation: .install,
            version: candidate.version
        )
    }

    private func refreshDashboard() {
        refreshAgentRuntimeStatuses()
        makeDynamicIslandDashboardRefreshDispatcher().refreshDashboard()
    }

    private func makeDynamicIslandDashboardRefreshDispatcher()
        -> DynamicIslandDashboardRefreshDispatcher
    {
        DynamicIslandDashboardRefreshDispatcher(
            availableProviders: { [weak self] in
                self?.dashboardStore.snapshot.availableProviders ?? []
            },
            refreshTasks: { [weak self] in
                self?.refreshTaskProgress()
            },
            refreshQuotaProvider: { [weak self] provider in
                self?.refreshQuota(provider: provider)
            }
        )
    }

    /// 只在主线程调用。三个触发源（启动与手动刷新、5 分钟定时器、集成操作完成）
    /// 共用一次探测：并发刷新会重复 fork 版本探测子进程，且两次
    /// `dashboardStore.update` 是 last-writer-wins，慢的旧结果可能覆盖新结果。
    ///
    /// - Parameter suppressAutoIntegration: 由集成操作自身触发的刷新必须置为
    ///   true，否则 evaluate → perform → refresh → evaluate 会自我循环。
    /// - Parameter completion: 在主线程、`dashboardStore` 更新之后回调。
    ///   注意 `dashboardStore.update` 在快照未变化时会静默跳过观察者通知，
    ///   因此需要感知"刷新已完成"的调用方必须用这个回调，而不是等待快照下发。
    private func refreshAgentRuntimeStatuses(
        suppressAutoIntegration: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        guard let generation = agentRuntimeRefreshGate.begin() else {
            // 已有刷新在飞：合并本次请求，等那一次落地后一起回调，
            // 不再另起一轮探测。
            if let completion {
                pendingAgentRuntimeRefreshCompletions.append(completion)
            }
            return
        }
        let registry = agentRegistry
        let previousStatuses = dashboardStore.snapshot.agentStatuses
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let probed = probedAgentRuntimeStatuses(
                registry: registry,
                preserving: previousStatuses
            )
            let integrationReport = AgentIntegrationManager(registry: registry)
                .status(
                    in: AgentIntegrationScope(
                        rootDirectory: FileManager.default.homeDirectoryForCurrentUser,
                        permitsLiveConfigurationChanges: false
                    )
                )
            let withIntegration = agentRuntimeStatusesMergingIntegration(
                probed,
                report: integrationReport
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    completion?()
                    return
                }
                guard self.agentRuntimeRefreshGate.complete(
                    generation: generation
                ) else {
                    // 代次不匹配说明这一轮已被取代，丢弃陈旧结果，
                    // 不写快照也不驱动自动集成。
                    completion?()
                    return
                }
                self.dashboardStore.update { snapshot in
                    snapshot.agentStatuses = agentRuntimeStatusesWithActivity(
                        withIntegration,
                        snapshots: snapshot.agentSnapshots,
                        attentionItems: snapshot.attentionItems
                    )
                    snapshot.agentEventChannelAvailable =
                        self.agentEventChannelAvailable
                }
                if !suppressAutoIntegration {
                    self.evaluateAutoIntegration(on: withIntegration)
                }
                let pending = self.pendingAgentRuntimeRefreshCompletions
                self.pendingAgentRuntimeRefreshCompletions = []
                completion?()
                for pendingCompletion in pending {
                    pendingCompletion()
                }
            }
        }
    }

    private func updateAgentRuntimeActivity(
        in snapshot: inout ActivityDashboardSnapshot
    ) {
        let statuses = snapshot.agentStatuses.isEmpty
            ? agentRuntimeStatusPlaceholders(registry: agentRegistry)
            : snapshot.agentStatuses
        snapshot.agentStatuses = agentRuntimeStatusesWithActivity(
            statuses,
            snapshots: snapshot.agentSnapshots,
            attentionItems: snapshot.attentionItems
        )
        snapshot.agentEventChannelAvailable = agentEventChannelAvailable
    }

    private func makeAgentDashboardProjection(
        collection: TaskProgressCollectionSnapshot,
        permissionQueue: ClaudePermissionQueueSnapshot,
        liveReduction: AgentReductionResult,
        agentStatuses: [AgentRuntimeStatus]
    ) -> AgentDashboardProjection {
        let compatibilities = Dictionary(
            agentStatuses.map {
                ($0.metadata.id, $0.discovery.compatibility)
            },
            uniquingKeysWith: { _, latest in latest }
        )
        let projected = agentDashboardProjection(
            collection: collection,
            permissionQueue: permissionQueue,
            liveReduction: liveReduction,
            agentCompatibilities: compatibilities,
            registry: agentRegistry
        )
        return AgentDashboardProjection(
            taskCollection: projected.taskCollection,
            snapshots: projected.snapshots,
            attentionItems: agentAttentionInterruptionGate.evaluate(
                items: projected.attentionItems,
                foregroundSessionKeys: foregroundHandledAgentSessionKeys(
                    presentationState: dynamicIslandController?.state,
                    selectedTaskKey: dynamicIslandController?.selectedTaskKey,
                    permissionQueue: permissionQueue
                )
            )
        )
    }

    private func refreshTaskProgress() {
        guard let generation = taskProgressRefreshGate.begin() else { return }
        dashboardStore.update { $0.isTaskRefreshing = true }
        let readerStore = taskProgressReaderStore
        let reader = readerStore.leaseReader(for: generation)
        DispatchQueue.global(qos: .utility).async { [weak self, readerStore] in
            let collection = reader.readCollection()
            DispatchQueue.main.async {
                guard let self else {
                    readerStore.releaseReader(for: generation, reuse: false)
                    return
                }
                let shouldApply = self.taskProgressRefreshGate.complete(
                    generation: generation
                )
                readerStore.releaseReader(for: generation, reuse: shouldApply)
                guard shouldApply else { return }
                self.lastPolledTaskCollection = collection
                self.ingestAgentHookDropInbox()
                self.dashboardStore.update { snapshot in
                    let liveUpdate = self.agentLiveEventStore.snapshotUpdate()
                    guard self.agentLiveReductionGate.shouldApply(
                        revision: liveUpdate.revision
                    ) else {
                        snapshot.isTaskRefreshing = false
                        return
                    }
                    let projected = self.makeAgentDashboardProjection(
                        collection: collection,
                        permissionQueue: snapshot.permissionQueue,
                        liveReduction: liveUpdate.reduction,
                        agentStatuses: snapshot.agentStatuses
                    )
                    snapshot.taskCollection = projected.taskCollection
                    snapshot.agentSnapshots = projected.snapshots
                    snapshot.attentionItems = projected.attentionItems
                    self.updateAgentRuntimeActivity(in: &snapshot)
                    snapshot.isTaskRefreshing = false
                }
                // 终端里直接回答后 Claude 不会关闭 hook 连接，靠这次刷新的会话
                // 状态收起已经不需要的问答弹窗。
                self.claudePermissionCoordinator?
                    .dismissIfAnsweredInTerminal(in: collection.items)
            }
        }
    }

    private func startAgentEventSocket() -> Bool {
        let server = AgentEventSocketServer(
            configuration: AgentEventSocketConfiguration(
                socketURL: agentEventSocketURL()
            )
        ) { [weak self] envelope in
            guard let self,
                  let update = self.agentLiveEventStore.ingestUpdate(envelope)
            else { return }
            DispatchQueue.main.async { [weak self] in
                self?.applyLiveAgentReduction(update)
            }
        }
        do {
            try server.start()
            agentEventSocketServer = server
            return true
        } catch {
            // This channel is observational only; the native agents must keep
            // working when ThreadHelm cannot accept events.
            fputs("ThreadHelm 本地 Agent 状态通道暂不可用。\n", stderr)
            return false
        }
    }

    private func startAgentHookDropInbox() {
        let directory = agentHookDropDirectoryURL()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(directory.path, S_IRWXU)
        ingestAgentHookDropInbox()
        agentHookDropTimer = Timer.scheduledTimer(
            withTimeInterval: 0.5,
            repeats: true
        ) { [weak self] _ in
            self?.ingestAgentHookDropInbox()
        }
    }

    private func ingestAgentHookDropInbox() {
        let envelopes = drainAgentHookDropInbox()
        guard !envelopes.isEmpty else { return }
        var latest: AgentLiveReductionUpdate?
        for envelope in envelopes {
            if let update = agentLiveEventStore.ingestUpdate(envelope) {
                latest = update
            }
        }
        guard let latest else { return }
        applyLiveAgentReduction(latest)
    }

    private func applyLiveAgentReduction(_ update: AgentLiveReductionUpdate) {
        guard agentLiveReductionGate.shouldApply(revision: update.revision) else {
            return
        }
        dashboardStore.update { snapshot in
            let projected = makeAgentDashboardProjection(
                collection: lastPolledTaskCollection,
                permissionQueue: snapshot.permissionQueue,
                liveReduction: update.reduction,
                agentStatuses: snapshot.agentStatuses
            )
            snapshot.taskCollection = projected.taskCollection
            snapshot.agentSnapshots = projected.snapshots
            snapshot.attentionItems = projected.attentionItems
            updateAgentRuntimeActivity(in: &snapshot)
        }
    }

    private static func makeRows(from response: RateLimitsResult) -> [QuotaRow] {
        let snapshot = codexSnapshot(from: response)

        if let window = weeklyRateLimitWindow(from: snapshot) {
            return [QuotaRow(
                name: "周额度",
                remainingPercent: max(0, 100 - window.usedPercent),
                resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )]
        }

        return []
    }

}

private struct QuotaRefreshPayload {
    let rows: [QuotaRow]
    let resetCredits: CodexResetCreditsSnapshot?
}

struct DynamicIslandDashboardActionBinding {
    let refreshDashboard: () -> Void
    let selectQuotaProvider: (QuotaProvider) -> Void
    let performIntegration: (AgentID, AgentIntegrationOperation) -> Void
    let toggleAutoIntegration: (Bool) -> Void

    init(
        refreshDashboard: @escaping () -> Void,
        selectQuotaProvider: @escaping (QuotaProvider) -> Void,
        performIntegration: @escaping (AgentID, AgentIntegrationOperation) -> Void = { _, _ in },
        toggleAutoIntegration: @escaping (Bool) -> Void = { _ in }
    ) {
        self.refreshDashboard = refreshDashboard
        self.selectQuotaProvider = selectQuotaProvider
        self.performIntegration = performIntegration
        self.toggleAutoIntegration = toggleAutoIntegration
    }

    func bind(to controller: DynamicIslandWindowController) {
        controller.onRefresh = refreshDashboard
        controller.onQuotaProviderChange = selectQuotaProvider
        controller.onPerformIntegration = performIntegration
        controller.onToggleAutoIntegration = toggleAutoIntegration
    }
}

struct DynamicIslandDashboardRefreshDispatcher {
    let availableProviders: () -> [QuotaProvider]
    let refreshTasks: () -> Void
    let refreshQuotaProvider: (QuotaProvider) -> Void

    func refreshDashboard() {
        let providers = availableProviders()
        refreshTasks()
        for provider in providers {
            refreshQuotaProvider(provider)
        }
    }
}

func dynamicIslandDashboardRefreshQuotaProviders(
    snapshot: ActivityDashboardSnapshot
) -> [QuotaProvider] {
    snapshot.availableProviders
}

func quotaProviderRemainingPercents(
    from states: [QuotaProvider: QuotaProviderState]
) -> [QuotaProvider: Int] {
    var result: [QuotaProvider: Int] = [:]
    for provider in QuotaProvider.allCases {
        guard let remaining = states[provider]?.rows.first(where: {
            $0.name == provider.summaryRowName
        })?.remainingPercent else { continue }
        result[provider] = remaining
    }
    return result
}

final class TaskProgressRefreshReaderStore {
    private let lock = NSLock()
    private var idleReaders: [CombinedTaskProgressReader] = [
        CombinedTaskProgressReader()
    ]
    private var activeReadersByGeneration: [Int: CombinedTaskProgressReader] = [:]

    func leaseReader(for generation: Int) -> CombinedTaskProgressReader {
        lock.lock()
        defer { lock.unlock() }
        if let reader = activeReadersByGeneration[generation] {
            return reader
        }
        let reader = idleReaders.popLast() ?? CombinedTaskProgressReader()
        activeReadersByGeneration[generation] = reader
        return reader
    }

    func releaseReader(for generation: Int, reuse: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let reader = activeReadersByGeneration.removeValue(
            forKey: generation
        ) else { return }
        if reuse {
            idleReaders.append(reader)
        }
    }

}

struct TaskProgressRefreshGate {
    private var activeGeneration: Int?
    private var nextGeneration = 0

    mutating func begin() -> Int? {
        guard activeGeneration == nil else { return nil }
        nextGeneration += 1
        activeGeneration = nextGeneration
        return nextGeneration
    }

    mutating func complete(generation: Int) -> Bool {
        guard activeGeneration == generation else { return false }
        activeGeneration = nil
        return true
    }
}

func runTaskProgressRefreshStabilityRegressionSelfTest() -> Bool {
    let readerStore = TaskProgressRefreshReaderStore()
    let completedReader = readerStore.leaseReader(for: 1)
    readerStore.releaseReader(for: 1, reuse: true)
    let reusedReader = readerStore.leaseReader(for: 2)
    guard ObjectIdentifier(completedReader) == ObjectIdentifier(reusedReader) else {
        return false
    }
    readerStore.releaseReader(for: 2, reuse: true)
    guard ObjectIdentifier(readerStore.leaseReader(for: 3))
            == ObjectIdentifier(reusedReader)
    else {
        return false
    }

    var gate = TaskProgressRefreshGate()
    guard let firstGeneration = gate.begin(),
          gate.begin() == nil,
          gate.complete(generation: firstGeneration),
          let secondGeneration = gate.begin(),
          firstGeneration != secondGeneration,
          !gate.complete(generation: firstGeneration),
          gate.complete(generation: secondGeneration)
    else {
        return false
    }
    return true
}
