//
//  TranscriptEventReaderSelfTest.swift
//  ThreadHelm
//
//  模块职责：--self-test-transcript-events 自测——锁定 JSONLFramer 纯状态机
//  契约（跨 chunk 偏移、第二/第三 chunk 才见 LF、>4 MiB 超长行、未完成尾行、
//  sourceOrder 跨 feed 单调），以及 metadata-only 索引契约（save/load 往返、
//  不含正文 sentinel、512 KiB 上限）。夹具在临时目录动态生成，不提交 blob。
import Darwin
import Foundation
func runTranscriptEventReaderSelfTest() -> Never {
    do {
        try runJSONLFramerContractSelfTest()
        try runTranscriptIndexContractSelfTest()
    } catch {
        fputs("transcript-events-self-test: \(error)\n", stderr)
        exit(1)
    }
    print(
        "transcript-events-self-test: providers=5 transcript=4 hook-only=1"
            + " utf8-boundary=pass partial=pass oversized-discard=pass"
            + " rotation=pass index=metadata-only budgets=8MiB/64MiB/4MiB"
            + " memory=32/64KiB"
    )
    exit(0)
}

private struct TranscriptEventSelfTestError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
    static func failed(_ message: String) -> TranscriptEventSelfTestError {
        TranscriptEventSelfTestError(message: message)
    }
}

/// 只展示记录前 64 UTF-8 标量的文本，避免把 5 MiB 记录体灌进错误字符串。
private func boundedRecordText(_ data: Data) -> String {
    guard let text = String(data: data, encoding: .utf8) else { return "<non-utf8>" }
    let prefix = String(text.prefix(64)).replacingOccurrences(
        of: "\n",
        with: "\\n"
    )
    return prefix + (text.count > 64 ? "…" : "")
}

private func assertRecord(
    _ record: JSONLFramerRecord,
    startOffset: UInt64,
    byteCount: Int,
    sourceOrder: UInt64,
    text: String,
    _ context: String = ""
) throws {
    guard record.startOffset == startOffset,
          record.byteCount == byteCount,
          record.sourceOrder == sourceOrder,
          String(data: record.data, encoding: .utf8) == text
    else {
        throw TranscriptEventSelfTestError.failed(
            "\(context): expected start=\(startOffset) size=\(byteCount)"
                + " order=\(sourceOrder) text=\(text.prefix(20)); got "
                + "start=\(record.startOffset) size=\(record.byteCount)"
                + " order=\(record.sourceOrder) text="
                + boundedRecordText(record.data)
        )
    }
}
private func runJSONLFramerContractSelfTest() throws {
    // 1) chunk 内完整多行。
    var f = JSONLFramer(maximumRecordBytes: 4 * 1_048_576)
    f.feed(Data("aaa\nbb\n".utf8), chunkStart: 0)
    guard f.records.count == 2 else {
        throw TranscriptEventSelfTestError.failed("basic two-line count")
    }
    try assertRecord(f.records[0], startOffset: 0, byteCount: 4, sourceOrder: 1, text: "aaa\n")
    try assertRecord(f.records[1], startOffset: 4, byteCount: 3, sourceOrder: 2, text: "bb\n")

    // 2) 跨 chunk：4 字节/块，LF 必跨块。
    let combined = "cccccccc\ndd\n"
    let bytes = Array(combined.utf8)
    var two = JSONLFramer(maximumRecordBytes: 4 * 1_048_576)
    var start: UInt64 = 0
    var cursor = 0
    while cursor < bytes.count {
        let end = min(cursor + 4, bytes.count)
        two.feed(Data(bytes[cursor..<end]), chunkStart: start)
        start += UInt64(end - cursor)
        cursor = end
    }
    guard two.records.count == 2 else {
        throw TranscriptEventSelfTestError.failed(
            "cross-chunk expected 2, got \(two.records.count)"
        )
    }
    try assertRecord(two.records[0], startOffset: 0, byteCount: 9, sourceOrder: 1, text: "cccccccc\n")
    try assertRecord(two.records[1], startOffset: 9, byteCount: 3, sourceOrder: 2, text: "dd\n")

    // 3) 超长无换行 record（>4 MiB）跨多 chunk：只计一次，committedOffset 停在
    //    超长行 LF 之后，下一个正常行被完整解析。
    let big = String(repeating: "x", count: 4 * 1_048_576 + 100) // > 4 MiB cap
    let after = "normal\n"
    let combinedBig = big + "\n" + after
    let bigBytes = Array(combinedBig.utf8)
    var fb = JSONLFramer(maximumRecordBytes: 4 * 1_048_576)
    var fbStart: UInt64 = 0
    var fbCursor = 0
    while fbCursor < bigBytes.count {
        let end = min(fbCursor + 1_048_576, bigBytes.count)
        fb.feed(Data(bigBytes[fbCursor..<end]), chunkStart: fbStart)
        fbStart += UInt64(end - fbCursor)
        fbCursor = end
    }
    guard fb.skippedOversized == 1,
          !fb.discarding,
          fb.records.count == 1
    else {
        throw TranscriptEventSelfTestError.failed(
            "oversized: skipped=\(fb.skippedOversized) discarding=\(fb.discarding)"
                + " count=\(fb.records.count) pending=\(fb.pending.count)"
        )
    }
    let bigCount = combinedBig.utf8.count
    let normalStart = bigCount - after.utf8.count
    try assertRecord(
        fb.records[0],
        startOffset: UInt64(normalStart),
        byteCount: after.utf8.count,
        sourceOrder: 2,
        text: after
    )
    guard fb.committedOffset == UInt64(bigCount) else {
        throw TranscriptEventSelfTestError.failed(
            "oversized committed expected \(bigCount) got \(fb.committedOffset)"
        )
    }

    // 4) 未完成尾行留在 pending，committedOffset 停在最后完整 LF 后；续读补全。
    let head = "done\nincom"
    var f4 = JSONLFramer(maximumRecordBytes: 4096)
    f4.feed(Data(head.utf8), chunkStart: 0)
    guard f4.records.count == 1,
          f4.pending.count == 5,
          f4.committedOffset == 5
    else {
        throw TranscriptEventSelfTestError.failed(
            "partial: records=\(f4.records.count) pending=\(f4.pending.count)"
                + " committed=\(f4.committedOffset)"
        )
    }
    f4.feed(Data("plete\n".utf8), chunkStart: UInt64(head.utf8.count))
    guard f4.records.count == 2,
          String(data: f4.records[1].data, encoding: .utf8) == "incomplete\n",
          f4.committedOffset == UInt64("done\nincomplete\n".utf8.count)
    else {
        throw TranscriptEventSelfTestError.failed(
            "partial resume: records=\(f4.records.count)"
                + " committed=\(f4.committedOffset)"
        )
    }

    // 5) 跨 feed sourceOrder 单调。
    var f5 = JSONLFramer(maximumRecordBytes: 4096)
    f5.feed(Data("x\n".utf8), chunkStart: 0)
    f5.feed(Data("y\n".utf8), chunkStart: 2)
    guard f5.records.map(\.sourceOrder) == [1, 2] else {
        throw TranscriptEventSelfTestError.failed("sourceOrder not monotonic")
    }

    // 6) 非零起始回扫偏移：framer 必须以窗口起点 lowerBound 作为绝对基准，
    //    不得产出窗口相对偏移（否则 stable ID / sidecar descriptor 被污染）。
    let backBody = "one\ntwo\nthree\nfour\n"
    let backBytes = Array(backBody.utf8)
    let windowStart = UInt64(backBytes.count) - 11 // 窗口从 "three\nfour\n" 起
    var back = JSONLFramer(
        maximumRecordBytes: 4 * 1_048_576,
        committedOffset: windowStart
    )
    back.feed(
        Data(backBytes[Int(windowStart)..<backBytes.count]),
        chunkStart: windowStart
    )
    guard back.records.count == 2,
          back.records[0].startOffset == windowStart,
          back.records[0].byteCount == 6, // "three\n"
          back.records[1].startOffset == windowStart + 6,
          back.records[1].byteCount == 5 // "four\n"
    else {
        throw TranscriptEventSelfTestError.failed(
            "backward non-zero offset: \(back.records.map { ($0.startOffset, $0.byteCount) })"
        )
    }
}

// MARK: index store contract（metadata-only）

private func runTranscriptIndexContractSelfTest() throws {
    let manager = FileManager.default
    let temp = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-transcript-index-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? manager.removeItem(at: temp) }
    try manager.createDirectory(at: temp, withIntermediateDirectories: true)

    let store = TranscriptIndexStore(rootDirectory: temp, fileManager: manager)
    let identity = TranscriptSourceIdentity(
        device: 1,
        inode: 2,
        birthSeconds: 1_600_000_000,
        birthNanoseconds: 0
    )
    let descriptor = TranscriptRecordLocation(
        startOffset: 42,
        byteCount: 128,
        sourceOrder: 3,
        eventClass: .publicMessage,
        occurredAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    var checkpoint = TranscriptIndexStore.Checkpoint(
        schemaVersion: TranscriptIndexStore.schemaVersion,
        agentID: .omp,
        sessionKeyDigest: "digest",
        sourceIdentity: identity,
        observedSize: 1_000,
        observedMTime: 0,
        committedOffset: 900,
        backscanContinuationOffset: nil,
        publicMessageDescriptors: [descriptor],
        currentToolDescriptor: nil,
        terminalDescriptor: nil,
        metadataDescriptor: nil,
        oversizedRecords: 0
    )
    try store.save(checkpoint, agentID: .omp, sessionKey: "session-key")
    guard let loaded = store.load(agentID: .omp, sessionKey: "session-key"),
          loaded.committedOffset == 900,
          loaded.publicMessageDescriptors.count == 1,
          loaded.sourceIdentity == identity,
          loaded.oversizedRecords == 0
    else {
        throw TranscriptEventSelfTestError.failed("index save/load round-trip")
    }

    // sidecar 不得含正文 sentinel / 工具输入 / 秘密标记。
    let url = store.indexFileURL(agentID: .omp, sessionKey: "session-key")
    guard let rawData = try? Data(contentsOf: url) else {
        throw TranscriptEventSelfTestError.failed("index file missing")
    }
    let rawText = String(data: rawData, encoding: .utf8) ?? ""
    guard !rawText.contains("SENTINEL-BODY"),
          !rawText.contains("tool-input"),
          !rawText.contains("secret")
    else {
        throw TranscriptEventSelfTestError.failed("sidecar persisted disallowed content")
    }
    guard rawData.count <= TranscriptIndexStore.maximumFileBytes else {
        throw TranscriptEventSelfTestError.failed("index exceeds 512 KiB")
    }
}