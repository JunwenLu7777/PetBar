import Foundation
import Darwin

enum ClaudeHookConstants {
    static let host = "127.0.0.1"
    static let port: UInt16 = 27_841
    static let path = "/chatbird/claude/permission"
    static let url = "http://\(host):\(port)\(path)"
    static let timeoutSeconds = 600
    static let requestTimeoutSeconds: TimeInterval = 590
    static let maximumBodyBytes = 256 * 1_024
}

enum ClaudePermissionInteractionKind {
    case toolApproval
    case askUserQuestion
    case exitPlanMode
}

struct ClaudeQuestionOption {
    let label: String
    let detail: String?
}

struct ClaudeQuestion {
    let answerKey: String
    let header: String?
    let options: [ClaudeQuestionOption]
    let allowsMultipleSelection: Bool
}

struct ClaudePermissionSuggestion {
    let title: String
    let rawValue: [String: Any]
}

struct ClaudePermissionPrompt {
    let requestID: UUID
    let interactionKind: ClaudePermissionInteractionKind
    let toolName: String
    let sessionID: String?
    let workingDirectory: String?
    let title: String
    let message: String
    let planText: String?
    let questions: [ClaudeQuestion]
    let originalToolInput: [String: Any]
    let suggestions: [ClaudePermissionSuggestion]
}

enum ClaudePermissionUserDecision {
    case allowOnce
    case allowWithSuggestion([String: Any])
    case deny(String)
    case submitAnswers([String: Any])
    case planFeedback(String)
    case nativeFallback
}

enum ClaudePermissionProtocolError: LocalizedError {
    case invalidJSON
    case invalidPayload(String)
    case unsupportedQuestionShape(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "请求不是有效的 JSON"
        case .invalidPayload(let reason):
            return "无效的 Claude 权限请求：\(reason)"
        case .unsupportedQuestionShape(let reason):
            return "无法安全呈现 Claude 问题：\(reason)"
        }
    }
}

enum ClaudePermissionProtocol {
    private static let maximumQuestions = 5
    private static let maximumOptionsPerQuestion = 5
    private static let maximumQuestionCharacters = 1_000
    private static let maximumOptionLabelCharacters = 200
    private static let maximumDescriptionCharacters = 1_000
    private static let maximumPlanCharacters = 8_000
    private static let maximumSuggestions = 20

    static func decodePrompt(from body: Data) throws -> ClaudePermissionPrompt {
        guard body.count <= ClaudeHookConstants.maximumBodyBytes,
              let object = try? JSONSerialization.jsonObject(with: body),
              let payload = object as? [String: Any]
        else {
            throw ClaudePermissionProtocolError.invalidJSON
        }

        guard let rawToolName = payload["tool_name"] as? String else {
            throw ClaudePermissionProtocolError.invalidPayload("缺少 tool_name")
        }
        let toolName = rawToolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !toolName.isEmpty else {
            throw ClaudePermissionProtocolError.invalidPayload("tool_name 为空")
        }

        let toolInput = payload["tool_input"] as? [String: Any] ?? [:]
        let normalizedToolName = toolName
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        let interactionKind: ClaudePermissionInteractionKind
        if normalizedToolName == "askuserquestion"
            || normalizedToolName == "askuserquestiontool"
        {
            interactionKind = .askUserQuestion
        } else if normalizedToolName == "exitplanmode"
            || normalizedToolName == "exitplanmodetool"
        {
            interactionKind = .exitPlanMode
        } else {
            interactionKind = .toolApproval
        }

        let sessionID = boundedString(payload["session_id"], maximum: 200)
        let workingDirectory = absoluteWorkingDirectory(
            payload["cwd"] ?? payload["working_directory"]
        )
        let suggestions = permissionSuggestions(from: payload["permission_suggestions"])
        let questions: [ClaudeQuestion]
        if interactionKind == .askUserQuestion {
            questions = try decodeQuestions(from: toolInput)
        } else {
            questions = []
        }

        let planText: String?
        if interactionKind == .exitPlanMode {
            planText = boundedString(
                toolInput["plan"] ?? toolInput["content"],
                maximum: maximumPlanCharacters
            )
        } else {
            planText = nil
        }

        let description = boundedString(
            toolInput["description"],
            maximum: maximumDescriptionCharacters
        )
        let presentation = promptPresentation(
            kind: interactionKind,
            toolName: toolName,
            description: description
        )

        return ClaudePermissionPrompt(
            requestID: UUID(),
            interactionKind: interactionKind,
            toolName: toolName,
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            title: presentation.title,
            message: presentation.message,
            planText: planText,
            questions: questions,
            originalToolInput: toolInput,
            suggestions: suggestions
        )
    }

    static func responseBody(
        for decision: ClaudePermissionUserDecision,
        prompt: ClaudePermissionPrompt
    ) -> Data? {
        if case .nativeFallback = decision {
            return nil
        }

        var wireDecision: [String: Any]
        switch decision {
        case .allowOnce:
            wireDecision = ["behavior": "allow"]
        case .allowWithSuggestion(let suggestion):
            wireDecision = [
                "behavior": "allow",
                "updatedPermissions": [suggestion],
            ]
        case .deny(let message):
            wireDecision = [
                "behavior": "deny",
                "message": boundedDecisionMessage(message, fallback: "用户拒绝了这次操作"),
            ]
        case .submitAnswers(let answers):
            var updatedInput = prompt.originalToolInput
            updatedInput["answers"] = answers
            wireDecision = [
                "behavior": "allow",
                "updatedInput": updatedInput,
            ]
        case .planFeedback(let feedback):
            wireDecision = [
                "behavior": "deny",
                "message": boundedDecisionMessage(feedback, fallback: "请修改计划后再次确认"),
            ]
        case .nativeFallback:
            return nil
        }

        let response: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": wireDecision,
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: response, options: [])
    }

    private static func decodeQuestions(from toolInput: [String: Any]) throws -> [ClaudeQuestion] {
        guard let rawQuestions = toolInput["questions"] as? [[String: Any]],
              !rawQuestions.isEmpty
        else {
            throw ClaudePermissionProtocolError.unsupportedQuestionShape("没有 questions")
        }
        guard rawQuestions.count <= maximumQuestions else {
            throw ClaudePermissionProtocolError.unsupportedQuestionShape(
                "问题数量超过 \(maximumQuestions)"
            )
        }

        var seenQuestions = Set<String>()
        return try rawQuestions.map { rawQuestion in
            guard let questionText = rawQuestion["question"] as? String,
                  !questionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  questionText.count <= maximumQuestionCharacters
            else {
                throw ClaudePermissionProtocolError.unsupportedQuestionShape(
                    "问题文本缺失或过长"
                )
            }
            guard seenQuestions.insert(questionText).inserted else {
                throw ClaudePermissionProtocolError.unsupportedQuestionShape("存在重复问题")
            }

            let rawOptions = rawQuestion["options"] as? [[String: Any]] ?? []
            guard rawOptions.count <= maximumOptionsPerQuestion else {
                throw ClaudePermissionProtocolError.unsupportedQuestionShape(
                    "单题选项超过 \(maximumOptionsPerQuestion)"
                )
            }

            var seenOptions = Set<String>()
            let options = try rawOptions.map { rawOption -> ClaudeQuestionOption in
                guard let label = rawOption["label"] as? String,
                      !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      label.count <= maximumOptionLabelCharacters
                else {
                    throw ClaudePermissionProtocolError.unsupportedQuestionShape(
                        "选项文本缺失或过长"
                    )
                }
                guard seenOptions.insert(label).inserted else {
                    throw ClaudePermissionProtocolError.unsupportedQuestionShape(
                        "同一问题存在重复选项"
                    )
                }
                return ClaudeQuestionOption(
                    label: label,
                    detail: boundedString(
                        rawOption["description"],
                        maximum: maximumDescriptionCharacters
                    )
                )
            }

            return ClaudeQuestion(
                answerKey: questionText,
                header: boundedString(rawQuestion["header"], maximum: 80),
                options: options,
                allowsMultipleSelection: rawQuestion["multiSelect"] as? Bool ?? false
            )
        }
    }

    private static func permissionSuggestions(from value: Any?) -> [ClaudePermissionSuggestion] {
        guard let rawSuggestions = value as? [[String: Any]] else { return [] }
        return rawSuggestions.prefix(maximumSuggestions).enumerated().map { index, suggestion in
            ClaudePermissionSuggestion(
                title: permissionSuggestionTitle(suggestion, index: index),
                rawValue: suggestion
            )
        }
    }

    private static func permissionSuggestionTitle(
        _ suggestion: [String: Any],
        index: Int
    ) -> String {
        let type = suggestion["type"] as? String
        if type == "setMode",
           let mode = boundedString(suggestion["mode"], maximum: 80)
        {
            return "切换为 \(mode) 模式"
        }
        if type == "addRules" {
            if let rules = suggestion["rules"] as? [[String: Any]],
               let first = rules.first
            {
                let toolName = boundedString(first["toolName"], maximum: 80)
                let rule = boundedString(first["ruleContent"], maximum: 120)
                if let toolName, let rule {
                    return "始终允许 \(toolName)：\(rule)"
                }
                if let toolName {
                    return "始终允许 \(toolName)"
                }
            }
            return "应用 Claude 建议的长期权限"
        }
        return "应用 Claude 权限建议 \(index + 1)"
    }

    private static func promptPresentation(
        kind: ClaudePermissionInteractionKind,
        toolName: String,
        description: String?
    ) -> (title: String, message: String) {
        switch kind {
        case .askUserQuestion:
            return (
                "Claude 等你回答",
                "回答后会直接返回当前 Claude Code 会话。"
            )
        case .exitPlanMode:
            return (
                "Claude 请求确认计划",
                "批准后 Claude 会离开计划模式并继续执行。"
            )
        case .toolApproval:
            let fallback = "Claude 请求使用 \(safeToolDisplayName(toolName))。"
            return (
                "Claude 等你确认",
                description ?? fallback
            )
        }
    }

    private static func safeToolDisplayName(_ toolName: String) -> String {
        let approvedNames: [String: String] = [
            "Bash": "终端命令",
            "Edit": "文件编辑",
            "Write": "文件写入",
            "Read": "文件读取",
            "WebFetch": "网页读取",
            "WebSearch": "网页搜索",
        ]
        if let displayName = approvedNames[toolName] {
            return displayName
        }
        let safe = toolName.filter {
            $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-"
        }
        return safe.isEmpty ? "受限工具" : safe
    }

    private static func absoluteWorkingDirectory(_ value: Any?) -> String? {
        guard let path = value as? String, path.hasPrefix("/") else { return nil }
        return String(path.prefix(4_096))
    }

    private static func boundedString(_ value: Any?, maximum: Int) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximum))
    }

    private static func boundedDecisionMessage(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? fallback : trimmed).prefix(2_000))
    }
}

enum ClaudeHookConfigurationError: LocalizedError {
    case invalidSettings
    case conflictingPermissionHooks([String])
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSettings:
            return "Claude settings.json 不是有效的 JSON 对象"
        case .conflictingPermissionHooks(let descriptions):
            return "发现其他 PermissionRequest Hook：\(descriptions.joined(separator: "；"))"
        case .writeFailed(let reason):
            return "写入 Claude Hook 配置失败：\(reason)"
        }
    }
}

enum ClaudeHookConfigurationStatus: Equatable {
    case installed
    case missing
    case conflict([String])
}

enum ClaudeHookConfiguration {
    static func defaultSettingsURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let configuredDirectory = environment["CLAUDE_CONFIG_DIR"],
           configuredDirectory.hasPrefix("/")
        {
            return URL(fileURLWithPath: configuredDirectory, isDirectory: true)
                .appendingPathComponent("settings.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    static func status(at settingsURL: URL = defaultSettingsURL()) throws
        -> ClaudeHookConfigurationStatus
    {
        let settings = try loadSettings(at: settingsURL)
        let handlers = permissionHandlers(in: settings)
        let conflicts = handlers.compactMap(conflictDescription)
        if !conflicts.isEmpty {
            return .conflict(conflicts)
        }
        if handlers.contains(where: isManagedHandler) {
            return .installed
        }
        return .missing
    }

    @discardableResult
    static func install(at settingsURL: URL = defaultSettingsURL()) throws -> Bool {
        var settings = try loadSettings(at: settingsURL)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var permissionEntries = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        let handlers = permissionHandlers(in: settings)

        let conflicts = handlers.compactMap(conflictDescription)
        guard conflicts.isEmpty else {
            throw ClaudeHookConfigurationError.conflictingPermissionHooks(conflicts)
        }
        if handlers.contains(where: isManagedHandler) {
            return false
        }

        permissionEntries.append([
            "matcher": "",
            "hooks": [[
                "type": "http",
                "url": ClaudeHookConstants.url,
                "timeout": ClaudeHookConstants.timeoutSeconds,
                "statusMessage": "等待 ChatBird 确认…",
            ]],
        ])
        hooks["PermissionRequest"] = permissionEntries
        settings["hooks"] = hooks
        try writeSettings(settings, to: settingsURL, makeBackup: true)
        return true
    }

    @discardableResult
    static func uninstall(at settingsURL: URL = defaultSettingsURL()) throws -> Bool {
        var settings = try loadSettings(at: settingsURL)
        guard var hooks = settings["hooks"] as? [String: Any],
              let rawEntries = hooks["PermissionRequest"] as? [[String: Any]]
        else {
            return false
        }

        var changed = false
        var remainingEntries: [[String: Any]] = []
        for var entry in rawEntries {
            if isManagedHandler(entry) {
                changed = true
                continue
            }
            if let nestedHandlers = entry["hooks"] as? [[String: Any]] {
                let filtered = nestedHandlers.filter { handler in
                    if isManagedHandler(handler) {
                        changed = true
                        return false
                    }
                    return true
                }
                if filtered.isEmpty {
                    if nestedHandlers.isEmpty {
                        remainingEntries.append(entry)
                    }
                    continue
                }
                entry["hooks"] = filtered
            }
            remainingEntries.append(entry)
        }

        guard changed else { return false }
        if remainingEntries.isEmpty {
            hooks.removeValue(forKey: "PermissionRequest")
        } else {
            hooks["PermissionRequest"] = remainingEntries
        }
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        try writeSettings(settings, to: settingsURL, makeBackup: true)
        return true
    }

    private static func loadSettings(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let settings = object as? [String: Any]
        else {
            throw ClaudeHookConfigurationError.invalidSettings
        }
        return settings
    }

    private static func permissionHandlers(in settings: [String: Any]) -> [[String: Any]] {
        guard let hooks = settings["hooks"] as? [String: Any],
              let entries = hooks["PermissionRequest"] as? [[String: Any]]
        else {
            return []
        }
        return entries.flatMap { entry in
            if let nested = entry["hooks"] as? [[String: Any]] {
                return nested
            }
            return [entry]
        }
    }

    private static func isManagedHandler(_ handler: [String: Any]) -> Bool {
        guard handler["type"] as? String == "http",
              let url = handler["url"] as? String
        else { return false }
        return url == ClaudeHookConstants.url
    }

    private static func conflictDescription(_ handler: [String: Any]) -> String? {
        if isManagedHandler(handler) { return nil }
        if let url = handler["url"] as? String {
            return "HTTP \(url)"
        }
        if let command = handler["command"] as? String {
            let compact = command
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return "命令 \(String(compact.prefix(120)))"
        }
        return "未知处理器"
    }

    private static func writeSettings(
        _ settings: [String: Any],
        to url: URL,
        makeBackup: Bool
    ) throws {
        do {
            let manager = FileManager.default
            try manager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if makeBackup, manager.fileExists(atPath: url.path) {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyyMMdd-HHmmss"
                let backupURL = url.deletingLastPathComponent().appendingPathComponent(
                    "\(url.lastPathComponent).chatbird-backup-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))"
                )
                try manager.copyItem(at: url, to: backupURL)
            }

            var data = try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            data.append(0x0A)
            let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
                ".\(url.lastPathComponent).chatbird-\(UUID().uuidString).tmp"
            )
            try data.write(to: temporaryURL, options: .atomic)
            try manager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporaryURL.path
            )
            guard rename(temporaryURL.path, url.path) == 0 else {
                let reason = String(cString: strerror(errno))
                try? manager.removeItem(at: temporaryURL)
                throw ClaudeHookConfigurationError.writeFailed(reason)
            }
        } catch let error as ClaudeHookConfigurationError {
            throw error
        } catch {
            throw ClaudeHookConfigurationError.writeFailed(error.localizedDescription)
        }
    }
}

func runClaudeHookSelfTest() -> Never {
    func fail(_ message: String) -> Never {
        fputs("claude-hook-self-test failed: \(message)\n", stderr)
        exit(1)
    }

    let questionFixture = """
    {
      "tool_name": "AskUserQuestion",
      "session_id": "12345678-1234-1234-1234-123456789abc",
      "cwd": "/tmp/chatbird",
      "tool_input": {
        "questions": [{
          "question": "选择输出格式",
          "header": "格式",
          "options": [
            {"label": "简洁", "description": "只给结论"},
            {"label": "详细", "description": "包含解释"}
          ],
          "multiSelect": false
        }]
      }
    }
    """
    guard let questionPrompt = try? ClaudePermissionProtocol.decodePrompt(
        from: Data(questionFixture.utf8)
    ), questionPrompt.interactionKind == .askUserQuestion,
       questionPrompt.questions.count == 1,
       questionPrompt.questions[0].answerKey == "选择输出格式",
       questionPrompt.questions[0].options.map(\.label) == ["简洁", "详细"],
       claudeQuestionPanelHeight(questionCount: 1) == 620,
       claudeQuestionPanelHeight(questionCount: 4) == 620,
       clampedClaudeQuestionPageIndex(-1, count: 3) == 0,
       clampedClaudeQuestionPageIndex(1, count: 3) == 1,
       clampedClaudeQuestionPageIndex(8, count: 3) == 2,
       clampedClaudeQuestionPageIndex(8, count: 0) == 0
    else {
        fail("AskUserQuestion 解析或分页布局")
    }

    guard let answerBody = ClaudePermissionProtocol.responseBody(
        for: .submitAnswers(["选择输出格式": "简洁"]),
        prompt: questionPrompt
    ), let answerJSON = try? JSONSerialization.jsonObject(with: answerBody) as? [String: Any],
       let hookOutput = answerJSON["hookSpecificOutput"] as? [String: Any],
       let answerDecision = hookOutput["decision"] as? [String: Any],
       answerDecision["behavior"] as? String == "allow",
       let updatedInput = answerDecision["updatedInput"] as? [String: Any],
       let answers = updatedInput["answers"] as? [String: String],
       answers["选择输出格式"] == "简洁"
    else {
        fail("AskUserQuestion 响应")
    }

    let planFixture = """
    {
      "tool_name": "ExitPlanMode",
      "tool_input": {"plan": "先检查，再修改，最后验证。"}
    }
    """
    guard let planPrompt = try? ClaudePermissionProtocol.decodePrompt(
        from: Data(planFixture.utf8)
    ), planPrompt.interactionKind == .exitPlanMode,
       planPrompt.planText == "先检查，再修改，最后验证。"
    else {
        fail("ExitPlanMode 解析")
    }

    let toolFixture = """
    {
      "tool_name": "Bash",
      "tool_input": {
        "command": "secret-command --token private",
        "description": "运行项目测试"
      },
      "permission_suggestions": [{
        "type": "addRules",
        "rules": [{"toolName": "Bash", "ruleContent": "npm test"}]
      }]
    }
    """
    guard let toolPrompt = try? ClaudePermissionProtocol.decodePrompt(
        from: Data(toolFixture.utf8)
    ), toolPrompt.interactionKind == .toolApproval,
       toolPrompt.message == "运行项目测试",
       !toolPrompt.message.contains("secret-command"),
       toolPrompt.suggestions.count == 1
    else {
        fail("普通权限解析或隐私边界")
    }

    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent(
        "chatbird-hook-self-test-\(UUID().uuidString)",
        isDirectory: true
    )
    let settingsURL = temporaryRoot.appendingPathComponent("settings.json")
    do {
        try manager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        try Data(#"{"model":"test"}"#.utf8).write(to: settingsURL)
        guard try ClaudeHookConfiguration.install(at: settingsURL) else {
            fail("配置安装没有产生修改")
        }
        guard try ClaudeHookConfiguration.status(at: settingsURL) == .installed else {
            fail("配置安装状态")
        }
        guard try !ClaudeHookConfiguration.install(at: settingsURL) else {
            fail("配置安装不具备幂等性")
        }
        guard try ClaudeHookConfiguration.uninstall(at: settingsURL) else {
            fail("配置卸载没有产生修改")
        }
        guard try ClaudeHookConfiguration.status(at: settingsURL) == .missing else {
            fail("配置卸载状态")
        }
        let finalData = try Data(contentsOf: settingsURL)
        guard let finalJSON = try JSONSerialization.jsonObject(with: finalData) as? [String: Any],
              finalJSON["model"] as? String == "test",
              finalJSON["hooks"] == nil
        else {
            fail("配置卸载破坏了其他字段")
        }
    } catch {
        fail(error.localizedDescription)
    }
    try? manager.removeItem(at: temporaryRoot)

    print("claude-hook-self-test: protocol=3/3; question-panel=620pt+paging; privacy=pass; config=install+idempotent+uninstall")
    exit(0)
}
