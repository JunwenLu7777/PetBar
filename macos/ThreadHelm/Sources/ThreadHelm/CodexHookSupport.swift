//
//  CodexHookSupport.swift
//  ThreadHelm
//
//  模块职责：把 Codex 的 PermissionRequest hook 接到 ThreadHelm 的审批闸门。
//  Codex 与 Claude 的裁决线协议同构，但 Codex 只支持 command 类型的 hook
//  （实测：type 只接受 command/mcp_tool/prompt/agent，没有 http），所以这里
//  额外提供一个把 stdin 转发到本地 HTTP 端点、再把裁决写回 stdout 的转发模式。
//
//  基线：codex-cli 0.150.1，本机实测。
//

import Foundation
import Security

enum CodexHookConstants {
    /// 与 Claude 共用同一个监听端口，靠路径区分来源。
    static let path = "/threadhelm/codex/permission"
    static let url = "http://\(ClaudeHookConstants.host):\(ClaudeHookConstants.port)\(path)"
    static let statusMessage = "等待 ThreadHelm 确认…"
    static let hookCommandFlag = "--codex-permission-hook"
    static let eventName = "PermissionRequest"
    /// Codex 对 command hook 未暴露可配的超时上限，实测 94.5 秒未被钳；
    /// 与 Claude 端对齐取 590 秒，让服务端的过期先于任何未知的平台上限。
    static let requestTimeoutSeconds: TimeInterval = 590
    static let tokenFileName = ".threadhelm-permission-token"
    /// hook 进程读 stdin 的上限。Codex 的 tool_input 可能含长命令，
    /// 留出与服务端 body 上限一致的余量。
    static let maximumInputBytes = ClaudeHookConstants.maximumBodyBytes
    /// 空裁决：Codex 收到后回落自己的原生批准 UI，而不是放行。
    static let noDecisionOutput = "{}"
}

// MARK: - 线协议

enum CodexPermissionProtocol {
    private static let maximumDescriptionCharacters = 1_000

    /// Codex 的 PermissionRequest payload 与 Claude 的字段名高度重合
    /// （tool_name / tool_input / session_id / cwd），差异在于 Codex 从不
    /// 携带 permission_suggestions，也没有 AskUserQuestion 与 ExitPlanMode。
    static func decodePrompt(from body: Data) throws -> ClaudePermissionPrompt {
        guard body.count <= ClaudeHookConstants.maximumBodyBytes,
              let object = try? JSONSerialization.jsonObject(with: body),
              let payload = object as? [String: Any]
        else {
            throw ClaudePermissionProtocolError.invalidJSON
        }

        guard let eventName = payload["hook_event_name"] as? String,
              eventName == CodexHookConstants.eventName
        else {
            throw ClaudePermissionProtocolError.invalidPayload(
                "hook_event_name 不是 PermissionRequest"
            )
        }

        guard let rawToolName = payload["tool_name"] as? String else {
            throw ClaudePermissionProtocolError.invalidPayload("缺少 tool_name")
        }
        let toolName = rawToolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !toolName.isEmpty else {
            throw ClaudePermissionProtocolError.invalidPayload("tool_name 为空")
        }

        let toolInput = payload["tool_input"] as? [String: Any] ?? [:]
        // Codex 让模型自己写一句面向人的说明，比工具名有用得多。
        let description = boundedString(
            toolInput["description"],
            maximum: maximumDescriptionCharacters
        )

        return ClaudePermissionPrompt(
            requestID: UUID(),
            interactionKind: .toolApproval,
            toolName: toolName,
            sessionID: boundedString(payload["session_id"], maximum: 200),
            workingDirectory: absoluteWorkingDirectory(payload["cwd"]),
            title: "Codex 等你确认",
            message: description ?? "Codex 请求使用 \(safeToolDisplayName(toolName))。",
            planText: nil,
            questions: [],
            originalToolInput: toolInput,
            suggestions: [],
            agentID: .codex
        )
    }

    /// 返回 nil 表示不给裁决——Codex 会回落到自己的原生批准 UI。
    static func responseBody(
        for decision: ClaudePermissionUserDecision
    ) -> Data? {
        let wireDecision: [String: Any]
        switch decision {
        case .allowOnce:
            wireDecision = ["behavior": "allow"]
        case .allowWithSuggestion:
            // Codex 对 updatedPermissions fail-closed，且从不发来 suggestion，
            // 所以这里不该出现。真出现时按最保守的读法处理：只放行这一次。
            wireDecision = ["behavior": "allow"]
        case .deny(let message):
            wireDecision = [
                "behavior": "deny",
                "message": boundedDecisionMessage(
                    message,
                    fallback: "用户拒绝了这次操作"
                ),
            ]
        case .planFeedback(let feedback):
            wireDecision = [
                "behavior": "deny",
                "message": boundedDecisionMessage(
                    feedback,
                    fallback: "请修改计划后再次确认"
                ),
            ]
        case .submitAnswers:
            // Codex 对 updatedInput fail-closed。发过去会让整次批准失败，
            // 不如交还原生 UI。
            return nil
        case .nativeFallback:
            return nil
        }

        let response: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": CodexHookConstants.eventName,
                "decision": wireDecision,
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: response, options: [])
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

    private static func boundedDecisionMessage(
        _ value: String,
        fallback: String
    ) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? fallback : trimmed).prefix(2_000))
    }
}

// MARK: - hooks.json 管理

enum CodexHookConfigurationError: LocalizedError {
    case invalidConfiguration
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Codex hooks.json 不是有效的 JSON 对象"
        case .writeFailed(let reason):
            return "写入 Codex Hook 配置失败：\(reason)"
        }
    }
}

enum CodexHookConfigurationStatus: Equatable {
    case installed
    case missing
    case conflict([String])
}

enum CodexHookConfiguration {
    /// 刻意不看 CODEX_HOME。受管集成经 AgentIntegrationScope 落盘，那条
    /// 路径永远是 `<home>/.codex`，与环境变量无关。读取端若跟着 CODEX_HOME
    /// 走就会与写入端错位：hook 进程继承的是 Codex 的环境，常驻面板由
    /// launchd 拉起、根本看不到那个变量，两边会读到不同的令牌文件，
    /// 结果是闸门 403 后静默回落——用户只会觉得「确认框不弹了」。
    static func defaultHooksURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("hooks.json")
    }

    static func status(
        at hooksURL: URL = defaultHooksURL()
    ) throws -> CodexHookConfigurationStatus {
        let configuration = try loadConfiguration(at: hooksURL)
        let handlers = permissionHandlers(in: configuration)
        let conflicts = handlers.compactMap(conflictDescription)
        if !conflicts.isEmpty {
            return .conflict(conflicts)
        }
        if handlers.contains(where: isOwnedManagedHandler) {
            return .installed
        }
        return .missing
    }

    @discardableResult
    static func install(
        at hooksURL: URL = defaultHooksURL(),
        hookCommand: String? = codexHookCommand(),
        isCodexAvailable: () -> Bool = { locateCodexExecutable() != nil }
    ) throws -> Bool {
        guard isCodexAvailable(), let hookCommand else { return false }

        var configuration = try loadConfiguration(at: hooksURL)
        var hooks = configuration["hooks"] as? [String: Any] ?? [:]
        var entries = hooks[CodexHookConstants.eventName] as? [[String: Any]] ?? []
        let handlers = permissionHandlers(in: configuration)

        guard handlers.compactMap(conflictDescription).isEmpty else {
            return false
        }

        let desiredHandler: [String: Any] = [
            "type": "command",
            "command": hookCommand,
            "statusMessage": CodexHookConstants.statusMessage,
        ]

        if entries.contains(where: entryContainsOwnedManagedHandler) {
            let upgraded = entries.map {
                upgradedEntry($0, handler: desiredHandler)
            }
            guard !entriesAreEquivalent(upgraded, entries) else { return false }
            entries = upgraded
        } else {
            entries.append([
                "matcher": "",
                "hooks": [desiredHandler],
            ])
        }

        hooks[CodexHookConstants.eventName] = entries
        configuration["hooks"] = hooks
        // 令牌必须先于配置落盘：hook 进程一旦被 Codex 拉起就会立刻去读它。
        try writeAuthenticationToken(makeAuthenticationToken(), for: hooksURL)
        try writeConfiguration(configuration, to: hooksURL, makeBackup: true)
        return true
    }

    @discardableResult
    static func uninstall(at hooksURL: URL = defaultHooksURL()) throws -> Bool {
        var configuration = try loadConfiguration(at: hooksURL)
        guard var hooks = configuration["hooks"] as? [String: Any],
              let rawEntries = hooks[CodexHookConstants.eventName] as? [[String: Any]]
        else {
            return false
        }

        var changed = false
        var remainingEntries: [[String: Any]] = []
        for var entry in rawEntries {
            if isOwnedManagedHandler(entry) {
                changed = true
                continue
            }
            if let nested = entry["hooks"] as? [[String: Any]] {
                let filtered = nested.filter { handler in
                    if isOwnedManagedHandler(handler) {
                        changed = true
                        return false
                    }
                    return true
                }
                if filtered.isEmpty {
                    if nested.isEmpty {
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
            hooks.removeValue(forKey: CodexHookConstants.eventName)
        } else {
            hooks[CodexHookConstants.eventName] = remainingEntries
        }
        if hooks.isEmpty {
            configuration.removeValue(forKey: "hooks")
        } else {
            configuration["hooks"] = hooks
        }
        try writeConfiguration(configuration, to: hooksURL, makeBackup: true)
        removeAuthenticationToken(for: hooksURL)
        return true
    }

    // MARK: 令牌

    static func authenticationTokenURL(
        for hooksURL: URL = defaultHooksURL()
    ) -> URL {
        hooksURL
            .deletingLastPathComponent()
            .appendingPathComponent(CodexHookConstants.tokenFileName)
    }

    /// 只接受 owner-only 的普通文件。放宽这条等于让任何本机进程
    /// 都能改令牌，从而向闸门伪造裁决请求。
    static func authenticationToken(
        for hooksURL: URL = defaultHooksURL()
    ) -> String? {
        let url = authenticationTokenURL(for: hooksURL)
        var statBuffer = stat()
        guard lstat(url.path, &statBuffer) == 0,
              statBuffer.st_uid == geteuid(),
              (statBuffer.st_mode & S_IFMT) == S_IFREG,
              (statBuffer.st_mode & S_IRWXG) == 0,
              (statBuffer.st_mode & S_IRWXO) == 0,
              let data = try? Data(contentsOf: url),
              data.count <= 512,
              let token = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { return nil }
        return token
    }

    private static func writeAuthenticationToken(
        _ token: String,
        for hooksURL: URL
    ) throws {
        let url = authenticationTokenURL(for: hooksURL)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(token.utf8).write(to: url, options: .atomic)
            guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
                throw CodexHookConfigurationError.writeFailed("无法收紧令牌文件权限")
            }
        } catch let error as CodexHookConfigurationError {
            throw error
        } catch {
            throw CodexHookConfigurationError.writeFailed(error.localizedDescription)
        }
    }

    private static func removeAuthenticationToken(for hooksURL: URL) {
        try? FileManager.default.removeItem(at: authenticationTokenURL(for: hooksURL))
    }

    private static func makeAuthenticationToken() -> String {
        AgentPermissionTokenFactory.make()
    }

    // MARK: 处理器识别

    private static func loadConfiguration(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let configuration = object as? [String: Any]
        else {
            throw CodexHookConfigurationError.invalidConfiguration
        }
        return configuration
    }

    private static func permissionHandlers(
        in configuration: [String: Any]
    ) -> [[String: Any]] {
        guard let hooks = configuration["hooks"] as? [String: Any],
              let entries = hooks[CodexHookConstants.eventName] as? [[String: Any]]
        else {
            return []
        }
        return entries.flatMap { entry -> [[String: Any]] in
            if let nested = entry["hooks"] as? [[String: Any]] {
                return nested
            }
            return [entry]
        }
    }

    /// 认自家 handler 靠命令里的 flag，而不是完整路径：ThreadHelm.app
    /// 可能被搬走或重装到别的位置，路径一变就会把自己的旧 handler
    /// 误判成第三方冲突，进而拒绝安装。
    private static func isOwnedManagedHandler(_ handler: [String: Any]) -> Bool {
        guard handler["type"] as? String == "command",
              let command = handler["command"] as? String
        else { return false }
        return command.contains(CodexHookConstants.hookCommandFlag)
    }

    private static func entryContainsOwnedManagedHandler(
        _ entry: [String: Any]
    ) -> Bool {
        if isOwnedManagedHandler(entry) { return true }
        guard let nested = entry["hooks"] as? [[String: Any]] else { return false }
        return nested.contains(where: isOwnedManagedHandler)
    }

    private static func upgradedEntry(
        _ entry: [String: Any],
        handler desired: [String: Any]
    ) -> [String: Any] {
        if isOwnedManagedHandler(entry) { return desired }
        guard let nested = entry["hooks"] as? [[String: Any]] else { return entry }
        var updated = entry
        updated["hooks"] = nested.map { isOwnedManagedHandler($0) ? desired : $0 }
        return updated
    }

    private static func entriesAreEquivalent(
        _ lhs: [[String: Any]],
        _ rhs: [[String: Any]]
    ) -> Bool {
        guard let lhsData = try? JSONSerialization.data(
            withJSONObject: lhs,
            options: [.sortedKeys]
        ),
        let rhsData = try? JSONSerialization.data(
            withJSONObject: rhs,
            options: [.sortedKeys]
        ) else { return false }
        return lhsData == rhsData
    }

    private static func conflictDescription(_ handler: [String: Any]) -> String? {
        if isOwnedManagedHandler(handler) { return nil }
        if let command = handler["command"] as? String {
            let compact = command
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return "命令 \(String(compact.prefix(120)))"
        }
        if let type = handler["type"] as? String {
            return "处理器 \(String(type.prefix(40)))"
        }
        return "未知处理器"
    }

    private static func writeConfiguration(
        _ configuration: [String: Any],
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
                    "\(url.lastPathComponent).threadhelm-backup-"
                        + "\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))"
                )
                try manager.copyItem(at: url, to: backupURL)
            }
            var data = try JSONSerialization.data(
                withJSONObject: configuration,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            data.append(0x0A)
            try AgentIntegrationAtomicFileWriter.write(data, to: url)
        } catch let error as CodexHookConfigurationError {
            throw error
        } catch {
            throw CodexHookConfigurationError.writeFailed(error.localizedDescription)
        }
    }
}

/// hooks.json 里写的命令。实测 Codex 会按空白切分参数，所以可以
/// 直接把旗标附在可执行文件后面，不需要额外的 shim 脚本。
/// 路径必须解引用符号链接：Codex 在解析 hook 命令时不跟随软链，
/// 拿到未解析的路径会静默跳过整个 hook——不报错、不告警。
func codexHookCommand(
    executableURL: URL = URL(
        fileURLWithPath: CommandLine.arguments.first ?? "",
        relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    )
) -> String? {
    let resolved = executableURL
        .standardizedFileURL
        .resolvingSymlinksInPath()
    let path = resolved.path
    guard path.hasPrefix("/"),
          FileManager.default.isExecutableFile(atPath: path),
          // 命令按空白切分，含空白的路径无法安全表达。
          !path.contains(where: { $0 == " " || $0 == "\t" || $0 == "\n" })
    else { return nil }
    return "\(path) \(CodexHookConstants.hookCommandFlag)"
}
