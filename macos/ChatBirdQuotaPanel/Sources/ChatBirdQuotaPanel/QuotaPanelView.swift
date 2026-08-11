//
//  QuotaPanelView.swift
//  ChatBirdQuotaPanel
//
//  模块职责：额度面板主视图——状态属性、事件处理（追踪区域/鼠标/
//  滚轮/光标）、任务符号视图同步与面板几何布局计算。自定义绘制逻辑
//  位于 QuotaPanelViewDrawing.swift 的扩展中。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

struct QuotaPanelModeSwitchSnapshot: Equatable {
    let buttonFrame: NSRect
    let hideButtonFrame: NSRect
    let title: String
    let toolTip: String?
    let accessibilityLabel: String?
    let accessibilityHelp: String?
}

private final class QuotaPanelModeSwitchButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

final class QuotaPanelView: NSView {
    var currentDateProvider: () -> Date = { Date() } {
        didSet { needsDisplay = true }
    }
    var rows: [QuotaRow] = [] { didSet { needsDisplay = true } }
    var providerRemainingPercents: [QuotaProvider: Int] = [:] {
        didSet { needsDisplay = true }
    }
    var availableQuotaProviders = QuotaProvider.allCases {
        didSet {
            guard availableQuotaProviders != oldValue else { return }
            if let hoveredQuotaProvider,
               !availableQuotaProviders.contains(hoveredQuotaProvider) {
                self.hoveredQuotaProvider = nil
            }
            needsDisplay = true
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
        }
    }
    var codexResetCredits: CodexResetCreditsSnapshot? {
        didSet { needsDisplay = true }
    }
    var selectedQuotaProvider: QuotaProvider = .codex {
        didSet {
            guard selectedQuotaProvider != oldValue else { return }
            needsDisplay = true
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
        }
    }
    var statusText = "正在读取额度…" { didSet { needsDisplay = true } }
    var errorText: String? { didSet { needsDisplay = true } }
    var isQuotaRefreshing = false {
        didSet {
            guard isQuotaRefreshing != oldValue else { return }
            refreshAnimationTimerState()
            needsDisplay = true
        }
    }
    var taskProgress = TaskProgressSnapshot.reading {
        didSet {
            clampTaskScrollOffset()
            if taskProgress != oldValue {
                needsDisplay = true
                syncTaskSymbolViews()
                updateTrackingAreas()
                window?.invalidateCursorRects(for: self)
                reconcileTaskHover()
            }
        }
    }
    var pointerSide: PointerSide = .left {
        didSet {
            guard pointerSide != oldValue else { return }
            needsDisplay = true
            needsLayout = true
            syncTaskSymbolViews()
            window?.invalidateCursorRects(for: self)
        }
    }
    var pointerCenterX: CGFloat? {
        didSet {
            guard pointerCenterX != oldValue else { return }
            needsDisplay = true
        }
    }
    var onRequestHide: (() -> Void)?
    var onRequestDynamicIsland: (() -> Void)?
    var onOpenTask: ((TaskProgressItem) -> Void)?
    var onRequestQuotaRefresh: (() -> Void)?
    var onSelectQuotaProvider: ((QuotaProvider) -> Void)?
    var onHoverRunningTask: ((TaskProgressItem?, NSRect?) -> Void)?
    private var interactiveTrackingAreas: [NSTrackingArea] = []
    private var isHideButtonHovered = false
    private var isModeSwitchButtonHovered = false
    private let modeSwitchButton = QuotaPanelModeSwitchButton(
        title: "",
        target: nil,
        action: nil
    )
    // 以下四个状态会被 QuotaPanelViewDrawing.swift 的绘制扩展读取，保持 internal。
    var hoveredQuotaProvider: QuotaProvider?
    var hoveredTaskIndex: Int?
    private var hoveredTaskKey: String?
    var taskScrollOffset = 0
    private var taskSymbolViews: [NSImageView] = []
    private var taskAnimationsEnabled = false
    private var animationTimer: Timer?
    var animationDegrees: CGFloat = 0
    private static let trackingKindKey = "tracking-kind"
    private static let trackingIndexKey = "tracking-index"
    private static let trackingProviderKey = "tracking-provider"

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureModeSwitchButton()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureModeSwitchButton()
    }

    deinit {
        animationTimer?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncTaskSymbolViews()
    }

    override func layout() {
        super.layout()
        modeSwitchButton.frame = modeSwitchButtonRect(in: panelBodyRect())
    }

    func setRunningTaskBadgeAnimationsEnabled(_ enabled: Bool) {
        guard taskAnimationsEnabled != enabled else { return }
        taskAnimationsEnabled = enabled
        refreshAnimationTimerState()
    }

    func applyDashboardSnapshot(_ snapshot: ActivityDashboardSnapshot) {
        let provider = snapshot.selectedQuotaProvider
        let quota = snapshot.quotaStates[provider] ?? QuotaProviderState()
        availableQuotaProviders = snapshot.availableProviders
        selectedQuotaProvider = provider
        rows = quota.rows
        codexResetCredits = snapshot.quotaStates[.codex]?.resetCredits
        statusText = quota.statusText
        errorText = quota.errorText
        isQuotaRefreshing = quota.isRefreshing
        taskProgress = snapshot.taskCollection.compactProjection()
        providerRemainingPercents = quotaProviderRemainingPercents(
            from: snapshot.quotaStates
        )
    }

    func scrollTaskList(by rowDelta: Int) {
        guard taskProgress.isScrollable, rowDelta != 0 else { return }
        let maximumOffset = max(
            0,
            taskProgress.items.count - maximumVisibleTaskRows
        )
        let nextOffset = max(
            0,
            min(maximumOffset, taskScrollOffset + rowDelta)
        )
        guard nextOffset != taskScrollOffset else { return }
        taskScrollOffset = nextOffset
        updateTaskHover(index: nil)
        needsDisplay = true
        syncTaskSymbolViews()
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard taskListRect(in: panelBodyRect()).contains(point),
              taskProgress.isScrollable
        else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        scrollTaskList(by: delta < 0 ? 1 : -1)
    }

    private func clampTaskScrollOffset() {
        guard taskProgress.isScrollable else {
            taskScrollOffset = 0
            return
        }
        taskScrollOffset = min(
            taskScrollOffset,
            max(0, taskProgress.items.count - maximumVisibleTaskRows)
        )
    }

    func updateTaskHover(index: Int?) {
        guard let index, displayedTaskItems.indices.contains(index) else {
            hoveredTaskIndex = nil
            hoveredTaskKey = nil
            onHoverRunningTask?(nil, nil)
            needsDisplay = true
            return
        }

        let item = displayedTaskItems[index]
        hoveredTaskIndex = index
        hoveredTaskKey = item.identityKey
        if item.kind == .running, let anchorRect = taskRowScreenRect(index: index) {
            onHoverRunningTask?(item, anchorRect)
        } else {
            onHoverRunningTask?(nil, nil)
        }
        needsDisplay = true
    }

    func refreshHoveredTaskAnchor() {
        reconcileTaskHover()
    }

    private func reconcileTaskHover() {
        guard let hoveredTaskKey else { return }
        guard let index = displayedTaskItems.firstIndex(where: {
            $0.identityKey == hoveredTaskKey
        }) else {
            updateTaskHover(index: nil)
            return
        }
        updateTaskHover(index: index)
    }

    private func taskRowScreenRect(index: Int) -> NSRect? {
        guard let window else { return nil }
        let rowRect = taskRowRect(index: index, in: panelBodyRect())
        return window.convertToScreen(convert(rowRect, to: nil))
    }

    private func refreshAnimationTimerState() {
        let hasVisibleRunningTask = displayedTaskItems.contains {
            $0.kind == .running
        }
        let shouldAnimate = isQuotaRefreshing
            || (taskAnimationsEnabled && hasVisibleRunningTask)
        if shouldAnimate {
            guard animationTimer == nil else { return }
            let timer = Timer(
                timeInterval: 1.0 / taskAnimationFramesPerSecond,
                repeats: true
            ) {
                [weak self] _ in
                guard let self else { return }
                self.animationDegrees = (
                    self.animationDegrees + taskAnimationDegreesPerTick
                )
                    .truncatingRemainder(dividingBy: 360)
                for (index, imageView) in self.taskSymbolViews.enumerated() {
                    let item = self.displayedTaskItems[index]
                    imageView.frameCenterRotation = item.kind == .running
                        ? self.animationDegrees
                        : 0
                }
                if self.isQuotaRefreshing {
                    self.needsDisplay = true
                }
            }
            animationTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else {
            animationTimer?.invalidate()
            animationTimer = nil
            animationDegrees = 0
            for imageView in taskSymbolViews {
                imageView.frameCenterRotation = 0
            }
        }
    }

    private func syncTaskSymbolViews() {
        for imageView in taskSymbolViews {
            imageView.removeFromSuperview()
        }
        taskSymbolViews.removeAll(keepingCapacity: true)

        let taskItems = displayedTaskItems
        let bodyRect = panelBodyRect()
        for (index, item) in taskItems.enumerated() {
            let rowRect = taskRowRect(index: index, in: bodyRect)
            let imageView = NSImageView(frame: NSRect(
                x: rowRect.minX + 7,
                y: rowRect.minY + 5.5,
                width: 15,
                height: 15
            ))
            imageView.image = NSImage(
                systemSymbolName: taskProgressSymbolName(for: item.kind),
                accessibilityDescription: item.statusText
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            )
            imageView.contentTintColor = taskProgressColor(for: item.kind)
            imageView.imageAlignment = .alignCenter
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.imageFrameStyle = .none
            imageView.isEditable = false
            addSubview(imageView)
            taskSymbolViews.append(imageView)
        }
        refreshAnimationTimerState()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.current?.imageInterpolation = .high

        let bodyRect = panelBodyRect()

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()

        let background = NSColor(calibratedRed: 0.035, green: 0.09, blue: 0.16, alpha: 0.96)
        let border = NSColor(calibratedRed: 0.47, green: 0.86, blue: 1.0, alpha: 0.24)
        let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 17, yRadius: 17)
        if let gradient = NSGradient(
            starting: NSColor(calibratedRed: 0.055, green: 0.15, blue: 0.26, alpha: 0.96),
            ending: NSColor(calibratedRed: 0.025, green: 0.075, blue: 0.14, alpha: 0.98)
        ) {
            gradient.draw(in: bodyPath, angle: -90)
        } else {
            background.setFill()
            bodyPath.fill()
        }

        border.setStroke()
        bodyPath.lineWidth = 1
        bodyPath.stroke()

        let arrow = NSBezierPath()
        switch pointerSide {
        case .left:
            let centerY = bodyRect.midY
            arrow.move(to: NSPoint(x: bodyRect.minX + 1, y: centerY - 8))
            arrow.line(to: NSPoint(x: 1, y: centerY))
            arrow.line(to: NSPoint(x: bodyRect.minX + 1, y: centerY + 8))
        case .right:
            let centerY = bodyRect.midY
            arrow.move(to: NSPoint(x: bodyRect.maxX - 1, y: centerY - 8))
            arrow.line(to: NSPoint(x: bounds.maxX - 1, y: centerY))
            arrow.line(to: NSPoint(x: bodyRect.maxX - 1, y: centerY + 8))
        case .bottom:
            let requestedCenterX = pointerCenterX ?? bodyRect.midX
            let centerX = min(
                max(requestedCenterX, bodyRect.minX + 12),
                bodyRect.maxX - 12
            )
            arrow.move(to: NSPoint(x: centerX - 8, y: bodyRect.maxY - 1))
            arrow.line(to: NSPoint(x: centerX, y: bounds.maxY - 1))
            arrow.line(to: NSPoint(x: centerX + 8, y: bodyRect.maxY - 1))
        }
        arrow.close()
        background.setFill()
        arrow.fill()
        border.setStroke()
        arrow.lineWidth = 1
        arrow.stroke()

        NSShadow().set()

        drawQuotaProviderButtons(in: bodyRect)
        let modeSwitchButton = modeSwitchButtonRect(in: bodyRect)
        let modeSwitchButtonPath = NSBezierPath(
            roundedRect: modeSwitchButton,
            xRadius: 8,
            yRadius: 8
        )
        NSColor(
            calibratedRed: 0.20,
            green: 0.68,
            blue: 1.0,
            alpha: isModeSwitchButtonHovered ? 0.24 : 0.13
        ).setFill()
        modeSwitchButtonPath.fill()
        NSColor(
            calibratedRed: 0.42,
            green: 0.82,
            blue: 1.0,
            alpha: isModeSwitchButtonHovered ? 0.72 : 0.42
        ).setStroke()
        modeSwitchButtonPath.lineWidth = 0.75
        modeSwitchButtonPath.stroke()
        drawText(
            "灵动岛",
            in: NSRect(
                x: modeSwitchButton.minX,
                y: modeSwitchButton.minY + 2,
                width: modeSwitchButton.width,
                height: 15
            ),
            font: .systemFont(ofSize: 9.5, weight: .semibold),
            color: NSColor.white.withAlphaComponent(
                isModeSwitchButtonHovered ? 1.0 : 0.92
            ),
            alignment: .center
        )

        let hideButton = hideButtonRect(in: bodyRect)
        let hideButtonPath = NSBezierPath(roundedRect: hideButton, xRadius: 8, yRadius: 8)
        NSColor.white.withAlphaComponent(isHideButtonHovered ? 0.20 : 0.11).setFill()
        hideButtonPath.fill()
        NSColor.white.withAlphaComponent(isHideButtonHovered ? 0.38 : 0.20).setStroke()
        hideButtonPath.lineWidth = 0.75
        hideButtonPath.stroke()
        drawText(
            "收起",
            in: NSRect(x: hideButton.minX, y: hideButton.minY + 2, width: hideButton.width, height: 15),
            font: .systemFont(ofSize: 9.5, weight: .medium),
            color: NSColor.white.withAlphaComponent(isHideButtonHovered ? 1.0 : 0.86),
            alignment: .center
        )

        let quotaRect = quotaColumnRect(in: bodyRect)
        let taskRect = taskListRect(in: bodyRect)
        let dividerX = taskRect.minX - 11
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: dividerX, y: 39))
        divider.line(to: NSPoint(x: dividerX, y: bodyRect.maxY - 13))
        NSColor.white.withAlphaComponent(0.13).setStroke()
        divider.lineWidth = 0.75
        divider.stroke()

        if let errorText {
            drawText(
                errorText,
                in: NSRect(x: quotaRect.minX, y: 82, width: quotaRect.width, height: 34),
                font: .systemFont(ofSize: 10.5, weight: .medium),
                color: NSColor(calibratedRed: 1.0, green: 0.48, blue: 0.43, alpha: 1),
                alignment: .center
            )
        } else if rows.isEmpty {
            drawText(
                selectedQuotaProvider == .codex
                    ? "正在读取周额度…"
                    : "正在读取 Claude 额度…",
                in: NSRect(x: quotaRect.minX, y: 85, width: quotaRect.width, height: 20),
                font: .systemFont(ofSize: 11, weight: .medium),
                color: NSColor.white.withAlphaComponent(0.68),
                alignment: .center
            )
        } else if selectedQuotaProvider == .claudeCode || rows.count > 1 {
            drawCompactQuotaRows(Array(rows.prefix(3)), x: quotaRect.minX, width: quotaRect.width)
        } else {
            for row in rows.prefix(1) {
                drawArcQuotaRow(row, x: quotaRect.minX, width: quotaRect.width)
            }
        }

        drawText(
            statusText,
            in: NSRect(
                x: quotaRect.minX,
                y: 188,
                width: quotaRect.width - 17,
                height: 14
            ),
            font: .systemFont(ofSize: 8.4, weight: .regular),
            color: NSColor.white.withAlphaComponent(0.48),
            alignment: .center
        )
        drawRefreshIcon(in: quotaRefreshButtonRect(in: bodyRect))

        drawText(
            availableQuotaProviders.contains(.claudeCode)
                ? "Codex + Claude 任务"
                : "Codex 任务",
            in: NSRect(x: taskRect.minX + 2, y: 42, width: taskRect.width - 4, height: 16),
            font: .systemFont(ofSize: 10.2, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.58)
        )
        let taskItems = displayedTaskItems
        for (index, item) in taskItems.enumerated() {
            drawTaskProgressItem(item, index: index, rect: taskRowRect(index: index, in: bodyRect))
        }
        drawTaskScrollbar(in: bodyRect)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for trackingArea in interactiveTrackingAreas {
            removeTrackingArea(trackingArea)
        }
        interactiveTrackingAreas.removeAll(keepingCapacity: true)

        let hideTrackingArea = NSTrackingArea(
            rect: hideButtonRect(in: panelBodyRect()),
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: [Self.trackingKindKey: "hide"]
        )
        addTrackingArea(hideTrackingArea)
        interactiveTrackingAreas.append(hideTrackingArea)

        let modeSwitchTrackingArea = NSTrackingArea(
            rect: modeSwitchButtonRect(in: panelBodyRect()),
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: [Self.trackingKindKey: "mode-switch"]
        )
        addTrackingArea(modeSwitchTrackingArea)
        interactiveTrackingAreas.append(modeSwitchTrackingArea)

        for provider in availableQuotaProviders {
            let providerTrackingArea = NSTrackingArea(
                rect: quotaProviderButtonRect(for: provider, in: panelBodyRect()),
                options: [.mouseEnteredAndExited, .activeAlways],
                owner: self,
                userInfo: [
                    Self.trackingKindKey: "quota-provider",
                    Self.trackingProviderKey: provider.rawValue,
                ]
            )
            addTrackingArea(providerTrackingArea)
            interactiveTrackingAreas.append(providerTrackingArea)
        }

        let items = displayedTaskItems
        for (index, _) in items.enumerated() {
            let trackingArea = NSTrackingArea(
                rect: taskRowRect(index: index, in: panelBodyRect()),
                options: [.mouseEnteredAndExited, .activeAlways],
                owner: self,
                userInfo: [
                    Self.trackingKindKey: "task",
                    Self.trackingIndexKey: index,
                ]
            )
            addTrackingArea(trackingArea)
            interactiveTrackingAreas.append(trackingArea)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard let kind = event.trackingArea?.userInfo?[Self.trackingKindKey] as? String
        else { return }
        if kind == "hide" {
            isHideButtonHovered = true
        } else if kind == "mode-switch" {
            isModeSwitchButtonHovered = true
        } else if kind == "quota-provider" {
            hoveredQuotaProvider = (
                event.trackingArea?.userInfo?[Self.trackingProviderKey] as? String
            ).flatMap(QuotaProvider.init(rawValue:))
        } else if kind == "task" {
            updateTaskHover(
                index: event.trackingArea?.userInfo?[Self.trackingIndexKey] as? Int
            )
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard let kind = event.trackingArea?.userInfo?[Self.trackingKindKey] as? String
        else { return }
        if kind == "hide" {
            isHideButtonHovered = false
        } else if kind == "mode-switch" {
            isModeSwitchButtonHovered = false
        } else if kind == "quota-provider" {
            if hoveredQuotaProvider?.rawValue
                == event.trackingArea?.userInfo?[Self.trackingProviderKey] as? String
            {
                hoveredQuotaProvider = nil
            }
        } else if kind == "task",
                  hoveredTaskIndex
                    == event.trackingArea?.userInfo?[Self.trackingIndexKey] as? Int
        {
            updateTaskHover(index: nil)
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let bodyRect = panelBodyRect()
        if hideButtonRect(in: bodyRect).contains(point) {
            onRequestHide?()
            return
        }
        if modeSwitchButtonRect(in: bodyRect).contains(point) {
            onRequestDynamicIsland?()
            return
        }
        if quotaRefreshButtonRect(in: bodyRect).contains(point) {
            onRequestQuotaRefresh?()
            return
        }
        for provider in availableQuotaProviders
            where quotaProviderButtonRect(for: provider, in: bodyRect).contains(point)
        {
            onSelectQuotaProvider?(provider)
            return
        }
        for (index, item) in displayedTaskItems.enumerated()
            where taskRowRect(index: index, in: bodyRect).contains(point)
        {
            if item.canOpen {
                onOpenTask?(item)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let bodyRect = panelBodyRect()
        addCursorRect(hideButtonRect(in: bodyRect), cursor: .pointingHand)
        addCursorRect(modeSwitchButtonRect(in: bodyRect), cursor: .pointingHand)
        for provider in availableQuotaProviders {
            addCursorRect(
                quotaProviderButtonRect(for: provider, in: bodyRect),
                cursor: .pointingHand
            )
        }
        addCursorRect(quotaRefreshButtonRect(in: bodyRect), cursor: .pointingHand)
        for (index, item) in displayedTaskItems.enumerated() where item.canOpen {
            addCursorRect(taskRowRect(index: index, in: bodyRect), cursor: .pointingHand)
        }
    }

    private var displayedTaskItems: [TaskProgressItem] {
        let items = taskProgress.items.isEmpty
            ? TaskProgressSnapshot.idle.items
            : taskProgress.items
        guard taskProgress.isScrollable else { return items }
        let end = min(
            items.count,
            taskScrollOffset + maximumVisibleTaskRows
        )
        guard taskScrollOffset < end else { return [] }
        return Array(items[taskScrollOffset..<end])
    }

    private func panelBodyRect() -> NSRect {
        let arrowWidth: CGFloat = 10
        switch pointerSide {
        case .left:
            return NSRect(x: arrowWidth, y: 3, width: bounds.width - arrowWidth, height: bounds.height - 6)
        case .right:
            return NSRect(x: 0, y: 3, width: bounds.width - arrowWidth, height: bounds.height - 6)
        case .bottom:
            return NSRect(x: 3, y: 3, width: bounds.width - 6, height: bounds.height - arrowWidth - 3)
        }
    }

    private func quotaColumnRect(in bodyRect: NSRect) -> NSRect {
        NSRect(
            x: bodyRect.minX + 14,
            y: 38,
            width: 140,
            height: bodyRect.height - 51
        )
    }

    // 以下两个几何方法会被绘制扩展使用，保持 internal。
    func taskListRect(in bodyRect: NSRect) -> NSRect {
        let x = bodyRect.minX + 178
        return NSRect(
            x: x,
            y: 38,
            width: bodyRect.maxX - 14 - x,
            height: bodyRect.height - 51
        )
    }

    private func taskRowRect(index: Int, in bodyRect: NSRect) -> NSRect {
        let listRect = taskListRect(in: bodyRect)
        return NSRect(
            x: listRect.minX,
            y: 61 + CGFloat(index) * taskProgressRowHeight,
            width: listRect.width,
            height: 26
        )
    }

    private func hideButtonRect(in bodyRect: NSRect) -> NSRect {
        NSRect(x: bodyRect.maxX - 48, y: 10, width: 38, height: 18)
    }

    private func modeSwitchButtonRect(in bodyRect: NSRect) -> NSRect {
        NSRect(x: bodyRect.maxX - 116, y: 10, width: 60, height: 18)
    }

    func modeSwitchSnapshotForSelfTest() -> QuotaPanelModeSwitchSnapshot {
        needsLayout = true
        layoutSubtreeIfNeeded()
        let bodyRect = panelBodyRect()
        return QuotaPanelModeSwitchSnapshot(
            buttonFrame: modeSwitchButton.frame,
            hideButtonFrame: hideButtonRect(in: bodyRect),
            title: "灵动岛",
            toolTip: modeSwitchButton.toolTip,
            accessibilityLabel:
                modeSwitchButton.accessibilityLabel() as? String,
            accessibilityHelp:
                modeSwitchButton.accessibilityHelp() as? String
        )
    }

    func performModeSwitchForSelfTest() {
        modeSwitchButton.performClick(nil)
    }

    private func configureModeSwitchButton() {
        modeSwitchButton.isBordered = false
        modeSwitchButton.isTransparent = true
        modeSwitchButton.focusRingType = .none
        modeSwitchButton.target = self
        modeSwitchButton.action = #selector(requestDynamicIsland)
        modeSwitchButton.setAccessibilityRole(.button)
        modeSwitchButton.setAccessibilityLabel("切换到灵动岛")
        modeSwitchButton.setAccessibilityHelp(
            "关闭宠物面板并显示灵动岛胶囊"
        )
        modeSwitchButton.toolTip = "切换到灵动岛"
        addSubview(modeSwitchButton)
    }

    @objc private func requestDynamicIsland() {
        onRequestDynamicIsland?()
    }

    func quotaProviderButtonRect(
        for provider: QuotaProvider,
        in bodyRect: NSRect
    ) -> NSRect {
        switch provider {
        case .codex:
            return NSRect(x: bodyRect.minX + 11, y: 8, width: 94, height: 23)
        case .claudeCode:
            return NSRect(x: bodyRect.minX + 115, y: 8, width: 104, height: 23)
        }
    }

    private func quotaRefreshButtonRect(in bodyRect: NSRect) -> NSRect {
        let quotaRect = quotaColumnRect(in: bodyRect)
        return NSRect(
            x: quotaRect.maxX - 18,
            y: 185,
            width: 18,
            height: 18
        )
    }
}
