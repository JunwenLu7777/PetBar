import AppKit
import Foundation

var dynamicIslandCurrentDate: () -> Date = Date.init

enum DynamicIslandProgressStyle: Equatable {
    case indeterminate
    case waiting
    case completed
    case failed
    case idle
}

struct DynamicIslandCapsulePresentation: Equatable {
    let title: String
    let statusText: String
    let activityText: String?
    let elapsedText: String?
    let providerText: String?
    let badgeText: String?
    let progressStyle: DynamicIslandProgressStyle
    let preferredTab: DynamicIslandTab
    let selectedTaskKey: String?
    let accessibilityValue: String
}

struct DynamicIslandCapsuleLayoutSnapshot: Equatable {
    let bounds: NSRect
    let statusDotFrame: NSRect
    let statusFrame: NSRect
    let titleFrame: NSRect
    let elapsedFrame: NSRect
    let chevronFrame: NSRect
    let hitTargetFrame: NSRect
    let modeSwitchFrame: NSRect
    let labelCount: Int
    let buttonCount: Int
    let hasVisibleButtonTitle: Bool
    let modeSwitchIsFrontmost: Bool
    let hitTargetToolTip: String?
    let hitTargetAccessibilityHelp: String?
    let modeSwitchTitle: String
    let modeSwitchToolTip: String?
    let modeSwitchAccessibilityLabel: String?
}

enum DynamicIslandPalette {
    static let background = NSColor(calibratedWhite: 0.055, alpha: 0.98)
    static let surface = NSColor(calibratedWhite: 0.075, alpha: 0.98)
    static let raised = NSColor(calibratedWhite: 0.105, alpha: 0.98)
    static let card = NSColor(calibratedWhite: 0.135, alpha: 0.98)
    static let cardHover = NSColor(calibratedWhite: 0.165, alpha: 0.98)
    static let hairline = NSColor.white.withAlphaComponent(0.12)
    static let strongHairline = NSColor.white.withAlphaComponent(0.20)
    static let primaryText = NSColor.white.withAlphaComponent(0.94)
    static let secondaryText = NSColor.white.withAlphaComponent(0.62)
    static let tertiaryText = NSColor.white.withAlphaComponent(0.42)
    static let green = NSColor(
        calibratedRed: 0.40,
        green: 0.83,
        blue: 0.08,
        alpha: 1
    )
    static let amber = NSColor(
        calibratedRed: 1.00,
        green: 0.67,
        blue: 0.08,
        alpha: 1
    )
    static let red = NSColor(
        calibratedRed: 1.00,
        green: 0.31,
        blue: 0.29,
        alpha: 1
    )

    static var isIndependentForSelfTest: Bool {
        func components(_ color: NSColor) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
            guard let converted = color.usingColorSpace(.deviceRGB) else {
                return nil
            }
            return (
                converted.redComponent,
                converted.greenComponent,
                converted.blueComponent
            )
        }
        guard let background = components(background),
              let raised = components(raised),
              let green = components(green),
              let amber = components(amber),
              let red = components(red)
        else { return false }
        let neutralSurfaces = background.blue < 0.14
            && raised.blue < 0.18
            && abs(background.red - background.green) < 0.02
            && abs(background.green - background.blue) < 0.02
        let statusColorsAreDistinct = green.green > green.red
            && green.green > green.blue
            && amber.red > amber.blue
            && amber.green > amber.blue
            && red.red > red.green
            && red.red > red.blue
        return neutralSurfaces && statusColorsAreDistinct
    }
}

enum DynamicIslandButtonStyle {
    case secondary
    case primary
    case destructive
    case subtle
    case icon
}

final class DynamicIslandCardView: NSView {
    private let accentView = NSView()
    private(set) var accentColor: NSColor?

    init(
        cornerRadius: CGFloat = 10,
        backgroundColor: NSColor = DynamicIslandPalette.raised,
        borderColor: NSColor = DynamicIslandPalette.hairline,
        accentColor: NSColor? = nil
    ) {
        self.accentColor = accentColor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.backgroundColor = backgroundColor.cgColor
        layer?.borderColor = borderColor.cgColor
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        accentView.wantsLayer = true
        addSubview(accentView)
        setAccentColor(accentColor)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        accentView.frame = NSRect(x: 0, y: 0, width: 3, height: bounds.height)
    }

    func setAccentColor(_ color: NSColor?) {
        accentColor = color
        accentView.isHidden = color == nil
        accentView.layer?.backgroundColor = color?.cgColor
    }

    func setSurface(
        backgroundColor: NSColor,
        borderColor: NSColor = DynamicIslandPalette.hairline,
        borderWidth: CGFloat = 1
    ) {
        layer?.backgroundColor = backgroundColor.cgColor
        layer?.borderColor = borderColor.cgColor
        layer?.borderWidth = borderWidth
    }
}

final class DynamicIslandDividerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = DynamicIslandPalette.hairline.cgColor
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class DynamicIslandButton: NSButton {
    private(set) var visualStyle: DynamicIslandButtonStyle
    private var selectedAccent: NSColor?
    private var isVisuallySelected = false

    init(
        title: String,
        style: DynamicIslandButtonStyle = .secondary,
        imageName: String? = nil
    ) {
        visualStyle = style
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        font = .systemFont(ofSize: 12.5, weight: .medium)
        if let imageName {
            image = NSImage(
                systemSymbolName: imageName,
                accessibilityDescription: title.isEmpty ? nil : title
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            )
            imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            imageScaling = .scaleProportionallyDown
        }
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isEnabled: Bool {
        didSet { applyAppearance() }
    }

    func setDisplayTitle(_ value: String) {
        title = value
        applyAppearance()
    }

    func setVisualStyle(_ style: DynamicIslandButtonStyle) {
        visualStyle = style
        applyAppearance()
    }

    func setSelected(_ selected: Bool, accent: NSColor) {
        isVisuallySelected = selected
        selectedAccent = accent
        applyAppearance()
    }

    private func applyAppearance() {
        let foreground: NSColor
        let background: NSColor
        let border: NSColor
        if isVisuallySelected, let selectedAccent {
            foreground = DynamicIslandPalette.primaryText
            background = selectedAccent.withAlphaComponent(0.22)
            border = selectedAccent.withAlphaComponent(0.78)
        } else {
            switch visualStyle {
            case .primary:
                foreground = NSColor(calibratedWhite: 0.05, alpha: 1)
                background = DynamicIslandPalette.amber
                border = DynamicIslandPalette.amber
            case .destructive:
                foreground = DynamicIslandPalette.red
                background = DynamicIslandPalette.red.withAlphaComponent(0.08)
                border = DynamicIslandPalette.red.withAlphaComponent(0.78)
            case .subtle:
                foreground = DynamicIslandPalette.secondaryText
                background = NSColor.white.withAlphaComponent(0.025)
                border = DynamicIslandPalette.hairline
            case .icon:
                foreground = DynamicIslandPalette.primaryText
                background = DynamicIslandPalette.raised
                border = DynamicIslandPalette.strongHairline
            case .secondary:
                foreground = DynamicIslandPalette.primaryText
                background = DynamicIslandPalette.card
                border = DynamicIslandPalette.strongHairline
            }
        }
        let effectiveForeground = isEnabled
            ? foreground
            : foreground.withAlphaComponent(0.34)
        layer?.backgroundColor = background
            .withAlphaComponent(isEnabled ? background.alphaComponent : 0.45)
            .cgColor
        layer?.borderColor = border
            .withAlphaComponent(isEnabled ? border.alphaComponent : 0.35)
            .cgColor
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: effectiveForeground,
                .font: font ?? NSFont.systemFont(ofSize: 12.5, weight: .medium),
            ]
        )
        contentTintColor = effectiveForeground
    }
}

final class DynamicIslandSegmentedControl: NSView {
    var onSelectionChange: ((Int) -> Void)?
    private var buttons: [DynamicIslandButton] = []
    private var labels: [String]
    private var accentColors: [NSColor]
    private(set) var selectedSegment: Int = 0

    init(labels: [String]) {
        self.labels = labels
        accentColors = Array(repeating: DynamicIslandPalette.green, count: labels.count)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = DynamicIslandPalette.raised.cgColor
        layer?.borderColor = DynamicIslandPalette.hairline.cgColor
        layer?.borderWidth = 1
        rebuildButtons()
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        guard !buttons.isEmpty else { return }
        let spacing: CGFloat = 2
        let width = max(1, (bounds.width - spacing * CGFloat(buttons.count + 1)) / CGFloat(buttons.count))
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(
                x: spacing + CGFloat(index) * (width + spacing),
                y: 2,
                width: width,
                height: max(1, bounds.height - 4)
            )
        }
    }

    func setLabel(_ label: String, forSegment index: Int) {
        guard labels.indices.contains(index), buttons.indices.contains(index) else { return }
        labels[index] = label
        buttons[index].setDisplayTitle(label)
        setAccessibilityValue(labels.joined(separator: "，"))
    }

    func setAccentColor(_ color: NSColor, forSegment index: Int) {
        guard accentColors.indices.contains(index) else { return }
        accentColors[index] = color
        updateSelectionAppearance()
    }

    func selectSegment(_ index: Int, notify: Bool = false) {
        guard buttons.indices.contains(index) else { return }
        selectedSegment = index
        updateSelectionAppearance()
        setAccessibilityValue("当前 \(labels[index])；" + labels.joined(separator: "，"))
        if notify { onSelectionChange?(index) }
    }

    private func rebuildButtons() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = labels.enumerated().map { index, title in
            let button = DynamicIslandButton(title: title, style: .subtle)
            button.tag = index
            button.target = self
            button.action = #selector(segmentClicked(_:))
            addSubview(button)
            return button
        }
        updateSelectionAppearance()
    }

    private func updateSelectionAppearance() {
        for (index, button) in buttons.enumerated() {
            let accent = accentColors.indices.contains(index)
                ? accentColors[index]
                : DynamicIslandPalette.green
            button.setSelected(index == selectedSegment, accent: accent)
        }
    }

    @objc private func segmentClicked(_ sender: NSButton) {
        selectSegment(sender.tag, notify: true)
    }
}

func taskElapsedText(from startedAt: Date, to now: Date) -> String {
    let totalSeconds = max(0, Int(now.timeIntervalSince(startedAt)))
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let seconds = totalSeconds % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%02d:%02d", minutes, seconds)
}

func dynamicIslandSanitizedTaskActivityText(_ text: String?) -> String? {
    guard var sanitized = text?
        .trimmingCharacters(in: .whitespacesAndNewlines),
          !sanitized.isEmpty
    else { return nil }

    let fakeProgressPattern =
        #"(\d+\s*/\s*\d+|\d+(?:\.\d+)?\s*%|推断步骤|预计步骤|第\s*\d+\s*步|共\s*\d+\s*步|\bstep\s+\d+\s+of\s+\d+\b)"#
    let clauses = sanitized
        .components(separatedBy: CharacterSet(charactersIn: "，,；;。"))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { clause in
            !clause.isEmpty
                && clause.range(
                    of: fakeProgressPattern,
                    options: [.regularExpression, .caseInsensitive]
                ) == nil
        }
    sanitized = clauses.joined(separator: "，")

    let patterns = [
        #"推断步骤[^，。；;,\n]*"#,
        #"预计步骤[^，。；;,\n]*"#,
        #"第\s*\d+\s*步"#,
        #"共\s*\d+\s*步"#,
        #"\bstep\s+\d+\s+of\s+\d+\b"#,
        #"\d+\s*/\s*\d+"#,
        #"\d+(?:\.\d+)?\s*%"#,
    ]
    for pattern in patterns {
        sanitized = sanitized.replacingOccurrences(
            of: pattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }
    sanitized = sanitized.replacingOccurrences(
        of: #"\s*([，。；;,])\s*"#,
        with: "$1",
        options: .regularExpression
    )
    sanitized = sanitized.replacingOccurrences(
        of: #"^[，。；;,\s]+|[，。；;,\s]+$"#,
        with: "",
        options: .regularExpression
    )
    sanitized = sanitized.replacingOccurrences(
        of: #"\s{2,}"#,
        with: " ",
        options: .regularExpression
    )
    return sanitized.isEmpty ? nil : sanitized
}

func dynamicIslandCapsulePresentation(
    snapshot: ActivityDashboardSnapshot,
    now: Date = Date()
) -> DynamicIslandCapsulePresentation {
    func accessibility(
        title: String,
        status: String,
        activity: String?,
        elapsed: String?,
        provider: String?,
        badge: String?
    ) -> String {
        [title, status, activity, elapsed, provider, badge].compactMap { $0 }
            .joined(separator: "，")
    }

    func taskModel(
        _ item: TaskProgressItem,
        style: DynamicIslandProgressStyle
    ) -> DynamicIslandCapsulePresentation {
        let elapsed = taskElapsedText(from: item.startedAt, to: now)
        let provider = item.source == .codex ? "Codex" : "Claude Code"
        let activity = dynamicIslandSanitizedTaskActivityText(item.activityText)
        let status: String
        switch style {
        case .indeterminate: status = "执行中"
        case .waiting: status = "等待中"
        case .completed: status = "已完成"
        case .failed: status = "失败"
        case .idle: status = "空闲"
        }
        return DynamicIslandCapsulePresentation(
            title: item.title,
            statusText: status,
            activityText: activity,
            elapsedText: elapsed,
            providerText: provider,
            badgeText: nil,
            progressStyle: style,
            preferredTab: .tasks,
            selectedTaskKey: item.identityKey,
            accessibilityValue: accessibility(
                title: item.title,
                status: status,
                activity: activity,
                elapsed: elapsed,
                provider: provider,
                badge: nil
            )
        )
    }

    if snapshot.permissionQueue.count > 0 {
        let current = snapshot.permissionQueue.current
        let typeText: String
        switch current?.interactionKind {
        case .toolApproval: typeText = "工具授权"
        case .askUserQuestion: typeText = "问题待回答"
        case .exitPlanMode: typeText = "计划待审批"
        case nil: typeText = "请求待确认"
        }
        let title = current?.title ?? "Claude 等待确认"
        let elapsed = current.map { taskElapsedText(from: $0.arrivedAt, to: now) }
        let badge = "\(snapshot.permissionQueue.count)"
        return DynamicIslandCapsulePresentation(
            title: title,
            statusText: "待确认",
            activityText: typeText,
            elapsedText: elapsed,
            providerText: "Claude Code",
            badgeText: badge,
            progressStyle: .waiting,
            preferredTab: .confirmation,
            selectedTaskKey: nil,
            accessibilityValue: accessibility(
                title: title,
                status: "待确认",
                activity: typeText,
                elapsed: elapsed,
                provider: "Claude Code",
                badge: "队列 \(badge) 项"
            )
        )
    }

    if let item = snapshot.taskCollection.items.first(where: {
        $0.kind == .waitingForInput
    }) {
        return taskModel(item, style: .waiting)
    }
    if let item = snapshot.taskCollection.items.first(where: {
        $0.kind == .running
    }) {
        return taskModel(item, style: .indeterminate)
    }
    if let item = snapshot.taskCollection.items.first(where: {
        guard $0.kind == .failed,
              let key = terminalTaskAcknowledgementKey(for: $0)
        else { return false }
        return !snapshot.acknowledgedTerminalTaskKeys.contains(key)
    }) {
        return taskModel(item, style: .failed)
    }
    if let item = snapshot.taskCollection.items.first(where: {
        guard $0.kind == .completed,
              let key = terminalTaskAcknowledgementKey(for: $0)
        else { return false }
        return !snapshot.acknowledgedTerminalTaskKeys.contains(key)
    }) {
        return taskModel(item, style: .completed)
    }

    if snapshot.codexDesktopRunning
        || snapshot.availableProviders.contains(.claudeCode)
    {
        let provider = snapshot.selectedQuotaProvider
        let state = snapshot.quotaStates[provider]
        let remaining = state?.rows.first(where: {
            $0.name == provider.summaryRowName
        })?.remainingPercent
        let activity = remaining.map { "\($0)% 可用" }
        let title = "ChatBird 空闲"
        let status = "空闲"
        return DynamicIslandCapsulePresentation(
            title: title,
            statusText: status,
            activityText: activity,
            elapsedText: nil,
            providerText: provider.displayName,
            badgeText: nil,
            progressStyle: .idle,
            preferredTab: .quota,
            selectedTaskKey: nil,
            accessibilityValue: accessibility(
                title: title,
                status: status,
                activity: activity,
                elapsed: nil,
                provider: provider.displayName,
                badge: nil
            )
        )
    }

    return DynamicIslandCapsulePresentation(
        title: "Codex 已退出",
        statusText: "离线",
        activityText: nil,
        elapsedText: nil,
        providerText: nil,
        badgeText: nil,
        progressStyle: .idle,
        preferredTab: .tasks,
        selectedTaskKey: nil,
        accessibilityValue: "Codex 已退出，等待 Codex 启动"
    )
}

final class DynamicIslandCapsuleHitTargetButton: NSButton {
    var onDragEnded: ((NSPoint) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard let window else {
            super.mouseDown(with: event)
            return
        }

        let start = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        var isDragging = false

        while let nextEvent = window.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) {
            let current = NSEvent.mouseLocation
            switch nextEvent.type {
            case .leftMouseDragged:
                if !isDragging {
                    isDragging = dynamicIslandCapsuleDragExceededThreshold(
                        from: start,
                        to: current
                    )
                }
                guard isDragging else { continue }
                window.setFrameOrigin(NSPoint(
                    x: startOrigin.x + current.x - start.x,
                    y: startOrigin.y + current.y - start.y
                ))
            case .leftMouseUp:
                if isDragging || dynamicIslandCapsuleDragExceededThreshold(
                    from: start,
                    to: current
                ) {
                    onDragEnded?(current)
                } else {
                    performClick(nil)
                }
                return
            default:
                continue
            }
        }
    }
}

final class DynamicIslandRootViewController: NSViewController {
    var onExpand: ((DynamicIslandTab, String?) -> Void)?
    var onCapsuleDragEnded: ((NSPoint) -> Void)?
    var onRequestPetPanel: (() -> Void)?
    var onCollapse: (() -> Void)?
    var onHide: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onTabChange: ((DynamicIslandTab) -> Void)?
    var onSourceFilterChange: ((TaskSourceFilter) -> Void)?
    var onQuotaProviderChange: ((QuotaProvider) -> Void)?
    var onOpenTask: ((TaskProgressItem) -> Void)?
    var onCopyWorkingDirectory: ((String) -> Bool)?
    var onSelectedTaskKeyChange: ((String?) -> Void)?

    private let capsuleController = DynamicIslandCapsuleViewController()
    private let workspaceController = DynamicIslandWorkspaceViewController()
    private(set) var selectedTaskKey: String?

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: dynamicIslandCapsuleSize))
        view.wantsLayer = true
        addChild(capsuleController)
        addChild(workspaceController)
        capsuleController.view.frame = view.bounds
        workspaceController.view.frame = view.bounds
        view.addSubview(capsuleController.view)

        capsuleController.onExpand = { [weak self] tab, key in
            self?.onExpand?(tab, key)
        }
        capsuleController.onDragEnded = { [weak self] point in
            self?.onCapsuleDragEnded?(point)
        }
        capsuleController.onRequestPetPanel = { [weak self] in
            self?.onRequestPetPanel?()
        }
        workspaceController.onCollapse = { [weak self] in
            self?.onCollapse?()
        }
        workspaceController.onHide = { [weak self] in
            self?.onHide?()
        }
        workspaceController.onRefresh = { [weak self] in
            self?.onRefresh?()
        }
        workspaceController.onTabChange = { [weak self] tab in
            self?.onTabChange?(tab)
        }
        workspaceController.onSourceFilterChange = { [weak self] filter in
            self?.onSourceFilterChange?(filter)
        }
        workspaceController.onQuotaProviderChange = { [weak self] provider in
            self?.onQuotaProviderChange?(provider)
        }
        workspaceController.onOpenTask = { [weak self] item in
            self?.onOpenTask?(item)
        }
        workspaceController.onCopyWorkingDirectory = { [weak self] path in
            self?.onCopyWorkingDirectory?(path) ?? false
        }
        workspaceController.onSelectedTaskKeyChange = { [weak self] key in
            self?.selectedTaskKey = key
            self?.onSelectedTaskKeyChange?(key)
        }
    }

    func apply(
        snapshot: ActivityDashboardSnapshot,
        state: DynamicIslandPresentationState
    ) {
        _ = view
        let targetSize = dynamicIslandRequestedSize(for: state)
        view.frame = NSRect(origin: .zero, size: targetSize)

        let model = dynamicIslandCapsulePresentation(
            snapshot: snapshot,
            now: dynamicIslandCurrentDate()
        )
        capsuleController.apply(model)
        workspaceController.selectedTaskKey = selectedTaskKey
        workspaceController.apply(snapshot: snapshot, state: state)

        switch state {
        case .hidden, .capsule:
            hideTaskHover()
            show(capsuleController)
        case .expanded:
            show(workspaceController)
        }
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }

    func accessibilitySnapshotForSelfTest() -> String {
        _ = view
        return workspaceController.accessibilitySnapshotForSelfTest()
    }

    func capsuleHitTargetSizeForSelfTest() -> NSSize {
        _ = view
        capsuleController.view.needsLayout = true
        capsuleController.view.layoutSubtreeIfNeeded()
        return capsuleController.hitTargetFrameForSelfTest.size
    }

    func capsuleLayoutSnapshotForSelfTest() -> DynamicIslandCapsuleLayoutSnapshot {
        _ = view
        capsuleController.view.needsLayout = true
        capsuleController.view.layoutSubtreeIfNeeded()
        return capsuleController.layoutSnapshotForSelfTest()
    }

    func setSelectedTaskKey(_ selectedTaskKey: String?) {
        self.selectedTaskKey = selectedTaskKey
        workspaceController.selectedTaskKey = selectedTaskKey
    }

    func selectedTaskKeyForSelfTest() -> String? {
        selectedTaskKey
    }

    func workspaceSelectedTaskKeyForSelfTest() -> String? {
        workspaceController.selectedTaskKey
    }

    func hideTaskHover() {
        workspaceController.hideTaskHover()
    }

    func showTaskHoverForSelfTest(item: TaskProgressItem) {
        workspaceController.showTaskHoverForSelfTest(item: item)
    }

    func taskHoverVisibleForSelfTest() -> Bool {
        workspaceController.taskHoverVisibleForSelfTest()
    }

    func performOpenSelectedTaskForSelfTest() {
        workspaceController.performOpenSelectedTaskForSelfTest()
    }

    func installConfirmationViewController(
        _ controller: DynamicIslandConfirmationViewController
    ) {
        _ = view
        workspaceController.installConfirmationViewController(controller)
    }

    func applyConfirmationPresentation(
        _ presentation: ClaudePermissionPresentation
    ) {
        _ = view
        workspaceController.applyConfirmationPresentation(presentation)
    }

    func clearConfirmationPresentation() {
        _ = view
        workspaceController.clearConfirmationPresentation()
    }

    func expandCapsuleForSelfTest() {
        _ = view
        capsuleController.expandForSelfTest()
    }

    func performCapsuleDragEndedForSelfTest(at point: NSPoint) {
        _ = view
        capsuleController.performDragEndedForSelfTest(at: point)
    }

    func performCapsuleModeSwitchForSelfTest() {
        _ = view
        capsuleController.performModeSwitchForSelfTest()
    }

    func performTopRefreshButtonClickForSelfTest() {
        workspaceController.performTopRefreshButtonClickForSelfTest()
    }

    func performHideButtonClickForSelfTest() {
        workspaceController.performHideButtonClickForSelfTest()
    }

    func performQuotaProviderButtonClickForSelfTest(_ provider: QuotaProvider) {
        workspaceController.performQuotaProviderButtonClickForSelfTest(provider)
    }

    private func show(_ controller: NSViewController) {
        let targetView = controller.view
        if targetView.superview !== view {
            view.subviews.forEach { $0.removeFromSuperview() }
            view.addSubview(targetView)
        }
        targetView.frame = view.bounds
        targetView.autoresizingMask = [.width, .height]
    }
}

final class DynamicIslandCapsuleViewController: NSViewController {
    var onExpand: ((DynamicIslandTab, String?) -> Void)?
    var onDragEnded: ((NSPoint) -> Void)?
    var onRequestPetPanel: (() -> Void)?

    private let backgroundView = DynamicIslandSurfaceView(
        cornerRadius: 29,
        showsHairline: true
    )
    private let statusDotView = NSView()
    private let statusField = DynamicIslandLabel(size: 12, weight: .medium)
    private let titleField = DynamicIslandLabel(size: 14, weight: .semibold)
    private let elapsedField = DynamicIslandLabel(
        size: 12,
        weight: .medium,
        monospaced: true
    )
    private let chevronView = NSImageView()
    private let hitTargetButton = DynamicIslandCapsuleHitTargetButton(
        title: "",
        target: nil,
        action: nil
    )
    private let modeSwitchButton = DynamicIslandButton(
        title: "面板",
        style: .secondary
    )
    private var model: DynamicIslandCapsulePresentation?

    var hitTargetFrameForSelfTest: NSRect { hitTargetButton.frame }

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: dynamicIslandCapsuleSize))
        view.addSubview(backgroundView)
        for subview in [
            statusDotView,
            statusField,
            titleField,
            elapsedField,
            chevronView,
        ] {
            view.addSubview(subview)
            subview.setAccessibilityElement(false)
        }
        view.addSubview(hitTargetButton)
        view.addSubview(modeSwitchButton)

        statusDotView.wantsLayer = true
        statusField.textColor = DynamicIslandPalette.secondaryText
        elapsedField.textColor = DynamicIslandPalette.secondaryText

        let chevronConfiguration = NSImage.SymbolConfiguration(
            pointSize: 13,
            weight: .semibold
        )
        chevronView.image = NSImage(
            systemSymbolName: "chevron.right",
            accessibilityDescription: "展开"
        )?.withSymbolConfiguration(chevronConfiguration)
        chevronView.contentTintColor = DynamicIslandPalette.secondaryText
        chevronView.imageScaling = .scaleProportionallyDown

        hitTargetButton.isBordered = false
        hitTargetButton.isTransparent = true
        hitTargetButton.focusRingType = .none
        hitTargetButton.title = ""
        hitTargetButton.target = self
        hitTargetButton.action = #selector(expandFromButton)
        hitTargetButton.onDragEnded = { [weak self] point in
            self?.onDragEnded?(point)
        }
        hitTargetButton.setAccessibilityRole(.button)
        hitTargetButton.setAccessibilityHelp(
            "点击展开灵动岛功能面板；拖动可移到其他屏幕；右侧按钮切换到宠物面板"
        )
        hitTargetButton.toolTip = "点击展开 · 拖动到其他屏幕"

        modeSwitchButton.target = self
        modeSwitchButton.action = #selector(requestPetPanel)
        modeSwitchButton.setAccessibilityLabel("切换到宠物面板")
        modeSwitchButton.setAccessibilityHelp(
            "关闭灵动岛并显示宠物面板"
        )
        modeSwitchButton.toolTip = "切换到宠物面板"
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        backgroundView.frame = view.bounds
        let centerY = view.bounds.midY
        statusDotView.frame = NSRect(x: 22, y: centerY - 5, width: 10, height: 10)
        statusDotView.layer?.cornerRadius = 5
        statusField.frame = NSRect(x: 42, y: centerY - 10, width: 58, height: 20)

        let modeSwitchFrame = NSRect(
            x: max(0, view.bounds.width - 64),
            y: centerY - 14,
            width: 50,
            height: 28
        )
        modeSwitchButton.frame = modeSwitchFrame
        let chevronFrame = NSRect(
            x: max(0, modeSwitchFrame.minX - 18),
            y: centerY - 8,
            width: 8,
            height: 16
        )
        chevronView.frame = chevronFrame
        elapsedField.frame = NSRect(
            x: max(0, chevronFrame.minX - 50),
            y: centerY - 10,
            width: 40,
            height: 20
        )
        titleField.frame = NSRect(
            x: 116,
            y: centerY - 11,
            width: max(0, elapsedField.frame.minX - 128),
            height: 22
        )
        hitTargetButton.frame = NSRect(
            x: 0,
            y: 0,
            width: max(0, modeSwitchFrame.minX - 6),
            height: view.bounds.height
        )
    }

    func apply(_ model: DynamicIslandCapsulePresentation) {
        _ = view
        self.model = model
        titleField.stringValue = model.title
        statusField.stringValue = model.statusText
        elapsedField.stringValue = model.elapsedText ?? ""
        titleField.toolTip = model.title
        statusDotView.layer?.backgroundColor = statusColor(for: model).cgColor

        let accessibilityLabel = "\(model.title)，\(model.statusText)"
        hitTargetButton.setAccessibilityLabel(accessibilityLabel)
        hitTargetButton.setAccessibilityValue(model.accessibilityValue)
    }

    @objc private func expandFromButton() {
        guard let model else { return }
        onExpand?(model.preferredTab, model.selectedTaskKey)
    }

    @objc private func requestPetPanel() {
        onRequestPetPanel?()
    }

    func expandForSelfTest() {
        hitTargetButton.performClick(nil)
    }

    func performDragEndedForSelfTest(at point: NSPoint) {
        onDragEnded?(point)
    }

    func performModeSwitchForSelfTest() {
        modeSwitchButton.performClick(nil)
    }

    func layoutSnapshotForSelfTest() -> DynamicIslandCapsuleLayoutSnapshot {
        let buttons = view.subviews.compactMap { $0 as? NSButton }
        return DynamicIslandCapsuleLayoutSnapshot(
            bounds: view.bounds,
            statusDotFrame: statusDotView.frame,
            statusFrame: statusField.frame,
            titleFrame: titleField.frame,
            elapsedFrame: elapsedField.frame,
            chevronFrame: chevronView.frame,
            hitTargetFrame: hitTargetButton.frame,
            modeSwitchFrame: modeSwitchButton.frame,
            labelCount: view.subviews.compactMap { $0 as? NSTextField }.count,
            buttonCount: buttons.count,
            hasVisibleButtonTitle: buttons.contains { !$0.title.isEmpty },
            modeSwitchIsFrontmost: view.subviews.last === modeSwitchButton,
            hitTargetToolTip: hitTargetButton.toolTip,
            hitTargetAccessibilityHelp:
                hitTargetButton.accessibilityHelp() as? String,
            modeSwitchTitle: modeSwitchButton.title,
            modeSwitchToolTip: modeSwitchButton.toolTip,
            modeSwitchAccessibilityLabel:
                modeSwitchButton.accessibilityLabel() as? String
        )
    }

    private func statusColor(for model: DynamicIslandCapsulePresentation) -> NSColor {
        if model.title == "Codex 已退出" { return DynamicIslandPalette.red }
        switch model.progressStyle {
        case .indeterminate, .completed:
            return DynamicIslandPalette.green
        case .waiting:
            return DynamicIslandPalette.amber
        case .failed:
            return DynamicIslandPalette.red
        case .idle:
            return DynamicIslandPalette.secondaryText
        }
    }
}

final class DynamicIslandWorkspaceViewController: NSViewController {
    var onCollapse: (() -> Void)?
    var onHide: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onTabChange: ((DynamicIslandTab) -> Void)?
    var onSourceFilterChange: ((TaskSourceFilter) -> Void)?
    var onQuotaProviderChange: ((QuotaProvider) -> Void)?
    var onOpenTask: ((TaskProgressItem) -> Void)?
    var onCopyWorkingDirectory: ((String) -> Bool)?
    var onSelectedTaskKeyChange: ((String?) -> Void)?
    var selectedTaskKey: String?

    private let backgroundView = DynamicIslandSurfaceView(
        cornerRadius: 20,
        showsHairline: true
    )
    private let titleField = DynamicIslandLabel(size: 15, weight: .semibold)
    private let tabs = DynamicIslandSegmentedControl(
        labels: ["任务", "确认", "额度"]
    )
    private let sourceFilter = DynamicIslandSegmentedControl(
        labels: ["全部", "Codex", "Claude"]
    )
    private let refreshButton = DynamicIslandButton(
        title: "",
        style: .icon,
        imageName: "arrow.clockwise"
    )
    private let collapseButton = DynamicIslandButton(
        title: "",
        style: .icon,
        imageName: "chevron.up"
    )
    private let hideButton = DynamicIslandButton(
        title: "",
        style: .icon,
        imageName: "xmark"
    )
    private let headerDivider = DynamicIslandDividerView()
    private let childContainer = NSView()
    private let taskController = DynamicIslandTaskViewController()
    private let quotaController = DynamicIslandQuotaViewController()
    private var confirmationController: DynamicIslandConfirmationViewController?
    private let statusSymbol = NSImageView()
    private let statusField = DynamicIslandLabel(size: 13, weight: .medium)
    private let placeholderField = DynamicIslandLabel(size: 13, weight: .regular)
    private var currentSourceFilter = TaskSourceFilter.all
    private var latestSnapshot = ActivityDashboardSnapshot()
    private var latestState = DynamicIslandPresentationState.capsule

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: dynamicIslandTaskSize))
        view.addSubview(backgroundView)
        for subview in [
            titleField,
            tabs,
            sourceFilter,
            refreshButton,
            collapseButton,
            hideButton,
            headerDivider,
            childContainer,
        ] {
            view.addSubview(subview)
        }
        addChild(taskController)
        addChild(quotaController)
        childContainer.addSubview(statusSymbol)
        childContainer.addSubview(statusField)
        childContainer.addSubview(placeholderField)

        titleField.stringValue = "ChatBird 活动"
        titleField.setAccessibilityLabel("ChatBird 活动")

        tabs.onSelectionChange = { [weak self] index in
            self?.tabChanged(index: index)
        }
        tabs.setAccessibilityLabel("活动分页")
        tabs.setAccentColor(DynamicIslandPalette.green, forSegment: 0)
        tabs.setAccentColor(DynamicIslandPalette.amber, forSegment: 1)
        tabs.setAccentColor(DynamicIslandPalette.green, forSegment: 2)

        sourceFilter.onSelectionChange = { [weak self] index in
            self?.sourceChanged(index: index)
        }
        sourceFilter.selectSegment(0)
        sourceFilter.setAccessibilityLabel("任务来源筛选")

        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        refreshButton.setAccessibilityLabel("刷新活动")
        refreshButton.toolTip = "刷新任务与额度"

        collapseButton.target = self
        collapseButton.action = #selector(collapse)
        collapseButton.setAccessibilityLabel("收起动态岛")
        collapseButton.toolTip = "收起为胶囊"

        hideButton.target = self
        hideButton.action = #selector(hide)
        hideButton.setAccessibilityLabel("隐藏灵动岛")
        hideButton.setAccessibilityHelp(
            "隐藏后可按 \(chatBirdVisibilityHotKeyDisplayName) 重新显示"
        )
        hideButton.toolTip = "隐藏灵动岛（\(chatBirdVisibilityHotKeyDisplayName) 可恢复）"

        placeholderField.stringValue = "任务、确认和额度详情将在后续任务接入"
        placeholderField.setAccessibilityLabel("共享展开工作台内容")
        statusField.setAccessibilityLabel("当前活动状态")
        taskController.onOpenTask = { [weak self] item in
            self?.onOpenTask?(item)
        }
        taskController.onCopyWorkingDirectory = { [weak self] path in
            self?.onCopyWorkingDirectory?(path) ?? false
        }
        taskController.onSelectedTaskKeyChange = { [weak self] key in
            self?.selectedTaskKey = key
            self?.onSelectedTaskKeyChange?(key)
        }
        quotaController.onSelectProvider = { [weak self] provider in
            self?.onQuotaProviderChange?(provider)
        }
        quotaController.onRefresh = { [weak self] in
            self?.onRefresh?()
        }
        childContainer.wantsLayer = true
        childContainer.layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        backgroundView.frame = view.bounds
        let width = view.bounds.width
        let height = view.bounds.height
        titleField.frame = NSRect(x: 22, y: height - 39, width: 118, height: 22)
        tabs.frame = NSRect(x: 146, y: height - 44, width: 240, height: 32)
        sourceFilter.frame = NSRect(x: 424, y: height - 44, width: 214, height: 32)
        refreshButton.frame = NSRect(x: width - 134, y: height - 44, width: 32, height: 32)
        collapseButton.frame = NSRect(x: width - 92, y: height - 44, width: 32, height: 32)
        hideButton.frame = NSRect(x: width - 50, y: height - 44, width: 32, height: 32)
        headerDivider.frame = NSRect(x: 0, y: height - 58, width: width, height: 1)
        childContainer.frame = NSRect(
            x: 12,
            y: 12,
            width: max(1, width - 24),
            height: max(1, height - 78)
        )
        let childHeight = childContainer.bounds.height
        statusSymbol.frame = NSRect(
            x: 18,
            y: childHeight - 42,
            width: 20,
            height: 20
        )
        statusField.frame = NSRect(
            x: 46,
            y: childHeight - 42,
            width: childContainer.bounds.width - 64,
            height: 20
        )
        placeholderField.frame = NSRect(
            x: 18,
            y: 18,
            width: childContainer.bounds.width - 36,
            height: max(20, childHeight - 72)
        )
        taskController.view.frame = childContainer.bounds
        quotaController.view.frame = childContainer.bounds
    }

    func apply(
        snapshot: ActivityDashboardSnapshot,
        state: DynamicIslandPresentationState
    ) {
        _ = view
        latestSnapshot = snapshot
        latestState = state
        let taskCount = snapshot.taskCollection.items.count
        let confirmationCount = snapshot.permissionQueue.count
        let activeTab: DynamicIslandTab
        if case .expanded(let tab) = state {
            activeTab = tab
        } else {
            activeTab = .tasks
        }
        tabs.setLabel(
            "  任务 \(taskCount)",
            forSegment: 0
        )
        tabs.setLabel(
            "  确认 \(confirmationCount)",
            forSegment: 1
        )
        tabs.setLabel(
            "  额度",
            forSegment: 2
        )
        tabs.setAccessibilityValue(
            "任务 \(taskCount)，确认 \(confirmationCount)，额度"
        )
        sourceFilter.setLabel(
            "  全部",
            forSegment: 0
        )
        sourceFilter.setLabel(
            "  Codex",
            forSegment: 1
        )
        sourceFilter.setLabel(
            "  Claude",
            forSegment: 2
        )
        tabs.selectSegment(tabSegmentIndex(for: state))
        sourceFilter.selectSegment(sourceSegmentIndex(for: currentSourceFilter))
        sourceFilter.setAccessibilityValue(
            "当前来源筛选 \(sourceFilterName(currentSourceFilter))，全部，Codex，Claude"
        )
        refreshButton.isEnabled = dynamicIslandDashboardRefreshEnabled(
            snapshot: snapshot
        )
        if snapshot.permissionQueue.count > 0 {
            confirmationController?.updateQueue(snapshot.permissionQueue)
        }

        switch state {
        case .expanded(.confirmation):
            if let confirmationController {
                showConfirmationContent(confirmationController)
            } else {
                showPlaceholderContent()
            }
            statusSymbol.image = NSImage(
                systemSymbolName: "questionmark.circle.fill",
                accessibilityDescription: "等待确认"
            )
            statusSymbol.contentTintColor = DynamicIslandPalette.amber
            statusField.stringValue = "等待确认"
            placeholderField.stringValue = "确认队列 \(confirmationCount) 项"
        case .expanded(.quota):
            showQuotaContent()
            quotaController.apply(snapshot)
            statusSymbol.image = NSImage(
                systemSymbolName: "circle.fill",
                accessibilityDescription: "额度状态"
            )
            statusSymbol.contentTintColor = DynamicIslandPalette.green
            statusField.stringValue = "额度状态"
            placeholderField.stringValue = "\(snapshot.selectedQuotaProvider.displayName) 额度"
        case .hidden, .capsule, .expanded(.tasks):
            showTaskContent()
            taskController.apply(
                collection: snapshot.taskCollection,
                sourceFilter: currentSourceFilter,
                preferredTaskKey: selectedTaskKey
            )
            selectedTaskKey = taskController.selectedTaskKeyForSelfTest()
            statusSymbol.image = NSImage(
                systemSymbolName: "arrow.triangle.2.circlepath",
                accessibilityDescription: "任务状态"
            )
            statusSymbol.contentTintColor = DynamicIslandPalette.green
            statusField.stringValue = "任务状态"
            if let selectedTaskKey {
                placeholderField.stringValue = "任务 \(taskCount) 项，选中 \(selectedTaskKey)"
            } else {
                placeholderField.stringValue = "任务 \(taskCount) 项"
            }
        }
    }

    private func tabSegmentIndex(for state: DynamicIslandPresentationState) -> Int {
        guard case .expanded(let tab) = state else { return 0 }
        switch tab {
        case .tasks: return 0
        case .confirmation: return 1
        case .quota: return 2
        }
    }

    private func sourceSegmentIndex(for filter: TaskSourceFilter) -> Int {
        switch filter {
        case .all: return 0
        case .codex: return 1
        case .claudeCode: return 2
        }
    }

    private func sourceFilterName(_ filter: TaskSourceFilter) -> String {
        switch filter {
        case .all: return "全部"
        case .codex: return "Codex"
        case .claudeCode: return "Claude"
        }
    }

    func accessibilitySnapshotForSelfTest() -> String {
        _ = view
        return [
            titleField.accessibilityLabel(),
            tabs.accessibilityValue() as? String,
            sourceFilter.accessibilityValue() as? String,
            refreshButton.accessibilityLabel(),
            collapseButton.accessibilityLabel(),
            hideButton.accessibilityLabel(),
        ].compactMap { $0 }.joined(separator: " ")
    }

    private func tabChanged(index: Int) {
        switch index {
        case 1: onTabChange?(.confirmation)
        case 2: onTabChange?(.quota)
        default: onTabChange?(.tasks)
        }
    }

    private func sourceChanged(index: Int) {
        switch index {
        case 1: currentSourceFilter = .codex
        case 2: currentSourceFilter = .claudeCode
        default: currentSourceFilter = .all
        }
        reapplyTaskControllerIfVisible(preferredTaskKey: nil)
        onSourceFilterChange?(currentSourceFilter)
    }

    @objc private func refresh() {
        onRefresh?()
    }

    @objc private func collapse() {
        taskController.hideHoverForSelfTest()
        onCollapse?()
    }

    @objc private func hide() {
        taskController.hideHoverForSelfTest()
        onHide?()
    }

    private func showTaskContent() {
        statusSymbol.removeFromSuperview()
        statusField.removeFromSuperview()
        placeholderField.removeFromSuperview()
        quotaController.view.removeFromSuperview()
        confirmationController?.view.removeFromSuperview()
        if taskController.view.superview !== childContainer {
            childContainer.addSubview(taskController.view)
        }
        taskController.view.frame = childContainer.bounds
        taskController.view.autoresizingMask = [.width, .height]
    }

    private func showPlaceholderContent() {
        taskController.hideHoverForSelfTest()
        taskController.view.removeFromSuperview()
        quotaController.view.removeFromSuperview()
        confirmationController?.view.removeFromSuperview()
        for subview in [statusSymbol, statusField, placeholderField]
            where subview.superview !== childContainer
        {
            childContainer.addSubview(subview)
        }
    }

    private func showConfirmationContent(
        _ controller: DynamicIslandConfirmationViewController
    ) {
        taskController.hideHoverForSelfTest()
        taskController.view.removeFromSuperview()
        quotaController.view.removeFromSuperview()
        statusSymbol.removeFromSuperview()
        statusField.removeFromSuperview()
        placeholderField.removeFromSuperview()
        if controller.parent !== self {
            addChild(controller)
        }
        if controller.view.superview !== childContainer {
            childContainer.addSubview(controller.view)
        }
        controller.view.frame = childContainer.bounds
        controller.view.autoresizingMask = [.width, .height]
    }

    private func showQuotaContent() {
        taskController.hideHoverForSelfTest()
        taskController.view.removeFromSuperview()
        confirmationController?.view.removeFromSuperview()
        statusSymbol.removeFromSuperview()
        statusField.removeFromSuperview()
        placeholderField.removeFromSuperview()
        if quotaController.view.superview !== childContainer {
            childContainer.addSubview(quotaController.view)
        }
        quotaController.view.frame = childContainer.bounds
        quotaController.view.autoresizingMask = [.width, .height]
    }

    private func reapplyTaskControllerIfVisible(preferredTaskKey: String?) {
        guard case .expanded(.tasks) = latestState else { return }
        taskController.apply(
            collection: latestSnapshot.taskCollection,
            sourceFilter: currentSourceFilter,
            preferredTaskKey: preferredTaskKey ?? selectedTaskKey
        )
        selectedTaskKey = taskController.selectedTaskKeyForSelfTest()
    }

    func hideTaskHover() {
        taskController.hideHoverForSelfTest()
    }

    func setSourceFilterForSelfTest(_ filter: TaskSourceFilter) {
        _ = view
        switch filter {
        case .all: sourceFilter.selectSegment(0)
        case .codex: sourceFilter.selectSegment(1)
        case .claudeCode: sourceFilter.selectSegment(2)
        }
        sourceChanged(index: sourceFilter.selectedSegment)
    }

    func taskVisibleKeysForSelfTest() -> [String] {
        taskController.visibleTaskKeysForSelfTest()
    }

    func quotaAccessibilitySnapshotForSelfTest() -> String {
        quotaController.accessibilitySnapshotForSelfTest()
    }

    func refreshForSelfTest() {
        refresh()
    }

    func performTopRefreshButtonClickForSelfTest() {
        _ = view
        refreshButton.performClick(nil)
    }

    func performHideButtonClickForSelfTest() {
        _ = view
        hideButton.performClick(nil)
    }

    func performQuotaProviderButtonClickForSelfTest(_ provider: QuotaProvider) {
        quotaController.performProviderButtonClickForSelfTest(provider)
    }

    func showTaskHoverForSelfTest(item: TaskProgressItem) {
        taskController.showHoverForSelfTest(item: item)
    }

    func taskHoverVisibleForSelfTest() -> Bool {
        taskController.hoverVisibleForSelfTest()
    }

    func performOpenSelectedTaskForSelfTest() {
        taskController.performOpenSelectedTaskForSelfTest()
    }

    func installConfirmationViewController(
        _ controller: DynamicIslandConfirmationViewController
    ) {
        _ = view
        if let confirmationController,
           confirmationController !== controller
        {
            confirmationController.view.removeFromSuperview()
            confirmationController.removeFromParent()
        }
        confirmationController = controller
        if case .expanded(.confirmation) = latestState {
            showConfirmationContent(controller)
        }
    }

    func applyConfirmationPresentation(
        _ presentation: ClaudePermissionPresentation
    ) {
        guard let confirmationController else { return }
        confirmationController.apply(presentation)
        if case .expanded(.confirmation) = latestState {
            showConfirmationContent(confirmationController)
        }
    }

    func clearConfirmationPresentation() {
        confirmationController?.clear()
    }
}

private final class DynamicIslandSurfaceView: NSView {
    private let cornerRadius: CGFloat
    private let showsHairline: Bool
    private let effectView = NSVisualEffectView()
    private let tintView = NSView()

    init(cornerRadius: CGFloat, showsHairline: Bool = false) {
        self.cornerRadius = cornerRadius
        self.showsHairline = showsHairline
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(effectView)
        addSubview(tintView)
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        tintView.wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        effectView.frame = bounds
        tintView.frame = bounds
        let reduceTransparency =
            NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        effectView.isHidden = reduceTransparency
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        layer?.borderColor = DynamicIslandPalette.hairline.cgColor
        layer?.borderWidth = showsHairline || reduceTransparency ? 1 : 0
        tintView.layer?.cornerRadius = cornerRadius
        tintView.layer?.backgroundColor = DynamicIslandPalette.background.cgColor
    }
}

private final class DynamicIslandLabel: NSTextField {
    init(size: CGFloat, weight: NSFont.Weight, monospaced: Bool = false) {
        super.init(frame: .zero)
        isBezeled = false
        isEditable = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        textColor = DynamicIslandPalette.primaryText
        font = monospaced
            ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
            : .systemFont(ofSize: size, weight: weight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
