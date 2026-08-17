//
//  OMPLocalSession.swift
//  ThreadHelm
//
//  模块职责：从 OMP 本机会话尾部恢复工作目录和可公开的 assistant 文本。
//  thinking、工具参数和工具结果不会进入任务面板。
//

import Foundation

struct OMPLocalSessionContent: Equatable {
    let workingDirectory: String?
    let events: [TaskActivityEvent]
}

enum OMPLocalSession {
    static let maximumVisibleEvents = 32

    private struct CachedContent {
        let modificationDate: Date
        let fileSize: Int
        let content: OMPLocalSessionContent
    }

    /// 持久会话状态：跨刷新保留 reader 和回扫进度。
    /// 前向 reader 的 committedOffset 锁在 snapshotEOF（发现时的文件大小），
    /// 只读追加部分；回扫 continuation 单独向后移动。
    private struct SessionState {
        var identity: TranscriptSourceIdentity
        var snapshotEOF: UInt64
        var forwardReader: TranscriptEventReader
        var backscanContinuation: UInt64?
        var backscanBudget: Int
        var recoveredWorkingDirectory: String?
        var metadataProbeComplete: Bool
        var recoveredDescriptors: [TranscriptRecordLocation]
        var recoveredEvents: [TaskActivityEvent]
    }

    private static let cacheLock = NSLock()
    private static var sessionURLCache: [String: URL] = [:]
    private static var contentCache: [String: CachedContent] = [:]
    private static var sessionStateCache: [String: SessionState] = [:]

    static func content(sessionID: String) -> OMPLocalSessionContent? {
        content(
            sessionID: sessionID,
            sessionsRoot: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    ".omp/agent/sessions",
                    isDirectory: true
                )
        )
    }

    static func content(
        sessionID: String,
        sessionsRoot: URL,
        fileManager: FileManager = .default
    ) -> OMPLocalSessionContent? {
        guard let normalizedSessionID = normalizedOMPSessionID(sessionID),
              let transcriptURL = locateTranscript(
                  sessionID: normalizedSessionID,
                  sessionsRoot: sessionsRoot,
                  fileManager: fileManager
              ),
              let values = try? transcriptURL.resourceValues(forKeys: [
                  .contentModificationDateKey,
                  .fileSizeKey,
                  .isRegularFileKey,
              ]),
              values.isRegularFile == true,
              let modificationDate = values.contentModificationDate,
              let fileSize = values.fileSize
        else { return nil }

        let cacheKey = transcriptURL.standardizedFileURL.path

        // 构造 reader 前置：identity 校验必须在缓存快速路径之前，
        // 否则原子替换（同 mtime/size）会返回旧 inode 的缓存内容（AC-08）。
        guard let reader = TranscriptEventReader.make(
            at: transcriptURL,
            fileManager: fileManager
        ) else { return nil }

        let fileSize64 = UInt64(fileSize)

        // 取持久状态并做 identity 校验。
        cacheLock.lock()
        var state = sessionStateCache[cacheKey]
        var needsColdStart = false
        if let existingState = state,
           existingState.identity != reader.identity
            || fileSize64 < existingState.snapshotEOF
        {
            sessionStateCache[cacheKey] = nil
            contentCache[cacheKey] = nil
            needsColdStart = true
        }
        cacheLock.unlock()
        if needsColdStart { state = nil }

        // 内容缓存命中检查（identity 已校验）。两个条件都要满足：
        // 1) 同一 mtime/size（文件未变）
        // 2) 回扫已耗尽 且 前向 reader 已到 EOF（scanHead >= fileSize）
        // 文件不变但回扫未完成时，继续一轮回扫。
        cacheLock.lock()
        if let cached = contentCache[cacheKey],
           cached.modificationDate == modificationDate,
           cached.fileSize == fileSize
        {
            let backscanDone = (state?.backscanBudget ?? 0) <= 0
            let forwardCaughtUp = (state?.forwardReader.scanHead ?? 0)
                >= fileSize64
            if backscanDone && forwardCaughtUp {
                cacheLock.unlock()
                return cached.content
            }
        }
        cacheLock.unlock()

        if state == nil {
            // 冷启动：先查 sidecar index（§4.2）。identity 匹配时从
            // checkpoint.committedOffset 恢复前向游标，从 byte range
            // descriptors 回读 record 重建 recoveredEvents（index-hit 路径）。
            let indexStore = TranscriptIndexStore(
                rootDirectory: TranscriptIndexStore.defaultRootDirectory,
                fileManager: fileManager
            )
            let checkpoint = indexStore.load(
                agentID: .omp,
                sessionKey: normalizedSessionID
            )
            if let checkpoint = checkpoint,
               checkpoint.sourceIdentity == reader.identity,
               checkpoint.committedOffset <= fileSize64
            {
                // Index-hit：从 descriptor 回读 record data。
                var restoredEvents: [TaskActivityEvent] = []
                for descriptor in checkpoint.publicMessageDescriptors {
                    if let data = reader.readRange(descriptor),
                       let decoded = decodeRecord(data),
                       let event = decoded.event
                    {
                        restoredEvents.append(event)
                    }
                }
                reader.setCommittedOffset(checkpoint.committedOffset)
                state = SessionState(
                        identity: reader.identity,
                        snapshotEOF: fileSize64,
                        forwardReader: reader,
                        backscanContinuation: checkpoint.backscanContinuationOffset,
                        backscanBudget: checkpoint.backscanContinuationOffset != nil
                            ? TranscriptReadBudget.transcriptEvents.maximumAutomaticBackscanBytes
                            : 0,
                        recoveredWorkingDirectory: nil,
                        metadataProbeComplete: false,
                        recoveredDescriptors: [],
                        recoveredEvents: restoredEvents
                )
            } else {
                // 无 sidecar 或 identity 不匹配：冷启动回扫。
                reader.setCommittedOffset(fileSize64)
                state = SessionState(
                        identity: reader.identity,
                        snapshotEOF: fileSize64,
                        forwardReader: reader,
                        backscanContinuation: fileSize64,
                        backscanBudget: TranscriptReadBudget.transcriptEvents
                            .maximumAutomaticBackscanBytes,
                        recoveredWorkingDirectory: nil,
                        metadataProbeComplete: false,
                        recoveredDescriptors: [],
                        recoveredEvents: []
                )
            }
        }

        guard var state = state else { return nil }
        // §5.1.2: 冷启动时从文件头做有界前缀探测（1 MiB），恢复第一条
        // `session` record 的 cwd。正文依赖回扫，cwd 不依赖回扫——
        // session record 可能在 8 MiB 回扫窗口之外（大文件头部）。
        // 只探测一次：即使 cwd 为 nil（文件无 session record）也不重复。
        if !state.metadataProbeComplete {
            state.metadataProbeComplete = true
            state.recoveredWorkingDirectory = probeWorkingDirectory(
                at: transcriptURL,
                fileManager: fileManager
            )
        }

        // 一轮回扫（最多 8 MiB，一轮 pass）。文件不变也能继续。
        if state.backscanBudget > 0,
           let endOffset = state.backscanContinuation,
           endOffset > 0 {
            let passBytes = min(state.backscanBudget, 8 * 1_048_576)
            let result = state.forwardReader.readBackwardPass(
                fromEnd: endOffset,
                maximumBytes: passBytes
            )
            if case .success(let (records, cont)) = result {
                var batchEvents: [TaskActivityEvent] = []
                var batchDescriptors: [TranscriptRecordLocation] = []
                for record in records {
                    if let decoded = decodeRecord(record.data) {
                        if let cwd = decoded.workingDirectory {
                            state.recoveredWorkingDirectory = cwd
                        }
                        if let event = decoded.event {
                            batchEvents.append(event)
                            batchDescriptors.append(
                                TranscriptRecordLocation(
                                    startOffset: record.startOffset,
                                    byteCount: UInt32(record.byteCount),
                                    sourceOrder: record.sourceOrder,
                                    eventClass: .publicMessage,
                                    occurredAt: event.occurredAt
                                )
                            )
                        }
                    }
                }
                state.recoveredEvents = batchEvents + state.recoveredEvents
                state.recoveredDescriptors = batchDescriptors + state.recoveredDescriptors
                if state.recoveredEvents.count > maximumVisibleEvents {
                    state.recoveredEvents = Array(state.recoveredEvents.suffix(maximumVisibleEvents))
                    state.recoveredDescriptors = Array(state.recoveredDescriptors.suffix(maximumVisibleEvents))
                }
                state.backscanContinuation = cont
                state.backscanBudget -= passBytes
                if state.recoveredEvents.count >= maximumVisibleEvents {
                    state.backscanBudget = 0
                }
            } else {
                state.backscanBudget = 0
            }
        }

        // 一轮前向增量：从 snapshotEOF fence 读追加部分。前向 reader 的
        // committedOffset 锁在 fence，不设为回扫 continuation（否则重读）。
        let forwardResult = state.forwardReader.readForwardPass()
        if case .success(let records) = forwardResult {
            for record in records {
                if let decoded = decodeRecord(record.data) {
                    if let cwd = decoded.workingDirectory {
                        state.recoveredWorkingDirectory = cwd
                    }
                    if let event = decoded.event {
                        state.recoveredEvents.append(event)
                        state.recoveredDescriptors.append(
                            TranscriptRecordLocation(
                                startOffset: record.startOffset,
                                byteCount: UInt32(record.byteCount),
                                sourceOrder: record.sourceOrder,
                                eventClass: .publicMessage,
                                occurredAt: event.occurredAt
                            )
                        )
                    }
                }
            }
            if state.recoveredEvents.count > maximumVisibleEvents {
                state.recoveredEvents = Array(state.recoveredEvents.suffix(maximumVisibleEvents))
                state.recoveredDescriptors = Array(state.recoveredDescriptors.suffix(maximumVisibleEvents))
            }
        }

        // 更新 fence 到当前文件大小（只追加增长时安全）。
        let currentSize = (try? fileManager.attributesOfItem(
            atPath: transcriptURL.path
        )[.size] as? NSNumber)?.uint64Value ?? state.snapshotEOF
        if currentSize >= state.snapshotEOF {
            state.snapshotEOF = currentSize
        }

        // §4.2: 保存 checkpoint sidecar（committedOffset + continuation +
        // publicMessage descriptors）。metadata-only，不含正文/工具参数。
        let indexStore = TranscriptIndexStore(
            rootDirectory: TranscriptIndexStore.defaultRootDirectory,
            fileManager: fileManager
        )
        let mtime = (try? fileManager.attributesOfItem(
            atPath: transcriptURL.path
        )[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let descriptors = Array(state.recoveredDescriptors.prefix(
            TranscriptIndexStore.maximumPublicMessages
        ))
        let checkpoint = TranscriptIndexStore.Checkpoint(
            schemaVersion: TranscriptIndexStore.schemaVersion,
            agentID: .omp,
            sessionKeyDigest: normalizedSessionID,
            sourceIdentity: state.identity,
            observedSize: state.snapshotEOF,
            observedMTime: UInt64(mtime),
            committedOffset: state.forwardReader.committedOffset,
            backscanContinuationOffset: state.backscanContinuation,
            publicMessageDescriptors: descriptors,
            currentToolDescriptor: nil,
            terminalDescriptor: nil,
            metadataDescriptor: nil,
            oversizedRecords: 0
        )
        try? indexStore.save(checkpoint, agentID: .omp, sessionKey: normalizedSessionID)
        let events = Array(state.recoveredEvents.suffix(maximumVisibleEvents))
        let parsed = OMPLocalSessionContent(
            workingDirectory: state.recoveredWorkingDirectory,
            events: events
        )
        guard parsed.workingDirectory != nil || !parsed.events.isEmpty else {
            cacheLock.lock()
            sessionStateCache[cacheKey] = state
            cacheLock.unlock()
            return nil
        }

        cacheLock.lock()
        sessionStateCache[cacheKey] = state
        contentCache[cacheKey] = CachedContent(
            modificationDate: modificationDate,
            fileSize: fileSize,
            content: parsed
        )
        cacheLock.unlock()
        return parsed
    }

    private struct DecodedRecord {
        let workingDirectory: String?
        let event: TaskActivityEvent?
    }

    private static func decodeRecord(_ data: Data) -> DecodedRecord? {
        guard let record = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        else { return nil }
        let type = (record["type"] as? String)?.lowercased()
        if type == "session",
           let cwd = record["cwd"] as? String,
           let normalized = normalizedAbsolutePath(cwd)
        {
            return DecodedRecord(workingDirectory: normalized, event: nil)
        }
        guard type == "message",
              let message = record["message"] as? [String: Any],
              (message["role"] as? String)?.lowercased() == "assistant",
              let content = message["content"] as? [[String: Any]]
        else { return nil }
        let timestamp = self.timestamp(from: record, message: message)
            ?? .distantPast
        for block in content {
            guard (block["type"] as? String)?.lowercased() == "text",
                  let text = block["text"] as? String,
                  let paragraph = safePublicActivityParagraph(from: text)
            else { continue }
            return DecodedRecord(
                workingDirectory: nil,
                event: TaskActivityEvent(
                    kind: .commentary,
                    occurredAt: timestamp,
                    text: paragraph
                )
            )
        }
        return nil
    }

    /// §5.1.2: 从文件头有界前缀探测（1 MiB budget）恢复 cwd。
    /// 使用 TranscriptEventReader 而非裸 FileHandle：享受读前/读后
    /// identity/truncation 校验（AC-08），避免 replace 时合并不同 inode。
    private static func probeWorkingDirectory(
        at url: URL,
        fileManager: FileManager
    ) -> String? {
        let probeBudget = TranscriptReadBudget(
            chunkBytes: 1_048_576,
            maximumBytesPerPass: 1_048_576,
            maximumAutomaticBackscanBytes: 0,
            maximumRecordBytes: TranscriptReadBudget.transcriptEvents
                .maximumRecordBytes,
            softWallTime: TranscriptReadBudget.transcriptEvents.softWallTime
        )
        guard let probeReader = TranscriptEventReader.make(
            at: url,
            budget: probeBudget,
            fileManager: fileManager
        ) else { return nil }
        let result = probeReader.readForwardPass()
        guard case .success(let records) = result else { return nil }
        for record in records {
            if let decoded = decodeRecord(record.data),
               let cwd = decoded.workingDirectory
            {
                return cwd
            }
        }
        return nil
    }

    static func content(fromJSONL text: String) -> OMPLocalSessionContent {
        var workingDirectory: String?
        var events: [TaskActivityEvent] = []

        for line in text.split(whereSeparator: \Character.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
            else { continue }
            let type = (record["type"] as? String)?.lowercased()
            if type == "session",
               let cwd = record["cwd"] as? String,
               let normalized = normalizedAbsolutePath(cwd)
            {
                workingDirectory = normalized
                continue
            }
            guard type == "message",
                  let message = record["message"] as? [String: Any],
                  (message["role"] as? String)?.lowercased() == "assistant",
                  let content = message["content"] as? [[String: Any]]
            else { continue }
            let timestamp = timestamp(from: record, message: message)
                ?? .distantPast
            for block in content {
                guard (block["type"] as? String)?.lowercased() == "text",
                      let text = block["text"] as? String,
                      let paragraph = safePublicActivityParagraph(from: text)
                else { continue }
                events = appendingTaskActivityEvent(
                    TaskActivityEvent(
                        kind: .commentary,
                        occurredAt: timestamp,
                        text: paragraph
                    ),
                    to: events
                )
            }
        }

        return OMPLocalSessionContent(
            workingDirectory: workingDirectory,
            events: Array(events.suffix(maximumVisibleEvents))
        )
    }

    private static func locateTranscript(
        sessionID: String,
        sessionsRoot: URL,
        fileManager: FileManager
    ) -> URL? {
        let root = sessionsRoot.standardizedFileURL.resolvingSymlinksInPath()
        let cacheKey = "\(root.path)\u{0}\(sessionID)"
        cacheLock.lock()
        let cachedURL = sessionURLCache[cacheKey]
        cacheLock.unlock()
        if let cachedURL, fileManager.fileExists(atPath: cachedURL.path) {
            return cachedURL
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return nil }
        let suffix = "_\(sessionID).jsonl"
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for case let candidate as URL in enumerator {
            guard candidate.lastPathComponent.hasSuffix(suffix),
                  (try? candidate.resourceValues(
                      forKeys: [.isRegularFileKey]
                  ).isRegularFile) == true
            else { continue }
            let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(rootPrefix) else { continue }
            cacheLock.lock()
            sessionURLCache[cacheKey] = resolved
            cacheLock.unlock()
            return resolved
        }
        return nil
    }


    private static func timestamp(
        from record: [String: Any],
        message: [String: Any]
    ) -> Date? {
        guard let value = record["timestamp"] as? String
                ?? message["timestamp"] as? String
        else { return nil }
        return iso8601WithFractional.date(from: value) ?? iso8601.date(from: value)
    }

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601 = ISO8601DateFormatter()
}
