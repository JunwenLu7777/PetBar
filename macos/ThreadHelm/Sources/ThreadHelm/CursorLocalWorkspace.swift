//
//  CursorLocalWorkspace.swift
//  ThreadHelm
//
//  模块职责：在 GUI 进程里用 Cursor 本机 transcript 和会话索引还原工作目录、
//  侧边栏标题和可公开活动正文。不把路径、提示或工具参数写回 hook 传输。
//

import Foundation
import SQLite3

struct CursorLocalActivityFragment: Equatable {
    let kind: TaskActivityEventKind
    let text: String
}

struct CursorConversationMetadata: Equatable {
    let title: String?
    let activityText: String?
    let fragments: [CursorLocalActivityFragment]

    init(
        title: String?,
        activityText: String? = nil,
        fragments: [CursorLocalActivityFragment] = []
    ) {
        self.title = title
        self.activityText = activityText
        self.fragments = fragments
    }
}

struct CursorLocalSessionContent: Equatable {
    let title: String?
    let activityText: String?
    let completedActivityText: String?
    let fragments: [CursorLocalActivityFragment]
}

enum CursorLocalWorkspace {
    static let maximumVisibleEvents = 32

    private static let cacheLock = NSLock()
    private static var contentCache: [String: CachedTranscript] = [:]
    static var mockIndexRootDirectory: URL?
    /// 测试钩子：模拟进程重启，清空内存缓存（sidecar 保留）。
    static func resetInMemoryStateForTesting() {
        cacheLock.lock()
        contentCache.removeAll()
        cacheLock.unlock()
    }

    private struct CachedTranscript {
        let modificationDate: Date
        let content: CursorLocalSessionContent
    }

    static func workingDirectory(sessionID: String) -> String? {
        workingDirectory(
            sessionID: sessionID,
            projectsRoot: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cursor/projects", isDirectory: true)
        )
    }

    static func workingDirectory(
        sessionID: String,
        projectsRoot: URL,
        fileManager: FileManager = .default,
        resolvedPathExists: ((String) -> Bool)? = nil
    ) -> String? {
        guard let match = locateSession(
            sessionID: sessionID,
            projectsRoot: projectsRoot,
            fileManager: fileManager
        ) else { return nil }
        let pathExists = resolvedPathExists ?? { path in
            fileManager.fileExists(atPath: path)
        }
        return decodeProjectSlug(match.projectSlug, pathExists: pathExists)
    }

    static func sessionContent(sessionID: String) -> CursorLocalSessionContent? {
        sessionContent(
            sessionID: sessionID,
            projectsRoot: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cursor/projects", isDirectory: true),
            conversationMetadata: { conversationMetadata(sessionID: $0) }
        )
    }

    static func sessionContent(
        sessionID: String,
        projectsRoot: URL,
        fileManager: FileManager = .default,
        conversationMetadata: ((String) -> CursorConversationMetadata?)? = nil
    ) -> CursorLocalSessionContent? {
        guard let match = locateSession(
            sessionID: sessionID,
            projectsRoot: projectsRoot,
            fileManager: fileManager
        ) else { return nil }
        let nativeID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let metadata = conversationMetadata?(nativeID)
        let parsed = match.transcriptURL.flatMap {
            cachedContent(
                at: $0,
                fileManager: fileManager,
                indexRootDirectory: CursorLocalWorkspace.mockIndexRootDirectory
            )
        } ?? CursorLocalSessionContent(
            title: nil,
            activityText: nil,
            completedActivityText: nil,
            fragments: []
        )
        let content = overlaying(parsed, with: metadata)
        guard content.title != nil
                || content.activityText != nil
                || !content.fragments.isEmpty
        else { return nil }
        return content
    }

    static func sessionContent(fromJSONL text: String) -> CursorLocalSessionContent {
        parseTranscript(text)
    }

    static func overlaying(
        _ content: CursorLocalSessionContent,
        with metadata: CursorConversationMetadata?
    ) -> CursorLocalSessionContent {
        let title = trimmedNonEmpty(metadata?.title) ?? content.title
        let composerText = trimmedNonEmpty(metadata?.activityText)
        let activityText = composerText ?? content.activityText
        let completedActivityText = composerText ?? content.completedActivityText
        let fragments = metadata?.fragments.isEmpty == false
            ? metadata!.fragments
            : content.fragments
        guard title != content.title
                || activityText != content.activityText
                || completedActivityText != content.completedActivityText
                || fragments != content.fragments
        else { return content }
        return CursorLocalSessionContent(
            title: title,
            activityText: activityText,
            completedActivityText: completedActivityText,
            fragments: fragments
        )
    }

    static func conversationMetadata(
        sessionID: String,
        conversationSearchURL: URL = defaultConversationSearchDatabaseURL,
        composerStateURL: URL = defaultComposerStateDatabaseURL
    ) -> CursorConversationMetadata? {
        let nativeID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard nativeID.count >= 8,
              nativeID != "unidentified",
              !nativeID.hasPrefix("unknown-")
        else { return nil }

        let searchTitle = sqliteQueryText(
            databaseURL: conversationSearchURL,
            sql: "SELECT title FROM conversations WHERE id = ? LIMIT 1",
            bind: nativeID
        )
        let composerTitle = sqliteQueryText(
            databaseURL: composerStateURL,
            sql: "SELECT json_extract(value, '$.name') FROM cursorDiskKV WHERE key = ? LIMIT 1",
            bind: "composerData:\(nativeID)"
        )
        let title = (trimmedNonEmpty(searchTitle) ?? trimmedNonEmpty(composerTitle))
            .map { String($0.prefix(80)) }
        let composerFragments = composerPublicActivityFragments(
            sessionID: nativeID,
            databaseURL: composerStateURL
        )
        let activityText = composerFragments.last?.text
        guard title != nil || activityText != nil else { return nil }
        return CursorConversationMetadata(
            title: title,
            activityText: activityText,
            fragments: composerFragments
        )
    }

    private static func composerPublicActivityFragments(
        sessionID: String,
        databaseURL: URL
    ) -> [CursorLocalActivityFragment] {
        let sql = """
        WITH composer(value) AS (
          SELECT value
          FROM cursorDiskKV
          WHERE key = 'composerData:' || ?1
          LIMIT 1
        ),
        headers(position, header) AS (
          SELECT CAST(entry.key AS INTEGER), entry.value
          FROM composer,
               json_each(
                 json_extract(composer.value, '$.fullConversationHeadersOnly')
               ) AS entry
        )
        SELECT
          CAST(json_extract(bubble.value, '$.type') AS TEXT),
          json_extract(bubble.value, '$.text'),
          json_extract(headers.header, '$.grouping.textPreview')
        FROM headers
        LEFT JOIN cursorDiskKV AS bubble
          ON bubble.key = 'bubbleId:' || ?1 || ':'
            || json_extract(headers.header, '$.bubbleId')
        WHERE CAST(json_extract(headers.header, '$.type') AS INTEGER) = 2
          AND json_extract(headers.header, '$.grouping.isRenderable') = 1
          AND json_extract(headers.header, '$.grouping.hasText') = 1
        ORDER BY headers.position
        """
        guard let rows = sqliteQueryTextRows(
            databaseURL: databaseURL,
            sql: sql,
            bind: sessionID,
            columns: 3
        ) else { return [] }
        return rows.reduce(into: []) { fragments, row in
            let fullText = row[0] == "2" ? row[1] : nil
            let candidate = trimmedNonEmpty(fullText) ?? trimmedNonEmpty(row[2])
            guard let candidate,
                  let paragraph = safePublicActivityParagraph(from: candidate)
            else { return }
            fragments = appendingCursorFragment(
                CursorLocalActivityFragment(
                    kind: .commentary,
                    text: paragraph
                ),
                to: fragments
            )
        }
    }

    static var defaultConversationSearchDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Cursor/User/globalStorage/conversation-search.db"
            )
    }

    static var defaultComposerStateDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
            )
    }

    static func datedEvents(
        from fragments: [CursorLocalActivityFragment],
        startedAt: Date,
        updatedAt: Date
    ) -> [TaskActivityEvent] {
        let rows = fragments.suffix(maximumVisibleEvents)
        guard !rows.isEmpty else { return [] }
        if rows.count == 1 {
            return [
                TaskActivityEvent(
                    kind: rows[rows.startIndex].kind,
                    occurredAt: updatedAt,
                    text: rows[rows.startIndex].text
                )
            ]
        }
        let span = max(updatedAt.timeIntervalSince(startedAt), 0)
        return rows.enumerated().map { index, fragment in
            let fraction = Double(index) / Double(rows.count - 1)
            return TaskActivityEvent(
                kind: fragment.kind,
                occurredAt: startedAt.addingTimeInterval(span * fraction),
                text: fragment.text
            )
        }
    }

    static func decodeProjectSlug(
        _ slug: String,
        pathExists: (String) -> Bool
    ) -> String? {
        if slug == "empty-window" || slug.hasPrefix("var-folders-") {
            return nil
        }
        let parts = slug.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return nil }

        var consumed = 0
        var current = ""
        while consumed < parts.count {
            var matched: String?
            for end in stride(from: parts.count, through: consumed + 1, by: -1) {
                let component = parts[consumed..<end].joined(separator: "-")
                let candidate = current + "/" + component
                if pathExists(candidate) {
                    matched = candidate
                    consumed = end
                    break
                }
            }
            guard let next = matched else { return nil }
            current = next
        }
        return current
    }

    static func activityEvents(from events: [AgentEvent]) -> [TaskActivityEvent] {
        let rows = events.compactMap(activityEvent(from:)).sorted {
            if $0.occurredAt == $1.occurredAt {
                return $0.text < $1.text
            }
            return $0.occurredAt < $1.occurredAt
        }
        if rows.count <= maximumVisibleEvents {
            return rows
        }
        return Array(rows.suffix(maximumVisibleEvents))
    }

    static func activityEvent(from event: AgentEvent) -> TaskActivityEvent? {
        let text: String
        let kind: TaskActivityEventKind
        switch event.eventType.lowercased() {
        case "sessionstart", "session_start":
            kind = .lifecycle
            text = "会话开始"
        case "sessionend", "session_end":
            kind = .lifecycle
            text = "会话结束"
        case "beforesubmitprompt", "userpromptsubmit":
            kind = .commentary
            text = "提交提示"
        case "pretooluse", "tool_call",
             "beforeshellexecution", "beforemcpexecution", "beforereadfile":
            kind = .tool
            text = "准备调用工具"
        case "posttooluse", "tool_result",
             "aftershellexecution", "aftermcpexecution", "afterfileedit":
            kind = .tool
            text = "工具调用完成"
        case "posttoolusefailure":
            kind = .tool
            text = "工具调用失败"
        case "stop", "agent_settled", "agent_end":
            kind = .lifecycle
            text = "本轮结束"
        case "subagentstart", "agent_start":
            kind = .lifecycle
            text = "启动子任务"
        case "subagentstop":
            kind = .lifecycle
            text = "子任务结束"
        default:
            return nil
        }
        return TaskActivityEvent(
            kind: kind,
            occurredAt: event.observedAt,
            text: text
        )
    }

    private static func locateSession(
        sessionID: String,
        projectsRoot: URL,
        fileManager: FileManager
    ) -> (projectSlug: String, transcriptURL: URL?)? {
        let nativeID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard nativeID.count >= 8,
              nativeID != "unidentified",
              !nativeID.hasPrefix("unknown-")
        else { return nil }

        guard let projects = try? fileManager.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for projectURL in projects.sorted(by: { $0.path < $1.path }) {
            let transcripts = projectURL.appendingPathComponent(
                "agent-transcripts",
                isDirectory: true
            )
            let sessionDirectory = transcripts.appendingPathComponent(
                nativeID,
                isDirectory: true
            )
            let nestedFile = sessionDirectory.appendingPathComponent(
                "\(nativeID).jsonl"
            )
            let flatFile = transcripts.appendingPathComponent(
                "\(nativeID).jsonl"
            )
            var isDirectory: ObjCBool = false
            let directoryExists = fileManager.fileExists(
                atPath: sessionDirectory.path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
            let transcriptURL: URL?
            if fileManager.fileExists(atPath: nestedFile.path) {
                transcriptURL = nestedFile
            } else if fileManager.fileExists(atPath: flatFile.path) {
                transcriptURL = flatFile
            } else if directoryExists {
                transcriptURL = nil
            } else {
                continue
            }
            return (projectURL.lastPathComponent, transcriptURL)
        }
        return nil
    }

    private static func cachedContent(
        at url: URL,
        fileManager: FileManager,
        indexRootDirectory: URL? = nil
    ) -> CursorLocalSessionContent? {
        let indexRoot = indexRootDirectory
            ?? TranscriptIndexStore.defaultRootDirectory
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let modificationDate = attributes?[.modificationDate] as? Date
            ?? Date.distantPast
        let cacheKey = url.path
        cacheLock.lock()
        if let cached = contentCache[cacheKey],
           cached.modificationDate == modificationDate
        {
            cacheLock.unlock()
            return cached.content
        }
        cacheLock.unlock()

        guard let reader = TranscriptEventReader.make(
            at: url,
            fileManager: fileManager
        ) else { return nil }

        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0

        // §4.2: 先查 sidecar index。identity 匹配时从 descriptor 回读
        // record data（index-hit），跳过回扫。
        let sessionKey = url.deletingPathExtension().lastPathComponent
        let indexStore = TranscriptIndexStore(
            rootDirectory: indexRoot,
            fileManager: fileManager
        )
        let checkpoint = indexStore.load(
            agentID: .cursor, sessionKey: sessionKey
        )
        if let checkpoint = checkpoint,
           checkpoint.sourceIdentity == reader.identity,
           checkpoint.committedOffset <= fileSize
        {
            var restoredData = Data()
            var restoredCurrentToolData = Data()
            // mixed record 的 range 同时出现在 public descriptors 与
            // currentToolDescriptor：public 恢复已含其 data，单独恢复
            // 会重复拼行。构建 public range 集合做去重。
            let publicRanges = Set(
                checkpoint.publicMessageDescriptors.map {
                    "\($0.startOffset)-\($0.byteCount)"
                }
            )
            // 先回读 current-tool descriptor（活动工具状态独立持久化，
            // 不受 32 条 public 窗口挤出影响，§4.2）。
            if let toolDescriptor = checkpoint.currentToolDescriptor,
               !publicRanges.contains(
                   "\(toolDescriptor.startOffset)-\(toolDescriptor.byteCount)"
               ),
               let data = reader.readRange(toolDescriptor) {
                restoredCurrentToolData = data
            }
            // public descriptors 按 sourceOrder 升序存储；按序 append 恢复顺序。
            for descriptor in checkpoint.publicMessageDescriptors {
                if let data = reader.readRange(descriptor) {
                    restoredData.append(data)
                }
            }
            // Index-hit 后从旧 committedOffset 做 forward-tail，读取
            // checkpoint 到当前 EOF 之间的追加字节（§4.2）。
            reader.setCommittedOffset(checkpoint.committedOffset)
            let forwardResult = reader.readForwardPass()
            var appendedData = Data()
            var appendedDescriptors: [TranscriptRecordLocation] = []
            var appendedCurrentToolDescriptor: TranscriptRecordLocation?
            if case .success(let forwardRecords) = forwardResult {
                for record in forwardRecords {
                    let cls = classifyCursorRecord(record.data)
                    // 分类非互斥：mixed record（text + tool_use）必须同时
                    // 更新 public 与 current-tool 通道（raw data 只拼一次）。
                    if cls.isPublic {
                        appendedData.append(record.data)
                        appendedDescriptors.append(
                            TranscriptRecordLocation(
                                startOffset: record.startOffset,
                                byteCount: UInt32(record.byteCount),
                                sourceOrder: record.sourceOrder,
                                eventClass: .publicMessage,
                                occurredAt: nil
                            )
                        )
                    }
                    if cls.isCurrentTool {
                        appendedCurrentToolDescriptor =
                            TranscriptRecordLocation(
                                startOffset: record.startOffset,
                                byteCount: UInt32(record.byteCount),
                                sourceOrder: record.sourceOrder,
                                eventClass: .currentTool,
                                occurredAt: nil
                            )
                        if !cls.isPublic {
                            // 纯 tool record 才把 data 拼入文本流；
                            // mixed record 的 data 已由 public 分支拼入。
                            appendedData.append(record.data)
                        }
                    }
                }
            }
            // 合并旧 descriptors + 追加 descriptors，截断到上限。
            var allDescriptors = checkpoint.publicMessageDescriptors
                + appendedDescriptors
            if allDescriptors.count
                > TranscriptIndexStore.maximumPublicMessages
            {
                allDescriptors = Array(allDescriptors.suffix(
                    TranscriptIndexStore.maximumPublicMessages
                ))
            }
            // 最新 current-tool descriptor：追加的优先，否则取恢复的旧值。
            let currentToolDescriptor = appendedCurrentToolDescriptor
                ?? checkpoint.currentToolDescriptor
            if !restoredData.isEmpty || !appendedData.isEmpty
                || !restoredCurrentToolData.isEmpty {
                // 顺序与冷扫描一致（chronological）：current-tool 记录在
                // public 文本之前（mixed 记录含 text，拼在末尾会覆盖
                // latestPublicText）。latestTool 按文本中最后 tool 取，
                // 顺序正确时自然指向最近的 tool。
                let allData = restoredCurrentToolData
                    + restoredData + appendedData
                let text = String(data: allData, encoding: .utf8)
                    ?? String(decoding: allData, as: UTF8.self)
                let content = parseTranscript(text)
                // 仅当前向已追平（scanHead 到 EOF）才缓存；否则 mtime
                // 命中会返回部分内容。未追平时下次调用经 index-hit 继续。
                if reader.scanHeadReachedEOF {
                    cacheLock.lock()
                    contentCache[cacheKey] = CachedTranscript(
                        modificationDate: modificationDate,
                        content: content
                    )
                    cacheLock.unlock()
                }
                // 保存 checkpoint：committedOffset 推进到前向 pass 停点
                // （最后完整 LF；预算受限/末尾未完成时 < fileSize）。
                let mtime = (attributes?[.modificationDate] as? Date)?
                    .timeIntervalSince1970 ?? 0
                let cp = TranscriptIndexStore.Checkpoint(
                    schemaVersion: TranscriptIndexStore.schemaVersion,
                    agentID: .cursor,
                    sessionKeyDigest: sessionKey,
                    sourceIdentity: reader.identity,
                    observedSize: fileSize,
                    observedMTime: UInt64(mtime),
                    committedOffset: reader.committedOffset,
                    backscanContinuationOffset: nil,
                    publicMessageDescriptors: allDescriptors,
                    currentToolDescriptor: currentToolDescriptor,
                    terminalDescriptor: nil,
                    metadataDescriptor: nil,
                    oversizedRecords: 0
                )
                try? indexStore.save(
                    cp, agentID: .cursor, sessionKey: sessionKey
                )
                return content
            }
        }

        // 有界回扫：从 EOF 向前读 8 MiB/pass，最多 64 MiB。
        // 只收集完整 LF 记录（片段由 reader 丢弃），拼成文本交给
        // 现有 parseTranscript——替代旧的 1 MiB 固定尾读。
        var backscanBudget = TranscriptReadBudget.transcriptEvents
            .maximumAutomaticBackscanBytes
        var enoughContent = false
        var committedAfterScan = fileSize
        var currentToolDescriptor: TranscriptRecordLocation?
        var currentToolData = Data()
        var endOffset = fileSize
        var recoveredData = Data()
        var descriptors: [TranscriptRecordLocation] = []
        while backscanBudget > 0, endOffset > 0 {
            let passBytes = min(backscanBudget, 8 * 1_048_576)
            let result = reader.readBackwardPass(
                fromEnd: endOffset,
                maximumBytes: passBytes
            )
            guard case .success(let (records, cont, trailingPartial)) = result
            else { break }
            if let trailingPartial, trailingPartial < committedAfterScan {
                committedAfterScan = trailingPartial
            }
            var passData = Data()
            var passDescriptors: [TranscriptRecordLocation] = []
            for record in records {
                let cls = classifyCursorRecord(record.data)
                // 分类非互斥：mixed record（text + tool_use）必须同时
                // 更新 public 与 current-tool 通道（raw data 只拼一次）。
                if cls.isPublic {
                    passData.append(record.data)
                    passDescriptors.append(
                        TranscriptRecordLocation(
                            startOffset: record.startOffset,
                            byteCount: UInt32(record.byteCount),
                            sourceOrder: record.sourceOrder,
                            eventClass: .publicMessage,
                            occurredAt: nil
                        )
                    )
                }
                if cls.isCurrentTool {
                    // 最新 tool 记录独立持久化（不被 32 条 public 窗口挤出）。
                    currentToolDescriptor = TranscriptRecordLocation(
                        startOffset: record.startOffset,
                        byteCount: UInt32(record.byteCount),
                        sourceOrder: record.sourceOrder,
                        eventClass: .currentTool,
                        occurredAt: nil
                    )
                    if !cls.isPublic {
                        // 纯 tool record 的 data 才进入 currentToolData；
                        // mixed record 的 data 已在 public 通道（重复解析
                        // 会把 latestPublicText 错误覆盖为 mixed 文本）。
                        currentToolData = record.data
                    }
                }
            }
            // 更早的窗口 prepend。
            recoveredData = passData + recoveredData
            descriptors = passDescriptors + descriptors
            backscanBudget -= passBytes
            if let cont = cont {
                endOffset = cont
            } else {
                break
            }
            if recoveredData.count
                >= Int(TranscriptReadBudget.transcriptEvents.maximumBytesPerPass)
            {
                enoughContent = true
                break
            }
        }
        // 冷扫描完成：提交点推进到回扫覆盖的末尾。无 trailing partial
        // 时 = fileSize；有 partial 时 = 最后完整 LF。与 Codex/Claude
        // cold scan 一致——否则 checkpoint 保存 reader.committedOffset(0)，
        // index-hit 会从文件头 forward 重放。
        reader.setCommittedOffset(committedAfterScan)
        // 持久 checkpoint 停在最后完整 LF 后（末尾未完成行不计入）。
        // tool 记录放最后：parseTranscript 的 latestTool 取末尾 tool。
        let allData = recoveredData + currentToolData
        let text = String(data: allData, encoding: .utf8)
            ?? String(decoding: allData, as: UTF8.self)
        let content = parseTranscript(text)
        if reader.scanHeadReachedEOF || committedAfterScan >= fileSize {
            cacheLock.lock()
            contentCache[cacheKey] = CachedTranscript(
                modificationDate: modificationDate,
                content: content
            )
            cacheLock.unlock()
        }
        // §4.2: 保存 checkpoint sidecar（metadata-only）。
        let mtime = (attributes?[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let cpDescriptors = Array(descriptors.suffix(
            TranscriptIndexStore.maximumPublicMessages
        ))
        let cp = TranscriptIndexStore.Checkpoint(
            schemaVersion: TranscriptIndexStore.schemaVersion,
            agentID: .cursor,
            sessionKeyDigest: sessionKey,
            sourceIdentity: reader.identity,
            observedSize: fileSize,
            observedMTime: UInt64(mtime),
            committedOffset: reader.committedOffset,
            backscanContinuationOffset: nil,
            publicMessageDescriptors: cpDescriptors,
            currentToolDescriptor: currentToolDescriptor,
            terminalDescriptor: nil,
            metadataDescriptor: nil,
            oversizedRecords: 0
        )
        try? indexStore.save(
            cp, agentID: .cursor, sessionKey: sessionKey
        )
        return content
    }

    private static func parseTranscript(_ text: String) -> CursorLocalSessionContent {
        var title: String?
        var fragments: [CursorLocalActivityFragment] = []
        var latestPublicText: String?
        var latestTool: String?

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
            else { continue }
            let role = ((record["role"] as? String) ?? (record["type"] as? String))?
                .lowercased()
            if role == "turn_ended" || record["type"] as? String == "turn_ended" {
                continue
            }
            let message = record["message"] as? [String: Any]
            let blocks = contentBlocks(from: message?["content"] ?? record["content"])
            if role == "user" {
                let userText = blocks.compactMap { block -> String? in
                    guard block.type == "text" else { return nil }
                    return block.text
                }.joined(separator: " ")
                if title == nil, let nextTitle = cursorTaskTitle(from: userText) {
                    title = nextTitle
                }
                continue
            }
            guard role == "assistant" else { continue }
            for block in blocks {
                if block.type == "text",
                   let text = block.text,
                   let paragraph = safePublicActivityParagraph(from: text)
                {
                    latestPublicText = paragraph
                    fragments = appendingCursorFragment(
                        CursorLocalActivityFragment(
                            kind: .commentary,
                            text: paragraph
                        ),
                        to: fragments
                    )
                    continue
                }
                guard block.type == "tool_use" || block.type == "tool-use",
                      let name = block.name
                else { continue }
                let toolActivity = cursorSafeToolActivity(name: name)
                latestTool = toolActivity
                fragments = appendingCursorFragment(
                    CursorLocalActivityFragment(
                        kind: .tool,
                        text: toolActivity
                    ),
                    to: fragments
                )
            }
        }

        let completedActivityText = latestPublicText ?? (fragments.isEmpty
            ? nil
            : fragments.map(\.text).joined(separator: " · "))
        return CursorLocalSessionContent(
            title: title,
            activityText: latestPublicText ?? latestTool,
            completedActivityText: completedActivityText,
            fragments: fragments
        )
    }
}

/// 分类一条 Cursor JSONL record：
/// - public: assistant text 或 user text（后者用于 title 提取）
/// - currentTool: assistant tool_use / tool-use block（活动工具状态）
/// 两者都不是 → 两个都为 false。
private func classifyCursorRecord(
    _ data: Data
) -> (isPublic: Bool, isCurrentTool: Bool) {
    guard let record = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any]
    else { return (false, false) }
    let role = ((record["role"] as? String) ?? (record["type"] as? String))?
        .lowercased()
    guard role == "assistant" || role == "user" else { return (false, false) }
    let message = record["message"] as? [String: Any]
    let blocks = contentBlocks(from: message?["content"] ?? record["content"])
    var isPublic = false
    var isCurrentTool = false
    for block in blocks {
        if (block.type == "text" || role == "user"), block.text != nil {
            // user text 也保留：parseTranscript 用它提取 title。
            isPublic = true
        }
        if role == "assistant",
           (block.type == "tool_use" || block.type == "tool-use"),
           block.name != nil {
            isCurrentTool = true
        }
    }
    return (isPublic, isCurrentTool)
}

private struct CursorTranscriptBlock {
    let type: String
    let text: String?
    let name: String?
}

private func contentBlocks(from value: Any?) -> [CursorTranscriptBlock] {
    if let text = value as? String {
        return [CursorTranscriptBlock(type: "text", text: text, name: nil)]
    }
    guard let items = value as? [[String: Any]] else { return [] }
    return items.compactMap { item in
        let type = (item["type"] as? String)?.lowercased() ?? ""
        return CursorTranscriptBlock(
            type: type,
            text: item["text"] as? String,
            name: item["name"] as? String
        )
    }
}

private func appendingCursorFragment(
    _ fragment: CursorLocalActivityFragment,
    to fragments: [CursorLocalActivityFragment]
) -> [CursorLocalActivityFragment] {
    // §4.4: 禁止 kind+text 去重。相同文本但不同 byte range 的消息
    // 必须同时保留。
    var next = fragments
    next.append(fragment)
    return next
}

private func cursorTaskTitle(from rawText: String) -> String? {
    var value = rawText
    if let start = value.range(of: "<user_query>"),
       let end = value.range(of: "</user_query>")
    {
        value = String(value[start.upperBound..<end.lowerBound])
    }
    value = value.replacingOccurrences(
        of: #"\[Image\]"#,
        with: " ",
        options: .regularExpression
    )
    value = value.replacingOccurrences(
        of: #"<[^>]+>"#,
        with: " ",
        options: .regularExpression
    )
    let skippedPrefixes = [
        "the following images were provided",
        "these images can be copied",
        "<image_files>",
    ]
    let lines = value.components(separatedBy: .newlines).compactMap { line -> String? in
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if skippedPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return nil
        }
        if lower.hasPrefix("<timestamp>") || lower.hasPrefix("timestamp>") {
            return nil
        }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "#*- "))
    }
    let text = lines.joined(separator: " ")
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    return String(text.prefix(80))
}

private func trimmedNonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private let sqliteTransientDestructor = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)

private func sqliteQueryText(
    databaseURL: URL,
    sql: String,
    bind: String
) -> String? {
    sqliteQueryTexts(
        databaseURL: databaseURL,
        sql: sql,
        bind: bind,
        columns: 1
    )?[0]
}

private func sqliteQueryTexts(
    databaseURL: URL,
    sql: String,
    bind: String,
    columns: Int
) -> [String?]? {
    sqliteQueryTextRows(
        databaseURL: databaseURL,
        sql: sql,
        bind: bind,
        columns: columns
    )?.first
}

private func sqliteQueryTextRows(
    databaseURL: URL,
    sql: String,
    bind: String,
    columns: Int
) -> [[String?]]? {
    guard columns > 0,
          FileManager.default.fileExists(atPath: databaseURL.path)
    else { return nil }
    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK,
          let opened = db
    else {
        if db != nil {
            sqlite3_close(db)
        }
        return nil
    }
    defer { sqlite3_close(opened) }
    sqlite3_busy_timeout(opened, 200)
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(opened, sql, -1, &statement, nil) == SQLITE_OK,
          let prepared = statement
    else { return nil }
    defer { sqlite3_finalize(prepared) }
    let bindResult = bind.withCString { pointer in
        sqlite3_bind_text(
            prepared,
            1,
            pointer,
            -1,
            sqliteTransientDestructor
        )
    }
    guard bindResult == SQLITE_OK else { return nil }
    var rows: [[String?]] = []
    while true {
        let result = sqlite3_step(prepared)
        if result == SQLITE_DONE {
            return rows
        }
        guard result == SQLITE_ROW else { return nil }
        rows.append((0..<columns).map { index in
            let column = Int32(index)
            if sqlite3_column_type(prepared, column) == SQLITE_NULL {
                return nil
            }
            guard let text = sqlite3_column_text(prepared, column) else {
                return nil
            }
            return String(cString: text)
        })
    }
}

private func cursorSafeToolActivity(name: String) -> String {
    let normalized = name.lowercased()
    if normalized.contains("ask") || normalized.contains("question") {
        return "等待输入"
    }
    if normalized.contains("shell")
        || normalized.contains("bash")
        || normalized.contains("command")
    {
        return "正在运行命令"
    }
    if normalized.contains("edit")
        || normalized.contains("write")
        || normalized.contains("patch")
        || normalized.contains("replace")
        || normalized.contains("delete")
    {
        return "正在编辑文件"
    }
    if normalized.contains("read")
        || normalized.contains("grep")
        || normalized.contains("glob")
        || normalized.contains("search")
    {
        return "正在检查文件"
    }
    if normalized.contains("web") || normalized.contains("browser") {
        return "正在搜索或检查网页"
    }
    return "正在使用工具"
}
