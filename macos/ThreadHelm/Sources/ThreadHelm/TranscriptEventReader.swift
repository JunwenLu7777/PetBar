//
//  TranscriptEventReader.swift
//  ThreadHelm
//
//  模块职责：共享 JSONL transcript 的 I/O 读取器与 metadata-only 索引。
//  - 字节切分交给无 I/O 的 JSONLFramer（状态机在 JSONLFramer.swift）；
//    本层只负责 1 MiB 分块读取、读前后 lstat 身份校验、record 汇总。
//  - record 同时携带字节范围（location，交 sidecar）与字节本体（data，供
//    decoder 直接消费），不要求 provider 再按 range 重读，避免 TOCTOU。
//  - forward incremental、backward bounded scan、文件身份、超长行由 framer
//    有界跳过、读前后校验。
//  - metadata-only sidecar：只存定位与计数诊断，绝不持久化正文/工具/cwd。
//

import CryptoKit
import Foundation

// MARK: - 身份与位置

struct TranscriptSourceIdentity: Codable, Equatable {
    let device: UInt64
    let inode: UInt64
    let birthSeconds: Int64
    let birthNanoseconds: Int64
}

enum TranscriptIndexedEventClass: String, Codable, Equatable {
    case publicMessage
    case currentTool
    case terminal
    case metadata
}

struct TranscriptRecordLocation: Codable, Equatable {
    let startOffset: UInt64
    let byteCount: UInt32
    let sourceOrder: UInt64
    let eventClass: TranscriptIndexedEventClass
    let occurredAt: Date?

    var endOffset: UInt64 { startOffset + UInt64(byteCount) }
}

struct TranscriptReadBudget: Equatable {
    let chunkBytes: Int
    let maximumBytesPerPass: Int
    let maximumAutomaticBackscanBytes: Int
    let maximumRecordBytes: Int
    let softWallTime: TimeInterval

    static let transcriptEvents = TranscriptReadBudget(
        chunkBytes: 1_048_576,
        maximumBytesPerPass: 8 * 1_048_576,
        maximumAutomaticBackscanBytes: 64 * 1_048_576,
        maximumRecordBytes: 4 * 1_048_576,
        softWallTime: 0.05
    )
}

// MARK: - 单调时钟

protocol TranscriptMonotonicClock {
    func nowNanoseconds() -> UInt64
}

struct SystemTranscriptMonotonicClock: TranscriptMonotonicClock {
    func nowNanoseconds() -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return mach_absolute_time() * UInt64(info.numer) / UInt64(info.denom)
    }
}

final class FakeTranscriptMonotonicClock: TranscriptMonotonicClock {
    private var storage: UInt64
    init(start: UInt64 = 1_000_000_000_000) { storage = start }
    func advance(by delta: UInt64) { storage &+= delta }
    func nowNanoseconds() -> UInt64 { storage }
}

// MARK: - 结果

struct TranscriptRecordRange: Equatable {
    let startOffset: UInt64
    let byteCount: Int
    let sourceOrder: UInt64
    let data: Data

    var endOffset: UInt64 { startOffset + UInt64(byteCount) }
}

struct TranscriptReadDiagnostics: Equatable {
    var bytesRead = 0
    var recordsDecoded = 0
    var recordsSkippedOversized = 0
    var recordsSkippedInvalid = 0
    var rawChunksRead = 0
    var wallTimeMs = 0.0
}

/// Test-visible audit for the shared transcript/index I/O boundary. Production
/// readers are reached from the utility refresh queue; UI code must use the
/// in-memory provider caches instead of entering this layer on the main thread.
enum TranscriptIOThreadAudit {
    private static let lock = NSLock()
    private static var mainThreadViolations = 0

    static func recordIO() {
        guard Thread.isMainThread else { return }
        lock.lock()
        mainThreadViolations += 1
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        mainThreadViolations = 0
        lock.unlock()
    }

    static func violationCount() -> Int {
        lock.lock()
        let count = mainThreadViolations
        lock.unlock()
        return count
    }
}

enum TranscriptReadError: Error {
    case identityChanged
    case truncation
    case ioFailed
}

// MARK: - Reader（I/O + framer 驱动）

final class TranscriptEventReader {
    let url: URL
    let identity: TranscriptSourceIdentity
    let budget: TranscriptReadBudget
    private let fileManager: FileManager
    private let clock: TranscriptMonotonicClock
    /// 当前累积的 framer（含 committedOffset/pending/discard/sourceOrder）。
    private var framer: JSONLFramer
    /// 当前 framer（含 committedOffset/pending/discard/sourceOrder）。
    var committedOffset: UInt64 { framer.committedOffset }
    var sourceOrder: UInt64 { framer.sourceOrder }
    /// 仅内存扫描头：已喂给 framer 的字节位置。committedOffset 是持久
    /// checkpoint（可能因超长行 discard 停留在更早位置），scanHead 必须单独
    /// 跟踪，否则 discard 后下一 pass 会从原地重读而永不前进。
    private(set) var scanHead: UInt64 = 0
    /// 最近一次前向 pass 是否已读到文件 EOF（remaining == 0 或
    /// readEndpoint == after.fileSize）。用于判断 checkpoint 的
    /// committedOffset 是否可以安全写为文件大小。
    private(set) var scanHeadReachedEOF = false
    private(set) var snapshotEOF: UInt64
    private(set) var backscanContinuationOffset: UInt64?
    private(set) var diagnostics = TranscriptReadDiagnostics()
    /// 测试注入：在读完 chunk 循环后、读后身份校验前调用。用于构造
    /// 读取中 truncate/replace 的确定性回归。
    var postReadHook: (() -> Void)?
    /// 测试注入：每读完一个 chunk 后调用。用于验证 soft wall time 和取消
    /// 都只在 chunk 边界生效。
    var postChunkReadHook: (() -> Void)?
    init(
        url: URL,
        identity: TranscriptSourceIdentity,
        budget: TranscriptReadBudget = .transcriptEvents,
        fileManager: FileManager = .default,
        clock: TranscriptMonotonicClock = SystemTranscriptMonotonicClock(),
        initialFileSize: UInt64 = 0,
        restoreOffset: UInt64 = 0
    ) {
        self.url = url
        self.identity = identity
        self.budget = budget
        self.fileManager = fileManager
        self.clock = clock
        snapshotEOF = initialFileSize
        scanHead = restoreOffset
        framer = JSONLFramer(
            maximumRecordBytes: budget.maximumRecordBytes,
            committedOffset: restoreOffset
        )
    }

    /// 用文件真实 identity 构造 reader（测试与冷启动统一入口）。
    static func make(
        at url: URL,
        budget: TranscriptReadBudget = .transcriptEvents,
        fileManager: FileManager = .default,
        clock: TranscriptMonotonicClock = SystemTranscriptMonotonicClock()
    ) -> TranscriptEventReader? {
        TranscriptIOThreadAudit.recordIO()
        var statBuffer = stat()
        guard lstat(url.path, &statBuffer) == 0 else { return nil }
        #if os(macOS)
        let birth = statBuffer.st_birthtimespec
        #else
        let birth = statBuffer.st_ctimespec
        #endif
        let identity = TranscriptSourceIdentity(
            device: UInt64(statBuffer.st_dev),
            inode: UInt64(statBuffer.st_ino),
            birthSeconds: Int64(birth.tv_sec),
            birthNanoseconds: Int64(birth.tv_nsec)
        )
        return TranscriptEventReader(
            url: url,
            identity: identity,
            budget: budget,
            fileManager: fileManager,
            clock: clock,
            initialFileSize: UInt64(statBuffer.st_size)
        )
    }

    // MARK: file identity

    private struct FileAttributes {
        let identity: TranscriptSourceIdentity
        let fileSize: UInt64
    }

    private func fileAttributes() throws -> FileAttributes {
        TranscriptIOThreadAudit.recordIO()
        var statBuffer = stat()
        guard lstat(url.path, &statBuffer) == 0 else {
            throw TranscriptReadError.ioFailed
        }
        #if os(macOS)
        let birth = statBuffer.st_birthtimespec
        #else
        let birth = statBuffer.st_ctimespec
        #endif
        let identity = TranscriptSourceIdentity(
            device: UInt64(statBuffer.st_dev),
            inode: UInt64(statBuffer.st_ino),
            birthSeconds: Int64(birth.tv_sec),
            birthNanoseconds: Int64(birth.tv_nsec)
        )
        return FileAttributes(
            identity: identity,
            fileSize: UInt64(statBuffer.st_size)
        )
    }

    // MARK: - forward incremental

    /// 从 framer 的 committedOffset 起读一个 budget 有界 pass。
    /// `maximumBytes` 允许 provider 把 index range restore、forward 与
    /// backward 纳入同一次 refresh 的共享 8 MiB 总预算。
    func readForwardPass(
        maximumBytes: Int? = nil,
        isCancelled: () -> Bool = { false }
    ) -> Result<[TranscriptRecordRange], TranscriptReadError> {
        let attrs: FileAttributes
        do {
            attrs = try fileAttributes()
        } catch {
            return .failure(.ioFailed)
        }
        guard attrs.identity == identity else { return .failure(.identityChanged) }
        let readStart = scanHead
        guard attrs.fileSize >= readStart else { return .failure(.truncation) }
        let remaining = attrs.fileSize - readStart
        guard remaining > 0 else {
            scanHeadReachedEOF = true
            snapshotEOF = attrs.fileSize
            return .success([])
        }
        let requestedLimit = maximumBytes ?? budget.maximumBytesPerPass
        let boundedLimit = min(
            max(0, requestedLimit),
            budget.maximumBytesPerPass
        )
        guard boundedLimit > 0 else { return .success([]) }
        let budgetLimit = UInt64(boundedLimit)
        let passLimit = min(remaining, budgetLimit)

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .failure(.ioFailed)
        }
        defer { try? handle.close() }
        let passStart = clock.nowNanoseconds()
        var produced: [TranscriptRecordRange] = []
        var consumed = 0
        var wallExceeded = false
        var chunkStart = readStart
        // 在副本上 feed；读后身份校验通过后才提交回真 framer。
        var workingFramer = framer

        do {
            try handle.seek(toOffset: readStart)
            while consumed < passLimit && !wallExceeded {
                if isCancelled() { break }
                let chunkLimit = min(
                    Int(passLimit - UInt64(consumed)),
                    budget.chunkBytes
                )
                guard let chunk = try handle.read(upToCount: chunkLimit),
                      !chunk.isEmpty
                else { break }
                chunkStart = readStart + UInt64(consumed)
                consumed += chunk.count
                diagnostics.bytesRead += chunk.count
                diagnostics.rawChunksRead += 1
                workingFramer.feed(chunk, chunkStart: chunkStart)
                postChunkReadHook?()
                wallExceeded = clock.nowNanoseconds() - passStart > wallClockNs
                if wallExceeded {
                    diagnostics.wallTimeMs += budget.softWallTime * 1_000
                }
            }
        } catch {
            return .failure(.ioFailed)
        }
        // 测试注入：读完 chunk 后、校验前截断，构造读取中 truncation。
        postReadHook?()

        // 读后身份校验：replace/truncate 时丢弃本轮（不提交副本）。
        // 必须按本轮真实读端点校验（readStart + consumed），而不是按
        // committedOffset——partial/discard 时 committedOffset 会落后于已读
        // 终点，若 truncate 到两者之间，按旧值校验会把 stale bytes / pending
        // 错误提交，并让 scanHead 越过新 EOF。
        let readEndpoint = readStart + UInt64(consumed)
        guard let after = try? fileAttributes(),
              after.identity == identity,
              after.fileSize >= readEndpoint,
              after.fileSize >= workingFramer.committedOffset
        else {
            return .failure(.truncation)
        }

        produced = workingFramer.records.map {
            TranscriptRecordRange(
                startOffset: $0.startOffset,
                byteCount: $0.byteCount,
                // Transcript ordering must survive backward continuation,
                // process restart, and sidecar restore.  The framer's local
                // sequence is useful for its own streaming contract, but an
                // absolute byte offset is the stable sequence for a file.
                sourceOrder: $0.startOffset,
                data: $0.data
            )
        }
        diagnostics.recordsDecoded += produced.count
        diagnostics.recordsSkippedOversized +=
            max(0, workingFramer.skippedOversized - framer.skippedOversized)
        scanHeadReachedEOF = (readEndpoint >= after.fileSize)
        snapshotEOF = readEndpoint
        scanHead = snapshotEOF
        // 清空 framer 已映射的 records：下一 pass 只返回新增记录。
        workingFramer.clearRecords()
        framer = workingFramer
        return .success(produced)
    }

    // MARK: - backward bounded backscan（冷启动无索引 / index re-read）

    /// 从 endOffset 向前回读最多 maximumBytes 字节，产生 records 与
    /// continuation 起点。
    func readBackwardPass(
        fromEnd endOffset: UInt64,
        maximumBytes: Int,
        isCancelled: () -> Bool = { false }
    ) -> Result<
        (
            records: [TranscriptRecordRange],
            continuation: UInt64?,
            trailingPartialStart: UInt64?
        ),
        TranscriptReadError
    > {
        let attrs: FileAttributes
        do {
            attrs = try fileAttributes()
        } catch {
            return .failure(.ioFailed)
        }
        guard attrs.identity == identity else { return .failure(.identityChanged) }
        guard attrs.fileSize >= endOffset else { return .failure(.truncation) }
        let passLimit = min(maximumBytes, budget.maximumBytesPerPass)
        guard passLimit > 0 else { return .success(([], nil, nil)) }
        let plannedLowerBound = endOffset > UInt64(passLimit)
            ? endOffset - UInt64(passLimit)
            : 0
        guard endOffset > plannedLowerBound else { return .success(([], nil, nil)) }


        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .failure(.ioFailed)
        }
        defer { try? handle.close() }
        do {
            let passStart = clock.nowNanoseconds()
            var cursor = endOffset
            var data = Data()
            while cursor > plannedLowerBound {
                if isCancelled() { break }
                let chunkStart: UInt64
                if cursor - plannedLowerBound > UInt64(budget.chunkBytes) {
                    chunkStart = cursor - UInt64(budget.chunkBytes)
                } else {
                    chunkStart = plannedLowerBound
                }
                let chunkSize = Int(cursor - chunkStart)
                try handle.seek(toOffset: chunkStart)
                let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                guard !chunk.isEmpty else { break }
                var combined = Data(capacity: chunk.count + data.count)
                combined.append(chunk)
                combined.append(data)
                data = combined
                diagnostics.bytesRead += chunk.count
                diagnostics.rawChunksRead += 1
                cursor = chunkStart
                postChunkReadHook?()
                if clock.nowNanoseconds() - passStart > wallClockNs {
                    diagnostics.wallTimeMs += budget.softWallTime * 1_000
                    break
                }
            }
            let lowerBound = cursor
            guard !data.isEmpty else {
                let continuation: UInt64? = lowerBound > 0 ? lowerBound : nil
                return .success(([], continuation, nil))
            }
            postReadHook?()
            guard let after = try? fileAttributes(),
                  after.identity == identity,
                  after.fileSize >= endOffset
            else {
                return .failure(.truncation)
            }

            // 当 lowerBound > 0 时，数据头部是被前一轮截断的半行 JSONL
            // 片段。丢弃第一个 LF 之前的所有字节（AC-07：跨边界记录不得损坏），
            // 只喂完整记录；continuation 设为第一个完整记录的起点，下一轮
            // 从该点继续向前回扫（与本轮有重叠，但不重复读取完整记录）。
            let feedStart: UInt64
            let feedData: Data
            if lowerBound > 0 {
                guard let firstLF = data.firstIndex(of: 0x0A) else {
                    // 整个区间无 LF：全是片段，不产生记录。
                    let continuation: UInt64? = lowerBound > 0 ? lowerBound : nil
                    return .success(([], continuation, nil))
                }
                let fragmentEnd = firstLF + 1
                feedStart = lowerBound + UInt64(fragmentEnd)
                feedData = data.subdata(in: fragmentEnd..<data.count)
            } else {
                feedStart = lowerBound
                feedData = data
            }

            var records: [TranscriptRecordRange] = []
            var framer = JSONLFramer(
                maximumRecordBytes: budget.maximumRecordBytes,
                committedOffset: feedStart,
                sourceOrder: self.sourceOrder
            )
            framer.feed(feedData, chunkStart: feedStart)
            records = framer.records.map {
                TranscriptRecordRange(
                    startOffset: $0.startOffset,
                    byteCount: $0.byteCount,
                    sourceOrder: $0.startOffset,
                    data: $0.data
                )
            }

            diagnostics.recordsDecoded += records.count
            // continuation 必须严格 < endOffset：窗口内首个 LF 恰为数据末
            // 字节（例如单条超长记录的唯一 LF 在窗口末端）时 feedStart ==
            // endOffset，作为 continuation 会让调用方反复读同一窗口直到
            // 预算耗尽，永远到不了更旧记录。退到 lowerBound 保证严格递减
            // （下一 pass 从本窗口起点继续，能越过无完整记录的字节）。
            let continuation: UInt64? = {
                guard lowerBound > 0 else { return nil }
                return feedStart < endOffset ? feedStart : lowerBound
            }()
            // 当本 pass 触及文件尾（endOffset == attrs.fileSize）且末尾
            // 是未完成行时，返回该行的起始偏移（最后一条完整记录之后），
            // 供调用方把持久 committedOffset 停在"最后完整记录后"，避免把
            // 未读/未完成字节标记为已提交。
            let trailingPartialStart: UInt64? = {
                guard endOffset == attrs.fileSize,
                      !framer.pending.isEmpty,
                      !framer.discarding
                else { return nil }
                return records.last.map { $0.endOffset }
                    ?? feedStart
            }()
            return .success((
                records,
                continuation,
                trailingPartialStart
            ))
        } catch {
            return .failure(.ioFailed)
        }
    }

    // MARK: 游标

    func setCommittedOffset(_ value: UInt64) {
        framer = JSONLFramer(
            maximumRecordBytes: budget.maximumRecordBytes,
            committedOffset: value,
            sourceOrder: framer.sourceOrder
        )
        scanHead = value
    }
    func setBackscanContinuation(_ value: UInt64?) { backscanContinuationOffset = value }
    func resetPartialBytes() { framer.resetPending() }

    /// 从指定 byte range 读回一条完整 record 的 raw data。
    /// 用于 index-hit 路径：按 sidecar 中的 descriptor 回读原文件 record。
    func readRange(
        _ location: TranscriptRecordLocation,
        maximumBytes: Int? = nil
    ) -> Data? {
        TranscriptIOThreadAudit.recordIO()
        let byteCount = Int(location.byteCount)
        let requestedLimit = min(
            max(0, maximumBytes ?? budget.maximumBytesPerPass),
            budget.maximumBytesPerPass
        )
        let (rangeEnd, overflow) = location.startOffset.addingReportingOverflow(
            UInt64(location.byteCount)
        )
        guard !overflow,
              byteCount > 0,
              byteCount <= requestedLimit,
              byteCount <= budget.maximumRecordBytes,
              let before = try? fileAttributes(),
              before.identity == identity,
              before.fileSize >= rangeEnd
        else {
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: location.startOffset)
            guard let data = try handle.read(upToCount: byteCount) else {
                return nil
            }
            diagnostics.bytesRead += data.count
            diagnostics.rawChunksRead += data.isEmpty ? 0 : 1
            guard
                  data.count == byteCount,
                  data.last == 0x0A,
                  let after = try? fileAttributes(),
                  after.identity == identity,
                  after.fileSize >= rangeEnd
            else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }
    func resetDiagnostics() { diagnostics = TranscriptReadDiagnostics() }

    private var wallClockNs: UInt64 {
        UInt64(budget.softWallTime * 1_000_000_000)
    }
}

// MARK: - 索引 store

enum TranscriptIndexError: Error {
    case corruptOrUnsupported
    case fileTooBig
}

struct TranscriptIndexStore {
    static let schemaVersion = 1
    static let maximumFileBytes = 512 * 1_024
    static let maximumDescriptors: UInt = 256
    static let maximumPublicMessages = 32
    static let maximumWriteInterval: TimeInterval = 5
    static let orphanRetentionPeriod: TimeInterval = 7 * 24 * 60 * 60

    struct Checkpoint: Codable, Equatable {
        var schemaVersion: Int
        var agentID: AgentID
        var sessionKeyDigest: String
        var sourceIdentity: TranscriptSourceIdentity
        var observedSize: UInt64
        var observedMTime: UInt64
        var committedOffset: UInt64
        var backscanContinuationOffset: UInt64?
        var publicMessageDescriptors: [TranscriptRecordLocation]
        var currentToolDescriptor: TranscriptRecordLocation?
        var terminalDescriptor: TranscriptRecordLocation?
        var metadataDescriptor: TranscriptRecordLocation?
        var oversizedRecords: Int
    }

    let rootDirectory: URL
    let fileManager: FileManager

    init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    static var defaultRootDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/ThreadHelm/Transcript Index/v1",
                isDirectory: true
            )
    }

    private func agentDirectory(agentID: AgentID) -> URL {
        rootDirectory.appendingPathComponent(agentID.rawValue, isDirectory: true)
    }

    func indexFileURL(agentID: AgentID, sessionKey: String) -> URL {
        agentDirectory(agentID: agentID).appendingPathComponent(
            digest(agentID.rawValue + "\u{0}" + sessionKey) + ".json",
            isDirectory: false
        )
    }

    func ensureRootExists() throws {
        TranscriptIOThreadAudit.recordIO()
        // `createDirectory(...withIntermediateDirectories:)` applies the
        // requested mode only to the leaf.  Protect the named index parent as
        // well so the default `Transcript Index/v1` hierarchy is 0700 at both
        // metadata-bearing directory levels.  Custom test/injected roots do
        // not chmod an unrelated parent directory.
        let parent = rootDirectory.deletingLastPathComponent()
        if rootDirectory.lastPathComponent == "v1",
           parent.lastPathComponent == "Transcript Index"
        {
            try fileManager.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            _ = chmod(parent.path, S_IRWXU)
            var protectedParent = parent
            var parentValues = URLResourceValues()
            parentValues.isExcludedFromBackup = true
            try protectedParent.setResourceValues(parentValues)
        }
        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(rootDirectory.path, S_IRWXU)
        var root = rootDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
    }

    func save(
        _ checkpoint: Checkpoint,
        agentID: AgentID,
        sessionKey: String,
        force: Bool = false
    ) throws {
        TranscriptIOThreadAudit.recordIO()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var encoded = checkpoint
        encoded.schemaVersion = Self.schemaVersion
        encoded.agentID = agentID
        encoded.sessionKeyDigest = digest(agentID.rawValue + "\u{0}" + sessionKey)
        encoded = normalizedStableOrdering(encoded)
        encoded.publicMessageDescriptors = Array(
            encoded.publicMessageDescriptors
                .filter { $0.eventClass == .publicMessage }
                .suffix(Self.maximumPublicMessages)
        )
        var descriptorCount = encoded.publicMessageDescriptors.count
        descriptorCount += encoded.currentToolDescriptor == nil ? 0 : 1
        descriptorCount += encoded.terminalDescriptor == nil ? 0 : 1
        descriptorCount += encoded.metadataDescriptor == nil ? 0 : 1
        if descriptorCount > Self.maximumDescriptors {
            encoded.currentToolDescriptor = nil
            encoded.terminalDescriptor = nil
            encoded.metadataDescriptor = nil
        }
        let data = try encoder.encode(encoded)
        guard data.count <= Self.maximumFileBytes else {
            throw TranscriptIndexError.fileTooBig
        }
        try ensureRootExists()
        let agentDir = agentDirectory(agentID: agentID)
        try fileManager.createDirectory(
            at: agentDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(agentDir.path, S_IRWXU)
        let url = indexFileURL(agentID: agentID, sessionKey: sessionKey)
        if !force,
           fileManager.fileExists(atPath: url.path),
           let modified = try? url.resourceValues(
               forKeys: [.contentModificationDateKey]
           ).contentModificationDate,
           Date().timeIntervalSince(modified) < Self.maximumWriteInterval
        {
            return
        }
        let tempURL = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: tempURL.path
        )
        _ = chmod(tempURL.path, S_IRUSR | S_IWUSR)
        guard rename(tempURL.path, url.path) == 0 else {
            let errnoValue = errno
            try? fileManager.removeItem(at: tempURL)
            throw POSIXError(POSIXErrorCode(rawValue: errnoValue) ?? .EIO)
        }
        _ = chmod(url.path, S_IRUSR | S_IWUSR)
        guard permissionsMatch(path: url.path, expected: S_IRUSR | S_IWUSR)
        else {
            throw POSIXError(.EACCES)
        }
    }

    func saveCoalesced(
        _ checkpoint: Checkpoint,
        agentID: AgentID,
        sessionKey: String
    ) throws {
        try save(checkpoint, agentID: agentID, sessionKey: sessionKey)
    }

    func flush(
        _ checkpoint: Checkpoint,
        agentID: AgentID,
        sessionKey: String
    ) throws {
        try save(checkpoint, agentID: agentID, sessionKey: sessionKey, force: true)
    }

    func load(agentID: AgentID, sessionKey: String) -> Checkpoint? {
        TranscriptIOThreadAudit.recordIO()
        let url = indexFileURL(agentID: agentID, sessionKey: sessionKey)
        guard permissionsAreStrictForLoad(url: url, agentID: agentID) else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard data.count <= Self.maximumFileBytes else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        guard let checkpoint = try? JSONDecoder().decode(Checkpoint.self, from: data),
              checkpoint.schemaVersion == Self.schemaVersion,
              checkpoint.agentID == agentID,
              checkpoint.sessionKeyDigest == digest(agentID.rawValue + "\u{0}" + sessionKey)
        else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        // Development builds before the absolute-offset ordering contract may
        // have persisted a pass-local sourceOrder.  Normalize on load instead
        // of trusting it, so an existing metadata-only sidecar cannot revive
        // unstable same-timestamp ordering.
        return normalizedStableOrdering(checkpoint)
    }

    private func normalizedStableOrdering(_ checkpoint: Checkpoint) -> Checkpoint {
        func normalized(_ location: TranscriptRecordLocation?)
            -> TranscriptRecordLocation?
        {
            guard let location else { return nil }
            return TranscriptRecordLocation(
                startOffset: location.startOffset,
                byteCount: location.byteCount,
                sourceOrder: location.startOffset,
                eventClass: location.eventClass,
                occurredAt: location.occurredAt
            )
        }

        var result = checkpoint
        result.publicMessageDescriptors = checkpoint.publicMessageDescriptors
            .compactMap { normalized($0) }
        result.currentToolDescriptor = normalized(checkpoint.currentToolDescriptor)
        result.terminalDescriptor = normalized(checkpoint.terminalDescriptor)
        result.metadataDescriptor = normalized(checkpoint.metadataDescriptor)
        return result
    }

    func delete(agentID: AgentID, sessionKey: String) {
        TranscriptIOThreadAudit.recordIO()
        let url = indexFileURL(agentID: agentID, sessionKey: sessionKey)
        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }

    func purgeOrphans(
        agentID: AgentID,
        referencedSessionKeys: Set<String>,
        now: Date = Date()
    ) {
        TranscriptIOThreadAudit.recordIO()
        let dir = agentDirectory(agentID: agentID)
        let referencedDigests = Set(referencedSessionKeys.map {
            digest(agentID.rawValue + "\u{0}" + $0)
        })
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let staleThreshold = now.addingTimeInterval(-Self.orphanRetentionPeriod)
        for entry in entries where entry.pathExtension == "json" {
            let name = entry.deletingPathExtension().lastPathComponent
            guard !referencedDigests.contains(name) else { continue }
            let modified = (try? entry.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            if modified < staleThreshold {
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    private func digest(_ value: String) -> String {
        let hash = SHA256.hash(data: Data(value.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func permissionsAreStrictForLoad(url: URL, agentID: AgentID) -> Bool {
        let agentDir = agentDirectory(agentID: agentID)
        guard permissionsMatch(path: rootDirectory.path, expected: S_IRWXU),
              permissionsMatch(path: agentDir.path, expected: S_IRWXU)
        else { return false }
        guard fileManager.fileExists(atPath: url.path) else { return true }
        return permissionsMatch(path: url.path, expected: S_IRUSR | S_IWUSR)
    }

    private func permissionsMatch(path: String, expected: mode_t) -> Bool {
        var statBuffer = stat()
        guard lstat(path, &statBuffer) == 0 else { return false }
        return (statBuffer.st_mode & mode_t(0o777)) == expected
    }
}

// MARK: - FileManager 便捷（供索引删除用）

private extension FileManager {
    func isDirectory(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
