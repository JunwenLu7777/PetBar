//
//  ClientContractSelfTest.swift
//  ChatBirdQuotaPanel
//
//  模块职责：--self-test-client-contract 自测——锁定 Codex app-server
//  rateLimits 响应中的重置额度契约，避免回退到直接读取登录令牌。
//

import AppKit
import Foundation

func runClientContractSelfTest() -> Never {
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

    let fakeHome = URL(fileURLWithPath: "/tmp/chatbird-client-contract-home")
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
        "client-contract-self-test: "
            + "app-server-reset-credits=pass path-discovery=codex+claude "
            + "count-only-credits=pass"
    )
    exit(0)
}
