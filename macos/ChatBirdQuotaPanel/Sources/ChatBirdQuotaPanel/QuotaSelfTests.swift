//
//  QuotaSelfTests.swift
//  ChatBirdQuotaPanel
//
//  模块职责：额度相关自测——--self-test-chatbird-edition（宠物选择持久化）、
//  --self-test-weekly-quota（周额度窗口选择/阈值/重置额度/失败文案）、
//  --self-test-claude-quota（Claude 解析器/提供者切换/可执行文件定位/
//  任务来源过滤）。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

func runChatBirdEditionSelfTest() -> Never {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("chatbird-edition-\(UUID().uuidString)", isDirectory: true)
    let config = directory.appendingPathComponent("config.toml")
    defer { try? FileManager.default.removeItem(at: directory) }

    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let initial = """
        selected-avatar-id = "codex"
        [general]
        model = "gpt"
        [desktop]
        avatar-overlay-mascot-width-px = 163
        selected-avatar-id = "custom:old-pet"
        [features]
        test = true
        """
        try initial.data(using: .utf8)?.write(to: config, options: .atomic)
        let store = ChatBirdPetSelectionStore(configURL: config)
        guard store.selectChatBird(), store.chatBirdIsSelected() else {
            throw NSError(domain: "ChatBirdEditionSelfTest", code: 1)
        }
        let chatBirdText = try String(contentsOf: config, encoding: .utf8)
        guard chatBirdText.components(separatedBy: "selected-avatar-id").count - 1 == 1,
              chatBirdText.contains("selected-avatar-id = \"custom:chatbird-nt\"")
        else {
            throw NSError(domain: "ChatBirdEditionSelfTest", code: 2)
        }
        let missingDesktop = ChatBirdPetSelectionStore.updatingDesktopSelection(
            in: "[general]\nmodel = \"gpt\"\n",
            avatarID: chatBirdPetAvatarID
        )
        guard missingDesktop.contains("[desktop]\nselected-avatar-id = \"custom:chatbird-nt\"") else {
            throw NSError(domain: "ChatBirdEditionSelfTest", code: 3)
        }
    } catch {
        fputs("ChatBird edition self-test failed: \(error)\n", stderr)
        exit(1)
    }

    print("chatbird-edition-self-test: edition=chatbird-nt pet=chatbird-nt persistence=pass duplicate-key=pass")
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
          weeklyResetStatus == "8月7日 08:59 重置 · 1分钟",
          missingResetStatus == "10:38 更新 · 1分钟",
          claudeStatus == "10:38 更新 · 1分钟",
          refreshInterval == 60
    else {
        fputs("weekly quota self-test failed\n", stderr)
        exit(1)
    }
    print("weekly-quota-self-test: legacy-secondary=pass current-primary=pass retired-short-window=ignored metadata-free=ignored spend-control=ignored thresholds=7/7 reset-credits=available-only weekly-reset-status=dated+fallback failure-copy=pass stale-row=preserved refresh=60s")
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
    let authenticationFixture = """
    Claude Code is not logged in.
    Run /login to continue.
    """
    _ = NSApplication.shared
    let providerView = QuotaPanelView(
        frame: NSRect(origin: .zero, size: panelSizeForTaskRows(1))
    )
    let providerWindow = NSWindow(
        contentRect: providerView.frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    providerWindow.contentView = providerView
    providerView.pointerSide = .bottom
    var clickedProvider: QuotaProvider?
    providerView.onSelectQuotaProvider = { clickedProvider = $0 }
    providerView.availableQuotaProviders = [.codex]
    let providerPointInWindow = providerView.convert(
        NSPoint(x: 135, y: 20),
        to: nil
    )
    if let event = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: providerPointInWindow,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: providerWindow.windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 1
    ) {
        providerView.mouseDown(with: event)
        guard clickedProvider == nil else {
            fputs("hidden Claude provider accepted a click\n", stderr)
            exit(1)
        }
        providerView.availableQuotaProviders = QuotaProvider.allCases
        providerView.mouseDown(with: event)
    }

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
        claudeCodeAvailable: false
    )
    let combinedTasks = combinedTaskProgressItems(
        codexItems: [codexTask],
        claudeItems: [claudeTask],
        claudeCodeAvailable: true
    )
    guard let remaining = try? ClaudeQuotaParser.parse(remainingFixture),
          let used = try? ClaudeQuotaParser.parse(usedFixture),
          let withoutFable = try? ClaudeQuotaParser.parse(withoutFableFixture),
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
          combinedTasks.map(\.source) == [.codex, .claudeCode],
          clickedProvider == .claudeCode
    else {
        fputs("claude quota self-test failed\n", stderr)
        exit(1)
    }

    print("claude-quota-self-test: left-percent=3/3 used-percent=3/3 windows=5h+weekly+fable legacy-without-fable=pass provider-buttons=2/2 click-hit=pass provider-visibility=installed+hidden fallback=pass auth-copy=pass locator=custom+missing task-filter=pass")
    exit(0)
}
