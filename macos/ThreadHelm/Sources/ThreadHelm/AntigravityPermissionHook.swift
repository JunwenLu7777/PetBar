//
//  AntigravityPermissionHook.swift
//  ThreadHelm
//
//  模块职责：把 Antigravity CLI（agy）的 PreToolUse hook 接到 ThreadHelm
//  的审批闸门。
//
//  agy 的 hook 契约与另外几家都不同，三处差别决定了这里的写法：
//
//  1. 负载是 protojson 的 **camelCase**（conversationId / toolCall.name /
//     toolCall.args / workspacePaths），不是 Claude 那套 snake_case，
//     所以解析器不能复用 ClaudePermissionProtocol.decodePrompt。
//  2. 裁决体里 `{}` **等于拒绝**，不是「无意见」。实测：hook 回 `{}` 时
//     agy 打的是「tool call denied by pre-tool hook」。所以就地放行必须
//     显式写 `{"decision":"allow"}`，照搬 Cursor 那套返回 `{}` 透传会把
//     用户的每一次只读操作都拦死。
//  3. hook 失败是 **fail-closed**：命令非零退出时 agy 直接阻断工具并把
//     错误回给模型。这点和 ZCode 相反，闸门够不着时不需要我们自己伪造
//     一份拒绝——但也因此不能放任 hook 崩溃，否则用户会被锁在工具外面。
//     兜底统一走 `ask`，把决定权交回 agy 自己的权限流程。
//
//  基线：agy 1.1.22，契约由本机实测确定（见 AgentValidationProfile）。
//

import Foundation

enum AntigravityPermissionHookConstants {
    /// 与另外几家共用监听端口，靠路径区分来源。
    static let path = "/threadhelm/antigravity/permission"
    static let url = "http://\(ClaudeHookConstants.host):\(ClaudeHookConstants.port)\(path)"
    static let flag = "--antigravity-permission-hook"
    static let eventName = "PreToolUse"
    static let tokenFileName = ".threadhelm-permission-token"

    /// hooks.json 里的 timeout 字段，单位是**秒**。默认 30 秒，对人在
    /// 回路太短——这段时间里 agent 循环是整个卡住的。
    static let hookTimeoutSeconds = 600
    /// 自己的等待上限，比 agy 的上限早收手：由我们返回一份说得清的
    /// `ask`，好过让 agy 打出它自己的超时错误。
    static let requestTimeoutSeconds: TimeInterval = 570

    /// 闸门够不着时写回的裁决。agy 的三态里 `ask` 表示「交回你自己问
    /// 用户」，既不替用户放行，也不把他锁在工具外面。
    static let handBackOutput = #"{"decision":"ask"}"#
    /// 就地放行。必须显式 allow——见文件头第 2 条。
    static let passThroughOutput = #"{"decision":"allow"}"#

    /// hooks.json 的 matcher。全量经过 hook，再由下面的白名单在进程内
    /// 决定要不要打扰用户。
    ///
    /// 走的是「只读白名单放行、其余一律拦截」，与 Cursor 那边枚举高风险
    /// 工具的方向相反。agy 有 119 个步骤类型且还在增加，正向枚举漏掉一个
    /// 写操作就是闸门静默失效；反过来漏掉一个只读工具，最坏结果只是多弹
    /// 一次确认框。
    static let matcher = "*"

    /// 确定不改变任何状态的工具，就地放行不打扰用户。
    ///
    /// 判据是「跑一百次和跑零次对机器与外部世界没有区别」。浏览器的点击、
    /// 输入、执行 JS 都不在此列——它们能在页面上产生真实副作用。
    static let readOnlyToolNames: Set<String> = [
        "view_file",
        "view_file_outline",
        "view_code_item",
        "view_content_chunk",
        "read_notebook",
        "read_resource",
        "read_terminal",
        "read_url_content",
        "read_browser_page",
        "grep_search",
        "code_search",
        "internal_search",
        "tool_search",
        "trajectory_search",
        "search_web",
        "find",
        "find_all_references",
        "list_directory",
        "list_resources",
        "list_browser_pages",
        "conversation_history",
        "command_status",
        "findings",
        "retrieve_content",
        "retrieve_memory",
        "directory_rules",
        "knowledge_artifacts",
        "capture_browser_screenshot",
        "capture_browser_console_logs",
        "browser_get_dom",
        "browser_get_network_request",
        "browser_list_network_requests",
        "lint_diff",
    ]
}

/// agy 的用户级 customization root。
///
/// 刻意选 `antigravity-cli/` 而不是通用的 `config/`：两处实测都会被加载，
/// 但 `config/` 是跨产品的，装在那里 IDE 会话也会触发我们的 hook，而
/// ThreadHelm 这条线只认 CLI 会话——多出来的事件没有归属，只会变成噪音。
///
/// 与受管集成写入的位置一致：那条路径由 AgentIntegrationScope 决定，
/// 固定挂在 home 下，不看环境变量。
func antigravityConfigurationDirectoryURL(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
) -> URL {
    homeDirectory
        .appendingPathComponent(".gemini", isDirectory: true)
        .appendingPathComponent("antigravity-cli", isDirectory: true)
}

enum AntigravityHookConfigurationError: LocalizedError {
    case invalidConfiguration
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Antigravity hooks.json 不是有效的 JSON 对象"
        case .writeFailed(let reason):
            return "写入 Antigravity Hook 配置失败：\(reason)"
        }
    }
}

/// 把 agy 的 PreToolUse 负载解析成面板要展示的确认项。
///
/// 字段名全部走 camelCase，且工具参数在 `toolCall.args` 下——不是
/// Claude 的 `tool_input`。
enum AntigravityPermissionProtocol {
    static func decodePrompt(
        from body: Data
    ) throws -> ClaudePermissionPrompt {
        guard body.count <= ClaudeHookConstants.maximumBodyBytes,
              let object = try? JSONSerialization.jsonObject(with: body),
              let payload = object as? [String: Any]
        else {
            throw ClaudePermissionProtocolError.invalidJSON
        }

        let toolCall = payload["toolCall"] as? [String: Any] ?? [:]
        guard let rawToolName = toolCall["name"] as? String else {
            throw ClaudePermissionProtocolError
                .invalidPayload("缺少 toolCall.name")
        }
        let toolName = rawToolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !toolName.isEmpty else {
            throw ClaudePermissionProtocolError
                .invalidPayload("toolCall.name 为空")
        }

        let toolInput = toolCall["args"] as? [String: Any] ?? [:]
        let sessionID = boundedHookPayloadString(
            payload["conversationId"],
            maximum: 200
        )
        // 工作目录优先取工具自己声明的 Cwd：agy 的 run_command 允许逐次
        // 指定，与会话的 workspacePaths 可以不同，展示时要以真正会执行的
        // 那个为准。
        let workingDirectory = absoluteHookWorkingDirectory(
            toolInput["Cwd"] ?? (payload["workspacePaths"] as? [Any])?.first
        )
        // agy 把人类可读的动作摘要放在 args 里，比工具名本身好懂。
        let description = boundedHookPayloadString(
            toolInput["toolSummary"] ?? toolInput["toolAction"],
            maximum: 1_000
        )
        let presentation = ClaudePermissionProtocol.promptPresentation(
            kind: .toolApproval,
            toolName: toolName,
            description: description,
            agentID: .antigravity
        )

        return ClaudePermissionPrompt(
            requestID: UUID(),
            interactionKind: .toolApproval,
            toolName: toolName,
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            title: presentation.title,
            message: presentation.message,
            planText: nil,
            questions: [],
            originalToolInput: toolInput,
            suggestions: [],
            agentID: .antigravity
        )
    }

    /// 把用户裁决翻成 agy 的 PreToolUse 返回值。
    ///
    /// decision 是四态 allow/deny/ask/force_ask。`{}` 不是「无意见」而是
    /// 拒绝，所以每条分支都必须显式写出 decision。
    static func responseBody(
        for decision: ClaudePermissionUserDecision,
        prompt: ClaudePermissionPrompt
    ) -> Data? {
        var payload: [String: Any]
        switch decision {
        case .allowOnce:
            payload = ["decision": "allow"]
        case .allowWithSuggestion:
            // agy 的 permissionOverrides 收的是 `command(<target>)` 这类
            // 规则串，与我们这边的建议结构对不上。硬翻会写进一条用户没
            // 看过的长期授权，所以只落成「这次放行」。
            payload = ["decision": "allow"]
        case .deny(let message):
            payload = [
                "decision": "deny",
                "reason": boundedHookDecisionMessage(
                    message,
                    fallback: "用户拒绝了这次操作"
                ),
            ]
        case .planFeedback(let feedback):
            payload = [
                "decision": "deny",
                "reason": boundedHookDecisionMessage(
                    feedback,
                    fallback: "请修改计划后再次确认"
                ),
            ]
        case .submitAnswers(let answers):
            // agy 没有问题回答类的 hook 事件，走不到这里。真要走到，
            // 也只能把答案并回工具参数后放行，而不是静默丢弃。
            var updated = prompt.originalToolInput
            for (key, value) in answers {
                updated[key] = value
            }
            payload = [
                "decision": "allow",
                "overwrite": updated,
            ]
        case .nativeFallback:
            payload = ["decision": "ask"]
        }
        return try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        )
    }
}

/// 这次 PreToolUse 涉及的工具要不要人来把关。
///
/// 解析失败一律按「需要把关」处理：读不懂的负载可能是新工具，也可能是
/// 我们没跟上的格式变化，那时多问一次远好过默认放行。
func antigravityToolNameIsGuarded(
    in body: Data,
    readOnly: Set<String> = AntigravityPermissionHookConstants.readOnlyToolNames
) -> Bool {
    guard let object = try? JSONSerialization.jsonObject(with: body),
          let payload = object as? [String: Any],
          let toolCall = payload["toolCall"] as? [String: Any],
          let toolName = toolCall["name"] as? String
    else { return true }
    return !readOnly.contains(toolName)
}
