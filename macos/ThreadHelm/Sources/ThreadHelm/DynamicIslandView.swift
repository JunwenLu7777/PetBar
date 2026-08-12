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

struct DynamicIslandCapsuleQuotaItem: Equatable {
    let provider: QuotaProvider
    let label: String
    let remainingPercent: Int?

    var valueText: String {
        remainingPercent.map { "\($0)%" } ?? "--"
    }

    var summaryText: String {
        "\(label) \(valueText)"
    }
}

struct DynamicIslandCapsulePresentation: Equatable {
    let title: String
    let statusText: String
    let activityText: String?
    let elapsedText: String?
    let provider: AgentID?
    let providerText: String?
    let badgeText: String?
    let quotaItems: [DynamicIslandCapsuleQuotaItem]
    let progressStyle: DynamicIslandProgressStyle
    let preferredTab: DynamicIslandTab
    let selectedTaskKey: String?
    let accessibilityValue: String
}

struct DynamicIslandCapsuleLayoutSnapshot: Equatable {
    let bounds: NSRect
    let providerIconFrame: NSRect
    let statusDotFrame: NSRect
    let statusFrame: NSRect
    let titleFrame: NSRect
    let elapsedFrame: NSRect
    let chevronFrame: NSRect
    let hitTargetFrame: NSRect
    let labelCount: Int
    let buttonCount: Int
    let hasVisibleButtonTitle: Bool
    let hitTargetToolTip: String?
    let hitTargetAccessibilityHelp: String?
    let providerIconAccessibilityDescription: String?
    let taskContentIsHidden: Bool
    let quotaSummaryIsHidden: Bool
}

struct DynamicIslandCapsuleQuotaSummaryLayoutSnapshot: Equatable {
    let frame: NSRect
    let iconFrames: [NSRect]
    let nameFrames: [NSRect]
    let valueFrames: [NSRect]
    let valueCellWidths: [CGFloat]
    let dividerFrame: NSRect
    let names: [String]
    let values: [String]
    let iconAccessibilityDescriptions: [String?]
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
        layer?.cornerRadius = 10
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
        layer?.cornerRadius = 11
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
        let spacing: CGFloat = 4
        let width = max(1, (bounds.width - spacing * CGFloat(buttons.count + 1)) / CGFloat(buttons.count))
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(
                x: spacing + CGFloat(index) * (width + spacing),
                y: 3,
                width: width,
                height: max(1, bounds.height - 6)
            )
        }
    }

    func setLabel(_ label: String, forSegment index: Int) {
        guard labels.indices.contains(index), buttons.indices.contains(index) else { return }
        labels[index] = label
        buttons[index].setDisplayTitle(label)
        setAccessibilityValue(labels.joined(separator: "，"))
    }

    func setLabels(_ nextLabels: [String]) {
        guard nextLabels != labels else { return }
        labels = nextLabels
        accentColors = Array(
            repeating: DynamicIslandPalette.green,
            count: nextLabels.count
        )
        if !nextLabels.indices.contains(selectedSegment) {
            selectedSegment = nextLabels.isEmpty ? -1 : 0
        }
        rebuildButtons()
        needsLayout = true
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

    func clearSelection() {
        selectedSegment = -1
        updateSelectionAppearance()
        setAccessibilityValue(labels.joined(separator: "，"))
    }

    func labelsForSelfTest() -> [String] {
        labels
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

func taskStartAndDurationText(from startedAt: Date, now: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    let started = formatter.string(from: startedAt)
    return "\(started) · \(taskElapsedText(from: startedAt, to: now))"
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

func dynamicIslandCapsuleContentChoices(
    for model: DynamicIslandCapsulePresentation
) -> [String] {
    guard model.quotaItems.isEmpty else { return [model.title] }
    guard let activity = dynamicIslandSanitizedTaskActivityText(model.activityText),
          activity != model.title
    else { return [model.title] }
    return [activity, model.title]
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
        let startAndElapsed = taskProgressStartAndDurationText(for: item, now: now)
        let provider = agentPresentation(for: item.source).displayName
        let activity = dynamicIslandSanitizedTaskActivityText(
            item.events.last?.text ?? item.activityText
        )
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
            elapsedText: startAndElapsed,
            provider: item.source,
            providerText: provider,
            badgeText: nil,
            quotaItems: [],
            progressStyle: style,
            preferredTab: .tasks,
            selectedTaskKey: item.identityKey,
            accessibilityValue: accessibility(
                title: item.title,
                status: status,
                activity: activity,
                elapsed: startAndElapsed,
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
        let elapsed = current.map { taskStartAndDurationText(from: $0.arrivedAt, now: now) }
        let badge = "\(snapshot.permissionQueue.count)"
        return DynamicIslandCapsulePresentation(
            title: title,
            statusText: "待确认",
            activityText: typeText,
            elapsedText: elapsed,
            provider: .claudeCode,
            providerText: "Claude Code",
            badgeText: badge,
            quotaItems: [],
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
        let quotaItems = [QuotaProvider.codex, .claudeCode].map { provider in
            let remaining = snapshot.quotaStates[provider]?.rows.first(where: {
                $0.name == provider.summaryRowName
            })?.remainingPercent
            let label = provider == .codex ? "GPT" : "Claude"
            return DynamicIslandCapsuleQuotaItem(
                provider: provider,
                label: label,
                remainingPercent: remaining
            )
        }
        let activity = quotaItems.map(\.summaryText).joined(separator: " · ")
        let title = "ThreadHelm 空闲"
        let status = "空闲"
        return DynamicIslandCapsulePresentation(
            title: title,
            statusText: status,
            activityText: activity,
            elapsedText: nil,
            provider: nil,
            providerText: nil,
            badgeText: nil,
            quotaItems: quotaItems,
            progressStyle: .idle,
            preferredTab: .quota,
            selectedTaskKey: nil,
            accessibilityValue: accessibility(
                title: title,
                status: status,
                activity: activity,
                elapsed: nil,
                provider: nil,
                badge: nil
            )
        )
    }

    return DynamicIslandCapsulePresentation(
        title: "Codex 已退出",
        statusText: "离线",
        activityText: nil,
        elapsedText: nil,
        provider: nil,
        providerText: nil,
        badgeText: nil,
        quotaItems: [],
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
    var onCollapse: (() -> Void)?
    var onHide: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onTabChange: ((DynamicIslandTab) -> Void)?
    var onSourceFilterChange: ((TaskSourceFilter) -> Void)?
    var onQuotaProviderChange: ((QuotaProvider) -> Void)?
    var onOpenTask: ((TaskProgressItem) -> OpenResult)?
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
            self?.onOpenTask?(item) ?? .failed
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

    func capsuleQuotaSummaryLayoutSnapshotForSelfTest()
        -> DynamicIslandCapsuleQuotaSummaryLayoutSnapshot
    {
        _ = view
        capsuleController.view.needsLayout = true
        capsuleController.view.layoutSubtreeIfNeeded()
        return capsuleController.quotaSummaryLayoutSnapshotForSelfTest()
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

final class DynamicIslandCapsuleQuotaSummaryView: NSView {
    private let iconViews = [NSImageView(), NSImageView()]
    private let nameFields = [
        DynamicIslandLabel(size: 12, weight: .medium),
        DynamicIslandLabel(size: 12, weight: .medium),
    ]
    private let valueFields = [
        DynamicIslandLabel(size: 13, weight: .semibold, monospaced: true),
        DynamicIslandLabel(size: 13, weight: .semibold, monospaced: true),
    ]
    private let dividerView = DynamicIslandDividerView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        for index in iconViews.indices {
            let iconView = iconViews[index]
            iconView.imageScaling = .scaleProportionallyDown
            iconView.setAccessibilityElement(false)
            addSubview(iconView)

            let nameField = nameFields[index]
            nameField.textColor = DynamicIslandPalette.secondaryText
            nameField.setAccessibilityElement(false)
            addSubview(nameField)

            let valueField = valueFields[index]
            valueField.textColor = DynamicIslandPalette.primaryText
            valueField.alignment = .right
            valueField.setAccessibilityElement(false)
            addSubview(valueField)
        }
        addSubview(dividerView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let iconWidth: CGFloat = 20
        let itemSpacing: CGFloat = 8
        let nameWidths: [CGFloat] = [30, 52]
        let valueWidth: CGFloat = 46
        let dividerWidth: CGFloat = 1
        let dividerHeight: CGFloat = 14
        let componentHeight: CGFloat = 20
        let centerY = bounds.midY
        let componentY = centerY - componentHeight / 2
        let dividerX = bounds.midX - dividerWidth / 2
        dividerView.frame = NSRect(
            x: dividerX,
            y: centerY - dividerHeight / 2,
            width: dividerWidth,
            height: dividerHeight
        )

        let columns: [(location: CGFloat, length: CGFloat)] = [
            (location: 0, length: dividerX),
            (
                location: dividerX + dividerWidth,
                length: bounds.width - dividerX - dividerWidth
            ),
        ]
        for index in iconViews.indices {
            let groupWidth = iconWidth
                + itemSpacing
                + nameWidths[index]
                + itemSpacing
                + valueWidth
            let columnMidX = columns[index].location + columns[index].length / 2
            let groupX = ((columnMidX - groupWidth / 2) * 2).rounded() / 2
            iconViews[index].frame = NSRect(
                x: groupX,
                y: componentY,
                width: iconWidth,
                height: componentHeight
            )
            nameFields[index].frame = NSRect(
                x: groupX + iconWidth + itemSpacing,
                y: componentY,
                width: nameWidths[index],
                height: componentHeight
            )
            valueFields[index].frame = NSRect(
                x: groupX
                    + iconWidth
                    + itemSpacing
                    + nameWidths[index]
                    + itemSpacing,
                y: componentY,
                width: valueWidth,
                height: componentHeight
            )
        }
    }

    func apply(_ items: [DynamicIslandCapsuleQuotaItem]) {
        let providers = [QuotaProvider.codex, .claudeCode]
        for (index, provider) in providers.enumerated() {
            let item = items.first { $0.provider == provider }
            iconViews[index].image = providerIconImage(for: provider)
            nameFields[index].stringValue = item?.label
                ?? (provider == .codex ? "GPT" : "Claude")
            valueFields[index].stringValue = item?.valueText ?? "--"
            valueFields[index].textColor = item?.remainingPercent == nil
                ? DynamicIslandPalette.tertiaryText
                : DynamicIslandPalette.primaryText
        }
        needsLayout = true
    }

    func layoutSnapshotForSelfTest() -> DynamicIslandCapsuleQuotaSummaryLayoutSnapshot {
        needsLayout = true
        layoutSubtreeIfNeeded()
        return DynamicIslandCapsuleQuotaSummaryLayoutSnapshot(
            frame: frame,
            iconFrames: iconViews.map(\.frame),
            nameFrames: nameFields.map(\.frame),
            valueFrames: valueFields.map(\.frame),
            valueCellWidths: valueFields.map {
                $0.cell?.cellSize.width ?? $0.intrinsicContentSize.width
            },
            dividerFrame: dividerView.frame,
            names: nameFields.map(\.stringValue),
            values: valueFields.map(\.stringValue),
            iconAccessibilityDescriptions: iconViews.map {
                $0.image?.accessibilityDescription
            }
        )
    }
}

final class DynamicIslandCapsuleViewController: NSViewController {
    var onExpand: ((DynamicIslandTab, String?) -> Void)?
    var onDragEnded: ((NSPoint) -> Void)?

    private let backgroundView = DynamicIslandSurfaceView(
        cornerRadius: 29,
        showsHairline: true
    )
    private let providerIconView = NSImageView()
    private let statusDotView = NSView()
    private let statusField = DynamicIslandLabel(size: 12, weight: .medium)
    private let titleField = DynamicIslandLabel(size: 14, weight: .semibold)
    private let elapsedField = DynamicIslandLabel(
        size: 12,
        weight: .medium,
        monospaced: true
    )
    private let quotaSummaryView = DynamicIslandCapsuleQuotaSummaryView()
    private let chevronView = NSImageView()
    private let hitTargetButton = DynamicIslandCapsuleHitTargetButton(
        title: "",
        target: nil,
        action: nil
    )
    private var model: DynamicIslandCapsulePresentation?
    private var contentChoices: [String] = []
    private var contentChoiceIndex = 0
    private var contentRotationTimer: Timer?

    var hitTargetFrameForSelfTest: NSRect { hitTargetButton.frame }

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: dynamicIslandCapsuleSize))
        view.addSubview(backgroundView)
        for subview in [
            providerIconView,
            statusDotView,
            statusField,
            titleField,
            elapsedField,
            chevronView,
        ] {
            view.addSubview(subview)
            subview.setAccessibilityElement(false)
        }
        view.addSubview(quotaSummaryView)
        quotaSummaryView.isHidden = true
        view.addSubview(hitTargetButton)

        statusDotView.wantsLayer = true
        providerIconView.imageScaling = .scaleProportionallyDown
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
            "点击展开灵动岛功能面板；拖动可移到其他屏幕"
        )
        hitTargetButton.toolTip = "点击展开 · 拖动到其他屏幕"
    }

    deinit {
        contentRotationTimer?.invalidate()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        backgroundView.frame = view.bounds
        let centerY = view.bounds.midY
        providerIconView.frame = NSRect(x: 18, y: centerY - 10, width: 20, height: 20)
        statusDotView.frame = NSRect(x: 46, y: centerY - 4, width: 8, height: 8)
        statusDotView.layer?.cornerRadius = 4
        statusField.frame = NSRect(x: 62, y: centerY - 10, width: 48, height: 20)

        let chevronFrame = NSRect(
            x: max(0, view.bounds.width - 24),
            y: centerY - 8,
            width: 8,
            height: 16
        )
        chevronView.frame = chevronFrame
        elapsedField.frame = NSRect(
            x: max(0, chevronFrame.minX - 104),
            y: centerY - 10,
            width: 96,
            height: 20
        )
        quotaSummaryView.frame = NSRect(
            x: 18,
            y: centerY - 10,
            width: 286,
            height: 20
        )
        titleField.frame = NSRect(
            x: 120,
            y: centerY - 11,
            width: max(0, elapsedField.frame.minX - 132),
            height: 22
        )
        hitTargetButton.frame = NSRect(
            x: 0,
            y: 0,
            width: view.bounds.width,
            height: view.bounds.height
        )
    }

    func apply(_ model: DynamicIslandCapsulePresentation) {
        _ = view
        self.model = model
        let showsQuotaSummary = !model.quotaItems.isEmpty
        let nextChoices = dynamicIslandCapsuleContentChoices(for: model)
        let contentChanged = contentChoices != nextChoices
        if contentChanged {
            contentChoices = nextChoices
            contentChoiceIndex = 0
        }
        renderCurrentContentChoice()
        if contentChanged || contentRotationTimer == nil {
            updateContentRotationTimer()
        }
        statusField.stringValue = model.statusText
        elapsedField.stringValue = model.elapsedText ?? ""
        titleField.toolTip = [model.title, model.activityText]
            .compactMap { $0 }
            .joined(separator: " · ")
        providerIconView.image = model.provider.flatMap {
            agentIconImage(for: $0)
        }
        quotaSummaryView.apply(model.quotaItems)
        quotaSummaryView.isHidden = !showsQuotaSummary
        providerIconView.isHidden = showsQuotaSummary || model.provider == nil
        statusDotView.isHidden = showsQuotaSummary
        statusField.isHidden = showsQuotaSummary
        titleField.isHidden = showsQuotaSummary
        elapsedField.isHidden = showsQuotaSummary
        statusDotView.layer?.backgroundColor = statusColor(for: model).cgColor

        let accessibilityLabel = showsQuotaSummary
            ? "GPT 和 Claude 额度"
            : "\(model.title)，\(model.statusText)"
        hitTargetButton.setAccessibilityLabel(accessibilityLabel)
        hitTargetButton.setAccessibilityValue(model.accessibilityValue)
    }

    @objc private func expandFromButton() {
        guard let model else { return }
        onExpand?(model.preferredTab, model.selectedTaskKey)
    }

    func expandForSelfTest() {
        hitTargetButton.performClick(nil)
    }

    func performDragEndedForSelfTest(at point: NSPoint) {
        onDragEnded?(point)
    }

    private func updateContentRotationTimer() {
        contentRotationTimer?.invalidate()
        contentRotationTimer = nil
        guard contentChoices.count > 1 else { return }
        let timer = Timer(timeInterval: 3.6, repeats: true) { [weak self] _ in
            self?.advanceContentChoice()
        }
        RunLoop.main.add(timer, forMode: .common)
        contentRotationTimer = timer
    }

    private func advanceContentChoice() {
        guard !contentChoices.isEmpty else { return }
        contentChoiceIndex = (contentChoiceIndex + 1) % contentChoices.count
        renderCurrentContentChoice()
    }

    private func renderCurrentContentChoice() {
        guard contentChoices.indices.contains(contentChoiceIndex) else {
            titleField.stringValue = model?.title ?? ""
            return
        }
        titleField.stringValue = contentChoices[contentChoiceIndex]
    }

    func layoutSnapshotForSelfTest() -> DynamicIslandCapsuleLayoutSnapshot {
        let buttons = view.subviews.compactMap { $0 as? NSButton }
        return DynamicIslandCapsuleLayoutSnapshot(
            bounds: view.bounds,
            providerIconFrame: providerIconView.frame,
            statusDotFrame: statusDotView.frame,
            statusFrame: statusField.frame,
            titleFrame: titleField.frame,
            elapsedFrame: elapsedField.frame,
            chevronFrame: chevronView.frame,
            hitTargetFrame: hitTargetButton.frame,
            labelCount: view.subviews.compactMap { $0 as? NSTextField }.count,
            buttonCount: buttons.count,
            hasVisibleButtonTitle: buttons.contains { !$0.title.isEmpty },
            hitTargetToolTip: hitTargetButton.toolTip,
            hitTargetAccessibilityHelp:
                hitTargetButton.accessibilityHelp() as? String,
            providerIconAccessibilityDescription:
                providerIconView.image?.accessibilityDescription,
            taskContentIsHidden: providerIconView.isHidden
                && statusDotView.isHidden
                && statusField.isHidden
                && titleField.isHidden
                && elapsedField.isHidden,
            quotaSummaryIsHidden: quotaSummaryView.isHidden
        )
    }

    func quotaSummaryLayoutSnapshotForSelfTest()
        -> DynamicIslandCapsuleQuotaSummaryLayoutSnapshot
    {
        quotaSummaryView.layoutSnapshotForSelfTest()
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
    var onOpenTask: ((TaskProgressItem) -> OpenResult)?
    var onCopyWorkingDirectory: ((String) -> Bool)?
    var onSelectedTaskKeyChange: ((String?) -> Void)?
    var selectedTaskKey: String?

    private let backgroundView = DynamicIslandSurfaceView(
        cornerRadius: 20,
        showsHairline: true
    )
    private let titleField = DynamicIslandLabel(size: 15, weight: .semibold)
    private let tabs = DynamicIslandSegmentedControl(
        labels: ["任务", "额度"]
    )
    private let sourceFilter = DynamicIslandSegmentedControl(
        labels: TaskSourceFilter.options(for: AgentID.builtInOrder).map {
            taskSourceFilterName($0)
        }
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
    private var sourceFilterOptions = TaskSourceFilter.options(
        for: AgentID.builtInOrder
    )
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

        titleField.stringValue = "ThreadHelm 活动"
        titleField.setAccessibilityLabel("ThreadHelm 活动")

        tabs.onSelectionChange = { [weak self] index in
            self?.tabChanged(index: index)
        }
        tabs.setAccessibilityLabel("活动分页")
        tabs.setAccentColor(DynamicIslandPalette.green, forSegment: 0)
        tabs.setAccentColor(DynamicIslandPalette.green, forSegment: 1)

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
            "隐藏后可点击菜单栏或 Dock 中的 ThreadHelm，或按 \(threadHelmVisibilityHotKeyDisplayName) 重新显示"
        )
        hideButton.toolTip = "隐藏灵动岛（菜单栏、Dock 或 \(threadHelmVisibilityHotKeyDisplayName) 可恢复）"

        placeholderField.stringValue = "任务与额度详情"
        placeholderField.setAccessibilityLabel("共享展开工作台内容")
        statusField.setAccessibilityLabel("当前活动状态")
        taskController.onOpenTask = { [weak self] item in
            self?.onOpenTask?(item) ?? .failed
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
        tabs.frame = NSRect(x: 146, y: height - 44, width: 160, height: 32)
        sourceFilter.frame = NSRect(
            x: 314,
            y: height - 44,
            width: max(1, width - 468),
            height: 32
        )
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
        sourceFilter.isHidden = activeTab != .tasks
        var seenAgentIDs = Set<AgentID>()
        let availableAgentIDs = snapshot.availableAgentIDs
            .filter { seenAgentIDs.insert($0).inserted }
            .sorted()
        sourceFilterOptions = TaskSourceFilter.options(for: availableAgentIDs)
        if !sourceFilterOptions.contains(currentSourceFilter) {
            currentSourceFilter = .all
        }
        sourceFilter.setLabels(sourceFilterOptions.map(taskSourceFilterName))
        tabs.setLabel(
            "  任务 \(taskCount)",
            forSegment: 0
        )
        tabs.setLabel(
            "  额度",
            forSegment: 1
        )
        tabs.setAccessibilityValue(
            "任务 \(taskCount)，额度"
        )
        if let segmentIndex = tabSegmentIndex(for: state) {
            tabs.selectSegment(segmentIndex)
        } else {
            tabs.clearSelection()
        }
        sourceFilter.selectSegment(sourceSegmentIndex(for: currentSourceFilter))
        sourceFilter.setAccessibilityValue(
            "当前来源筛选 \(taskSourceFilterName(currentSourceFilter))，"
                + sourceFilterOptions.map(taskSourceFilterName)
                    .joined(separator: "，")
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

    private func tabSegmentIndex(for state: DynamicIslandPresentationState) -> Int? {
        guard case .expanded(let tab) = state else { return 0 }
        switch tab {
        case .tasks: return 0
        case .confirmation: return nil
        case .quota: return 1
        }
    }

    private func sourceSegmentIndex(for filter: TaskSourceFilter) -> Int {
        sourceFilterOptions.firstIndex(of: filter) ?? 0
    }

    func accessibilitySnapshotForSelfTest() -> String {
        _ = view
        return [
            titleField.accessibilityLabel(),
            tabs.accessibilityValue() as? String,
            sourceFilter.isHidden
                ? nil
                : sourceFilter.accessibilityValue() as? String,
            refreshButton.accessibilityLabel(),
            collapseButton.accessibilityLabel(),
            hideButton.accessibilityLabel(),
        ].compactMap { $0 }.joined(separator: " ")
    }

    private func tabChanged(index: Int) {
        switch index {
        case 1: onTabChange?(.quota)
        default: onTabChange?(.tasks)
        }
    }

    private func sourceChanged(index: Int) {
        currentSourceFilter = sourceFilterOptions.indices.contains(index)
            ? sourceFilterOptions[index]
            : .all
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
        sourceFilter.selectSegment(sourceSegmentIndex(for: filter))
        sourceChanged(index: sourceFilter.selectedSegment)
    }

    func sourceFilterLabelsForSelfTest() -> [String] {
        _ = view
        return sourceFilter.labelsForSelfTest()
    }

    func taskVisibleKeysForSelfTest() -> [String] {
        taskController.visibleTaskKeysForSelfTest()
    }

    func sourceFilterIsHiddenForSelfTest() -> Bool {
        _ = view
        return sourceFilter.isHidden
    }

    func topLevelTabLabelsForSelfTest() -> [String] {
        _ = view
        return tabs.labelsForSelfTest()
    }

    func selectedTopLevelTabForSelfTest() -> Int? {
        _ = view
        return tabs.selectedSegment >= 0 ? tabs.selectedSegment : nil
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
