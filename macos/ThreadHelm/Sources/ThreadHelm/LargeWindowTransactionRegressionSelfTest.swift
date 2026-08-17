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
//  4 MiB record cap，只用多条小 tool record 累计 7–8 MiB 尾部；sentinel 落
//  在 64 MiB 自动回扫预算内，修复后单次读取可恢复。
//

import Foundation

func runLargeTranscriptWindowRegressionSelfTest() -> Never {
    var failures: [String] = []
    runProviderCase("omp", failures: &failures) {
        try runOMPLargeToolTailRecoverySelfTest()
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
            "large-window-regression: 四个来源均满足正向契约（共享 reader 已落地或本就不依赖固定尾读）。\n",
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
        targetBytes: 7 * 1_048_576
    )
    let body = (lines + toolTail).map { $0 + "\n" }.joined()
    let data = Data(body.utf8)
    guard data.count >= 7 * 1_048_576 else {
        throw LargeWindowSelfTestError.failed("OMP fixture must have >= 7 MiB to EOF")
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
            "OMP 固定窗口读取未恢复哨兵；events: \(content?.events.map { $0.text } ?? [])"
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
            "Cursor 固定 1 MiB 尾读未恢复哨兵；fragments: \(content?.fragments.map { $0.text } ?? [])"
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
        targetBytes: 7 * 1_048_576
    )
    let body = (lines + toolTail).map { $0 + "\n" }.joined()
    let data = Data(body.utf8)
    guard data.count >= 7 * 1_048_576 else {
        throw LargeWindowSelfTestError.failed("Codex fixture must have >= 7 MiB to EOF")
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
    let reader = CodexTaskProgressReader()
    let snapshot = reader.read()
    let texts = snapshot.items.first?.events.map { $0.text } ?? []
    let recovered = texts.contains(where: { $0.contains(sentinel) })
    let toolLeaked = texts.contains(where: {
        $0.contains("tool-pad") || $0.contains("ExecCommand")
    })

    guard recovered, !toolLeaked else {
        throw LargeWindowSelfTestError.failed(
            "Codex 固定 1 MiB 尾读未恢复 \(data.count) 字节样本哨兵；events: \(texts)"
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
    let count = max(1, (7 * 1_048_576) / singleSize) + 2
    let tailLines = (0..<count).map { index in
        #"{"type":"assistant","timestamp":"2026-08-17T05:30:00.000Z","message":{"content":[{"type":"tool_use","id":"call-\#(index)","name":"Bash","input":{"command":"echo \#(chunk)"}}]}}"#
    }
    let body = ([userLine, sentinelLine] + tailLines).map { $0 + "\n" }.joined()
    let data = Data(body.utf8)
    guard data.count >= 7 * 1_048_576 else {
        throw LargeWindowSelfTestError.failed("Claude fixture must have >= 7 MiB to EOF")
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
        environment: [:],
        claudeExecutable: { nil },
        now: { Date() }
    )
    let snapshot = reader.read()
    let texts = snapshot.items.first?.events.map { $0.text } ?? []
    let recovered = texts.contains(where: { $0.contains(sentinel) })
    let toolLeaked = texts.contains(where: {
        $0.contains("tool-pad") || $0.contains("Bash")
    })

    guard recovered, !toolLeaked else {
        throw LargeWindowSelfTestError.failed(
            "Claude 固定 1 MiB 尾读未恢复 7 MiB 样本哨兵；events: \(texts)"
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