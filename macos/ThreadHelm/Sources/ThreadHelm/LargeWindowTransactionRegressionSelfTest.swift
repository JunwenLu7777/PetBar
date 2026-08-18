//
//  LargeTranscriptWindowRegressionSelfTest.swift
//  ThreadHelm
//
//  模块职责：Phase 0 红灯证据与逆向 Green 回归。四种 transcript（Codex、
//  Claude Code、Cursor、OMP）在 7–8 MiB tool-only 尾部样本上断言正向契约——
//  "最近公开消息距 EOF 至少 7 MiB 且其后只有合法 tool 记录时，该正文必须被
//  恢复，纯 tool 尾部不得进入公开正文"。ZCode 明确走 Hook-only 路径（无
//  transcript），不在此列。
//
//  当前固定窗口读取（Codex/Claude/Cursor 固定 1 MiB 尾读、OMP prefix+tail）
//  在四个来源上均应显示红灯（各自断言失败聚合上报，进程非零退出）；共享
//  reader/索引落地后转为绿灯（退出 0）。断言正向契约，绝不把"正文未恢复"
//  固化成通过断言。
//
//  fixture 约束（与共享 reader 预算对齐）：所有单条 tool 记录必须远小于
//  4 MiB record cap，只用多条小 tool record 累计 20 MiB 尾部；sentinel 落
//  在 64 MiB 自动回扫预算内，修复后通过 continuation 恢复。
//

import Foundation

func runLargeTranscriptWindowRegressionSelfTest() -> Never {
    var failures: [String] = []
    runProviderCase("reader-ac02", failures: &failures) {
        try runReaderContinuationRestoresPublicMessageAfterTwentyMiBTailSelfTest()
    }
    runProviderCase("reader-ac03-forward", failures: &failures) {
        try runReaderForwardPassStopsAtChunkBoundaryAfterSoftWallTimeSelfTest()
    }
    runProviderCase("reader-ac03-backward", failures: &failures) {
        try runReaderBackwardPassStopsAtChunkBoundaryAfterSoftWallTimeSelfTest()
    }
    runProviderCase("reader-ac14-cancel", failures: &failures) {
        try runReaderBackwardPassCancelsAtChunkBoundarySelfTest()
    }
    runProviderCase("omp", failures: &failures) {
        try runOMPLargeToolTailRecoverySelfTest()
    }
    runProviderCase("omp-budget", failures: &failures) {
        try runOMPRefreshBudgetAndCheckpointSelfTest()
    }
    runProviderCase("omp-lifecycle-cap", failures: &failures) {
        try runOMPBackscanLifecycleCapSelfTest()
    }
    runProviderCase("omp-missing-source-index-delete", failures: &failures) {
        try runOMPMissingSourceDeletesSidecarSelfTest()
    }
    runProviderCase("omp-descriptor-budget", failures: &failures) {
        try runOMPDescriptorRestoreBudgetSelfTest()
    }
    runProviderCase("cursor", failures: &failures) {
        try runCursorLargeToolTailRecoverySelfTest()
    }
    runProviderCase("codex", failures: &failures) {
        try runCodexLargeToolTailRecoverySelfTest()
    }
    runProviderCase("claude", failures: &failures) {
        try runClaudeLargeToolTailRecoverySelfTest()
    }

    if failures.isEmpty {
        fputs(
            "large-window-regression: providers=4 ac02=20MiB-continuation ac03=100MiB-soft-stop ac14=chunk-cancel\n",
            stderr
        )
        exit(0)
    }
    fputs(
        "large-window-regression FAILED: \(failures.joined(separator: "；"))\n",
        stderr
    )
    exit(1)
}

private func runProviderCase(
    _ name: String,
    failures: inout [String],
    body: () throws -> Void
) {
    do {
        try body()
    } catch {
        failures.append("\(name): \(error)")
    }
}

/// 生成若干条 tool 记录累计约 targetBytes 字节；单条固定（含小后缀去重），
/// 远低于 4 MiB record cap。
private func makeToolRecords(
    lineTemplate: (String) -> String,
    targetBytes: Int
) -> [String] {
    let smallChunk = String(repeating: "tool-pad-", count: 8_000) // ~72 KB
    let single = lineTemplate(smallChunk) + "\n"
    let singleSize = single.utf8.count
    guard singleSize > 0, singleSize < 4 * 1_048_576 else { return [] }
    let count = max(1, targetBytes / singleSize) + 2
    return (0..<count).map { index in
        lineTemplate(smallChunk + "-\(index)")
    }
}

private final class AdvancingTranscriptClock: TranscriptMonotonicClock {
    private var callCount = 0
    private let start: UInt64
    private let step: UInt64

    init(start: UInt64 = 1_000_000_000_000, step: UInt64) {
        self.start = start
        self.step = step
    }

    func nowNanoseconds() -> UInt64 {
        defer { callCount += 1 }
        return start + UInt64(callCount) * step
    }
}

private func fileSize(_ url: URL) throws -> UInt64 {
    let value = try FileManager.default.attributesOfItem(
        atPath: url.path
    )[.size] as? NSNumber
    return value?.uint64Value ?? 0
}

private func makeStreamingToolTranscript(
    at url: URL,
    prefixLines: [String] = [],
    lineTemplate: (Int) -> String,
    tailBytes: Int
) throws {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    for line in prefixLines {
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }
    let sample = lineTemplate(0) + "\n"
    let sampleSize = sample.utf8.count
    guard sampleSize > 0, sampleSize < 4 * 1_048_576 else {
        throw LargeWindowSelfTestError.failed("tool record size violates budget")
    }
    let count = max(1, tailBytes / sampleSize) + 2
    for index in 0..<count {
        try handle.write(contentsOf: Data((lineTemplate(index) + "\n").utf8))
    }
}

private func unwrapTranscriptResult<T>(
    _ result: Result<T, TranscriptReadError>,
    _ label: String
) throws -> T {
    switch result {
    case .success(let value):
        return value
    case .failure(let error):
        throw LargeWindowSelfTestError.failed("\(label) failed: \(error)")
    }
}

private func runReaderContinuationRestoresPublicMessageAfterTwentyMiBTailSelfTest()
    throws
{
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-reader-ac02-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? manager.removeItem(at: temporaryRoot) }
    try manager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

    let transcriptURL = temporaryRoot.appendingPathComponent("session.jsonl")
    let sentinel = "reader-ac02-public-message"
    let publicLine = #"{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"\#(sentinel)"}]}}"#
    try makeStreamingToolTranscript(
        at: transcriptURL,
        prefixLines: [publicLine],
        lineTemplate: { index in
            let pad = String(repeating: "tool-pad-", count: 8_000)
            return #"{"type":"message","message":{"role":"assistant","content":[{"type":"tool_use","id":"tool-\#(index)","name":"Bash","input":{"command":"echo \#(pad)"}}]}}"#
        },
        tailBytes: 20 * 1_048_576
    )

    let size = try fileSize(transcriptURL)
    let publicEnd = UInt64((publicLine + "\n").utf8.count)
    guard size >= publicEnd + UInt64(20 * 1_048_576),
          size - publicEnd >= UInt64(7 * 1_048_576)
    else {
        throw LargeWindowSelfTestError.failed("ac02 fixture distance is too small")
    }
    guard let reader = TranscriptEventReader.make(at: transcriptURL) else {
        throw LargeWindowSelfTestError.failed("ac02 reader make failed")
    }

    var end: UInt64? = size
    var remaining = TranscriptReadBudget.transcriptEvents.maximumAutomaticBackscanBytes
    var passCount = 0
    var recovered = false
    while remaining > 0, let currentEnd = end, currentEnd > 0 {
        let passBytes = min(
            remaining,
            TranscriptReadBudget.transcriptEvents.maximumBytesPerPass
        )
        let result = try unwrapTranscriptResult(
            reader.readBackwardPass(fromEnd: currentEnd, maximumBytes: passBytes),
            "ac02 backward pass"
        )
        passCount += 1
        recovered = recovered || result.records.contains {
            String(data: $0.data, encoding: .utf8)?.contains(sentinel) == true
        }
        end = result.continuation
        remaining -= passBytes
        if recovered { break }
    }
    guard recovered, passCount > 1 else {
        throw LargeWindowSelfTestError.failed(
            "ac02 continuation did not recover public message"
        )
    }
}

private func runReaderForwardPassStopsAtChunkBoundaryAfterSoftWallTimeSelfTest()
    throws
{
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-reader-ac03-forward-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? manager.removeItem(at: temporaryRoot) }
    try manager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    let transcriptURL = temporaryRoot.appendingPathComponent("tool-only.jsonl")
    try makeStreamingToolTranscript(
        at: transcriptURL,
        lineTemplate: { index in
            let pad = String(repeating: "tool-pad-", count: 8_000)
            return #"{"type":"message","message":{"role":"assistant","content":[{"type":"tool_use","id":"tool-\#(index)","name":"Bash","input":{"command":"echo \#(pad)"}}]}}"#
        },
        tailBytes: 100 * 1_048_576
    )
    guard try fileSize(transcriptURL) >= UInt64(100 * 1_048_576) else {
        throw LargeWindowSelfTestError.failed("ac03 forward fixture too small")
    }
    let budget = TranscriptReadBudget.transcriptEvents
    guard let reader = TranscriptEventReader.make(
        at: transcriptURL,
        budget: budget,
        clock: AdvancingTranscriptClock(step: 60_000_000)
    ) else {
        throw LargeWindowSelfTestError.failed("ac03 forward reader make failed")
    }
    _ = try unwrapTranscriptResult(reader.readForwardPass(), "ac03 forward pass")
    guard reader.diagnostics.rawChunksRead == 1,
          reader.diagnostics.bytesRead == budget.chunkBytes,
          reader.scanHead == UInt64(budget.chunkBytes)
    else {
        throw LargeWindowSelfTestError.failed("ac03 forward soft stop violated")
    }
}

private func runReaderBackwardPassStopsAtChunkBoundaryAfterSoftWallTimeSelfTest()
    throws
{
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-reader-ac03-backward-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? manager.removeItem(at: temporaryRoot) }
    try manager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    let transcriptURL = temporaryRoot.appendingPathComponent("tool-only.jsonl")
    try makeStreamingToolTranscript(
        at: transcriptURL,
        lineTemplate: { index in
            let pad = String(repeating: "tool-pad-", count: 8_000)
            return #"{"type":"message","message":{"role":"assistant","content":[{"type":"tool_use","id":"tool-\#(index)","name":"Bash","input":{"command":"echo \#(pad)"}}]}}"#
        },
        tailBytes: 100 * 1_048_576
    )
    let size = try fileSize(transcriptURL)
    guard size >= UInt64(100 * 1_048_576) else {
        throw LargeWindowSelfTestError.failed("ac03 backward fixture too small")
    }
    let budget = TranscriptReadBudget.transcriptEvents
    guard let reader = TranscriptEventReader.make(
        at: transcriptURL,
        budget: budget,
        clock: AdvancingTranscriptClock(step: 60_000_000)
    ) else {
        throw LargeWindowSelfTestError.failed("ac03 backward reader make failed")
    }
    _ = try unwrapTranscriptResult(
        reader.readBackwardPass(fromEnd: size, maximumBytes: budget.maximumBytesPerPass),
        "ac03 backward pass"
    )
    guard reader.diagnostics.rawChunksRead == 1,
          reader.diagnostics.bytesRead == budget.chunkBytes
    else {
        throw LargeWindowSelfTestError.failed("ac03 backward soft stop violated")
    }
}

private func runReaderBackwardPassCancelsAtChunkBoundarySelfTest() throws {
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-reader-ac14-cancel-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? manager.removeItem(at: temporaryRoot) }
    try manager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    let transcriptURL = temporaryRoot.appendingPathComponent("tool-only.jsonl")
    try makeStreamingToolTranscript(
        at: transcriptURL,
        lineTemplate: { index in
            let pad = String(repeating: "tool-pad-", count: 8_000)
            return #"{"type":"message","message":{"role":"assistant","content":[{"type":"tool_use","id":"tool-\#(index)","name":"Bash","input":{"command":"echo \#(pad)"}}]}}"#
        },
        tailBytes: 100 * 1_048_576
    )
    let size = try fileSize(transcriptURL)
    let budget = TranscriptReadBudget.transcriptEvents
    guard let reader = TranscriptEventReader.make(
        at: transcriptURL,
        budget: budget,
        clock: AdvancingTranscriptClock(step: 0)
    ) else {
        throw LargeWindowSelfTestError.failed("ac14 reader make failed")
    }
    var shouldCancel = false
    reader.postChunkReadHook = {
        shouldCancel = true
    }
    _ = try unwrapTranscriptResult(
        reader.readBackwardPass(
            fromEnd: size,
            maximumBytes: budget.maximumBytesPerPass,
            isCancelled: { shouldCancel }
        ),
        "ac14 backward pass"
    )
    guard reader.diagnostics.rawChunksRead == 1,
          reader.diagnostics.bytesRead == budget.chunkBytes
    else {
        throw LargeWindowSelfTestError.failed("ac14 cancel boundary violated")
    }
}

// MARK: OMP

private func runOMPLargeToolTailRecoverySelfTest() throws {
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-omp-window-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? manager.removeItem(at: temporaryRoot) }
    try manager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

    let sessionID = "01a00e2c-d9a5-7000-a897-cc3f8baf2a75"
    let sentinel = "OMP 七兆字节之前的公开正文必须被恢复"
    let directory = "/private/tmp/omp-large-project"
    let headFiller = String(repeating: "head-", count: 30_000) // ~150 KB beyond prefix
    let lines: [String] = [
        #"{"type":"session","timestamp":"2026-08-17T05:14:51.173Z","cwd":"\#(directory)"}"#,
        #"{"type":"message","timestamp":"2026-08-17T05:14:52.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"\#(headFiller)"}]}}"#,
        // 公开正文：在 prefix(64 KiB)+head 填充之外、距 EOF >= 7 MiB。
        #"{"type":"message","timestamp":"2026-08-17T05:15:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"\#(sentinel)"}]}}"#,
    ]
    let toolTail = makeToolRecords(
        lineTemplate: { chunk in
            #"{"type":"message","timestamp":"2026-08-17T05:16:00.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"\#(chunk)"}]}}"#
        },
        targetBytes: 20 * 1_048_576
    )
    let body = (lines + toolTail).map { $0 + "\n" }.joined()
    let data = Data(body.utf8)
    let publicEnd = lines.map { $0.utf8.count + 1 }.reduce(0, +)
    guard data.count >= publicEnd + 20 * 1_048_576,
          data.count - publicEnd >= 7 * 1_048_576
    else {
        throw LargeWindowSelfTestError.failed("OMP fixture distance is too small")
    }
    let transcriptURL = temporaryRoot.appendingPathComponent(
        "2026-08-17T05-14-51-173Z_\(sessionID).jsonl",
        isDirectory: false
    )
    try data.write(to: transcriptURL)

    let indexRoot = temporaryRoot.appendingPathComponent(
        "Transcript Index",
        isDirectory: true
    )
    var content: OMPLocalSessionContent?
    var remaining = TranscriptReadBudget.transcriptEvents
        .maximumAutomaticBackscanBytes
    while remaining > 0 {
        content = OMPLocalSession.content(
            sessionID: sessionID,
            sessionsRoot: temporaryRoot,
            fileManager: manager,
            indexRootDirectory: indexRoot
        )
        if content?.events.contains(where: { $0.text.contains(sentinel) }) == true {
            break
        }
        remaining -= TranscriptReadBudget.transcriptEvents.maximumBytesPerPass
    }
    let recovered = content?.events.contains(where: { $0.text.contains(sentinel) }) == true
    let recoveredDirectory = content?.workingDirectory == directory
    let toolLeaked = content?.events.contains(where: {
        $0.text.contains("tool-pad") || $0.text.contains("ExecCommand")
    }) == true

    guard recovered, recoveredDirectory, !toolLeaked else {
        throw LargeWindowSelfTestError.failed(
            "OMP did not recover public message or leaked tool text"
        )
    }
}

private func runOMPRefreshBudgetAndCheckpointSelfTest() throws {
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-omp-budget-\(UUID().uuidString)",
        isDirectory: true
    )
    defer {
        OMPLocalSession.resetInMemoryStateForTesting()
        try? manager.removeItem(at: temporaryRoot)
    }
    try manager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

    let sessionID = "01a00e2c-d9a5-7000-a897-cc3f8baf2a76"
    let transcriptURL = temporaryRoot.appendingPathComponent(
        "2026-08-17T05-14-51-173Z_\(sessionID).jsonl",
        isDirectory: false
    )
    let initialLines = [
        #"{"type":"session","timestamp":"2026-08-17T05:14:51.173Z","cwd":"/private/tmp/omp-budget"}"#,
        #"{"type":"message","timestamp":"2026-08-17T05:14:52.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"old-private"}]}}"#,
    ]
    try Data(initialLines.map { $0 + "\n" }.joined().utf8).write(to: transcriptURL)
    guard let reader = TranscriptEventReader.make(
        at: transcriptURL,
        fileManager: manager
    ) else {
        throw LargeWindowSelfTestError.failed("OMP budget reader make failed")
    }
    let initialSize = (try manager.attributesOfItem(
        atPath: transcriptURL.path
    )[.size] as? NSNumber)?.uint64Value ?? 0
    let indexRoot = temporaryRoot.appendingPathComponent(
        "Transcript Index",
        isDirectory: true
    )
    let indexStore = TranscriptIndexStore(
        rootDirectory: indexRoot,
        fileManager: manager
    )
    let checkpoint = TranscriptIndexStore.Checkpoint(
        schemaVersion: TranscriptIndexStore.schemaVersion,
        agentID: .omp,
        sessionKeyDigest: sessionID,
        sourceIdentity: reader.identity,
        observedSize: initialSize,
        observedMTime: 0,
        committedOffset: initialSize,
        backscanContinuationOffset: initialSize,
        publicMessageDescriptors: [],
        currentToolDescriptor: nil,
        terminalDescriptor: nil,
        metadataDescriptor: nil,
        oversizedRecords: 0
    )
    try indexStore.flush(checkpoint, agentID: .omp, sessionKey: sessionID)

    let appended = "OMP forward 增量必须优先于 continuation 回扫"
    let handle = try FileHandle(forWritingTo: transcriptURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(
        (#"{"type":"message","timestamp":"2026-08-17T05:15:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"\#(appended)"}]}}"# + "\n").utf8
    ))
    try handle.close()

    OMPLocalSession.resetInMemoryStateForTesting()
    let content = OMPLocalSession.content(
        sessionID: sessionID,
        sessionsRoot: temporaryRoot,
        fileManager: manager,
        indexRootDirectory: indexRoot
    )
    guard content?.events.contains(where: { $0.text.contains(appended) }) == true
    else {
        throw LargeWindowSelfTestError.failed("OMP budget forward append was not recovered")
    }
    let loaded = indexStore.load(agentID: .omp, sessionKey: sessionID)
    guard loaded?.backscanContinuationOffset == initialSize else {
        throw LargeWindowSelfTestError.failed(
            "OMP forward refresh also advanced backscan continuation"
        )
    }
}

private func runOMPBackscanLifecycleCapSelfTest() throws {
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-omp-lifecycle-\(UUID().uuidString)",
        isDirectory: true
    )
    defer {
        OMPLocalSession.resetInMemoryStateForTesting()
        try? manager.removeItem(at: temporaryRoot)
    }
    try manager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

    let sessionID = "01a00e2c-d9a5-7000-a897-cc3f8baf2a77"
    let transcriptURL = temporaryRoot.appendingPathComponent(
        "2026-08-17T05-14-51-173Z_\(sessionID).jsonl",
        isDirectory: false
    )
    let sessionLine =
        #"{"type":"session","timestamp":"2026-08-17T05:14:51.173Z","cwd":"/private/tmp/omp-lifecycle"}"#
    let toolTail = makeToolRecords(
        lineTemplate: { chunk in
            #"{"type":"message","timestamp":"2026-08-17T05:16:00.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"\#(chunk)"}]}}"#
        },
        targetBytes: 80 * 1_048_576
    )
    try Data(([sessionLine] + toolTail).map { $0 + "\n" }.joined().utf8)
        .write(to: transcriptURL)

    let indexRoot = temporaryRoot.appendingPathComponent(
        "Transcript Index",
        isDirectory: true
    )
    let indexStore = TranscriptIndexStore(
        rootDirectory: indexRoot,
        fileManager: manager
    )

    OMPLocalSession.resetInMemoryStateForTesting()
    let callsToHitLifecycleCap =
        TranscriptReadBudget.transcriptEvents.maximumAutomaticBackscanBytes
        / TranscriptReadBudget.transcriptEvents.maximumBytesPerPass + 1
    for _ in 0..<callsToHitLifecycleCap {
        _ = OMPLocalSession.content(
            sessionID: sessionID,
            sessionsRoot: temporaryRoot,
            fileManager: manager,
            indexRootDirectory: indexRoot
        )
    }
    guard let cappedContinuation = indexStore.load(
        agentID: .omp,
        sessionKey: sessionID
    )?.backscanContinuationOffset else {
        throw LargeWindowSelfTestError.failed("OMP lifecycle cap did not persist continuation")
    }

    _ = OMPLocalSession.content(
        sessionID: sessionID,
        sessionsRoot: temporaryRoot,
        fileManager: manager,
        indexRootDirectory: indexRoot
    )
    let sameLifecycleContinuation = indexStore.load(
        agentID: .omp,
        sessionKey: sessionID
    )?.backscanContinuationOffset
    guard sameLifecycleContinuation == cappedContinuation else {
        throw LargeWindowSelfTestError.failed(
            "OMP lifecycle cap did not stop same-lifecycle backscan"
        )
    }

    OMPLocalSession.resetInMemoryStateForTesting()
    _ = OMPLocalSession.content(
        sessionID: sessionID,
        sessionsRoot: temporaryRoot,
        fileManager: manager,
        indexRootDirectory: indexRoot
    )
    let resumedContinuation = indexStore.load(
        agentID: .omp,
        sessionKey: sessionID
    )?.backscanContinuationOffset
    guard resumedContinuation == nil
            || resumedContinuation! < cappedContinuation else {
        throw LargeWindowSelfTestError.failed(
            "OMP lifecycle restart did not resume from persisted continuation"
        )
    }
}

private func runOMPMissingSourceDeletesSidecarSelfTest() throws {
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-omp-missing-source-\(UUID().uuidString)",
        isDirectory: true
    )
    defer {
        OMPLocalSession.resetInMemoryStateForTesting()
        try? manager.removeItem(at: temporaryRoot)
    }
    try manager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

    let sessionID = "01a00e2c-d9a5-7000-a897-cc3f8baf2a78"
    let transcriptURL = temporaryRoot.appendingPathComponent(
        "2026-08-17T05-14-51-173Z_\(sessionID).jsonl",
        isDirectory: false
    )
    let line =
        #"{"type":"message","timestamp":"2026-08-17T05:15:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"sidecar source"}]}}"# + "\n"
    try Data(line.utf8).write(to: transcriptURL)
    guard let reader = TranscriptEventReader.make(
        at: transcriptURL,
        fileManager: manager
    ) else {
        throw LargeWindowSelfTestError.failed("OMP missing-source reader make failed")
    }
    let size = try fileSize(transcriptURL)
    let indexRoot = temporaryRoot.appendingPathComponent(
        "Transcript Index",
        isDirectory: true
    )
    let indexStore = TranscriptIndexStore(
        rootDirectory: indexRoot,
        fileManager: manager
    )
    let descriptor = TranscriptRecordLocation(
        startOffset: 0,
        byteCount: UInt32(line.utf8.count),
        sourceOrder: 0,
        eventClass: .publicMessage,
        occurredAt: nil
    )
    let checkpoint = TranscriptIndexStore.Checkpoint(
        schemaVersion: TranscriptIndexStore.schemaVersion,
        agentID: .omp,
        sessionKeyDigest: sessionID,
        sourceIdentity: reader.identity,
        observedSize: size,
        observedMTime: 0,
        committedOffset: size,
        backscanContinuationOffset: nil,
        publicMessageDescriptors: [descriptor],
        currentToolDescriptor: nil,
        terminalDescriptor: nil,
        metadataDescriptor: nil,
        oversizedRecords: 0
    )
    try indexStore.flush(checkpoint, agentID: .omp, sessionKey: sessionID)
    guard indexStore.load(agentID: .omp, sessionKey: sessionID) != nil else {
        throw LargeWindowSelfTestError.failed("OMP missing-source fixture sidecar missing")
    }

    try manager.removeItem(at: transcriptURL)
    OMPLocalSession.resetInMemoryStateForTesting()
    let content = OMPLocalSession.content(
        sessionID: sessionID,
        sessionsRoot: temporaryRoot,
        fileManager: manager,
        indexRootDirectory: indexRoot
    )
    guard content == nil,
          indexStore.load(agentID: .omp, sessionKey: sessionID) == nil
    else {
        throw LargeWindowSelfTestError.failed(
            "OMP missing source did not delete temp sidecar"
        )
    }
}

private func runOMPDescriptorRestoreBudgetSelfTest() throws {
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-omp-descriptor-budget-\(UUID().uuidString)",
        isDirectory: true
    )
    defer {
        OMPLocalSession.resetInMemoryStateForTesting()
        try? manager.removeItem(at: temporaryRoot)
    }
    try manager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

    let sessionID = "01a00e2c-d9a5-7000-a897-cc3f8baf2a79"
    let transcriptURL = temporaryRoot.appendingPathComponent(
        "2026-08-17T05-14-51-173Z_\(sessionID).jsonl",
        isDirectory: false
    )
    var offset: UInt64 = 0
    var lines: [String] = []
    var descriptors: [TranscriptRecordLocation] = []
    for index in 0..<10 {
        let marker = "descriptor-budget-\(index)"
        let padding = String(repeating: "x", count: 1_020_000)
        let line =
            #"{"type":"message","timestamp":"2026-08-17T05:15:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"\#(marker) \#(padding)"}]}}"#
        lines.append(line)
        let byteCount = UInt32((line + "\n").utf8.count)
        descriptors.append(TranscriptRecordLocation(
            startOffset: offset,
            byteCount: byteCount,
            sourceOrder: UInt64(index),
            eventClass: .publicMessage,
            occurredAt: nil
        ))
        offset += UInt64(byteCount)
    }
    try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: transcriptURL)
    guard let reader = TranscriptEventReader.make(
        at: transcriptURL,
        fileManager: manager
    ) else {
        throw LargeWindowSelfTestError.failed("OMP descriptor reader make failed")
    }
    let indexRoot = temporaryRoot.appendingPathComponent(
        "Transcript Index",
        isDirectory: true
    )
    let indexStore = TranscriptIndexStore(
        rootDirectory: indexRoot,
        fileManager: manager
    )
    let checkpoint = TranscriptIndexStore.Checkpoint(
        schemaVersion: TranscriptIndexStore.schemaVersion,
        agentID: .omp,
        sessionKeyDigest: sessionID,
        sourceIdentity: reader.identity,
        observedSize: offset,
        observedMTime: 0,
        committedOffset: offset,
        backscanContinuationOffset: nil,
        publicMessageDescriptors: descriptors,
        currentToolDescriptor: nil,
        terminalDescriptor: nil,
        metadataDescriptor: nil,
        oversizedRecords: 0
    )
    try indexStore.flush(checkpoint, agentID: .omp, sessionKey: sessionID)

    OMPLocalSession.resetInMemoryStateForTesting()
    let content = OMPLocalSession.content(
        sessionID: sessionID,
        sessionsRoot: temporaryRoot,
        fileManager: manager,
        indexRootDirectory: indexRoot
    )
    let texts = content?.events.map(\.text) ?? []
    guard texts.contains(where: { $0.contains("descriptor-budget-9") }),
          !texts.contains(where: { $0.contains("descriptor-budget-0") })
    else {
        throw LargeWindowSelfTestError.failed(
            "OMP descriptor restore did not prioritize latest ranges"
        )
    }
    let visibleOrders = texts.compactMap { text -> Int? in
        guard let range = text.range(of: "descriptor-budget-") else { return nil }
        let suffix = text[range.upperBound...].prefix { $0.isNumber }
        return Int(suffix)
    }
    // Descriptor ranges are restored into provider state chronologically, then
    // AgentActivityProjection applies the user-facing AC-05 contract: newest
    // first, with sourceOrder as the stable tie-breaker for equal timestamps.
    guard visibleOrders == visibleOrders.sorted(by: >) else {
        throw LargeWindowSelfTestError.failed(
            "OMP descriptor restore did not project newest-first"
        )
    }
}

// MARK: Cursor

private func runCursorLargeToolTailRecoverySelfTest() throws {
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-cursor-window-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? manager.removeItem(at: temporaryRoot) }
    try manager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

    let sessionID = "0123456789abcdef"
    let sentinel = "Cursor 大尾部后的公开正文必须可达"
    let userLine =
        #"{"timestamp":"2026-08-17T05:00:00.000Z","type":"user","message":{"role":"user","content":"帮我检查项目"}}"#
    let sentinelLine =
        #"{"timestamp":"2026-08-17T05:01:00.000Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(sentinel)"}]}}"#
    let toolTail = makeToolRecords(
        lineTemplate: { chunk in
            #"{"timestamp":"2026-08-17T05:02:00.000Z","type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"echo \#(chunk)"}}]}}"#
        },
        targetBytes: 20 * 1_048_576
    )
    let body = ([userLine, sentinelLine] + toolTail).map { $0 + "\n" }.joined()
    let data = Data(body.utf8)
    let publicEnd = (userLine + "\n" + sentinelLine + "\n").utf8.count
    guard data.count >= publicEnd + 20 * 1_048_576,
          data.count - publicEnd >= 7 * 1_048_576
    else {
        throw LargeWindowSelfTestError.failed(
            "Cursor fixture distance is too small"
        )
    }

    let projectRoot = temporaryRoot.appendingPathComponent("tmp-cursor-large-project")
    let transcriptRoot = projectRoot.appendingPathComponent("agent-transcripts")
    try manager.createDirectory(at: transcriptRoot, withIntermediateDirectories: true)
    let transcriptURL = transcriptRoot.appendingPathComponent(
        "\(sessionID).jsonl",
        isDirectory: false
    )
    try data.write(to: transcriptURL)

    var content: CursorLocalSessionContent?
    var remaining = TranscriptReadBudget.transcriptEvents
        .maximumAutomaticBackscanBytes
    while remaining > 0 {
        content = CursorLocalWorkspace.sessionContent(
            sessionID: sessionID,
            projectsRoot: temporaryRoot,
            fileManager: manager,
            conversationMetadata: { _ in nil }
        )
        if content?.fragments.contains(where: { $0.text.contains(sentinel) }) == true {
            break
        }
        remaining -= TranscriptReadBudget.transcriptEvents.maximumBytesPerPass
    }
    let recovered = content?.fragments.contains(where: { $0.text.contains(sentinel) }) == true
    let toolLeaked = content?.fragments.contains(where: {
        $0.text.contains("tool-pad") || $0.text.contains("Bash")
    }) == true

    guard recovered, !toolLeaked else {
        throw LargeWindowSelfTestError.failed(
            "Cursor did not recover public message or leaked tool text"
        )
    }
}

// MARK: Codex

private func runCodexLargeToolTailRecoverySelfTest() throws {
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-codex-window-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? manager.removeItem(at: temporaryRoot) }
    try manager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

    let sessionID = "11111111-2222-3333-4444-555555555555"
    let sentinel = "Codex 七兆字节之前的公开正文必须被恢复"
    let lines: [String] = [
        #"{"type":"session_meta","payload":{"cwd":"/private/tmp/codex-large-project","thread_source":"root"}}"#,
        #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
        #"{"timestamp":"2026-08-17T05:15:00.000Z","type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"\#(sentinel)"}}"#,
    ]
    let toolTail = makeToolRecords(
        lineTemplate: { chunk in
            #"{"timestamp":"2026-08-17T05:16:00.000Z","type":"event_msg","payload":{"type":"agent_message","phase":"reasoning","message":"\#(chunk)"}}"#
        },
        targetBytes: 20 * 1_048_576
    )
    let body = (lines + toolTail).map { $0 + "\n" }.joined()
    let data = Data(body.utf8)
    let publicEnd = lines.map { $0.utf8.count + 1 }.reduce(0, +)
    guard data.count >= publicEnd + 20 * 1_048_576,
          data.count - publicEnd >= 7 * 1_048_576
    else {
        throw LargeWindowSelfTestError.failed("Codex fixture distance is too small")
    }

    let sessionsDir = temporaryRoot.appendingPathComponent("sessions", isDirectory: true)
    try manager.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    let transcriptURL = sessionsDir.appendingPathComponent(
        "rollout-\(sessionID).jsonl",
        isDirectory: false
    )
    try data.write(to: transcriptURL)

    let original = ProcessInfo.processInfo.environment["CODEX_HOME"]
    setenv("CODEX_HOME", temporaryRoot.path, 1)
    defer {
        if let original {
            setenv("CODEX_HOME", original, 1)
        } else {
            unsetenv("CODEX_HOME")
        }
    }
    let reader = CodexTaskProgressReader(
        indexRootDirectory: temporaryRoot.appendingPathComponent(
            "transcript-index", isDirectory: true
        )
    )
    var snapshot = reader.read()
    var remaining = TranscriptReadBudget.transcriptEvents
        .maximumAutomaticBackscanBytes
    while remaining > 0,
          snapshot.items.first?.events.contains(where: {
              $0.text.contains(sentinel)
          }) != true {
        remaining -= TranscriptReadBudget.transcriptEvents.maximumBytesPerPass
        snapshot = reader.read()
    }
    let texts = snapshot.items.first?.events.map { $0.text } ?? []
    let recovered = texts.contains(where: { $0.contains(sentinel) })
    let toolLeaked = texts.contains(where: {
        $0.contains("tool-pad") || $0.contains("ExecCommand")
    })

    guard recovered, !toolLeaked else {
        throw LargeWindowSelfTestError.failed(
            "Codex did not recover public message or leaked tool text"
        )
    }
}

// MARK: Claude Code

private func runClaudeLargeToolTailRecoverySelfTest() throws {
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-claude-window-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? manager.removeItem(at: temporaryRoot) }
    try manager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

    let sessionID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    let sentinel = "Claude 七兆字节之前的公开正文必须被保留"
    let userLine =
        #"{"type":"user","message":{"role":"user","content":"帮我检查"}}"#
    let sentinelLine =
        #"{"type":"assistant","timestamp":"2026-08-17T05:01:00.000Z","message":{"content":[{"type":"text","text":"\#(sentinel)"}]}}"#
    let chunk = String(repeating: "tool-pad-", count: 8_000)
    let single = #"{"type":"assistant","timestamp":"2026-08-17T05:30:00.000Z","message":{"content":[{"type":"tool_use","id":"call-0","name":"Bash","input":{"command":"echo \#(chunk)"}}]}}"# + "\n"
    let singleSize = single.utf8.count
    let count = max(1, (20 * 1_048_576) / singleSize) + 2
    let tailLines = (0..<count).map { index in
        #"{"type":"assistant","timestamp":"2026-08-17T05:30:00.000Z","message":{"content":[{"type":"tool_use","id":"call-\#(index)","name":"Bash","input":{"command":"echo \#(chunk)"}}]}}"#
    }
    let body = ([userLine, sentinelLine] + tailLines).map { $0 + "\n" }.joined()
    let data = Data(body.utf8)
    let publicEnd = (userLine + "\n" + sentinelLine + "\n").utf8.count
    guard data.count >= publicEnd + 20 * 1_048_576,
          data.count - publicEnd >= 7 * 1_048_576
    else {
        throw LargeWindowSelfTestError.failed("Claude fixture distance is too small")
    }

    let projects = temporaryRoot.appendingPathComponent(
        ".claude/projects",
        isDirectory: true
    )
    try manager.createDirectory(at: projects, withIntermediateDirectories: true)
    let transcriptURL = projects.appendingPathComponent(
        "\(sessionID).jsonl",
        isDirectory: false
    )
    try data.write(to: transcriptURL)

    let reader = ClaudeTaskProgressReader(
        homeDirectory: temporaryRoot,
        indexRootDirectory: temporaryRoot.appendingPathComponent(
            "transcript-index", isDirectory: true
        ),
        environment: [:],
        claudeExecutable: { nil },
        now: { Date() }
    )
    var snapshot = reader.read()
    var remaining = TranscriptReadBudget.transcriptEvents
        .maximumAutomaticBackscanBytes
    while remaining > 0,
          snapshot.items.first?.events.contains(where: {
              $0.text.contains(sentinel)
          }) != true {
        remaining -= TranscriptReadBudget.transcriptEvents.maximumBytesPerPass
        snapshot = reader.read()
    }
    let texts = snapshot.items.first?.events.map { $0.text } ?? []
    let recovered = texts.contains(where: { $0.contains(sentinel) })
    let toolLeaked = texts.contains(where: {
        $0.contains("tool-pad") || $0.contains("Bash")
    })

    guard recovered, !toolLeaked else {
        throw LargeWindowSelfTestError.failed(
            "Claude did not recover public message or leaked tool text"
        )
    }
}

private enum LargeWindowSelfTestError: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}
