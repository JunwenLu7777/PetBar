//
//  main.swift
//  ChatBirdQuotaPanel
//
//  模块职责：进程入口与命令行分发——一次性 CLI 操作（额度/位置/配置打印、
//  overlay 通知准备与恢复、Claude Hook 管理、预览渲染、各项自测）在此
//  分发到对应模块；无任何旗标时启动 NSApplication 进入常驻面板模式。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

if CommandLine.arguments.contains("--print-quota") {
    printQuotaOnce()
}

if CommandLine.arguments.contains("--print-claude-quota") {
    printClaudeQuotaOnce()
}

if CommandLine.arguments.contains("--print-panel-location") {
    printPanelPlacementOnce()
}

if CommandLine.arguments.contains("--print-saved-panel-location") {
    printPanelPlacementOnce(savedStateOnly: true)
}

if CommandLine.arguments.contains("--prepare-codex-overlay-notifications") {
    prepareCodexOverlayNotifications()
}

if CommandLine.arguments.contains("--restore-codex-overlay-notifications") {
    restoreCodexOverlayNotifications()
}

if CommandLine.arguments.contains("--check-accessibility") {
    printAccessibilityStatus()
}

if let selectionFlag = CommandLine.arguments.firstIndex(of: "--select-chatbird") {
    let configURL: URL?
    if CommandLine.arguments.indices.contains(selectionFlag + 1),
       !CommandLine.arguments[selectionFlag + 1].hasPrefix("--")
    {
        configURL = URL(fileURLWithPath: CommandLine.arguments[selectionFlag + 1])
    } else {
        configURL = nil
    }
    selectChatBirdOnce(configURL: configURL)
}

if CommandLine.arguments.contains("--suppress-native-activity-once") {
    suppressNativeActivityOnce()
}

if CommandLine.arguments.contains("--self-test-placement") {
    runPlacementSelfTest()
}

if CommandLine.arguments.contains("--self-test-lifecycle") {
    runLifecycleSelfTest()
}

if CommandLine.arguments.contains("--self-test-native-notification-state") {
    runNativeNotificationStateSelfTest()
}

if CommandLine.arguments.contains("--self-test-task-progress") {
    runTaskProgressSelfTest()
}

if CommandLine.arguments.contains("--self-test-chatbird-edition") {
    runChatBirdEditionSelfTest()
}

if CommandLine.arguments.contains("--self-test-weekly-quota") {
    runWeeklyQuotaSelfTest()
}

if CommandLine.arguments.contains("--self-test-claude-quota") {
    runClaudeQuotaSelfTest()
}

if CommandLine.arguments.contains("--self-test-claude-hook") {
    runClaudeHookSelfTest()
}

if CommandLine.arguments.contains("--self-test-dynamic-island") {
    runDynamicIslandSelfTest()
}

if CommandLine.arguments.contains("--self-test-client-contract") {
    runClientContractSelfTest()
}

if let flag = CommandLine.arguments.firstIndex(
    of: "--render-dynamic-island-preview"
) {
    guard CommandLine.arguments.indices.contains(flag + 2) else {
        fputs(
            "用法：--render-dynamic-island-preview <state> <path>\n",
            stderr
        )
        exit(1)
    }
    let state = CommandLine.arguments[flag + 1]
    let outputURL = URL(
        fileURLWithPath: CommandLine.arguments[flag + 2]
    )
    do {
        try renderDynamicIslandPreview(state: state, to: outputURL)
        print(outputURL.path)
        exit(0)
    } catch {
        fputs(
            "写入灵动岛预览失败：\(error.localizedDescription)\n",
            stderr
        )
        exit(1)
    }
}

if CommandLine.arguments.contains("--install-claude-hook") {
    do {
        let claudeAvailable = locateClaudeExecutable() != nil
        let changed = try ClaudeHookConfiguration.install(
            isClaudeAvailable: { claudeAvailable }
        )
        let status = try ClaudeHookConfiguration.status()
        switch classifyClaudeHookInstall(
            changed: changed,
            status: status,
            claudeAvailable: claudeAvailable
        ) {
        case .installed:
            print("ChatBird Claude Hook 已安装：\(ClaudeHookConstants.url)")
        case .alreadyInstalled:
            print("ChatBird Claude Hook 已经安装")
        case .skippedClaudeUnavailable:
            print("未找到 Claude CLI，已跳过 ChatBird Claude Hook")
        case .skippedConflict(let handlers):
            print(
                "已保留其他 PermissionRequest Hook，跳过 ChatBird Claude Hook："
                    + handlers.joined(separator: "；")
            )
        case .failedMissing:
            fputs("ChatBird Claude Hook 安装后仍未生效\n", stderr)
            exit(1)
        }
        exit(0)
    } catch {
        fputs("安装 ChatBird Claude Hook 失败：\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--uninstall-claude-hook") {
    do {
        let changed = try ClaudeHookConfiguration.uninstall()
        print(changed
            ? "ChatBird Claude Hook 已移除"
            : "没有找到 ChatBird Claude Hook")
        exit(0)
    } catch {
        fputs("移除 ChatBird Claude Hook 失败：\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--print-claude-hook-status") {
    do {
        switch try ClaudeHookConfiguration.status() {
        case .installed:
            print("installed \(ClaudeHookConstants.url)")
        case .missing:
            print(locateClaudeExecutable() == nil ? "unavailable" : "missing")
        case .conflict(let handlers):
            print("conflict \(handlers.joined(separator: " | "))")
        }
        exit(0)
    } catch {
        fputs("读取 ChatBird Claude Hook 状态失败：\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--print-panel-config") {
    printPanelConfiguration()
}

if CommandLine.arguments.contains("--print-task-progress") {
    printTaskProgressOnce()
}

if let previewFlag = CommandLine.arguments.firstIndex(of: "--render-claude-hook-preview"),
   CommandLine.arguments.indices.contains(previewFlag + 2)
{
    let kind = CommandLine.arguments[previewFlag + 1]
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[previewFlag + 2])
    do {
        try renderClaudePermissionPreview(kind: kind, to: outputURL)
        print(outputURL.path)
        exit(0)
    } catch {
        fputs("写入 Claude Hook 预览失败：\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if let previewFlag = CommandLine.arguments.firstIndex(of: "--render-preview"),
   CommandLine.arguments.indices.contains(previewFlag + 1)
{
    renderPreviewOnce(to: CommandLine.arguments[previewFlag + 1])
}

let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.run()
