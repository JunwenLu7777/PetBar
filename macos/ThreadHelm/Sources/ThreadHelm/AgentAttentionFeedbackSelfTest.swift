//
//  AgentAttentionFeedbackSelfTest.swift
//  ThreadHelm
//
//  模块职责：锁定只含数字和有限分类的本地注意力反馈存储与诊断入口。
//

import Darwin
import Foundation

func runAgentAttentionFeedbackSelfTest() {
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-attention-feedback-self-test-\(UUID().uuidString)",
        isDirectory: true
    )
    let stateURL = temporaryRoot.appendingPathComponent("feedback.json")
    defer { try? manager.removeItem(at: temporaryRoot) }

    let store = AgentAttentionFeedbackStore(
        fileURL: stateURL,
        fileManager: manager
    )
    guard !manager.fileExists(atPath: stateURL.path),
          AgentID.builtInOrder.allSatisfy({ agentID in
              let totals = store.snapshot().totals(for: agentID)
              return totals.rawCount == 0
                  && AgentAttentionFeedback.allCases.allSatisfy({
                      totals.count($0) == 0
                  })
          })
    else {
        failAgentAttentionFeedbackSelfTest("zero evidence must stay in memory")
    }

    let ratings: [(AgentID, AgentAttentionFeedback)] = [
        (.codex, .useful),
        (.claudeCode, .unnecessary),
        (.cursor, .wrongState),
        (.zcode, .wrongSession),
    ]
    for (agentID, rating) in ratings {
        guard store.record(agentID: agentID, feedback: rating) else {
            failAgentAttentionFeedbackSelfTest("persist bounded feedback")
        }
    }
    guard !store.record(
        agentID: AgentID(rawValue: "third-party"),
        feedback: .useful
    ) else {
        failAgentAttentionFeedbackSelfTest("reject unregistered agent")
    }

    let reloaded = AgentAttentionFeedbackStore(
        fileURL: stateURL,
        fileManager: manager
    )
    let snapshot = reloaded.snapshot()
    guard snapshot.rawCount == 4,
          snapshot.totals(for: .codex).count(.useful) == 1,
          snapshot.totals(for: .claudeCode).count(.unnecessary) == 1,
          snapshot.totals(for: .cursor).count(.wrongState) == 1,
          snapshot.totals(for: .zcode).count(.wrongSession) == 1,
          snapshot.totals(for: .pi).rawCount == 0,
          attentionFeedbackDiagnosticText(snapshot).contains("样本不足"),
          attentionFeedbackDiagnosticText(snapshot).contains("codex 1"),
          attentionFeedbackDiagnosticText(snapshot).contains("pi 0")
    else {
        failAgentAttentionFeedbackSelfTest("raw local totals")
    }

    for _ in 0..<16 {
        guard reloaded.record(agentID: .codex, feedback: .useful) else {
            failAgentAttentionFeedbackSelfTest("reach diagnostic sample")
        }
    }
    let rated = reloaded.snapshot()
    let diagnostic = attentionFeedbackDiagnosticText(rated)
    guard rated.rawCount == 20,
          rated.count(.useful) == 17,
          diagnostic.contains("值得打扰 85%"),
          diagnostic.contains("不必要 5%"),
          diagnostic.contains("总计 20")
    else {
        failAgentAttentionFeedbackSelfTest("diagnostic threshold and raw count")
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
        failAgentAttentionFeedbackSelfTest("owner-only 0700/0600 feedback")
    }

    guard let data = try? Data(contentsOf: stateURL),
          agentAttentionFeedbackJSONIsCountOnly(data)
    else {
        failAgentAttentionFeedbackSelfTest("count-only privacy schema")
    }

    guard parseAgentAttentionFeedbackCLI([
        "ThreadHelm", "--print-attention-feedback",
    ]) == .printSnapshot,
          parseAgentAttentionFeedbackCLI([
              "ThreadHelm", "--record-attention-feedback", "cursor",
              "wrongState",
          ]) == .record(agentID: .cursor, feedback: .wrongState),
          parseAgentAttentionFeedbackCLI([
              "ThreadHelm", "--record-attention-feedback", "cursor",
              "free-form-text",
          ]) == .invalid,
          parseAgentAttentionFeedbackCLI([
              "ThreadHelm", "--print-quota",
          ]) == .notRequested
    else {
        failAgentAttentionFeedbackSelfTest("bounded diagnostics CLI")
    }
}

private func agentAttentionFeedbackJSONIsCountOnly(_ data: Data) -> Bool {
    guard let root = try? JSONSerialization.jsonObject(with: data)
        as? [String: Any],
          Set(root.keys) == Set(["schemaVersion", "agents"]),
          root["schemaVersion"] as? Int == 1,
          let agents = root["agents"] as? [String: Any],
          Set(agents.keys) == Set(AgentID.builtInOrder.map(\.rawValue))
    else { return false }

    let allowed = Set(AgentAttentionFeedback.allCases.map(\.rawValue))
    for value in agents.values {
        guard let totals = value as? [String: Any],
              Set(totals.keys) == Set(["ratings"]),
              let ratings = totals["ratings"] as? [String: Any],
              Set(ratings.keys).isSubset(of: allowed),
              ratings.values.allSatisfy(attentionFeedbackValueIsCount)
        else { return false }
    }
    return true
}

private func attentionFeedbackValueIsCount(_ value: Any) -> Bool {
    guard let number = value as? NSNumber else { return false }
    let integer = number.intValue
    return integer >= 0 && number.doubleValue == Double(integer)
}

private func failAgentAttentionFeedbackSelfTest(_ reason: String) -> Never {
    fputs("agent attention feedback self-test failed: \(reason)\n", stderr)
    exit(1)
}
