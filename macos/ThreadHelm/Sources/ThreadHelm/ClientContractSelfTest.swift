//
//  ClientContractSelfTest.swift
//  ThreadHelm
//
//  模块职责：--self-test-client-contract 自测——锁定 Codex app-server
//  rateLimits 响应中的重置额度契约，避免回退到直接读取登录令牌。
//

import AppKit
import Darwin
import Foundation

func runClientContractSelfTest() -> Never {
    runAgentTransportSelfTest()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let expiresAt = Int64(now.addingTimeInterval(3_600).timeIntervalSince1970)
    let payload = """
    {
      "rateLimits": {
        "limitId": "codex",
        "primary": {
          "usedPercent": 25,
          "windowDurationMins": 10080,
          "resetsAt": 1800600000
        }
      },
      "rateLimitResetCredits": {
        "availableCount": 2,
        "credits": [
          {
            "id": "credit-active",
            "status": "available",
            "expiresAt": \(expiresAt),
            "grantedAt": 1799990000,
            "resetType": "codexRateLimits"
          }
        ]
      }
    }
    """

    guard let data = payload.data(using: .utf8),
          let response = try? JSONDecoder().decode(RateLimitsResult.self, from: data),
          let snapshot = makeCodexResetCreditsSnapshot(from: response, now: now),
          snapshot.reportedAvailableCount == 2,
          snapshot.availableCredits(at: now).map(\.id) == ["credit-active"],
          snapshot.credits.first?.expiresAt
              == Date(timeIntervalSince1970: TimeInterval(expiresAt))
    else {
        fputs("Codex app-server reset-credit decoding failed\n", stderr)
        exit(1)
    }

    let fakeHome = URL(fileURLWithPath: "/tmp/threadhelm-client-contract-home")
    let codexURL = locateCodexExecutable(
        environment: ["PATH": "/custom/bin:/secondary/bin"],
        homeDirectory: fakeHome,
        isExecutableFile: { $0 == "/secondary/bin/codex" }
    )
    let claudeURL = locateClaudeExecutable(
        environment: ["PATH": "/custom/bin:/secondary/bin"],
        homeDirectory: fakeHome,
        isExecutableFile: { $0 == "/custom/bin/claude" }
    )
    guard codexURL?.path == "/secondary/bin/codex",
          claudeURL?.path == "/custom/bin/claude"
    else {
        fputs("CLI PATH discovery failed\n", stderr)
        exit(1)
    }

    guard runBoundedProcessCaptureSelfTest() else {
        fputs("bounded process capture failed\n", stderr)
        exit(1)
    }
    guard runCodexQuotaEnvironmentSelfTest() else {
        fputs("Codex quota process environment failed\n", stderr)
        exit(1)
    }
    guard runCodexQuotaTimeoutSelfTest() else {
        fputs("Codex quota timeout completion failed\n", stderr)
        exit(1)
    }

    let countOnlyPayload = """
    {
      "rateLimits": {
        "primary": {
          "usedPercent": 25,
          "windowDurationMins": 10080
        }
      },
      "rateLimitResetCredits": {
        "availableCount": 3,
        "credits": null
      }
    }
    """
    guard let countOnlyData = countOnlyPayload.data(using: .utf8),
          let countOnlyResponse = try? JSONDecoder().decode(
              RateLimitsResult.self,
              from: countOnlyData
          ),
          let countOnlySnapshot = makeCodexResetCreditsSnapshot(
              from: countOnlyResponse,
              now: now
          )
    else {
        fputs("count-only reset-credit decoding failed\n", stderr)
        exit(1)
    }
    let countOnlyPresentation = codexResetCreditsPresentation(
        snapshot: countOnlySnapshot,
        now: now
    )
    guard countOnlyPresentation.availableText == "3 次可用",
          countOnlyPresentation.hasAvailableCredits,
          countOnlyPresentation.expiryLines.isEmpty
    else {
        fputs("count-only reset-credit presentation failed\n", stderr)
        exit(1)
    }

    print(
        "client-contract-self-test: agent-transport=64KiB+250ms+metadata-only+fail-open "
        + "app-server-reset-credits=pass path-discovery=codex+claude "
            + "count-only-credits=pass process-timeout=term+kill "
            + "inherited-pipe=nonblocking codex-environment=supplemented "
            + "codex-timeout=completion"
    )
    exit(0)
}

private func runCodexQuotaEnvironmentSelfTest() -> Bool {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "threadhelm-codex-environment-\(UUID().uuidString)",
        isDirectory: true
    )
    let executable = directory.appendingPathComponent("codex")
    let capturedPathFile = directory.appendingPathComponent("path.txt")
    let fakeHome = directory.appendingPathComponent("home", isDirectory: true)
    let interpreterDirectory = fakeHome.appendingPathComponent(
        ".local/bin",
        isDirectory: true
    )
    let interpreter = interpreterDirectory.appendingPathComponent(
        "threadhelm-test-node"
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        try FileManager.default.createDirectory(
            at: interpreterDirectory,
            withIntermediateDirectories: true
        )
        try Data(
            "#!/usr/bin/env threadhelm-test-node\n".utf8
        ).write(to: executable)
        try Data(
            """
            #!/bin/sh
            printf '%s' "$PATH" > "$THREADHELM_PATH_CAPTURE"
            IFS= read -r _
            printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
            IFS= read -r _
            IFS= read -r _
            printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":10080}}}}'
            """.utf8
        ).write(to: interpreter)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: interpreter.path
        )
    } catch {
        return false
    }

    let basePath = "/usr/bin:/bin:/usr/sbin:/sbin"
    let environment = supplementedExecutableEnvironment(
        base: [
            "PATH": basePath,
            "THREADHELM_PATH_CAPTURE": capturedPathFile.path,
        ],
        homeDirectory: fakeHome
    )
    let completion = DispatchSemaphore(value: 0)
    var result: Result<RateLimitsResult, Error>?
    CodexQuotaClient(
        executableLocator: { executable },
        timeout: 3,
        processEnvironment: environment
    ).fetch {
        result = $0
        completion.signal()
    }
    guard completion.wait(timeout: .now() + 5) == .success,
          case .success(let response) = result,
          response.rateLimits.primary?.usedPercent == 25,
          let capturedPath = try? String(contentsOf: capturedPathFile),
          capturedPath == [
              basePath,
              "/opt/homebrew/bin",
              "/usr/local/bin",
              fakeHome.appendingPathComponent(".local/bin").path,
          ].joined(separator: ":")
    else {
        return false
    }
    return true
}

private func runCodexQuotaTimeoutSelfTest() -> Bool {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "threadhelm-codex-timeout-\(UUID().uuidString)",
        isDirectory: true
    )
    let executable = directory.appendingPathComponent("codex")
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data(
            "#!/bin/sh\ntrap '' TERM\nexec /bin/sleep 30\n".utf8
        ).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
    } catch {
        return false
    }

    let completion = DispatchSemaphore(value: 0)
    var result: Result<RateLimitsResult, Error>?
    let startedAt = Date()
    CodexQuotaClient(
        executableLocator: { executable },
        timeout: 0.1,
        terminationGracePeriod: 0.1
    ).fetch {
        result = $0
        completion.signal()
    }
    guard completion.wait(timeout: .now() + 1) == .success,
          Date().timeIntervalSince(startedAt) < 1,
          case .failure(let error) = result,
          error.localizedDescription == "Codex 暂未返回额度数据"
    else {
        return false
    }
    return true
}

private func runBoundedProcessCaptureSelfTest() -> Bool {
    let timedOutProcess = Process()
    let timedOutOutput = Pipe()
    timedOutProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
    timedOutProcess.arguments = [
        "-c",
        "trap '' TERM; printf ready; exec /bin/sleep 30",
    ]
    timedOutProcess.standardOutput = timedOutOutput
    timedOutProcess.standardError = FileHandle.nullDevice
    do {
        try timedOutProcess.run()
    } catch {
        return false
    }

    let timeoutStartedAt = Date()
    let timedOutCapture = captureProcessOutput(
        process: timedOutProcess,
        output: timedOutOutput.fileHandleForReading,
        timeout: 0.1,
        terminationGracePeriod: 0.1,
        maximumOutputBytes: 4_096
    )
    guard timedOutCapture.termination == .timedOut,
          timedOutCapture.data == Data("ready".utf8),
          Date().timeIntervalSince(timeoutStartedAt) < 1,
          !timedOutProcess.isRunning
    else {
        if timedOutProcess.isRunning {
            kill(timedOutProcess.processIdentifier, SIGKILL)
        }
        return false
    }

    let inheritedPipeProcess = Process()
    let inheritedPipeOutput = Pipe()
    inheritedPipeProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
    inheritedPipeProcess.arguments = [
        "-c",
        "/bin/sleep 30 & printf '%s' \"$!\"",
    ]
    inheritedPipeProcess.standardOutput = inheritedPipeOutput
    inheritedPipeProcess.standardError = FileHandle.nullDevice
    do {
        try inheritedPipeProcess.run()
    } catch {
        return false
    }

    let inheritedPipeStartedAt = Date()
    let inheritedPipeCapture = captureProcessOutput(
        process: inheritedPipeProcess,
        output: inheritedPipeOutput.fileHandleForReading,
        timeout: 1,
        terminationGracePeriod: 0.1,
        maximumOutputBytes: 4_096
    )
    let childProcessID = String(
        data: inheritedPipeCapture.data,
        encoding: .utf8
    ).flatMap(Int32.init)
    if let childProcessID {
        kill(childProcessID, SIGKILL)
    }
    return inheritedPipeCapture.termination == .exited
        && childProcessID != nil
        && Date().timeIntervalSince(inheritedPipeStartedAt) < 1
}
