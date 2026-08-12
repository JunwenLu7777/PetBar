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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let quotaClient = CodexQuotaClient()
    private let claudeQuotaClient = ClaudeQuotaClient()
    private let quotaProviderPreference = QuotaProviderPreference()
    private let healthWriter = RuntimeHealthWriter()
    private let dashboardStore = ActivityDashboardStore()
    private let agentRegistry = AgentRegistry.builtIn
    private let agentLiveEventStore = AgentLiveEventStore()
    private var agentLiveReductionGate = AgentLiveReductionGate()
    private var agentEventChannelAvailable = false
    private var lastPolledTaskCollection = TaskProgressCollectionSnapshot
        .displaying([])
    private var claudePermissionCoordinator: ClaudePermissionCoordinator!
    private var dynamicIslandController: DynamicIslandWindowController!
    private var dynamicIslandConfirmationPresenter:
        DynamicIslandConfirmationPresenter!
    private var claudePermissionHookServer: ClaudePermissionHookServer?
    private var agentEventSocketServer: AgentEventSocketServer?
    private var screenParametersObserver: NSObjectProtocol?
    private var statusItem: NSStatusItem?
    private var visibilityHotKey: ThreadHelmVisibilityHotKey?
    private var refreshTimer: Timer?
    private var taskProgressTimer: Timer?
    private var windowStackRefreshTimer: Timer?
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
            panelVisible: false,
            locationSource: nil,
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
        dynamicIslandController?.hide()
        refreshTimer?.invalidate()
        taskProgressTimer?.invalidate()
        windowStackRefreshTimer?.invalidate()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        visibilityHotKey = nil
        healthWriter.write(
            status: "terminated",
            panelVisible: false,
            locationSource: nil,
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
        case .togglePet:
            item.title = ""
            item.isEnabled = false
        case .selectMode:
            item.title = ""
            item.isEnabled = false
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
        case .togglePet, .selectMode:
            return
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
                self?.openTerminalForClaudePermission(prompt)
            },
            onQueueChange: { [weak self] queue in
                guard let self else { return }
                self.dashboardStore.update { snapshot in
                    snapshot.permissionQueue = queue
                    let liveUpdate = self.agentLiveEventStore.snapshotUpdate()
                    guard self.agentLiveReductionGate.shouldApply(
                        revision: liveUpdate.revision
                    ) else { return }
                    let projected = agentDashboardProjection(
                        collection: self.lastPolledTaskCollection,
                        permissionQueue: queue,
                        liveReduction: liveUpdate.reduction,
                        registry: self.agentRegistry
                    )
                    snapshot.taskCollection = projected.taskCollection
                    snapshot.agentSnapshots = projected.snapshots
                    snapshot.attentionItems = projected.attentionItems
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
            let shouldPresent = shouldPresentClaudePermissionPanel(
                cachedCodexDesktopRunning: cachedCodexDesktopRunning,
                liveCodexDesktopRunning: liveCodexDesktopRunning
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

    private func openTerminalForClaudePermission(_ prompt: ClaudePermissionPrompt) {
        let request = claudeTerminalOpenRequest(
            for: prompt,
            taskItems: dashboardStore.snapshot.taskCollection.items
        )
        let result = openClaudeTerminal(request: request)
        if result == .exactSession
            || result == .workingDirectoryFallback
            || result == .appFocused
        {
            return
        }
        // A generic activation can expose an unrelated tab. It is only safe
        // when the prompt contains no process, session, or directory target.
        guard allowsGenericTerminalFallback(for: request) else { return }
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
            return
        }
        let terminalURL = URL(
            fileURLWithPath: "/System/Applications/Utilities/Terminal.app",
            isDirectory: true
        )
        NSWorkspace.shared.openApplication(
            at: terminalURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
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
            locationSource: nil,
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
        let decision = presentationRuntimeDecision(
            mode: .dynamicIsland,
            hiddenByUser: isPanelHiddenByUser,
            petEnabled: false
        )
        switch dynamicIslandVisibilityAction(
            decision: decision,
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
        if item.source == .claudeCode {
            if claudePermissionCoordinator?
                .handoffToTerminalIfPresenting(item) == true
            {
                return .unknown
            }
        }
        guard let adapter = agentRegistry.adapter(for: item.source),
              let snapshot = agentSessionSnapshot(
                  from: item,
                  metadata: adapter.metadata,
                  permissionQueue: dashboardStore.snapshot.permissionQueue
              )
        else { return .unavailable }
        return adapter.open(session: snapshot)
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
            }
        ).bind(to: controller)
    }

    private func refreshDashboard() {
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
                self.dashboardStore.update {
                    let liveUpdate = self.agentLiveEventStore.snapshotUpdate()
                    guard self.agentLiveReductionGate.shouldApply(
                        revision: liveUpdate.revision
                    ) else {
                        $0.isTaskRefreshing = false
                        return
                    }
                    let projected = agentDashboardProjection(
                        collection: collection,
                        permissionQueue: $0.permissionQueue,
                        liveReduction: liveUpdate.reduction,
                        registry: self.agentRegistry
                    )
                    $0.taskCollection = projected.taskCollection
                    $0.agentSnapshots = projected.snapshots
                    $0.attentionItems = projected.attentionItems
                    $0.isTaskRefreshing = false
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

    private func applyLiveAgentReduction(_ update: AgentLiveReductionUpdate) {
        guard agentLiveReductionGate.shouldApply(revision: update.revision) else {
            return
        }
        dashboardStore.update { snapshot in
            let projected = agentDashboardProjection(
                collection: lastPolledTaskCollection,
                permissionQueue: snapshot.permissionQueue,
                liveReduction: update.reduction,
                registry: agentRegistry
            )
            snapshot.taskCollection = projected.taskCollection
            snapshot.agentSnapshots = projected.snapshots
            snapshot.attentionItems = projected.attentionItems
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

    func bind(to controller: DynamicIslandWindowController) {
        controller.onRefresh = refreshDashboard
        controller.onQuotaProviderChange = selectQuotaProvider
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
