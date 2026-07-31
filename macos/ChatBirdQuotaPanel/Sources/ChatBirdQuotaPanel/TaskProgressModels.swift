//
//  TaskProgressModels.swift
//  ChatBirdQuotaPanel
//
//  模块职责：任务进度数据模型（TaskProgressItem/Snapshot）、Claude 终端
//  打开请求的导航计划，以及任务活动文本的段落/截断处理工具。
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

enum TaskSource: String, Equatable {
    case codex
    case claudeCode
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
        processStartIdentity: String? = nil
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
        self.workingDirectory = workingDirectory
        self.processID = processID
        self.processStartIdentity = processStartIdentity
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
        "\(source.rawValue):\(normalizedTitle)"
    }

    var canOpen: Bool {
        switch source {
        case .codex:
            return threadID != nil
        case .claudeCode:
            return (processID != nil && processStartIdentity != nil)
                || (sessionID != nil && workingDirectory != nil)
        }
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

@discardableResult
func openClaudeTerminal(
    request: ClaudeTerminalOpenRequest
) -> Bool {
    for action in claudeTerminalNavigationPlan(for: request) {
        switch action {
        case .focusProcess(let processID, let processStartIdentity):
            if focusExistingClaudeTerminal(
                processID: processID,
                processStartIdentity: processStartIdentity
            ) {
                return true
            }
        case .resumeSession(let sessionID, let workingDirectory):
            if openClaudeSession(
                sessionID: sessionID,
                workingDirectory: workingDirectory
            ) {
                return true
            }
        case .focusWorkingDirectory(let workingDirectory):
            if focusExistingClaudeTerminal(
                workingDirectory: workingDirectory
            ) {
                return true
            }
        }
    }
    return false
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
        guard !sourceItems.isEmpty else { return .idle }

        // Recurring Codex tasks create a new thread on every run. Multiple
        // rows with the same title are indistinguishable in this compact view,
        // so show the highest-priority/newest sorted instance only.
        let sorted = sourceItems.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.title < $1.title }
            return $0.updatedAt > $1.updatedAt
        }
        var seenTitles = Set<String>()
        let deduplicated = sorted.filter { item in
            seenTitles.insert(item.deduplicationKey).inserted
        }
        guard !deduplicated.isEmpty else { return .idle }

        let active = deduplicated.filter(\.kind.isActive)
        if active.count > maximumVisibleTaskRows {
            return TaskProgressSnapshot(items: active, isScrollable: true)
        }

        let terminal = deduplicated.filter {
            $0.kind == .completed || $0.kind == .failed
        }
        let rows = Array((active + terminal).prefix(maximumVisibleTaskRows))
        guard !rows.isEmpty else { return .idle }
        return TaskProgressSnapshot(items: rows)
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
let maximumTaskActivityCharacters = 4_096

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

func appendingTaskActivityParagraph(
    _ fragment: String,
    to current: String
) -> String {
    let combined = current.isEmpty ? fragment : "\(current) \(fragment)"
    return String(combined.suffix(maximumTaskActivityCharacters))
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
