//
//  CursorPermissionHook.swift
//  ThreadHelm
//
//  模块职责：把 Cursor 的 preToolUse hook 接到 ThreadHelm 的审批闸门。
//
//  Cursor 没有对应 Claude PermissionRequest 的事件——它内部那张事件映射表
//  把 PermissionRequest 明确写成 null。能用的只有 preToolUse，而它与
//  PermissionRequest 有一处本质区别：PermissionRequest 是「agent 自己决定
//  要问用户」时才触发，preToolUse 是**每次工具调用**都触发。全量接上去会
//  把每个 Read、每个 Grep 都变成一个确认框。
//
//  所以这里只拦高风险工具。两道过滤：hooks.json 里的 matcher 做粗筛（省掉
//  绝大多数进程启动），hook 自己再判一次工具名。第二道不是冗余——matcher
//  是 `new RegExp(matcher).test(toolName)`，而 Cursor 对无效正则的处理是
//  「匹配所有」，粗筛失灵时只有第二道能保证我们不去拦只读操作。
//
//  基线：cursor-agent 2026.04.14-ee4b43a，契约取自其 hooks 模块实现。
//

import Foundation

enum CursorPermissionHookConstants {
    /// 与另外四家共用监听端口，靠路径区分来源。
    static let path = "/threadhelm/cursor/permission"
    static let url = "http://\(ClaudeHookConstants.host):\(ClaudeHookConstants.port)\(path)"
    static let flag = "--cursor-permission-hook"
    static let eventName = "preToolUse"
    static let tokenFileName = ".threadhelm-permission-token"

    /// hooks.json 里的 timeout 字段，单位是**秒**（Cursor 内部乘 1000）。
    /// 默认 60 秒，对人在回路太短。
    static let hookTimeoutSeconds = 600
    /// 扩展自己的等待上限，比 Cursor 的上限早收手：由我们返回一份说得清
    /// 的拒绝，好过让 Cursor 打出它自己的超时文案。
    static let requestTimeoutSeconds: TimeInterval = 570

    /// 需要人来把关的工具。名字用 Cursor 侧的叫法——它内部把 Claude 的
    /// Bash 映射成 Shell、Edit 和 Write 都映射成 Write。
    ///
    /// 只读类（Read / Grep / Glob / WebSearch / WebFetch）不拦：它们改不了
    /// 任何东西，而 preToolUse 每次调用都触发，拦它们只会把确认框变成噪音，
    /// 最终让用户对所有确认框脱敏——那比不拦更危险。
    static let guardedToolNames: Set<String> = ["Shell", "Write"]

    /// hooks.json 的 matcher。锚定写法，避免 `test()` 的子串语义把
    /// "WriteSomethingElse" 也匹配进来。
    static let matcher = "^(Shell|Write)$"
}

/// Cursor 的配置目录。与受管集成写入的位置一致——由 AgentIntegrationScope
/// 决定，固定挂在 home 下。
func cursorConfigurationDirectoryURL(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
) -> URL {
    homeDirectory.appendingPathComponent(".cursor", isDirectory: true)
}

/// 把用户裁决翻成 Cursor 的 preToolUse 返回值。
///
/// Cursor 的 permission 是三态 allow/deny/ask，还接受 updated_input 与
/// 分别给用户和模型的两段文字。多个 hook 的结果按「任一 deny 即 deny、
/// 其次 ask」合并，所以与观测 hook 并存是安全的。
enum CursorPermissionProtocol {
    static func responseBody(
        for decision: ClaudePermissionUserDecision,
        prompt: ClaudePermissionPrompt
    ) -> Data? {
        var payload: [String: Any]
        switch decision {
        case .allowOnce, .allowWithSuggestion:
            // Cursor 没有长期授权回执，建议只能落成「这次放行」。
            payload = ["permission": "allow"]
        case .deny(let message):
            let reason = boundedHookDecisionMessage(
                message,
                fallback: "用户拒绝了这次操作"
            )
            payload = [
                "permission": "deny",
                "agent_message": reason,
            ]
        case .planFeedback(let feedback):
            let reason = boundedHookDecisionMessage(
                feedback,
                fallback: "请修改计划后再次确认"
            )
            payload = [
                "permission": "deny",
                "agent_message": reason,
            ]
        case .submitAnswers(let answers):
            var updated = prompt.originalToolInput
            updated["answers"] = answers
            payload = [
                "permission": "allow",
                "updated_input": updated,
            ]
        case .nativeFallback:
            // Cursor 没有可回落的原生批准界面，但它有 ask：把决定权交回
            // Cursor 自己的权限流程，而不是替用户放行。
            payload = ["permission": "ask"]
        }
        return try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        )
    }
}

/// 从观测 hook 的命令里剥出可执行文件本身。
///
/// 观测命令的形状是 `"<可执行文件>" --agent-hook cursor`，审批命令绝不能
/// 沿用它：进程入口会先匹配 --agent-hook 并把这次调用当成观测事件处理，
/// 然后 exit(0)——审批转发一行都跑不到，闸门静默失效。
func cursorPermissionCommand(observationCommand: String) -> String {
    let executable: String
    if observationCommand.hasPrefix("\"") ,
       let closing = observationCommand.dropFirst().firstIndex(of: "\"")
    {
        executable = String(observationCommand[...closing])
    } else {
        executable = observationCommand
            .split(separator: " ", maxSplits: 1)
            .first
            .map(String.init) ?? observationCommand
    }
    return "\(executable) \(CursorPermissionHookConstants.flag)"
}
