//
//  PanelCLI.swift
//  ThreadHelm
//
//  模块职责：命令行一次性操作——单次额度打印、运行配置打印、
//  Codex 原生气泡状态的准备与恢复、辅助功能状态检查、原生任务气泡
//  抑制。均由 main.swift 的 CLI 分发调用后退出进程。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

func printQuotaOnce() -> Never {
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 1
    CodexQuotaClient().fetch { result in
        switch result {
        case .success(let response):
            let snapshot = codexSnapshot(from: response)
            guard let window = weeklyRateLimitWindow(from: snapshot) else {
                fputs("Codex 暂未返回可确认的周额度\n", stderr)
                semaphore.signal()
                return
            }
            let remaining = max(0, 100 - window.usedPercent)
            print("codex-weekly: remaining=\(remaining)%")
            exitCode = 0
        case .failure(let error):
            fputs("\(error.localizedDescription)\n", stderr)
        }
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + 20) == .timedOut {
        fputs("读取额度超时\n", stderr)
    }
    exit(exitCode)
}

func printClaudeQuotaOnce() -> Never {
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 1
    ClaudeQuotaClient().fetch { result in
        switch result {
        case .success(let snapshot):
            let details = snapshot.rows.map {
                "\($0.name)=\($0.remainingPercent)%"
            }.joined(separator: " ")
            print("claude-quota: \(details)")
            exitCode = snapshot.rows.count >= 2 ? 0 : 1
        case .failure(let error):
            fputs("\(error.localizedDescription)\n", stderr)
        }
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + 30) == .timedOut {
        fputs("读取 Claude 额度超时\n", stderr)
    }
    exit(exitCode)
}

func printPanelConfiguration() -> Never {
    print(
        "panel-config: version=\(panelVersion) "
            + "edition=\(panelEdition) productID=\(threadHelmProductID) "
            + "presentation=dynamic-island "
            + "codexWeeklyQuotaOnly=true "
            + "claudeQuotaPeriods=5h,weekly,fable"
    )
    exit(0)
}

func printTaskProgressOnce() -> Never {
    let snapshot = CombinedTaskProgressReader().read()
    let details = snapshot.items.enumerated().map { index, item in
        "\(index + 1):\(item.title)[\(item.source.rawValue):\(item.kind.rawValue)]"
    }.joined(separator: " | ")
    print("task-progress: count=\(snapshot.items.count) \(details)")
    exit(0)
}

func prepareCodexOverlayNotifications() -> Never {
    guard let flagIndex = CommandLine.arguments.firstIndex(
        of: "--prepare-codex-overlay-notifications"
    ), CommandLine.arguments.count > flagIndex + 3
    else {
        fputs(
            "用法：--prepare-codex-overlay-notifications STATE SESSION_INDEX BACKUP\n",
            stderr
        )
        exit(2)
    }
    let stateURL = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
    let sessionIndexURL = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 2])
    let backupURL = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 3])
    if isCodexDesktopRunning() {
        print(
            "codex-overlay-notifications: deferred until Codex exits "
                + "(ThreadHelm will synchronize automatically)"
        )
        exit(0)
    }
    do {
        try CodexOverlayNotificationState.prepareFiles(
            stateURL: stateURL,
            sessionIndexURL: sessionIndexURL,
            backupURL: backupURL,
            canWrite: {
                !isCodexDesktopRunning()
            }
        )
        print("codex-overlay-notifications: prepared")
        exit(0)
    } catch {
        fputs("准备 Codex 原生气泡状态失败：\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

func restoreCodexOverlayNotifications() -> Never {
    guard let flagIndex = CommandLine.arguments.firstIndex(
        of: "--restore-codex-overlay-notifications"
    ), CommandLine.arguments.count > flagIndex + 2
    else {
        fputs("用法：--restore-codex-overlay-notifications STATE BACKUP\n", stderr)
        exit(2)
    }
    let stateURL = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
    let backupURL = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 2])
    if isCodexDesktopRunning() {
        fputs(
            "恢复 Codex 原生气泡状态前请先完全退出 Codex；恢复文件已保留。\n",
            stderr
        )
        exit(1)
    }
    do {
        try CodexOverlayNotificationState.restoreFiles(
            stateURL: stateURL,
            backupURL: backupURL,
            canWrite: {
                !isCodexDesktopRunning()
            }
        )
        print("codex-overlay-notifications: restored")
        exit(0)
    } catch {
        fputs("恢复 Codex 原生气泡状态失败：\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

func printAccessibilityStatus() -> Never {
    if AXIsProcessTrusted() {
        print("accessibility: authorized")
        exit(0)
    }
    fputs(
        "accessibility: required for hiding and muting Codex activity UI\n",
        stderr
    )
    exit(1)
}

func suppressNativeActivityOnce() -> Never {
    let result = NativeActivityPillSuppressor().suppressActivityPillsIfNeeded()
    switch result {
    case .badgeHidden:
        print("native-activity: badge hidden")
        exit(0)
    case .muted:
        print("native-activity: muted")
        exit(0)
    case .permissionRequired:
        fputs("native-activity: accessibility permission required\n", stderr)
    case .codexNotRunning:
        fputs("native-activity: Codex is not running\n", stderr)
    case .buttonNotFound:
        fputs("native-activity: notification button not found\n", stderr)
    case .actionFailed:
        fputs("native-activity: Mute task action failed\n", stderr)
    }
    exit(1)
}
