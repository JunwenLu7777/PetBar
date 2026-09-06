//
//  ZCodeLocalSession.swift
//  ThreadHelm
//
//  模块职责：读取 ZCode CLI 的本地会话库，给 ZCode 任务卡提供与
//  Codex/Claude 同级的输出预览。之前 ZCode 卡片永远顶着「ZCode 会话」
//  的占位标题、事件框为空，因为 hook 事件只带状态不带内容——而
//  ZCode 在 `~/.zcode/cli/db/db.sqlite` 里存着结构化的会话数据。
//
//  库结构（实测 2026-09，schema_migration 管理）：
//    - session(id='sess_<uuid>', title, directory)：真实标题与工作目录；
//    - message(id, session_id, data JSON: role/modelID/…)；
//    - part(message_id, session_id, data JSON: type/text/time, sequence)。
//      分片类型实测分布：tool/step-start/step-finish/reasoning/text/…
//      只有 assistant 消息里 type=text 的分片是公开叙述；reasoning 是
//      模型思考，tool 是工具记录——一律不显示。
//
//  访问方式：SQLITE_OPEN_READONLY 只读打开，与 CLI 的写入（WAL）互不
//  干扰；每次调用独立连接，无跨调用状态。结果按会话做 1.5 秒 TTL
//  缓存，面板 2 秒刷新时主线程零磁盘 IO。
//

import Foundation
import SQLite3

// Swift 对 SQLite 的标准转义：让 bind_text 复制缓冲区。
private let zcodeSQLITE_TRANSIENT = unsafeBitCast(
    -1, to: sqlite3_destructor_type.self
)

struct ZCodeLocalSessionContent: Equatable {
    let title: String?
    let workingDirectory: String?
    let projection: AgentActivityProjection
}

enum ZCodeLocalSession {
    /// 与 agy/OMP 的公开文本预算同口径。
    static let maximumVisibleEvents = 32
    /// 缓存 TTL：略小于面板刷新周期，保证刷新时最多穿透一次查询。
    static let cacheTTL: TimeInterval = 1.5
    /// 单次查询扫描的分片上限。text 分片约占总分片 1/6，512 行足够
    /// 凑满 32 条叙述，同时把每次刷新的读取代价封顶。
    static let maximumScannedParts = 512

    private static let cacheLock = NSLock()
    private static var cacheStore: [String: (content: ZCodeLocalSessionContent?, at: Date)] = [:]

    static func defaultDatabaseURL(homeDirectory: URL? = nil) -> URL {
        let home = homeDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(
            ".zcode/cli/db/db.sqlite",
            isDirectory: false
        )
    }

    /// hook 上报的会话号可能是 `sess_<uuid>` 或裸 uuid；库内主键带
    /// sess_ 前缀。归一化成库内形态。
    static func normalizedZCodeSessionID(_ sessionID: String) -> String? {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128 else { return nil }
        if trimmed.hasPrefix("sess_") { return trimmed }
        return "sess_\(trimmed)"
    }

    static func resetInMemoryStateForTesting() {
        cacheLock.lock()
        cacheStore = [:]
        cacheLock.unlock()
    }

    /// 主线程快速路径：1.5 秒 TTL 内直接复用上次结果。
    static func cachedContent(
        sessionID: String,
        now: Date = Date()
    ) -> ZCodeLocalSessionContent? {
        guard let normalized = normalizedZCodeSessionID(sessionID) else {
            return nil
        }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let cached = cacheStore[normalized],
              now.timeIntervalSince(cached.at) <= cacheTTL
        else { return nil }
        return cached.content
    }

    static func content(
        sessionID: String,
        databaseURL: URL = defaultDatabaseURL(),
        now: Date = Date()
    ) -> ZCodeLocalSessionContent? {
        guard let normalized = normalizedZCodeSessionID(sessionID) else {
            return nil
        }
        cacheLock.lock()
        let cached = cacheStore[normalized]
        cacheLock.unlock()
        if let cached, now.timeIntervalSince(cached.at) <= cacheTTL {
            return cached.content
        }

        let parsed = readSession(
            normalizedSessionID: normalized,
            databaseURL: databaseURL
        )

        cacheLock.lock()
        cacheStore[normalized] = (parsed, now)
        // 缓存只服务会话卡片，条目数等于出现过的 ZCode 会话数；超限时
        // 清掉最旧的一半，避免无界增长。
        if cacheStore.count > 128 {
            let evictions = cacheStore
                .sorted { $0.value.at < $1.value.at }
                .prefix(cacheStore.count / 2)
                .map(\.key)
            for key in evictions { cacheStore.removeValue(forKey: key) }
        }
        cacheLock.unlock()
        return parsed
    }

    private static func readSession(
        normalizedSessionID: String,
        databaseURL: URL
    ) -> ZCodeLocalSessionContent? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY,
            nil
        ) == SQLITE_OK, let database
        else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)

        guard let title = scalarText(
            database,
            sql: "SELECT title FROM session WHERE id = ?",
            arguments: [.text(normalizedSessionID)]
        ), let workingDirectory = scalarText(
            database,
            sql: "SELECT directory FROM session WHERE id = ?",
            arguments: [.text(normalizedSessionID)]
        ) else {
            // 会话行不存在：ID 没对上或库是旧版本。返回 nil，卡片保持
            // 现状，绝不编造内容。
            return nil
        }

        var entries: [AgentActivityEntry] = []
        do {
            try query(
                database,
                sql: """
                    SELECT m.data, p.data, p.time_created, p.id
                    FROM part p JOIN message m ON p.message_id = m.id
                    WHERE p.session_id = ?
                    ORDER BY p.time_created DESC, p.id DESC
                    LIMIT ?
                    """,
                arguments: [
                    .text(normalizedSessionID),
                    .int(maximumScannedParts),
                ]
            ) { row in
                guard entries.count < maximumVisibleEvents,
                      let messageData = row.text(0),
                      let partData = row.text(1),
                      let role = JSONValue(messageData)?["role"] as? String,
                      role.lowercased() == "assistant",
                      let part = JSONValue(partData),
                      (part["type"] as? String)?.lowercased() == "text",
                      let rawText = part["text"] as? String,
                      let paragraph = safePublicActivityParagraph(from: rawText)
                else { return }
                let created = row.double(2)
                let partID = row.text(3) ?? UUID().uuidString
                entries.append(AgentActivityEntry(
                    id: AgentActivityEventID(
                        source: .zcode,
                        sessionKey: normalizedSessionID,
                        stableSourceKey: "zcode-part:\(partID)"
                    ),
                    occurredAt: normalizedTimestamp(created),
                    sourceOrder: UInt64(max(0, created)),
                    text: paragraph
                ))
            }
        } catch {
            // 会话元数据已拿到，分片读取失败时仍返回标题与目录，预览
            // 留空——错的信息比缺的信息更糟。
            return ZCodeLocalSessionContent(
                title: title,
                workingDirectory: workingDirectory,
                projection: AgentActivityProjection(publicMessages: [])
            )
        }
        return ZCodeLocalSessionContent(
            title: title,
            workingDirectory: workingDirectory,
            projection: AgentActivityProjection(
                publicMessages: Array(entries.reversed())
            )
        )
    }

    // MARK: - SQLite 便捷封装

    private enum SQLArgument {
        case text(String)
        case int(Int)
    }

    private struct SQLRow {
        let statement: OpaquePointer

        func text(_ index: Int32) -> String? {
            guard let cString = sqlite3_column_text(statement, index)
            else { return nil }
            return String(cString: cString)
        }

        func double(_ index: Int32) -> Double {
            sqlite3_column_double(statement, index)
        }
    }

    private static func normalizedTimestamp(_ value: Double) -> Date {
        // 库里的 time_created 是 epoch；旧数据可能是毫秒，按量级归一。
        if value > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: value / 1_000)
        }
        if value > 0 {
            return Date(timeIntervalSince1970: value)
        }
        return .distantPast
    }

    private static func JSONValue(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { return nil }
        return dictionary
    }

    private static func scalarText(
        _ database: OpaquePointer,
        sql: String,
        arguments: [SQLArgument]
    ) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil)
            == SQLITE_OK, let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(arguments, to: statement)
        if sqlite3_step(statement) == SQLITE_ROW {
            return SQLRow(statement: statement).text(0)
        }
        return nil
    }

    private static func query(
        _ database: OpaquePointer,
        sql: String,
        arguments: [SQLArgument],
        rowHandler: (SQLRow) -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil)
            == SQLITE_OK, let statement
        else {
            throw ZCodeLocalSessionError.queryFailed(
                String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }
        bind(arguments, to: statement)
        while sqlite3_step(statement) == SQLITE_ROW {
            rowHandler(SQLRow(statement: statement))
        }
        let resultCode = sqlite3_errcode(database)
        guard resultCode == SQLITE_OK || resultCode == SQLITE_DONE else {
            throw ZCodeLocalSessionError.queryFailed(
                String(cString: sqlite3_errmsg(database))
            )
        }
    }

    private static func bind(
        _ arguments: [SQLArgument],
        to statement: OpaquePointer
    ) {
        for (index, argument) in arguments.enumerated() {
            let position = Int32(index + 1)
            switch argument {
            case .text(let value):
                sqlite3_bind_text(
                    statement, position, value, -1, zcodeSQLITE_TRANSIENT
                )
            case .int(let value):
                sqlite3_bind_int64(statement, position, Int64(value))
            }
        }
    }

    private enum ZCodeLocalSessionError: Error {
        case queryFailed(String)
    }
}
