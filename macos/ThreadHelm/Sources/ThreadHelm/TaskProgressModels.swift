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
    let events: [TaskActivityEvent]

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
        events: [TaskActivityEvent] = []
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
        self.events = events
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

    var rowCount: Int { max(1, min(maximumVisibleTaskRows, items.count)) }

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

struct TaskActivityPreviewPayload: Equatable {
    let taskKey: String
    let body: String
}

let maximumTaskActivityLines = 3

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
    var next = events.filter {
        !($0.kind == event.kind && $0.text == event.text)
    }
    next.append(event)
    next.sort {
        if $0.occurredAt == $1.occurredAt { return $0.text < $1.text }
        return $0.occurredAt < $1.occurredAt
    }
    return next
}

func taskActivityVisibleTailText(
    from text: String,
    width: CGFloat,
    font: NSFont,
    lineSpacing: CGFloat,
    maximumLineCount: Int
) -> String {
    guard width > 0, maximumLineCount > 0, !text.isEmpty else {
        return ""
    }

    func renderedLineCount(_ candidate: String) -> Int {
        guard !candidate.isEmpty else { return 0 }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.lineSpacing = lineSpacing
        let storage = NSTextStorage(
            string: candidate,
            attributes: [
                .font: font,
                .paragraphStyle: paragraph,
            ]
        )
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: NSSize(
                width: width,
                height: .greatestFiniteMagnitude
            )
        )
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = .byCharWrapping
        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        var lineCount = 0
        layoutManager.enumerateLineFragments(
            forGlyphRange: NSRange(
                location: 0,
                length: layoutManager.numberOfGlyphs
            )
        ) { _, _, _, _, _ in
            lineCount += 1
        }
        return lineCount
    }

    guard renderedLineCount(text) > maximumLineCount else {
        return text
    }

    let characters = Array(text)
    var lowerBound = 1
    var upperBound = characters.count
    while lowerBound < upperBound {
        let candidateStart = lowerBound
            + (upperBound - lowerBound) / 2
        let candidate = String(characters.dropFirst(candidateStart))
        if renderedLineCount(candidate) <= maximumLineCount {
            upperBound = candidateStart
        } else {
            lowerBound = candidateStart + 1
        }
    }
    return String(characters.dropFirst(lowerBound))
}

func taskActivityPreviewPayload(
    for item: TaskProgressItem
) -> TaskActivityPreviewPayload? {
    guard item.kind == .running else { return nil }
    let body = item.activityText.flatMap(taskActivityParagraph)
    return TaskActivityPreviewPayload(
        taskKey: item.identityKey,
        body: body ?? "正在思考"
    )
}
