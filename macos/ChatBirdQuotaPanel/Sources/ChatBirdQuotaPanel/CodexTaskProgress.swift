//
//  CodexTaskProgress.swift
//  ChatBirdQuotaPanel
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
        let isAvailable: Bool
    }

    private struct RolloutCandidate {
        let url: URL
        let modificationDate: Date
    }

    private struct ParsedCacheEntry {
        let modificationDate: Date
        let snapshot: TaskProgressSnapshot
    }

    private let fileManager = FileManager.default
    private let maximumTailBytes: UInt64 = 1_048_576
    private let rolloutRescanInterval: TimeInterval = codexTaskProgressRescanInterval
    private let activeTaskFreshness: TimeInterval = 30 * 60
    private let completedTaskVisibility: TimeInterval = 2 * 60
    private var cachedRollouts: [RolloutCandidate] = []
    private var cachedRolloutVisibility: [String: Bool] = [:]
    private var parsedCache: [String: ParsedCacheEntry] = [:]
    private var cachedThreadTitles: [String: String] = [:]
    private var cachedThreadIndexModificationDate: Date?
    private var cachedUnreadThreadIDs = Set<String>()
    private var cachedUnreadStateModificationDate: Date?
    private var hasCachedUnreadState = false
    private var nextRolloutScanAt = Date.distantPast

    func read() -> TaskProgressSnapshot {
        let now = Date()
        let threadTitles = readThreadTitleIndex()
        let unreadState = readUnreadThreadState()
        var items: [TaskProgressItem] = []
        for candidate in recentRollouts(at: now, unreadThreadIDs: unreadState.ids) {
            let cacheKey = candidate.url.path
            let snapshot: TaskProgressSnapshot
            if let cached = parsedCache[cacheKey],
               cached.modificationDate == candidate.modificationDate
            {
                snapshot = cached.snapshot
            } else {
                guard let lines = readTailLines(from: candidate.url) else { continue }
                snapshot = Self.parse(
                    lines: lines,
                    modificationDate: candidate.modificationDate,
                    now: now
                )
                parsedCache[cacheKey] = ParsedCacheEntry(
                    modificationDate: candidate.modificationDate,
                    snapshot: snapshot
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
                threadID: threadID
            )
            guard Self.shouldDisplay(
                kind: item.kind,
                threadID: threadID,
                modificationDate: candidate.modificationDate,
                now: now,
                unreadState: unreadState,
                fallbackVisibility: completedTaskVisibility
            ) else { continue }
            items.append(item)
        }

        items.sort {
            if $0.updatedAt == $1.updatedAt { return $0.title < $1.title }
            return $0.updatedAt > $1.updatedAt
        }
        return .displaying(items)
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
            else { continue }

            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = record["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String
            else { continue }

            if record["type"] as? String == "event_msg" {
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
                    taskStartedAt = timestamp(from: record) ?? modificationDate
                    lastUpdatedAt = timestamp(from: record) ?? modificationDate
                } else if payloadType == "task_complete" {
                    lifecycle = .completed
                    pendingUserInputCalls.removeAll()
                    activeTools.removeAll()
                    lastUpdatedAt = timestamp(from: record) ?? lastUpdatedAt
                } else if ["task_failed", "turn_aborted", "error"].contains(payloadType) {
                    lifecycle = .failed
                    pendingUserInputCalls.removeAll()
                    activeTools.removeAll()
                    lastUpdatedAt = timestamp(from: record) ?? lastUpdatedAt
                } else if payloadType == "agent_message",
                          payload["phase"] as? String == "commentary",
                          let message = payload["message"] as? String,
                          let commentary = sanitizedPublicCommentary(message)
                {
                    if latestPublicCommentary != commentary {
                        latestPublicCommentary = commentary
                        publicCommentaryText = appendingTaskActivityParagraph(
                            commentary,
                            to: publicCommentaryText
                        )
                    }
                    lastUpdatedAt = timestamp(from: record) ?? lastUpdatedAt
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
                } else {
                    activeTools[callID] = (
                        text: safeToolActivity(name: name),
                        updatedAt: eventDate
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
                updatedAt: lastUpdatedAt
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
                activityText: activityText
            )])
        }
        if !pendingUserInputCalls.isEmpty {
            return TaskProgressSnapshot(items: [TaskProgressItem(
                title: title,
                kind: .waitingForInput,
                startedAt: taskStartedAt,
                updatedAt: lastUpdatedAt
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
                )
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
        return joined.isEmpty ? nil : joined
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

    static func isUserVisibleSessionMetadata(line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              record["type"] as? String == "session_meta",
              let payload = record["payload"] as? [String: Any]
        else {
            return true
        }

        let threadSource = (payload["thread_source"] as? String)?.lowercased()
        if threadSource == "subagent" || threadSource == "automation" {
            return false
        }
        if let source = payload["source"] as? [String: Any], source["subagent"] != nil {
            return false
        }
        return true
    }

    static func shouldDisplay(
        kind: TaskProgressKind,
        threadID: String?,
        modificationDate: Date,
        now: Date,
        unreadState: UnreadThreadState,
        fallbackVisibility: TimeInterval = 2 * 60
    ) -> Bool {
        guard kind == .completed || kind == .failed else { return true }
        if unreadState.isAvailable, let threadID {
            return unreadState.ids.contains(threadID)
        }
        return now.timeIntervalSince(modificationDate) <= fallbackVisibility
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
        if let override = ProcessInfo.processInfo.environment["CHATBIRD_CODEX_STATE_FILE"],
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
                isAvailable: hasCachedUnreadState
            )
        }
        if cachedUnreadStateModificationDate == modificationDate {
            return UnreadThreadState(
                ids: cachedUnreadThreadIDs,
                isAvailable: hasCachedUnreadState
            )
        }

        guard let data = try? Data(contentsOf: stateURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let atomState = root["electron-persisted-atom-state"] as? [String: Any],
              let unreadByHost = atomState["unread-thread-ids-by-host-v1"] as? [String: Any]
        else {
            return UnreadThreadState(
                ids: cachedUnreadThreadIDs,
                isAvailable: hasCachedUnreadState
            )
        }

        var ids = Set<String>()
        for value in unreadByHost.values {
            guard let hostIDs = value as? [String] else { continue }
            ids.formUnion(hostIDs.map { $0.lowercased() })
        }
        cachedUnreadThreadIDs = ids
        cachedUnreadStateModificationDate = modificationDate
        hasCachedUnreadState = true
        return UnreadThreadState(ids: ids, isAvailable: true)
    }

    private func recentRollouts(
        at now: Date,
        unreadThreadIDs: Set<String>
    ) -> [RolloutCandidate] {
        if let override = ProcessInfo.processInfo.environment["CHATBIRD_TASK_ROLLOUT_FILE"],
           !override.isEmpty
        {
            let url = URL(fileURLWithPath: override)
            guard isUserVisibleRollout(url) else { return [] }
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
            guard now.timeIntervalSince(modified) <= activeTaskFreshness || isUnread,
                  isUserVisibleRollout(url)
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

    private func isUserVisibleRollout(_ url: URL) -> Bool {
        if let cached = cachedRolloutVisibility[url.path] { return cached }

        var isVisible = true
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 262_144),
               let text = String(data: data, encoding: .utf8),
               let firstLine = text.split(separator: "\n", maxSplits: 1).first
            {
                isVisible = Self.isUserVisibleSessionMetadata(line: String(firstLine))
            }
        }
        cachedRolloutVisibility[url.path] = isVisible
        return isVisible
    }

    private func readTailLines(from url: URL) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let startOffset = fileSize > maximumTailBytes ? fileSize - maximumTailBytes : 0
        do {
            try handle.seek(toOffset: startOffset)
            guard var data = try handle.readToEnd(), !data.isEmpty else { return [] }
            if startOffset > 0, let firstNewline = data.firstIndex(of: 0x0A) {
                data.removeSubrange(...firstNewline)
            }
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return text.split(whereSeparator: \.isNewline).map(String.init)
        } catch {
            return nil
        }
    }

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601 = ISO8601DateFormatter()
}
