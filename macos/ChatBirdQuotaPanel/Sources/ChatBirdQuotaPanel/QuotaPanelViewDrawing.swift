//
//  QuotaPanelViewDrawing.swift
//  ChatBirdQuotaPanel
//
//  模块职责：QuotaPanelView 的绘制扩展——额度行/圆弧/供应商按钮/
//  重置卡片/刷新图标/任务行/滚动条等全部自定义绘制逻辑。被主类
//  draw(_:) 与符号同步调用的方法保持 internal，仅供扩展内部复用的
//  辅助方法保持 private。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

extension QuotaPanelView {
    func drawArcQuotaRow(_ row: QuotaRow, x: CGFloat, width: CGFloat) {
        let remaining = max(0, min(100, row.remainingPercent))
        let level = quotaLevel(for: remaining)
        drawText(
            row.name,
            in: NSRect(x: x, y: 47, width: width, height: 17),
            font: .systemFont(ofSize: 11, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.88),
            alignment: .center
        )
        drawQuotaArc(remaining: remaining, centerX: x + width / 2)
        drawText(
            "\(remaining)%",
            in: NSRect(x: x, y: 91, width: width, height: 35),
            font: .monospacedDigitSystemFont(ofSize: 29, weight: .bold),
            color: level == .exhausted
                ? quotaColor(for: .critical)
                : NSColor.white.withAlphaComponent(0.98),
            alignment: .center
        )

        if level == .exhausted {
            drawText(
                "额度已耗尽",
                in: NSRect(x: x, y: 124, width: width, height: 14),
                font: .systemFont(ofSize: 9.4, weight: .semibold),
                color: quotaColor(for: .critical),
                alignment: .center
            )
        }

        drawQuotaResetCard(in: NSRect(x: x + 1, y: 140, width: width - 2, height: 43))
    }

    private func drawQuotaResetCard(in rect: NSRect) {
        let presentation = codexResetCreditsPresentation(
            snapshot: codexResetCredits,
            now: currentDateProvider()
        )
        let card = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        NSColor.black.withAlphaComponent(0.16).setFill()
        card.fill()
        NSColor(
            calibratedRed: 0.28,
            green: 0.80,
            blue: 1,
            alpha: 0.16
        ).setStroke()
        card.lineWidth = 0.8
        card.stroke()

        drawText(
            "限额重置",
            in: NSRect(
                x: rect.minX + 8,
                y: rect.minY + 4,
                width: presentation.hasAvailableCredits
                    ? rect.width - 68
                    : rect.width - 16,
                height: 13
            ),
            font: .systemFont(ofSize: 8.0, weight: .semibold),
            color: NSColor(
                calibratedRed: 0.37,
                green: 0.88,
                blue: 1,
                alpha: 0.92
            )
        )
        drawText(
            presentation.availableText,
            in: NSRect(
                x: presentation.hasAvailableCredits
                    ? rect.maxX - 67
                    : rect.minX + 8,
                y: presentation.hasAvailableCredits
                    ? rect.minY + 4
                    : rect.minY + 22,
                width: presentation.hasAvailableCredits
                    ? 59
                    : rect.width - 16,
                height: 14
            ),
            font: .systemFont(
                ofSize: presentation.hasAvailableCredits ? 8.2 : 7.2,
                weight: .semibold
            ),
            color: NSColor.white.withAlphaComponent(
                presentation.hasAvailableCredits ? 0.88 : 0.58
            ),
            alignment: presentation.hasAvailableCredits ? .right : .center
        )
        guard presentation.hasAvailableCredits else { return }
        if let clock = NSImage(
            systemSymbolName: "clock",
            accessibilityDescription: "过期时间"
        ) {
            clock.draw(
                in: NSRect(x: rect.minX + 8, y: rect.minY + 21, width: 9, height: 9),
                from: .zero,
                operation: .sourceOver,
                fraction: 0.62,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        }
        for (index, line) in presentation.expiryLines.prefix(2).enumerated() {
            drawText(
                line,
                in: NSRect(
                    x: rect.minX + 20,
                    y: rect.minY + 18 + CGFloat(index) * 11,
                    width: rect.width - 28,
                    height: 11
                ),
                font: .monospacedDigitSystemFont(ofSize: 7.1, weight: .regular),
                color: NSColor.white.withAlphaComponent(0.58),
                alignment: .left
            )
        }
    }

    func drawCompactQuotaRows(
        _ rows: [QuotaRow],
        x: CGFloat,
        width: CGFloat
    ) {
        let now = currentDateProvider()
        let isDense = rows.count >= 3
        for (index, row) in rows.enumerated() {
            let remaining = max(0, min(100, row.remainingPercent))
            let level = quotaLevel(for: remaining)
            let top = CGFloat(
                (isDense ? 53 : 65) + index * (isDense ? 38 : 49)
            )
            let labelHeight: CGFloat = isDense ? 13 : 15
            let trackOffset: CGFloat = isDense ? 15 : 18
            let trackHeight: CGFloat = isDense ? 4 : 6
            let resetOffset: CGFloat = isDense ? 21 : 27
            let resetHeight: CGFloat = isDense ? 11 : 13
            drawText(
                row.name,
                in: NSRect(
                    x: x + 2,
                    y: top,
                    width: width - 50,
                    height: labelHeight
                ),
                font: .systemFont(
                    ofSize: isDense ? 9.4 : 10.2,
                    weight: .semibold
                ),
                color: NSColor.white.withAlphaComponent(0.84)
            )
            drawText(
                "\(remaining)%",
                in: NSRect(
                    x: x + width - 47,
                    y: top - 1,
                    width: 45,
                    height: isDense ? 14 : 16
                ),
                font: .monospacedDigitSystemFont(
                    ofSize: isDense ? 11.5 : 12.5,
                    weight: .bold
                ),
                color: level == .exhausted
                    ? quotaColor(for: .critical)
                    : NSColor.white.withAlphaComponent(0.97),
                alignment: .right
            )

            let trackRect = NSRect(
                x: x + 2,
                y: top + trackOffset,
                width: width - 4,
                height: trackHeight
            )
            let trackRadius = trackHeight / 2
            let track = NSBezierPath(
                roundedRect: trackRect,
                xRadius: trackRadius,
                yRadius: trackRadius
            )
            NSColor.white.withAlphaComponent(0.14).setFill()
            track.fill()
            if remaining > 0 {
                let fillRect = NSRect(
                    x: trackRect.minX,
                    y: trackRect.minY,
                    width: trackRect.width * CGFloat(remaining) / 100,
                    height: trackRect.height
                )
                let fill = NSBezierPath(
                    roundedRect: fillRect,
                    xRadius: trackRadius,
                    yRadius: trackRadius
                )
                quotaColor(for: level).setFill()
                fill.fill()
            }

            let resetText: String
            if let date = row.resetsAt {
                resetText = "\(quotaResetTimeDescription(date, now: now)) 重置"
            } else if row.resetDescription != nil {
                resetText = "重置时间以 Claude 为准"
            } else if level == .exhausted {
                resetText = "额度已耗尽"
            } else {
                resetText = "重置时间未知"
            }
            drawText(
                resetText,
                in: NSRect(
                    x: x + 2,
                    y: top + resetOffset,
                    width: width - 4,
                    height: resetHeight
                ),
                font: .systemFont(
                    ofSize: isDense ? 7.8 : 8.4,
                    weight: .regular
                ),
                color: level == .exhausted
                    ? quotaColor(for: .critical)
                    : NSColor.white.withAlphaComponent(0.58),
                alignment: .center
            )
        }
    }

    func drawQuotaProviderButtons(in bodyRect: NSRect) {
        for provider in availableQuotaProviders {
            let rect = quotaProviderButtonRect(for: provider, in: bodyRect)
            let isSelected = provider == selectedQuotaProvider
            let isHovered = provider == hoveredQuotaProvider
            let background = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            NSColor.white.withAlphaComponent(
                isSelected ? 0.16 : (isHovered ? 0.11 : 0.045)
            ).setFill()
            background.fill()
            let accent = taskSourceColor(for: provider == .codex ? .codex : .claudeCode)
            (isSelected
                ? accent.withAlphaComponent(0.58)
                : NSColor.white.withAlphaComponent(isHovered ? 0.22 : 0.10)
            ).setStroke()
            background.lineWidth = isSelected ? 1 : 0.75
            background.stroke()

            let iconRect = NSRect(
                x: rect.minX + 7,
                y: rect.minY + 5,
                width: 13,
                height: 13
            )
            drawProviderIcon(
                provider,
                in: iconRect,
                fraction: isSelected ? 0.98 : 0.62
            )
            let remainingText = providerRemainingPercents[provider]
                .map { "\($0)%" } ?? "--"
            let font = NSFont.monospacedDigitSystemFont(
                ofSize: 9.2,
                weight: isSelected ? .semibold : .medium
            )
            let textHeight = ceil(font.ascender - font.descender)
            drawText(
                "\(remainingText) · \(provider.summaryWindowName)",
                in: NSRect(
                    x: rect.minX,
                    y: floor(rect.midY - textHeight / 2),
                    width: rect.width,
                    height: textHeight
                ),
                font: font,
                color: NSColor.white.withAlphaComponent(isSelected ? 0.96 : 0.64),
                alignment: .center
            )
        }
    }

    private func drawProviderIcon(
        _ provider: QuotaProvider,
        in rect: NSRect,
        fraction: CGFloat
    ) {
        let image = providerIconImage(for: provider)
        image?.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: fraction,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    private func drawQuotaArc(remaining: Int, centerX: CGFloat) {
        let center = NSPoint(x: centerX, y: 128)
        let radius: CGFloat = 49
        let segments = 72

        let track = NSBezierPath()
        for index in 0...segments {
            let angle = .pi + .pi * CGFloat(index) / CGFloat(segments)
            let point = NSPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            if index == 0 { track.move(to: point) } else { track.line(to: point) }
        }
        NSColor.white.withAlphaComponent(0.15).setStroke()
        track.lineWidth = 7
        track.lineCapStyle = .round
        track.stroke()

        let visibleSegments = max(0, min(segments, Int(
            (CGFloat(remaining) / 100 * CGFloat(segments)).rounded()
        )))
        guard visibleSegments > 0 else { return }
        let levelColor = quotaColor(for: quotaLevel(for: remaining))
        for index in 0..<visibleSegments {
            let startProgress = CGFloat(index) / CGFloat(segments)
            let endProgress = CGFloat(index + 1) / CGFloat(segments)
            let startAngle = .pi + .pi * startProgress
            let endAngle = .pi + .pi * endProgress
            let path = NSBezierPath()
            path.move(to: NSPoint(
                x: center.x + cos(startAngle) * radius,
                y: center.y + sin(startAngle) * radius
            ))
            path.line(to: NSPoint(
                x: center.x + cos(endAngle) * radius,
                y: center.y + sin(endAngle) * radius
            ))
            levelColor.setStroke()
            path.lineWidth = 7
            path.lineCapStyle = .round
            path.stroke()
        }
    }

    private func quotaColor(for level: QuotaLevel) -> NSColor {
        switch level {
        case .healthy:
            return NSColor(
                calibratedRed: 0.27,
                green: 0.66,
                blue: 1.0,
                alpha: 1
            )
        case .warning:
            return NSColor(
                calibratedRed: 1.0,
                green: 0.73,
                blue: 0.20,
                alpha: 1
            )
        case .critical:
            return NSColor(
                calibratedRed: 1.0,
                green: 0.34,
                blue: 0.30,
                alpha: 1
            )
        case .exhausted:
            return NSColor.white.withAlphaComponent(0.26)
        }
    }

    func drawRefreshIcon(in rect: NSRect) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: center.y)
        transform.rotate(byDegrees: isQuotaRefreshing ? animationDegrees : 0)
        transform.translateX(by: -center.x, yBy: -center.y)
        transform.concat()
        drawText(
            "↻",
            in: NSRect(x: rect.minX, y: rect.minY - 1, width: rect.width, height: rect.height),
            font: .systemFont(ofSize: 12, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.72),
            alignment: .center
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    func drawTaskScrollbar(in bodyRect: NSRect) {
        guard taskProgress.isScrollable,
              taskProgress.items.count > maximumVisibleTaskRows
        else { return }

        let listRect = taskListRect(in: bodyRect)
        let trackRect = NSRect(
            x: listRect.maxX - 2,
            y: 57,
            width: 2,
            height: CGFloat(maximumVisibleTaskRows) * taskProgressRowHeight - 4
        )
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: 1, yRadius: 1)
        NSColor.white.withAlphaComponent(0.10).setFill()
        trackPath.fill()

        let visibleRatio = CGFloat(maximumVisibleTaskRows)
            / CGFloat(taskProgress.items.count)
        let thumbHeight = max(18, trackRect.height * visibleRatio)
        let maximumOffset = taskProgress.items.count - maximumVisibleTaskRows
        let offsetRatio = CGFloat(taskScrollOffset) / CGFloat(maximumOffset)
        let thumbRect = NSRect(
            x: trackRect.minX,
            y: trackRect.minY + (trackRect.height - thumbHeight) * offsetRatio,
            width: trackRect.width,
            height: thumbHeight
        )
        let thumbPath = NSBezierPath(roundedRect: thumbRect, xRadius: 1, yRadius: 1)
        NSColor.white.withAlphaComponent(0.46).setFill()
        thumbPath.fill()
    }

    func drawTaskProgressItem(
        _ item: TaskProgressItem,
        index: Int,
        rect: NSRect
    ) {
        let rowBackground = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        let isClickable = item.canOpen
        if hoveredTaskIndex == index, isClickable {
            NSColor.white.withAlphaComponent(0.12).setFill()
            rowBackground.fill()
            NSColor.white.withAlphaComponent(0.16).setStroke()
            rowBackground.lineWidth = 0.75
            rowBackground.stroke()
        } else if index.isMultiple(of: 2) {
            NSColor.white.withAlphaComponent(0.025).setFill()
            rowBackground.fill()
        }

        let sourceStrip = NSBezierPath(
            roundedRect: NSRect(
                x: rect.minX + 2,
                y: rect.minY + 6,
                width: 2.5,
                height: rect.height - 12
            ),
            xRadius: 1.25,
            yRadius: 1.25
        )
        taskSourceColor(for: item.source).setFill()
        sourceStrip.fill()

        let color = taskProgressColor(for: item.kind)
        drawText(
            item.title,
            in: NSRect(
                x: rect.minX + 28,
                y: rect.minY + 6,
                width: rect.width - 89,
                height: 15
            ),
            font: .systemFont(ofSize: 9.8, weight: index == 0 ? .semibold : .medium),
            color: NSColor.white.withAlphaComponent(isClickable ? 0.92 : 0.72)
        )
        drawText(
            item.statusText,
            in: NSRect(
                x: rect.maxX - 58,
                y: rect.minY + 6,
                width: 51,
                height: 15
            ),
            font: .systemFont(ofSize: 9.0, weight: .semibold),
            color: color,
            alignment: .right
        )
    }

    private func taskSourceColor(for source: TaskSource) -> NSColor {
        switch source {
        case .codex:
            return NSColor(
                calibratedRed: 0.25,
                green: 0.70,
                blue: 1.0,
                alpha: 0.92
            )
        case .claudeCode:
            return NSColor(
                calibratedRed: 0.75,
                green: 0.48,
                blue: 1.0,
                alpha: 0.94
            )
        }
    }

    func taskProgressColor(for kind: TaskProgressKind) -> NSColor {
        switch kind {
        case .reading:
            return NSColor.white.withAlphaComponent(0.56)
        case .running:
            return NSColor(calibratedRed: 0.22, green: 0.68, blue: 1.0, alpha: 1)
        case .waitingForInput:
            return NSColor(calibratedRed: 1.0, green: 0.70, blue: 0.22, alpha: 1)
        case .completed:
            return NSColor(calibratedRed: 0.24, green: 0.86, blue: 0.58, alpha: 1)
        case .failed:
            return NSColor(calibratedRed: 1.0, green: 0.36, blue: 0.30, alpha: 1)
        case .idle:
            return NSColor.white.withAlphaComponent(0.56)
        }
    }

    func drawText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
                .shadow: Self.textShadow,
            ]
        )
    }

    private static let textShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(
            calibratedRed: 0.0,
            green: 0.20,
            blue: 0.23,
            alpha: 0.84
        )
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: 1)
        return shadow
    }()
}
