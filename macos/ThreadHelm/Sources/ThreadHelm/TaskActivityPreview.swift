//
//  TaskActivityPreview.swift
//  ThreadHelm
//
//  模块职责：悬停运行中任务时展示的"正在处理"活动预览气泡
//  （无边框 NSPanel + 渐变内容视图 + 跟随锚点的控制器）。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

final class TaskActivityPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class TaskActivityPreviewView: NSView {
    static let bodyFont = NSFont.systemFont(ofSize: 10, weight: .regular)
    static let bodyLineSpacing: CGFloat = 1
    static let horizontalInset: CGFloat = 13
    static let bodyOriginY: CGFloat = 31
    static let bottomInset: CGFloat = 9

    var bodyText = "正在思考" {
        didSet {
            guard bodyText != oldValue else { return }
            needsDisplay = true
        }
    }

    var visibleBodyText: String {
        taskActivityVisibleTailText(
            from: bodyText,
            width: max(0, bounds.width - Self.horizontalInset * 2),
            font: Self.bodyFont,
            lineSpacing: Self.bodyLineSpacing,
            maximumLineCount: maximumTaskActivityLines
        )
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let background = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            xRadius: 12,
            yRadius: 12
        )
        if let gradient = NSGradient(
            starting: NSColor(
                calibratedRed: 0.055,
                green: 0.15,
                blue: 0.26,
                alpha: 0.98
            ),
            ending: NSColor(
                calibratedRed: 0.025,
                green: 0.075,
                blue: 0.14,
                alpha: 0.99
            )
        ) {
            gradient.draw(in: background, angle: -90)
        }
        NSColor(
            calibratedRed: 0.47,
            green: 0.86,
            blue: 1.0,
            alpha: 0.28
        ).setStroke()
        background.lineWidth = 1
        background.stroke()

        drawText(
            "Codex 正在处理",
            in: NSRect(x: 13, y: 10, width: bounds.width - 26, height: 17),
            font: .systemFont(ofSize: 11, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.94),
            lineBreakMode: .byTruncatingTail
        )
        drawText(
            visibleBodyText,
            in: NSRect(
                x: Self.horizontalInset,
                y: Self.bodyOriginY,
                width: bounds.width - Self.horizontalInset * 2,
                height: max(
                    0,
                    bounds.height - Self.bodyOriginY - Self.bottomInset
                )
            ),
            font: Self.bodyFont,
            color: NSColor.white.withAlphaComponent(0.72),
            lineBreakMode: .byCharWrapping
        )
    }

    private func drawText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        lineBreakMode: NSLineBreakMode
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreakMode
        paragraph.lineSpacing = 1
        (text as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )
    }
}

final class TaskActivityPreviewController {
    private let previewSize = NSSize(width: 360, height: 84)
    private let contentView: TaskActivityPreviewView
    private let panel: TaskActivityPreviewPanel
    private var presentedTaskKey: String?

    init() {
        contentView = TaskActivityPreviewView(
            frame: NSRect(origin: .zero, size: previewSize)
        )
        panel = TaskActivityPreviewPanel(
            contentRect: NSRect(origin: .zero, size: previewSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = contentView
        contentView.autoresizingMask = [.width, .height]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(
            rawValue: NSWindow.Level.statusBar.rawValue + 1
        )
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    var isVisible: Bool { panel.isVisible }
    var currentBody: String? {
        panel.isVisible ? contentView.visibleBodyText : nil
    }
    var currentPanelHeight: CGFloat { panel.frame.height }

    func show(
        item: TaskProgressItem,
        anchorRect: NSRect,
        visibleFrame: NSRect? = nil
    ) {
        guard let payload = taskActivityPreviewPayload(for: item) else {
            hide()
            return
        }
        presentedTaskKey = payload.taskKey
        contentView.bodyText = payload.body
        let resolvedVisibleFrame =
            visibleFrame ?? screenVisibleFrame(for: anchorRect)
        panel.setFrame(
            previewFrame(
                anchorRect: anchorRect,
                visibleFrame: resolvedVisibleFrame
            ),
            display: panel.isVisible
        )
        panel.orderFrontRegardless()
    }

    func update(item: TaskProgressItem) {
        guard let payload = taskActivityPreviewPayload(for: item),
              payload.taskKey == presentedTaskKey
        else {
            hide()
            return
        }
        contentView.bodyText = payload.body
    }

    func hide() {
        presentedTaskKey = nil
        panel.orderOut(nil)
    }

    private func screenVisibleFrame(for anchorRect: NSRect) -> NSRect {
        NSScreen.screens.first(where: {
            $0.frame.intersects(anchorRect)
        })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 800, height: 600)
    }

    private func previewFrame(
        anchorRect: NSRect,
        visibleFrame: NSRect
    ) -> NSRect {
        let margin: CGFloat = 8
        let proposedX = anchorRect.midX - previewSize.width / 2
        let maximumX = visibleFrame.maxX - previewSize.width - margin
        let x = max(
            visibleFrame.minX + margin,
            min(maximumX, proposedX)
        )
        let aboveY = anchorRect.maxY + margin
        let belowY = anchorRect.minY - previewSize.height - margin
        let proposedY = aboveY + previewSize.height <= visibleFrame.maxY - margin
            ? aboveY
            : belowY
        let maximumY = visibleFrame.maxY - previewSize.height - margin
        let y = max(
            visibleFrame.minY + margin,
            min(maximumY, proposedY)
        )
        return NSRect(origin: NSPoint(x: x, y: y), size: previewSize)
    }
}
