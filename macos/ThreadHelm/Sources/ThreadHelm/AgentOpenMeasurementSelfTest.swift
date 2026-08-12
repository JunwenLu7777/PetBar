//
//  AgentOpenMeasurementSelfTest.swift
//  ThreadHelm
//
//  模块职责：锁定五 Agent 的真实打开报告，以及只含数字的本地计数边界。
//

import Darwin
import Foundation

func runAgentOpenMeasurementSelfTest() {
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-open-measurement-self-test-\(UUID().uuidString)",
        isDirectory: true
    )
    let stateURL = temporaryRoot.appendingPathComponent("open-results.json")
    defer { try? manager.removeItem(at: temporaryRoot) }

    let store = AgentOpenMeasurementStore(
        fileURL: stateURL,
        fileManager: manager
    )
    guard !manager.fileExists(atPath: stateURL.path) else {
        failAgentOpenMeasurementSelfTest("reading zero must not invent evidence")
    }
    for agentID in AgentID.builtInOrder {
        let totals = store.snapshot().totals(for: agentID)
        guard totals.exactAttempts == 0,
              totals.exactSuccesses == 0,
              OpenResult.allCases.allSatisfy({
                  totals.resultCount($0) == 0
              })
        else {
            failAgentOpenMeasurementSelfTest("initial evidence must be zero")
        }
    }

    let codex = AgentOpenReport(
        agentID: .codex,
        advertisedActionability: .openExactNativeSession,
        result: .unknown,
        invokedExactTarget: true,
        independentlyConfirmedIdentity: false
    )
    let claude = AgentOpenReport(
        agentID: .claudeCode,
        advertisedActionability: .openExactNativeSession,
        result: .exactSession,
        invokedExactTarget: true,
        independentlyConfirmedIdentity: true
    )
    let cursor = AgentOpenReport(
        agentID: .cursor,
        advertisedActionability: .openNativeApp,
        result: .appFocused,
        invokedExactTarget: false,
        independentlyConfirmedIdentity: false
    )
    let zcode = AgentOpenReport(
        agentID: .zcode,
        advertisedActionability: .openNativeApp,
        result: .workingDirectoryFallback,
        invokedExactTarget: false,
        independentlyConfirmedIdentity: false
    )
    let pi = AgentOpenReport(
        agentID: .pi,
        advertisedActionability: .viewOnly,
        result: .unavailable,
        invokedExactTarget: false,
        independentlyConfirmedIdentity: false
    )
    let unconfirmedExactClaim = AgentOpenReport(
        agentID: .codex,
        advertisedActionability: .openExactNativeSession,
        result: .exactSession,
        invokedExactTarget: true,
        independentlyConfirmedIdentity: false
    )
    let invalidCursorExactClaim = AgentOpenReport(
        agentID: .cursor,
        advertisedActionability: .openNativeApp,
        result: .exactSession,
        invokedExactTarget: false,
        independentlyConfirmedIdentity: true
    )

    guard codex.exactAttempted,
          !codex.independentlyConfirmedIdentity,
          codex.result == .unknown,
          claude.exactAttempted,
          claude.independentlyConfirmedIdentity,
          claude.result == .exactSession,
          !cursor.exactAttempted,
          !zcode.exactAttempted,
          !pi.exactAttempted,
          unconfirmedExactClaim.result == .unknown,
          !unconfirmedExactClaim.independentlyConfirmedIdentity,
          invalidCursorExactClaim.result == .unknown,
          !invalidCursorExactClaim.exactAttempted,
          !invalidCursorExactClaim.independentlyConfirmedIdentity
    else {
        failAgentOpenMeasurementSelfTest("truthful exact-attempt boundary")
    }

    for report in [codex, claude, cursor, zcode, pi] {
        guard store.record(report) else {
            failAgentOpenMeasurementSelfTest("persist report")
        }
    }

    let reloaded = AgentOpenMeasurementStore(
        fileURL: stateURL,
        fileManager: manager
    ).snapshot()
    guard reloaded.totals(for: .codex).exactAttempts == 1,
          reloaded.totals(for: .codex).exactSuccesses == 0,
          reloaded.totals(for: .codex).resultCount(.unknown) == 1,
          reloaded.totals(for: .claudeCode).exactAttempts == 1,
          reloaded.totals(for: .claudeCode).exactSuccesses == 1,
          reloaded.totals(for: .claudeCode).resultCount(.exactSession) == 1,
          reloaded.totals(for: .cursor).exactAttempts == 0,
          reloaded.totals(for: .cursor).resultCount(.appFocused) == 1,
          reloaded.totals(for: .zcode).exactAttempts == 0,
          reloaded.totals(for: .zcode)
            .resultCount(.workingDirectoryFallback) == 1,
          reloaded.totals(for: .pi).exactAttempts == 0,
          reloaded.totals(for: .pi).resultCount(.unavailable) == 1
    else {
        failAgentOpenMeasurementSelfTest("five-agent persisted totals")
    }

    let permissions = ((try? manager.attributesOfItem(atPath: stateURL.path)[
        .posixPermissions
    ]) as? NSNumber)?.intValue
    guard permissions.map({ $0 & 0o777 }) == 0o600 else {
        failAgentOpenMeasurementSelfTest("owner-only 0600 state file")
    }

    guard let data = try? Data(contentsOf: stateURL),
          agentOpenMeasurementJSONIsCountOnly(data),
          let encoded = String(data: data, encoding: .utf8),
          !encoded.contains("title"),
          !encoded.contains("path"),
          !encoded.contains("session"),
          !encoded.contains("thread"),
          !encoded.contains("timeline")
    else {
        failAgentOpenMeasurementSelfTest("count-only privacy schema")
    }
}

private func agentOpenMeasurementJSONIsCountOnly(_ data: Data) -> Bool {
    guard let root = try? JSONSerialization.jsonObject(with: data)
        as? [String: Any],
          Set(root.keys) == Set(["schemaVersion", "agents"]),
          root["schemaVersion"] as? Int == 1,
          let agents = root["agents"] as? [String: Any],
          Set(agents.keys) == Set(AgentID.builtInOrder.map(\.rawValue))
    else { return false }

    let allowedResults = Set(OpenResult.allCases.map(\.rawValue))
    for value in agents.values {
        guard let totals = value as? [String: Any],
              Set(totals.keys) == Set([
                  "results", "exactAttempts", "exactSuccesses",
              ]),
              let results = totals["results"] as? [String: Any],
              Set(results.keys).isSubset(of: allowedResults),
              isNonnegativeInteger(totals["exactAttempts"]),
              isNonnegativeInteger(totals["exactSuccesses"]),
              results.values.allSatisfy(isNonnegativeInteger)
        else { return false }
    }
    return true
}

private func isNonnegativeInteger(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber else { return false }
    let integer = number.intValue
    return integer >= 0 && number.doubleValue == Double(integer)
}

private func failAgentOpenMeasurementSelfTest(_ reason: String) -> Never {
    fputs("agent open measurement self-test failed: \(reason)\n", stderr)
    exit(1)
}
