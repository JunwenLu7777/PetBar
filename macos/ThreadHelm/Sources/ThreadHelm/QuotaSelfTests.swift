//
//  QuotaSelfTests.swift
//  ThreadHelm
//
//  模块职责：额度相关自测——--self-test-threadhelm-edition（独立 App 身份）、
//  --self-test-weekly-quota（周额度窗口选择/阈值/重置额度/失败文案）、
//  --self-test-claude-quota（Claude 解析器/提供者切换/可执行文件定位/
//  任务来源过滤）。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

func runThreadHelmEditionSelfTest() -> Never {
    guard threadHelmBundleIdentifier == "dev.threadhelm.app",
          threadHelmLaunchAgentLabel == threadHelmBundleIdentifier,
          legacyThreadHelmBundleIdentifiers == [
              "dev.chatbird.app",
              "dev.chatbird.codex-quota-panel",
          ],
          panelEdition == "threadhelm",
          threadHelmProductID == "threadhelm"
    else {
        fputs("ThreadHelm edition identity self-test failed\n", stderr)
        exit(1)
    }

    print("threadhelm-edition-self-test: edition=threadhelm app-id=dev.threadhelm.app product=standalone")
    exit(0)
}

func runWeeklyQuotaSelfTest() -> Never {
    let legacy = RateLimitSnapshot(
        limitId: "codex",
        limitName: "Codex",
        primary: RateLimitWindow(
            usedPercent: 19,
            windowDurationMins: 300,
            resetsAt: 1_800_000_000
        ),
        secondary: RateLimitWindow(
            usedPercent: 42,
            windowDurationMins: 10_080,
            resetsAt: 1_800_604_800
        ),
        individualLimit: nil
    )
    let current = RateLimitSnapshot(
        limitId: "codex",
        limitName: "Codex",
        primary: RateLimitWindow(
            usedPercent: 25,
            windowDurationMins: 10_080,
            resetsAt: 1_800_604_800
        ),
        secondary: nil,
        individualLimit: nil
    )
    let retiredShortOnly = RateLimitSnapshot(
        limitId: "codex",
        limitName: "Codex",
        primary: RateLimitWindow(
            usedPercent: 7,
            windowDurationMins: 300,
            resetsAt: 1_800_000_000
        ),
        secondary: nil,
        individualLimit: nil
    )
    let metadataFree = RateLimitSnapshot(
        limitId: "codex",
        limitName: "Codex",
        primary: RateLimitWindow(
            usedPercent: 12,
            windowDurationMins: nil,
            resetsAt: 1_800_604_800
        ),
        secondary: nil,
        individualLimit: nil
    )
    let spendOnly = RateLimitSnapshot(
        limitId: "codex",
        limitName: "Codex",
        primary: nil,
        secondary: nil,
        individualLimit: SpendControlLimit(
            remainingPercent: 93,
            resetsAt: 1_800_604_800
        )
    )
    let upstreamFailure = QuotaClientError.server(
        "failed to fetch codex rate limits: private upstream response"
    )
    let emptyFailurePresentation = quotaFailurePresentation(
        for: upstreamFailure,
        hasExistingRows: false
    )
    let staleFailurePresentation = quotaFailurePresentation(
        for: upstreamFailure,
        hasExistingRows: true
    )
    let resetReferenceDate = Date(timeIntervalSince1970: 1_800_000_000)
    let resetCredits = CodexResetCreditsSnapshot(
        credits: [
            CodexResetCredit(
                id: "active",
                status: .available,
                expiresAt: resetReferenceDate.addingTimeInterval(24 * 60 * 60)
            ),
            CodexResetCredit(
                id: "expired",
                status: .available,
                expiresAt: resetReferenceDate.addingTimeInterval(-60)
            ),
            CodexResetCredit(
                id: "redeemed",
                status: .other("redeemed"),
                expiresAt: resetReferenceDate.addingTimeInterval(2 * 24 * 60 * 60)
            ),
        ],
        reportedAvailableCount: 1,
        updatedAt: resetReferenceDate
    )
    let resetCreditsPresentation = codexResetCreditsPresentation(
        snapshot: resetCredits,
        now: resetReferenceDate
    )
    let legacyResetCreditPayload = """
    {
      "rateLimits": {
        "primary": {
          "usedPercent": 25,
          "windowDurationMins": 10080
        }
      },
      "rateLimitResetCredits": {
        "available_count": 1,
        "credits": [{
          "id": "legacy-iso",
          "status": "available",
          "expires_at": "2027-01-15T08:00:00Z"
        }]
      }
    }
    """
    let legacyResetCreditExpiry = ISO8601DateFormatter().date(
        from: "2027-01-15T08:00:00Z"
    )
    let legacyResetCreditSnapshot = legacyResetCreditPayload.data(using: .utf8)
        .flatMap {
            try? JSONDecoder().decode(RateLimitsResult.self, from: $0)
        }
        .flatMap {
            makeCodexResetCreditsSnapshot(from: $0, now: resetReferenceDate)
        }
    let numericLegacyResetCreditPayload = """
    {
      "rateLimits": {
        "primary": {
          "usedPercent": 25,
          "windowDurationMins": 10080
        }
      },
      "rateLimitResetCredits": {
        "available_count": 1,
        "credits": [{
          "id": "legacy-numeric",
          "status": "available",
          "expires_at": 3600
        }]
      }
    }
    """
    let numericLegacyResetCreditSnapshot = numericLegacyResetCreditPayload.data(
        using: .utf8
    ).flatMap {
        try? JSONDecoder().decode(RateLimitsResult.self, from: $0)
    }.flatMap {
        makeCodexResetCreditsSnapshot(from: $0, now: resetReferenceDate)
    }
    let invalidLegacyResetCreditPayload = """
    {
      "rateLimits": {
        "primary": {
          "usedPercent": 25,
          "windowDurationMins": 10080
        }
      },
      "rateLimitResetCredits": {
        "available_count": 1,
        "credits": [{
          "id": "invalid-legacy",
          "status": "available",
          "expires_at": "not-a-date"
        }]
      }
    }
    """
    let invalidLegacyResetCreditData = Data(invalidLegacyResetCreditPayload.utf8)
    var statusCalendar = Calendar(identifier: .gregorian)
    statusCalendar.timeZone = .current
    let statusUpdatedAt = statusCalendar.date(from: DateComponents(
        year: 2026,
        month: 7,
        day: 31,
        hour: 10,
        minute: 38
    ))!
    let weeklyResetAt = statusCalendar.date(from: DateComponents(
        year: 2026,
        month: 8,
        day: 7,
        hour: 8,
        minute: 59
    ))!
    let weeklyResetStatus = quotaSuccessStatusText(
        provider: .codex,
        rows: [QuotaRow(
            name: "周额度",
            remainingPercent: 82,
            resetsAt: weeklyResetAt
        )],
        updatedAt: statusUpdatedAt
    )
    let missingResetStatus = quotaSuccessStatusText(
        provider: .codex,
        rows: [QuotaRow(
            name: "周额度",
            remainingPercent: 82,
            resetsAt: nil
        )],
        updatedAt: statusUpdatedAt
    )
    let claudeStatus = quotaSuccessStatusText(
        provider: .claudeCode,
        rows: [QuotaRow(
            name: "周额度",
            remainingPercent: 82,
            resetsAt: weeklyResetAt
        )],
        updatedAt: statusUpdatedAt
    )
    let summaryClearedAfterEmptyRows = quotaProviderRemainingPercents(
        from: [
            .codex: QuotaProviderState(rows: []),
            .claudeCode: QuotaProviderState(rows: [QuotaRow(
                name: "5 小时",
                remainingPercent: 93,
                resetsAt: nil
            )]),
        ]
    )
    let summaryClearedAfterSummarylessRows = quotaProviderRemainingPercents(
        from: [
            .codex: QuotaProviderState(rows: [QuotaRow(
                name: "周额度",
                remainingPercent: 82,
                resetsAt: nil
            )]),
            .claudeCode: QuotaProviderState(rows: [QuotaRow(
                name: "周额度",
                remainingPercent: 91,
                resetsAt: nil
            )]),
        ]
    )
    let cachedQuotaState = QuotaProviderState(
        rows: [QuotaRow(
            name: "周额度",
            remainingPercent: 64,
            resetsAt: resetReferenceDate
        )],
        resetCredits: resetCredits,
        statusText: "12:00 更新",
        errorText: nil,
        updatedAt: resetReferenceDate,
        isRefreshing: true,
        isStale: false
    )
    var priorFailedCachedQuotaState = cachedQuotaState
    priorFailedCachedQuotaState.statusText = "1 分钟后自动重试"
    priorFailedCachedQuotaState.errorText = "额度服务暂不可用"
    priorFailedCachedQuotaState.isRefreshing = false
    priorFailedCachedQuotaState.isStale = true
    let refreshingCachedQuotaState = quotaProviderStateRefreshing(
        priorFailedCachedQuotaState
    )
    let refreshingEmptyQuotaState = quotaProviderStateRefreshing(
        QuotaProviderState(
            statusText: "1 分钟后自动重试",
            errorText: "额度服务暂不可用"
        )
    )
    let failedCachedQuotaState = quotaProviderStateAfterFailure(
        cachedQuotaState,
        error: QuotaClientError.noResponse,
        provider: .codex
    )
    let firstFailureQuotaState = quotaProviderStateAfterFailure(
        QuotaProviderState(isRefreshing: true),
        error: QuotaClientError.noResponse,
        provider: .codex
    )
    let emptySuccessUpdatedAt = resetReferenceDate.addingTimeInterval(60)
    let emptySuccessQuotaState = quotaProviderStateAfterSuccess(
        QuotaProviderState(isRefreshing: true),
        rows: [],
        resetCredits: nil,
        provider: .codex,
        updatedAt: emptySuccessUpdatedAt
    )
    let dynamicIslandRefreshingPhaseState = QuotaProviderState(
        rows: [QuotaRow(
            name: "周额度",
            remainingPercent: 64,
            resetsAt: resetReferenceDate
        )],
        resetCredits: resetCredits,
        statusText: "正在更新…",
        errorText: nil,
        updatedAt: resetReferenceDate,
        isRefreshing: true,
        isStale: false
    )
    let dynamicIslandStalePhaseState = QuotaProviderState(
        rows: dynamicIslandRefreshingPhaseState.rows,
        resetCredits: resetCredits,
        statusText: "1 分钟后自动重试",
        errorText: nil,
        updatedAt: resetReferenceDate,
        isRefreshing: false,
        isStale: true
    )
    let dynamicIslandErrorStalePhaseState = QuotaProviderState(
        rows: dynamicIslandRefreshingPhaseState.rows,
        resetCredits: nil,
        statusText: "1 分钟后自动重试",
        errorText: "额度服务暂不可用",
        updatedAt: resetReferenceDate,
        isRefreshing: false,
        isStale: false
    )
    let dynamicIslandFirstFailurePhaseState = QuotaProviderState(
        rows: [],
        resetCredits: nil,
        statusText: "1 分钟后自动重试",
        errorText: "额度服务暂不可用",
        updatedAt: nil,
        isRefreshing: false,
        isStale: false
    )
    let dynamicIslandEmptyCurrentPhaseState = QuotaProviderState(
        rows: [],
        resetCredits: nil,
        statusText: "没有可确认的额度数据",
        errorText: nil,
        updatedAt: emptySuccessUpdatedAt,
        isRefreshing: false,
        isStale: false
    )

    guard weeklyRateLimitWindow(from: legacy)?.usedPercent == 42,
          weeklyRateLimitWindow(from: current)?.usedPercent == 25,
          weeklyRateLimitWindow(from: retiredShortOnly) == nil,
          weeklyRateLimitWindow(from: metadataFree) == nil,
          weeklyRateLimitWindow(from: spendOnly) == nil,
          quotaLevel(for: 100) == .healthy,
          quotaLevel(for: 50) == .healthy,
          quotaLevel(for: 49) == .warning,
          quotaLevel(for: 20) == .warning,
          quotaLevel(for: 19) == .critical,
          quotaLevel(for: 1) == .critical,
          quotaLevel(for: 0) == .exhausted,
          emptyFailurePresentation.errorText == "额度服务暂不可用",
          emptyFailurePresentation.statusText == "1 分钟后自动重试",
          staleFailurePresentation.errorText == nil,
          staleFailurePresentation.statusText == "1 分钟后自动重试",
          resetCredits.availableCredits(at: resetReferenceDate).map(\.id) == ["active"],
          resetCreditsPresentation.availableText == "1 次可用",
          resetCreditsPresentation.hasAvailableCredits,
          resetCreditsPresentation.expiryLines.count == 1,
          legacyResetCreditSnapshot?.reportedAvailableCount == 1,
          legacyResetCreditSnapshot?.credits.first?.id == "legacy-iso",
          legacyResetCreditSnapshot?.credits.first?.expiresAt == legacyResetCreditExpiry,
          numericLegacyResetCreditSnapshot?.credits.first?.expiresAt
              == Date(timeIntervalSinceReferenceDate: 3600),
          (try? JSONDecoder().decode(
              RateLimitsResult.self,
              from: invalidLegacyResetCreditData
          )) == nil,
          weeklyResetStatus == "8月7日 08:59 重置 · 1分钟",
          missingResetStatus == "10:38 更新 · 1分钟",
          claudeStatus == "10:38 更新 · 1分钟",
          summaryClearedAfterEmptyRows == [.claudeCode: 93],
          summaryClearedAfterSummarylessRows == [.codex: 82],
          refreshingCachedQuotaState.rows == priorFailedCachedQuotaState.rows,
          refreshingCachedQuotaState.resetCredits == resetCredits,
          refreshingCachedQuotaState.updatedAt == resetReferenceDate,
          refreshingCachedQuotaState.statusText == "正在更新…",
          refreshingCachedQuotaState.errorText == nil,
          refreshingCachedQuotaState.isRefreshing,
          refreshingCachedQuotaState.isStale,
          refreshingEmptyQuotaState.rows.isEmpty,
          refreshingEmptyQuotaState.resetCredits == nil,
          refreshingEmptyQuotaState.updatedAt == nil,
          refreshingEmptyQuotaState.statusText == "正在读取额度…",
          refreshingEmptyQuotaState.errorText == nil,
          refreshingEmptyQuotaState.isRefreshing,
          !refreshingEmptyQuotaState.isStale,
          failedCachedQuotaState.rows == cachedQuotaState.rows,
          failedCachedQuotaState.resetCredits == resetCredits,
          failedCachedQuotaState.updatedAt == cachedQuotaState.updatedAt,
          failedCachedQuotaState.errorText == nil,
          failedCachedQuotaState.statusText == "1 分钟后自动重试",
          failedCachedQuotaState.isStale,
          !failedCachedQuotaState.isRefreshing,
          firstFailureQuotaState.rows.isEmpty,
          firstFailureQuotaState.resetCredits == nil,
          firstFailureQuotaState.errorText == "额度服务暂不可用",
          firstFailureQuotaState.statusText == "1 分钟后自动重试",
          !firstFailureQuotaState.isStale,
          !firstFailureQuotaState.isRefreshing,
          emptySuccessQuotaState.rows.isEmpty,
          emptySuccessQuotaState.resetCredits == nil,
          emptySuccessQuotaState.updatedAt == emptySuccessUpdatedAt,
          emptySuccessQuotaState.statusText == "没有可确认的额度数据",
          emptySuccessQuotaState.errorText == nil,
          !emptySuccessQuotaState.isStale,
          !emptySuccessQuotaState.isRefreshing,
          dynamicIslandQuotaPhase(
              state: nil,
              providerAvailable: true
          ) == .firstLoad,
          dynamicIslandQuotaPhase(
              state: dynamicIslandRefreshingPhaseState,
              providerAvailable: true
          ) == .refreshing,
          dynamicIslandRefreshingPhaseState.rows
              == [QuotaRow(
                  name: "周额度",
                  remainingPercent: 64,
                  resetsAt: resetReferenceDate
              )],
          dynamicIslandRefreshingPhaseState.resetCredits == resetCredits,
          dynamicIslandQuotaPhase(
              state: dynamicIslandStalePhaseState,
              providerAvailable: true
          ) == .stale,
          dynamicIslandStalePhaseState.resetCredits == resetCredits,
          dynamicIslandQuotaPhase(
              state: dynamicIslandErrorStalePhaseState,
              providerAvailable: true
          ) == .stale,
          dynamicIslandQuotaPhase(
              state: dynamicIslandFirstFailurePhaseState,
              providerAvailable: true
          ) == .firstFailure,
          dynamicIslandQuotaPhase(
              state: dynamicIslandEmptyCurrentPhaseState,
              providerAvailable: true
          ) == .current,
          dynamicIslandEmptyCurrentPhaseState.statusText
              == "没有可确认的额度数据",
          dynamicIslandQuotaPhase(
              state: dynamicIslandRefreshingPhaseState,
              providerAvailable: false
          ) == .unavailable,
          refreshInterval == 60
    else {
        fputs("weekly quota self-test failed\n", stderr)
        exit(1)
    }
    print("weekly-quota-self-test: legacy-secondary=pass current-primary=pass retired-short-window=ignored metadata-free=ignored spend-control=ignored thresholds=7/7 reset-credits=available-only stale-reset-credits=preserved legacy-expires-at=iso+date-fallback+invalid-fails weekly-reset-status=dated+fallback failure-copy=pass refresh-start=clears-error+preserves-cache stale-row=preserved empty-success=distinct dynamic-island-phases=6/6 provider-summary-clear=2/2 refresh=60s")
    exit(0)
}

func runClaudeQuotaSelfTest() -> Never {
    let remainingFixture = """
    Settings:  Status  Config  Usage
    Current session
    91% left
    Resets 8:30pm (Asia/Singapore)
    Current week (all models)
    93% left
    Resets Jul 30 at 12pm (Asia/Singapore)
    Current week (Fable)
    97% left
    Resets Jul 30 at 12pm (Asia/Singapore)
    """
    let usedFixture = """
    Settings: Usage
    Current session
    9% used
    Resets 8:30pm
    Current week (all models)
    7% used
    Resets Jul 30 at 12pm
    Current week (Fable)
    3% used
    Resets Jul 30 at 12pm
    """
    let withoutFableFixture = """
    Current session
    9% used
    Resets 8:30pm
    Current week (all models)
    7% used
    Resets Jul 30 at 12pm
    """
    // 非交互式 `claude /usage` 的输出形态：标签、百分比与重置时间同处一行。
    // 这是额度读取的首选路径，格式必须能解析出包含 Fable 的全部三行。
    let nonInteractiveFixture = """
    Settings: Usage
    Current session: 39% used · resets Aug 8 at 9:59pm (Asia/Singapore)
    Current week (all models): 38% used · resets Aug 13 at 11:59am (Asia/Singapore)
    Current week (Fable): 39% used · resets Aug 13 at 11:59am (Asia/Singapore)
    """
    let authenticationFixture = """
    Claude Code is not logged in.
    Run /login to continue.
    """
    let customClaudeURL = locateClaudeExecutable(
        environment: ["CLAUDE_BIN": "/custom/bin/claude"],
        homeDirectory: URL(fileURLWithPath: "/test-home", isDirectory: true),
        isExecutableFile: { $0 == "/custom/bin/claude" }
    )
    let missingClaudeURL = locateClaudeExecutable(
        environment: [:],
        homeDirectory: URL(fileURLWithPath: "/test-home", isDirectory: true),
        isExecutableFile: { _ in false }
    )
    let authenticationPresentation = quotaFailurePresentation(
        for: ClaudeQuotaError.authenticationRequired,
        hasExistingRows: false,
        provider: .claudeCode
    )
    let codexTask = TaskProgressItem(
        title: "Codex task",
        kind: .running,
        source: .codex
    )
    let claudeTask = TaskProgressItem(
        title: "Claude task",
        kind: .running,
        source: .claudeCode
    )
    let codexOnlyTasks = combinedTaskProgressItems(
        codexItems: [codexTask],
        claudeItems: [claudeTask],
        enabledAgentIDs: [.codex]
    )
    let combinedTasks = combinedTaskProgressItems(
        codexItems: [codexTask],
        claudeItems: [claudeTask],
        enabledAgentIDs: [.codex, .claudeCode]
    )
    guard let remaining = try? ClaudeQuotaParser.parse(remainingFixture),
          let used = try? ClaudeQuotaParser.parse(usedFixture),
          let withoutFable = try? ClaudeQuotaParser.parse(withoutFableFixture),
          let nonInteractive = try? ClaudeQuotaParser.parse(nonInteractiveFixture),
          nonInteractive.rows.map(\.name) == ["5 小时", "周额度", "Fable"],
          nonInteractive.rows.map(\.remainingPercent) == [61, 62, 61],
          nonInteractive.rows.allSatisfy({ $0.resetsAt != nil }),
          remaining.rows.map(\.name) == ["5 小时", "周额度", "Fable"],
          remaining.rows.map(\.remainingPercent) == [91, 93, 97],
          used.rows.map(\.remainingPercent) == [91, 93, 97],
          withoutFable.rows.map(\.name) == ["5 小时", "周额度"],
          remaining.rows.allSatisfy({ $0.resetsAt != nil || $0.resetDescription != nil }),
          QuotaProvider.codex.displayName == "Codex",
          QuotaProvider.claudeCode.displayName == "Claude Code",
          QuotaProvider.allCases == [.codex, .claudeCode],
          quotaProviders(claudeCodeAvailable: false) == [.codex],
          quotaProviders(claudeCodeAvailable: true) == [.codex, .claudeCode],
          resolvedQuotaProvider(
              preferred: .claudeCode,
              availableProviders: [.codex]
          ) == .codex,
          resolvedQuotaProvider(
              preferred: .claudeCode,
              availableProviders: QuotaProvider.allCases
          ) == .claudeCode,
          ClaudeQuotaParser.requiresAuthentication(authenticationFixture),
          authenticationPresentation.errorText == "请先登录 Claude Code",
          authenticationPresentation.statusText == "登录后点击刷新",
          customClaudeURL?.path == "/custom/bin/claude",
          missingClaudeURL == nil,
          codexOnlyTasks.map(\.source) == [.codex],
          combinedTasks.map(\.source) == [.codex, .claudeCode]
    else {
        fputs("claude quota self-test failed\n", stderr)
        exit(1)
    }

    print("claude-quota-self-test: left-percent=3/3 used-percent=3/3 non-interactive=3/3 windows=5h+weekly+fable legacy-without-fable=pass provider-availability=installed+hidden fallback=pass auth-copy=pass locator=custom+missing task-filter=pass")
    exit(0)
}
