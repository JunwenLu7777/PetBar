import AppKit
import CoreGraphics
import Foundation

final class DynamicIslandPanel: NSPanel {
    var allowsKeyWindow = false

    override var canBecomeKey: Bool { allowsKeyWindow }
    override var canBecomeMain: Bool { false }
}

final class DynamicIslandWindowController {
    private(set) var state: DynamicIslandPresentationState = .hidden
    private(set) var targetDisplayID: CGDirectDisplayID?
    private(set) var isAnimating = false

    var onOpenTask: ((TaskProgressItem) -> OpenResult)?
    var onRequestHide: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onQuotaProviderChange: ((QuotaProvider) -> Void)?
    var onPerformIntegration: ((AgentID, AgentIntegrationOperation) -> Void)?
    var onToggleAutoIntegration: ((Bool) -> Void)?
    var onCopyWorkingDirectory: ((String) -> Bool)?
    var onTaskDetailOpened: ((TaskProgressItem) -> Void)?

    let panel: DynamicIslandPanel

    private let rootController = DynamicIslandRootViewController()
    private let store: ActivityDashboardStore?
    private var storeObserverToken: UUID?
    private var currentSnapshot = ActivityDashboardSnapshot()
    private(set) var selectedTaskKey: String?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var animationGeneration = 0
    private var suppressSelectedTaskAcknowledgement = false
    private var rememberedExpandedSize: NSSize?
    private var resizeObserver: NSObjectProtocol?

    init(store: ActivityDashboardStore? = nil) {
        self.store = store
        let screen = dynamicIslandScreenContaining(
            point: NSEvent.mouseLocation
        ) ?? NSScreen.main ?? NSScreen.screens.first
        targetDisplayID = screen.flatMap(dynamicIslandDisplayID(for:))

        panel = DynamicIslandPanel(
            contentRect: NSRect(origin: .zero, size: dynamicIslandCapsuleSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = rootController
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = panelDefaultWindowLevel
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.minSize = dynamicIslandCapsuleSize
        panel.maxSize = dynamicIslandCapsuleSize
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
        ]
        rootController.onExpand = { [weak self] tab, selectedTaskKey in
            self?.expand(tab, selectedTaskKey: selectedTaskKey)
        }
        rootController.onCapsuleDragEnded = { [weak self] point in
            self?.capsuleDragEnded(at: point)
        }
        rootController.onCollapse = { [weak self] in
            self?.collapse()
        }
        rootController.onHide = { [weak self] in
            guard let self else { return }
            if let onRequestHide = self.onRequestHide {
                onRequestHide()
            } else {
                self.hide()
            }
        }
        rootController.onRefresh = { [weak self] in
            self?.onRefresh?()
        }
        rootController.onTabChange = { [weak self] tab in
            self?.expand(tab, selectedTaskKey: nil)
        }
        rootController.onSourceFilterChange = { _ in }
        rootController.onQuotaProviderChange = { [weak self] provider in
            self?.onQuotaProviderChange?(provider)
        }
        rootController.onPerformIntegration = { [weak self] agentID, op in
            self?.onPerformIntegration?(agentID, op)
        }
        rootController.onToggleAutoIntegration = { [weak self] enabled in
            self?.onToggleAutoIntegration?(enabled)
        }
        rootController.onOpenTask = { [weak self] item in
            self?.onOpenTask?(item) ?? .failed
        }
        rootController.onCopyWorkingDirectory = { [weak self] path in
            return self?.copyWorkingDirectory(path) ?? false
        }
        rootController.onSelectedTaskKeyChange = { [weak self] key in
            self?.selectedTaskKeyDidChange(key)
        }

        if let store {
            currentSnapshot = store.snapshot
            storeObserverToken = store.observe { [weak self] snapshot in
                guard let self else { return }
                currentSnapshot = snapshot
                applySnapshotToRoot()
            }
        }
        applySnapshotToRoot(state: .capsule)
        applyFrame(for: .capsule)
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.expandedWindowDidResize()
        }
    }

    func setAgentIntegrationTransientState(
        _ state: AgentIntegrationRowTransientState,
        for agentID: AgentID
    ) {
        rootController.setAgentIntegrationTransientState(state, for: agentID)
    }

    deinit {
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
        removeInteractionMonitors()
        if let storeObserverToken {
            store?.removeObserver(storeObserverToken)
        }
    }

    func showCapsule() {
        state = .capsule
        panel.allowsKeyWindow = false
        panel.level = panelDefaultWindowLevel
        removeInteractionMonitors()
        rootController.hideTaskHover()
        applySnapshotToRoot()
        transition(to: .capsule, duration: 0)
        panel.orderFrontRegardless()
    }

    func expand(_ tab: DynamicIslandTab) {
        expand(tab, selectedTaskKey: nil)
    }

    func expand(_ tab: DynamicIslandTab, selectedTaskKey: String?) {
        guard !isAnimating else { return }
        state = .expanded(tab)
        self.selectedTaskKey = selectedTaskKey
        panel.allowsKeyWindow = true
        installInteractionMonitors()
        rootController.setSelectedTaskKey(selectedTaskKey)
        applySnapshotToRoot()
        acknowledgeTaskDetailIfNeeded(tab: tab, selectedTaskKey: selectedTaskKey)
        transition(to: .expanded(tab), duration: 0.22)
        panel.orderFrontRegardless()
    }

    func collapse() {
        state = .capsule
        releaseKeyFocus()
        panel.allowsKeyWindow = false
        removeInteractionMonitors()
        rootController.hideTaskHover()
        applySnapshotToRoot()
        transition(to: .capsule, duration: 0.18)
        panel.orderFrontRegardless()
    }

    func hide() {
        state = .hidden
        releaseKeyFocus()
        panel.allowsKeyWindow = false
        panel.level = panelDefaultWindowLevel
        removeInteractionMonitors()
        animationGeneration += 1
        isAnimating = false
        rootController.hideTaskHover()
        applySnapshotToRoot()
        panel.orderOut(nil)
    }

    func moveToScreenContainingMouse() {
        if let screen = dynamicIslandScreenContaining(
            point: NSEvent.mouseLocation
        ) {
            targetDisplayID = dynamicIslandDisplayID(for: screen)
            applyFrame(for: state == .hidden ? .capsule : state)
        }
    }

    func screenParametersDidChange() {
        if dynamicIslandScreen(displayID: targetDisplayID) == nil {
            targetDisplayID = (NSScreen.main ?? NSScreen.screens.first)
                .flatMap(dynamicIslandDisplayID(for:))
        }
        applyFrame(for: state == .hidden ? .capsule : state)
    }

    func setConfirmationInputActive(
        _ active: Bool,
        initialResponder: NSResponder? = nil
    ) {
        if active {
            panel.allowsKeyWindow = true
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKey()
            if let initialResponder {
                _ = panel.makeFirstResponder(initialResponder)
            }
        } else {
            releaseKeyFocus()
            panel.allowsKeyWindow = {
                if case .expanded = state { return true }
                return false
            }()
        }
    }

    func installConfirmationViewController(
        _ controller: DynamicIslandConfirmationViewController
    ) {
        rootController.installConfirmationViewController(controller)
    }

    func makeConfirmationPresenter(
        viewController: DynamicIslandConfirmationViewController
    ) -> DynamicIslandConfirmationPresenter {
        installConfirmationViewController(viewController)
        let presenter = DynamicIslandConfirmationPresenter(
            show: { [weak self] presentation in
                self?.rootController.applyConfirmationPresentation(presentation)
            },
            dismissView: { [weak self, weak viewController] in
                viewController?.clear()
                self?.rootController.clearConfirmationPresentation()
            },
            repositionWindow: { [weak self] in
                self?.moveToScreenContainingMouse()
            }
        )
        presenter.onExpand = { [weak self] tab in
            self?.expand(tab)
        }
        presenter.onReturnToPriorTab = { [weak self] tab in
            self?.expand(tab)
        }
        presenter.onSetKeyWindowEligibility = {
            [weak self, weak viewController] active in
            self?.setConfirmationInputActive(
                active,
                initialResponder: active
                    ? viewController?.initialInputResponder()
                    : nil
            )
        }
        presenter.currentTab = { [weak self] in
            guard let self,
                  case .expanded(let tab) = self.state
            else { return nil }
            return tab
        }
        return presenter
    }

    func reconcileWindowLevel(entries: [WindowStackEntry]) {
        guard panel.windowNumber > 0 else { return }
        let panelWindowNumber = CGWindowID(panel.windowNumber)
        let intersects = nativeActivityStackIntersectsPanel(
            entries: entries,
            panelWindowNumber: panelWindowNumber
        )
        let targetLevel = intersects
            ? panelNativeActivityWindowLevel
            : panelDefaultWindowLevel
        let levelChanged = panel.level.rawValue != targetLevel.rawValue
        if levelChanged {
            panel.level = targetLevel
        }
        if panel.isVisible,
           levelChanged || nativeActivityStackOccludesPanel(
               entries: entries,
               panelWindowNumber: panelWindowNumber
           )
        {
            panel.orderFrontRegardless()
        }
    }

    func setAnimationInProgressForSelfTest(_ value: Bool) {
        isAnimating = value
    }

    func completeAnimationForSelfTest() {
        applyFrame(for: state == .hidden ? .capsule : state)
        isAnimating = false
        panel.alphaValue = 1
        if case .expanded = state {
            rememberedExpandedSize = panel.frame.size
        }
        panel.invalidateShadow()
    }

    func visibleFrameForSelfTest() -> NSRect {
        selectedVisibleFrame
    }

    func rootControllerForSelfTest() -> DynamicIslandRootViewController {
        rootController
    }

    func selectedTaskKeyForSelfTest() -> String? {
        selectedTaskKey
    }

    func handleEscapeForSelfTest() {
        collapse()
    }

    func handleOutsideClickForSelfTest() {
        collapse()
    }

    func performOpenSelectedTaskForSelfTest() {
        rootController.performOpenSelectedTaskForSelfTest()
    }

    func copyWorkingDirectoryForSelfTest(_ path: String) -> Bool {
        copyWorkingDirectory(path)
    }

    func installConfirmationViewForSelfTest(
        _ controller: DynamicIslandConfirmationViewController
    ) {
        installConfirmationViewController(controller)
    }

    private var selectedVisibleFrame: NSRect {
        if let screen = dynamicIslandScreen(displayID: targetDisplayID) {
            return screen.visibleFrame
        }
        if let main = NSScreen.main ?? NSScreen.screens.first {
            targetDisplayID = dynamicIslandDisplayID(for: main)
            return main.visibleFrame
        }
        return NSRect(x: 0, y: 0, width: 1_024, height: 768)
    }

    private func applyFrame(for targetState: DynamicIslandPresentationState) {
        applyResizePolicy(for: targetState)
        let frame = dynamicIslandFrame(
            size: requestedWindowSize(for: targetState),
            visibleFrame: selectedVisibleFrame
        )
        panel.setFrame(frame, display: true)
        lockCapsuleSizeIfNeeded(for: targetState)
        panel.invalidateShadow()
    }

    private func requestedWindowSize(
        for targetState: DynamicIslandPresentationState
    ) -> NSSize {
        switch targetState {
        case .hidden, .capsule:
            return dynamicIslandCapsuleSize
        case .expanded:
            return dynamicIslandPreferredExpandedSize(
                visibleFrame: selectedVisibleFrame,
                remembered: rememberedExpandedSize
            )
        }
    }

    private func applyResizePolicy(
        for targetState: DynamicIslandPresentationState
    ) {
        switch targetState {
        case .expanded:
            panel.styleMask.insert(.resizable)
            panel.minSize = dynamicIslandExpandedMinSize
            panel.maxSize = dynamicIslandExpandedMaxSize
        case .hidden, .capsule:
            panel.styleMask.remove(.resizable)
            panel.minSize = dynamicIslandCapsuleSize
            panel.maxSize = dynamicIslandExpandedMaxSize
        }
    }

    private func lockCapsuleSizeIfNeeded(
        for targetState: DynamicIslandPresentationState
    ) {
        switch targetState {
        case .hidden, .capsule:
            panel.minSize = dynamicIslandCapsuleSize
            panel.maxSize = dynamicIslandCapsuleSize
        case .expanded:
            break
        }
    }

    private func expandedWindowDidResize() {
        guard !isAnimating, case .expanded = state else { return }
        rememberedExpandedSize = panel.frame.size
        panel.invalidateShadow()
    }

    private func capsuleDragEnded(at globalPoint: NSPoint) {
        guard state == .capsule else { return }
        if let screen = dynamicIslandScreenContaining(point: globalPoint) {
            targetDisplayID = dynamicIslandDisplayID(for: screen)
        }
        applyFrame(for: .capsule)
        panel.orderFrontRegardless()
    }

    private func releaseKeyFocus() {
        _ = panel.makeFirstResponder(nil)
        if panel.isKeyWindow {
            panel.resignKey()
        }
    }

    private func transition(
        to targetState: DynamicIslandPresentationState,
        duration: TimeInterval
    ) {
        let targetFrame = dynamicIslandFrame(
            size: requestedWindowSize(for: targetState),
            visibleFrame: selectedVisibleFrame
        )
        applyResizePolicy(for: targetState)
        animationGeneration += 1
        let generation = animationGeneration
        let reduceMotion =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let resolvedDuration: TimeInterval
        if duration == 0 {
            resolvedDuration = 0
        } else {
            resolvedDuration = reduceMotion ? 0.10 : duration
        }
        isAnimating = resolvedDuration > 0

        guard resolvedDuration > 0 else {
            panel.alphaValue = 1
            panel.setFrame(targetFrame, display: true)
            lockCapsuleSizeIfNeeded(for: targetState)
            panel.invalidateShadow()
            return
        }

        if reduceMotion {
            panel.setFrame(targetFrame, display: true)
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = resolvedDuration
                panel.animator().alphaValue = 1
            } completionHandler: { [weak self] in
                self?.finishAnimation(generation: generation)
            }
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = resolvedDuration
                panel.animator().setFrame(targetFrame, display: true)
            } completionHandler: { [weak self] in
                self?.finishAnimation(generation: generation)
            }
        }
    }

    private func finishAnimation(generation: Int) {
        guard generation == animationGeneration else { return }
        isAnimating = false
        panel.alphaValue = 1
        if case .expanded = state {
            rememberedExpandedSize = panel.frame.size
        }
        lockCapsuleSizeIfNeeded(for: state)
        panel.invalidateShadow()
    }

    private func installInteractionMonitors() {
        guard localMonitor == nil, globalMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                collapse()
                return nil
            }
            if event.type == .leftMouseDown,
               panel.frame.contains(NSEvent.mouseLocation) == false
            {
                collapse()
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { [weak self] _ in
            guard let self,
                  panel.frame.contains(NSEvent.mouseLocation) == false
            else { return }
            collapse()
        }
    }

    private func removeInteractionMonitors() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    private func copyWorkingDirectory(_ path: String) -> Bool {
        if let onCopyWorkingDirectory {
            return onCopyWorkingDirectory(path)
        }
        guard let normalizedPath = normalizedAbsolutePath(path) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([normalizedPath as NSString])
    }

    private func applySnapshotToRoot(
        state targetState: DynamicIslandPresentationState? = nil
    ) {
        suppressSelectedTaskAcknowledgement = true
        rootController.apply(
            snapshot: currentSnapshot,
            state: targetState ?? state
        )
        suppressSelectedTaskAcknowledgement = false
    }

    private func selectedTaskKeyDidChange(_ key: String?) {
        selectedTaskKey = key
        guard !suppressSelectedTaskAcknowledgement,
              case .expanded(.tasks) = state
        else { return }
        acknowledgeTaskDetailIfNeeded(tab: .tasks, selectedTaskKey: key)
    }

    private func acknowledgeTaskDetailIfNeeded(
        tab: DynamicIslandTab,
        selectedTaskKey: String?
    ) {
        guard tab == .tasks,
              let selectedTaskKey,
              let item = currentSnapshot.taskCollection.items.first(where: {
                  $0.identityKey == selectedTaskKey
              })
        else { return }
        onTaskDetailOpened?(item)
    }
}
