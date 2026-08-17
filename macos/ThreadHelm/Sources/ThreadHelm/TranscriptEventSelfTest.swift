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
        try runTranscriptReaderContractSelfTest()
        try runTranscriptIndexContractSelfTest()
        try runTranscriptRestartEquivalenceSelfTest()
        try runSameSizeAtomicReplaceIdentitySelfTest()
    } catch {
        fputs("transcript-events-self-test: \(error)\n", stderr)
        exit(1)
    }
    print(
        "transcript-events-self-test: providers=5 transcript=4 hook-only=1"
            + " index=metadata-only restart=index-hit+cold-scan+incremental-tail"
            + " samesize-replace=identityChanged"
            + " budgets=8MiB/64MiB/4MiB memory=32/64KiB"
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

// MARK: Reader contract（真实文件驱动）

private func runTranscriptReaderContractSelfTest() throws {
    let manager = FileManager.default
    let temp = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-reader-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? manager.removeItem(at: temp) }
    try manager.createDirectory(at: temp, withIntermediateDirectories: true)

    let identity = TranscriptSourceIdentity(
        device: 3,
        inode: 4,
        birthSeconds: 1_600_000_000,
        birthNanoseconds: 0
    )

    // 1) forward pass 读完整记录（用 make 捕获真实 identity）。
    let smallURL = temp.appendingPathComponent("small.jsonl")
    try Data("alpha\nbeta\n".utf8).write(to: smallURL)
    guard var reader = TranscriptEventReader.make(at: smallURL) else {
        throw TranscriptEventSelfTestError.failed("reader make failed")
    }
    let pass1 = try XCTUnwrapResult(reader.readForwardPass())
    guard pass1.count == 2,
          pass1[0].data == Data("alpha\n".utf8),
          pass1[1].data == Data("beta\n".utf8),
          reader.committedOffset == UInt64("alpha\nbeta\n".utf8.count),
          reader.scanHead == UInt64("alpha\nbeta\n".utf8.count)
    else {
        throw TranscriptEventSelfTestError.failed(
            "reader forward pass: count=\(pass1.count)"
                + " scanHead=\(reader.scanHead)"
                + " committed=\(reader.committedOffset)"
        )
    }
    // 2) 增量：追加（保留 inode）后第二次 pass 只读新增。
    let appendHandle = try FileHandle(forWritingTo: smallURL)
    try appendHandle.seekToEnd()
    try appendHandle.write(contentsOf: Data("gamma\n".utf8))
    try appendHandle.close()
    let pass2 = try XCTUnwrapResult(reader.readForwardPass())
    guard pass2.count == 1,
          pass2[0].data == Data("gamma\n".utf8),
          reader.committedOffset == UInt64("alpha\nbeta\ngamma\n".utf8.count),
          reader.scanHead == UInt64("alpha\nbeta\ngamma\n".utf8.count)
    else {
        throw TranscriptEventSelfTestError.failed(
            "reader incremental tail: count=\(pass2.count) data="
                + "\(pass2.map { String(data: $0.data, encoding: .utf8) ?? "?" })"
                + " committed=\(reader.committedOffset)"
                + " scanHead=\(reader.scanHead)"
        )
    }

    // 3) identity 改变：不同 identity 的 reader 在同一文件上应 identity 失败。
    let otherIdentity = TranscriptSourceIdentity(
        device: 3,
        inode: 5,
        birthSeconds: 1_600_000_000,
        birthNanoseconds: 0
    )
    let mismatched = TranscriptEventReader(url: smallURL, identity: otherIdentity)
    if case .success = mismatched.readForwardPass() {
        throw TranscriptEventSelfTestError.failed("reader identity mismatch accepted")
    }
    // 缺失文件 → ioFailed。
    let missingURL = temp.appendingPathComponent("missing.jsonl")
    let missingReader = TranscriptEventReader(url: missingURL, identity: identity)
    if case .success = missingReader.readForwardPass() {
        throw TranscriptEventSelfTestError.failed("reader ioFailed on missing file")
    }

    // 4) 跨 pass 超长行不前进死锁：>8 MiB 无 LF 行 + 结尾 "tail\n"。用注入
    //    的 Fake 单调时钟避免真实 50 ms wall budget 抢先终止造成歧义。
    let huge = String(repeating: "y", count: 10 * 1_048_576) // >8 MiB
    let hugeURL = temp.appendingPathComponent("huge.jsonl")
    let hugeData = Data((huge + "\ntail\n").utf8)
    try hugeData.write(to: hugeURL)
    let fakeClock = FakeTranscriptMonotonicClock()
    guard let hugeReader = TranscriptEventReader.make(
        at: hugeURL,
        clock: fakeClock
    ) else {
        throw TranscriptEventSelfTestError.failed("reader huge make failed")
    }
    let hugePass1 = try XCTUnwrapResult(hugeReader.readForwardPass())
    guard hugePass1.isEmpty else {
        throw TranscriptEventSelfTestError.failed("reader huge pass1 produced records")
    }
    // scanHead 前进到 8 MiB pass 边界；committedOffset 不前进（停在起始）。
    guard hugeReader.scanHead == UInt64(8 * 1_048_576) else {
        throw TranscriptEventSelfTestError.failed(
            "reader huge pass1 scanHead stuck: \(hugeReader.scanHead)"
        )
    }
    // 第二 pass：读到 LF + tail，恢复。
    let hugePass2 = try XCTUnwrapResult(hugeReader.readForwardPass())
    guard hugePass2.contains(where: { $0.data == Data("tail\n".utf8) }) else {
        throw TranscriptEventSelfTestError.failed(
            "reader huge pass2 did not resume after LF (records \(hugePass2.count))"
        )
    }
    guard hugeReader.scanHead == UInt64(hugeData.count) else {
        throw TranscriptEventSelfTestError.failed(
            "reader huge scanHead not at EOF"
        )
    }
    // 5) 读取中 truncate 到 readStart+consumed 与 committedOffset 之间：
    //    partial/discard 时 committedOffset 落后于本轮已读终点，旧校验
    //    (fileSize >= committedOffset) 会放行 stale bytes 并让 scanHead
    //    越过新 EOF。用 postReadHook 在读完 chunk、校验前截断。
    let truncURL = temp.appendingPathComponent("trunc.jsonl")
    // 2 MiB 无 LF 行、且 8 MiB pass 内完全没有 LF：pass 结束 committedOffset
    // 仍为 0，而 consumed 已读到 2 MiB。这样旧校验（fileSize>=committed=0）
    // 会放行并把 cursor 越过新 EOF；新校验（fileSize>=readEndpoint）失败。
    let prefixLine = String(repeating: "p", count: 2 * 1_048_576) // 2 MiB 无 LF
    try Data(prefixLine.utf8).write(to: truncURL)
    guard let truncReader = TranscriptEventReader.make(at: truncURL) else {
        throw TranscriptEventSelfTestError.failed("reader trunc make failed")
    }
    // 读到 2 MiB 后、校验前截断到 1 byte（保留 inode，identity 不变）。
    truncReader.postReadHook = {
        do {
            let h = try FileHandle(forWritingTo: truncURL)
            try h.truncate(atOffset: 1)
            try h.close()
        } catch {
            // 忽略：让 fileSize 校验决定结果
        }
    }
    let truncResult = truncReader.readForwardPass()
    guard case .failure(.truncation) = truncResult else {
        throw TranscriptEventSelfTestError.failed(
            "reader mid-read truncate not flagged as truncation: "
                + "\(truncResult)"
        )
    }
    // committedOffset / scanHead 不得前进越过新 EOF（本轮丢弃，无提交）。
    guard truncReader.committedOffset == 0,
          truncReader.scanHead == 0
    else {
        throw TranscriptEventSelfTestError.failed(
            "reader mid-read truncate advanced cursor: "
                + "committed=\(truncReader.committedOffset)"
                + " scanHead=\(truncReader.scanHead)"
        )
    }

    // 6) readBackwardPass 跨边界：用小 budget 强制 lowerBound > 0，
    //    验证头部片段被丢弃、continuation 指向第一个完整记录起点，
    //    跨边界记录不丢失（AC-07）。
    let backURL = temp.appendingPathComponent("back.jsonl")
    // 三条记录：rec0 短、rec1 长（跨越 budget 边界）、rec2 短。
    let rec0 = Data("{\"i\":0}\n".utf8)
    let rec1Body = String(repeating: "x", count: 300)
    let rec1 = Data("{\"i\":1,\"d\":\"\(rec1Body)\"}\n".utf8)
    let rec2 = Data("{\"i\":2}\n".utf8)
    var backFile = rec0
    backFile.append(rec1)
    backFile.append(rec2)
    try backFile.write(to: backURL)

    let rec0End = UInt64(rec0.count)
    let rec1End = UInt64(rec0.count + rec1.count)
    let rec2End = UInt64(backFile.count)

    // 第一轮 backward pass：从 EOF 读 rec2 + rec1 的尾部。
    // budget 刚好读完 rec2 + 部分进入 rec1 但不到 rec0。
    let backBudget = TranscriptReadBudget(
        chunkBytes: 1_048_576,
        maximumBytesPerPass: 8 * 1_048_576,
        maximumAutomaticBackscanBytes: 64 * 1_048_576,
        maximumRecordBytes: 4 * 1_048_576,
        softWallTime: 0.05
    )
    guard let backReader = TranscriptEventReader.make(
        at: backURL,
        budget: backBudget
    ) else {
        throw TranscriptEventSelfTestError.failed("reader back make failed")
    }
    // pass 1：从 EOF 向前读 rec2.size + 部分 rec1（但不完整）。
    // 只读 rec2 这条完整记录：rec1 的尾部是片段，被丢弃。
    let pass1Bytes = rec2.count + 10 // 只进入 rec1 的尾部
    let backResult1 = try XCTUnwrapResult(backReader.readBackwardPass(
        fromEnd: rec2End,
        maximumBytes: pass1Bytes
    ))
    let (backRecords1, cont1, _) = backResult1
    // 只应恢复 rec2（rec1 尾部片段被丢弃）。
    guard backRecords1.count == 1,
          backRecords1[0].data == rec2
    else {
        throw TranscriptEventSelfTestError.failed(
            "backward pass1: count=\(backRecords1.count)"
                + " data=\(backRecords1.map { String(data: $0.data, encoding: .utf8) ?? "?" })"
        )
    }
    // continuation 指向 rec2 的起点（= rec1 结束位置）。
    guard cont1 == rec1End else {
        throw TranscriptEventSelfTestError.failed(
            "backward pass1 continuation: got \(cont1 ?? 0) expected \(rec1End)"
        )
    }

    // pass 2：从 rec1End 向前读 rec1 + rec0 尾部（5 bytes）。
    // lowerBound = rec0End - 5 > 0，所以 rec0 尾部片段被丢弃。
    // rec1 完整恢复（片段后第一个 LF 标记 rec1 起点）。
    let pass2Bytes = rec1.count + 5
    let backResult2 = try XCTUnwrapResult(backReader.readBackwardPass(
        fromEnd: cont1!,
        maximumBytes: pass2Bytes
    ))
    let (backRecords2, cont2, _) = backResult2
    guard backRecords2.count == 1,
          backRecords2[0].data == rec1
    else {
        throw TranscriptEventSelfTestError.failed(
            "backward pass2: count=\(backRecords2.count)"
                + " data=\(backRecords2.map { String(data: $0.data, encoding: .utf8) ?? "?" })"
        )
    }
    // continuation 指向 rec1 的起点（= rec0 结束位置）。
    guard cont2 == rec0End else {
        throw TranscriptEventSelfTestError.failed(
            "backward pass2 continuation: got \(cont2 ?? 0) expected \(rec0End)"
        )
    }

    // pass 3：从 rec0End 向前读 rec0（lowerBound == 0，无片段丢弃）。
    let backResult3 = try XCTUnwrapResult(backReader.readBackwardPass(
        fromEnd: cont2!,
        maximumBytes: rec0.count
    ))
    let (backRecords3, cont3, _) = backResult3
    guard backRecords3.count == 1,
          backRecords3[0].data == rec0
    else {
        throw TranscriptEventSelfTestError.failed(
            "backward pass3: count=\(backRecords3.count)"
                + " data=\(backRecords3.map { String(data: $0.data, encoding: .utf8) ?? "?" })"
        )
    }
    // lowerBound == 0 → continuation == nil（到达文件头）。
    guard cont3 == nil else {
        throw TranscriptEventSelfTestError.failed(
            "backward pass3 continuation: got \(cont3 ?? 0) expected nil"
        )
    }
}

private func XCTUnwrapResult<T>(
    _ result: Result<T, TranscriptReadError>
) throws -> T {
    switch result {
    case .success(let value):
        return value
    case .failure(let error):
        throw TranscriptEventSelfTestError.failed("reader failed: \(error)")
    }
}
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

// MARK: Index-hit / cold-scan / incremental-tail 等价回归

private func runTranscriptRestartEquivalenceSelfTest() throws {
    let manager = FileManager.default
    let temp = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-restart-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? manager.removeItem(at: temp) }
    try manager.createDirectory(at: temp, withIntermediateDirectories: true)

    let url = temp.appendingPathComponent("session.jsonl")
    // 小预算：回扫上限 128 KiB。头部消息在 256 KiB padding 之后，
    // 超出回扫预算（模拟 >64 MiB cold-scan 不可达）。
    let smallBudget = TranscriptReadBudget(
        chunkBytes: 4_096,
        maximumBytesPerPass: 16_384,
        maximumAutomaticBackscanBytes: 128 * 1_024,
        maximumRecordBytes: 4 * 1_048_576,
        softWallTime: 0.05
    )

    // 头部 public message（超出回扫预算，冷扫不可达）
    let headLine = #"{"role":"assistant","content":[{"type":"text","text":"头部消息超出回扫预算"}]}"# + "\n"
    // 256 KiB padding（确保头部消息在回扫窗口之外）
    let padding = String(repeating: "{\"i\":0}\n", count: 20_000)
    // 尾部 public message（回扫可达）
    let tailLine = #"{"role":"assistant","content":[{"type":"text","text":"尾部消息在回扫窗口内"}]}"# + "\n"

    try Data((headLine + padding + tailLine).utf8).write(to: url)

    // 1) Cold-scan：从 EOF 回扫，只恢复尾部消息
    guard let coldReader = TranscriptEventReader.make(
        at: url, budget: smallBudget
    ) else {
        throw TranscriptEventSelfTestError.failed("restart: cold reader make failed")
    }
    let fileSize = (try? manager.attributesOfItem(
        atPath: url.path
    )[.size] as? NSNumber)?.uint64Value ?? 0
    coldReader.setCommittedOffset(fileSize)
    var coldRecords: [TranscriptRecordRange] = []
    var cont: UInt64? = fileSize
    var budget = smallBudget.maximumAutomaticBackscanBytes
    while budget > 0, let end = cont, end > 0 {
        let passBytes = min(budget, smallBudget.maximumBytesPerPass)
        let result = try XCTUnwrapResult(coldReader.readBackwardPass(
            fromEnd: end, maximumBytes: passBytes
        ))
        coldRecords = result.records + coldRecords
        cont = result.continuation
        budget -= passBytes
        if cont == nil { break }
    }
    let coldTexts = coldRecords.compactMap {
        String(data: $0.data, encoding: .utf8)
    }
    // 头部消息不可达（超出回扫预算），只恢复尾部消息
    let coldHasTail = coldTexts.contains { $0.contains("尾部消息") }
    let coldHasHead = coldTexts.contains { $0.contains("头部消息") }
    guard coldHasTail, !coldHasHead else {
        throw TranscriptEventSelfTestError.failed(
            "restart cold-scan: hasTail=\(coldHasTail) hasHead=\(coldHasHead)"
        )
    }

    let descriptors = coldRecords.compactMap { record -> TranscriptRecordLocation? in
        guard let text = String(data: record.data, encoding: .utf8),
              text.contains("尾部消息") || text.contains("头部消息")
        else { return nil }
        return TranscriptRecordLocation(
            startOffset: record.startOffset,
            byteCount: UInt32(record.byteCount),
            sourceOrder: record.sourceOrder,
            eventClass: .publicMessage,
            occurredAt: nil
        )
    }
    let store = TranscriptIndexStore(rootDirectory: temp, fileManager: manager)

    let checkpoint = TranscriptIndexStore.Checkpoint(
        schemaVersion: TranscriptIndexStore.schemaVersion,
        agentID: .codex,
        sessionKeyDigest: "test-restart",
        sourceIdentity: coldReader.identity,
        observedSize: fileSize,
        observedMTime: 0,
        committedOffset: fileSize,
        backscanContinuationOffset: cont,
        publicMessageDescriptors: descriptors,
        currentToolDescriptor: nil,
        terminalDescriptor: nil,
        metadataDescriptor: nil,
        oversizedRecords: 0
    )
    try store.save(checkpoint, agentID: .codex, sessionKey: "test-restart")

    // 3) Index-hit：加载 checkpoint，从 descriptor 回读
    let loaded = store.load(agentID: .codex, sessionKey: "test-restart")
    guard let loaded = loaded,
          loaded.sourceIdentity == coldReader.identity
    else {
        throw TranscriptEventSelfTestError.failed("restart: checkpoint load/identity failed")
    }
    guard let hitReader = TranscriptEventReader.make(
        at: url, budget: smallBudget
    ) else {
        throw TranscriptEventSelfTestError.failed("restart: hit reader make failed")
    }
    hitReader.setCommittedOffset(loaded.committedOffset)
    let hitRecords = loaded.publicMessageDescriptors.compactMap {
        hitReader.readRange($0)
    }
    let hitTexts = hitRecords.compactMap {
        String(data: $0, encoding: .utf8)
    }
    // Index-hit 应与 cold-scan 等价：恢复尾部消息，不恢复头部
    let hitHasTail = hitTexts.contains { $0.contains("尾部消息") }
    let hitHasHead = hitTexts.contains { $0.contains("头部消息") }
    guard hitHasTail, !hitHasHead else {
        throw TranscriptEventSelfTestError.failed(
            "restart index-hit: hasTail=\(hitHasTail) hasHead=\(hitHasHead)"
        )
    }

    // 4) Incremental-tail：追加新消息，前向 pass 只读追加字节
    let appendLine = #"{"role":"assistant","content":[{"type":"text","text":"增量追加的新消息"}]}"# + "\n"
    let appendHandle = try FileHandle(forWritingTo: url)
    try appendHandle.seekToEnd()
    try appendHandle.write(contentsOf: Data(appendLine.utf8))
    try appendHandle.close()

    let forwardResult = try XCTUnwrapResult(hitReader.readForwardPass())
    let forwardTexts = forwardResult.compactMap {
        String(data: $0.data, encoding: .utf8)
    }
    // 增量 pass 只恢复新追加的消息
    guard forwardTexts.count == 1,
          forwardTexts.first?.contains("增量追加的新消息") == true
    else {
        throw TranscriptEventSelfTestError.failed(
            "restart incremental-tail: count=\(forwardTexts.count)"
            + " texts=\(forwardTexts)"
        )
    }
}

// MARK: 同大小原子替换 identity 回归

/// reader 在 EOF（remaining == 0）时，路径被原子替换为同大小新 inode，
/// readForwardPass 必须返回 .identityChanged——绝不能直接 .success([])，
/// 否则 Codex/Claude 会把旧 reducer 以新 mtime 缓存并长期显示错误投影。
private func runSameSizeAtomicReplaceIdentitySelfTest() throws {
    let manager = FileManager.default
    let temp = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-samesize-replace-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? manager.removeItem(at: temp) }
    try manager.createDirectory(at: temp, withIntermediateDirectories: true)
    let url = temp.appendingPathComponent("session.jsonl")
    let line = #"{"role":"assistant","content":[{"type":"text","text":"AAA"}]}"# + "\n"
    try Data(line.utf8).write(to: url)

    guard let reader = TranscriptEventReader.make(at: url) else {
        throw TranscriptEventSelfTestError.failed("samesize: reader make failed")
    }
    // 读到 EOF。
    let first = try XCTUnwrapResult(reader.readForwardPass())
    guard first.count == 1 else {
        throw TranscriptEventSelfTestError.failed(
            "samesize: first pass count=\(first.count)"
        )
    }
    guard reader.scanHeadReachedEOF else {
        throw TranscriptEventSelfTestError.failed(
            "samesize: reader must reach EOF after first pass"
        )
    }

    // 同大小原子替换：新 inode、同 mtime/size。
    let replacementURL = temp.appendingPathComponent("replacement.jsonl")
    let replacement = #"{"role":"assistant","content":[{"type":"text","text":"BBB"}]}"# + "\n"
    try Data(replacement.utf8).write(to: replacementURL)
    // 等长才满足 same-size（两行文本等长，含 LF）。
    guard (try? Data(contentsOf: replacementURL).count)
            == (try? Data(contentsOf: url).count)
    else {
        throw TranscriptEventSelfTestError.failed(
            "samesize: fixture lines must be equal length"
        )
    }
    try manager.replaceItemAt(
        url,
        withItemAt: replacementURL,
        backupItemName: nil,
        options: []
    )

    // 第二次 pass：路径已被替换为同大小新 inode，
    // remaining == 0（scanHead == 旧 fileSize == 新 fileSize），
    // 但 identity 已变，必须失败。
    let second = reader.readForwardPass()
    guard case .failure(.identityChanged) = second else {
        throw TranscriptEventSelfTestError.failed(
            "samesize: expected .identityChanged, got \(second)"
        )
    }
}