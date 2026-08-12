//
//  ClaudePermissionViews.swift
//  ThreadHelm
//
//  模块职责：Claude 权限面板的可复用视觉组件——尺寸常量、调色板、
//  无边框面板、镀铬背景、分隔线、来源/计数徽章、动作按钮、内嵌卡片
//  与工具图标。供 ClaudePermissionPanel.swift 与
//  ClaudePermissionQuestions.swift 使用。
//

import AppKit

// 面板宽度被提示页控制器（ClaudePermissionPanel.swift）读取，保持 internal。
let claudePermissionPanelWidth: CGFloat = 548
private let claudePermissionPanelCornerRadius: CGFloat = 20
// 指针高度同时被镀铬背景与提示页布局读取，保持 internal。
let claudePermissionPanelPointerHeight: CGFloat = 14

func claudeQuestionPanelHeight(questionCount _: Int) -> CGFloat {
    620
}

func clampedClaudeQuestionPageIndex(_ proposedIndex: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return min(max(0, proposedIndex), count - 1)
}

enum ClaudePanelPalette {
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

final class ClaudePermissionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ClaudePermissionChromeView: NSView {
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

final class ClaudeSeparatorView: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        ClaudePanelPalette.hairline.setFill()
        bounds.fill()
    }
}

final class ClaudeSourceBadgeView: NSView {
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

final class ClaudeCountBadgeView: NSView {
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

enum ClaudeActionButtonStyle {
    case plain
    case secondary
    case danger
    case primary
    case link
}

final class ClaudeActionButton: NSButton {
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

final class ClaudeInsetCardView: NSView {
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

final class ClaudeToolIconView: NSView {
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
