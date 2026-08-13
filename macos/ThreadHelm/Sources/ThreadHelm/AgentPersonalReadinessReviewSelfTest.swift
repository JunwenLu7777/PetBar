//
//  AgentPersonalReadinessReviewSelfTest.swift
//  ThreadHelm
//
//  模块职责：锁定主人复核必须以十次真实会话为前置、只保存五个布尔值、
//  可以撤销，并且并发本地确认不会互相覆盖。
//

import Darwin
import Foundation

private var agentPersonalReadinessReviewSelfTestTemporaryRoot: URL?

func runAgentPersonalReadinessReviewSelfTest() {
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-personal-readiness-review-self-test-\(UUID().uuidString)",
        isDirectory: true
    )
    let sessionURL = temporaryRoot.appendingPathComponent("sessions.json")
    let reviewURL = temporaryRoot.appendingPathComponent("reviews.json")
    agentPersonalReadinessReviewSelfTestTemporaryRoot = temporaryRoot
    defer { cleanupAgentPersonalReadinessReviewSelfTestTemporaryRoot() }

    let sessionStore = AgentPersonalSessionEvidenceStore(
        fileURL: sessionURL,
        fileManager: manager
    )
    let reviewStore = AgentPersonalReadinessReviewStore(
        fileURL: reviewURL,
        fileManager: manager
    )
    let liveReader = AgentPersonalReadinessReviewStore(
        fileURL: reviewURL,
        fileManager: manager
    )

    guard !manager.fileExists(atPath: reviewURL.path),
          AgentID.builtInOrder.allSatisfy({
              !ActivityDashboardSnapshot().personalReadinessReviews
                  .isReviewed(for: $0)
                  && !reviewStore.snapshot().isReviewed(for: $0)
          })
    else {
        failAgentPersonalReadinessReviewSelfTest(
            "initial owner review state must be false"
        )
    }

    for _ in 0..<9 {
        guard sessionStore.record(
            agentID: .cursor,
            source: .explicitOwnerRecord
        ) else {
            failAgentPersonalReadinessReviewSelfTest(
                "seed nine real cursor sessions"
            )
        }
    }
    guard reviewStore.confirm(
        agentID: .cursor,
        personalSessions: sessionStore.snapshot()
    ) == .insufficientPersonalSessions,
          !reviewStore.snapshot().isReviewed(for: .cursor),
          !manager.fileExists(atPath: reviewURL.path)
    else {
        failAgentPersonalReadinessReviewSelfTest(
            "review cannot be confirmed before ten real sessions"
        )
    }

    guard sessionStore.record(
        agentID: .cursor,
        source: .explicitOwnerRecord
    ), let sessionDataBeforeReview = try? Data(contentsOf: sessionURL),
       reviewStore.confirm(
           agentID: .cursor,
           personalSessions: sessionStore.snapshot()
       ) == .updated,
       reviewStore.confirm(
           agentID: .cursor,
           personalSessions: sessionStore.snapshot()
       ) == .unchanged,
       reviewStore.snapshot().isReviewed(for: .cursor),
       AgentID.builtInOrder.filter({ $0 != .cursor }).allSatisfy({
           !reviewStore.snapshot().isReviewed(for: $0)
       }), let sessionDataAfterReview = try? Data(contentsOf: sessionURL),
       sessionDataAfterReview == sessionDataBeforeReview
    else {
        failAgentPersonalReadinessReviewSelfTest(
            "ten sessions allow an idempotent bool-only owner review"
        )
    }

    let reloaded = AgentPersonalReadinessReviewStore(
        fileURL: reviewURL,
        fileManager: manager
    )
    guard reloaded.snapshot().isReviewed(for: .cursor),
          liveReader.refreshedSnapshot().isReviewed(for: .cursor),
          agentPersonalSessionEvidenceDiagnosticText(
              sessionStore.snapshot(),
              reviews: reloaded.snapshot()
          ).contains("cursor personal-ready · 真实会话 10/10")
    else {
        failAgentPersonalReadinessReviewSelfTest(
            "persist and display the owner review"
        )
    }

    let reviewPermissions = ((try? manager.attributesOfItem(
        atPath: reviewURL.path
    )[.posixPermissions]) as? NSNumber)?.intValue
    let directoryPermissions = ((try? manager.attributesOfItem(
        atPath: temporaryRoot.path
    )[.posixPermissions]) as? NSNumber)?.intValue
    let lockURL = URL(fileURLWithPath: reviewURL.path + ".lock")
    let lockAttributes = try? manager.attributesOfItem(atPath: lockURL.path)
    let lockPermissions = (lockAttributes?[.posixPermissions] as? NSNumber)?
        .intValue
    let lockSize = (lockAttributes?[.size] as? NSNumber)?.intValue
    let lockType = lockAttributes?[.type] as? FileAttributeType
    guard reviewPermissions.map({ $0 & 0o777 }) == 0o600,
          directoryPermissions.map({ $0 & 0o777 }) == 0o700,
          lockPermissions.map({ $0 & 0o777 }) == 0o600,
          lockSize == 0,
          lockType == .typeRegular,
          let reviewData = try? Data(contentsOf: reviewURL),
          agentPersonalReadinessReviewJSONIsBooleanOnly(reviewData)
    else {
        failAgentPersonalReadinessReviewSelfTest(
            "owner-only bool-only review storage"
        )
    }

    guard (try? Data("must-be-cleared".utf8).write(to: lockURL)) != nil,
          reviewStore.revoke(agentID: .cursor) == .updated,
          let clearedLockSize = ((try? manager.attributesOfItem(
              atPath: lockURL.path
          )[.size]) as? NSNumber)?.intValue,
          clearedLockSize == 0,
          reviewStore.confirm(
              agentID: .cursor,
              personalSessions: sessionStore.snapshot()
          ) == .updated
    else {
        failAgentPersonalReadinessReviewSelfTest(
            "owner review lock must remain metadata-free"
        )
    }

    guard reviewStore.revoke(agentID: .cursor) == .updated,
          reviewStore.revoke(agentID: .cursor) == .unchanged,
          !reviewStore.snapshot().isReviewed(for: .cursor),
          sessionStore.snapshot().count(for: .cursor) == 10,
          agentPersonalSessionEvidenceDiagnosticText(
              sessionStore.snapshot(),
              reviews: reviewStore.snapshot()
          ).contains(
              "cursor experimental · 真实会话 10/10 · 待主人复核"
          )
    else {
        failAgentPersonalReadinessReviewSelfTest(
            "revoking review preserves real session evidence"
        )
    }

    guard reviewStore.confirm(
        agentID: AgentID(rawValue: "third-party"),
        personalSessions: sessionStore.snapshot()
    ) == .invalidAgent,
          reviewStore.revoke(
              agentID: AgentID(rawValue: "third-party")
          ) == .invalidAgent
    else {
        failAgentPersonalReadinessReviewSelfTest(
            "reject non-built-in owner review state"
        )
    }

    guard parseAgentPersonalSessionEvidenceCLI([
        "ThreadHelm", "--confirm-personal-readiness", "cursor",
    ]) == .confirmReadiness(agentID: .cursor),
          parseAgentPersonalSessionEvidenceCLI([
              "ThreadHelm", "--revoke-personal-readiness", "cursor",
          ]) == .revokeReadiness(agentID: .cursor),
          parseAgentPersonalSessionEvidenceCLI([
              "ThreadHelm", "--confirm-personal-readiness", "third-party",
          ]) == .invalid,
          parseAgentPersonalSessionEvidenceCLI([
              "ThreadHelm", "--confirm-personal-readiness", "cursor", "note",
          ]) == .invalid
    else {
        failAgentPersonalReadinessReviewSelfTest(
            "explicit bounded owner review CLI"
        )
    }

    assertAgentPersonalReadinessReviewCLIExecution(
        temporaryRoot: temporaryRoot,
        fileManager: manager
    )
    assertMalformedAgentPersonalReadinessReviewInputs(
        temporaryRoot: temporaryRoot,
        fileManager: manager
    )
    assertAgentPersonalReadinessReviewSymlinkBoundaries(
        temporaryRoot: temporaryRoot,
        fileManager: manager
    )
    assertConcurrentAgentPersonalReadinessReviewWrites(
        temporaryRoot: temporaryRoot,
        fileManager: manager
    )
}

private func assertAgentPersonalReadinessReviewCLIExecution(
    temporaryRoot: URL,
    fileManager: FileManager
) {
    let sessionURL = temporaryRoot.appendingPathComponent("cli-sessions.json")
    let reviewURL = temporaryRoot.appendingPathComponent("cli-reviews.json")
    let sessions = AgentPersonalSessionEvidenceStore(
        fileURL: sessionURL,
        fileManager: fileManager
    )
    let reviews = AgentPersonalReadinessReviewStore(
        fileURL: reviewURL,
        fileManager: fileManager
    )

    guard runSilentAgentPersonalSessionEvidenceCLI(
        arguments: [
            "ThreadHelm", "--confirm-personal-readiness", "cursor",
        ],
        store: sessions,
        reviewStore: reviews
    ) == 1,
          !fileManager.fileExists(atPath: reviewURL.path)
    else {
        failAgentPersonalReadinessReviewSelfTest(
            "CLI must reject owner review before ten sessions"
        )
    }

    for _ in 0..<AgentPersonalReadinessAssessment
        .requiredPersonalSessionCount
    {
        guard sessions.record(
            agentID: .cursor,
            source: .explicitOwnerRecord
        ) else {
            failAgentPersonalReadinessReviewSelfTest(
                "seed CLI owner review sessions"
            )
        }
    }
    guard runSilentAgentPersonalSessionEvidenceCLI(
        arguments: [
            "ThreadHelm", "--confirm-personal-readiness", "cursor",
        ],
        store: sessions,
        reviewStore: reviews
    ) == 0,
          runSilentAgentPersonalSessionEvidenceCLI(
              arguments: [
                  "ThreadHelm", "--confirm-personal-readiness", "cursor",
              ],
              store: sessions,
              reviewStore: reviews
          ) == 0,
          reviews.snapshot().isReviewed(for: .cursor),
          runSilentAgentPersonalSessionEvidenceCLI(
              arguments: ["ThreadHelm", "--print-personal-session-evidence"],
              store: sessions,
              reviewStore: reviews
          ) == 0,
          runSilentAgentPersonalSessionEvidenceCLI(
              arguments: [
                  "ThreadHelm", "--revoke-personal-readiness", "cursor",
              ],
              store: sessions,
              reviewStore: reviews
          ) == 0,
          runSilentAgentPersonalSessionEvidenceCLI(
              arguments: [
                  "ThreadHelm", "--revoke-personal-readiness", "cursor",
              ],
              store: sessions,
              reviewStore: reviews
          ) == 0,
          !reviews.snapshot().isReviewed(for: .cursor),
          sessions.snapshot().count(for: .cursor)
              == AgentPersonalReadinessAssessment.requiredPersonalSessionCount,
          runSilentAgentPersonalSessionEvidenceCLI(
              arguments: [
                  "ThreadHelm",
                  "--confirm-personal-readiness", "cursor",
                  "--revoke-personal-readiness", "cursor",
              ],
              store: sessions,
              reviewStore: reviews
          ) == 2
    else {
        failAgentPersonalReadinessReviewSelfTest(
            "CLI confirm, print, revoke, and invalid execution boundaries"
        )
    }
}

private func runSilentAgentPersonalSessionEvidenceCLI(
    arguments: [String],
    store: AgentPersonalSessionEvidenceStore,
    reviewStore: AgentPersonalReadinessReviewStore
) -> Int? {
    runAgentPersonalSessionEvidenceCLIIfRequested(
        arguments: arguments,
        store: store,
        reviewStore: reviewStore,
        writeOutput: { _ in },
        writeError: { _ in }
    )
}

private func assertMalformedAgentPersonalReadinessReviewInputs(
    temporaryRoot: URL,
    fileManager: FileManager
) {
    let reviewURL = temporaryRoot.appendingPathComponent(
        "malformed-reviews.json"
    )
    let invalidDocuments = [
        "{ bad json",
        "{\"cursor\":\"true\"}",
        "{\"cursor\":1}",
        "{\"cursor\":true}",
        "{\"codex\":false,\"claudeCode\":false,\"cursor\":true,"
            + "\"zcode\":false,\"pi\":false,\"unexpected\":false}",
    ]

    for document in invalidDocuments {
        try? fileManager.removeItem(at: reviewURL)
        guard fileManager.createFile(
            atPath: reviewURL.path,
            contents: Data(document.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            failAgentPersonalReadinessReviewSelfTest(
                "write malformed owner review fixture"
            )
        }
        let snapshot = AgentPersonalReadinessReviewStore(
            fileURL: reviewURL,
            fileManager: fileManager
        ).snapshot()
        guard AgentID.builtInOrder.allSatisfy({
            !snapshot.isReviewed(for: $0)
        }) else {
            failAgentPersonalReadinessReviewSelfTest(
                "malformed owner review state must fail closed"
            )
        }
    }
}

private func assertAgentPersonalReadinessReviewSymlinkBoundaries(
    temporaryRoot: URL,
    fileManager: FileManager
) {
    let externalReviewURL = temporaryRoot.appendingPathComponent(
        "external-review-target.json"
    )
    let reviewURL = temporaryRoot.appendingPathComponent(
        "symlinked-reviews.json"
    )
    let completeExternalReview = Data(
        "{\"codex\":false,\"claudeCode\":false,\"cursor\":true,"
            .appending("\"zcode\":false,\"pi\":false}")
            .utf8
    )
    guard fileManager.createFile(
        atPath: externalReviewURL.path,
        contents: completeExternalReview,
        attributes: [.posixPermissions: 0o600]
    ) else {
        failAgentPersonalReadinessReviewSelfTest(
            "write external owner review symlink target"
        )
    }
    do {
        try fileManager.createSymbolicLink(
            at: reviewURL,
            withDestinationURL: externalReviewURL
        )
    } catch {
        failAgentPersonalReadinessReviewSelfTest(
            "create owner review file symlink"
        )
    }

    let sessions = AgentPersonalSessionEvidenceStore(
        fileURL: temporaryRoot.appendingPathComponent(
            "symlink-sessions.json"
        ),
        fileManager: fileManager
    )
    for _ in 0..<AgentPersonalReadinessAssessment
        .requiredPersonalSessionCount
    {
        guard sessions.record(
            agentID: .cursor,
            source: .explicitOwnerRecord
        ) else {
            failAgentPersonalReadinessReviewSelfTest(
                "seed owner review symlink sessions"
            )
        }
    }
    let reviews = AgentPersonalReadinessReviewStore(
        fileURL: reviewURL,
        fileManager: fileManager
    )
    guard !reviews.snapshot().isReviewed(for: .cursor),
          reviews.confirm(
              agentID: .cursor,
              personalSessions: sessions.snapshot()
          ) == .updated,
          reviews.snapshot().isReviewed(for: .cursor),
          let externalData = try? Data(contentsOf: externalReviewURL),
          externalData == completeExternalReview,
          let reviewType = (try? fileManager.attributesOfItem(
              atPath: reviewURL.path
          )[.type]) as? FileAttributeType,
          reviewType == .typeRegular
    else {
        failAgentPersonalReadinessReviewSelfTest(
            "owner review must not trust or overwrite a symlink target"
        )
    }

    let lockReviewURL = temporaryRoot.appendingPathComponent(
        "symlinked-lock-reviews.json"
    )
    let lockURL = URL(fileURLWithPath: lockReviewURL.path + ".lock")
    let externalLockURL = temporaryRoot.appendingPathComponent(
        "external-review-lock"
    )
    guard fileManager.createFile(
        atPath: externalLockURL.path,
        contents: Data("unchanged".utf8),
        attributes: [.posixPermissions: 0o600]
    ) else {
        failAgentPersonalReadinessReviewSelfTest(
            "write external owner review lock target"
        )
    }
    do {
        try fileManager.createSymbolicLink(
            at: lockURL,
            withDestinationURL: externalLockURL
        )
    } catch {
        failAgentPersonalReadinessReviewSelfTest(
            "create owner review lock symlink"
        )
    }
    let lockReviews = AgentPersonalReadinessReviewStore(
        fileURL: lockReviewURL,
        fileManager: fileManager
    )
    guard lockReviews.confirm(
        agentID: .cursor,
        personalSessions: sessions.snapshot()
    ) == .failed,
          !fileManager.fileExists(atPath: lockReviewURL.path),
          (try? Data(contentsOf: externalLockURL))
              == Data("unchanged".utf8)
    else {
        failAgentPersonalReadinessReviewSelfTest(
            "owner review must reject a symlink lock"
        )
    }
}

private func assertConcurrentAgentPersonalReadinessReviewWrites(
    temporaryRoot: URL,
    fileManager: FileManager
) {
    let sessionURL = temporaryRoot.appendingPathComponent(
        "concurrent-sessions.json"
    )
    let reviewURL = temporaryRoot.appendingPathComponent(
        "concurrent-reviews.json"
    )
    let goURL = temporaryRoot.appendingPathComponent("concurrent-review-go")
    let sessions = AgentPersonalSessionEvidenceStore(
        fileURL: sessionURL,
        fileManager: fileManager
    )
    for agentID in AgentID.builtInOrder {
        for _ in 0..<AgentPersonalReadinessAssessment
            .requiredPersonalSessionCount
        {
            guard sessions.record(
                agentID: agentID,
                source: .explicitOwnerRecord
            ) else {
                failAgentPersonalReadinessReviewSelfTest(
                    "seed concurrent owner review sessions"
                )
            }
        }
    }

    guard let executableURL = Bundle.main.executableURL else {
        failAgentPersonalReadinessReviewSelfTest(
            "locate executable for concurrent owner reviews"
        )
    }
    var processes: [Process] = []
    var readyURLs: [URL] = []
    for (index, agentID) in AgentID.builtInOrder.enumerated() {
        let readyURL = temporaryRoot.appendingPathComponent(
            "concurrent-review-ready-\(index)"
        )
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "--self-test-personal-readiness-review-writer",
            reviewURL.path,
            sessionURL.path,
            readyURL.path,
            goURL.path,
            agentID.rawValue,
        ]
        do {
            try process.run()
        } catch {
            _ = fileManager.createFile(atPath: goURL.path, contents: Data())
            processes.forEach { $0.waitUntilExit() }
            failAgentPersonalReadinessReviewSelfTest(
                "launch concurrent owner review writers"
            )
        }
        processes.append(process)
        readyURLs.append(readyURL)
    }

    let readyDeadline = Date().addingTimeInterval(5)
    while Date() < readyDeadline,
          !readyURLs.allSatisfy({ fileManager.fileExists(atPath: $0.path) })
    {
        usleep(10_000)
    }
    guard readyURLs.allSatisfy({ fileManager.fileExists(atPath: $0.path) }),
          fileManager.createFile(atPath: goURL.path, contents: Data())
    else {
        _ = fileManager.createFile(atPath: goURL.path, contents: Data())
        processes.forEach { $0.waitUntilExit() }
        failAgentPersonalReadinessReviewSelfTest(
            "synchronize concurrent owner review writers"
        )
    }

    processes.forEach { $0.waitUntilExit() }
    guard processes.allSatisfy({ $0.terminationStatus == 0 }) else {
        failAgentPersonalReadinessReviewSelfTest(
            "concurrent owner review writer process"
        )
    }
    let snapshot = AgentPersonalReadinessReviewStore(
        fileURL: reviewURL,
        fileManager: fileManager
    ).snapshot()
    guard AgentID.builtInOrder.allSatisfy({ snapshot.isReviewed(for: $0) }),
          let data = try? Data(contentsOf: reviewURL),
          agentPersonalReadinessReviewJSONIsBooleanOnly(data)
    else {
        failAgentPersonalReadinessReviewSelfTest(
            "concurrent owner review writes must not lose booleans"
        )
    }
}

func runAgentPersonalReadinessReviewWriterSelfTestIfRequested(
    arguments: [String] = CommandLine.arguments,
    fileManager: FileManager = .default
) -> Int? {
    guard let flagIndex = arguments.firstIndex(
        of: "--self-test-personal-readiness-review-writer"
    ) else { return nil }
    guard arguments.count == 7, flagIndex == 1 else { return 2 }

    let reviewURL = URL(fileURLWithPath: arguments[flagIndex + 1])
        .standardizedFileURL
    let sessionURL = URL(fileURLWithPath: arguments[flagIndex + 2])
        .standardizedFileURL
    let readyURL = URL(fileURLWithPath: arguments[flagIndex + 3])
        .standardizedFileURL
    let goURL = URL(fileURLWithPath: arguments[flagIndex + 4])
        .standardizedFileURL
    let agentID = AgentID(rawValue: arguments[flagIndex + 5])
    let stateDirectory = reviewURL.deletingLastPathComponent()
    let temporaryPathPrefix = fileManager.temporaryDirectory
        .standardizedFileURL.path
        + "/threadhelm-personal-readiness-review-self-test-"
    guard AgentID.builtInOrder.contains(agentID),
          reviewURL.path.hasPrefix(temporaryPathPrefix),
          sessionURL.deletingLastPathComponent() == stateDirectory,
          readyURL.deletingLastPathComponent() == stateDirectory,
          goURL.deletingLastPathComponent() == stateDirectory
    else { return 2 }

    let reviewStore = AgentPersonalReadinessReviewStore(
        fileURL: reviewURL,
        fileManager: fileManager
    )
    let sessionStore = AgentPersonalSessionEvidenceStore(
        fileURL: sessionURL,
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
    let result = reviewStore.confirm(
        agentID: agentID,
        personalSessions: sessionStore.snapshot()
    )
    return result == .updated || result == .unchanged ? 0 : 1
}

private func agentPersonalReadinessReviewJSONIsBooleanOnly(
    _ data: Data
) -> Bool {
    guard let root = try? JSONSerialization.jsonObject(with: data)
        as? [String: Any],
          Set(root.keys) == Set(AgentID.builtInOrder.map(\.rawValue))
    else { return false }
    return root.values.allSatisfy { value in
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

private func failAgentPersonalReadinessReviewSelfTest(
    _ reason: String
) -> Never {
    cleanupAgentPersonalReadinessReviewSelfTestTemporaryRoot()
    fputs("agent personal readiness review self-test failed: \(reason)\n", stderr)
    exit(1)
}

private func cleanupAgentPersonalReadinessReviewSelfTestTemporaryRoot() {
    guard let temporaryRoot =
        agentPersonalReadinessReviewSelfTestTemporaryRoot?.standardizedFileURL
    else { return }
    agentPersonalReadinessReviewSelfTestTemporaryRoot = nil

    let manager = FileManager.default
    guard temporaryRoot.deletingLastPathComponent()
        == manager.temporaryDirectory.standardizedFileURL,
          temporaryRoot.lastPathComponent.hasPrefix(
              "threadhelm-personal-readiness-review-self-test-"
          )
    else { return }
    try? manager.removeItem(at: temporaryRoot)
}
