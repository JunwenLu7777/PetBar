//
//  LargeTranscriptWindowRegressionSelfTest.swift
//  ThreadHelm
//
//  模块职责：Phase 0 红灯证据与逆向 Green 回归。在四种 transcript 的大尾部
//  样本上断言正向契约——“最近公开消息距 EOF 至少 7 MiB 且其后只有 tool 记录时，
//  该正文必须被恢复，纯 tool 尾部不得进入公开正文”。当前的固定窗口读取
//  （OMP prefix+tail、Cursor 固定 1 MiB 尾读）应在此用例上显示红灯
//  （断言失败、进程非零退出）；共享 reader/索引落地后转为绿灯（退出 0）。
//  断言正向契约，绝不把“正文未恢复”固化成通过断言。
//
//  fixture 约束（与共享 reader 预算对齐）：所有单条 tool 记录必须远小于
//  4 MiB record cap，因此只用多条小 tool record 累计成 7–8 MiB 尾部，
//  绝不拼单条 >4 MiB 的大行；sentinel 落在 64 MiB 自动回扫预算内，
//  修复后单次 content() 可恢复，无需跨 App lifecycle continuation。
//

import Foundation

func runLargeTranscriptWindowRegressionSelfTest() -> Never {
    do {
        try runOMPLargeToolTailRecoverySelfTest()
        try runCursorLargeToolTailRecoverySelfTest()
    } catch {
        fputs("large-window-regression: \(error)\n", stderr)
        exit(1)
    }
    exit(0)
}

/// 生成若干条重复的 tool 记录，累计约 targetBytes 字节；单条固定约 8 KiB，
/// 远低于 4 MiB record cap（因此耗时只决定条数，不触碰 cap）。
private func makeToolRecords(
    lineTemplate: (String) -> String,
    targetBytes: Int
) -> [String] {
    let smallChunk = String(repeating: "tool-pad-", count: 8_000) // ~72 KB
    let single = lineTemplate(smallChunk) + "\n"
    let singleSize = single.utf8.count
    guard singleSize > 0, singleSize < 4 * 1_048_576 else { return [] }
    let count = max(1, targetBytes / singleSize)
    return (0..<count).map { index in
        // 每条加一个可忽略小后缀让记录互不相同，避免整行级文本去重误合并。
        lineTemplate(smallChunk + "-\(index)")
    }
}

private func runOMPLargeToolTailRecoverySelfTest() throws {
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-omp-large-window-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? manager.removeItem(at: temporaryRoot) }
    try manager.createDirectory(
        at: temporaryRoot,
        withIntermediateDirectories: true
    )
    let sessionID = "01a00e2c-d9a5-7000-a897-cc3f8baf2a75"




    let sentinel = "七兆字节之前的公开正文必须被恢复"
    let directory = "/private/tmp/omp-large-project"
    // 头部先放足量 thinking 记录，把 prefix 窗口(64 KiB)之外的内容锁定。
    let headFiller = String(repeating: "head-", count: 30_000) // ~150 KB
    let lines: [String] = [
        #"{"type":"session","timestamp":"2026-08-17T05:14:51.173Z","cwd":"\#(directory)"}"#,
        #"{"type":"message","timestamp":"2026-08-17T05:14:52.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"\#(headFiller)"}]}}"#,
        // sentinel 公开正文：距 EOF 至少 7 MiB，前面有 >200 KiB 填充保证在
        // prefix 之外。
        #"{"type":"message","timestamp":"2026-08-17T05:15:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"\#(sentinel)"}]}}"#,
    ]
    let toolTail = makeToolRecords(
        lineTemplate: { chunk in
            #"{"type":"message","timestamp":"2026-08-17T05:16:00.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"\#(chunk)"}]}}"#
        },
        targetBytes: 7 * 1_048_576
    )
    let body = (lines + toolTail).map { $0 + "\n" }.joined()
    let data = Data(body.utf8)
    guard data.count >= 7 * 1_048_576 else {
        throw LargeWindowSelfTestError.failed(
            "OMP fixture must have >= 7 MiB between sentinel tail and EOF"
        )
    }
    let transcriptURL = temporaryRoot.appendingPathComponent(
        "2026-08-17T05-14-51-173Z_\(sessionID).jsonl",
        isDirectory: false
    )
    try data.write(to: transcriptURL)

    let content = OMPLocalSession.content(
        sessionID: sessionID,
        sessionsRoot: temporaryRoot,
        fileManager: manager
    )
    let recovered = content?.events.contains(where: { $0.text.contains(sentinel) }) == true
    let recoveredDirectory = content?.workingDirectory == directory
    let toolLeaked = content?.events.contains(where: {
        $0.text.contains("tool-pad") || $0.text.contains("ExecCommand")
    }) == true

    guard recovered, recoveredDirectory, !toolLeaked else {
        throw LargeWindowSelfTestError.failed(
            "OMP 固定窗口读取未恢复 \(data.count / (1_048_576)) MiB 样本中的哨兵；"
                + "events: \(content?.events.map { $0.text } ?? [])"
        )
    }
}

private func runCursorLargeToolTailRecoverySelfTest() throws {
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-cursor-large-window-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? manager.removeItem(at: temporaryRoot) }

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
        targetBytes: 7 * 1_048_576
    )
    let body = ([userLine, sentinelLine] + toolTail).map { $0 + "\n" }.joined()
    let data = Data(body.utf8)
    guard data.count > CursorLocalWorkspace.maximumTailBytes,
          data.count >= 7 * 1_048_576
    else {
        throw LargeWindowSelfTestError.failed(
            "Cursor fixture must exceed fixed 1 MiB tail and have >= 7 MiB to EOF"
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

    let content = CursorLocalWorkspace.sessionContent(
        sessionID: sessionID,
        projectsRoot: temporaryRoot,
        fileManager: manager,
        conversationMetadata: { _ in nil }
    )
    let recovered = content?.fragments.contains(where: { $0.text.contains(sentinel) }) == true
    let toolLeaked = content?.fragments.contains(where: {
        $0.text.contains("tool-pad") || $0.text.contains("Bash")
    }) == true

    guard recovered, !toolLeaked else {
        throw LargeWindowSelfTestError.failed(
            "Cursor 固定 1 MiB 尾读未恢复大文件远端正文；"
                + "fragments: \(content?.fragments.map(\.text) ?? [])"
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