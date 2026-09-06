//
//  AntigravityLocalSession.swift
//  ThreadHelm
//
//  模块职责：读取 agy 的本地 transcript，给 Antigravity 任务卡提供与
//  Codex/Claude 同级的输出预览。之前这张卡的「最近事件」永远是空的，
//  因为 hook 事件只携带工具调用，不带助手文本——而 agy 其实和 Claude
//  一样在本地写完整对话记录。
//
//  transcript 位置与格式（实测 2026-09，本机 63 份、1.9 万条记录）：
//    ~/.gemini/antigravity-cli/brain/<会话UUID>/.system_generated/logs/
//    transcript_full.jsonl
//    - PLANNER_RESPONSE（source=MODEL，content 非空）＝面向用户的叙述，
//      是唯一的公开文本来源（实测 9458 条里 732 条带 content）；
//    - GENERIC / RUN_COMMAND / VIEW_FILE 等是原始工具输出，一律不显示；
//    - USER_INPUT / CHECKPOINT / SYSTEM_MESSAGE 是用户输入与系统噪声，
//      一律不显示。
//
//  实现取舍：与 OMP 的增量 reader+磁盘 sidecar 不同，这里每轮对文件
//  尾部做一次有界回扫（2 MiB），内容缓存按 mtime+size 失效。agy 会话
//  通常几十 KB，单次代价很小；换来的是没有跨调用的可变 reader 状态，
//  身份校验由 TranscriptEventReader 每轮自带。少一份需要跨会话维护的
//  增量机，就少一份复制粘贴漂移面。
//

import Foundation

struct AntigravityLocalSessionContent: Equatable {
    let workingDirectory: String?
    let projection: AgentActivityProjection
}

enum AntigravityLocalSession {
    /// 与 OMP 的公开文本预算同口径：卡片只保留最近的叙述文本。
    static let maximumVisibleEvents = 32
    /// 每轮回扫的文件尾部窗口。
    static let maximumTailBytes = 2 * 1_048_576

    private struct CachedContent: Equatable {
        let modificationDate: Date
        let fileSize: Int
        let content: AntigravityLocalSessionContent
    }

    private static let cacheLock = NSLock()
    private static var contentCache: [String: CachedContent] = [:]
    private static var idCacheTouchStamps: [String: Date] = [:]
    private static let maximumCachedSessions = 64

    static func resetInMemoryStateForTesting() {
        cacheLock.lock()
        contentCache.removeAll()
        idCacheTouchStamps.removeAll()
        cacheLock.unlock()
    }

    static func brainRootDirectory(homeDirectory: URL? = nil) -> URL {
        let home = homeDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".gemini/antigravity-cli/brain", isDirectory: true)
    }

    static func transcriptURL(
        sessionID: String,
        brainRoot: URL = brainRootDirectory()
    ) -> URL? {
        guard let normalized = normalizedAntigravitySessionID(sessionID)
        else { return nil }
        // brain 目录名就是会话 UUID（本机实测 63 个目录全部为 UUID 命名），
        // 与 hook 负载里的 conversationId 同源。
        return brainRoot
            .appendingPathComponent(normalized, isDirectory: true)
            .appendingPathComponent(".system_generated/logs/transcript_full.jsonl")
    }

    static func cachedContent(sessionID: String) -> AntigravityLocalSessionContent? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let normalized = normalizedAntigravitySessionID(sessionID) else {
            return nil
        }
        if let content = sessionContentCache[normalized] {
            idCacheTouchStamps[normalized] = Date()
            return content
        }
        return nil
    }

    private static var sessionContentCache: [String: AntigravityLocalSessionContent] = [:]

    /// 完整读取。主线程走缓存（每 2 秒刷新不能碰磁盘），后台队列才读盘。
    static func content(
        sessionID: String,
        brainRoot: URL = brainRootDirectory(),
        fileManager: FileManager = .default
    ) -> AntigravityLocalSessionContent? {
        if Thread.isMainThread,
           brainRoot == brainRootDirectory() {
            return cachedContent(sessionID: sessionID)
        }
        guard let normalized = normalizedAntigravitySessionID(sessionID),
              let transcriptURL = transcriptURL(
                  sessionID: normalized,
                  brainRoot: brainRoot
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
        cacheLock.lock()
        if let cached = contentCache[cacheKey],
           cached.modificationDate == modificationDate,
           cached.fileSize == fileSize {
            idCacheTouchStamps[normalized] = Date()
            pruneIDCacheLocked()
            cacheLock.unlock()
            return cached.content
        }
        cacheLock.unlock()

        let parsed = readPublicOutput(
            transcriptURL: transcriptURL,
            sessionKey: normalized,
            fileSize: fileSize
        )
        guard let parsed else { return nil }

        cacheLock.lock()
        contentCache[cacheKey] = CachedContent(
            modificationDate: modificationDate,
            fileSize: fileSize,
            content: parsed
        )
        sessionContentCache[normalized] = parsed
        idCacheTouchStamps[normalized] = Date()
        pruneIDCacheLocked()
        cacheLock.unlock()
        return parsed
    }

    // 以下 touch/prune 都要求调用方已持有 cacheLock（NSLock 不可重入）。
    private static func pruneIDCacheLocked() {
        guard idCacheTouchStamps.count > maximumCachedSessions else { return }
        let evictions = idCacheTouchStamps
            .sorted { $0.value < $1.value }
            .prefix(idCacheTouchStamps.count - maximumCachedSessions)
            .map(\.key)
        for key in evictions {
            idCacheTouchStamps.removeValue(forKey: key)
            sessionContentCache.removeValue(forKey: key)
        }
    }

    /// 从文件尾部有界回扫，抽取 PLANNER_RESPONSE 的公开叙述文本。
    private static func readPublicOutput(
        transcriptURL: URL,
        sessionKey: String,
        fileSize: Int
    ) -> AntigravityLocalSessionContent? {
        guard fileSize > 0,
              let reader = TranscriptEventReader.make(at: transcriptURL)
        else { return nil }

        let tailBytes = min(maximumTailBytes, fileSize)
        let result = reader.readBackwardPass(
            fromEnd: UInt64(fileSize),
            maximumBytes: tailBytes
        )
        guard case .success(let (records, _, _)) = result else { return nil }

        var entries: [AgentActivityEntry] = []
        for record in records {
            guard let decoded = decodeRecord(
                record.data,
                sessionKey: sessionKey,
                startOffset: record.startOffset,
                byteCount: record.byteCount
            ) else { continue }
            entries.append(decoded)
        }
        entries.sort {
            if $0.occurredAt != $1.occurredAt {
                return $0.occurredAt < $1.occurredAt
            }
            return $0.id.stableSourceKey < $1.id.stableSourceKey
        }
        let projection = AgentActivityProjection(
            publicMessages: Array(entries.suffix(maximumVisibleEvents))
        )
        guard !projection.publicMessages.isEmpty else { return nil }
        return AntigravityLocalSessionContent(
            workingDirectory: nil,
            projection: projection
        )
    }

    private struct DecodedRecord {
        let workingDirectory: String?
        let projectionEntry: AgentActivityEntry?
    }

    private static func decodeRecord(
        _ data: Data,
        sessionKey: String,
        startOffset: UInt64,
        byteCount: Int
    ) -> AgentActivityEntry? {
        decodeAggyRecord(
            data,
            sessionKey: sessionKey,
            startOffset: startOffset,
            byteCount: byteCount
        ).flatMap(\.projectionEntry)
    }

    private static func decodeAggyRecord(
        _ data: Data,
        sessionKey: String,
        startOffset: UInt64,
        byteCount: Int
    ) -> DecodedRecord? {
        guard let record = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        else { return nil }
        // 只有模型发出的 PLANNER_RESPONSE 才是面向用户的叙述；其余类型
        // （工具输出、用户输入、系统噪声）按隐私契约一律不进预览。
        guard (record["type"] as? String)?.uppercased() == "PLANNER_RESPONSE",
              (record["source"] as? String)?.uppercased() == "MODEL",
              let text = record["content"] as? String,
              let paragraph = safePublicActivityParagraph(from: text)
        else { return nil }
        let timestamp = (record["created_at"] as? String).flatMap {
            aggyISO8601WithFractional.date(from: $0)
                ?? aggyISO8601.date(from: $0)
        } ?? .distantPast
        return DecodedRecord(
            workingDirectory: nil,
            projectionEntry: AgentActivityEntry(
                id: AgentActivityEventID(
                    source: .antigravity,
                    sessionKey: sessionKey,
                    stableSourceKey: aggyTranscriptStableSourceKey(
                        sourceIdentity: aggyStableKeyIdentity,
                        startOffset: startOffset,
                        byteCount: Int(byteCount)
                    )
                ),
                occurredAt: timestamp,
                sourceOrder: startOffset,
                text: paragraph
            )
        )
    }

    /// 稳定键用「偏移+长度」组合：transcript 是 append-only 的，同一
    /// 记录的偏移跨刷新稳定，UI 去重不依赖 inode 身份（缓存已按
    /// mtime+size 失效，文件被替换后整表重建）。
    private static let aggyStableKeyIdentity = TranscriptSourceIdentity(
        device: 0,
        inode: 0,
        birthSeconds: 0,
        birthNanoseconds: 0
    )

    private static func aggyTranscriptStableSourceKey(
        sourceIdentity: TranscriptSourceIdentity,
        startOffset: UInt64,
        byteCount: Int
    ) -> String {
        "dev:\(sourceIdentity.device):ino:\(sourceIdentity.inode):range:\(startOffset)+\(byteCount)"
    }

    private static let aggyISO8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let aggyISO8601 = ISO8601DateFormatter()
}
