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
    let projection: AgentActivityProjection

    init(
        workingDirectory: String?,
        projection: AgentActivityProjection
    ) {
        self.workingDirectory = workingDirectory
        self.projection = projection.budgeted()
    }

    var events: [TaskActivityEvent] {
        projection.displayEvents
    }
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
        var recoveredProjectionEntries: [AgentActivityEntry]
    }

    private static let cacheLock = NSLock()
    private static var sessionURLCache: [String: URL] = [:]
    private static var contentCache: [String: CachedContent] = [:]
    private static var sessionContentCache: [String: OMPLocalSessionContent] = [:]
    private static var sessionStateCache: [String: SessionState] = [:]

    static func resetInMemoryStateForTesting() {
        cacheLock.lock()
        sessionURLCache.removeAll()
        contentCache.removeAll()
        sessionContentCache.removeAll()
        sessionStateCache.removeAll()
        cacheLock.unlock()
    }

    static func content(sessionID: String) -> OMPLocalSessionContent? {
        if Thread.isMainThread {
            return cachedContent(sessionID: sessionID)
        }
        return content(
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
        fileManager: FileManager = .default,
        indexRootDirectory: URL? = nil
    ) -> OMPLocalSessionContent? {
        if Thread.isMainThread,
           sessionsRoot == FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".omp/agent/sessions", isDirectory: true)
        {
            return cachedContent(sessionID: sessionID)
        }
        guard let normalizedSessionID = normalizedOMPSessionID(sessionID)
        else { return nil }
        let indexRoot = indexRootDirectory
            ?? TranscriptIndexStore.defaultRootDirectory
        let maximumRefreshBytes = TranscriptReadBudget.transcriptEvents
            .maximumBytesPerPass
        var refreshBytesRead = 0
        guard let transcriptURL = locateTranscript(
            sessionID: normalizedSessionID,
            sessionsRoot: sessionsRoot,
            fileManager: fileManager
        ) else {
            TranscriptIndexStore(
                rootDirectory: indexRoot,
                fileManager: fileManager
            ).delete(agentID: .omp, sessionKey: normalizedSessionID)
            return nil
        }
        guard let values = try? transcriptURL.resourceValues(forKeys: [
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
            // descriptors 回读 record 重建 projection entries（index-hit 路径）。
            let indexStore = TranscriptIndexStore(
                rootDirectory: indexRoot,
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
                var restoredProjectionEntries: [AgentActivityEntry] = []
                let restoreDescriptors = latestDescriptorsWithinBudget(
                    checkpoint.publicMessageDescriptors,
                    maximumBytes: maximumRefreshBytes
                )
                for descriptor in restoreDescriptors {
                    let beforeBytesRead = reader.diagnostics.bytesRead
                    let remainingRangeBudget = max(
                        0,
                        maximumRefreshBytes - refreshBytesRead
                    )
                    if let data = reader.readRange(
                        descriptor,
                        maximumBytes: remainingRangeBudget
                    ),
                       let decoded = decodeRecord(
                           data,
                           sessionKey: normalizedSessionID,
                           stableSourceKey: ompTranscriptStableSourceKey(
                               sourceIdentity: reader.identity,
                               startOffset: descriptor.startOffset,
                               byteCount: Int(descriptor.byteCount)
                           ),
                           sourceOrder: descriptor.sourceOrder
                       ),
                       let entry = decoded.projectionEntry
                    {
                        restoredProjectionEntries.append(entry)
                    }
                    refreshBytesRead += max(
                        0,
                        reader.diagnostics.bytesRead - beforeBytesRead
                    )
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
                        recoveredDescriptors: checkpoint.publicMessageDescriptors,
                        recoveredProjectionEntries: restoredProjectionEntries
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
                        recoveredProjectionEntries: []
                )
            }
        }

        guard var state = state else { return nil }
        let startingBackscanContinuation = state.backscanContinuation
        let startingCommittedOffset = state.forwardReader.committedOffset
        // §5.1.2: 冷启动时从文件头做有界前缀探测（1 MiB），恢复第一条
        // `session` record 的 cwd。正文依赖回扫，cwd 不依赖回扫——
        // session record 可能在 8 MiB 回扫窗口之外（大文件头部）。
        // 只探测一次：即使 cwd 为 nil（文件无 session record）也不重复。
        let hasForwardWork = state.forwardReader.scanHead < fileSize64
        if !state.metadataProbeComplete,
           !hasForwardWork,
           refreshBytesRead < maximumRefreshBytes {
            state.metadataProbeComplete = true
            let probe = probeWorkingDirectory(
                at: transcriptURL,
                fileManager: fileManager,
                maximumBytes: maximumRefreshBytes - refreshBytesRead
            )
            refreshBytesRead += probe.bytesRead
            state.recoveredWorkingDirectory = probe.workingDirectory
        }

        // 单次 refresh 共享同一个 8 MiB I/O 预算：有增量尾部时优先
        // forward，且本轮不再 backscan；否则用剩余预算做一轮回扫。
        let remainingRefreshBudget = max(0, maximumRefreshBytes - refreshBytesRead)
        if hasForwardWork, remainingRefreshBudget > 0 {
            let beforeBytesRead = state.forwardReader.diagnostics.bytesRead
            let forwardResult = state.forwardReader.readForwardPass(
                maximumBytes: remainingRefreshBudget
            )
            refreshBytesRead += max(
                0,
                state.forwardReader.diagnostics.bytesRead - beforeBytesRead
            )
            if case .failure = forwardResult {
                // 前向读失败（truncation/identity）：backscan 预算已过期的
                // 事件仍可回落，但把 reader 复位到最后完整 LF 的安全位置，
                // 下轮刷新重读追加部分（§4.2：不得把未读字节标记为已提交）。
                state.forwardReader.resetPartialBytes()
            }
            if case .success(let records) = forwardResult {
                for record in records {
                    if let decoded = decodeRecord(
                        record.data,
                        sessionKey: normalizedSessionID,
                        stableSourceKey: ompTranscriptStableSourceKey(
                            sourceIdentity: state.identity,
                            startOffset: record.startOffset,
                            byteCount: record.byteCount
                        ),
                        sourceOrder: record.sourceOrder
                    ) {
                        if let cwd = decoded.workingDirectory {
                            state.recoveredWorkingDirectory = cwd
                        }
                        if let entry = decoded.projectionEntry {
                            state.recoveredProjectionEntries.append(entry)
                            state.recoveredDescriptors.append(
                                TranscriptRecordLocation(
                                    startOffset: record.startOffset,
                                    byteCount: UInt32(record.byteCount),
                                    sourceOrder: record.sourceOrder,
                                    eventClass: .publicMessage,
                                    occurredAt: entry.occurredAt
                                )
                            )
                        }
                    }
                }
                trimRecoveredProjection(&state)
            }
        } else if state.backscanBudget > 0,
                  remainingRefreshBudget > 0,
                  let endOffset = state.backscanContinuation,
                  endOffset > 0 {
            let passBytes = min(state.backscanBudget, remainingRefreshBudget)
            let beforeBytesRead = state.forwardReader.diagnostics.bytesRead
            let result = state.forwardReader.readBackwardPass(
                fromEnd: endOffset,
                maximumBytes: passBytes
            )
            let actualBytesRead = max(
                0,
                state.forwardReader.diagnostics.bytesRead - beforeBytesRead
            )
            refreshBytesRead += actualBytesRead
            if case .success(let (records, cont, trailingPartial)) = result {
                // 冷扫描触及文件尾且末尾未完成时，fence 停在最后完整记录后。
                if let trailingPartial, trailingPartial < state.snapshotEOF {
                    if state.forwardReader.committedOffset
                        > trailingPartial {
                        state.forwardReader.resetPartialBytes()
                    }
                    if state.forwardReader.committedOffset != trailingPartial {
                        state.forwardReader.setCommittedOffset(trailingPartial)
                    }
                }
                var batchProjectionEntries: [AgentActivityEntry] = []
                var batchDescriptors: [TranscriptRecordLocation] = []
                for record in records {
                    if let decoded = decodeRecord(
                        record.data,
                        sessionKey: normalizedSessionID,
                        stableSourceKey: ompTranscriptStableSourceKey(
                            sourceIdentity: state.identity,
                            startOffset: record.startOffset,
                            byteCount: record.byteCount
                        ),
                        sourceOrder: record.sourceOrder
                    ) {
                        if let cwd = decoded.workingDirectory {
                            state.recoveredWorkingDirectory = cwd
                        }
                        if let entry = decoded.projectionEntry {
                            batchProjectionEntries.append(entry)
                            batchDescriptors.append(
                                TranscriptRecordLocation(
                                    startOffset: record.startOffset,
                                    byteCount: UInt32(record.byteCount),
                                    sourceOrder: record.sourceOrder,
                                    eventClass: .publicMessage,
                                    occurredAt: entry.occurredAt
                                )
                            )
                        }
                    }
                }
                state.recoveredProjectionEntries =
                    batchProjectionEntries + state.recoveredProjectionEntries
                state.recoveredDescriptors = batchDescriptors + state.recoveredDescriptors
                trimRecoveredProjection(&state)
                state.backscanContinuation = cont
                state.backscanBudget = max(0, state.backscanBudget - actualBytesRead)
                if state.recoveredProjectionEntries.count >= maximumVisibleEvents {
                    state.backscanBudget = 0
                }
            } else {
                state.backscanBudget = 0
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
            rootDirectory: indexRoot,
            fileManager: fileManager
        )
        let mtime = (try? fileManager.attributesOfItem(
            atPath: transcriptURL.path
        )[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let descriptors = Array(state.recoveredDescriptors.suffix(
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
        if state.backscanContinuation != startingBackscanContinuation
            || state.forwardReader.committedOffset != startingCommittedOffset
        {
            try? indexStore.flush(
                checkpoint,
                agentID: .omp,
                sessionKey: normalizedSessionID
            )
        } else {
            try? indexStore.saveCoalesced(
                checkpoint,
                agentID: .omp,
                sessionKey: normalizedSessionID
            )
        }
        let parsed = OMPLocalSessionContent(
            workingDirectory: state.recoveredWorkingDirectory,
            projection: AgentActivityProjection(
                publicMessages: Array(
                    state.recoveredProjectionEntries.suffix(maximumVisibleEvents)
                )
            )
        )
        guard parsed.workingDirectory != nil
                || !parsed.projection.publicMessages.isEmpty else {
            cacheLock.lock()
            sessionStateCache[cacheKey] = state
            cacheLock.unlock()
            return nil
        }

        cacheLock.lock()
        sessionStateCache[cacheKey] = state
        sessionContentCache[normalizedSessionID] = parsed
        contentCache[cacheKey] = CachedContent(
            modificationDate: modificationDate,
            fileSize: fileSize,
            content: parsed
        )
        cacheLock.unlock()
        return parsed
    }

    private static func trimRecoveredProjection(_ state: inout SessionState) {
        if state.recoveredProjectionEntries.count > maximumVisibleEvents {
            state.recoveredProjectionEntries = Array(
                state.recoveredProjectionEntries.suffix(maximumVisibleEvents)
            )
            state.recoveredDescriptors = Array(
                state.recoveredDescriptors.suffix(maximumVisibleEvents)
            )
        }
    }

    private static func latestDescriptorsWithinBudget(
        _ descriptors: [TranscriptRecordLocation],
        maximumBytes: Int
    ) -> [TranscriptRecordLocation] {
        guard maximumBytes > 0 else { return [] }
        let chronological = descriptors.sorted {
            if $0.sourceOrder != $1.sourceOrder {
                return $0.sourceOrder < $1.sourceOrder
            }
            return $0.startOffset < $1.startOffset
        }
        var selected: [TranscriptRecordLocation] = []
        var usedBytes = 0
        for descriptor in chronological.reversed() {
            let byteCount = Int(descriptor.byteCount)
            guard byteCount > 0, byteCount <= maximumBytes - usedBytes
            else { continue }
            selected.append(descriptor)
            usedBytes += byteCount
        }
        return selected.reversed()
    }

    private struct DecodedRecord {
        let workingDirectory: String?
        let projectionEntry: AgentActivityEntry?
    }

    private static func decodeRecord(
        _ data: Data,
        sessionKey: String = "",
        stableSourceKey: String = "omp-record",
        sourceOrder: UInt64 = 0
    ) -> DecodedRecord? {
        guard let record = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        else { return nil }
        let type = (record["type"] as? String)?.lowercased()
        if type == "session",
           let cwd = record["cwd"] as? String,
           let normalized = normalizedAbsolutePath(cwd)
        {
            return DecodedRecord(
                workingDirectory: normalized,
                projectionEntry: nil
            )
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
                projectionEntry: AgentActivityEntry(
                    id: AgentActivityEventID(
                        source: .omp,
                        sessionKey: sessionKey,
                        stableSourceKey: "\(stableSourceKey):public"
                    ),
                    occurredAt: timestamp,
                    sourceOrder: sourceOrder,
                    text: paragraph
                )
            )
        }
        return nil
    }

    /// §5.1.2: 从文件头有界前缀探测（1 MiB budget）恢复 cwd。
    /// 使用 TranscriptEventReader 而非裸 FileHandle：享受读前/读后
    /// identity/truncation 校验（AC-08），避免 replace 时合并不同 inode。
    private struct WorkingDirectoryProbeResult {
        let workingDirectory: String?
        let bytesRead: Int
    }

    private static func probeWorkingDirectory(
        at url: URL,
        fileManager: FileManager,
        maximumBytes: Int
    ) -> WorkingDirectoryProbeResult {
        guard maximumBytes > 0 else {
            return WorkingDirectoryProbeResult(workingDirectory: nil, bytesRead: 0)
        }
        let probeBytes = min(1_048_576, maximumBytes)
        let probeBudget = TranscriptReadBudget(
            chunkBytes: probeBytes,
            maximumBytesPerPass: probeBytes,
            maximumAutomaticBackscanBytes: 0,
            maximumRecordBytes: TranscriptReadBudget.transcriptEvents
                .maximumRecordBytes,
            softWallTime: TranscriptReadBudget.transcriptEvents.softWallTime
        )
        guard let probeReader = TranscriptEventReader.make(
            at: url,
            budget: probeBudget,
            fileManager: fileManager
        ) else {
            return WorkingDirectoryProbeResult(workingDirectory: nil, bytesRead: 0)
        }
        let result = probeReader.readForwardPass()
        let bytesRead = probeReader.diagnostics.bytesRead
        guard case .success(let records) = result else {
            return WorkingDirectoryProbeResult(
                workingDirectory: nil,
                bytesRead: bytesRead
            )
        }
        for record in records {
            if let decoded = decodeRecord(record.data),
               let cwd = decoded.workingDirectory
            {
                return WorkingDirectoryProbeResult(
                    workingDirectory: cwd,
                    bytesRead: bytesRead
                )
            }
        }
        return WorkingDirectoryProbeResult(workingDirectory: nil, bytesRead: bytesRead)
    }

    static func content(fromJSONL text: String) -> OMPLocalSessionContent {
        var workingDirectory: String?
        var publicMessages: [AgentActivityEntry] = []

        for (index, line) in text.split(whereSeparator: { $0.isNewline }).enumerated() {
            guard let data = String(line).data(using: .utf8),
                  let decoded = decodeRecord(
                    data,
                    sessionKey: "",
                    stableSourceKey: "line:\(index)",
                    sourceOrder: UInt64(index)
                  )
            else { continue }
            if let cwd = decoded.workingDirectory {
                workingDirectory = cwd
            }
            if let entry = decoded.projectionEntry {
                publicMessages.append(entry)
            }
        }

        return OMPLocalSessionContent(
            workingDirectory: workingDirectory,
            projection: AgentActivityProjection(publicMessages: publicMessages)
        )
    }

    static func cachedContent(sessionID: String) -> OMPLocalSessionContent? {
        guard let normalizedSessionID = normalizedOMPSessionID(sessionID)
        else { return nil }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return sessionContentCache[normalizedSessionID]
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

private func ompTranscriptStableSourceKey(
    sourceIdentity: TranscriptSourceIdentity,
    startOffset: UInt64,
    byteCount: Int
) -> String {
    "dev:\(sourceIdentity.device):ino:\(sourceIdentity.inode):birth:\(sourceIdentity.birthSeconds).\(sourceIdentity.birthNanoseconds):range:\(startOffset)+\(byteCount)"
}
