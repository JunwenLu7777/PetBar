//
//  AppDelegate.swift
//  ChatBirdQuotaPanel
//
//  模块职责：应用委托——面板/状态栏项生命周期、宠物跟随与窗口层级
//  调整、额度刷新编排（Codex/Claude/重置额度）、任务进度定时刷新、
//  Claude 权限 Hook 启动与终端打开回退。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

let chatBirdStatusItemLength = NSStatusItem.squareLength

func makeChatBirdStatusItemImage() -> NSImage? {
    let configuration = NSImage.SymbolConfiguration(
        pointSize: 15,
        weight: .semibold
    )
    let image = (
        NSImage(
            systemSymbolName: "bird.fill",
            accessibilityDescription: "ChatBird"
        )
        ?? NSImage(
            systemSymbolName: "message.fill",
            accessibilityDescription: "ChatBird"
        )
    )?.withSymbolConfiguration(configuration)
    image?.isTemplate = true
    return image
}

private func configureChatBirdStatusButton(_ button: NSStatusBarButton?) {
    guard let button else { return }
    if let image = makeChatBirdStatusItemImage() {
        button.title = "ChatBird"
        button.image = image
        button.imagePosition = .imageOnly
    } else {
        button.image = nil
        button.title = "CB"
        button.imagePosition = .noImage
    }
    button.toolTip = "ChatBird · \(chatBirdVisibilityHotKeyDisplayName) 显示/隐藏"
    button.setAccessibilityLabel("ChatBird")
    button.setAccessibilityHelp(
        "打开 ChatBird 菜单；隐藏后可选择“显示”或按 \(chatBirdVisibilityHotKeyDisplayName) 恢复面板"
    )
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let quotaClient = CodexQuotaClient()
    private let claudeQuotaClient = ClaudeQuotaClient()
    private let quotaProviderPreference = QuotaProviderPreference()
    private let locator = PetWindowLocator()
    private let healthWriter = RuntimeHealthWriter()
    private let petSelectionStore = ChatBirdPetSelectionStore()
    private let taskActivityPreviewController = TaskActivityPreviewController()
    private let dashboardStore = ActivityDashboardStore()
    private let presentationModePreference = PresentationModePreference()
    private var presentationMode: PresentationMode = .petPanel
    private var claudePermissionCoordinator: ClaudePermissionCoordinator!
    private var claudePermissionPanelPresenter: ClaudePermissionPanelPresenter!
    private var dynamicIslandController: DynamicIslandWindowController!
    private var dynamicIslandConfirmationPresenter:
        DynamicIslandConfirmationPresenter!
    private var claudePermissionHookServer: ClaudePermissionHookServer?
    private var dashboardObserverToken: UUID?
    private var screenParametersObserver: NSObjectProtocol?
    private let quotaView = QuotaPanelView(frame: NSRect(origin: .zero, size: expandedPanelSize))
    private var panel: NSPanel!
    private var statusItem: NSStatusItem?
    private var visibilityHotKey: ChatBirdVisibilityHotKey?
    private var refreshTimer: Timer?
    private var taskProgressTimer: Timer?
    private var followTimer: Timer?
    private var globalMouseMonitor: Any?
    private let taskProgressReaderStore = TaskProgressRefreshReaderStore()
    private var refreshingQuotaProviders = Set<QuotaProvider>()
    private var taskProgressRefreshGate = TaskProgressRefreshGate()
    private var lastLocatedPet: LocatedPet?
    private var lastLocatedAt: CFAbsoluteTime = 0
    private var lastPetLocationPollAt: CFAbsoluteTime = 0
    private var lastPetMovementAt: CFAbsoluteTime = 0
    private var lastWindowStackCheckAt: CFAbsoluteTime = 0
    private var petPanelFallbackDisplayID: CGDirectDisplayID?
    private var currentPanelScale: CGFloat = 1
    private var currentBasePanelSize = expandedPanelSize
    private var isPanelHiddenByUser = false
    private var ignoreVisiblePetDoubleClickUntil: CFAbsoluteTime = 0
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
            label: "dev.chatbird.codex-quota-panel.native-activity",
            qos: .utility
        )
        return NativeActivityPillSuppressionMonitor(
            interval: taskProgressRefreshInterval,
            shouldSuppress: {
                suppressor.isTrusted
            },
            suppress: {
                if case .muted = suppressor.suppressActivityPillsIfNeeded() {
                    fputs("ChatBird 已自动静音新出现的 Codex 原生任务气泡。\n", stderr)
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
        NSApp.setActivationPolicy(.accessory)
        presentationMode = presentationModePreference.mode
        selectChatBirdAtStartup(using: petSelectionStore)
        let availableProviders = synchronizeQuotaProviderAvailability()
        makePanel()
        makeDynamicIslandController()
        startCodexDesktopMonitoring()
        startClaudePermissionHook()
        startScreenParameterMonitoring()
        makeStatusItem()
        makeVisibilityHotKey()
        startPetClickMonitor()
        bindClaudePermissionPresenter(for: presentationMode)
        applyInitialPresentationVisibility()
        updateStatusMenu()
        healthWriter.write(status: "started", panelVisible: false, locationSource: nil, force: true)
        availableProviders.forEach { refreshQuota(provider: $0) }
        refreshTaskProgress()
        nativeActivityPillSuppressionMonitor.start()

        followTimer = Timer.scheduledTimer(withTimeInterval: followInterval, repeats: true) { [weak self] _ in
            self?.followPet(forceLocationPoll: false)
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

    func applicationWillTerminate(_ notification: Notification) {
        nativeActivityPillSuppressionMonitor.stop()
        codexOverlayNotificationSynchronizer.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
        if let dashboardObserverToken {
            dashboardStore.removeObserver(dashboardObserverToken)
        }
        dynamicIslandConfirmationPresenter?.setPresentationActive(false)
        claudePermissionCoordinator?.cancelAll()
        claudePermissionHookServer?.stop()
        taskActivityPreviewController.hide()
        quotaView.setRunningTaskBadgeAnimationsEnabled(false)
        dynamicIslandController?.hide()
        panel?.orderOut(nil)
        refreshTimer?.invalidate()
        taskProgressTimer?.invalidate()
        followTimer?.invalidate()
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        visibilityHotKey = nil
        healthWriter.write(status: "terminated", panelVisible: false, locationSource: nil, force: true)
    }

    private func makePanel() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: expandedPanelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = quotaView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = panelDefaultWindowLevel
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        quotaView.onRequestHide = { [weak self] in
            self?.hidePanelByUser()
        }
        quotaView.onRequestDynamicIsland = { [weak self] in
            self?.selectPresentationMode(.dynamicIsland)
        }
        quotaView.onRequestQuotaRefresh = { [weak self] in
            self?.refreshQuota()
        }
        quotaView.onSelectQuotaProvider = { [weak self] provider in
            self?.selectQuotaProvider(provider)
        }
        quotaView.onHoverRunningTask = { [weak self] item, anchorRect in
            guard let self else { return }
            guard let item, let anchorRect else {
                self.taskActivityPreviewController.hide()
                return
            }
            self.taskActivityPreviewController.show(
                item: item,
                anchorRect: anchorRect
            )
        }
        quotaView.onOpenTask = { [weak self] item in
            self?.openTask(item)
        }
        dashboardObserverToken = dashboardStore.observe { [weak self] snapshot in
            guard let self else { return }
            self.quotaView.applyDashboardSnapshot(snapshot)
            let compact = snapshot.taskCollection.compactProjection()
            let nextBaseSize = panelSizeForTaskRows(compact.rowCount)
            if nextBaseSize != self.currentBasePanelSize {
                self.currentBasePanelSize = nextBaseSize
                self.followPet()
            }
        }
    }

    private func makeDynamicIslandController() {
        let controller = DynamicIslandWindowController(store: dashboardStore)
        controller.onRequestHide = { [weak self] in
            self?.hidePanelByUser()
        }
        controller.onRequestPetPanel = { [weak self] in
            self?.selectPresentationMode(.petPanel)
        }
        controller.onOpenTask = { [weak self] item in
            self?.openTask(item)
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
                  presentationRuntimeDecision(
                      mode: self.presentationMode,
                      hiddenByUser: self.isPanelHiddenByUser
                  ).showDynamicIsland
            else { return }
            controller?.expand(tab)
        }
    }

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: chatBirdStatusItemLength)
        configureChatBirdStatusButton(item.button)
        item.menu = makeStatusMenu()
        item.isVisible = true
        statusItem = item
    }

    private func makeVisibilityHotKey() {
        visibilityHotKey = ChatBirdVisibilityHotKey { [weak self] in
            self?.handlePresentationCommand(.toggleVisibility)
        }
        if visibilityHotKey == nil {
            fputs(
                "ChatBird 无法注册全局快捷键 \(chatBirdVisibilityHotKeyDisplayName)\n",
                stderr
            )
        }
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu(title: "ChatBird")
        menu.delegate = self
        menu.addItem(menuItem(command: .toggleVisibility))
        menu.addItem(.separator())
        menu.addItem(menuItem(command: .selectMode(.petPanel)))
        menu.addItem(menuItem(command: .selectMode(.dynamicIsland)))
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
        item.isEnabled = isPresentationCommandEnabled(
            command,
            mode: presentationMode
        )
        item.state = .off
        item.keyEquivalent = ""
        item.keyEquivalentModifierMask = []
        switch command {
        case .toggleVisibility:
            item.title = isPanelHiddenByUser ? "显示" : "隐藏"
            item.keyEquivalent = chatBirdVisibilityHotKeyKeyEquivalent
            item.keyEquivalentModifierMask = chatBirdVisibilityHotKeyModifierMask
        case .selectMode(.petPanel):
            item.title = "宠物面板"
            item.state = presentationMode == .petPanel ? .on : .off
        case .selectMode(.dynamicIsland):
            item.title = "灵动岛"
            item.state = presentationMode == .dynamicIsland ? .on : .off
        case .moveToCurrentDisplay:
            item.title = "移到当前显示器"
        case .quit:
            item.title = "退出 ChatBird"
        }
    }

    @objc private func handlePresentationMenuItem(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? PresentationCommand
        else { return }
        handlePresentationCommand(command)
    }

    private func handlePresentationCommand(_ command: PresentationCommand) {
        guard isPresentationCommandEnabled(command, mode: presentationMode)
        else { return }
        switch command {
        case .toggleVisibility:
            if isPanelHiddenByUser {
                showPanelFromStatusItem()
            } else {
                hidePanelByUser()
            }
        case .selectMode(let mode):
            selectPresentationMode(mode)
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
        let decision = codexLifecyclePresentationDecision(
            mode: presentationMode,
            hiddenByUser: isPanelHiddenByUser,
            codexDesktopRunning: codexDesktopRunning
        )
        if presentationMode == .petPanel {
            followPet(forceLocationPoll: true)
        } else if decision.showDynamicIsland {
            dynamicIslandController?.showCapsule()
        } else {
            dynamicIslandController?.hide()
        }
    }

    private func startClaudePermissionHook() {
        claudePermissionCoordinator = ClaudePermissionCoordinator(
            openTerminal: { [weak self] prompt in
                self?.openTerminalForClaudePermission(prompt)
            },
            onQueueChange: { [weak self] queue in
                self?.dashboardStore.update { $0.permissionQueue = queue }
            }
        )
        claudePermissionPanelPresenter = ClaudePermissionPanelPresenter(
            anchorWindowProvider: { [weak self] in self?.panel }
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
                fputs("ChatBird Claude Hook 已监听 \(ClaudeHookConstants.url)\n", stderr)
            case .failed(let reason):
                fputs("ChatBird Claude Hook 启动失败：\(reason)\n", stderr)
            case .starting, .stopped:
                break
            }
        }
        do {
            try server.start()
            claudePermissionHookServer = server
        } catch {
            fputs("ChatBird Claude Hook 启动失败：\(error.localizedDescription)\n", stderr)
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
            if dynamicIslandScreen(displayID: self.petPanelFallbackDisplayID) == nil {
                self.petPanelFallbackDisplayID = nil
            }
            self.followPet(forceLocationPoll: true)
        }
    }

    private func openTerminalForClaudePermission(_ prompt: ClaudePermissionPrompt) {
        let request = claudeTerminalOpenRequest(
            for: prompt,
            taskItems: dashboardStore.snapshot.taskCollection.items
        )
        if openClaudeTerminal(request: request) {
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
        statusItem?.length = chatBirdStatusItemLength
        configureChatBirdStatusButton(statusItem?.button)
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

    private func startPetClickMonitor() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) {
            [weak self] event in
            let clickCount = event.clickCount
            let clickLocation = NSEvent.mouseLocation
            DispatchQueue.main.async {
                self?.handlePetClick(at: clickLocation, clickCount: clickCount)
            }
        }
    }

    private func handlePetClick(at location: NSPoint, clickCount: Int) {
        guard shouldHandlePetClick(mode: presentationMode) else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard cachedCodexDesktopRunning, let pet = locator.locate() else { return }
        let action = petPanelClickAction(
            clickCount: clickCount,
            clickLocation: location,
            petVisibleRect: pet.visibleRect,
            panelHidden: isPanelHiddenByUser,
            suppressVisibleDoubleClick: now < ignoreVisiblePetDoubleClickUntil
        )
        guard action != .none else { return }

        lastLocatedPet = pet
        lastLocatedAt = now
        if action == .show {
            ignoreVisiblePetDoubleClickUntil = now + NSEvent.doubleClickInterval
            showPanelFromStatusItem()
        } else {
            hidePanelByUser()
        }
    }

    private func hidePanelByUser() {
        isPanelHiddenByUser = true
        taskActivityPreviewController.hide()
        dynamicIslandController?.hide()
        quotaView.setRunningTaskBadgeAnimationsEnabled(false)
        panel.level = panelDefaultWindowLevel
        panel.orderOut(nil)
        updateStatusMenu()
        healthWriter.write(
            status: "hidden-by-user",
            panelVisible: false,
            locationSource: nil,
            panelScale: currentPanelScale,
            panelSize: scaledPanelSize(currentBasePanelSize, scale: currentPanelScale),
            force: true
        )
    }

    @objc private func showPanelFromStatusItem() {
        isPanelHiddenByUser = false
        updateStatusMenu()
        showCurrentPresentation()
    }

    private func applyInitialPresentationVisibility() {
        hideCurrentPresentation()
        showCurrentPresentation()
    }

    private func selectPresentationMode(_ mode: PresentationMode) {
        guard presentationMode != mode else { return }
        if mode == .petPanel, presentationMode == .dynamicIsland {
            petPanelFallbackDisplayID = dynamicIslandController?.targetDisplayID
        }
        hideCurrentPresentation()
        taskActivityPreviewController.hide()
        presentationMode = mode
        presentationModePreference.mode = mode
        bindClaudePermissionPresenter(for: mode)
        showCurrentPresentation()
        updateStatusMenu()
    }

    private func hideCurrentPresentation() {
        taskActivityPreviewController.hide()
        quotaView.setRunningTaskBadgeAnimationsEnabled(false)
        panel?.orderOut(nil)
        dynamicIslandController?.hide()
    }

    private func showCurrentPresentation() {
        let decision = presentationRuntimeDecision(
            mode: presentationMode,
            hiddenByUser: isPanelHiddenByUser
        )
        quotaView.setRunningTaskBadgeAnimationsEnabled(decision.showPetPanel)
        if decision.showPetPanel {
            followPet(forceLocationPoll: true)
        } else {
            panel?.orderOut(nil)
        }
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

    private func bindClaudePermissionPresenter(for mode: PresentationMode) {
        let decision = presentationRuntimeDecision(
            mode: mode,
            hiddenByUser: isPanelHiddenByUser
        )
        dynamicIslandConfirmationPresenter?.setPresentationActive(
            decision.bindDynamicPermissionPresenter
        )
        if decision.bindDynamicPermissionPresenter {
            claudePermissionCoordinator?.setPresenter(
                dynamicIslandConfirmationPresenter
            )
        } else if decision.bindLegacyPermissionPresenter {
            claudePermissionCoordinator?.setPresenter(
                claudePermissionPanelPresenter
            )
        }
    }

    private func followPet(forceLocationPoll: Bool = true) {
        let now = CFAbsoluteTimeGetCurrent()
        if presentationMode == .dynamicIsland {
            if forceLocationPoll
                || now - lastWindowStackCheckAt >= overlayStateRefreshInterval
            {
                lastWindowStackCheckAt = now
                dynamicIslandController?.reconcileWindowLevel(
                    entries: currentWindowStackEntries()
                )
            }
            return
        }
        guard cachedCodexDesktopRunning else {
            lastLocatedPet = nil
            lastLocatedAt = 0
            lastPetLocationPollAt = 0
            lastPetMovementAt = 0
            lastWindowStackCheckAt = 0
            taskActivityPreviewController.hide()
            quotaView.setRunningTaskBadgeAnimationsEnabled(false)
            panel.level = panelDefaultWindowLevel
            panel.orderOut(nil)
            healthWriter.write(
                status: "waiting-for-codex",
                panelVisible: false,
                locationSource: nil,
                panelScale: currentPanelScale,
                panelSize: scaledPanelSize(currentBasePanelSize, scale: currentPanelScale)
            )
            return
        }
        guard !isPanelHiddenByUser else {
            taskActivityPreviewController.hide()
            quotaView.setRunningTaskBadgeAnimationsEnabled(false)
            panel.level = panelDefaultWindowLevel
            panel.orderOut(nil)
            return
        }

        guard shouldPollPetLocation(
            now: now,
            lastPollAt: lastPetLocationPollAt,
            lastMovementAt: lastPetMovementAt,
            force: forceLocationPoll
        ) else { return }
        lastPetLocationPollAt = now

        let pet: LocatedPet
        let panelStatus: String
        if let located = locator.locate() {
            if locatedPetGeometryDiffers(lastLocatedPet, from: located) {
                lastPetMovementAt = now
            }
            lastLocatedPet = located
            lastLocatedAt = now
            petPanelFallbackDisplayID = dynamicIslandDisplayID(for: located.screen)
            pet = located
            panelStatus = "following-pet"
        } else if let recent = lastLocatedPet, now - lastLocatedAt <= 0.50 {
            // Preserve the last exact attachment only across a brief window-list
            // transition. Never leave the panel at an unrelated screen corner.
            pet = recent
            panelStatus = "following-pet"
        } else if let saved = locator.locateSavedState(
            allowClosedOverlay: true,
            preferredDisplayID: petPanelFallbackDisplayID
        ) {
            petPanelFallbackDisplayID = dynamicIslandDisplayID(for: saved.screen)
            pet = saved
            panelStatus = "pet-panel-saved-position-fallback"
        } else {
            taskActivityPreviewController.hide()
            presentDetachedPetPanel()
            return
        }

        let basePanelSize = currentBasePanelSize
        currentPanelScale = presentedPanelScale(pet.panelScale)
        quotaView.setRunningTaskBadgeAnimationsEnabled(true)

        let currentPanelSize = scaledPanelSize(basePanelSize, scale: currentPanelScale)
        let placement = panelPlacement(
            petVisibleRect: pet.visibleRect,
            panelSize: currentPanelSize,
            panelScale: currentPanelScale,
            screenVisibleFrame: pet.screen.visibleFrame
        )

        quotaView.pointerSide = .bottom
        let targetPointerCenterX = placement.pointerCenterX / currentPanelScale
        if quotaView.pointerCenterX.map({
            abs($0 - targetPointerCenterX) > 0.1
        }) ?? true {
            quotaView.pointerCenterX = targetPointerCenterX
        }
        let targetOrigin = placement.origin
        let targetFrame = NSRect(origin: targetOrigin, size: currentPanelSize)
        let panelFrameChanged = rectDiffers(panel.frame, from: targetFrame)
        if panelFrameChanged {
            panel.setFrame(targetFrame, display: false)
        }
        // Keep the view's design coordinate system at the current task-list
        // height while its frame follows the scaled window. AppKit then scales
        // every visual and hit target together without changing proportions.
        let targetViewFrame = NSRect(origin: .zero, size: currentPanelSize)
        let targetViewBounds = NSRect(origin: .zero, size: basePanelSize)
        let contentGeometryChanged = rectDiffers(
            quotaView.frame,
            from: targetViewFrame
        ) || rectDiffers(
            quotaView.bounds,
            from: targetViewBounds
        )
        if contentGeometryChanged {
            quotaView.frame = targetViewFrame
            quotaView.bounds = targetViewBounds
            quotaView.needsDisplay = true
            panel.invalidateCursorRects(for: quotaView)
        }
        if panelFrameChanged || contentGeometryChanged {
            quotaView.refreshHoveredTaskAnchor()
            claudePermissionPanelPresenter?.reposition()
        }

        var shouldReorderForNativeActivity = false
        if panel.isVisible,
           forceLocationPoll
            || now - lastWindowStackCheckAt >= overlayStateRefreshInterval
        {
            lastWindowStackCheckAt = now
            let windowNumber = panel.windowNumber
            if windowNumber > 0 {
                let entries = currentWindowStackEntries()
                let panelWindowNumber = CGWindowID(windowNumber)
                let activityStackIntersects =
                    nativeActivityStackIntersectsPanel(
                        entries: entries,
                        panelWindowNumber: panelWindowNumber
                    )
                let targetLevel = activityStackIntersects
                    ? panelNativeActivityWindowLevel
                    : panelDefaultWindowLevel
                let panelLevelChanged =
                    panel.level.rawValue != targetLevel.rawValue
                if panelLevelChanged {
                    panel.level = targetLevel
                }
                shouldReorderForNativeActivity = panelLevelChanged
                    || nativeActivityStackOccludesPanel(
                        entries: entries,
                        panelWindowNumber: panelWindowNumber
                    )
            }
        }
        if shouldPresentPanel(
            codexDesktopRunning: true,
            hiddenByUser: isPanelHiddenByUser,
            hasPetLocation: true
        ), !panel.isVisible || shouldReorderForNativeActivity {
            panel.orderFrontRegardless()
        }
        healthWriter.write(
            status: panelStatus,
            panelVisible: true,
            locationSource: pet.source,
            gap: placement.actualGap,
            centerError: placement.centerError,
            panelScale: currentPanelScale,
            panelSize: currentPanelSize
        )
    }

    private func presentDetachedPetPanel() {
        guard shouldPresentDetachedPetPanel(
            codexDesktopRunning: cachedCodexDesktopRunning,
            hiddenByUser: isPanelHiddenByUser
        ) else {
            quotaView.setRunningTaskBadgeAnimationsEnabled(false)
            panel.orderOut(nil)
            return
        }
        guard let screen = dynamicIslandScreen(
            displayID: petPanelFallbackDisplayID
        ) ?? dynamicIslandScreenContaining(
            point: NSEvent.mouseLocation
        ) ?? NSScreen.main ?? NSScreen.screens.first else {
            quotaView.setRunningTaskBadgeAnimationsEnabled(false)
            panel.orderOut(nil)
            healthWriter.write(
                status: "waiting-for-display",
                panelVisible: false,
                locationSource: nil,
                force: true
            )
            return
        }

        petPanelFallbackDisplayID = dynamicIslandDisplayID(for: screen)
        currentPanelScale = 1
        let basePanelSize = currentBasePanelSize
        let panelSize = scaledPanelSize(basePanelSize, scale: currentPanelScale)
        let targetFrame = detachedPanelFrame(
            panelSize: panelSize,
            screenVisibleFrame: screen.visibleFrame
        )
        let targetViewFrame = NSRect(origin: .zero, size: panelSize)
        let targetViewBounds = NSRect(origin: .zero, size: basePanelSize)
        let panelFrameChanged = rectDiffers(panel.frame, from: targetFrame)
        let contentGeometryChanged = rectDiffers(
            quotaView.frame,
            from: targetViewFrame
        ) || rectDiffers(
            quotaView.bounds,
            from: targetViewBounds
        )

        quotaView.pointerSide = .bottom
        quotaView.pointerCenterX = basePanelSize.width / 2
        if panelFrameChanged {
            panel.setFrame(targetFrame, display: false)
        }
        if contentGeometryChanged {
            quotaView.frame = targetViewFrame
            quotaView.bounds = targetViewBounds
            quotaView.needsDisplay = true
            panel.invalidateCursorRects(for: quotaView)
        }
        if panelFrameChanged || contentGeometryChanged {
            quotaView.refreshHoveredTaskAnchor()
            claudePermissionPanelPresenter?.reposition()
        }

        quotaView.setRunningTaskBadgeAnimationsEnabled(true)
        panel.level = panelDefaultWindowLevel
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        healthWriter.write(
            status: "pet-panel-display-fallback",
            panelVisible: true,
            locationSource: "display-fallback",
            panelScale: currentPanelScale,
            panelSize: panelSize
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

    private func openTask(_ item: TaskProgressItem) {
        switch item.source {
        case .codex:
            guard let threadID = item.threadID,
                  let url = codexThreadURL(threadID: threadID)
            else { return }
            NSWorkspace.shared.open(url)
        case .claudeCode:
            if claudePermissionCoordinator?
                .handoffToTerminalIfPresenting(item) == true
            {
                return
            }
            openClaudeTerminal(
                request: claudeTerminalOpenRequest(for: item)
            )
        }
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
        let claudeCodeAvailable = synchronizeQuotaProviderAvailability()
            .contains(.claudeCode)
        let readerStore = taskProgressReaderStore
        let reader = readerStore.leaseReader(for: generation)
        DispatchQueue.global(qos: .utility).async { [weak self, readerStore] in
            let collection = reader.readCollection(
                claudeCodeAvailable: claudeCodeAvailable
            )
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
                self.dashboardStore.update {
                    $0.taskCollection = collection
                    $0.isTaskRefreshing = false
                }
                // 终端里直接回答后 Claude 不会关闭 hook 连接，靠这次刷新的会话
                // 状态收起已经不需要的问答弹窗。
                self.claudePermissionCoordinator?
                    .dismissIfAnsweredInTerminal(in: collection.items)
            }
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
