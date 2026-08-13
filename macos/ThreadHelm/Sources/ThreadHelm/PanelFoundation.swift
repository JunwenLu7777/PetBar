//
//  PanelFoundation.swift
//  ThreadHelm
//
//  模块职责：动态岛运行常量、额度等级判定与重置时间格式化。
//

import AppKit
import Foundation

let refreshInterval: TimeInterval = 60
let taskProgressRefreshInterval: TimeInterval = 2
let codexTaskProgressRescanInterval: TimeInterval = 5
let panelVersion = "1.1.0"
let panelEdition = "threadhelm"
let threadHelmProductID = "threadhelm"
let overlayStateRefreshInterval: TimeInterval = 0.25
let panelDefaultWindowLevel = NSWindow.Level.statusBar
let panelNativeActivityWindowLevel = NSWindow.Level(
    rawValue: NSWindow.Level.statusBar.rawValue + 1
)
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
        if snapshot.reportedAvailableCount > 0 {
            return CodexResetCreditsPresentation(
                availableText: "\(snapshot.reportedAvailableCount) 次可用",
                expiryLines: [],
                hasAvailableCredits: true
            )
        }
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
        availableText: "\(max(credits.count, snapshot.reportedAvailableCount)) 次可用",
        expiryLines: expiryLines,
        hasAvailableCredits: true
    )
}
