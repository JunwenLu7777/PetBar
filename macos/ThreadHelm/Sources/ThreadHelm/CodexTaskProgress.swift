//
//  CodexTaskProgress.swift
//  ThreadHelm
//
//  模块职责：扫描 Codex sessions 目录的 rollout jsonl，解析任务生命周期
//  事件（开始/完成/失败/等待输入/工具调用），结合标题索引与未读状态
//  产出 Codex 任务进度快照。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

final class CodexTaskProgressReader {
    struct UnreadThreadState {
        let ids: Set<String>
        let explicitlyVisibleIDs: Set<String>
        let isAvailable: Bool

        init(
            ids: Set<String>,
            explicitlyVisibleIDs: Set<String> = [],
            isAvailable: Bool
        ) {
            self.ids = ids
            self.explicitlyVisibleIDs = explicitlyVisibleIDs
            self.isAvailable = isAvailable
        }
    }

    private struct RolloutCandidate {
        let url: URL
        let modificationDate: Date
    }

    private struct ParsedCacheEntry {
        let modificationDate: Date
        let snapshot: TaskProgressSnapshot
        var reader: TranscriptEventReader?
        var reducer: CodexReducerState
    }

    /// 增量 reducer 状态：只 apply 新 records，不保存原始历史行。
    /// events 限制为最近 32 条（AC-15）。
    struct CodexReducerState {
        var lifecycle: TaskProgressKind?
        var pendingUserInputCalls = Set<String>()
        var activeTools: [String: (text: String, updatedAt: Date)] = [:]
        var latestUserTitle: String?
        var activeTaskTitle: String?
        var publicCommentaryText = ""
        var latestPublicCommentary: String?
        var workingDirectory: String?
        var events: [TaskActivityEvent] = []
        var taskStartedAt: Date
        var lastUpdatedAt: Date

        init(modificationDate: Date) {
            taskStartedAt = modificationDate
            lastUpdatedAt = modificationDate
        }

        mutating func apply(_ line: String) {
            guard line.contains("task_started")
                || line.contains("task_complete")
                || line.contains("task_failed")
                || line.contains("turn_aborted")
                || line.contains(#""type":"error""#)
                || line.contains("user_message")
                || line.contains("agent_message")
                || line.contains("request_user_input")
                || line.contains("function_call")
                || line.contains("custom_tool_call")
                || line.contains("function_call_output")
                || line.contains("custom_tool_call_output")
                || line.contains("session_meta")
            else { return }
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = record["payload"] as? [String: Any]
            else { return }
            if record["type"] as? String == "session_meta",
               let rawCwd = payload["cwd"] as? String,
               let cwd = normalizedAbsolutePath(rawCwd) {
                workingDirectory = cwd
                return
            }
            guard let payloadType = payload["type"] as? String else { return }
            if record["type"] as? String == "event_msg" {
                let eventDate = CodexTaskProgressReader.timestamp(from: record) ?? lastUpdatedAt
                if payloadType == "user_message",
                   let message = payload["message"] as? String,
                   let title = CodexTaskProgressReader.taskTitle(from: message) {
                    latestUserTitle = title
                } else if payloadType == "task_started" {
                    lifecycle = .running
                    pendingUserInputCalls.removeAll()
                    activeTools.removeAll()
                    publicCommentaryText = ""
                    latestPublicCommentary = nil
                    activeTaskTitle = latestUserTitle ?? activeTaskTitle
                    taskStartedAt = eventDate
                    lastUpdatedAt = eventDate
                    events.removeAll(keepingCapacity: true)
                    events = appendingTaskActivityEvent(
                        TaskActivityEvent(kind: .lifecycle, occurredAt: eventDate, text: "任务开始"),
                        to: events
                    )
                } else if payloadType == "task_complete" {
                    lifecycle = .completed
                    pendingUserInputCalls.removeAll()
                    activeTools.removeAll()
                    lastUpdatedAt = eventDate
                    events = appendingTaskActivityEvent(
                        TaskActivityEvent(kind: .lifecycle, occurredAt: eventDate, text: "任务完成"),
                        to: events
                    )
                } else if ["task_failed", "turn_aborted", "error"].contains(payloadType) {
                    lifecycle = .failed
                    pendingUserInputCalls.removeAll()
                    activeTools.removeAll()
                    lastUpdatedAt = eventDate
                    events = appendingTaskActivityEvent(
                        TaskActivityEvent(kind: .lifecycle, occurredAt: eventDate, text: "任务失败"),
                        to: events
                    )
                } else if payloadType == "agent_message",
                          ["commentary", "final_answer"].contains(
                              (payload["phase"] as? String)?.lowercased() ?? ""
                          ),
                          let message = payload["message"] as? String,
                          let commentary = CodexTaskProgressReader.sanitizedPublicCommentary(message) {
                    if latestPublicCommentary != commentary {
                        latestPublicCommentary = commentary
                        publicCommentaryText = appendingTaskActivityParagraph(commentary, to: publicCommentaryText)
                        events = appendingTaskActivityEvent(
                        TaskActivityEvent(kind: .commentary, occurredAt: eventDate, text: commentary),
                            to: events
                        )
                        if events.count > 32 {
                            events = Array(events.suffix(32))
                        }
                    }
                    lastUpdatedAt = eventDate
                }
                return
            }
            if ["function_call", "custom_tool_call"].contains(payloadType),
               let name = payload["name"] as? String,
               let callID = payload["call_id"] as? String {
                let eventDate = CodexTaskProgressReader.timestamp(from: record) ?? lastUpdatedAt
                lastUpdatedAt = eventDate
                if name == "request_user_input" {
                    pendingUserInputCalls.insert(callID)
                    activeTools.removeValue(forKey: callID)
                    events = appendingTaskActivityEvent(
                        TaskActivityEvent(kind: .lifecycle, occurredAt: eventDate, text: "等待输入"),
                        to: events
                    )
                } else {
                    let toolActivity = CodexTaskProgressReader.safeToolActivity(name: name)
                    activeTools[callID] = (text: toolActivity, updatedAt: eventDate)
                    events = appendingTaskActivityEvent(
                        TaskActivityEvent(kind: .tool, occurredAt: eventDate, text: toolActivity),
                        to: events
                    )
                }
                return
            }
            if ["function_call_output", "custom_tool_call_output"].contains(payloadType),
               let callID = payload["call_id"] as? String {
                let wasPendingInput = pendingUserInputCalls.remove(callID) != nil
                let wasActiveTool = activeTools.removeValue(forKey: callID) != nil
                if wasPendingInput || wasActiveTool {
                    lastUpdatedAt = CodexTaskProgressReader.timestamp(from: record) ?? lastUpdatedAt
                }
            }
        }

        func snapshot(modificationDate: Date, now: Date) -> TaskProgressSnapshot {
            let title = activeTaskTitle ?? latestUserTitle ?? "Codex 任务"
            if lifecycle == .running, !pendingUserInputCalls.isEmpty {
                return TaskProgressSnapshot(items: [TaskProgressItem(
                    title: title, kind: .waitingForInput,
                    startedAt: taskStartedAt, updatedAt: lastUpdatedAt,
                    workingDirectory: workingDirectory, events: events
                )])
            }
            if let lifecycle {
                let activityText: String?
                if lifecycle == .running {
                    activityText = CodexTaskProgressReader.runningActivityText(
                        activeTools: activeTools,
                        publicCommentaryText: publicCommentaryText
                    )
                } else { activityText = nil }
                return TaskProgressSnapshot(items: [TaskProgressItem(
                    title: title, kind: lifecycle,
                    startedAt: taskStartedAt, updatedAt: lastUpdatedAt,
                    activityText: activityText,
                    workingDirectory: workingDirectory, events: events
                )])
            }
            if !pendingUserInputCalls.isEmpty {
                return TaskProgressSnapshot(items: [TaskProgressItem(
                    title: title, kind: .waitingForInput,
                    startedAt: taskStartedAt, updatedAt: lastUpdatedAt,
                    workingDirectory: workingDirectory, events: events
                )])
            }
            if now.timeIntervalSince(modificationDate) <= 30 * 60 {
                return TaskProgressSnapshot(items: [TaskProgressItem(
                    title: title, kind: .running,
                    startedAt: taskStartedAt, updatedAt: lastUpdatedAt,
                    activityText: CodexTaskProgressReader.runningActivityText(
                        activeTools: activeTools,
                        publicCommentaryText: publicCommentaryText
                    ),
                    workingDirectory: workingDirectory, events: events
                )])
            }
            return .idle
        }

        private static func timestamp(from record: [String: Any]) -> Date? {
            CodexTaskProgressReader.timestamp(from: record)
        }
    }
    private struct RolloutSessionMetadata {
        let firstLine: String?
        let workingDirectory: String?
    }

    private let fileManager = FileManager.default
    private let rolloutRescanInterval: TimeInterval = codexTaskProgressRescanInterval
    private let activeTaskFreshness: TimeInterval = 30 * 60
    private let completedTaskVisibility = completedTaskPanelRetention
    private var cachedRollouts: [RolloutCandidate] = []
    private var cachedRolloutVisibility: [String: Bool] = [:]
    private var cachedSessionMetadata: [String: RolloutSessionMetadata] = [:]
    private var parsedCache: [String: ParsedCacheEntry] = [:]
    private var cachedThreadTitles: [String: String] = [:]
    private var cachedThreadIndexModificationDate: Date?
    private var cachedUnreadThreadIDs = Set<String>()
    private var cachedExplicitlyVisibleThreadIDs = Set<String>()
    private var cachedUnreadStateModificationDate: Date?
    private var hasCachedUnreadState = false
    private var nextRolloutScanAt = Date.distantPast

    func readCollection() -> TaskProgressCollectionSnapshot {
        let now = Date()
        let threadTitles = readThreadTitleIndex()
        let unreadState = readUnreadThreadState()
        var items: [TaskProgressItem] = []
        for candidate in recentRollouts(
            at: now,
            unreadThreadIDs: unreadState.ids,
            explicitlyVisibleThreadIDs: unreadState.explicitlyVisibleIDs
        ) {
            let cacheKey = candidate.url.path
            let sessionMetadata = readSessionMetadata(from: candidate.url)
            let snapshot: TaskProgressSnapshot
            if var cached = parsedCache[cacheKey],
               cached.modificationDate == candidate.modificationDate
            {
                snapshot = cached.snapshot
            } else {
                // 增量 reducer：有持久 reader 时做前向 pass，只 apply 新
                // records 到持久 reducer 状态（不保存原始行）。
                // 无则冷启动回扫后 apply 全部回扫记录。
                var reader: TranscriptEventReader?
                var reducer: CodexReducerState
                if let cached = parsedCache[cacheKey],
                   let cachedReader = cached.reader
                {
                    let result = cachedReader.readForwardPass()
                    if case .success(let records) = result {
                        reducer = cached.reducer
                        for record in records {
                            if let line = String(data: record.data, encoding: .utf8) {
                                reducer.apply(line)
                            }
                        }
                        reader = cachedReader
                    } else {
                        // identity 变化：冷启动。
                        guard let newReader = TranscriptEventReader.make(
                            at: candidate.url
                        ) else { continue }
                        reader = newReader
                        reducer = CodexReducerState(modificationDate: candidate.modificationDate)
                        let coldLines = readTailLinesColdScan(
                            reader: newReader, url: candidate.url
                        )
                        for line in coldLines { reducer.apply(line) }
                    }
                } else {
                    guard let newReader = TranscriptEventReader.make(
                        at: candidate.url
                    ) else { continue }
                    reader = newReader
                    reducer = CodexReducerState(modificationDate: candidate.modificationDate)
                    let coldLines = readTailLinesColdScan(
                        reader: newReader, url: candidate.url
                    )
                    for line in coldLines { reducer.apply(line) }
                }
                snapshot = reducer.snapshot(
                    modificationDate: candidate.modificationDate, now: now
                )
                parsedCache[cacheKey] = ParsedCacheEntry(
                    modificationDate: candidate.modificationDate,
                    snapshot: snapshot,
                    reader: reader,
                    reducer: reducer
                )
            }
            guard var item = snapshot.items.first, item.kind != .idle else { continue }
            let resolvedTitle = Self.resolvedTitle(
                for: candidate.url,
                indexedTitles: threadTitles,
                fallback: item.title
            )
            let threadID = Self.threadID(from: candidate.url)
            item = TaskProgressItem(
                title: resolvedTitle,
                kind: item.kind,
                startedAt: item.startedAt,
                updatedAt: item.updatedAt,
                activityText: item.activityText,
                statusOverride: item.statusOverride,
                threadID: threadID,
                workingDirectory: item.workingDirectory
                    ?? sessionMetadata.workingDirectory,
                events: item.events
            )
            guard Self.shouldDisplay(
                kind: item.kind,
                threadID: threadID,
                modificationDate: candidate.modificationDate,
                now: now,
                unreadState: unreadState,
                fallbackVisibility: completedTaskVisibility,
                activeVisibility: activeTaskFreshness,
                terminalDate: item.updatedAt
            ) else { continue }
            items.append(item)
        }

        return .displaying(items)
    }

    func read() -> TaskProgressSnapshot {
        readCollection().compactProjection()
    }

    static func parse(
        lines: [String],
        modificationDate: Date,
        now: Date
    ) -> TaskProgressSnapshot {
        var lifecycle: TaskProgressKind?
        var pendingUserInputCalls = Set<String>()
        var activeTools: [String: (text: String, updatedAt: Date)] = [:]
        var latestUserTitle: String?
        var activeTaskTitle: String?
        var publicCommentaryText = ""
        var latestPublicCommentary: String?
        var workingDirectory: String?
        var events: [TaskActivityEvent] = []
        var taskStartedAt = modificationDate
        var lastUpdatedAt = modificationDate

        for line in lines {
            guard line.contains("task_started")
                || line.contains("task_complete")
                || line.contains("task_failed")
                || line.contains("turn_aborted")
                || line.contains(#""type":"error""#)
                || line.contains("user_message")
                || line.contains("agent_message")
                || line.contains("request_user_input")
                || line.contains("function_call")
                || line.contains("custom_tool_call")
                || line.contains("function_call_output")
                || line.contains("custom_tool_call_output")
                || line.contains("session_meta")
            else { continue }

            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = record["payload"] as? [String: Any]
            else { continue }

            if record["type"] as? String == "session_meta",
               let rawCwd = payload["cwd"] as? String,
               let cwd = normalizedAbsolutePath(rawCwd) {
                workingDirectory = cwd
                continue
            }

            guard let payloadType = payload["type"] as? String else { continue }

            if record["type"] as? String == "event_msg" {
                let eventDate = timestamp(from: record) ?? lastUpdatedAt
                if payloadType == "user_message",
                   let message = payload["message"] as? String,
                   let title = taskTitle(from: message)
                {
                    latestUserTitle = title
                } else if payloadType == "task_started" {
                    lifecycle = .running
                    pendingUserInputCalls.removeAll()
                    activeTools.removeAll()
                    publicCommentaryText = ""
                    latestPublicCommentary = nil
                    activeTaskTitle = latestUserTitle ?? activeTaskTitle
                    taskStartedAt = eventDate
                    lastUpdatedAt = eventDate
                    events.removeAll(keepingCapacity: true)
                    events = appendingTaskActivityEvent(
                        TaskActivityEvent(
                            kind: .lifecycle,
                            occurredAt: eventDate,
                            text: "任务开始"
                        ),
                        to: events
                    )
                } else if payloadType == "task_complete" {
                    lifecycle = .completed
                    pendingUserInputCalls.removeAll()
                    activeTools.removeAll()
                    lastUpdatedAt = eventDate
                    events = appendingTaskActivityEvent(
                        TaskActivityEvent(
                            kind: .lifecycle,
                            occurredAt: eventDate,
                            text: "任务完成"
                        ),
                        to: events
                    )
                } else if ["task_failed", "turn_aborted", "error"].contains(payloadType) {
                    lifecycle = .failed
                    pendingUserInputCalls.removeAll()
                    activeTools.removeAll()
                    lastUpdatedAt = eventDate
                    events = appendingTaskActivityEvent(
                        TaskActivityEvent(
                            kind: .lifecycle,
                            occurredAt: eventDate,
                            text: "任务失败"
                        ),
                        to: events
                    )
                } else if payloadType == "agent_message",
                          ["commentary", "final_answer"].contains(
                              (payload["phase"] as? String)?.lowercased() ?? ""
                          ),
                          let message = payload["message"] as? String,
                          let commentary = sanitizedPublicCommentary(message)
                {
                    if latestPublicCommentary != commentary {
                        latestPublicCommentary = commentary
                        publicCommentaryText = appendingTaskActivityParagraph(
                            commentary,
                            to: publicCommentaryText
                        )
                        events = appendingTaskActivityEvent(
                            TaskActivityEvent(
                                kind: .commentary,
                                occurredAt: eventDate,
                                text: commentary
                            ),
                            to: events
                        )
                    }
                    lastUpdatedAt = eventDate
                }
                continue
            }

            if ["function_call", "custom_tool_call"].contains(payloadType),
               let name = payload["name"] as? String,
               let callID = payload["call_id"] as? String
            {
                let eventDate = timestamp(from: record) ?? lastUpdatedAt
                lastUpdatedAt = eventDate
                if name == "request_user_input" {
                    pendingUserInputCalls.insert(callID)
                    activeTools.removeValue(forKey: callID)
                    events = appendingTaskActivityEvent(
                        TaskActivityEvent(
                            kind: .lifecycle,
                            occurredAt: eventDate,
                            text: "等待输入"
                        ),
                        to: events
                    )
                } else {
                    let toolActivity = safeToolActivity(name: name)
                    activeTools[callID] = (
                        text: toolActivity,
                        updatedAt: eventDate
                    )
                    events = appendingTaskActivityEvent(
                        TaskActivityEvent(
                            kind: .tool,
                            occurredAt: eventDate,
                            text: toolActivity
                        ),
                        to: events
                    )
                }
                continue
            }

            if ["function_call_output", "custom_tool_call_output"].contains(payloadType),
               let callID = payload["call_id"] as? String
            {
                let wasPendingInput = pendingUserInputCalls.remove(callID) != nil
                let wasActiveTool = activeTools.removeValue(forKey: callID) != nil
                if wasPendingInput || wasActiveTool {
                    lastUpdatedAt = timestamp(from: record) ?? lastUpdatedAt
                }
            }
        }

        let title = activeTaskTitle ?? latestUserTitle ?? "Codex 任务"
        if lifecycle == .running, !pendingUserInputCalls.isEmpty {
            return TaskProgressSnapshot(items: [TaskProgressItem(
                title: title,
                kind: .waitingForInput,
                startedAt: taskStartedAt,
                updatedAt: lastUpdatedAt,
                workingDirectory: workingDirectory,
                events: events
            )])
        }
        if let lifecycle {
            let activityText: String?
            if lifecycle == .running {
                activityText = runningActivityText(
                    activeTools: activeTools,
                    publicCommentaryText: publicCommentaryText
                )
            } else {
                activityText = nil
            }
            return TaskProgressSnapshot(items: [TaskProgressItem(
                title: title,
                kind: lifecycle,
                startedAt: taskStartedAt,
                updatedAt: lastUpdatedAt,
                activityText: activityText,
                workingDirectory: workingDirectory,
                events: events
            )])
        }
        if !pendingUserInputCalls.isEmpty {
            return TaskProgressSnapshot(items: [TaskProgressItem(
                title: title,
                kind: .waitingForInput,
                startedAt: taskStartedAt,
                updatedAt: lastUpdatedAt,
                workingDirectory: workingDirectory,
                events: events
            )])
        }
        if now.timeIntervalSince(modificationDate) <= 30 * 60 {
            return TaskProgressSnapshot(items: [TaskProgressItem(
                title: title,
                kind: .running,
                startedAt: taskStartedAt,
                updatedAt: lastUpdatedAt,
                activityText: runningActivityText(
                    activeTools: activeTools,
                    publicCommentaryText: publicCommentaryText
                ),
                workingDirectory: workingDirectory,
                events: events
            )])
        }
        return .idle
    }

    private static func runningActivityText(
        activeTools: [String: (text: String, updatedAt: Date)],
        publicCommentaryText: String
    ) -> String {
        let activeTool = activeTools.values.max {
            $0.updatedAt < $1.updatedAt
        }?.text
        let sections = [
            activeTool,
            publicCommentaryText.isEmpty ? nil : publicCommentaryText,
        ].compactMap { $0 }
        return sections.isEmpty
            ? "正在思考"
            : sections.joined(separator: " · ")
    }

    private static func safeToolActivity(name: String) -> String {
        switch name.lowercased() {
        case "exec_command":
            return "正在运行命令"
        case "apply_patch":
            return "正在编辑文件"
        case let value
            where value.contains("web")
                || value.contains("browser")
                || value.contains("search"):
            return "正在搜索或检查网页"
        default:
            return "正在使用工具"
        }
    }

    private static func sanitizedPublicCommentary(_ message: String) -> String? {
        let markdownPatterns: [(String, String)] = [
            (#"!\[[^\]]*\]\([^)]+\)"#, ""),
            (#"\[([^\]]+)\]\([^)]+\)"#, "$1"),
            (#"[`*_>#~-]+"#, ""),
        ]
        var lines = message.components(separatedBy: .newlines).map {
            rawLine -> String in
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            for (pattern, replacement) in markdownPatterns {
                line = line.replacingOccurrences(
                    of: pattern,
                    with: replacement,
                    options: .regularExpression
                )
            }
            line = line.replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            return line
        }
        while lines.first?.isEmpty == true {
            lines.removeFirst()
        }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        let joined = lines.joined(separator: " ")
        return safePublicActivityParagraph(from: joined)
    }

    private static func taskTitle(from rawMessage: String) -> String? {
        var value = rawMessage
        if let marker = value.range(
            of: "## My request for Codex:",
            options: [.caseInsensitive]
        ) {
            value = String(value[marker.upperBound...])
        }
        if let imageTag = value.range(of: "<image", options: [.caseInsensitive]) {
            value = String(value[..<imageTag.lowerBound])
        }

        let lines = value.components(separatedBy: .newlines).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("# Files mentioned"),
                  !trimmed.hasPrefix("## My request"),
                  !trimmed.hasPrefix("/")
            else { return nil }
            return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "#*- "))
        }
        let title = lines.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return String(title.prefix(80))
    }

    private static func timestamp(from record: [String: Any]) -> Date? {
        guard let raw = record["timestamp"] as? String else { return nil }
        return iso8601WithFractional.date(from: raw) ?? iso8601.date(from: raw)
    }

    static func threadID(from rolloutURL: URL) -> String? {
        let filename = rolloutURL.deletingPathExtension().lastPathComponent
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        guard let range = filename.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return String(filename[range]).lowercased()
    }

    static func resolvedTitle(
        for rolloutURL: URL,
        indexedTitles: [String: String],
        fallback: String
    ) -> String {
        guard let threadID = threadID(from: rolloutURL),
              let indexedTitle = indexedTitles[threadID],
              !indexedTitle.isEmpty
        else { return fallback }
        return indexedTitle
    }

    static func isUserVisibleSessionMetadata(
        line: String,
        explicitlyVisible: Bool = false
    ) -> Bool {
        guard let data = line.data(using: .utf8),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              record["type"] as? String == "session_meta",
              let payload = record["payload"] as? [String: Any]
        else {
            return true
        }

        let threadSource = (payload["thread_source"] as? String)?.lowercased()
        if threadSource == "automation" {
            return false
        }
        let isSubagent = threadSource == "subagent"
            || (payload["source"] as? [String: Any])?["subagent"] != nil
        if isSubagent {
            return explicitlyVisible
        }
        return true
    }

    static func workingDirectoryFromSessionMetadata(line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              record["type"] as? String == "session_meta",
              let payload = record["payload"] as? [String: Any],
              let rawCwd = payload["cwd"] as? String
        else { return nil }
        return normalizedAbsolutePath(rawCwd)
    }

    static func shouldDisplay(
        kind: TaskProgressKind,
        threadID: String?,
        modificationDate: Date,
        now: Date,
        unreadState: UnreadThreadState,
        fallbackVisibility: TimeInterval = completedTaskPanelRetention,
        activeVisibility: TimeInterval = 30 * 60,
        terminalDate: Date? = nil
    ) -> Bool {
        if kind == .completed || kind == .failed {
            guard taskIsWithinTerminalPanelRetention(
                kind: kind,
                updatedAt: terminalDate ?? modificationDate,
                now: now,
                retention: fallbackVisibility
            ) else { return false }
            if unreadState.isAvailable, let threadID {
                return unreadState.ids.contains(threadID)
            }
            return true
        }
        if kind == .running || kind == .waitingForInput || kind == .reading {
            if unreadState.isAvailable,
               let threadID,
               unreadState.ids.contains(threadID)
            {
                return true
            }
            return now.timeIntervalSince(modificationDate) <= activeVisibility
        }
        return true
    }

    private func codexHomeURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    private func readThreadTitleIndex() -> [String: String] {
        let indexURL = codexHomeURL().appendingPathComponent("session_index.jsonl")
        guard let values = try? indexURL.resourceValues(
            forKeys: [.contentModificationDateKey, .isRegularFileKey]
        ),
        values.isRegularFile == true,
        let modificationDate = values.contentModificationDate
        else {
            return cachedThreadTitles
        }

        if cachedThreadIndexModificationDate == modificationDate {
            return cachedThreadTitles
        }
        guard let data = try? Data(contentsOf: indexURL),
              let text = String(data: data, encoding: .utf8)
        else {
            return cachedThreadTitles
        }

        var titles: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = String(line).data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let rawID = record["id"] as? String,
                  let rawTitle = record["thread_name"] as? String
            else { continue }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            titles[rawID.lowercased()] = String(title.prefix(80))
        }

        cachedThreadTitles = titles
        cachedThreadIndexModificationDate = modificationDate
        return titles
    }

    private func readUnreadThreadState() -> UnreadThreadState {
        let stateURL: URL
        if let override = ProcessInfo.processInfo.environment["THREADHELM_CODEX_STATE_FILE"],
           !override.isEmpty
        {
            stateURL = URL(fileURLWithPath: override)
        } else {
            stateURL = codexHomeURL().appendingPathComponent(".codex-global-state.json")
        }

        guard let values = try? stateURL.resourceValues(
            forKeys: [.contentModificationDateKey, .isRegularFileKey]
        ),
        values.isRegularFile == true,
        let modificationDate = values.contentModificationDate
        else {
            return UnreadThreadState(
                ids: cachedUnreadThreadIDs,
                explicitlyVisibleIDs: cachedExplicitlyVisibleThreadIDs,
                isAvailable: hasCachedUnreadState
            )
        }
        if cachedUnreadStateModificationDate == modificationDate {
            return UnreadThreadState(
                ids: cachedUnreadThreadIDs,
                explicitlyVisibleIDs: cachedExplicitlyVisibleThreadIDs,
                isAvailable: hasCachedUnreadState
            )
        }

        guard let data = try? Data(contentsOf: stateURL),
              let state = Self.threadState(from: data)
        else {
            return UnreadThreadState(
                ids: cachedUnreadThreadIDs,
                explicitlyVisibleIDs: cachedExplicitlyVisibleThreadIDs,
                isAvailable: hasCachedUnreadState
            )
        }
        cachedUnreadThreadIDs = state.ids
        cachedExplicitlyVisibleThreadIDs = state.explicitlyVisibleIDs
        cachedUnreadStateModificationDate = modificationDate
        hasCachedUnreadState = state.isAvailable
        nextRolloutScanAt = .distantPast
        return state
    }

    static func threadState(from data: Data) -> UnreadThreadState? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let atomState = root["electron-persisted-atom-state"] as? [String: Any]
        let unreadByHost = atomState?["unread-thread-ids-by-host-v1"] as? [String: Any]
        var unreadIDs = Set<String>()
        for value in unreadByHost?.values ?? Dictionary<String, Any>().values {
            guard let hostIDs = value as? [String] else { continue }
            unreadIDs.formUnion(hostIDs.map { $0.lowercased() })
        }

        var explicitlyVisibleIDs = Set<String>()
        for key in ["pinned-thread-ids", "projectless-thread-ids"] {
            guard let ids = root[key] as? [String] else { continue }
            explicitlyVisibleIDs.formUnion(ids.map { $0.lowercased() })
        }
        if let assignments = root["thread-project-assignments"] as? [String: Any] {
            explicitlyVisibleIDs.formUnion(assignments.keys.map { $0.lowercased() })
        }

        return UnreadThreadState(
            ids: unreadIDs,
            explicitlyVisibleIDs: explicitlyVisibleIDs,
            isAvailable: unreadByHost != nil
        )
    }

    private func recentRollouts(
        at now: Date,
        unreadThreadIDs: Set<String>,
        explicitlyVisibleThreadIDs: Set<String>
    ) -> [RolloutCandidate] {
        if let override = ProcessInfo.processInfo.environment["THREADHELM_TASK_ROLLOUT_FILE"],
           !override.isEmpty
        {
            let url = URL(fileURLWithPath: override)
            guard isUserVisibleRollout(
                url,
                explicitlyVisibleThreadIDs: explicitlyVisibleThreadIDs
            ) else { return [] }
            let modified = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? now
            return [RolloutCandidate(url: url, modificationDate: modified)]
        }

        if now < nextRolloutScanAt, !cachedRollouts.isEmpty {
            return cachedRollouts.filter { fileManager.fileExists(atPath: $0.url.path) }
        }

        nextRolloutScanAt = now.addingTimeInterval(rolloutRescanInterval)
        let codexHome = codexHomeURL()
        let sessionsURL = codexHome.appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            cachedRollouts = []
            return []
        }

        var candidates: [RolloutCandidate] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-"),
                  let values = try? url.resourceValues(
                      forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate
            else { continue }
            let threadID = Self.threadID(from: url)
            let isUnread = threadID.map { unreadThreadIDs.contains($0) } ?? false
            let scanVisibility = max(
                activeTaskFreshness,
                completedTaskVisibility
            )
            guard now.timeIntervalSince(modified) <= scanVisibility || isUnread,
                  isUserVisibleRollout(
                      url,
                      explicitlyVisibleThreadIDs: explicitlyVisibleThreadIDs
                  )
            else {
                continue
            }
            candidates.append(RolloutCandidate(url: url, modificationDate: modified))
        }

        cachedRollouts = Array(candidates.sorted {
            $0.modificationDate > $1.modificationDate
        }.prefix(12))
        let activePaths = Set(cachedRollouts.map { $0.url.path })
        parsedCache = parsedCache.filter { activePaths.contains($0.key) }
        return cachedRollouts
    }

    private func readSessionMetadata(from url: URL) -> RolloutSessionMetadata {
        if let cached = cachedSessionMetadata[url.path] { return cached }
        var firstLine: String?
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 262_144),
               let text = String(data: data, encoding: .utf8),
               let line = text.split(separator: "\n", maxSplits: 1).first
            {
                firstLine = String(line)
            }
        }
        let metadata = RolloutSessionMetadata(
            firstLine: firstLine,
            workingDirectory: firstLine.flatMap(
                Self.workingDirectoryFromSessionMetadata(line:)
            )
        )
        cachedSessionMetadata[url.path] = metadata
        return metadata
    }

    private func isUserVisibleRollout(
        _ url: URL,
        explicitlyVisibleThreadIDs: Set<String>
    ) -> Bool {
        let explicitlyVisible = Self.threadID(from: url).map {
            explicitlyVisibleThreadIDs.contains($0)
        } ?? false
        let cacheKey = "\(url.path)#\(explicitlyVisible ? "explicit" : "default")"
        if let cached = cachedRolloutVisibility[cacheKey] { return cached }
        var isVisible = true
        if let firstLine = readSessionMetadata(from: url).firstLine {
            isVisible = Self.isUserVisibleSessionMetadata(
                line: firstLine,
                explicitlyVisible: explicitlyVisible
            )
        }
        cachedRolloutVisibility[cacheKey] = isVisible
        return isVisible
    }

    private func readTailLinesColdScan(
        reader: TranscriptEventReader,
        url: URL
    ) -> [String] {
        let fileSize = (try? fileManager.attributesOfItem(
            atPath: url.path
        )[.size] as? NSNumber)?.uint64Value ?? 0
        // 有界回扫：从 EOF 向前读 8 MiB/pass，最多 64 MiB。
        // 冷启动后前向 fence 设为 fileSize（只读追加）。
        reader.setCommittedOffset(fileSize)
        var budget = TranscriptReadBudget.transcriptEvents
            .maximumAutomaticBackscanBytes
        var endOffset = fileSize
        var lines: [String] = []
        while budget > 0, endOffset > 0 {
            let passBytes = min(budget, 8 * 1_048_576)
            let result = reader.readBackwardPass(
                fromEnd: endOffset,
                maximumBytes: passBytes
            )
            guard case .success(let (records, cont)) = result else { break }
            let passLines = records.compactMap {
                String(data: $0.data, encoding: .utf8)
            }
            lines = passLines + lines
            budget -= passBytes
            if let cont = cont {
                endOffset = cont
            } else {
                break
            }
            if lines.count >= 200 { break }
        }
        return lines
    }

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601 = ISO8601DateFormatter()
}
