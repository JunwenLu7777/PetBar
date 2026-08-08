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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let quotaClient = CodexQuotaClient()
    private let claudeQuotaClient = ClaudeQuotaClient()
    private let quotaProviderPreference = QuotaProviderPreference()
    private let locator = PetWindowLocator()
    private let healthWriter = RuntimeHealthWriter()
    private let petSelectionStore = ChatBirdPetSelectionStore()
    private let taskActivityPreviewController = TaskActivityPreviewController()
    private var claudePermissionPanelController: ClaudePermissionPanelController!
    private var claudePermissionHookServer: ClaudePermissionHookServer?
    private let quotaView = QuotaPanelView(frame: NSRect(origin: .zero, size: expandedPanelSize))
    private var panel: NSPanel!
    private var statusItem: NSStatusItem?
    private var refreshTimer: Timer?
    private var taskProgressTimer: Timer?
    private var followTimer: Timer?
    private var globalMouseMonitor: Any?
    private let taskProgressReaderStore = TaskProgressRefreshReaderStore()
    private var isRefreshing = false
    private var quotaRowsByProvider: [QuotaProvider: [QuotaRow]] = [:]
    private var currentCodexResetCreditsSnapshot: CodexResetCreditsSnapshot?
    private var taskProgressRefreshGate = TaskProgressRefreshGate()
    private var lastLocatedPet: LocatedPet?
    private var lastLocatedAt: CFAbsoluteTime = 0
    private var lastPetLocationPollAt: CFAbsoluteTime = 0
    private var lastPetMovementAt: CFAbsoluteTime = 0
    private var lastWindowStackCheckAt: CFAbsoluteTime = 0
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
        selectChatBirdAtStartup(using: petSelectionStore)
        let availableProviders = synchronizeQuotaProviderAvailability()
        makePanel()
        startCodexDesktopMonitoring()
        startClaudePermissionHook()
        makeStatusItem()
        startPetClickMonitor()
        updateStatusItem()
        healthWriter.write(status: "started", panelVisible: false, locationSource: nil, force: true)
        followPet()
        refreshQuota()
        if let backgroundProvider = availableProviders.first(where: {
            $0 != quotaView.selectedQuotaProvider
        }) {
            refreshBackgroundQuotaSummary(for: backgroundProvider)
        }
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
        claudePermissionPanelController?.cancelAll()
        claudePermissionHookServer?.stop()
        taskActivityPreviewController.hide()
        quotaView.setRunningTaskBadgeAnimationsEnabled(false)
        refreshTimer?.invalidate()
        taskProgressTimer?.invalidate()
        followTimer?.invalidate()
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
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
            switch item.source {
            case .codex:
                guard let threadID = item.threadID,
                      let url = codexThreadURL(threadID: threadID)
                else { return }
                NSWorkspace.shared.open(url)
            case .claudeCode:
                if self?.claudePermissionPanelController?
                    .handoffToTerminalIfPresenting(item) == true
                {
                    return
                }
                openClaudeTerminal(
                    request: claudeTerminalOpenRequest(for: item)
                )
            }
        }
    }

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "ChatBird"
        item.button?.toolTip = "ChatBird 额度面板"
        item.button?.target = self
        item.button?.action = #selector(handleStatusItem)
        item.isVisible = false
        statusItem = item
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
        codexOverlayNotificationSynchronizer.codexRunningStateDidChange(
            isRunning
        )
        if !isRunning {
            claudePermissionPanelController?.cancelAll()
        }
        followPet(forceLocationPoll: true)
    }

    private func startClaudePermissionHook() {
        claudePermissionPanelController = ClaudePermissionPanelController(
            anchorWindowProvider: { [weak self] in self?.panel },
            openTerminal: { [weak self] prompt in
                self?.openTerminalForClaudePermission(prompt)
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
            self.claudePermissionPanelController.enqueue(
                prompt: prompt,
                completion: completion
            )
        }
        server.onRequestExpired = { [weak self] requestID in
            self?.claudePermissionPanelController.expire(requestID: requestID)
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

    private func openTerminalForClaudePermission(_ prompt: ClaudePermissionPrompt) {
        let request = claudeTerminalOpenRequest(
            for: prompt,
            taskItems: quotaView.taskProgress.items
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

    private func updateStatusItem() {
        statusItem?.button?.title = "ChatBird"
        statusItem?.button?.toolTip = "显示 ChatBird 额度面板"
        statusItem?.isVisible = isPanelHiddenByUser
    }

    @objc private func handleStatusItem() {
        showPanelFromStatusItem()
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
        quotaView.setRunningTaskBadgeAnimationsEnabled(false)
        panel.level = panelDefaultWindowLevel
        panel.orderOut(nil)
        updateStatusItem()
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
        updateStatusItem()
        followPet()
    }

    private func followPet(forceLocationPoll: Bool = true) {
        let now = CFAbsoluteTimeGetCurrent()
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

        guard shouldPollPetLocation(
            now: now,
            lastPollAt: lastPetLocationPollAt,
            lastMovementAt: lastPetMovementAt,
            force: forceLocationPoll
        ) else { return }
        lastPetLocationPollAt = now

        let pet: LocatedPet
        if let located = locator.locate() {
            if locatedPetGeometryDiffers(lastLocatedPet, from: located) {
                lastPetMovementAt = now
            }
            lastLocatedPet = located
            lastLocatedAt = now
            pet = located
        } else if let recent = lastLocatedPet, now - lastLocatedAt <= 0.50 {
            // Preserve the last exact attachment only across a brief window-list
            // transition. Never leave the panel at an unrelated screen corner.
            pet = recent
        } else {
            taskActivityPreviewController.hide()
            quotaView.setRunningTaskBadgeAnimationsEnabled(false)
            panel.level = panelDefaultWindowLevel
            panel.orderOut(nil)
            healthWriter.write(
                status: "waiting-for-pet-location",
                panelVisible: false,
                locationSource: nil,
                panelScale: currentPanelScale,
                panelSize: scaledPanelSize(currentBasePanelSize, scale: currentPanelScale)
            )
            return
        }

        let basePanelSize = currentBasePanelSize
        currentPanelScale = presentedPanelScale(pet.panelScale)
        if isPanelHiddenByUser {
            taskActivityPreviewController.hide()
            quotaView.setRunningTaskBadgeAnimationsEnabled(false)
            panel.level = panelDefaultWindowLevel
            panel.orderOut(nil)
            claudePermissionPanelController?.reposition()
            return
        }

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
            claudePermissionPanelController?.reposition()
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
            status: "following-pet",
            panelVisible: true,
            locationSource: pet.source,
            gap: placement.actualGap,
            centerError: placement.centerError,
            panelScale: currentPanelScale,
            panelSize: currentPanelSize
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
        quotaView.availableQuotaProviders = availableProviders
        if preferredProvider != resolvedProvider {
            quotaProviderPreference.selectedProvider = resolvedProvider
        }
        if quotaView.selectedQuotaProvider != resolvedProvider {
            quotaView.selectedQuotaProvider = resolvedProvider
            quotaView.rows = quotaRowsByProvider[resolvedProvider] ?? []
            quotaView.codexResetCredits = currentCodexResetCreditsSnapshot
            quotaView.errorText = nil
            quotaView.statusText = quotaView.rows.isEmpty
                ? "正在读取额度…"
                : "正在更新…"
        }
        return availableProviders
    }

    private func refreshQuota() {
        synchronizeQuotaProviderAvailability()
        guard !isRefreshing else { return }
        isRefreshing = true
        let provider = quotaView.selectedQuotaProvider
        quotaView.isQuotaRefreshing = true
        if quotaView.rows.isEmpty {
            quotaView.errorText = nil
            quotaView.statusText = provider == .codex
                ? "正在读取 Codex 额度…"
                : "正在读取 Claude 额度…"
        } else {
            quotaView.statusText = "正在更新…"
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
        isRefreshing = false
        guard quotaView.selectedQuotaProvider == provider else {
            refreshQuota()
            return
        }
        quotaView.isQuotaRefreshing = false

        switch result {
        case .success(let payload):
            let updatedAt = Date()
            let rows = payload.rows
            cacheQuotaRows(rows, for: provider)
            if provider == .codex {
                currentCodexResetCreditsSnapshot = payload.resetCredits
                quotaView.codexResetCredits = payload.resetCredits
            }
            quotaView.rows = rows
            quotaView.errorText = rows.isEmpty
                ? (provider == .codex
                    ? "周额度暂不可用"
                    : "Claude 额度暂不可用")
                : nil
            quotaView.statusText = rows.isEmpty
                ? "没有可确认的额度数据"
                : quotaSuccessStatusText(
                    provider: provider,
                    rows: rows,
                    updatedAt: updatedAt
                )
        case .failure(let error):
            let existingRows = quotaRowsByProvider[provider] ?? []
            quotaView.rows = existingRows
            let presentation = quotaFailurePresentation(
                for: error,
                hasExistingRows: !existingRows.isEmpty,
                provider: provider
            )
            quotaView.errorText = presentation.errorText
            quotaView.statusText = presentation.statusText
            if provider == .codex {
                currentCodexResetCreditsSnapshot = nil
                quotaView.codexResetCredits = nil
            }
        }
    }

    private func selectQuotaProvider(_ provider: QuotaProvider) {
        guard quotaView.availableQuotaProviders.contains(provider) else { return }
        quotaProviderPreference.selectedProvider = provider
        quotaView.selectedQuotaProvider = provider
        quotaView.rows = quotaRowsByProvider[provider] ?? []
        quotaView.codexResetCredits = currentCodexResetCreditsSnapshot
        quotaView.errorText = nil
        quotaView.statusText = quotaView.rows.isEmpty
            ? "正在读取额度…"
            : "正在更新…"
        if !isRefreshing {
            refreshQuota()
        }
    }

    private func cacheQuotaRows(_ rows: [QuotaRow], for provider: QuotaProvider) {
        quotaRowsByProvider[provider] = rows
        quotaView.providerRemainingPercents = quotaProviderRemainingPercents(
            afterCaching: rows,
            for: provider,
            existing: quotaView.providerRemainingPercents
        )
    }

    private func refreshBackgroundQuotaSummary(for provider: QuotaProvider) {
        switch provider {
        case .codex:
            quotaClient.fetch { [weak self] result in
                guard case .success(let response) = result else { return }
                let rows = Self.makeRows(from: response)
                let resetCredits = makeCodexResetCreditsSnapshot(
                    from: response,
                    now: Date()
                )
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.cacheQuotaRows(rows, for: provider)
                    self.currentCodexResetCreditsSnapshot = resetCredits
                    self.quotaView.codexResetCredits = resetCredits
                }
            }
        case .claudeCode:
            claudeQuotaClient.fetch { [weak self] result in
                guard case .success(let snapshot) = result else { return }
                DispatchQueue.main.async {
                    self?.cacheQuotaRows(snapshot.rows, for: provider)
                }
            }
        }
    }

    private func refreshTaskProgress() {
        guard let generation = taskProgressRefreshGate.begin() else { return }
        let claudeCodeAvailable = synchronizeQuotaProviderAvailability()
            .contains(.claudeCode)
        let readerStore = taskProgressReaderStore
        let reader = readerStore.leaseReader(for: generation)
        DispatchQueue.global(qos: .utility).async { [weak self, readerStore] in
            let snapshot = reader.read(
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
                self.quotaView.taskProgress = snapshot
                // 终端里直接回答后 Claude 不会关闭 hook 连接，靠这次刷新的会话
                // 状态收起已经不需要的问答弹窗。
                self.claudePermissionPanelController?
                    .dismissIfAnsweredInTerminal(in: snapshot.items)
                let nextBaseSize = panelSizeForTaskRows(snapshot.rowCount)
                if nextBaseSize != self.currentBasePanelSize {
                    self.currentBasePanelSize = nextBaseSize
                    self.followPet()
                }
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

func quotaProviderRemainingPercents(
    afterCaching rows: [QuotaRow],
    for provider: QuotaProvider,
    existing: [QuotaProvider: Int]
) -> [QuotaProvider: Int] {
    var summaries = existing
    if let remaining = rows.first(where: {
        $0.name == provider.summaryRowName
    })?.remainingPercent {
        summaries[provider] = remaining
    } else {
        summaries.removeValue(forKey: provider)
    }
    return summaries
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
