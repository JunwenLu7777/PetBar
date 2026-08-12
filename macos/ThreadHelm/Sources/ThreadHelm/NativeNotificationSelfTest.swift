//
//  NativeNotificationSelfTest.swift
//  ThreadHelm
//
//  模块职责：--self-test-native-notification-state 自测——原生活动抑制监视器
//  调度与并发停止、overlay 通知同步探针稳定退出策略、同步器重试与重启
//  取消、通知路径解析，以及 prepare/restore/文件事务的完整生命周期。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

func runNativeNotificationStateSelfTest() -> Never {
    var suppressionEligible = false
    var suppressionAttemptCount = 0
    var scheduledSuppressionChecks: [() -> Void] = []
    let suppressionMonitor = NativeActivityPillSuppressionMonitor(
        interval: 0,
        shouldSuppress: {
            suppressionEligible
        },
        suppress: {
            suppressionAttemptCount += 1
        },
        schedule: { _, check in
            scheduledSuppressionChecks.append(check)
        }
    )
    suppressionMonitor.start()
    guard scheduledSuppressionChecks.count == 1,
          suppressionAttemptCount == 0
    else {
        fputs("native activity monitor did not schedule its initial check\n", stderr)
        exit(1)
    }
    scheduledSuppressionChecks.removeFirst()()
    guard scheduledSuppressionChecks.count == 1,
          suppressionAttemptCount == 0
    else {
        fputs("native activity monitor ignored its eligibility gate\n", stderr)
        exit(1)
    }
    suppressionEligible = true
    scheduledSuppressionChecks.removeFirst()()
    guard scheduledSuppressionChecks.count == 1,
          suppressionAttemptCount == 1
    else {
        fputs("native activity monitor did not suppress an eligible pill\n", stderr)
        exit(1)
    }
    suppressionMonitor.start()
    guard scheduledSuppressionChecks.count == 1 else {
        fputs("native activity monitor start was not idempotent\n", stderr)
        exit(1)
    }
    suppressionMonitor.stop()
    scheduledSuppressionChecks.removeFirst()()
    guard scheduledSuppressionChecks.isEmpty,
          suppressionAttemptCount == 1
    else {
        fputs("native activity monitor did not cancel stale checks\n", stderr)
        exit(1)
    }

    let concurrentCheckStarted = DispatchSemaphore(value: 0)
    let allowConcurrentCheckToFinish = DispatchSemaphore(value: 0)
    let concurrentSuppressionFinished = DispatchSemaphore(value: 0)
    let concurrentStopStarted = DispatchSemaphore(value: 0)
    let concurrentStopFinished = DispatchSemaphore(value: 0)
    let concurrentQueue = DispatchQueue(
        label: "\(threadHelmBundleIdentifier).native-activity-self-test"
    )
    let concurrentMonitor = NativeActivityPillSuppressionMonitor(
        interval: 60,
        shouldSuppress: {
            concurrentCheckStarted.signal()
            return allowConcurrentCheckToFinish.wait(
                timeout: .now() + 2
            ) == .success
        },
        suppress: {
            concurrentSuppressionFinished.signal()
        },
        schedule: { delay, check in
            concurrentQueue.asyncAfter(
                deadline: .now() + delay,
                execute: check
            )
        }
    )
    concurrentMonitor.start()
    guard concurrentCheckStarted.wait(timeout: .now() + 2) == .success else {
        fputs("native activity monitor concurrency check did not start\n", stderr)
        exit(1)
    }
    DispatchQueue.global(qos: .utility).async {
        concurrentStopStarted.signal()
        concurrentMonitor.stop()
        concurrentStopFinished.signal()
    }
    guard concurrentStopStarted.wait(timeout: .now() + 2) == .success,
          concurrentStopFinished.wait(timeout: .now() + 0.05) == .timedOut
    else {
        fputs("native activity monitor stop did not wait for an active check\n", stderr)
        exit(1)
    }
    allowConcurrentCheckToFinish.signal()
    guard concurrentSuppressionFinished.wait(timeout: .now() + 2) == .success,
          concurrentStopFinished.wait(timeout: .now() + 2) == .success
    else {
        fputs("native activity monitor did not finish a synchronized stop\n", stderr)
        exit(1)
    }

    let initialState: [String: Any] = [
        "electron-persisted-atom-state": [
            "first-awake-pet-notification-avatar-ids": ["codex"],
            "avatar-overlay-muted-notification-ids-v1": ["local:local:already-muted"],
            "thread-client-id-v1:local%3Aknown-thread": "client-1",
        ],
        "unrelated": ["keep": true],
    ]
    let initialData = try! JSONSerialization.data(withJSONObject: initialState)
    let sessionIndex = """
    {"id":"indexed-thread","title":"not persisted by ThreadHelm"}
    invalid-json-line
    {"id":"already-muted"}
    """.data(using: .utf8)
    let initialSnapshot = CodexOverlayNotificationDiskSnapshot(
        stateData: initialData,
        sessionIndexData: sessionIndex
    )

    var syncProbe = CodexOverlayNotificationSyncProbe(
        requiredStableSampleCount: 3
    )
    guard syncProbe.observe(codexRunning: true, snapshot: nil) == .waitForCodexExit,
          syncProbe.observe(codexRunning: false, snapshot: initialSnapshot)
            == .waitForStableFiles,
          syncProbe.observe(codexRunning: false, snapshot: initialSnapshot)
            == .waitForStableFiles,
          syncProbe.observe(codexRunning: false, snapshot: initialSnapshot)
            == .synchronize
    else {
        fputs("native notification stable-exit policy failed\n", stderr)
        exit(1)
    }

    let changedSnapshot = CodexOverlayNotificationDiskSnapshot(
        stateData: initialData,
        sessionIndexData: #"{"id":"late-thread"}"#.data(using: .utf8)
    )
    guard syncProbe.observe(codexRunning: false, snapshot: changedSnapshot)
            == .waitForStableFiles
    else {
        fputs("native notification changed disk did not reset stability\n", stderr)
        exit(1)
    }

    enum TestSyncError: Error {
        case transient
    }
    var codexRunning = true
    var snapshotReadCount = 0
    var synchronizationAttemptCount = 0
    var scheduledChecks: [() -> Void] = []
    let synchronizer = CodexOverlayNotificationSynchronizer(
        requiredStableSampleCount: 2,
        maximumAttempts: 5,
        checkInterval: 0,
        isCodexRunning: { codexRunning },
        readSnapshot: {
            snapshotReadCount += 1
            return initialSnapshot
        },
        synchronize: {
            synchronizationAttemptCount += 1
            if synchronizationAttemptCount == 1 {
                throw TestSyncError.transient
            }
            return true
        },
        schedule: { _, check in
            scheduledChecks.append(check)
        },
        log: { _ in }
    )
    synchronizer.codexRunningStateDidChange(true)
    guard scheduledChecks.isEmpty,
          snapshotReadCount == 0,
          synchronizationAttemptCount == 0
    else {
        fputs("native notification sync touched disk while Codex was running\n", stderr)
        exit(1)
    }

    codexRunning = false
    synchronizer.codexRunningStateDidChange(false)
    for _ in 0..<3 {
        guard !scheduledChecks.isEmpty else {
            fputs("native notification sync did not schedule a retry\n", stderr)
            exit(1)
        }
        let check = scheduledChecks.removeFirst()
        check()
    }
    guard snapshotReadCount == 3,
          synchronizationAttemptCount == 2,
          scheduledChecks.isEmpty
    else {
        fputs("native notification transient sync retry failed\n", stderr)
        exit(1)
    }

    codexRunning = true
    synchronizer.codexRunningStateDidChange(true)
    codexRunning = false
    synchronizer.codexRunningStateDidChange(false)
    guard scheduledChecks.count == 1 else {
        fputs("native notification sync did not restart after the next exit\n", stderr)
        exit(1)
    }
    let staleCheck = scheduledChecks.removeFirst()
    codexRunning = true
    synchronizer.codexRunningStateDidChange(true)
    staleCheck()
    guard snapshotReadCount == 3,
          synchronizationAttemptCount == 2
    else {
        fputs("native notification relaunch did not cancel stale sync work\n", stderr)
        exit(1)
    }
    synchronizer.stop()

    let fallbackPaths = CodexOverlayNotificationPaths.current(
        environment: [:],
        homeDirectory: URL(fileURLWithPath: "/tmp/threadhelm-home", isDirectory: true)
    )
    let configuredHomePaths = CodexOverlayNotificationPaths.current(
        environment: ["CODEX_HOME": "/tmp/threadhelm-codex-home"],
        homeDirectory: URL(fileURLWithPath: "/tmp/ignored-home", isDirectory: true)
    )
    let explicitStatePaths = CodexOverlayNotificationPaths.current(
        environment: [
            "CODEX_HOME": "/tmp/ignored-codex-home",
            "THREADHELM_CODEX_STATE_FILE": "/tmp/threadhelm-state/custom-state.json",
        ],
        homeDirectory: URL(fileURLWithPath: "/tmp/ignored-home", isDirectory: true)
    )
    guard fallbackPaths.stateURL.path
            == "/tmp/threadhelm-home/.codex/.codex-global-state.json",
          fallbackPaths.sessionIndexURL.path
            == "/tmp/threadhelm-home/.codex/session_index.jsonl",
          configuredHomePaths.backupURL.path
            == "/tmp/threadhelm-codex-home/threadhelm-native-notification-backup.json",
          explicitStatePaths.stateURL.path
            == "/tmp/threadhelm-state/custom-state.json",
          explicitStatePaths.sessionIndexURL.path
            == "/tmp/threadhelm-state/session_index.jsonl"
    else {
        fputs("native notification path resolution failed\n", stderr)
        exit(1)
    }

    let firstPreparation: PreparedCodexOverlayNotificationState
    do {
        firstPreparation = try CodexOverlayNotificationState.prepare(
            stateData: initialData,
            sessionIndexData: sessionIndex,
            existingBackupData: nil
        )
    } catch {
        fputs("native notification prepare failed: \(error)\n", stderr)
        exit(1)
    }

    func persistedAtoms(in data: Data) -> [String: Any] {
        let root = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        return root["electron-persisted-atom-state"] as! [String: Any]
    }
    let preparedAtoms = persistedAtoms(in: firstPreparation.stateData)
    let firstAwake = preparedAtoms["first-awake-pet-notification-avatar-ids"] as? [String]
    let muted = preparedAtoms["avatar-overlay-muted-notification-ids-v1"] as? [String]
    guard firstAwake == ["codex"],
          muted == [
              "local:local:already-muted",
              "local:local:indexed-thread",
              "local:local:known-thread",
          ]
    else {
        fputs("native notification prepare did not add the expected values\n", stderr)
        exit(1)
    }

    let secondIndex = #"{"id":"later-thread"}"#.data(using: .utf8)
    let secondPreparation: PreparedCodexOverlayNotificationState
    do {
        secondPreparation = try CodexOverlayNotificationState.prepare(
            stateData: firstPreparation.stateData,
            sessionIndexData: secondIndex,
            existingBackupData: firstPreparation.backupData
        )
    } catch {
        fputs("native notification re-prepare failed: \(error)\n", stderr)
        exit(1)
    }

    var changedRoot = try! JSONSerialization.jsonObject(
        with: secondPreparation.stateData
    ) as! [String: Any]
    var changedAtoms = changedRoot["electron-persisted-atom-state"] as! [String: Any]
    changedAtoms["first-awake-pet-notification-avatar-ids"] = [
        "codex",
        "custom:user-pet",
    ]
    changedAtoms["avatar-overlay-muted-notification-ids-v1"] = [
        "local:local:already-muted",
        "local:local:indexed-thread",
        "local:local:known-thread",
        "local:local:later-thread",
        "local:local:user-choice",
    ]
    changedRoot["electron-persisted-atom-state"] = changedAtoms
    let changedData = try! JSONSerialization.data(withJSONObject: changedRoot)

    let restoredData: Data
    do {
        restoredData = try CodexOverlayNotificationState.restore(
            stateData: changedData,
            backupData: secondPreparation.backupData
        )
    } catch {
        fputs("native notification restore failed: \(error)\n", stderr)
        exit(1)
    }
    let restoredAtoms = persistedAtoms(in: restoredData)
    guard restoredAtoms["first-awake-pet-notification-avatar-ids"] as? [String]
        == ["codex", "custom:user-pet"],
        restoredAtoms["avatar-overlay-muted-notification-ids-v1"] as? [String]
        == ["local:local:already-muted", "local:local:user-choice"]
    else {
        fputs("native notification restore did not preserve user values\n", stderr)
        exit(1)
    }

    let testDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("threadhelm-native-state-\(UUID().uuidString)", isDirectory: true)
    let stateURL = testDirectory.appendingPathComponent("state.json")
    let sessionIndexURL = testDirectory.appendingPathComponent("session_index.jsonl")
    let backupURL = testDirectory.appendingPathComponent("backup.json")
    do {
        try FileManager.default.createDirectory(
            at: testDirectory,
            withIntermediateDirectories: true
        )
        try initialData.write(to: stateURL)
        try sessionIndex?.write(to: sessionIndexURL)
        var relaunchCancellationObserved = false
        do {
            try CodexOverlayNotificationState.prepareFiles(
                stateURL: stateURL,
                sessionIndexURL: sessionIndexURL,
                backupURL: backupURL,
                canWrite: { false }
            )
        } catch {
            relaunchCancellationObserved = true
        }
        guard relaunchCancellationObserved,
              try Data(contentsOf: stateURL) == initialData,
              !FileManager.default.fileExists(atPath: backupURL.path)
        else {
            fputs("native notification relaunch guard wrote state\n", stderr)
            exit(1)
        }

        var writeBoundaryCancellationObserved = false
        var writeBoundaryCheckCount = 0
        do {
            try CodexOverlayNotificationState.prepareFiles(
                stateURL: stateURL,
                sessionIndexURL: sessionIndexURL,
                backupURL: backupURL,
                canWrite: {
                    writeBoundaryCheckCount += 1
                    return writeBoundaryCheckCount < 3
                }
            )
        } catch {
            writeBoundaryCancellationObserved = true
        }
        guard writeBoundaryCancellationObserved,
              writeBoundaryCheckCount == 3,
              try Data(contentsOf: stateURL) == initialData,
              !FileManager.default.fileExists(atPath: backupURL.path)
        else {
            fputs("native notification partial write did not roll back backup\n", stderr)
            exit(1)
        }

        let externallyChangedData = Data(#"{"external-write":true}"#.utf8)
        var snapshotChangeCancellationObserved = false
        var snapshotBoundaryCheckCount = 0
        do {
            try CodexOverlayNotificationState.prepareFiles(
                stateURL: stateURL,
                sessionIndexURL: sessionIndexURL,
                backupURL: backupURL,
                canWrite: {
                    snapshotBoundaryCheckCount += 1
                    if snapshotBoundaryCheckCount == 1 {
                        try! externallyChangedData.write(to: stateURL, options: .atomic)
                    }
                    return true
                }
            )
        } catch {
            snapshotChangeCancellationObserved = true
        }
        guard snapshotChangeCancellationObserved,
              try Data(contentsOf: stateURL) == externallyChangedData,
              !FileManager.default.fileExists(atPath: backupURL.path)
        else {
            fputs("native notification changed snapshot was overwritten\n", stderr)
            exit(1)
        }
        try initialData.write(to: stateURL, options: .atomic)

        let firstFilePreparationChanged = try CodexOverlayNotificationState.prepareFiles(
            stateURL: stateURL,
            sessionIndexURL: sessionIndexURL,
            backupURL: backupURL
        )
        let filePreparedAtoms = persistedAtoms(in: try Data(contentsOf: stateURL))
        guard firstFilePreparationChanged,
              FileManager.default.fileExists(atPath: backupURL.path),
              filePreparedAtoms["first-awake-pet-notification-avatar-ids"] as? [String]
                == ["codex"]
        else {
            fputs("native notification file prepare did not persist state\n", stderr)
            exit(1)
        }

        var exitRoot = initialState
        var exitAtoms = exitRoot["electron-persisted-atom-state"] as! [String: Any]
        exitAtoms["thread-client-id-v1:local%3Alate-state-thread"] = "client-late"
        exitRoot["electron-persisted-atom-state"] = exitAtoms
        try JSONSerialization.data(withJSONObject: exitRoot).write(to: stateURL)
        try """
        {"id":"indexed-thread"}
        {"id":"late-index-thread"}
        """.data(using: .utf8)!.write(to: sessionIndexURL)

        let exitRepairChanged = try CodexOverlayNotificationState.prepareFiles(
            stateURL: stateURL,
            sessionIndexURL: sessionIndexURL,
            backupURL: backupURL
        )
        let repairedStateData = try Data(contentsOf: stateURL)
        let repairedBackupData = try Data(contentsOf: backupURL)
        let repairedAtoms = persistedAtoms(in: repairedStateData)
        let repairedMuted = repairedAtoms[
            "avatar-overlay-muted-notification-ids-v1"
        ] as? [String]
        guard exitRepairChanged,
              repairedMuted?.contains("local:local:already-muted") == true,
              repairedMuted?.contains("local:local:indexed-thread") == true,
              repairedMuted?.contains("local:local:late-index-thread") == true,
              repairedMuted?.contains("local:local:late-state-thread") == true
        else {
            fputs("native notification exit repair missed late thread IDs\n", stderr)
            exit(1)
        }

        let idempotentPreparationChanged = try CodexOverlayNotificationState.prepareFiles(
            stateURL: stateURL,
            sessionIndexURL: sessionIndexURL,
            backupURL: backupURL
        )
        guard !idempotentPreparationChanged,
              try Data(contentsOf: stateURL) == repairedStateData,
              try Data(contentsOf: backupURL) == repairedBackupData
        else {
            fputs("native notification exit repair was not idempotent\n", stderr)
            exit(1)
        }

        var restoreCancellationObserved = false
        do {
            try CodexOverlayNotificationState.restoreFiles(
                stateURL: stateURL,
                backupURL: backupURL,
                canWrite: { false }
            )
        } catch {
            restoreCancellationObserved = true
        }
        guard restoreCancellationObserved,
              try Data(contentsOf: stateURL) == repairedStateData,
              try Data(contentsOf: backupURL) == repairedBackupData
        else {
            fputs("native notification active-Codex restore changed files\n", stderr)
            exit(1)
        }

        try CodexOverlayNotificationState.restoreFiles(
            stateURL: stateURL,
            backupURL: backupURL
        )
        let fileRestoredAtoms = persistedAtoms(in: try Data(contentsOf: stateURL))
        guard !FileManager.default.fileExists(atPath: backupURL.path),
              fileRestoredAtoms[
                  "first-awake-pet-notification-avatar-ids"
              ] as? [String] == ["codex"],
              fileRestoredAtoms[
                  "avatar-overlay-muted-notification-ids-v1"
              ] as? [String] == ["local:local:already-muted"]
        else {
            fputs("native notification file restore retained its backup\n", stderr)
            exit(1)
        }
    } catch {
        fputs("native notification file lifecycle failed: \(error)\n", stderr)
        try? FileManager.default.removeItem(at: testDirectory)
        exit(1)
    }
    try? FileManager.default.removeItem(at: testDirectory)

    print(
        "native-notification-state-self-test: "
            + "prepare=pass reinstall=pass restore=pass "
            + "file-lifecycle=pass user-values=preserved "
            + "live-monitor=pass "
            + "deferred-sync=pass stable-exit=pass relaunch-guard=pass retry=pass "
            + "snapshot-guard=pass transaction-rollback=pass restore-guard=pass "
            + "late-threads=pass idempotent=pass"
    )
    exit(0)
}
