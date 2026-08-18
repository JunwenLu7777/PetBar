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
    let projection: AgentActivityProjection

    init(
        title: String?,
        activityText: String?,
        completedActivityText: String?,
        fragments: [CursorLocalActivityFragment],
        projection: AgentActivityProjection
    ) {
        self.title = title
        self.activityText = activityText
        self.completedActivityText = completedActivityText
        self.fragments = fragments
        self.projection = projection.budgeted()
    }
}

enum CursorLocalWorkspace {
    static let maximumVisibleEvents = 32

    private static let cacheLock = NSLock()
    private static var contentCache: [String: CachedTranscript] = [:]
    private static var sessionContentCache: [String: CursorLocalSessionContent] = [:]
    private static var sessionWorkingDirectoryCache: [String: String] = [:]
    private static var lifecycleBackscanBytes: [String: Int] = [:]
    static var mockIndexRootDirectory: URL?
    /// 测试钩子：模拟进程重启，清空内存缓存（sidecar 保留）。
    static func resetInMemoryStateForTesting() {
        cacheLock.lock()
        contentCache.removeAll()
        sessionContentCache.removeAll()
        sessionWorkingDirectoryCache.removeAll()
        lifecycleBackscanBytes.removeAll()
        cacheLock.unlock()
    }

    static func lifecycleBackscanBytesForTesting(at url: URL) -> Int {
        let cacheKey = transcriptCacheKey(for: url)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return lifecycleBackscanBytes[cacheKey] ?? 0
    }

    private static func transcriptCacheKey(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private struct CachedTranscript {
        let sourceIdentity: TranscriptSourceIdentity
        let modificationDate: Date
        let fileSize: UInt64
        let content: CursorLocalSessionContent
    }

    static func workingDirectory(sessionID: String) -> String? {
        if Thread.isMainThread {
            return cachedWorkingDirectory(sessionID: sessionID)
        }
        return workingDirectory(
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
        if Thread.isMainThread {
            return cachedSessionContent(sessionID: sessionID)
        }
        return sessionContent(
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
        let nativeID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = locateSession(
            sessionID: sessionID,
            projectsRoot: projectsRoot,
            fileManager: fileManager
        ) else {
            deleteCursorSidecar(
                sessionKey: nativeID,
                fileManager: fileManager,
                indexRootDirectory: CursorLocalWorkspace.mockIndexRootDirectory
            )
            cacheLock.lock()
            sessionContentCache.removeValue(forKey: nativeID)
            sessionWorkingDirectoryCache.removeValue(forKey: nativeID)
            cacheLock.unlock()
            return nil
        }
        if match.transcriptURL == nil {
            deleteCursorSidecar(
                sessionKey: nativeID,
                fileManager: fileManager,
                indexRootDirectory: CursorLocalWorkspace.mockIndexRootDirectory
            )
        }
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
            fragments: [],
            projection: .empty
        )
        let content = overlaying(parsed, with: metadata)
        guard content.title != nil
                || content.activityText != nil
                || !content.fragments.isEmpty
        else { return nil }
        cacheLock.lock()
        sessionContentCache[nativeID] = content
        if let directory = workingDirectory(
            sessionID: sessionID,
            projectsRoot: projectsRoot,
            fileManager: fileManager
        ) {
            sessionWorkingDirectoryCache[nativeID] = directory
        }
        cacheLock.unlock()
        return content
    }

    private static func deleteCursorSidecar(
        sessionKey: String,
        fileManager: FileManager,
        indexRootDirectory: URL? = nil
    ) {
        let indexRoot = indexRootDirectory
            ?? TranscriptIndexStore.defaultRootDirectory
        TranscriptIndexStore(
            rootDirectory: indexRoot,
            fileManager: fileManager
        ).delete(agentID: .cursor, sessionKey: sessionKey)
    }

    static func cachedSessionContent(sessionID: String) -> CursorLocalSessionContent? {
        let nativeID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return sessionContentCache[nativeID]
    }

    static func cachedWorkingDirectory(sessionID: String) -> String? {
        let nativeID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return sessionWorkingDirectoryCache[nativeID]
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
        let projection = metadata?.fragments.isEmpty == false
            ? cursorProjection(
                from: metadata!.fragments,
                source: .cursor,
                sessionKey: "",
                stablePrefix: "cursor-composer"
            )
            : content.projection
        guard title != content.title
                || activityText != content.activityText
                || completedActivityText != content.completedActivityText
                || fragments != content.fragments
                || projection != content.projection
        else { return content }
        return CursorLocalSessionContent(
            title: title,
            activityText: activityText,
            completedActivityText: completedActivityText,
            fragments: fragments,
            projection: projection
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
        let rows: [CursorLocalActivityFragment]
        if fragments.count <= maximumVisibleEvents {
            rows = fragments
        } else {
            // 按通道截断：保留最新 32 条 commentary + 最新 tool 各独立
            // 计数。混合数组整体 suffix(32) 会恰好裁掉中间的 tool，
            // 无 Hook 时 currentToolStatus 投影为 nil。
            let commentarySuffix = fragments.enumerated()
                .filter { $0.element.kind == .commentary }
                .suffix(maximumVisibleEvents)
            let latestToolIndex = fragments.lastIndex {
                $0.kind == .tool
            }
            let kept = Set(
                commentarySuffix.map(\.offset)
                    + (latestToolIndex.map { [$0] } ?? [])
            )
            rows = fragments.enumerated().compactMap {
                kept.contains($0.offset) ? $0.element : nil
            }
        }
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
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let cacheKey = transcriptCacheKey(for: url)
        // Resolve the file identity before the mtime/size cache fast path.
        // APFS atomic replacement can preserve both values while changing the
        // inode, in which case returning the old projection would be stale.
        guard let reader = TranscriptEventReader.make(
            at: url,
            fileManager: fileManager
        ) else { return nil }
        cacheLock.lock()
        if let cached = contentCache[cacheKey],
           cached.sourceIdentity == reader.identity,
           cached.modificationDate == modificationDate,
           cached.fileSize == fileSize
        {
            cacheLock.unlock()
            return cached.content
        }
        if let cached = contentCache[cacheKey],
           cached.sourceIdentity != reader.identity
        {
            contentCache.removeValue(forKey: cacheKey)
            lifecycleBackscanBytes.removeValue(forKey: cacheKey)
        }
        cacheLock.unlock()
        let refreshByteLimit = TranscriptReadBudget.transcriptEvents
            .maximumBytesPerPass
        var refreshBytesRemaining = refreshByteLimit

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
        let validCheckpoint: TranscriptIndexStore.Checkpoint?
        if let checkpoint = checkpoint,
           checkpoint.sourceIdentity == reader.identity,
           checkpoint.committedOffset <= fileSize {
            validCheckpoint = checkpoint
        } else {
            validCheckpoint = nil
        }
        if let checkpoint = validCheckpoint {
            let shouldContinueColdBackscan =
                checkpoint.backscanContinuationOffset != nil
                && checkpoint.publicMessageDescriptors.isEmpty
            // current-tool + public descriptors 统一按 startOffset 排序
            // 去重回读，保证 chronological：current-tool 可能是较旧的
            // mixed tool（已在 public 窗口）或较新的 pure tool（只在
            // currentToolDescriptor）。分别拼接会把顺序搞反，导致
            // latestTool / latestPublicText 退回旧记录。
            var unifiedDescriptors = checkpoint.publicMessageDescriptors
            if let toolDescriptor = checkpoint.currentToolDescriptor {
                unifiedDescriptors.append(toolDescriptor)
            }
            var seenDescriptorRanges = Set<String>()
            let newestUniqueDescriptors = unifiedDescriptors.sorted {
                if $0.startOffset == $1.startOffset {
                    return $0.byteCount > $1.byteCount
                }
                return $0.startOffset > $1.startOffset
            }.filter { descriptor in
                let key = "\(descriptor.startOffset):\(descriptor.byteCount)"
                if seenDescriptorRanges.contains(key) {
                    return false
                }
                seenDescriptorRanges.insert(key)
                return true
            }
            var restoredPairs:
                [(descriptor: TranscriptRecordLocation, input: CursorTranscriptRecordInput)] = []
            for descriptor in newestUniqueDescriptors {
                guard refreshBytesRemaining > 0 else { break }
                if let data = reader.readRange(
                    descriptor,
                    maximumBytes: refreshBytesRemaining
                ) {
                    restoredPairs.append((
                        descriptor,
                        cursorRecordInput(
                            data: data,
                            sourceIdentity: reader.identity,
                            startOffset: descriptor.startOffset,
                            byteCount: Int(descriptor.byteCount),
                            sourceOrder: descriptor.sourceOrder,
                            sessionKey: sessionKey
                        )
                    ))
                    refreshBytesRemaining = max(
                        0,
                        refreshByteLimit - reader.diagnostics.bytesRead
                    )
                }
            }
            restoredPairs.sort {
                if $0.descriptor.startOffset == $1.descriptor.startOffset {
                    return $0.descriptor.byteCount < $1.descriptor.byteCount
                }
                return $0.descriptor.startOffset < $1.descriptor.startOffset
            }
            let restoredInputs = restoredPairs.map(\.input)
            // Index-hit 后从旧 committedOffset 做 forward-tail，读取
            // checkpoint 到当前 EOF 之间的追加字节（§4.2）。
            var appendedInputs: [CursorTranscriptRecordInput] = []
            var appendedDescriptors: [TranscriptRecordLocation] = []
            var appendedCurrentToolDescriptor: TranscriptRecordLocation?
            var forwardCommittedOffset = checkpoint.committedOffset
            var forwardReachedEOF = false
            if refreshBytesRemaining > 0 {
                reader.setCommittedOffset(checkpoint.committedOffset)
                let forwardResult = reader.readForwardPass(
                    maximumBytes: refreshBytesRemaining
                )
                refreshBytesRemaining = max(
                    0,
                    refreshByteLimit - reader.diagnostics.bytesRead
                )
                forwardCommittedOffset = reader.committedOffset
                forwardReachedEOF = reader.scanHeadReachedEOF
                if case .success(let forwardRecords) = forwardResult {
                    for record in forwardRecords {
                        let cls = classifyCursorRecord(record.data)
                        // 分类非互斥：mixed record（text + tool_use）必须同时
                        // 更新 public 与 current-tool 通道（raw data 只拼一次）。
                        if cls.isPublic {
                            appendedInputs.append(
                                cursorRecordInput(
                                    record,
                                    sourceIdentity: reader.identity,
                                    sessionKey: sessionKey
                                )
                            )
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
                                appendedInputs.append(
                                    cursorRecordInput(
                                        record,
                                        sourceIdentity: reader.identity,
                                        sessionKey: sessionKey
                                    )
                                )
                            }
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
            let inputs = restoredInputs + appendedInputs
            let shouldContinueBackscanAfterTail =
                shouldContinueColdBackscan && allDescriptors.isEmpty
            if !inputs.isEmpty, !shouldContinueBackscanAfterTail {
                // 顺序已由统一 descriptor 回读保证 chronological
                // （current-tool + public 按 startOffset 排序），
                // forward tail 顺序追加在末。latestTool 取文本中
                // 最后 tool，即最近发生的工具活动。
                let content = parseTranscript(records: inputs)
                // 仅当前向已追平（scanHead 到 EOF）才缓存；否则 mtime
                // 命中会返回部分内容。未追平时下次调用经 index-hit 继续。
                if forwardReachedEOF {
                    cacheLock.lock()
                    contentCache[cacheKey] = CachedTranscript(
                        sourceIdentity: reader.identity,
                        modificationDate: modificationDate,
                        fileSize: fileSize,
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
                    committedOffset: forwardCommittedOffset,
                    backscanContinuationOffset: nil,
                    publicMessageDescriptors: allDescriptors,
                    currentToolDescriptor: currentToolDescriptor,
                    terminalDescriptor: nil,
                    metadataDescriptor: nil,
                    oversizedRecords: 0
                )
                if appendedDescriptors.isEmpty
                    && appendedCurrentToolDescriptor == nil
                {
                    try? indexStore.saveCoalesced(
                        cp, agentID: .cursor, sessionKey: sessionKey
                    )
                } else {
                    try? indexStore.flush(
                        cp, agentID: .cursor, sessionKey: sessionKey
                    )
                }
                return content
            }
            if refreshBytesRemaining <= 0, !inputs.isEmpty {
                return parseTranscript(records: inputs)
            }
        }

        // 有界回扫：每次调用最多从 EOF/continuation 向前读 8 MiB。
        // 同一 app lifecycle 对同一 transcript 最多自动推进 64 MiB；
        // 若尾部全是 tool-only 且尚未找到最近 public window，持久化
        // continuation，后续显式读取调用继续推进。
        // 只收集完整 LF 记录（片段由 reader 丢弃），拼成文本交给
        // 现有 parseTranscript——替代旧的 1 MiB 固定尾读。
        let maximumLifecycleBackscan = TranscriptReadBudget.transcriptEvents
            .maximumAutomaticBackscanBytes
        cacheLock.lock()
        let alreadyBackscanned = lifecycleBackscanBytes[cacheKey] ?? 0
        cacheLock.unlock()
        let continuingCheckpoint = validCheckpoint
        var committedAfterScan = continuingCheckpoint?.committedOffset
            ?? fileSize
        var currentToolDescriptor = continuingCheckpoint?.currentToolDescriptor
        var currentToolInput: CursorTranscriptRecordInput?
        if let descriptor = currentToolDescriptor,
           let data = reader.readRange(
                descriptor,
                maximumBytes: refreshBytesRemaining
           )
        {
            refreshBytesRemaining = max(
                0,
                refreshByteLimit - reader.diagnostics.bytesRead
            )
            currentToolInput = cursorRecordInput(
                data: data,
                sourceIdentity: reader.identity,
                startOffset: descriptor.startOffset,
                byteCount: Int(descriptor.byteCount),
                sourceOrder: descriptor.sourceOrder,
                sessionKey: sessionKey
            )
        }
        let remainingLifecycleBackscan = min(
            refreshBytesRemaining,
            max(
                0,
                maximumLifecycleBackscan - alreadyBackscanned
            )
        )
        let endOffset = continuingCheckpoint?.backscanContinuationOffset
            ?? fileSize
        var recoveredInputs: [CursorTranscriptRecordInput] = []
        var descriptors = continuingCheckpoint?.publicMessageDescriptors ?? []
        var nextBackscanContinuation = continuingCheckpoint?
            .backscanContinuationOffset
        if remainingLifecycleBackscan > 0, endOffset > 0 {
            let passBytes = min(
                remainingLifecycleBackscan,
                TranscriptReadBudget.transcriptEvents.maximumBytesPerPass
            )
            let bytesBeforeBackscan = reader.diagnostics.bytesRead
            let result = reader.readBackwardPass(
                fromEnd: endOffset,
                maximumBytes: passBytes
            )
            let actualBackscanBytes = max(
                0,
                reader.diagnostics.bytesRead - bytesBeforeBackscan
            )
            if actualBackscanBytes > 0 {
                cacheLock.lock()
                lifecycleBackscanBytes[cacheKey] = alreadyBackscanned
                    + actualBackscanBytes
                cacheLock.unlock()
            }
            if case .success(let (records, cont, trailingPartial)) = result {
                if let trailingPartial, trailingPartial < committedAfterScan {
                    committedAfterScan = trailingPartial
                }
                var passInputs: [CursorTranscriptRecordInput] = []
                var passDescriptors: [TranscriptRecordLocation] = []
                for record in records {
                    let cls = classifyCursorRecord(record.data)
                    // 分类非互斥：mixed record（text + tool_use）必须同时
                    // 更新 public 与 current-tool 通道（raw data 只拼一次）。
                    if cls.isPublic {
                        passInputs.append(
                            cursorRecordInput(
                                record,
                                sourceIdentity: reader.identity,
                                sessionKey: sessionKey
                            )
                        )
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
                        // 跨 pass 回扫从 EOF 向旧数据推进：更旧的 pass 后处理，
                        // 无条件覆盖会让旧 tool 顶替新的。按最大 startOffset
                        // 原子更新 descriptor+data（同一文件内 startOffset 唯一，
                        // 相等即同一条）。
                        if let existing = currentToolDescriptor,
                           record.startOffset <= existing.startOffset
                        {
                            continue
                        }
                        currentToolDescriptor = TranscriptRecordLocation(
                            startOffset: record.startOffset,
                            byteCount: UInt32(record.byteCount),
                            sourceOrder: record.sourceOrder,
                            eventClass: .currentTool,
                            occurredAt: nil
                        )
                        if cls.isPublic {
                            // mixed：data 已在 public 通道。清空 currentToolInput
                            // 避免旧 pure tool 的 data 残留末尾，latestTool 倒退。
                            currentToolInput = nil
                        } else {
                            currentToolInput = cursorRecordInput(
                                record,
                                sourceIdentity: reader.identity,
                                sessionKey: sessionKey
                            )
                        }
                    }
                }
                // 更早的窗口 prepend。
                recoveredInputs = passInputs + recoveredInputs
                descriptors = passDescriptors + descriptors
                nextBackscanContinuation = passDescriptors.isEmpty ? cont : nil
            }
        }
        // 冷扫描完成：提交点推进到回扫覆盖的末尾。无 trailing partial
        // 时 = fileSize；有 partial 时 = 最后完整 LF。与 Codex/Claude
        // cold scan 一致——否则 checkpoint 保存 reader.committedOffset(0)，
        // index-hit 会从文件头 forward 重放。
        reader.setCommittedOffset(committedAfterScan)
        // 持久 checkpoint 停在最后完整 LF 后（末尾未完成行不计入）。
        // tool 记录放最后：parseTranscript 的 latestTool 取末尾 tool。
        let inputs = recoveredInputs + (currentToolInput.map { [$0] } ?? [])
        let content = parseTranscript(records: inputs)
        if nextBackscanContinuation == nil,
           (reader.scanHeadReachedEOF || committedAfterScan >= fileSize)
        {
            cacheLock.lock()
            contentCache[cacheKey] = CachedTranscript(
                sourceIdentity: reader.identity,
                modificationDate: modificationDate,
                fileSize: fileSize,
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
            backscanContinuationOffset: nextBackscanContinuation,
            publicMessageDescriptors: cpDescriptors,
            currentToolDescriptor: currentToolDescriptor,
            terminalDescriptor: nil,
            metadataDescriptor: nil,
            oversizedRecords: 0
        )
        if nextBackscanContinuation
            != continuingCheckpoint?.backscanContinuationOffset
        {
            try? indexStore.flush(
                cp, agentID: .cursor, sessionKey: sessionKey
            )
        } else {
            try? indexStore.saveCoalesced(
                cp, agentID: .cursor, sessionKey: sessionKey
            )
        }
        return content
    }

    private static func parseTranscript(_ text: String) -> CursorLocalSessionContent {
        parseTranscript(records: cursorRecordInputs(
            text: text,
            source: .cursor,
            sessionKey: ""
        ))
    }

    private static func parseTranscript(
        records: [CursorTranscriptRecordInput]
    ) -> CursorLocalSessionContent {
        var title: String?
        var fragments: [CursorLocalActivityFragment] = []
        var latestPublicText: String?
        var latestTool: String?
        var publicMessages: [AgentActivityEntry] = []
        var currentToolStatus: AgentActivityEntry?

        for input in records {
            guard let record = try? JSONSerialization.jsonObject(with: input.data)
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
                    publicMessages.append(
                        AgentActivityEntry(
                            id: AgentActivityEventID(
                                source: input.source,
                                sessionKey: input.sessionKey,
                                stableSourceKey: "\(input.stableSourceKey):public"
                            ),
                            occurredAt: input.occurredAt,
                            sourceOrder: input.sourceOrder,
                            text: paragraph
                        )
                    )
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
                currentToolStatus = AgentActivityEntry(
                    id: AgentActivityEventID(
                        source: input.source,
                        sessionKey: input.sessionKey,
                        stableSourceKey: "\(input.stableSourceKey):tool"
                    ),
                    occurredAt: input.occurredAt,
                    sourceOrder: input.sourceOrder,
                    text: toolActivity
                )
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
            fragments: fragments,
            projection: AgentActivityProjection(
                publicMessages: publicMessages,
                currentToolStatus: currentToolStatus,
                terminalEvent: nil
            )
        )
    }
}

private struct CursorTranscriptRecordInput {
    let data: Data
    let source: AgentID
    let sessionKey: String
    let stableSourceKey: String
    let sourceOrder: UInt64
    let occurredAt: Date
}

private func cursorRecordInput(
    _ record: TranscriptRecordRange,
    sourceIdentity: TranscriptSourceIdentity,
    sessionKey: String
) -> CursorTranscriptRecordInput {
    cursorRecordInput(
        data: record.data,
        sourceIdentity: sourceIdentity,
        startOffset: record.startOffset,
        byteCount: record.byteCount,
        sourceOrder: record.sourceOrder,
        sessionKey: sessionKey
    )
}

private func cursorRecordInput(
    data: Data,
    sourceIdentity: TranscriptSourceIdentity,
    startOffset: UInt64,
    byteCount: Int,
    sourceOrder: UInt64,
    sessionKey: String
) -> CursorTranscriptRecordInput {
    CursorTranscriptRecordInput(
        data: data,
        source: .cursor,
        sessionKey: sessionKey,
        stableSourceKey: transcriptStableSourceKey(
            sourceIdentity: sourceIdentity,
            startOffset: startOffset,
            byteCount: byteCount
        ),
        sourceOrder: sourceOrder,
        occurredAt: .distantPast
    )
}

private func cursorRecordInputs(
    text: String,
    source: AgentID,
    sessionKey: String
) -> [CursorTranscriptRecordInput] {
    text.split(whereSeparator: \.isNewline).enumerated().compactMap { index, rawLine in
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = line.data(using: .utf8), !data.isEmpty else {
            return nil
        }
        return CursorTranscriptRecordInput(
            data: data,
            source: source,
            sessionKey: sessionKey,
            stableSourceKey: "line:\(index)",
            sourceOrder: UInt64(index),
            occurredAt: .distantPast
        )
    }
}

private func cursorProjection(
    from fragments: [CursorLocalActivityFragment],
    source: AgentID,
    sessionKey: String,
    stablePrefix: String
) -> AgentActivityProjection {
    var publicMessages: [AgentActivityEntry] = []
    var currentToolStatus: AgentActivityEntry?
    for (index, fragment) in fragments.enumerated() {
        let entry = AgentActivityEntry(
            id: AgentActivityEventID(
                source: source,
                sessionKey: sessionKey,
                stableSourceKey: "\(stablePrefix):\(index)"
            ),
            occurredAt: .distantPast,
            sourceOrder: UInt64(index),
            text: fragment.text
        )
        switch fragment.kind {
        case .commentary:
            publicMessages.append(entry)
        case .tool:
            currentToolStatus = entry
        case .lifecycle:
            break
        }
    }
    return AgentActivityProjection(
        publicMessages: publicMessages,
        currentToolStatus: currentToolStatus,
        terminalEvent: nil
    )
}

private func transcriptStableSourceKey(
    sourceIdentity: TranscriptSourceIdentity,
    startOffset: UInt64,
    byteCount: Int
) -> String {
    "dev:\(sourceIdentity.device):ino:\(sourceIdentity.inode):birth:\(sourceIdentity.birthSeconds).\(sourceIdentity.birthNanoseconds):range:\(startOffset)+\(byteCount)"
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
