//
//  RealTranscriptReadonlySelfTest.swift
//  ThreadHelm
//
//  本机专用验收：对四种真实 vendor transcript 运行生产读取路径，并证明
//  size / mtime / SHA-256 前后不变。输出只含聚合计数，不打印路径、正文、
//  标题、session ID 或 digest。该入口不属于 release 的可移植 fixture 门禁。
//

import CryptoKit
import Foundation

private enum RealTranscriptReadonlySelfTestError: Error {
    case providerUnavailable(String)
    case providerReadFailed(String)
    case sourceChanged(String)
}

private struct RealTranscriptCandidate {
    let provider: String
    let url: URL
    let sessionID: String?
}

private struct RealTranscriptFingerprint: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let sha256: String
}

func runRealTranscriptReadonlySelfTest() -> Never {
    let group = DispatchGroup()
    let resultLock = NSLock()
    var result: Result<Int, Error>?

    group.enter()
    DispatchQueue.global(qos: .utility).async {
        let computed: Result<Int, Error>
        do {
            computed = .success(try performRealTranscriptReadonlySelfTest())
        } catch {
            computed = .failure(error)
        }
        resultLock.lock()
        result = computed
        resultLock.unlock()
        group.leave()
    }
    group.wait()

    resultLock.lock()
    let completed = result
    resultLock.unlock()
    switch completed {
    case .success(let providerCount):
        fputs(
            "real-transcript-readonly-self-test: providers=\(providerCount) unchanged=\(providerCount) metadata=size,mtime,sha256\n",
            stderr
        )
        exit(0)
    case .failure(let error):
        let label: String
        switch error {
        case RealTranscriptReadonlySelfTestError.providerUnavailable(let provider):
            label = "provider-unavailable:\(provider)"
        case RealTranscriptReadonlySelfTestError.providerReadFailed(let provider):
            label = "provider-read-failed:\(provider)"
        case RealTranscriptReadonlySelfTestError.sourceChanged(let provider):
            label = "source-changed:\(provider)"
        default:
            label = "unexpected"
        }
        fputs("real-transcript-readonly-self-test FAILED: \(label)\n", stderr)
        exit(1)
    case .none:
        fputs("real-transcript-readonly-self-test FAILED: no-result\n", stderr)
        exit(1)
    }
}

private func performRealTranscriptReadonlySelfTest() throws -> Int {
    let manager = FileManager.default
    let home = manager.homeDirectoryForCurrentUser
    let indexRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-real-transcript-index-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? manager.removeItem(at: indexRoot) }
    let candidates = try realTranscriptCandidates(home: home, fileManager: manager)
    let before = try Dictionary(uniqueKeysWithValues: candidates.map {
        ($0.provider, try fingerprintRealTranscript(at: $0.url))
    })

    // Codex/Claude 使用生产 collection reader；关闭 Claude CLI 探针，只验证
    // 本地 transcript 路径，避免把网络或额外进程混进只读验收。必须证明所选
    // candidate 真正进入 provider 输出，不能只调用后丢弃 collection。
    guard let codex = candidates.first(where: { $0.provider == "codex" }),
          let codexSessionID = codex.sessionID,
          let codexFingerprint = before["codex"]
    else {
        throw RealTranscriptReadonlySelfTestError.providerReadFailed("codex")
    }
    let rolloutEnvironmentKey = "THREADHELM_TASK_ROLLOUT_FILE"
    let codexStateEnvironmentKey = "THREADHELM_CODEX_STATE_FILE"
    let previousRollout = getenv(rolloutEnvironmentKey).map {
        String(cString: $0)
    }
    let previousCodexState = getenv(codexStateEnvironmentKey).map {
        String(cString: $0)
    }
    setenv(rolloutEnvironmentKey, codex.url.path, 1)
    // 本验收证明 transcript 能进入 production collection；用户当前的
    // 已读状态不属于 transcript 读取合同，不能让同一真实文件时绿时红。
    // 指向不存在的隔离文件会让 production reader 使用其既有 fail-open
    // 路径，同时仍保留候选、解析、投影和可见性判断。
    setenv(
        codexStateEnvironmentKey,
        indexRoot.appendingPathComponent("absent-codex-state.json").path,
        1
    )
    defer {
        if let previousRollout {
            setenv(rolloutEnvironmentKey, previousRollout, 1)
        } else {
            unsetenv(rolloutEnvironmentKey)
        }
        if let previousCodexState {
            setenv(codexStateEnvironmentKey, previousCodexState, 1)
        } else {
            unsetenv(codexStateEnvironmentKey)
        }
    }
    let codexNow = fingerprintDate(codexFingerprint)
    let codexCollection = CodexTaskProgressReader(
        indexRootDirectory: indexRoot,
        now: { codexNow }
    ).readCollection()
    guard codexCollection.items.contains(where: {
        $0.threadID?.lowercased() == codexSessionID.lowercased()
    }) else {
        throw RealTranscriptReadonlySelfTestError.providerReadFailed("codex")
    }

    guard let claude = candidates.first(where: { $0.provider == "claude" }),
          let claudeSessionID = claude.sessionID,
          let claudeFingerprint = before["claude"]
    else {
        throw RealTranscriptReadonlySelfTestError.providerReadFailed("claude")
    }
    let claudeNow = fingerprintDate(claudeFingerprint)
    let claudeCollection = ClaudeTaskProgressReader(
        homeDirectory: home,
        indexRootDirectory: indexRoot,
        claudeExecutable: { nil },
        now: { claudeNow }
    ).readCollection()
    guard claudeCollection.items.contains(where: {
        $0.sessionID?.lowercased() == claudeSessionID.lowercased()
    }) else {
        throw RealTranscriptReadonlySelfTestError.providerReadFailed("claude")
    }

    let previousCursorIndexRoot = CursorLocalWorkspace.mockIndexRootDirectory
    CursorLocalWorkspace.mockIndexRootDirectory = indexRoot
    defer { CursorLocalWorkspace.mockIndexRootDirectory = previousCursorIndexRoot }
    CursorLocalWorkspace.resetInMemoryStateForTesting()
    OMPLocalSession.resetInMemoryStateForTesting()

    guard let cursor = candidates.first(where: { $0.provider == "cursor" }),
          let cursorSessionID = cursor.sessionID,
          CursorLocalWorkspace.sessionContent(
              sessionID: cursorSessionID,
              projectsRoot: home.appendingPathComponent(
                  ".cursor/projects",
                  isDirectory: true
              ),
              fileManager: manager,
              conversationMetadata: { _ in nil }
          ) != nil
    else {
        throw RealTranscriptReadonlySelfTestError.providerReadFailed("cursor")
    }

    guard let omp = candidates.first(where: { $0.provider == "omp" }),
          let ompSessionID = omp.sessionID,
          OMPLocalSession.content(
              sessionID: ompSessionID,
              sessionsRoot: home.appendingPathComponent(
                  ".omp/agent/sessions",
                  isDirectory: true
              ),
              fileManager: manager,
              indexRootDirectory: indexRoot
          ) != nil
    else {
        throw RealTranscriptReadonlySelfTestError.providerReadFailed("omp")
    }

    for candidate in candidates {
        let after = try fingerprintRealTranscript(at: candidate.url)
        guard after == before[candidate.provider] else {
            throw RealTranscriptReadonlySelfTestError.sourceChanged(
                candidate.provider
            )
        }
    }
    return candidates.count
}

private func realTranscriptCandidates(
    home: URL,
    fileManager: FileManager
) throws -> [RealTranscriptCandidate] {
    let codex = newestStableJSONL(
        roots: [home.appendingPathComponent(".codex/sessions", isDirectory: true)],
        fileManager: fileManager,
        accepts: {
            $0.lastPathComponent.hasPrefix("rollout-")
                && isReadableCodexCandidate($0)
        }
    ).map {
        RealTranscriptCandidate(
            provider: "codex",
            url: $0,
            sessionID: CodexTaskProgressReader.threadID(from: $0)
        )
    }

    let claude = newestStableJSONL(
        roots: [
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent(".config/claude/projects", isDirectory: true),
        ],
        fileManager: fileManager,
        accepts: { !$0.path.contains("/subagents/") }
    ).map {
        RealTranscriptCandidate(
            provider: "claude",
            url: $0,
            sessionID: $0.deletingPathExtension().lastPathComponent.lowercased()
        )
    }

    let cursor = newestStableJSONL(
        roots: [home.appendingPathComponent(".cursor/projects", isDirectory: true)],
        fileManager: fileManager,
        accepts: { $0.path.contains("/agent-transcripts/") }
    ).map {
        RealTranscriptCandidate(
            provider: "cursor",
            url: $0,
            sessionID: $0.deletingPathExtension().lastPathComponent
        )
    }

    let omp = newestStableJSONL(
        roots: [home.appendingPathComponent(".omp/agent/sessions", isDirectory: true)],
        fileManager: fileManager,
        accepts: { normalizedOMPSessionID(fromTranscriptURL: $0) != nil }
    ).map {
        RealTranscriptCandidate(
            provider: "omp",
            url: $0,
            sessionID: normalizedOMPSessionID(fromTranscriptURL: $0)
        )
    }

    let named: [(String, RealTranscriptCandidate?)] = [
        ("codex", codex),
        ("claude", claude),
        ("cursor", cursor),
        ("omp", omp),
    ]
    for (provider, candidate) in named where candidate == nil {
        throw RealTranscriptReadonlySelfTestError.providerUnavailable(provider)
    }
    return named.compactMap(\.1)
}

private func newestStableJSONL(
    roots: [URL],
    fileManager: FileManager,
    accepts: (URL) -> Bool
) -> URL? {
    // 避免选择仍被当前 agent 写入的会话；验收目标是证明 ThreadHelm 的读取
    // 不改写源文件，而不是把厂商自己的并发 append 误报成 ThreadHelm 写入。
    let stableBefore = Date().addingTimeInterval(-10 * 60)
    var best: (url: URL, modifiedAt: Date)?
    for root in roots {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { continue }
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  accepts(url),
                  let values = try? url.resourceValues(forKeys: [
                      .contentModificationDateKey,
                      .isRegularFileKey,
                  ]),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt <= stableBefore
            else { continue }
            if best == nil || modifiedAt > best!.modifiedAt {
                best = (url, modifiedAt)
            }
        }
    }
    return best?.url
}

private func isReadableCodexCandidate(_ url: URL) -> Bool {
    guard CodexTaskProgressReader.threadID(from: url) != nil,
          let handle = try? FileHandle(forReadingFrom: url)
    else { return false }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 262_144),
          let text = String(data: data, encoding: .utf8),
          let firstLine = text.split(separator: "\n", maxSplits: 1).first
    else { return false }
    return CodexTaskProgressReader.isUserVisibleSessionMetadata(
        line: String(firstLine),
        explicitlyVisible: false
    )
}

private func fingerprintDate(_ fingerprint: RealTranscriptFingerprint) -> Date {
    Date(
        timeIntervalSince1970: Double(fingerprint.modifiedSeconds)
            + Double(fingerprint.modifiedNanoseconds) / 1_000_000_000
    )
}

private func normalizedOMPSessionID(fromTranscriptURL url: URL) -> String? {
    let stem = url.deletingPathExtension().lastPathComponent
    let raw = stem.split(separator: "_").last.map(String.init) ?? stem
    return normalizedOMPSessionID(raw)
}

private func fingerprintRealTranscript(
    at url: URL
) throws -> RealTranscriptFingerprint {
    var statBuffer = stat()
    guard lstat(url.path, &statBuffer) == 0 else {
        throw RealTranscriptReadonlySelfTestError.providerReadFailed("metadata")
    }
    let handle: FileHandle
    do {
        handle = try FileHandle(forReadingFrom: url)
    } catch {
        throw RealTranscriptReadonlySelfTestError.providerReadFailed("sha256")
    }
    defer { try? handle.close() }
    var hasher = SHA256()
    do {
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
    } catch {
        throw RealTranscriptReadonlySelfTestError.providerReadFailed("sha256")
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return RealTranscriptFingerprint(
        device: UInt64(statBuffer.st_dev),
        inode: UInt64(statBuffer.st_ino),
        size: UInt64(statBuffer.st_size),
        modifiedSeconds: Int64(statBuffer.st_mtimespec.tv_sec),
        modifiedNanoseconds: Int64(statBuffer.st_mtimespec.tv_nsec),
        sha256: digest
    )
}
