//
//  TaskProgressModels.swift
//  ThreadHelm
//
//  模块职责：任务进度数据模型（TaskProgressItem/Snapshot）、Claude 终端
//  打开请求的导航计划，以及任务活动文本的完整段落处理工具。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

enum TaskProgressKind: String, Equatable {
    case reading
    case running
    case waitingForInput
    case completed
    case failed
    case idle

    var isActive: Bool {
        self == .running || self == .waitingForInput
    }
}

typealias TaskSource = AgentID

let completedTaskPanelRetention: TimeInterval = 24 * 60 * 60

func taskIsWithinTerminalPanelRetention(
    kind: TaskProgressKind,
    updatedAt: Date,
    now: Date,
    retention: TimeInterval = completedTaskPanelRetention
) -> Bool {
    guard kind == .completed || kind == .failed else { return true }
    return now.timeIntervalSince(updatedAt) <= retention
}

func taskProgressSymbolName(for kind: TaskProgressKind) -> String {
    switch kind {
    case .running:
        return "arrow.triangle.2.circlepath"
    case .waitingForInput:
        return "questionmark.circle.fill"
    case .completed:
        return "checkmark.circle.fill"
    case .failed:
        return "exclamationmark.triangle.fill"
    case .reading:
        return "clock"
    case .idle:
        return "circle"
    }
}

struct TaskProgressItem: Equatable {
    let title: String
    let kind: TaskProgressKind
    let startedAt: Date
    let updatedAt: Date
    let source: TaskSource
    let activityText: String?
    let statusOverride: String?
    let threadID: String?
    let sessionID: String?
    let workingDirectory: String?
    let processID: Int32?
    let processStartIdentity: String?
    /// 公共活动投影：唯一的事件语义源。视图只读 `events`
    ///（= projection.displayEvents），provider 不再直接写混合数组。
    let projection: AgentActivityProjection
    let allowsAgentOpen: Bool
    init(
        title: String,
        kind: TaskProgressKind,
        startedAt: Date = .distantPast,
        updatedAt: Date? = nil,
        source: TaskSource = .codex,
        activityText: String? = nil,
        statusOverride: String? = nil,
        threadID: String? = nil,
        sessionID: String? = nil,
        workingDirectory: String? = nil,
        processID: Int32? = nil,
        processStartIdentity: String? = nil,
        projection: AgentActivityProjection = .empty,
        allowsAgentOpen: Bool = true
    ) {
        self.title = title
        self.kind = kind
        self.startedAt = startedAt
        self.updatedAt = updatedAt ?? startedAt
        self.source = source
        self.activityText = activityText
        self.statusOverride = statusOverride
        self.threadID = threadID
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory.flatMap(normalizedAbsolutePath)
        self.processID = processID
        self.processStartIdentity = processStartIdentity
        var resolved = projection.budgeted()
        // AC-16：终态卡片无条件清除陈旧工具状态（显式 projection 或只有
        // tool、没有 lifecycle record 时也必须生效）。
        if kind == .completed || kind == .failed {
            resolved.currentToolStatus = nil
        }
        self.projection = resolved
        self.allowsAgentOpen = allowsAgentOpen
    }

    /// 只读派生：唯一来源为 `projection.displayEvents`。
    var events: [TaskActivityEvent] {
        projection.displayEvents
    }


    var statusText: String {
        if let statusOverride { return statusOverride }
        switch kind {
        case .reading:
            return "读取中"
        case .running:
            return "正在执行"
        case .waitingForInput:
            return "等你确认"
        case .completed:
            return "已完成"
        case .failed:
            return "执行失败"
        case .idle:
            return "等待"
        }
    }

    var identityKey: String {
        if let threadID { return "\(source.rawValue):\(threadID)" }
        if let sessionID { return "\(source.rawValue):\(sessionID)" }
        return "\(source.rawValue):\(normalizedTitle)"
    }

    var deduplicationKey: String {
        identityKey
    }

    var canOpen: Bool {
        guard allowsAgentOpen else { return false }
        if source == .codex {
            return threadID != nil
        }
        if source == .claudeCode {
            return (processID != nil && processStartIdentity != nil)
                || (sessionID != nil && workingDirectory != nil)
        }
        if source == .cursor || source == .zcode {
            return sessionID != nil
        }
        if source == .omp {
            return sessionID.flatMap(normalizedOMPSessionID) != nil
        }
        return false
    }

    var openButtonTitle: String {
        agentTaskOpenButtonTitle(for: self)
    }

    private var normalizedTitle: String {
        title
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}

struct ClaudeTerminalOpenRequest: Equatable {
    let sessionID: String?
    let workingDirectory: String?
    let processID: Int32?
    let processStartIdentity: String?

    init(
        sessionID: String?,
        workingDirectory: String?,
        processID: Int32?,
        processStartIdentity: String? = nil
    ) {
        let trimmedSessionID = sessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionID = trimmedSessionID.flatMap {
            UUID(uuidString: $0) == nil ? nil : $0.lowercased()
        }
        self.workingDirectory = workingDirectory.flatMap(normalizedAbsolutePath)
        let normalizedProcessID = processID.flatMap { $0 > 1 ? $0 : nil }
        let normalizedProcessStartIdentity = processStartIdentity?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedProcessID,
           let normalizedProcessStartIdentity,
           !normalizedProcessStartIdentity.isEmpty
        {
            self.processID = normalizedProcessID
            self.processStartIdentity = normalizedProcessStartIdentity
        } else {
            self.processID = nil
            self.processStartIdentity = nil
        }
    }
}

enum ClaudeTerminalNavigationAction: Equatable {
    case focusProcess(processID: Int32, processStartIdentity: String)
    case resumeSession(sessionID: String, workingDirectory: String)
    case focusWorkingDirectory(String)
}

func claudeTerminalNavigationPlan(
    for request: ClaudeTerminalOpenRequest
) -> [ClaudeTerminalNavigationAction] {
    var actions: [ClaudeTerminalNavigationAction] = []
    if let processID = request.processID,
       let processStartIdentity = request.processStartIdentity
    {
        actions.append(.focusProcess(
            processID: processID,
            processStartIdentity: processStartIdentity
        ))
    }
    if let sessionID = request.sessionID,
       let workingDirectory = request.workingDirectory
    {
        actions.append(.resumeSession(
            sessionID: sessionID,
            workingDirectory: workingDirectory
        ))
        // A failed resume may still leave a useful project-location fallback.
        // It remains explicitly non-exact, which is safe even when multiple
        // Claude sessions share the same directory.
        actions.append(.focusWorkingDirectory(workingDirectory))
    } else if let workingDirectory = request.workingDirectory {
        // A directory is not a session identity. Only use it when no resumable
        // Claude session is available and the caller has no stronger target.
        actions.append(.focusWorkingDirectory(workingDirectory))
    }
    return actions
}

func allowsGenericTerminalFallback(
    for request: ClaudeTerminalOpenRequest
) -> Bool {
    request.processID == nil
        && request.sessionID == nil
        && request.workingDirectory == nil
}

func claudeTerminalOpenRequest(
    for item: TaskProgressItem
) -> ClaudeTerminalOpenRequest {
    ClaudeTerminalOpenRequest(
        sessionID: item.sessionID,
        workingDirectory: item.workingDirectory,
        processID: item.processID,
        processStartIdentity: item.processStartIdentity
    )
}

func claudeTerminalOpenRequest(
    for prompt: ClaudePermissionPrompt,
    taskItems: [TaskProgressItem]
) -> ClaudeTerminalOpenRequest {
    let item = claudeTaskItem(
        forSessionID: prompt.sessionID,
        in: taskItems
    )
    return ClaudeTerminalOpenRequest(
        sessionID: prompt.sessionID,
        workingDirectory: prompt.workingDirectory,
        processID: item?.processID,
        processStartIdentity: item?.processStartIdentity
    )
}

func claudeTerminalOpenResult(
    for request: ClaudeTerminalOpenRequest,
    focusProcess: (Int32, String) -> OpenResult,
    resumeSession: (String, String) -> Bool,
    focusWorkingDirectory: (String) -> Bool
) -> OpenResult {
    let plan = claudeTerminalNavigationPlan(for: request)
    guard !plan.isEmpty else { return .unavailable }
    for action in plan {
        switch action {
        case .focusProcess(let processID, let processStartIdentity):
            let result = focusProcess(processID, processStartIdentity)
            switch result {
            case .exactSession, .appFocused, .workingDirectoryFallback, .unknown:
                return result
            case .unavailable, .failed, .notAttempted:
                continue
            }
        case .resumeSession(let sessionID, let workingDirectory):
            if resumeSession(sessionID, workingDirectory) {
                // Launching `claude --resume` proves the request was sent, not
                // that the terminal landed in the expected native session.
                return .unknown
            }
        case .focusWorkingDirectory(let workingDirectory):
            if focusWorkingDirectory(workingDirectory) {
                return .workingDirectoryFallback
            }
        }
    }
    return .failed
}

@discardableResult
func openClaudeTerminal(
    request: ClaudeTerminalOpenRequest
) -> OpenResult {
    let currentRequest: ClaudeTerminalOpenRequest
    if let sessionID = request.sessionID {
        currentRequest = refreshedClaudeTerminalOpenRequest(
            request,
            liveProcessTarget: currentClaudeLiveProcessTarget(
                forSessionID: sessionID
            )
        )
    } else {
        currentRequest = request
    }
    return claudeTerminalOpenResult(
        for: currentRequest,
        focusProcess: { processID, processStartIdentity in
            focusExistingClaudeTerminal(
                processID: processID,
                processStartIdentity: processStartIdentity
            )
        },
        resumeSession: { sessionID, workingDirectory in
            openClaudeSession(
                sessionID: sessionID,
                workingDirectory: workingDirectory
            )
        },
        focusWorkingDirectory: { workingDirectory in
            focusExistingClaudeTerminal(workingDirectory: workingDirectory)
        }
    )
}

struct TaskProgressSnapshot: Equatable {
    let items: [TaskProgressItem]
    let isScrollable: Bool

    init(items: [TaskProgressItem], isScrollable: Bool = false) {
        self.items = items
        self.isScrollable = isScrollable
    }

    var kind: TaskProgressKind { items.first?.kind ?? .idle }
    var text: String {
        items.first?.statusText ?? "等待任务"
    }

    static let reading = TaskProgressSnapshot(items: [TaskProgressItem(
        title: "正在读取任务",
        kind: .reading
    )])

    static let idle = TaskProgressSnapshot(items: [TaskProgressItem(
        title: "暂无进行中的任务",
        kind: .idle
    )])

    static func displaying(_ sourceItems: [TaskProgressItem]) -> TaskProgressSnapshot {
        TaskProgressCollectionSnapshot.displaying(sourceItems).compactProjection()
    }
}

func claudeTaskItem(
    forSessionID sessionID: String?,
    in items: [TaskProgressItem]
) -> TaskProgressItem? {
    guard let sessionID else { return nil }
    return items.first {
        $0.source == .claudeCode
            && $0.sessionID?.caseInsensitiveCompare(sessionID) == .orderedSame
    }
}

func claudeProcessID(
    forSessionID sessionID: String?,
    in items: [TaskProgressItem]
) -> Int32? {
    claudeTaskItem(forSessionID: sessionID, in: items)?.processID
}

func taskActivityParagraph(from text: String) -> String? {
    let paragraph = text.components(separatedBy: .newlines)
        .map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        .replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return paragraph.isEmpty ? nil : paragraph
}

func safePublicActivityParagraph(from text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let data = trimmed.data(using: .utf8),
       let value = try? JSONSerialization.jsonObject(with: data),
       value is [String: Any] || value is [Any]
    {
        return nil
    }

    guard var paragraph = taskActivityParagraph(from: text) else { return nil }
    if paragraph.range(
        of: #"-----BEGIN(?: [A-Z0-9]+)* PRIVATE KEY-----"#,
        options: [.regularExpression, .caseInsensitive]
    ) != nil {
        return nil
    }

    let redactions: [(pattern: String, replacement: String)] = [
        (
            #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#,
            "Bearer [已隐藏]"
        ),
        (
            #"(?i)\b(api[\s_-]*key|access[\s_-]*token|refresh[\s_-]*token|client[\s_-]*secret|password|private[\s_-]*key)\b\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#,
            "$1=[已隐藏]"
        ),
        (
            #"(?i)\bsk-[A-Za-z0-9_-]{8,}\b"#,
            "[已隐藏]"
        ),
        (
            #"(?i)\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b"#,
            "[已隐藏]"
        ),
        (
            #"(?i)\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#,
            "[已隐藏]"
        ),
        (
            #"(?i)\bAKIA[0-9A-Z]{16}\b"#,
            "[已隐藏]"
        ),
        (
            #"(?i)(https?://)[^/\s:@]+:[^@\s/]+@"#,
            "$1[已隐藏]@"
        ),
    ]
    for redaction in redactions {
        paragraph = paragraph.replacingOccurrences(
            of: redaction.pattern,
            with: redaction.replacement,
            options: .regularExpression
        )
    }
    return paragraph
}

/// 活动文本单条 / 合计预算（计划 §4.3）。
enum AgentActivityBudget {
    static let maximumPublicMessages = 32
    static let maximumPublicMessageBytes = 4 * 1_024
    static let maximumPublicMessagesTotalBytes = 64 * 1_024
    static let maximumToolStatusBytes = 512
    static let maximumTerminalBytes = 256
}

/// 在脱敏之后做 UTF-8 安全截断：按标量边界截断，绝不劈开多字节 UTF-8。
func safeUTF8Truncated(_ text: String, to byteLimit: Int) -> String {
    guard byteLimit > 0 else { return "" }
    if text.utf8.count <= byteLimit { return text }
    var result = ""
    var bytes = 0
    for scalar in text.unicodeScalars {
        let size = UTF8.width(scalar)
        if bytes + size > byteLimit { break }
        result.unicodeScalars.append(scalar)
        bytes += size
    }
    return result
}

func appendingTaskActivityParagraph(
    _ fragment: String,
    to current: String
) -> String {
    current.isEmpty ? fragment : "\(current) \(fragment)"
}

func appendingTaskActivityEvent(
    _ event: TaskActivityEvent,
    to events: [TaskActivityEvent]
) -> [TaskActivityEvent] {
    // §4.4: 禁止文本去重和文本字典序 tie-breaker。相同文本但不同
    // 稳定 ID 的消息必须同时保留。投影的 budgeted() 按 stable ID 处理。
    var next = events
    next.append(event)
    // 稳定排序：occurredAt 升序，同时间保持插入顺序（非文本字典序）。
    let indexed = next.enumerated().sorted {
        if $0.element.occurredAt == $1.element.occurredAt {
            return $0.offset < $1.offset
        }
        return $0.element.occurredAt < $1.element.occurredAt
    }.map(\.element)
    return indexed
}

// MARK: - Read-only repository and check evidence

enum TaskGitCheckoutKind: Equatable {
    case checkout
    case linkedWorktree
}

struct TaskGitStatus: Equatable {
    let repositoryRoot: String
    let branch: String?
    let isDetached: Bool
    let checkoutKind: TaskGitCheckoutKind
    let isDirty: Bool
    let upstreamName: String?
    let aheadCount: Int?
    let behindCount: Int?
    let headSHA: String?
    /// Safe `owner/repository` slug only. The original remote URL is never kept.
    let githubRepository: String?

    var headShortSHA: String? {
        headSHA.map { String($0.prefix(12)) }
    }
}

enum TaskCheckState: Equatable {
    case unknown
    case pending
    case passed
    case failed
    case inconclusive
}

struct TaskCheckStatus: Equatable {
    let state: TaskCheckState
    let totalCount: Int
    let successCount: Int
    let failureCount: Int
    let pendingCount: Int
    let inconclusiveCount: Int

    static let unknown = TaskCheckStatus(
        state: .unknown,
        totalCount: 0,
        successCount: 0,
        failureCount: 0,
        pendingCount: 0,
        inconclusiveCount: 0
    )
}

/// Per-task, in-memory-only snapshot. It is deliberately not Codable: repository
/// paths, branches, commit IDs and check state must not drift into persisted metrics.
struct TaskRepositoryEvidence: Equatable {
    let workingDirectory: String
    let gitStatus: TaskGitStatus?
    let checkStatus: TaskCheckStatus
    let gitObservedAt: Date
    let checksObservedAt: Date
}

let taskGitStatusCacheLifetime: TimeInterval = 10
let taskCheckStatusCacheLifetime: TimeInterval = 60
let taskRepositoryProbeLimit = 8

private struct TaskStatusCommandResult {
    let data: Data
    let exitStatus: Int32
}

private func runTaskStatusCommand(
    executableURL: URL,
    arguments: [String],
    timeout: TimeInterval,
    maximumOutputBytes: Int
) -> TaskStatusCommandResult? {
    let process = Process()
    let output = Pipe()
    process.executableURL = executableURL
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    var environment = ProcessInfo.processInfo.environment
    environment["LC_ALL"] = "C"
    environment["LANG"] = "C"
    environment["NO_COLOR"] = "1"
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    environment["GIT_PAGER"] = "cat"
    environment["PAGER"] = "cat"
    environment["GH_PROMPT_DISABLED"] = "1"
    environment["GH_NO_UPDATE_NOTIFIER"] = "1"
    process.environment = environment
    do {
        try process.run()
    } catch {
        return nil
    }
    let capture = captureProcessOutput(
        process: process,
        output: output.fileHandleForReading,
        timeout: timeout,
        maximumOutputBytes: maximumOutputBytes
    )
    guard capture.termination == .exited else { return nil }
    return TaskStatusCommandResult(
        data: capture.data,
        exitStatus: process.terminationStatus
    )
}

private func taskStatusCommandText(
    executableURL: URL,
    arguments: [String],
    timeout: TimeInterval = 2,
    maximumOutputBytes: Int = 64 * 1_024
) -> String? {
    guard let result = runTaskStatusCommand(
        executableURL: executableURL,
        arguments: arguments,
        timeout: timeout,
        maximumOutputBytes: maximumOutputBytes
    ), result.exitStatus == 0,
       let text = String(data: result.data, encoding: .utf8)
    else { return nil }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

func parsedTaskGitStatus(
    repositoryRoot: String,
    porcelainV2: String,
    checkoutKind: TaskGitCheckoutKind,
    githubRepository: String? = nil
) -> TaskGitStatus? {
    guard let normalizedRoot = normalizedAbsolutePath(repositoryRoot) else {
        return nil
    }
    var headOID: String?
    var sawHeadOID = false
    var branchMarker: String?
    var upstreamName: String?
    var aheadCount: Int?
    var behindCount: Int?
    var isDirty = false

    for rawLine in porcelainV2.split(
        omittingEmptySubsequences: true,
        whereSeparator: { $0.isNewline }
    ) {
        let line = String(rawLine)
        if line.hasPrefix("# branch.oid ") {
            sawHeadOID = true
            let value = String(line.dropFirst("# branch.oid ".count))
            if value != "(initial)" {
                guard value.range(
                    of: #"^(?:[0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$"#,
                    options: .regularExpression
                ) != nil else { return nil }
                headOID = value.lowercased()
            }
        } else if line.hasPrefix("# branch.head ") {
            let value = String(line.dropFirst("# branch.head ".count))
            guard !value.isEmpty, value.count <= 256 else { return nil }
            branchMarker = value
        } else if line.hasPrefix("# branch.upstream ") {
            let value = String(line.dropFirst("# branch.upstream ".count))
            guard !value.isEmpty, value.count <= 256 else { return nil }
            upstreamName = value
        } else if line.hasPrefix("# branch.ab ") {
            let values = line.dropFirst("# branch.ab ".count).split(separator: " ")
            guard values.count == 2,
                  values[0].first == "+",
                  values[1].first == "-",
                  let parsedAhead = Int(values[0].dropFirst()),
                  let parsedBehind = Int(values[1].dropFirst()),
                  parsedAhead >= 0,
                  parsedBehind >= 0
            else { return nil }
            aheadCount = parsedAhead
            behindCount = parsedBehind
        } else if !line.hasPrefix("# ") {
            isDirty = true
        }
    }

    guard sawHeadOID, let branchMarker else { return nil }
    let isDetached = branchMarker == "(detached)"
    let branch: String?
    if isDetached || branchMarker == "(unknown)" || branchMarker.isEmpty {
        branch = nil
    } else {
        branch = branchMarker
    }
    return TaskGitStatus(
        repositoryRoot: normalizedRoot,
        branch: branch,
        isDetached: isDetached,
        checkoutKind: checkoutKind,
        isDirty: isDirty,
        upstreamName: upstreamName,
        aheadCount: aheadCount,
        behindCount: behindCount,
        headSHA: headOID,
        githubRepository: githubRepository
    )
}

func taskGitCheckoutKind(
    repositoryRoot: String,
    gitDirectory: String,
    commonGitDirectory: String
) -> TaskGitCheckoutKind? {
    guard let normalizedRoot = normalizedAbsolutePath(repositoryRoot) else {
        return nil
    }
    func resolved(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL.path
        }
        return URL(fileURLWithPath: normalizedRoot, isDirectory: true)
            .appendingPathComponent(trimmed)
            .standardizedFileURL.path
    }
    guard let gitPath = resolved(gitDirectory),
          let commonPath = resolved(commonGitDirectory)
    else { return nil }
    return gitPath == commonPath ? .checkout : .linkedWorktree
}

private func taskGitHubRepositoryComponentIsSafe(_ value: String) -> Bool {
    guard value != ".", value != ".." else { return false }
    return value.range(
        of: #"^[A-Za-z0-9._-]{1,100}$"#,
        options: .regularExpression
    ) != nil
}

func githubRepositorySlug(from remoteURL: String) -> String? {
    let githubHost = "github.com"
    let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 2_048 else { return nil }
    let scpPrefix = "git" + "@" + githubHost + ":"
    let repositoryPath: String
    if trimmed.hasPrefix(scpPrefix) {
        repositoryPath = String(trimmed.dropFirst(scpPrefix.count))
        guard !repositoryPath.hasPrefix("/") else { return nil }
    } else {
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["git", "http", "https", "ssh"].contains(scheme),
              url.host?.lowercased() == githubHost,
              (url.user == nil || (scheme == "ssh" && url.user == "git")),
              url.password == nil,
              url.query == nil,
              url.fragment == nil
        else { return nil }
        repositoryPath = url.path
    }
    var components = repositoryPath.split(separator: "/").map(String.init)
    guard components.count == 2 else { return nil }
    if components[1].hasSuffix(".git") {
        components[1].removeLast(4)
    }
    guard components.allSatisfy(taskGitHubRepositoryComponentIsSafe) else {
        return nil
    }
    return components.joined(separator: "/")
}

func taskCheckStatus(from data: Data) -> TaskCheckStatus? {
    guard let root = try? JSONSerialization.jsonObject(with: data)
        as? [String: Any],
          let totalCount = root["total_count"] as? Int,
          totalCount >= 0,
          let checkRuns = root["check_runs"] as? [[String: Any]],
          checkRuns.count == totalCount
    else { return nil }
    guard totalCount > 0 else { return .unknown }

    var successCount = 0
    var failureCount = 0
    var pendingCount = 0
    var inconclusiveCount = 0
    for run in checkRuns {
        guard let status = run["status"] as? String else { return nil }
        if ["queued", "in_progress", "waiting", "requested", "pending"]
            .contains(status)
        {
            pendingCount += 1
            continue
        }
        guard status == "completed",
              let conclusion = run["conclusion"] as? String
        else { return nil }
        switch conclusion {
        case "success":
            successCount += 1
        case "failure", "timed_out", "action_required", "startup_failure":
            failureCount += 1
        case "cancelled", "neutral", "skipped", "stale":
            inconclusiveCount += 1
        default:
            return nil
        }
    }
    let state: TaskCheckState
    if failureCount > 0 {
        state = .failed
    } else if pendingCount > 0 {
        state = .pending
    } else if inconclusiveCount > 0 {
        state = .inconclusive
    } else {
        state = .passed
    }
    return TaskCheckStatus(
        state: state,
        totalCount: totalCount,
        successCount: successCount,
        failureCount: failureCount,
        pendingCount: pendingCount,
        inconclusiveCount: inconclusiveCount
    )
}

func locateGitHubCLI(fileManager: FileManager = .default) -> URL? {
    for path in [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/usr/bin/gh",
    ] where fileManager.isExecutableFile(atPath: path) {
        return URL(fileURLWithPath: path)
    }
    return nil
}

private func taskGitHubRepository(
    gitExecutableURL: URL,
    repositoryRoot: String,
    upstreamName: String?
) -> String? {
    if let upstreamName,
       let remoteName = upstreamName.split(separator: "/").first
    {
        guard let remote = taskStatusCommandText(
            executableURL: gitExecutableURL,
            arguments: [
                "-C", repositoryRoot, "remote", "get-url", String(remoteName),
            ],
            timeout: 1,
            maximumOutputBytes: 4_096
        ) else { return nil }
        return githubRepositorySlug(from: remote)
    }
    guard let remote = taskStatusCommandText(
        executableURL: gitExecutableURL,
        arguments: ["-C", repositoryRoot, "remote", "get-url", "origin"],
        timeout: 1,
        maximumOutputBytes: 4_096
    ) else { return nil }
    return githubRepositorySlug(from: remote)
}

private func probeTaskGitStatus(
    workingDirectory: String,
    gitExecutableURL: URL
) -> TaskGitStatus? {
    guard let directory = normalizedAbsolutePath(workingDirectory) else {
        return nil
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(
        atPath: directory,
        isDirectory: &isDirectory
    ), isDirectory.boolValue else { return nil }
    guard let repositoryRoot = taskStatusCommandText(
        executableURL: gitExecutableURL,
        arguments: ["-C", directory, "rev-parse", "--show-toplevel"],
        timeout: 1,
        maximumOutputBytes: 4_096
    ).flatMap(normalizedAbsolutePath),
          let statusText = taskStatusCommandText(
              executableURL: gitExecutableURL,
              arguments: [
                  "-c", "core.fsmonitor=false",
                  "-c", "core.untrackedCache=false",
                  "-C", repositoryRoot, "status", "--porcelain=v2", "--branch",
                  "--untracked-files=normal",
              ],
              timeout: 2,
              maximumOutputBytes: 128 * 1_024
          ),
          let metadataText = taskStatusCommandText(
              executableURL: gitExecutableURL,
              arguments: [
                  "-C", repositoryRoot, "rev-parse", "--git-dir",
                  "--git-common-dir",
              ],
              timeout: 1,
              maximumOutputBytes: 8_192
          )
    else { return nil }
    let metadataLines = metadataText.split(
        omittingEmptySubsequences: true,
        whereSeparator: { $0.isNewline }
    ).map(String.init)
    guard metadataLines.count == 2,
          let checkoutKind = taskGitCheckoutKind(
              repositoryRoot: repositoryRoot,
              gitDirectory: metadataLines[0],
              commonGitDirectory: metadataLines[1]
          ),
          let preliminary = parsedTaskGitStatus(
              repositoryRoot: repositoryRoot,
              porcelainV2: statusText,
              checkoutKind: checkoutKind
          )
    else { return nil }
    let githubRepository = taskGitHubRepository(
        gitExecutableURL: gitExecutableURL,
        repositoryRoot: repositoryRoot,
        upstreamName: preliminary.upstreamName
    )
    return parsedTaskGitStatus(
        repositoryRoot: repositoryRoot,
        porcelainV2: statusText,
        checkoutKind: checkoutKind,
        githubRepository: githubRepository
    )
}

private func probeTaskCheckStatus(
    githubRepository: String,
    headSHA: String,
    ghExecutableURL: URL
) -> TaskCheckStatus {
    let repositoryComponents = githubRepository.split(separator: "/")
        .map(String.init)
    guard repositoryComponents.count == 2,
          repositoryComponents.allSatisfy(taskGitHubRepositoryComponentIsSafe),
          headSHA.range(
              of: #"^(?:[0-9a-f]{40}|[0-9a-f]{64})$"#,
              options: .regularExpression
          ) != nil
    else { return .unknown }
    let endpoint = "repos/\(githubRepository)/commits/\(headSHA)"
        + "/check-runs?per_page=100&filter=latest"
    let jq = "{total_count: .total_count, check_runs: "
        + "[.check_runs[] | {status: .status, conclusion: .conclusion}]}"
    guard let result = runTaskStatusCommand(
        executableURL: ghExecutableURL,
        arguments: [
            "api", "-H", "Accept: application/vnd.github+json", endpoint,
            "--jq", jq,
        ],
        timeout: 3,
        maximumOutputBytes: 64 * 1_024
    ), result.exitStatus == 0,
       let status = taskCheckStatus(from: result.data)
    else { return .unknown }
    return status
}

func probeTaskRepositoryEvidence(
    workingDirectory: String,
    previous: TaskRepositoryEvidence?,
    now: Date = Date(),
    gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
    ghExecutableURL: URL? = locateGitHubCLI()
) -> TaskRepositoryEvidence {
    let normalizedDirectory = normalizedAbsolutePath(workingDirectory)
        ?? workingDirectory
    let matchingPrevious = previous?.workingDirectory == normalizedDirectory
        ? previous
        : nil
    func isFresh(_ date: Date, lifetime: TimeInterval) -> Bool {
        let age = now.timeIntervalSince(date)
        return age >= 0 && age < lifetime
    }
    let checksAreFresh = matchingPrevious.map {
        isFresh($0.checksObservedAt, lifetime: taskCheckStatusCacheLifetime)
    } ?? false
    let gitIsFresh = matchingPrevious.map {
        isFresh($0.gitObservedAt, lifetime: taskGitStatusCacheLifetime)
    } ?? false
    if gitIsFresh, checksAreFresh, let matchingPrevious {
        return matchingPrevious
    }

    let gitStatus = probeTaskGitStatus(
        workingDirectory: normalizedDirectory,
        gitExecutableURL: gitExecutableURL
    )
    let canReuseChecks = checksAreFresh
        && matchingPrevious?.gitStatus?.repositoryRoot == gitStatus?.repositoryRoot
        && matchingPrevious?.gitStatus?.headSHA == gitStatus?.headSHA
        && matchingPrevious?.gitStatus?.githubRepository
            == gitStatus?.githubRepository
    let checkStatus: TaskCheckStatus
    let checksObservedAt: Date
    if canReuseChecks, let matchingPrevious {
        checkStatus = matchingPrevious.checkStatus
        checksObservedAt = matchingPrevious.checksObservedAt
    } else if let githubRepository = gitStatus?.githubRepository,
              let headSHA = gitStatus?.headSHA,
              let ghExecutableURL
    {
        checkStatus = probeTaskCheckStatus(
            githubRepository: githubRepository,
            headSHA: headSHA,
            ghExecutableURL: ghExecutableURL
        )
        checksObservedAt = now
    } else {
        checkStatus = .unknown
        checksObservedAt = now
    }
    return TaskRepositoryEvidence(
        workingDirectory: normalizedDirectory,
        gitStatus: gitStatus,
        checkStatus: checkStatus,
        gitObservedAt: now,
        checksObservedAt: checksObservedAt
    )
}

func taskRepositoryEvidenceByTaskIdentity(
    items: [TaskProgressItem],
    previous: [String: TaskRepositoryEvidence],
    now: Date = Date(),
    maximumDirectories: Int = taskRepositoryProbeLimit,
    probe: (
        String,
        TaskRepositoryEvidence?,
        Date
    ) -> TaskRepositoryEvidence = { directory, previous, now in
        probeTaskRepositoryEvidence(
            workingDirectory: directory,
            previous: previous,
            now: now
        )
    }
) -> [String: TaskRepositoryEvidence] {
    var previousByDirectory: [String: TaskRepositoryEvidence] = [:]
    for evidence in previous.values {
        if let existing = previousByDirectory[evidence.workingDirectory],
           existing.gitObservedAt > evidence.gitObservedAt
            || (existing.gitObservedAt == evidence.gitObservedAt
                && existing.checksObservedAt >= evidence.checksObservedAt)
        {
            continue
        } else {
            previousByDirectory[evidence.workingDirectory] = evidence
        }
    }

    var visitedDirectories = Set<String>()
    var evidenceByDirectory: [String: TaskRepositoryEvidence] = [:]
    var result: [String: TaskRepositoryEvidence] = [:]
    let limit = max(0, maximumDirectories)
    for item in items {
        guard let directory = item.workingDirectory.flatMap(normalizedAbsolutePath)
        else { continue }
        if let evidence = evidenceByDirectory[directory] {
            result[item.identityKey] = evidence
            continue
        }
        guard visitedDirectories.insert(directory).inserted,
              visitedDirectories.count <= limit
        else { continue }
        let evidence = probe(
            directory,
            previousByDirectory[directory],
            now
        )
        evidenceByDirectory[directory] = evidence
        result[item.identityKey] = evidence
    }
    return result
}
