//
//  main.swift
//  ThreadHelm
//
//  模块职责：进程入口与命令行分发——一次性 CLI 操作（额度/配置打印、
//  overlay 通知准备与恢复、Claude Hook 管理、预览渲染、各项自测）在此
//  分发到对应模块；无任何旗标时启动 NSApplication 进入常驻面板模式。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

// Agent hooks are synchronous vendor callbacks. Handle them before AppKit is
// initialized, keep stdout empty, and always fail open even if ThreadHelm is
// stopped or its local endpoint is unhealthy.
if runAgentHookCommandIfRequested() {
    exit(0)
}

if let integrationExitCode = AgentIntegrationCLI.runIfRequested() {
    exit(integrationExitCode)
}

if let attentionFeedbackExitCode = runAgentAttentionFeedbackCLIIfRequested() {
    exit(Int32(attentionFeedbackExitCode))
}

if let agentTruthReplayExitCode = runAgentTruthReplayCLIIfRequested() {
    exit(Int32(agentTruthReplayExitCode))
}

if CommandLine.arguments.contains("--print-quota") {
    printQuotaOnce()
}

if CommandLine.arguments.contains("--print-claude-quota") {
    printClaudeQuotaOnce()
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

if CommandLine.arguments.contains("--suppress-native-activity-once") {
    suppressNativeActivityOnce()
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

// 受管集成的逻辑自测也挂在 --self-test-task-progress 上，但那条链会先跑
// 一批与集成无关的适配器自测；任何一条失败都会在集成自测之前 exit(1)。
// 这个独立入口保证集成契约始终可以被单独验证。
if CommandLine.arguments.contains("--self-test-agent-integration-manager") {
    runAgentIntegrationManagerSelfTest()
    print(
        "agent-integration-manager-self-test: lifecycle+backup+restore+rollback"
            + "+targeted-scope+targeted-rollback+version-gate+cli-boundary"
    )
    exit(0)
}

if CommandLine.arguments.contains("--self-test-threadhelm-edition") {
    runThreadHelmEditionSelfTest()
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
        let discovery = ClaudeCodeAgentAdapter().discover()
        guard discovery.compatibility == .validated else {
            print(discovery.isInstalled
                ? "Claude Code 版本未验证，已跳过 ThreadHelm Claude Hook"
                : "未找到 Claude CLI，已跳过 ThreadHelm Claude Hook")
            exit(0)
        }
        let changed = try ClaudeHookConfiguration.install(
            isClaudeAvailable: { true }
        )
        let status = try ClaudeHookConfiguration.status()
        switch classifyClaudeHookInstall(
            changed: changed,
            status: status,
            claudeAvailable: true
        ) {
        case .installed:
            print("ThreadHelm Claude Hook 已安装：\(ClaudeHookConstants.url)")
        case .alreadyInstalled:
            print("ThreadHelm Claude Hook 已经安装")
        case .skippedClaudeUnavailable:
            print("未找到 Claude CLI，已跳过 ThreadHelm Claude Hook")
        case .skippedConflict(let handlers):
            print(
                "已保留其他 PermissionRequest Hook，跳过 ThreadHelm Claude Hook："
                    + handlers.joined(separator: "；")
            )
        case .failedMissing:
            fputs("ThreadHelm Claude Hook 安装后仍未生效\n", stderr)
            exit(1)
        }
        exit(0)
    } catch {
        fputs("安装 ThreadHelm Claude Hook 失败：\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--uninstall-claude-hook") {
    do {
        let changed = try ClaudeHookConfiguration.uninstall()
        print(changed
            ? "ThreadHelm Claude Hook 已移除"
            : "没有找到 ThreadHelm Claude Hook")
        exit(0)
    } catch {
        fputs("移除 ThreadHelm Claude Hook 失败：\(error.localizedDescription)\n", stderr)
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
        fputs("读取 ThreadHelm Claude Hook 状态失败：\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--print-panel-config") {
    printPanelConfiguration()
}

if CommandLine.arguments.contains("--print-task-progress") {
    printTaskProgressOnce()
}

let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.run()
