//
//  PanelFoundation.swift
//  ChatBirdQuotaPanel
//
//  模块职责：全局常量、额度等级判定、重置时间格式化，以及面板尺寸与
//  宠物精灵几何等基础工具。原为 main.swift 顶部的基础设施区。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

let refreshInterval: TimeInterval = 60
let taskProgressRefreshInterval: TimeInterval = 2
let codexTaskProgressRescanInterval: TimeInterval = 5
let taskAnimationFramesPerSecond: TimeInterval = 8
let taskAnimationDegreesPerTick: CGFloat = 36
let panelVersion = "1.0.0"
let panelEdition = "chatbird-nt"
let chatBirdPetID = "chatbird-nt"
let chatBirdPetAvatarID = "custom:\(chatBirdPetID)"
// Track fast enough that the panel preserves its 14 px visual gap while the
// pet window is moving between animation positions.
let followInterval: TimeInterval = 0.03
let idlePetLocationPollInterval: TimeInterval = 0.20
let petMovementGraceInterval: TimeInterval = 0.50
let overlayStateRefreshInterval: TimeInterval = 0.25
let maximumStoredOverlayAspectDistortion: CGFloat = 0.15
let panelDefaultWindowLevel = NSWindow.Level.statusBar
let panelNativeActivityWindowLevel = NSWindow.Level(
    rawValue: NSWindow.Level.statusBar.rawValue + 1
)
let taskProgressRowHeight: CGFloat = 28
let maximumVisibleTaskRows = 5

enum QuotaLevel: Equatable {
    case healthy
    case warning
    case critical
    case exhausted
}

func quotaLevel(for remainingPercent: Int) -> QuotaLevel {
    switch max(0, min(100, remainingPercent)) {
    case 50...100:
        return .healthy
    case 20...49:
        return .warning
    case 1...19:
        return .critical
    default:
        return .exhausted
    }
}

let quotaResetClockFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = .current
    formatter.dateFormat = "HH:mm"
    return formatter
}()

let quotaResetCalendarFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = .current
    formatter.dateFormat = "M月d日 HH:mm"
    return formatter
}()

let quotaUpdateClockFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = .current
    formatter.dateFormat = "HH:mm"
    return formatter
}()

func quotaResetTimeDescription(
    _ date: Date,
    now: Date = Date()
) -> String {
    let calendar = Calendar.current
    if calendar.isDate(date, inSameDayAs: now) {
        return "今天 \(quotaResetClockFormatter.string(from: date))"
    }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
       calendar.isDate(date, inSameDayAs: tomorrow)
    {
        return "明天 \(quotaResetClockFormatter.string(from: date))"
    }
    return quotaResetCalendarFormatter.string(from: date)
}

func quotaSuccessStatusText(
    provider: QuotaProvider,
    rows: [QuotaRow],
    updatedAt: Date
) -> String {
    let refreshMinutes = max(1, Int(refreshInterval / 60))
    if provider == .codex,
       let resetAt = rows.first(where: {
           $0.name == provider.summaryRowName
       })?.resetsAt
    {
        return "\(quotaResetTimeDescription(resetAt, now: updatedAt)) 重置 · \(refreshMinutes)分钟"
    }
    return "\(quotaUpdateClockFormatter.string(from: updatedAt)) 更新 · \(refreshMinutes)分钟"
}

struct CodexResetCreditsPresentation: Equatable {
    let availableText: String
    let expiryLines: [String]
    let hasAvailableCredits: Bool
}

func codexResetCreditsPresentation(
    snapshot: CodexResetCreditsSnapshot?,
    now: Date = Date()
) -> CodexResetCreditsPresentation {
    guard let snapshot else {
        return CodexResetCreditsPresentation(
            availableText: "重置额度暂不可用",
            expiryLines: [],
            hasAvailableCredits: false
        )
    }
    let credits = snapshot.availableCredits(at: now)
    guard !credits.isEmpty else {
        return CodexResetCreditsPresentation(
            availableText: "暂无可用重置额度",
            expiryLines: [],
            hasAvailableCredits: false
        )
    }
    var expiryTexts = credits.prefix(4).map { credit in
        credit.expiresAt.map { quotaResetTimeDescription($0, now: now) } ?? "无过期时间"
    }
    if credits.count > expiryTexts.count {
        expiryTexts[expiryTexts.count - 1] = "+\(credits.count - expiryTexts.count + 1)"
    }
    let expiryLines: [String]
    if expiryTexts.count <= 2 {
        expiryLines = expiryTexts
    } else {
        expiryLines = [
            expiryTexts.prefix(2).joined(separator: " · "),
            expiryTexts.dropFirst(2).joined(separator: " · "),
        ]
    }
    return CodexResetCreditsPresentation(
        availableText: "\(credits.count) 次可用",
        expiryLines: expiryLines,
        hasAvailableCredits: true
    )
}

// A fixed landscape canvas keeps ChatBird compact above the pet while giving
// task titles enough horizontal room to remain useful and clickable.
let panelDesignWidth: CGFloat = 388
let baseExpandedPanelHeight: CGFloat = 226
func panelSizeForTaskRows(_ count: Int) -> NSSize {
    _ = max(1, min(maximumVisibleTaskRows, count))
    return NSSize(width: panelDesignWidth, height: baseExpandedPanelHeight)
}

func rectDiffers(
    _ lhs: NSRect,
    from rhs: NSRect,
    tolerance: CGFloat = 0.1
) -> Bool {
    abs(lhs.origin.x - rhs.origin.x) > tolerance
        || abs(lhs.origin.y - rhs.origin.y) > tolerance
        || abs(lhs.size.width - rhs.size.width) > tolerance
        || abs(lhs.size.height - rhs.size.height) > tolerance
}

func shouldPollPetLocation(
    now: CFAbsoluteTime,
    lastPollAt: CFAbsoluteTime,
    lastMovementAt: CFAbsoluteTime,
    force: Bool
) -> Bool {
    if force || lastPollAt <= 0 {
        return true
    }
    let recentlyMoving = lastMovementAt > 0
        && now - lastMovementAt <= petMovementGraceInterval
    let interval = recentlyMoving
        ? followInterval
        : idlePetLocationPollInterval
    return now - lastPollAt >= interval
}

let expandedPanelSize = panelSizeForTaskRows(1)
let panelPetGap: CGFloat = 14
let panelScreenMargin: CGFloat = 8
let pointerTipBottomInset: CGFloat = 1
let pointerHorizontalSafeInset: CGFloat = 18
let canonicalPetSpriteSize = NSSize(width: 163, height: 177)
let petAtlasFrameSize = NSSize(width: 192, height: 208)
// Alpha bounds (threshold 20) of every distinct visible frame in ChatBird's
// 8x11 v2 atlas. Matching both width and height lets us recover the zoom factor
// without mistaking animation-specific silhouette changes for a resize.
let petFrameVisiblePixelSizes: [NSSize] = [
    NSSize(width: 121, height: 190), NSSize(width: 121, height: 194),
    NSSize(width: 123, height: 187), NSSize(width: 125, height: 183),
    NSSize(width: 125, height: 191), NSSize(width: 126, height: 192),
    NSSize(width: 131, height: 183), NSSize(width: 132, height: 198),
    NSSize(width: 133, height: 182), NSSize(width: 133, height: 198),
    NSSize(width: 135, height: 183), NSSize(width: 135, height: 187),
    NSSize(width: 136, height: 188), NSSize(width: 136, height: 198),
    NSSize(width: 137, height: 179), NSSize(width: 137, height: 193),
    NSSize(width: 138, height: 175), NSSize(width: 141, height: 185),
    NSSize(width: 141, height: 198), NSSize(width: 142, height: 198),
    NSSize(width: 143, height: 198), NSSize(width: 144, height: 198),
    NSSize(width: 146, height: 198), NSSize(width: 147, height: 198),
    NSSize(width: 148, height: 198), NSSize(width: 149, height: 198),
    NSSize(width: 153, height: 198), NSSize(width: 155, height: 198),
    NSSize(width: 162, height: 198), NSSize(width: 163, height: 198),
    NSSize(width: 165, height: 198), NSSize(width: 167, height: 198),
    NSSize(width: 171, height: 198), NSSize(width: 175, height: 198),
    NSSize(width: 177, height: 198), NSSize(width: 180, height: 198),
    NSSize(width: 181, height: 198), NSSize(width: 182, height: 104),
    NSSize(width: 182, height: 144), NSSize(width: 182, height: 179),
    NSSize(width: 182, height: 183), NSSize(width: 182, height: 186),
    NSSize(width: 182, height: 196),
]
let visualScaleTolerance: CGFloat = 0.12
let minimumPanelScale: CGFloat = 0.20
let maximumPanelScale: CGFloat = 8
// Keep the information panel readable even when the pet sprite is displayed
// at its smaller default scale. 388×226 at 0.95 is about 369×215 points,
// matching the user-marked target region while remaining centered on the pet.
let minimumPresentedPanelScale: CGFloat = 0.95
// The v2 sprite has a small transparent top padding inside Codex's stored
// mascot anchor. Add it so the panel measures from ChatBird's visible tuft.
let petSpriteTopPaddingInsideAnchor: CGFloat = 7
