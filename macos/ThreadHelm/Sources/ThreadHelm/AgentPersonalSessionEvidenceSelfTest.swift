//
//  AgentPersonalSessionEvidenceSelfTest.swift
//  ThreadHelm
//
//  模块职责：锁定显式、只计数的个人真实会话证据，以及个人 readiness
//  不会被真值夹具、启动/轮询或单独的样本数量自动升级。
//

import Darwin
import Foundation

private var agentPersonalSessionEvidenceSelfTestTemporaryRoot: URL?

func runAgentPersonalSessionEvidenceSelfTest() {
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-personal-session-self-test-\(UUID().uuidString)",
        isDirectory: true
    )
    let stateURL = temporaryRoot.appendingPathComponent("sessions.json")
    agentPersonalSessionEvidenceSelfTestTemporaryRoot = temporaryRoot
    defer { cleanupAgentPersonalSessionEvidenceSelfTestTemporaryRoot() }

    let store = AgentPersonalSessionEvidenceStore(
        fileURL: stateURL,
        fileManager: manager
    )
    let liveReader = AgentPersonalSessionEvidenceStore(
        fileURL: stateURL,
        fileManager: manager
    )
    guard !manager.fileExists(atPath: stateURL.path),
          AgentID.builtInOrder.allSatisfy({
              ActivityDashboardSnapshot().personalSessionEvidence.count(
                  for: $0
              ) == 0
          }),
          AgentID.builtInOrder.allSatisfy({
              store.snapshot().count(for: $0) == 0
          })
    else {
        failAgentPersonalSessionEvidenceSelfTest(
            "initial real personal evidence must be zero"
        )
    }

    for _ in 0..<81 {
        guard !store.record(
            agentID: .codex,
            source: .truthFixtureReplay
        ) else {
            failAgentPersonalSessionEvidenceSelfTest(
                "truth fixture replay was counted as personal use"
            )
        }
    }
    guard store.snapshot().count(for: .codex) == 0 else {
        failAgentPersonalSessionEvidenceSelfTest(
            "81 truth fixtures changed personal evidence"
        )
    }

    for _ in 0..<9 {
        guard store.record(agentID: .codex, source: .explicitOwnerRecord) else {
            failAgentPersonalSessionEvidenceSelfTest(
                "persist explicit personal session"
            )
        }
    }
    guard AgentPersonalReadinessAssessment(
        personalSessionCount: 9,
        independentlyReviewed: true
    ).readiness == .experimental else {
        failAgentPersonalSessionEvidenceSelfTest(
            "fewer than ten sessions left experimental"
        )
    }

    guard store.record(agentID: .codex, source: .explicitOwnerRecord) else {
        failAgentPersonalSessionEvidenceSelfTest("reach ten personal sessions")
    }
    guard AgentPersonalReadinessAssessment(
        personalSessionCount: 10,
        independentlyReviewed: false
    ).readiness == .experimental,
          AgentPersonalReadinessAssessment(
              personalSessionCount: 10,
              independentlyReviewed: true
          ).readiness == .personalReady
    else {
        failAgentPersonalSessionEvidenceSelfTest(
            "ten sessions must be necessary but not sufficient"
        )
    }

    guard !store.record(
        agentID: AgentID(rawValue: "third-party"),
        source: .explicitOwnerRecord
    ) else {
        failAgentPersonalSessionEvidenceSelfTest("reject unregistered agent")
    }

    let reloaded = AgentPersonalSessionEvidenceStore(
        fileURL: stateURL,
        fileManager: manager
    )
    guard reloaded.snapshot().count(for: .codex) == 10,
          liveReader.refreshedSnapshot().count(for: .codex) == 10,
          AgentID.builtInOrder.filter({ $0 != .codex }).allSatisfy({
              reloaded.snapshot().count(for: $0) == 0
          })
    else {
        failAgentPersonalSessionEvidenceSelfTest("persist five-agent counts")
    }

    let permissions = ((try? manager.attributesOfItem(atPath: stateURL.path)[
        .posixPermissions
    ]) as? NSNumber)?.intValue
    let directoryPermissions = ((try? manager.attributesOfItem(
        atPath: temporaryRoot.path
    )[.posixPermissions]) as? NSNumber)?.intValue
    guard permissions.map({ $0 & 0o777 }) == 0o600,
          directoryPermissions.map({ $0 & 0o777 }) == 0o700
    else {
        failAgentPersonalSessionEvidenceSelfTest(
            "owner-only 0700/0600 personal evidence"
        )
    }

    guard let data = try? Data(contentsOf: stateURL),
          agentPersonalSessionEvidenceJSONIsCountOnly(data)
    else {
        failAgentPersonalSessionEvidenceSelfTest(
            "storage must contain only five agent IDs and counts"
        )
    }

    assertConcurrentAgentPersonalSessionEvidenceWrites(
        temporaryRoot: temporaryRoot,
        fileManager: manager
    )

    guard parseAgentPersonalSessionEvidenceCLI([
        "ThreadHelm", "--print-personal-session-evidence",
    ]) == .printSnapshot,
          parseAgentPersonalSessionEvidenceCLI([
              "ThreadHelm", "--record-personal-session", "cursor",
          ]) == .record(agentID: .cursor),
          parseAgentPersonalSessionEvidenceCLI([
              "ThreadHelm", "--record-personal-session", "third-party",
          ]) == .invalid,
          parseAgentPersonalSessionEvidenceCLI([
              "ThreadHelm", "--record-personal-session", "cursor", "note",
          ]) == .invalid,
          parseAgentPersonalSessionEvidenceCLI([
              "ThreadHelm", "--print-quota",
          ]) == .notRequested
    else {
        failAgentPersonalSessionEvidenceSelfTest(
            "explicit bounded personal evidence CLI"
        )
    }

    let profiles = builtInAgentValidationProfiles()
    let expectedVersions: [AgentID: String] = [
        .codex: "0.145.0",
        .claudeCode: "2.1.226",
        .cursor: "Desktop 3.15.6 · Agent CLI 2026.04.14-ee4b43a",
        .zcode: "3.7.6 · build 3.7.6.4691",
        .pi: "0.84.1",
    ]
    guard Set(profiles.keys) == Set(AgentID.builtInOrder),
          expectedVersions.allSatisfy({ agentID, version in
              profiles[agentID]?.testedVersion == version
          }),
          profiles.values.allSatisfy({
              !$0.supportedCapabilitiesSummary.isEmpty
                  && !$0.knownLimitation.isEmpty
          }),
          profiles[.pi]?.knownLimitation.contains("不支持审批") == true
    else {
        failAgentPersonalSessionEvidenceSelfTest(
            "version-pinned capability and limitation profiles"
        )
    }
}

private func assertConcurrentAgentPersonalSessionEvidenceWrites(
    temporaryRoot: URL,
    fileManager: FileManager
) {
    let stateURL = temporaryRoot.appendingPathComponent(
        "concurrent-sessions.json"
    )
    let childCount = 16
    let goURL = temporaryRoot.appendingPathComponent("concurrent-go")
    guard let executableURL = Bundle.main.executableURL else {
        failAgentPersonalSessionEvidenceSelfTest(
            "locate executable for concurrent personal evidence writers"
        )
    }
    var processes: [Process] = []
    var readyURLs: [URL] = []

    for index in 0..<childCount {
        let readyURL = temporaryRoot.appendingPathComponent(
            "concurrent-ready-\(index)"
        )
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "--self-test-personal-session-writer",
            stateURL.path,
            readyURL.path,
            goURL.path,
        ]
        do {
            try process.run()
        } catch {
            _ = fileManager.createFile(
                atPath: goURL.path,
                contents: Data()
            )
            processes.forEach { $0.waitUntilExit() }
            failAgentPersonalSessionEvidenceSelfTest(
                "launch concurrent personal evidence writers"
            )
        }
        processes.append(process)
        readyURLs.append(readyURL)
    }

    let readyDeadline = Date().addingTimeInterval(5)
    while Date() < readyDeadline,
          !readyURLs.allSatisfy({
              fileManager.fileExists(atPath: $0.path)
          })
    {
        usleep(10_000)
    }
    guard readyURLs.allSatisfy({
        fileManager.fileExists(atPath: $0.path)
    }) else {
        _ = fileManager.createFile(atPath: goURL.path, contents: Data())
        processes.forEach { $0.waitUntilExit() }
        failAgentPersonalSessionEvidenceSelfTest(
            "prepare concurrent personal evidence writers"
        )
    }
    guard fileManager.createFile(atPath: goURL.path, contents: Data()) else {
        processes.forEach { $0.terminate() }
        processes.forEach { $0.waitUntilExit() }
        failAgentPersonalSessionEvidenceSelfTest(
            "release concurrent personal evidence writers"
        )
    }

    processes.forEach { $0.waitUntilExit() }
    guard processes.allSatisfy({ $0.terminationStatus == 0 }) else {
        failAgentPersonalSessionEvidenceSelfTest(
            "concurrent personal evidence writers complete"
        )
    }

    let finalCount = AgentPersonalSessionEvidenceStore(
        fileURL: stateURL,
        fileManager: fileManager
    ).snapshot().count(for: .cursor)
    guard finalCount == childCount else {
        failAgentPersonalSessionEvidenceSelfTest(
            "cross-process personal evidence writes must not lose counts"
        )
    }

    let lockURL = URL(fileURLWithPath: stateURL.path + ".lock")
    let lockAttributes = try? fileManager.attributesOfItem(
        atPath: lockURL.path
    )
    let lockPermissions = (lockAttributes?[.posixPermissions] as? NSNumber)?
        .intValue
    let lockSize = (lockAttributes?[.size] as? NSNumber)?.intValue
    let lockType = lockAttributes?[.type] as? FileAttributeType
    guard lockPermissions.map({ $0 & 0o777 }) == 0o600,
          lockSize == 0,
          lockType == .typeRegular,
          let concurrentData = try? Data(contentsOf: stateURL),
          agentPersonalSessionEvidenceJSONIsCountOnly(concurrentData)
    else {
        failAgentPersonalSessionEvidenceSelfTest(
            "count-only data and empty owner-only process lock"
        )
    }
}

func runAgentPersonalSessionEvidenceWriterSelfTestIfRequested(
    arguments: [String] = CommandLine.arguments,
    fileManager: FileManager = .default
) -> Int? {
    guard let flagIndex = arguments.firstIndex(
        of: "--self-test-personal-session-writer"
    ) else { return nil }
    guard arguments.count == 5, flagIndex == 1 else { return 2 }

    let stateURL = URL(fileURLWithPath: arguments[flagIndex + 1])
        .standardizedFileURL
    let readyURL = URL(fileURLWithPath: arguments[flagIndex + 2])
        .standardizedFileURL
    let goURL = URL(fileURLWithPath: arguments[flagIndex + 3])
        .standardizedFileURL
    let stateDirectory = stateURL.deletingLastPathComponent()
    let temporaryPathPrefix = fileManager.temporaryDirectory
        .standardizedFileURL.path + "/threadhelm-personal-session-self-test-"
    guard stateURL.path.hasPrefix(temporaryPathPrefix),
          readyURL.deletingLastPathComponent() == stateDirectory,
          goURL.deletingLastPathComponent() == stateDirectory
    else { return 2 }

    let store = AgentPersonalSessionEvidenceStore(
        fileURL: stateURL,
        fileManager: fileManager
    )
    guard fileManager.createFile(
        atPath: readyURL.path,
        contents: Data(),
        attributes: [.posixPermissions: 0o600]
    ) else { return 1 }

    let goDeadline = Date().addingTimeInterval(5)
    while Date() < goDeadline,
          !fileManager.fileExists(atPath: goURL.path)
    {
        usleep(10_000)
    }
    guard fileManager.fileExists(atPath: goURL.path) else { return 1 }
    return store.record(
        agentID: .cursor,
        source: .explicitOwnerRecord
    ) ? 0 : 1
}

private func agentPersonalSessionEvidenceJSONIsCountOnly(_ data: Data) -> Bool {
    guard let root = try? JSONSerialization.jsonObject(with: data)
        as? [String: Any],
          Set(root.keys) == Set(AgentID.builtInOrder.map(\.rawValue))
    else { return false }
    return root.values.allSatisfy { value in
        guard let number = value as? NSNumber else { return false }
        let integer = number.intValue
        return integer >= 0 && number.doubleValue == Double(integer)
    }
}

private func failAgentPersonalSessionEvidenceSelfTest(
    _ reason: String
) -> Never {
    cleanupAgentPersonalSessionEvidenceSelfTestTemporaryRoot()
    fputs("agent personal session evidence self-test failed: \(reason)\n", stderr)
    exit(1)
}

private func cleanupAgentPersonalSessionEvidenceSelfTestTemporaryRoot() {
    guard let temporaryRoot =
        agentPersonalSessionEvidenceSelfTestTemporaryRoot?.standardizedFileURL
    else { return }
    agentPersonalSessionEvidenceSelfTestTemporaryRoot = nil

    let manager = FileManager.default
    guard temporaryRoot.deletingLastPathComponent()
        == manager.temporaryDirectory.standardizedFileURL,
          temporaryRoot.lastPathComponent.hasPrefix(
              "threadhelm-personal-session-self-test-"
          )
    else { return }
    try? manager.removeItem(at: temporaryRoot)
}
