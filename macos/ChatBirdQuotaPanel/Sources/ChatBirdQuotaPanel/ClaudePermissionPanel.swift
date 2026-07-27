import AppKit

private let claudePermissionPanelWidth: CGFloat = 548
private let claudePermissionPanelCornerRadius: CGFloat = 20
private let claudePermissionPanelPointerHeight: CGFloat = 14

func claudeQuestionPanelHeight(questionCount _: Int) -> CGFloat {
    620
}

func clampedClaudeQuestionPageIndex(_ proposedIndex: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return min(max(0, proposedIndex), count - 1)
}

private enum ClaudePanelPalette {
    static let top = NSColor(
        calibratedRed: 0.055,
        green: 0.15,
        blue: 0.26,
        alpha: 0.99
    )
    static let bottom = NSColor(
        calibratedRed: 0.022,
        green: 0.068,
        blue: 0.13,
        alpha: 0.995
    )
    static let cyan = NSColor(
        calibratedRed: 0.24,
        green: 0.78,
        blue: 1,
        alpha: 1
    )
    static let brightCyan = NSColor(
        calibratedRed: 0.36,
        green: 0.92,
        blue: 1,
        alpha: 1
    )
    static let blue = NSColor(
        calibratedRed: 0.12,
        green: 0.57,
        blue: 1,
        alpha: 1
    )
    static let purple = NSColor(
        calibratedRed: 0.70,
        green: 0.43,
        blue: 1,
        alpha: 1
    )
    static let red = NSColor(
        calibratedRed: 1,
        green: 0.31,
        blue: 0.29,
        alpha: 1
    )
    static let primaryText = NSColor.white.withAlphaComponent(0.97)
    static let secondaryText = NSColor(
        calibratedRed: 0.58,
        green: 0.72,
        blue: 0.86,
        alpha: 1
    )
    static let mutedText = NSColor(
        calibratedRed: 0.43,
        green: 0.59,
        blue: 0.74,
        alpha: 1
    )
    static let insetFill = NSColor(
        calibratedRed: 0.02,
        green: 0.08,
        blue: 0.15,
        alpha: 0.72
    )
    static let hairline = NSColor(
        calibratedRed: 0.35,
        green: 0.75,
        blue: 1,
        alpha: 0.18
    )
}

private final class ClaudePermissionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class ClaudePermissionChromeView: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.current?.imageInterpolation = .high

        let bodyRect = NSRect(
            x: 1,
            y: claudePermissionPanelPointerHeight,
            width: bounds.width - 2,
            height: bounds.height - claudePermissionPanelPointerHeight - 1
        )
        let body = NSBezierPath(
            roundedRect: bodyRect,
            xRadius: claudePermissionPanelCornerRadius,
            yRadius: claudePermissionPanelCornerRadius
        )

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.42)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -5)
        shadow.set()

        if let gradient = NSGradient(
            starting: ClaudePanelPalette.top,
            ending: ClaudePanelPalette.bottom
        ) {
            gradient.draw(in: body, angle: -90)
        } else {
            ClaudePanelPalette.bottom.setFill()
            body.fill()
        }

        let centerX = bounds.midX
        let pointer = NSBezierPath()
        pointer.move(to: NSPoint(x: centerX - 13, y: bodyRect.minY + 1))
        pointer.line(to: NSPoint(x: centerX, y: 1))
        pointer.line(to: NSPoint(x: centerX + 13, y: bodyRect.minY + 1))
        pointer.close()
        ClaudePanelPalette.bottom.setFill()
        pointer.fill()

        NSGraphicsContext.current?.saveGraphicsState()
        NSShadow().set()
        ClaudePanelPalette.cyan.withAlphaComponent(0.82).setStroke()
        body.lineWidth = 1.25
        body.stroke()

        let pointerBorder = NSBezierPath()
        pointerBorder.move(to: NSPoint(x: centerX - 13, y: bodyRect.minY + 1))
        pointerBorder.line(to: NSPoint(x: centerX, y: 1))
        pointerBorder.line(to: NSPoint(x: centerX + 13, y: bodyRect.minY + 1))
        pointerBorder.lineWidth = 1.1
        pointerBorder.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

private final class ClaudeSeparatorView: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        ClaudePanelPalette.hairline.setFill()
        bounds.fill()
    }
}

private final class ClaudeSourceBadgeView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 17
        layer?.backgroundColor = ClaudePanelPalette.purple
            .withAlphaComponent(0.18)
            .cgColor
        layer?.borderColor = ClaudePanelPalette.purple
            .withAlphaComponent(0.78)
            .cgColor
        layer?.borderWidth = 1.2
        layer?.shadowColor = ClaudePanelPalette.purple.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 8
        layer?.shadowOffset = .zero

        let image = NSImageView()
        image.image = NSImage(
            systemSymbolName: "sparkles",
            accessibilityDescription: "Claude Code"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        )
        image.contentTintColor = ClaudePanelPalette.purple
        image.imageScaling = .scaleProportionallyDown
        image.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "Claude Code")
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = NSColor(
            calibratedRed: 0.82,
            green: 0.67,
            blue: 1,
            alpha: 1
        )
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(image)
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 150),
            heightAnchor.constraint(equalToConstant: 34),
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 21),
            image.heightAnchor.constraint(equalToConstant: 21),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class ClaudeCountBadgeView: NSView {
    init(count: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 17
        layer?.backgroundColor = ClaudePanelPalette.blue
            .withAlphaComponent(0.12)
            .cgColor
        layer?.borderColor = ClaudePanelPalette.cyan
            .withAlphaComponent(0.25)
            .cgColor
        layer?.borderWidth = 1

        let label = NSTextField(labelWithString: "\(max(1, count))")
        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        label.textColor = ClaudePanelPalette.cyan
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 34),
            heightAnchor.constraint(equalToConstant: 34),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private enum ClaudeActionButtonStyle {
    case plain
    case secondary
    case danger
    case primary
    case link
}

private final class ClaudeActionButton: NSButton {
    private let visualStyle: ClaudeActionButtonStyle
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private let symbolName: String?

    init(
        title: String,
        symbolName: String? = nil,
        style: ClaudeActionButtonStyle,
        target: AnyObject?,
        action: Selector?
    ) {
        visualStyle = style
        self.symbolName = symbolName
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        imagePosition = symbolName == nil ? .noImage : .imageLeading
        imageHugsTitle = true
        font = .systemFont(
            ofSize: style == .link ? 12 : 14,
            weight: style == .primary || style == .danger ? .semibold : .medium
        )
        wantsLayer = true
        layer?.cornerRadius = style == .link ? 0 : 12
        layer?.masksToBounds = false
        if let symbolName {
            image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: title
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: style == .link ? 10 : 12,
                    weight: .semibold
                )
            )
        }
        updateVisuals()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateVisuals()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateVisuals()
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        updateVisuals(isPressed: flag)
    }

    private func updateVisuals(isPressed: Bool = false) {
        let foreground: NSColor
        let background: NSColor
        let border: NSColor
        let borderWidth: CGFloat

        switch visualStyle {
        case .plain:
            foreground = isHovered
                ? ClaudePanelPalette.primaryText
                : ClaudePanelPalette.secondaryText
            background = isHovered
                ? NSColor.white.withAlphaComponent(0.055)
                : .clear
            border = .clear
            borderWidth = 0
        case .secondary:
            foreground = isHovered
                ? ClaudePanelPalette.primaryText
                : ClaudePanelPalette.secondaryText
            background = NSColor.white.withAlphaComponent(isHovered ? 0.08 : 0.035)
            border = ClaudePanelPalette.cyan.withAlphaComponent(isHovered ? 0.5 : 0.26)
            borderWidth = 1
        case .danger:
            foreground = ClaudePanelPalette.red
            background = ClaudePanelPalette.red.withAlphaComponent(isHovered ? 0.12 : 0.035)
            border = ClaudePanelPalette.red.withAlphaComponent(isHovered ? 0.95 : 0.8)
            borderWidth = 1.25
        case .primary:
            foreground = .white
            background = ClaudePanelPalette.blue.withAlphaComponent(
                isPressed ? 0.72 : (isHovered ? 1 : 0.88)
            )
            border = ClaudePanelPalette.brightCyan
            borderWidth = 1.4
        case .link:
            foreground = isHovered
                ? ClaudePanelPalette.cyan
                : ClaudePanelPalette.secondaryText
            background = .clear
            border = .clear
            borderWidth = 0
        }

        layer?.backgroundColor = background.cgColor
        layer?.borderColor = border.cgColor
        layer?.borderWidth = borderWidth
        if visualStyle == .primary {
            layer?.shadowColor = ClaudePanelPalette.cyan.cgColor
            layer?.shadowOpacity = isHovered ? 0.34 : 0.2
            layer?.shadowRadius = isHovered ? 12 : 8
            layer?.shadowOffset = .zero
        } else {
            layer?.shadowOpacity = 0
        }
        contentTintColor = foreground
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: font ?? NSFont.systemFont(ofSize: 14),
                .foregroundColor: foreground,
            ]
        )
    }
}

private final class ClaudeInsetCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.backgroundColor = ClaudePanelPalette.insetFill.cgColor
        layer?.borderColor = ClaudePanelPalette.cyan
            .withAlphaComponent(0.15)
            .cgColor
        layer?.borderWidth = 0.8
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class ClaudeToolIconView: NSView {
    init(symbolName: String, accessibilityDescription: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.035).cgColor
        layer?.borderColor = ClaudePanelPalette.secondaryText
            .withAlphaComponent(0.32)
            .cgColor
        layer?.borderWidth = 1

        let imageView = NSImageView()
        imageView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityDescription
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        )
        imageView.contentTintColor = ClaudePanelPalette.cyan
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 40),
            heightAnchor.constraint(equalToConstant: 40),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 23),
            imageView.heightAnchor.constraint(equalToConstant: 23),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class ClaudePermissionPanelController {
    private struct Entry {
        let prompt: ClaudePermissionPrompt
        let completion: (ClaudePermissionUserDecision) -> Void
    }

    private let anchorWindowProvider: () -> NSWindow?
    private let openTerminal: (ClaudePermissionPrompt) -> Void
    private var entries: [Entry] = []
    private var currentEntry: Entry?
    private var panel: ClaudePermissionPanel?
    private var promptController: ClaudePermissionPromptViewController?

    init(
        anchorWindowProvider: @escaping () -> NSWindow?,
        openTerminal: @escaping (ClaudePermissionPrompt) -> Void
    ) {
        self.anchorWindowProvider = anchorWindowProvider
        self.openTerminal = openTerminal
    }

    func enqueue(
        prompt: ClaudePermissionPrompt,
        completion: @escaping (ClaudePermissionUserDecision) -> Void
    ) {
        let alreadyQueued = currentEntry?.prompt.requestID == prompt.requestID
            || entries.contains(where: { $0.prompt.requestID == prompt.requestID })
        guard !alreadyQueued else { return }
        entries.append(Entry(prompt: prompt, completion: completion))
        showNextIfNeeded()
    }

    func expire(requestID: UUID) {
        if currentEntry?.prompt.requestID == requestID {
            currentEntry = nil
            hidePanel()
            showNextIfNeeded()
            return
        }
        entries.removeAll { $0.prompt.requestID == requestID }
    }

    func reposition() {
        guard let panel, panel.isVisible else { return }
        let anchorFrame = anchorWindowProvider()?.frame
        let screen = anchorWindowProvider()?.screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }

        let proposedX: CGFloat
        let proposedY: CGFloat
        if let anchorFrame {
            proposedX = anchorFrame.midX - panel.frame.width / 2
            proposedY = anchorFrame.minY
        } else {
            proposedX = visibleFrame.maxX - panel.frame.width - 24
            proposedY = visibleFrame.maxY - panel.frame.height - 24
        }
        let origin = NSPoint(
            x: min(
                max(proposedX, visibleFrame.minX + 8),
                visibleFrame.maxX - panel.frame.width - 8
            ),
            y: min(
                max(proposedY, visibleFrame.minY + 8),
                visibleFrame.maxY - panel.frame.height - 8
            )
        )
        panel.setFrameOrigin(origin)
    }

    func cancelAll() {
        let outstanding = ([currentEntry].compactMap { $0 } + entries)
        currentEntry = nil
        entries.removeAll()
        hidePanel()
        outstanding.forEach { $0.completion(.nativeFallback) }
    }

    private func showNextIfNeeded() {
        guard currentEntry == nil, !entries.isEmpty else { return }
        let entry = entries.removeFirst()
        currentEntry = entry

        let controller = ClaudePermissionPromptViewController(
            prompt: entry.prompt,
            queueCount: entries.count + 1
        )
        controller.onDecision = { [weak self] decision in
            self?.completeCurrent(with: decision)
        }
        promptController = controller

        let size = controller.preferredPanelSize
        let panel: ClaudePermissionPanel
        if let existing = self.panel {
            panel = existing
        } else {
            panel = ClaudePermissionPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
            panel.hidesOnDeactivate = false
            panel.isMovable = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            self.panel = panel
        }

        panel.setContentSize(size)
        panel.contentViewController = controller
        reposition()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func completeCurrent(with decision: ClaudePermissionUserDecision) {
        guard let entry = currentEntry else { return }
        currentEntry = nil
        if case .nativeFallback = decision {
            openTerminal(entry.prompt)
        }
        hidePanel()
        entry.completion(decision)
        showNextIfNeeded()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        panel?.contentViewController = nil
        promptController = nil
    }
}

private final class ClaudePermissionPromptViewController: NSViewController {
    var onDecision: ((ClaudePermissionUserDecision) -> Void)?

    let preferredPanelSize: NSSize

    private let prompt: ClaudePermissionPrompt
    private let queueCount: Int
    private var questionInputs: [ClaudeQuestionInput] = []
    private var currentQuestionIndex = 0
    private var questionPageIndicator: NSTextField?
    private var previousQuestionButton: NSButton?
    private var nextQuestionButton: NSButton?
    private var planFeedbackField: NSTextField?
    private var validationLabel: NSTextField?

    init(prompt: ClaudePermissionPrompt, queueCount: Int = 1) {
        self.prompt = prompt
        self.queueCount = queueCount
        switch prompt.interactionKind {
        case .toolApproval:
            preferredPanelSize = NSSize(
                width: claudePermissionPanelWidth,
                height: 304
            )
        case .askUserQuestion:
            preferredPanelSize = NSSize(
                width: claudePermissionPanelWidth,
                height: claudeQuestionPanelHeight(
                    questionCount: prompt.questions.count
                )
            )
        case .exitPlanMode:
            preferredPanelSize = NSSize(width: claudePermissionPanelWidth, height: 478)
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let chrome = ClaudePermissionChromeView()
        chrome.translatesAutoresizingMaskIntoConstraints = false

        let bodySurface = NSView()
        bodySurface.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(bodySurface)
        NSLayoutConstraint.activate([
            bodySurface.leadingAnchor.constraint(equalTo: chrome.leadingAnchor),
            bodySurface.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            bodySurface.topAnchor.constraint(equalTo: chrome.topAnchor),
            bodySurface.bottomAnchor.constraint(
                equalTo: chrome.bottomAnchor,
                constant: -claudePermissionPanelPointerHeight
            ),
        ])

        let header = makeHeader()
        let footer = makeFooter()
        let content = makeContent()
        bodySurface.addSubview(header)
        bodySurface.addSubview(content)
        bodySurface.addSubview(footer)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: bodySurface.leadingAnchor, constant: 26),
            header.trailingAnchor.constraint(equalTo: bodySurface.trailingAnchor, constant: -26),
            header.topAnchor.constraint(equalTo: bodySurface.topAnchor, constant: 19),
            header.heightAnchor.constraint(equalToConstant: 34),

            content.leadingAnchor.constraint(equalTo: bodySurface.leadingAnchor, constant: 27),
            content.trailingAnchor.constraint(equalTo: bodySurface.trailingAnchor, constant: -27),
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 17),
            content.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: -14),

            footer.leadingAnchor.constraint(equalTo: bodySurface.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: bodySurface.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bodySurface.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: footerHeight),
        ])

        self.view = chrome
    }

    private var footerHeight: CGFloat {
        switch prompt.interactionKind {
        case .toolApproval:
            return 82
        case .askUserQuestion, .exitPlanMode:
            return 74
        }
    }

    private var statusTitle: String {
        switch prompt.interactionKind {
        case .toolApproval:
            return "需要你的确认"
        case .askUserQuestion:
            return "需要你的回答"
        case .exitPlanMode:
            return "需要你审阅计划"
        }
    }

    private var headline: String {
        switch prompt.interactionKind {
        case .toolApproval:
            switch prompt.toolName.lowercased() {
            case "bash":
                return "允许 Claude 运行这个命令吗？"
            case "edit":
                return "允许 Claude 修改这个文件吗？"
            case "write":
                return "允许 Claude 写入这个文件吗？"
            case "webfetch", "websearch":
                return "允许 Claude 访问网络吗？"
            default:
                return "允许 Claude 使用 \(safeSingleLine(prompt.toolName)) 吗？"
            }
        case .askUserQuestion:
            if prompt.questions.count == 1 {
                return "Claude 有一个问题需要你回答"
            }
            return "Claude 有 \(prompt.questions.count) 个问题需要你回答"
        case .exitPlanMode:
            return "批准 Claude 的执行计划吗？"
        }
    }

    private func makeHeader() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let source = ClaudeSourceBadgeView()
        source.translatesAutoresizingMaskIntoConstraints = false

        let status = NSTextField(labelWithString: statusTitle)
        status.font = .systemFont(ofSize: 15, weight: .semibold)
        status.textColor = NSColor(
            calibratedRed: 0.75,
            green: 0.85,
            blue: 0.96,
            alpha: 1
        )
        status.alignment = .center
        status.translatesAutoresizingMaskIntoConstraints = false

        let leftDot = headerDot()
        let rightDot = headerDot()
        let statusRow = NSStackView(views: [leftDot, status, rightDot])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        let count = ClaudeCountBadgeView(count: queueCount)
        count.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(source)
        container.addSubview(statusRow)
        container.addSubview(count)
        NSLayoutConstraint.activate([
            source.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            source.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            statusRow.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            statusRow.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            statusRow.leadingAnchor.constraint(greaterThanOrEqualTo: source.trailingAnchor, constant: 8),
            statusRow.trailingAnchor.constraint(lessThanOrEqualTo: count.leadingAnchor, constant: -8),
            count.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            count.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func headerDot() -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 2
        dot.layer?.backgroundColor = ClaudePanelPalette.mutedText
            .withAlphaComponent(0.72)
            .cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 4),
            dot.heightAnchor.constraint(equalToConstant: 4),
        ])
        return dot
    }

    private func makeContent() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(wrappingLabelWithString: headline)
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        title.textColor = ClaudePanelPalette.primaryText
        title.maximumNumberOfLines = prompt.interactionKind == .askUserQuestion ? 2 : 1
        title.lineBreakMode = .byWordWrapping
        title.setContentCompressionResistancePriority(.required, for: .vertical)
        stack.addArrangedSubview(title)
        title.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        switch prompt.interactionKind {
        case .toolApproval:
            buildToolApproval(in: stack)
        case .askUserQuestion:
            buildQuestionForm(in: stack)
        case .exitPlanMode:
            buildPlanReview(in: stack)
        }
        return stack
    }

    private func buildToolApproval(in stack: NSStackView) {
        let message = multilineLabel(prompt.message, fontSize: 13)
        message.maximumNumberOfLines = 1
        message.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(message)
        message.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(10, after: message)

        let commandRow = NSStackView()
        commandRow.orientation = .horizontal
        commandRow.alignment = .centerY
        commandRow.spacing = 12

        let icon = ClaudeToolIconView(
            symbolName: toolSymbolName,
            accessibilityDescription: prompt.toolName
        )
        commandRow.addArrangedSubview(icon)

        let command = NSTextField(labelWithString: toolSummary)
        command.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
        command.textColor = ClaudePanelPalette.primaryText.withAlphaComponent(0.9)
        command.lineBreakMode = .byTruncatingMiddle
        command.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        commandRow.addArrangedSubview(command)

        let divider = ClaudeSeparatorView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = ClaudePanelPalette.hairline.cgColor
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 28),
        ])
        commandRow.addArrangedSubview(divider)

        let tool = NSTextField(labelWithString: safeSingleLine(prompt.toolName))
        tool.font = .systemFont(ofSize: 13, weight: .semibold)
        tool.textColor = ClaudePanelPalette.blue
        tool.setContentCompressionResistancePriority(.required, for: .horizontal)
        commandRow.addArrangedSubview(tool)
        stack.addArrangedSubview(commandRow)
        NSLayoutConstraint.activate([
            commandRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            commandRow.heightAnchor.constraint(equalToConstant: 40),
        ])

        let detailsTitle = prompt.suggestions.isEmpty
            ? "本次授权不会更改长期权限"
            : "查看权限详情"
        let details = ClaudeActionButton(
            title: detailsTitle,
            symbolName: prompt.suggestions.isEmpty ? "lock.shield" : "chevron.right",
            style: .link,
            target: self,
            action: prompt.suggestions.isEmpty ? nil : #selector(showPermissionDetails)
        )
        details.alignment = .left
        details.toolTip = prompt.suggestions.first?.title
        details.heightAnchor.constraint(equalToConstant: 20).isActive = true
        stack.addArrangedSubview(details)
    }

    private func buildQuestionForm(in stack: NSStackView) {
        let message = multilineLabel(prompt.message, fontSize: 12)
        message.maximumNumberOfLines = 1
        stack.addArrangedSubview(message)
        message.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(12, after: message)

        for question in prompt.questions {
            let input = ClaudeQuestionInput(question: question)
            questionInputs.append(input)
        }

        let previous = ClaudeActionButton(
            title: "上一题",
            symbolName: "chevron.left",
            style: .secondary,
            target: self,
            action: #selector(showPreviousQuestion)
        )
        previous.translatesAutoresizingMaskIntoConstraints = false
        previousQuestionButton = previous

        let indicator = NSTextField(labelWithString: "")
        indicator.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        indicator.textColor = ClaudePanelPalette.secondaryText
        indicator.alignment = .center
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.setContentHuggingPriority(.defaultLow, for: .horizontal)
        questionPageIndicator = indicator

        let next = ClaudeActionButton(
            title: "下一题",
            symbolName: "chevron.right",
            style: .secondary,
            target: self,
            action: #selector(showNextQuestion)
        )
        next.translatesAutoresizingMaskIntoConstraints = false
        nextQuestionButton = next

        let navigation = NSStackView(views: [previous, indicator, next])
        navigation.orientation = .horizontal
        navigation.alignment = .centerY
        navigation.spacing = 10
        stack.addArrangedSubview(navigation)
        NSLayoutConstraint.activate([
            navigation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            navigation.heightAnchor.constraint(equalToConstant: 32),
            previous.widthAnchor.constraint(equalToConstant: 112),
            previous.heightAnchor.constraint(equalToConstant: 30),
            next.widthAnchor.constraint(equalToConstant: 112),
            next.heightAnchor.constraint(equalToConstant: 30),
        ])
        stack.setCustomSpacing(9, after: navigation)

        let pageContainer = NSView()
        pageContainer.translatesAutoresizingMaskIntoConstraints = false
        for input in questionInputs {
            input.view.translatesAutoresizingMaskIntoConstraints = false
            input.view.isHidden = true
            pageContainer.addSubview(input.view)
            NSLayoutConstraint.activate([
                input.view.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
                input.view.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
                input.view.topAnchor.constraint(equalTo: pageContainer.topAnchor),
                input.view.bottomAnchor.constraint(
                    equalTo: pageContainer.bottomAnchor
                ),
            ])
        }
        stack.addArrangedSubview(pageContainer)
        NSLayoutConstraint.activate([
            pageContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pageContainer.heightAnchor.constraint(equalToConstant: 292),
        ])

        let validation = makeValidationLabel()
        validationLabel = validation
        stack.addArrangedSubview(validation)
        validation.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        showQuestionPage(at: 0)
    }

    @objc private func showPreviousQuestion() {
        hideValidation()
        showQuestionPage(at: currentQuestionIndex - 1)
    }

    @objc private func showNextQuestion() {
        hideValidation()
        showQuestionPage(at: currentQuestionIndex + 1)
    }

    fileprivate func showQuestionPage(at proposedIndex: Int) {
        currentQuestionIndex = clampedClaudeQuestionPageIndex(
            proposedIndex,
            count: questionInputs.count
        )
        for (index, input) in questionInputs.enumerated() {
            input.view.isHidden = index != currentQuestionIndex
        }

        let count = questionInputs.count
        questionPageIndicator?.stringValue = count == 0
            ? "暂无问题"
            : "问题 \(currentQuestionIndex + 1) / \(count)"
        let hasMultipleQuestions = count > 1
        previousQuestionButton?.isHidden = !hasMultipleQuestions
        nextQuestionButton?.isHidden = !hasMultipleQuestions
        previousQuestionButton?.isEnabled = currentQuestionIndex > 0
        nextQuestionButton?.isEnabled = currentQuestionIndex + 1 < count
        previousQuestionButton?.alphaValue = currentQuestionIndex > 0 ? 1 : 0.36
        nextQuestionButton?.alphaValue = currentQuestionIndex + 1 < count ? 1 : 0.36
    }

    private func buildPlanReview(in stack: NSStackView) {
        let message = multilineLabel(prompt.message, fontSize: 12)
        message.maximumNumberOfLines = 1
        stack.addArrangedSubview(message)
        message.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(10, after: message)

        let planText = prompt.planText ?? "Claude 已完成计划。完整计划可在终端中查看。"
        let planLabel = NSTextField(wrappingLabelWithString: planText)
        planLabel.isSelectable = true
        planLabel.font = .systemFont(ofSize: 12)
        planLabel.textColor = ClaudePanelPalette.primaryText.withAlphaComponent(0.86)
        planLabel.maximumNumberOfLines = 0
        planLabel.lineBreakMode = .byWordWrapping
        let planStack = NSStackView(views: [planLabel])
        planStack.orientation = .vertical
        planStack.alignment = .leading
        planLabel.widthAnchor.constraint(equalTo: planStack.widthAnchor).isActive = true
        let scroll = makeScrollView(contentStack: planStack, height: 176)
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(10, after: scroll)

        let feedback = NSTextField()
        styleTextField(feedback, placeholder: "需要调整？在这里告诉 Claude")
        planFeedbackField = feedback
        stack.addArrangedSubview(feedback)
        NSLayoutConstraint.activate([
            feedback.widthAnchor.constraint(equalTo: stack.widthAnchor),
            feedback.heightAnchor.constraint(equalToConstant: 34),
        ])

        let validation = makeValidationLabel()
        validationLabel = validation
        stack.addArrangedSubview(validation)
        validation.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func makeFooter() -> NSView {
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.wantsLayer = true
        footer.layer?.backgroundColor = NSColor(
            calibratedRed: 0.01,
            green: 0.055,
            blue: 0.11,
            alpha: 0.38
        ).cgColor

        let divider = ClaudeSeparatorView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(divider)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            divider.topAnchor.constraint(equalTo: footer.topAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
        ])

        let buttons: [NSButton]
        switch prompt.interactionKind {
        case .toolApproval:
            buttons = [
                footerButton(
                    title: "回到终端",
                    symbolName: "terminal",
                    style: .plain,
                    selector: #selector(useNativeFallback),
                    width: 150
                ),
                footerButton(
                    title: "拒绝",
                    symbolName: "xmark",
                    style: .danger,
                    selector: #selector(denyTool),
                    width: 126
                ),
                footerButton(
                    title: "允许一次",
                    symbolName: "checkmark",
                    style: .primary,
                    selector: #selector(allowOnce),
                    width: 196,
                    keyEquivalent: "\r"
                ),
            ]
        case .askUserQuestion:
            buttons = [
                footerButton(
                    title: "回到终端",
                    symbolName: "terminal",
                    style: .plain,
                    selector: #selector(useNativeFallback),
                    width: 170
                ),
                footerButton(
                    title: "提交回答",
                    symbolName: "paperplane.fill",
                    style: .primary,
                    selector: #selector(submitAnswers),
                    width: 250,
                    keyEquivalent: "\r"
                ),
            ]
        case .exitPlanMode:
            buttons = [
                footerButton(
                    title: "回到终端",
                    symbolName: "terminal",
                    style: .plain,
                    selector: #selector(useNativeFallback),
                    width: 140
                ),
                footerButton(
                    title: "让 Claude 修改",
                    symbolName: "arrow.uturn.backward",
                    style: .secondary,
                    selector: #selector(submitPlanFeedback),
                    width: 160
                ),
                footerButton(
                    title: "批准并继续",
                    symbolName: "checkmark",
                    style: .primary,
                    selector: #selector(allowOnce),
                    width: 180,
                    keyEquivalent: "\r"
                ),
            ]
        }

        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(row)

        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            row.topAnchor.constraint(equalTo: footer.topAnchor, constant: 13),
            row.heightAnchor.constraint(equalToConstant: 42),
        ])

        if prompt.interactionKind == .toolApproval {
            let helper = NSTextField(labelWithString: "仅允许本次操作")
            helper.font = .systemFont(ofSize: 10, weight: .medium)
            helper.textColor = ClaudePanelPalette.blue
            helper.alignment = .center
            helper.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(helper)
            NSLayoutConstraint.activate([
                helper.centerXAnchor.constraint(equalTo: buttons[2].centerXAnchor),
                helper.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 3),
            ])
        }

        return footer
    }

    private func footerButton(
        title: String,
        symbolName: String,
        style: ClaudeActionButtonStyle,
        selector: Selector,
        width: CGFloat,
        keyEquivalent: String = ""
    ) -> NSButton {
        let button = ClaudeActionButton(
            title: title,
            symbolName: symbolName,
            style: style,
            target: self,
            action: selector
        )
        button.keyEquivalent = keyEquivalent
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: width),
            button.heightAnchor.constraint(equalToConstant: 42),
        ])
        return button
    }

    private var toolSymbolName: String {
        switch prompt.toolName.lowercased() {
        case "bash":
            return "terminal"
        case "edit", "write":
            return "doc.badge.ellipsis"
        case "read":
            return "doc.text.magnifyingglass"
        case "webfetch", "websearch":
            return "network"
        default:
            return "lock.shield"
        }
    }

    private var toolSummary: String {
        let candidateKeys = [
            "command",
            "file_path",
            "path",
            "url",
            "query",
            "description",
        ]
        for key in candidateKeys {
            if let value = prompt.originalToolInput[key] as? String {
                let text = safeSingleLine(value)
                if !text.isEmpty {
                    return String(text.prefix(90))
                }
            }
        }
        return safeSingleLine(prompt.toolName)
    }

    private func multilineLabel(_ text: String, fontSize: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: fontSize)
        label.textColor = ClaudePanelPalette.secondaryText
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        return label
    }

    private func makeValidationLabel() -> NSTextField {
        let validation = NSTextField(labelWithString: "")
        validation.font = .systemFont(ofSize: 11, weight: .medium)
        validation.textColor = ClaudePanelPalette.red
        validation.isHidden = true
        return validation
    }

    private func styleTextField(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: ClaudePanelPalette.mutedText,
            ]
        )
        field.font = .systemFont(ofSize: 12)
        field.textColor = ClaudePanelPalette.primaryText
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = ClaudePanelPalette.insetFill
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.cornerRadius = 9
        field.layer?.borderColor = ClaudePanelPalette.cyan
            .withAlphaComponent(0.2)
            .cgColor
        field.layer?.borderWidth = 0.8
    }

    private func makeScrollView(contentStack: NSStackView, height: CGFloat) -> NSScrollView {
        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 5),
            contentStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -9),
            contentStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 6),
            contentStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -6),
        ])

        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = ClaudePanelPalette.insetFill
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 11
        scroll.layer?.borderColor = ClaudePanelPalette.cyan
            .withAlphaComponent(0.16)
            .cgColor
        scroll.layer?.borderWidth = 0.8
        scroll.heightAnchor.constraint(equalToConstant: max(100, height)).isActive = true
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        return scroll
    }

    private func safeSingleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    @objc private func allowOnce() {
        onDecision?(.allowOnce)
    }

    @objc private func denyTool() {
        onDecision?(.deny("用户在 ChatBird 中拒绝了这次操作"))
    }

    @objc private func useNativeFallback() {
        onDecision?(.nativeFallback)
    }

    @objc private func showPermissionDetails(_ sender: NSButton) {
        guard !prompt.suggestions.isEmpty else { return }
        let menu = NSMenu(title: "权限详情")
        menu.autoenablesItems = false
        for (index, suggestion) in prompt.suggestions.enumerated() {
            let detail = NSMenuItem(title: suggestion.title, action: nil, keyEquivalent: "")
            detail.isEnabled = false
            menu.addItem(detail)

            let apply = NSMenuItem(
                title: "应用这条长期允许",
                action: #selector(applySuggestionFromMenu),
                keyEquivalent: ""
            )
            apply.target = self
            apply.tag = index
            menu.addItem(apply)
            if index < prompt.suggestions.count - 1 {
                menu.addItem(.separator())
            }
        }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: sender.bounds.minX, y: sender.bounds.maxY + 3),
            in: sender
        )
    }

    @objc private func applySuggestionFromMenu(_ sender: NSMenuItem) {
        guard prompt.suggestions.indices.contains(sender.tag) else { return }
        onDecision?(.allowWithSuggestion(prompt.suggestions[sender.tag].rawValue))
    }

    @objc private func submitAnswers() {
        var answers: [String: Any] = [:]
        for (index, input) in questionInputs.enumerated() {
            guard let value = input.answerValue else {
                showQuestionPage(at: index)
                showValidation("请先回答第 \(index + 1) 题，或选择“回到终端”。")
                return
            }
            answers[input.question.answerKey] = value
        }
        hideValidation()
        onDecision?(.submitAnswers(answers))
    }

    @objc private func submitPlanFeedback() {
        let feedback = planFeedbackField?.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !feedback.isEmpty else {
            showValidation("请先填写希望 Claude 修改的内容。")
            return
        }
        hideValidation()
        onDecision?(.planFeedback(feedback))
    }

    private func showValidation(_ message: String) {
        validationLabel?.stringValue = message
        validationLabel?.isHidden = false
    }

    private func hideValidation() {
        validationLabel?.stringValue = ""
        validationLabel?.isHidden = true
    }
}

private final class ClaudeChoiceButton: NSButton {
    let optionIndex: Int
    let allowsMultipleSelection: Bool

    init(
        option: ClaudeQuestionOption,
        index: Int,
        allowsMultipleSelection: Bool,
        target: AnyObject,
        action: Selector
    ) {
        optionIndex = index
        self.allowsMultipleSelection = allowsMultipleSelection
        super.init(frame: .zero)
        title = option.label
        toolTip = option.detail
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        imagePosition = .imageLeading
        imageHugsTitle = true
        alignment = .left
        font = .systemFont(ofSize: 12, weight: .medium)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.8
        setSelected(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSelected(_ selected: Bool) {
        state = selected ? .on : .off
        let symbol: String
        if allowsMultipleSelection {
            symbol = selected ? "checkmark.square.fill" : "square"
        } else {
            symbol = selected ? "record.circle.fill" : "circle"
        }
        image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: selected ? "已选择" : "未选择"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        )
        let foreground = selected
            ? ClaudePanelPalette.primaryText
            : ClaudePanelPalette.secondaryText
        contentTintColor = selected ? ClaudePanelPalette.cyan : ClaudePanelPalette.mutedText
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: font ?? NSFont.systemFont(ofSize: 12),
                .foregroundColor: foreground,
            ]
        )
        layer?.backgroundColor = (
            selected
                ? ClaudePanelPalette.blue.withAlphaComponent(0.13)
                : NSColor.white.withAlphaComponent(0.025)
        ).cgColor
        layer?.borderColor = (
            selected
                ? ClaudePanelPalette.cyan.withAlphaComponent(0.5)
                : ClaudePanelPalette.cyan.withAlphaComponent(0.12)
        ).cgColor
    }
}

private final class ClaudeQuestionInput: NSObject {
    let question: ClaudeQuestion
    let view: NSView

    private var choiceButtons: [ClaudeChoiceButton] = []
    private let otherField = NSTextField()

    init(question: ClaudeQuestion) {
        self.question = question
        let card = ClaudeInsetCardView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -11),
        ])

        if let header = question.header {
            let headerLabel = NSTextField(labelWithString: header.uppercased())
            headerLabel.font = .systemFont(ofSize: 10, weight: .semibold)
            headerLabel.textColor = ClaudePanelPalette.cyan
            stack.addArrangedSubview(headerLabel)
        }

        let promptLabel = NSTextField(wrappingLabelWithString: question.answerKey)
        promptLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        promptLabel.textColor = ClaudePanelPalette.primaryText
        promptLabel.maximumNumberOfLines = 3
        stack.addArrangedSubview(promptLabel)
        promptLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        self.view = card
        super.init()

        for (index, option) in question.options.enumerated() {
            let button = ClaudeChoiceButton(
                option: option,
                index: index,
                allowsMultipleSelection: question.allowsMultipleSelection,
                target: self,
                action: #selector(toggleChoice)
            )
            button.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(button)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalTo: stack.widthAnchor),
                button.heightAnchor.constraint(equalToConstant: 28),
            ])
            choiceButtons.append(button)
        }

        let placeholder = question.options.isEmpty
            ? "输入你的回答"
            : "其他回答（填写后优先使用）"
        styleOtherField(placeholder: placeholder)
        stack.addArrangedSubview(otherField)
        NSLayoutConstraint.activate([
            otherField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            otherField.heightAnchor.constraint(equalToConstant: 76),
        ])
    }

    var answerValue: Any? {
        let custom = otherField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            return custom
        }
        let selections = zip(question.options, choiceButtons).compactMap { option, button in
            button.state == .on ? option.label : nil
        }
        if question.allowsMultipleSelection {
            return selections.isEmpty ? nil : selections.joined(separator: ", ")
        }
        return selections.first
    }

    @objc private func toggleChoice(_ sender: ClaudeChoiceButton) {
        if question.allowsMultipleSelection {
            sender.setSelected(sender.state != .on)
            return
        }
        for button in choiceButtons {
            button.setSelected(button === sender)
        }
    }

    private func styleOtherField(placeholder: String) {
        otherField.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: ClaudePanelPalette.mutedText,
            ]
        )
        otherField.font = .systemFont(ofSize: 11)
        otherField.textColor = ClaudePanelPalette.primaryText
        otherField.isBordered = false
        otherField.drawsBackground = true
        otherField.backgroundColor = NSColor.black.withAlphaComponent(0.16)
        otherField.focusRingType = .none
        otherField.maximumNumberOfLines = 3
        otherField.lineBreakMode = .byWordWrapping
        otherField.cell?.usesSingleLineMode = false
        otherField.cell?.wraps = true
        otherField.cell?.isScrollable = false
        otherField.wantsLayer = true
        otherField.layer?.cornerRadius = 7
        otherField.layer?.borderColor = ClaudePanelPalette.cyan
            .withAlphaComponent(0.15)
            .cgColor
        otherField.layer?.borderWidth = 0.7
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

func renderClaudePermissionPreview(kind: String, to outputURL: URL) throws {
    _ = NSApplication.shared
    let fixture: String
    switch kind {
    case "question", "question-second":
        fixture = """
        {
          "tool_name": "AskUserQuestion",
          "session_id": "12345678-1234-1234-1234-123456789abc",
          "cwd": "/tmp/chatbird",
          "tool_input": {
            "questions": [
              {
                "question": "你希望任务完成后生成哪种交付物？",
                "header": "交付方式",
                "options": [
                  {"label": "只提交代码", "description": "保留最小变更"},
                  {"label": "代码和说明", "description": "同时提供使用说明"}
                ],
                "multiSelect": false
              },
              {
                "question": "需要执行哪些验证？",
                "header": "验证",
                "options": [
                  {"label": "单元测试"},
                  {"label": "构建检查"}
                ],
                "multiSelect": true
              }
            ]
          }
        }
        """
    case "plan":
        fixture = """
        {
          "tool_name": "ExitPlanMode",
          "tool_input": {
            "plan": "1. 检查当前 Hook 配置和冲突。\\n2. 启动本地权限服务。\\n3. 为确认、提问和计划审查显示原生弹窗。\\n4. 完成构建与协议验证。"
          }
        }
        """
    default:
        fixture = """
        {
          "tool_name": "Bash",
          "tool_input": {
            "command": "swift test",
            "description": "用于确认当前修改没有破坏现有功能。"
          },
          "permission_suggestions": [{
            "type": "addRules",
            "rules": [{"toolName": "Bash", "ruleContent": "swift test"}]
          }]
        }
        """
    }

    let prompt = try ClaudePermissionProtocol.decodePrompt(from: Data(fixture.utf8))
    let controller = ClaudePermissionPromptViewController(prompt: prompt)
    let size = controller.preferredPanelSize
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isOpaque = false
    window.backgroundColor = .clear
    window.contentViewController = controller
    controller.view.frame = NSRect(origin: .zero, size: size)
    if kind == "question-second" {
        controller.showQuestionPage(at: 1)
    }
    controller.view.layoutSubtreeIfNeeded()
    window.displayIfNeeded()

    let scale: CGFloat = 2
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width * scale),
        pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(
            domain: "ChatBirdClaudeHook",
            code: 20,
            userInfo: [NSLocalizedDescriptionKey: "无法创建 Hook 预览画布"]
        )
    }
    bitmap.size = size
    controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(
            domain: "ChatBirdClaudeHook",
            code: 21,
            userInfo: [NSLocalizedDescriptionKey: "无法编码 Hook 预览"]
        )
    }
    try png.write(to: outputURL, options: .atomic)
}
