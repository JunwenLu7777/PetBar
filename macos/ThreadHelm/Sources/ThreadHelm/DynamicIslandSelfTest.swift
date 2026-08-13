import AppKit
import Foundation

private final class ClaudePermissionPresenterSpy: ClaudePermissionPresenting {
    var presentations: [ClaudePermissionPresentation] = []
    var dismissCount = 0

    func present(_ presentation: ClaudePermissionPresentation) {
        presentations.append(presentation)
    }

    func dismiss() {
        dismissCount += 1
    }

    func reposition() {}
}

private final class ClaudePermissionLifetimeProbe {}

private final class DynamicIslandFirstResponderProbe: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private extension Array where Element == NSRect {
    var isNonOverlappingHorizontally: Bool {
        let frames = sorted { $0.minX < $1.minX }
        return zip(frames, frames.dropFirst()).allSatisfy { left, right in
            left.maxX <= right.minX
        }
    }

    var isNonOverlappingVertically: Bool {
        for leftIndex in indices {
            for rightIndex in indices where rightIndex > leftIndex {
                if self[leftIndex].intersects(self[rightIndex]) {
                    return false
                }
            }
        }
        return true
    }
}

private func dynamicIslandMinimumFontSizeForSelfTest(
    in view: NSView,
    excludingButtonTitles: Bool = false
) -> CGFloat {
    let ownFont: CGFloat
    if excludingButtonTitles, view is NSButton {
        ownFont = .greatestFiniteMagnitude
    } else {
        ownFont = (view as? NSControl)?.font?.pointSize ?? .greatestFiniteMagnitude
    }
    return view.subviews.reduce(ownFont) { current, subview in
        min(
            current,
            dynamicIslandMinimumFontSizeForSelfTest(
                in: subview,
                excludingButtonTitles: excludingButtonTitles
            )
        )
    }
}

private func colorMatchesForSelfTest(
    _ color: NSColor,
    red: CGFloat,
    green: CGFloat,
    blue: CGFloat
) -> Bool {
    var actualRed: CGFloat = 0
    var actualGreen: CGFloat = 0
    var actualBlue: CGFloat = 0
    var alpha: CGFloat = 0
    color.getRed(
        &actualRed,
        green: &actualGreen,
        blue: &actualBlue,
        alpha: &alpha
    )
    return abs(actualRed - red) <= 0.002
        && abs(actualGreen - green) <= 0.002
        && abs(actualBlue - blue) <= 0.002
        && abs(alpha - 1) <= 0.002
}

private func providerIconResourceContainsBrandColorForSelfTest(
    provider: QuotaProvider,
    hex: String,
    bundle: Bundle = .main
) -> Bool {
    guard let url = bundle.url(
        forResource: provider.iconResourceName,
        withExtension: "svg"
    ),
          let text = try? String(contentsOf: url, encoding: .utf8)
    else { return false }
    return text.localizedCaseInsensitiveContains(hex)
}

private func assertDynamicIslandCapsulePresentation() {
    let now = Date(timeIntervalSince1970: 10_000)
    let started = now.addingTimeInterval(-185)
    let runningTask = TaskProgressItem(
        title: "Build feature",
        kind: .running,
        startedAt: started,
        updatedAt: now,
        source: .codex,
        activityText: "正在运行测试，推断步骤 3/5，当前 61% 完成"
    )
    let adjacentProgressTask = TaskProgressItem(
        title: "Chinese adjacent progress",
        kind: .running,
        startedAt: started,
        updatedAt: now.addingTimeInterval(-1),
        source: .codex,
        activityText: "中文邻接，当前61%完成，进度3/5，推断步骤3/5"
    )
    let waitingTask = TaskProgressItem(
        title: "Answer Claude",
        kind: .waitingForInput,
        startedAt: started,
        updatedAt: now.addingTimeInterval(1),
        source: .claudeCode,
        activityText: "等待工具授权"
    )
    let failedTask = TaskProgressItem(
        title: "Failed task",
        kind: .failed,
        startedAt: started,
        updatedAt: now.addingTimeInterval(2),
        source: .codex
    )
    let completedTask = TaskProgressItem(
        title: "Completed task",
        kind: .completed,
        startedAt: started,
        updatedAt: now.addingTimeInterval(3),
        source: .claudeCode
    )
    let queueItem = ClaudePermissionQueueItem(
        requestID: UUID(),
        interactionKind: .toolApproval,
        title: "允许 Bash",
        sessionID: nil,
        arrivedAt: started
    )
    let quotaState = QuotaProviderState(
        rows: [QuotaRow(name: "周额度", remainingPercent: 64, resetsAt: nil)],
        resetCredits: nil,
        statusText: "Codex ok",
        errorText: nil,
        updatedAt: now,
        isRefreshing: false,
        isStale: false
    )
    let claudeQuotaState = QuotaProviderState(
        rows: [QuotaRow(name: "5 小时", remainingPercent: 17, resetsAt: nil)],
        resetCredits: nil,
        statusText: "Claude ok",
        errorText: nil,
        updatedAt: now,
        isRefreshing: false,
        isStale: false
    )

    func snapshot(
        items: [TaskProgressItem],
        queue: ClaudePermissionQueueSnapshot = .empty,
        acknowledged: Set<String> = [],
        codexRunning: Bool = true,
        quotaStates: [QuotaProvider: QuotaProviderState]? = nil,
        availableProviders: [QuotaProvider] = QuotaProvider.allCases,
        selectedQuotaProvider: QuotaProvider = .codex
    ) -> ActivityDashboardSnapshot {
        ActivityDashboardSnapshot(
            taskCollection: TaskProgressCollectionSnapshot.displaying(items),
            quotaStates: quotaStates ?? [
                .codex: quotaState,
                .claudeCode: claudeQuotaState,
            ],
            availableProviders: availableProviders,
            selectedQuotaProvider: selectedQuotaProvider,
            permissionQueue: queue,
            acknowledgedTerminalTaskKeys: acknowledged,
            isTaskRefreshing: false,
            codexDesktopRunning: codexRunning
        )
    }

    let queued = dynamicIslandCapsulePresentation(
        snapshot: snapshot(
            items: [runningTask],
            queue: ClaudePermissionQueueSnapshot(
                current: queueItem,
                pending: [queueItem]
            )
        ),
        now: now
    )
    guard queued.title == "允许 Bash",
          queued.statusText == "待确认",
          queued.badgeText == "2",
          queued.preferredTab == .confirmation,
          queued.progressStyle == .waiting,
          queued.accessibilityValue.contains("工具授权"),
          queued.accessibilityValue.contains("Claude Code"),
          queued.accessibilityValue.contains("队列 2 项")
    else {
        fputs("dynamic island capsule queue priority self-test failed\n", stderr)
        exit(1)
    }

    let waiting = dynamicIslandCapsulePresentation(
        snapshot: snapshot(items: [runningTask, waitingTask]),
        now: now
    )
    guard waiting.title == waitingTask.title,
          waiting.statusText == "等待中",
          waiting.progressStyle == .waiting,
          waiting.preferredTab == .tasks
    else {
        fputs("dynamic island capsule waiting priority self-test failed\n", stderr)
        exit(1)
    }

    let running = dynamicIslandCapsulePresentation(
        snapshot: snapshot(items: [runningTask]),
        now: now
    )
    guard running.title == runningTask.title,
          running.statusText == "执行中",
          running.activityText == "正在运行测试",
          running.provider == .codex,
          running.quotaItems.isEmpty,
          dynamicIslandCapsuleContentChoices(for: running)
            == ["正在运行测试", "Build feature"],
          running.progressStyle == .indeterminate,
          running.elapsedText?.hasSuffix(" · 03:05") == true,
          running.accessibilityValue.contains("正在运行测试"),
          running.accessibilityValue.contains("Codex"),
          !running.title.contains("3/5"),
          !running.title.contains("61%"),
          !running.title.contains("推断步骤"),
          !running.statusText.contains("3/5"),
          !running.statusText.contains("61%"),
          !running.statusText.contains("推断步骤"),
          !(running.activityText ?? "").contains("3/5"),
          !(running.activityText ?? "").contains("61%"),
          !(running.activityText ?? "").contains("推断步骤"),
          !running.accessibilityValue.contains("3/5"),
          !running.accessibilityValue.contains("61%"),
          !running.accessibilityValue.contains("%"),
          !running.accessibilityValue.contains("推断步骤")
    else {
        fputs("dynamic island capsule running/no-fake-progress self-test failed\n", stderr)
        exit(1)
    }

    let adjacent = dynamicIslandCapsulePresentation(
        snapshot: snapshot(items: [adjacentProgressTask]),
        now: now
    )
    guard adjacent.title == adjacentProgressTask.title,
          adjacent.statusText == "执行中",
          adjacent.activityText == "中文邻接",
          adjacent.progressStyle == .indeterminate,
          !(adjacent.activityText ?? "").contains("当前61%完成"),
          !(adjacent.activityText ?? "").contains("进度3/5"),
          !(adjacent.activityText ?? "").contains("推断步骤"),
          !adjacent.accessibilityValue.contains("当前61%完成"),
          !adjacent.accessibilityValue.contains("61%"),
          !adjacent.accessibilityValue.contains("进度3/5"),
          !adjacent.accessibilityValue.contains("3/5"),
          !adjacent.accessibilityValue.contains("推断步骤")
    else {
        fputs("dynamic island capsule adjacent fake-progress self-test failed\n", stderr)
        exit(1)
    }

    let failed = dynamicIslandCapsulePresentation(
        snapshot: snapshot(items: [failedTask, completedTask]),
        now: now
    )
    let failedLater = dynamicIslandCapsulePresentation(
        snapshot: snapshot(items: [failedTask, completedTask]),
        now: now.addingTimeInterval(3_600)
    )
    guard failed.title == failedTask.title,
          failed.statusText == "失败",
          failed.progressStyle == .failed,
          failed.elapsedText?.hasSuffix(" · 03:07") == true,
          failedLater.elapsedText == failed.elapsedText
    else {
        fputs("dynamic island capsule failed priority self-test failed\n", stderr)
        exit(1)
    }

    guard let failedKey = terminalTaskAcknowledgementKey(for: failedTask),
          let completedKey = terminalTaskAcknowledgementKey(for: completedTask)
    else {
        exit(1)
    }
    let completed = dynamicIslandCapsulePresentation(
        snapshot: snapshot(
            items: [failedTask, completedTask],
            acknowledged: [failedKey]
        ),
        now: now
    )
    guard completed.title == completedTask.title,
          completed.statusText == "已完成",
          completed.progressStyle == .completed
    else {
        fputs("dynamic island capsule completed priority self-test failed\n", stderr)
        exit(1)
    }

    let idle = dynamicIslandCapsulePresentation(
        snapshot: snapshot(
            items: [failedTask, completedTask],
            acknowledged: [failedKey, completedKey]
        ),
        now: now
    )
    guard idle.title == "ThreadHelm 空闲",
          idle.statusText == "空闲",
          idle.progressStyle == .idle,
          idle.preferredTab == .quota,
          idle.activityText == "GPT 64% · Claude 17%",
          idle.quotaItems.map(\.provider) == [.codex, .claudeCode],
          idle.quotaItems.map(\.label) == ["GPT", "Claude"],
          idle.quotaItems.map(\.remainingPercent) == [64, 17],
          idle.accessibilityValue.contains("GPT 64%"),
          idle.accessibilityValue.contains("Claude 17%")
    else {
        fputs("dynamic island capsule idle quota self-test failed\n", stderr)
        exit(1)
    }

    let partiallyUnavailable = dynamicIslandCapsulePresentation(
        snapshot: snapshot(
            items: [],
            quotaStates: [.codex: quotaState],
            availableProviders: [.codex],
            selectedQuotaProvider: .claudeCode
        ),
        now: now
    )
    guard partiallyUnavailable.activityText == "GPT 64% · Claude --",
          partiallyUnavailable.quotaItems.map(\.remainingPercent) == [64, nil],
          partiallyUnavailable.accessibilityValue.contains("GPT 64%"),
          partiallyUnavailable.accessibilityValue.contains("Claude --")
    else {
        fputs("dynamic island capsule partial quota self-test failed\n", stderr)
        exit(1)
    }

    let fullyUnavailable = dynamicIslandCapsulePresentation(
        snapshot: snapshot(items: [], quotaStates: [:]),
        now: now
    )
    guard fullyUnavailable.activityText == "GPT -- · Claude --",
          fullyUnavailable.quotaItems.map(\.remainingPercent) == [nil, nil],
          fullyUnavailable.accessibilityValue.contains("GPT --"),
          fullyUnavailable.accessibilityValue.contains("Claude --")
    else {
        fputs("dynamic island capsule unavailable quota self-test failed\n", stderr)
        exit(1)
    }

    let exited = dynamicIslandCapsulePresentation(
        snapshot: ActivityDashboardSnapshot(
            taskCollection: TaskProgressCollectionSnapshot.displaying([]),
            quotaStates: [:],
            availableProviders: [],
            selectedQuotaProvider: .codex,
            permissionQueue: .empty,
            acknowledgedTerminalTaskKeys: [],
            isTaskRefreshing: false,
            codexDesktopRunning: false
        ),
        now: now
    )
    guard exited.title == "Codex 已退出",
          exited.statusText == "离线",
          exited.preferredTab == .tasks
    else {
        fputs("dynamic island capsule exited self-test failed\n", stderr)
        exit(1)
    }
}

private func assertDynamicIslandChromeAccessibility() {
    _ = NSApplication.shared
    guard let codexIcon = providerIconImage(for: .codex),
          let claudeIcon = providerIconImage(for: .claudeCode)
    else {
        fputs("dynamic island provider icon load self-test failed\n", stderr)
        exit(1)
    }
    let reloadedCodexIcon = providerIconImage(for: .codex)
    let reloadedClaudeIcon = providerIconImage(for: .claudeCode)
    let providerIconChecks: [(String, Bool)] = [
        ("codex-reload", reloadedCodexIcon != nil
            && reloadedCodexIcon?.accessibilityDescription
                == codexIcon.accessibilityDescription),
        ("claude-reload", reloadedClaudeIcon != nil
            && reloadedClaudeIcon?.accessibilityDescription
                == claudeIcon.accessibilityDescription),
        ("codex-concrete", !codexIcon.isTemplate),
        ("claude-concrete", !claudeIcon.isTemplate),
        ("codex-svg-color", providerIconResourceContainsBrandColorForSelfTest(
            provider: .codex,
            hex: "#10A37F"
        )),
        ("claude-svg-color", providerIconResourceContainsBrandColorForSelfTest(
            provider: .claudeCode,
            hex: "#D97757"
        )),
        ("codex-brand-color", colorMatchesForSelfTest(
            QuotaProvider.codex.brandColor,
            red: 16.0 / 255.0,
            green: 163.0 / 255.0,
            blue: 127.0 / 255.0
        )),
        ("claude-brand-color", colorMatchesForSelfTest(
            QuotaProvider.claudeCode.brandColor,
            red: 217.0 / 255.0,
            green: 119.0 / 255.0,
            blue: 87.0 / 255.0
        )),
    ]
    if let failedCheck = providerIconChecks.first(where: { !$0.1 }) {
        fputs(
            "dynamic island provider icon \(failedCheck.0) self-test failed\n",
            stderr
        )
        exit(1)
    }
    let segmentedProbe = DynamicIslandSegmentedControl(labels: ["一", "二", "三"])
    segmentedProbe.frame = NSRect(x: 0, y: 0, width: 240, height: 32)
    segmentedProbe.layoutSubtreeIfNeeded()
    let segmentedButtons = segmentedProbe.subviews
        .compactMap { $0 as? DynamicIslandButton }
        .sorted { $0.frame.minX < $1.frame.minX }
    let segmentedGaps = zip(segmentedButtons, segmentedButtons.dropFirst()).map {
        $1.frame.minX - $0.frame.maxX
    }
    guard segmentedProbe.layer?.cornerRadius ?? 0 >= 10,
          segmentedButtons.allSatisfy({ ($0.layer?.cornerRadius ?? 0) >= 9 }),
          segmentedGaps.allSatisfy({ $0 >= 4 })
    else {
        fputs("dynamic island rounded spaced controls self-test failed\n", stderr)
        exit(1)
    }
    let root = DynamicIslandRootViewController()
    let now = Date(timeIntervalSince1970: 20_000)
    let runningTask = TaskProgressItem(
        title: "Run tests",
        kind: .running,
        startedAt: now.addingTimeInterval(-30),
        updatedAt: now,
        source: .codex
    )
    let prompt = ClaudePermissionQueueItem(
        requestID: UUID(),
        interactionKind: .askUserQuestion,
        title: "回答问题",
        sessionID: nil,
        arrivedAt: now
    )
    root.apply(
        snapshot: ActivityDashboardSnapshot(
            taskCollection: TaskProgressCollectionSnapshot.displaying([runningTask]),
            quotaStates: [
                .codex: QuotaProviderState(
                    rows: [QuotaRow(name: "周额度", remainingPercent: 55, resetsAt: nil)],
                    resetCredits: nil,
                    statusText: "Codex ok",
                    errorText: nil,
                    updatedAt: now,
                    isRefreshing: true,
                    isStale: false
                )
            ],
            availableProviders: [.codex],
            selectedQuotaProvider: .codex,
            permissionQueue: ClaudePermissionQueueSnapshot(current: prompt),
            acknowledgedTerminalTaskKeys: [],
            isTaskRefreshing: true,
            codexDesktopRunning: true
        ),
        state: .capsule
    )
    let accessibilitySnapshot = root.accessibilitySnapshotForSelfTest()
    let hitTargetSize = root.capsuleHitTargetSizeForSelfTest()
    let capsuleLayout = root.capsuleLayoutSnapshotForSelfTest()
    let capsuleContentFrames = [
        capsuleLayout.providerIconFrame,
        capsuleLayout.statusDotFrame,
        capsuleLayout.statusFrame,
        capsuleLayout.titleFrame,
        capsuleLayout.elapsedFrame,
        capsuleLayout.chevronFrame,
    ]
    guard dynamicIslandCapsuleSize == NSSize(width: 404, height: 58),
          root.view.frame.size == dynamicIslandCapsuleSize,
          capsuleLayout.bounds == NSRect(
              origin: .zero,
              size: dynamicIslandCapsuleSize
          ),
          capsuleLayout.providerIconFrame == NSRect(x: 18, y: 19, width: 20, height: 20),
          capsuleLayout.statusDotFrame == NSRect(x: 46, y: 25, width: 8, height: 8),
          capsuleLayout.statusFrame == NSRect(x: 62, y: 19, width: 48, height: 20),
          capsuleLayout.titleFrame == NSRect(x: 120, y: 18, width: 144, height: 22),
          capsuleLayout.elapsedFrame == NSRect(x: 276, y: 19, width: 96, height: 20),
          capsuleLayout.chevronFrame == NSRect(x: 380, y: 21, width: 8, height: 16),
          capsuleContentFrames.allSatisfy({
              capsuleLayout.bounds.contains($0)
          }),
          capsuleContentFrames.isNonOverlappingHorizontally,
          capsuleLayout.hitTargetFrame == NSRect(x: 0, y: 0, width: 404, height: 58),
          capsuleLayout.labelCount == 3,
          capsuleLayout.buttonCount == 1,
          !capsuleLayout.hasVisibleButtonTitle,
          capsuleLayout.hitTargetToolTip == "点击展开 · 拖动到其他屏幕",
          capsuleLayout.hitTargetAccessibilityHelp
            == "点击展开灵动岛功能面板；拖动可移到其他屏幕",
          capsuleLayout.providerIconAccessibilityDescription == "Claude Code",
          !capsuleLayout.taskContentIsHidden,
          capsuleLayout.quotaSummaryIsHidden,
          accessibilitySnapshot.contains("ThreadHelm 活动"),
          accessibilitySnapshot.contains("任务 1"),
          !accessibilitySnapshot.contains("确认"),
          accessibilitySnapshot.contains("额度"),
          accessibilitySnapshot.contains("全部"),
          accessibilitySnapshot.contains("Codex"),
          accessibilitySnapshot.contains("Claude"),
          accessibilitySnapshot.contains("刷新"),
          accessibilitySnapshot.contains("收起"),
          accessibilitySnapshot.contains("隐藏灵动岛"),
          hitTargetSize == NSSize(width: 404, height: 58)
    else {
        fputs(
            "dynamic island chrome accessibility self-test failed "
                + "snapshot=\(accessibilitySnapshot) "
                + "hitTarget=\(hitTargetSize) "
                + "layout=\(capsuleLayout) "
                + "rootSize=\(root.view.frame.size)\n",
            stderr
        )
        exit(1)
    }

    let idleRoot = DynamicIslandRootViewController()
    idleRoot.apply(
        snapshot: ActivityDashboardSnapshot(
            taskCollection: TaskProgressCollectionSnapshot.displaying([]),
            quotaStates: [
                .codex: QuotaProviderState(
                    rows: [
                        QuotaRow(
                            name: QuotaProvider.codex.summaryRowName,
                            remainingPercent: 35,
                            resetsAt: nil
                        )
                    ]
                ),
                .claudeCode: QuotaProviderState(
                    rows: [
                        QuotaRow(
                            name: QuotaProvider.claudeCode.summaryRowName,
                            remainingPercent: 100,
                            resetsAt: nil
                        )
                    ]
                ),
            ],
            availableProviders: QuotaProvider.allCases,
            selectedQuotaProvider: .claudeCode,
            permissionQueue: .empty,
            acknowledgedTerminalTaskKeys: [],
            isTaskRefreshing: false,
            codexDesktopRunning: true
        ),
        state: .capsule
    )
    let idleCapsuleLayout = idleRoot.capsuleLayoutSnapshotForSelfTest()
    let quotaSummaryLayout = idleRoot
        .capsuleQuotaSummaryLayoutSnapshotForSelfTest()
    let quotaComponentFrames = quotaSummaryLayout.iconFrames
        + quotaSummaryLayout.nameFrames
        + quotaSummaryLayout.valueFrames
    let leftQuotaGroupFrame = quotaSummaryLayout.iconFrames[0]
        .union(quotaSummaryLayout.nameFrames[0])
        .union(quotaSummaryLayout.valueFrames[0])
    let rightQuotaGroupFrame = quotaSummaryLayout.iconFrames[1]
        .union(quotaSummaryLayout.nameFrames[1])
        .union(quotaSummaryLayout.valueFrames[1])
    let leftQuotaColumnMidX = quotaSummaryLayout.dividerFrame.minX / 2
    let rightQuotaColumnMidX = (
        quotaSummaryLayout.dividerFrame.maxX
            + quotaSummaryLayout.frame.width
    ) / 2
    guard idleCapsuleLayout.taskContentIsHidden,
          !idleCapsuleLayout.quotaSummaryIsHidden,
          idleCapsuleLayout.hitTargetFrame == NSRect(
              x: 0,
              y: 0,
              width: 404,
              height: 58
          ),
          idleCapsuleLayout.chevronFrame == NSRect(
              x: 380,
              y: 21,
              width: 8,
              height: 16
          ),
          quotaSummaryLayout.frame == NSRect(
              x: 18,
              y: 19,
              width: 286,
              height: 20
          ),
          quotaSummaryLayout.iconFrames == [
              NSRect(x: 15.5, y: 0, width: 20, height: 20),
              NSRect(x: 148, y: 0, width: 20, height: 20),
          ],
          quotaSummaryLayout.nameFrames == [
              NSRect(x: 43.5, y: 0, width: 30, height: 20),
              NSRect(x: 176, y: 0, width: 52, height: 20),
          ],
          quotaSummaryLayout.valueFrames == [
              NSRect(x: 81.5, y: 0, width: 46, height: 20),
              NSRect(x: 236, y: 0, width: 46, height: 20),
          ],
          quotaSummaryLayout.valueCellWidths.enumerated().allSatisfy({
              index, width in
              width <= quotaSummaryLayout.valueFrames[index].width
          }),
          quotaSummaryLayout.dividerFrame == NSRect(
              x: 142.5,
              y: 3,
              width: 1,
              height: 14
          ),
          quotaSummaryLayout.dividerFrame.midX
              == quotaSummaryLayout.frame.width / 2,
          quotaComponentFrames.allSatisfy({ frame in
              frame.midY == quotaSummaryLayout.frame.height / 2
          }),
          abs(leftQuotaGroupFrame.midX - leftQuotaColumnMidX) <= 0.25,
          abs(rightQuotaGroupFrame.midX - rightQuotaColumnMidX) <= 0.25,
          quotaSummaryLayout.names == ["GPT", "Claude"],
          quotaSummaryLayout.values == ["35%", "100%"],
          quotaSummaryLayout.iconAccessibilityDescriptions == [
              "Codex",
              "Claude Code",
          ]
    else {
        fputs(
            "dynamic island capsule dual quota layout self-test failed "
                + "capsule=\(idleCapsuleLayout) "
                + "quota=\(quotaSummaryLayout)\n",
            stderr
        )
        exit(1)
    }

    guard DynamicIslandPalette.isIndependentForSelfTest else {
        fputs("dynamic island independent palette self-test failed\n", stderr)
        exit(1)
    }
    guard dynamicIslandMinimumFontSizeForSelfTest(
        in: root.view,
        excludingButtonTitles: true
    ) >= 12
    else {
        fputs("dynamic island minimum font self-test failed\n", stderr)
        exit(1)
    }

    let expansionStore = ActivityDashboardStore(snapshot: ActivityDashboardSnapshot(
        taskCollection: TaskProgressCollectionSnapshot.displaying([runningTask]),
        quotaStates: [:],
        availableProviders: [.codex],
        selectedQuotaProvider: .codex,
        permissionQueue: .empty,
        acknowledgedTerminalTaskKeys: [],
        isTaskRefreshing: false,
        codexDesktopRunning: true
    ))
    let controller = DynamicIslandWindowController(store: expansionStore)
    controller.showCapsule()
    controller.rootControllerForSelfTest().expandCapsuleForSelfTest()
    controller.completeAnimationForSelfTest()
    guard controller.state == .expanded(.tasks),
          controller.selectedTaskKeyForSelfTest() == runningTask.identityKey,
          controller.rootControllerForSelfTest().selectedTaskKeyForSelfTest()
              == runningTask.identityKey,
          controller.rootControllerForSelfTest()
              .workspaceSelectedTaskKeyForSelfTest() == runningTask.identityKey
    else {
        fputs("dynamic island selected task key propagation self-test failed\n", stderr)
        exit(1)
    }
    var hideRequestCount = 0
    controller.onRequestHide = {
        hideRequestCount += 1
        controller.hide()
    }
    controller.rootControllerForSelfTest().performHideButtonClickForSelfTest()
    guard hideRequestCount == 1,
          controller.state == .hidden,
          !controller.panel.isVisible
    else {
        fputs("dynamic island hide button self-test failed\n", stderr)
        exit(1)
    }
}

private func assertDynamicIslandTaskWorkspace() {
    _ = NSApplication.shared
    let now = Date(timeIntervalSince1970: 30_000)
    let previousDateProvider = dynamicIslandCurrentDate
    dynamicIslandCurrentDate = { now }
    defer { dynamicIslandCurrentDate = previousDateProvider }
    let shortEventHeight = dynamicIslandTaskEventRowHeight(
        text: "safe event",
        availableWidth: 360
    )
    let longEventHeight = dynamicIslandTaskEventRowHeight(
        text: String(repeating: "完整活动内容需要自动换行显示。", count: 12),
        availableWidth: 360
    )
    guard shortEventHeight >= 30,
          longEventHeight > shortEventHeight
    else {
        fputs("dynamic island task event wrapping self-test failed\n", stderr)
        exit(1)
    }
    let fullActivityText = String(
        repeating: "完整活动内容必须保留并通过滚动查看。",
        count: 180
    )
    func event(_ index: Int) -> TaskActivityEvent {
        TaskActivityEvent(
            kind: .commentary,
            occurredAt: now.addingTimeInterval(TimeInterval(index)),
            text: index == 5 ? fullActivityText : "safe event \(index)"
        )
    }
    let codexRunning = TaskProgressItem(
        title: "Codex running",
        kind: .running,
        startedAt: now.addingTimeInterval(-90),
        updatedAt: now.addingTimeInterval(4),
        source: .codex,
        activityText: "正在整理输出",
        threadID: "thread-abc1234",
        workingDirectory: "/tmp/threadhelm/../threadhelm",
        events: (1...5).map(event)
    )
    let claudeWaiting = TaskProgressItem(
        title: "Claude waiting",
        kind: .waitingForInput,
        startedAt: now.addingTimeInterval(-60),
        updatedAt: now.addingTimeInterval(3),
        source: .claudeCode,
        sessionID: "87654321-4321-4321-4321-cba987654321",
        workingDirectory: "/tmp/claude",
        processID: 42,
        processStartIdentity: "start-42",
        events: [event(8)]
    )
    let codexCompleted = TaskProgressItem(
        title: "Codex completed",
        kind: .completed,
        startedAt: now.addingTimeInterval(-40),
        updatedAt: now.addingTimeInterval(2),
        source: .codex,
        threadID: "thread-done9999"
    )
    let claudeFailed = TaskProgressItem(
        title: "Claude failed",
        kind: .failed,
        startedAt: now.addingTimeInterval(-30),
        updatedAt: now.addingTimeInterval(1),
        source: .claudeCode,
        sessionID: "12345678-1234-1234-1234-123456789abc",
        workingDirectory: "relative/path"
    )
    let collection = TaskProgressCollectionSnapshot.displaying([
        codexRunning,
        claudeWaiting,
        codexCompleted,
        claudeFailed,
    ])

    let queueSections = taskQueueSections(for: collection.items)
    guard queueSections.map(\.group) == [.needsYou, .running, .review],
          queueSections.map(\.items.count) == [2, 1, 1],
          queueSections[0].items.map(\.identityKey) == [
              claudeWaiting.identityKey,
              claudeFailed.identityKey,
          ],
          queueSections[1].items.map(\.identityKey) == [
              codexRunning.identityKey,
          ],
          queueSections[2].items.map(\.identityKey) == [
              codexCompleted.identityKey,
          ]
    else {
        fputs("dynamic island task queue grouping self-test failed\n", stderr)
        exit(1)
    }

    guard collection.filtered(source: .codex, state: .running)
        .map(\.identityKey) == [codexRunning.identityKey],
          collection.filtered(source: .claudeCode, state: .failed)
        .map(\.identityKey) == [claudeFailed.identityKey],
          collection.filtered(source: .claudeCode, state: .completed).isEmpty
    else {
        fputs("dynamic island task filters self-test failed\n", stderr)
        exit(1)
    }

    guard resolvedSelectedTaskKey(
        previousKey: codexRunning.identityKey,
        preferredKey: nil,
        visibleItems: collection.items
    ) == codexRunning.identityKey,
          resolvedSelectedTaskKey(
              previousKey: "missing",
              preferredKey: claudeWaiting.identityKey,
              visibleItems: collection.items
          ) == claudeWaiting.identityKey,
          resolvedSelectedTaskKey(
              previousKey: "missing",
              preferredKey: "also-missing",
              visibleItems: collection.items
          ) == collection.items.first?.identityKey,
          resolvedSelectedTaskKey(
              previousKey: nil,
              preferredKey: nil,
              visibleItems: []
          ) == nil,
          shortenedTaskIdentifier(nil) == nil,
          shortenedTaskIdentifier("thread-abc1234") == "1234",
          shortenedTaskIdentifier("session xyz-9q") == "YZ9Q"
    else {
        fputs("dynamic island task selection self-test failed\n", stderr)
        exit(1)
    }

    let controller = DynamicIslandTaskViewController()
    controller.apply(
        collection: collection,
        sourceFilter: .codex,
        preferredTaskKey: codexRunning.identityKey
    )
    guard controller.visibleTaskKeysForSelfTest() == [
        codexRunning.identityKey,
        codexCompleted.identityKey,
    ],
          controller.selectedTaskKeyForSelfTest() == codexRunning.identityKey,
          controller.accessibilitySnapshotForSelfTest().contains("全部 2"),
          controller.accessibilitySnapshotForSelfTest().contains("运行 1"),
          controller.accessibilitySnapshotForSelfTest().contains("最近事件"),
          controller.accessibilitySnapshotForSelfTest().contains("开始 "),
          controller.accessibilitySnapshotForSelfTest().contains("持续 01:30"),
          controller.detailEventTextsForSelfTest()
              == [
                  "safe event 1",
                  "safe event 2",
                  "safe event 3",
                  "safe event 4",
                  fullActivityText,
              ],
          controller.currentActivityTextForSelfTest() == fullActivityText,
          controller.activityScrollerIsEnabledForSelfTest(),
          controller.eventsScrollerIsEnabledForSelfTest(),
          controller.visibleProviderIconsAreConcreteForSelfTest(),
          controller.visibleTaskGroupSummariesForSelfTest() == [
              "进行中 1",
              "已完成 1",
          ],
          controller.footerButtonGapForSelfTest() >= 14,
          controller.copyPathForSelfTest() == "/tmp/threadhelm",
          controller.openButtonTitleForSelfTest() == "打开 Codex"
    else {
        fputs("dynamic island task controller self-test failed\n", stderr)
        exit(1)
    }

    controller.onOpenTask = { _ in .workingDirectoryFallback }
    controller.performOpenSelectedTaskForSelfTest()
    guard controller.openButtonTitleForSelfTest() == "仅打开目录" else {
        fputs("dynamic island typed open feedback self-test failed\n", stderr)
        exit(1)
    }

    controller.onOpenTask = { _ in .exactSession }
    controller.performOpenSelectedTaskForSelfTest()
    guard controller.openButtonTitleForSelfTest() == "已打开会话" else {
        fputs("dynamic island exact open feedback self-test failed\n", stderr)
        exit(1)
    }
    controller.onOpenTask = { _ in .failed }
    controller.performOpenSelectedTaskForSelfTest()
    guard controller.openButtonTitleForSelfTest() == "打开失败" else {
        fputs("dynamic island failed fallback feedback self-test failed\n", stderr)
        exit(1)
    }

    controller.setStateFilterForSelfTest(.completed)
    guard controller.visibleTaskKeysForSelfTest() == [
        codexCompleted.identityKey,
    ] else {
        fputs("dynamic island task state filter self-test failed\n", stderr)
        exit(1)
    }

    controller.setStateFilterForSelfTest(.all)
    controller.apply(
        collection: collection,
        sourceFilter: .claudeCode,
        preferredTaskKey: claudeWaiting.identityKey
    )
    guard controller.visibleTaskKeysForSelfTest() == [
        claudeWaiting.identityKey,
        claudeFailed.identityKey,
    ],
          controller.openButtonTitleForSelfTest() == "回到终端"
    else {
        fputs("dynamic island task preferred selection self-test failed\n", stderr)
        exit(1)
    }

    controller.apply(
        collection: collection,
        sourceFilter: .codex,
        preferredTaskKey: nil
    )
    guard controller.selectedTaskKeyForSelfTest() == codexRunning.identityKey else {
        fputs("dynamic island task refreshed selection self-test failed\n", stderr)
        exit(1)
    }

    controller.setStateFilterForSelfTest(.failed)
    guard controller.visibleTaskKeysForSelfTest().isEmpty,
          controller.accessibilitySnapshotForSelfTest().contains("没有匹配任务")
    else {
        fputs("dynamic island task empty state self-test failed\n", stderr)
        exit(1)
    }

    controller.setStateFilterForSelfTest(.all)
    guard let cursorMetadata = builtInAgentMetadata().first(where: {
        $0.id == .cursor
    }) else {
        fputs("dynamic island cursor metadata self-test failed\n", stderr)
        exit(1)
    }
    let cursorNotInstalled = AgentRuntimeStatus(
        metadata: cursorMetadata,
        discovery: AgentDiscovery(
            isInstalled: true,
            version: "3.15.19",
            compatibility: .unvalidated,
            versionComponents: [
                AgentVersionComponent(
                    key: "desktop",
                    label: "Desktop",
                    value: "3.15.19"
                ),
                AgentVersionComponent(
                    key: "agentCLI",
                    label: "Agent CLI",
                    value: "2026.04.15-dccdccd"
                ),
            ]
        ),
        integrationStatus: .notInstalled,
        diagnostics: AgentDiagnostics(
            health: .degraded,
            summary: "集成未安装",
            counters: [:]
        ),
        activeSessionCount: 0,
        attentionCount: 0
    )
    let emptyCopy = cursorListeningEmptyPresentation(
        sourceFilter: .cursor,
        sourceItemCount: 0,
        cursorStatus: cursorNotInstalled
    )
    let cursorStatusUnknown = AgentRuntimeStatus(
        metadata: cursorMetadata,
        discovery: cursorNotInstalled.discovery,
        integrationStatus: nil,
        diagnostics: cursorNotInstalled.diagnostics,
        activeSessionCount: 0,
        attentionCount: 0
    )
    guard emptyCopy?.title == "还听不到 Cursor 的执行",
          emptyCopy?.eyebrow == "Cursor · 监听未安装",
          emptyCopy?.body.contains("3.15.19") == true,
          emptyCopy?.body.contains("3.15.6") == true,
          emptyCopy?.facts.contains(where: {
              $0.label == "集成状态" && $0.value == "未安装"
          }) == true,
          emptyCopy?.facts.contains(where: {
              $0.label == "钩子文件" && $0.value.contains("hooks.json")
          }) == true,
          cursorListeningEmptyPresentation(
              sourceFilter: .cursor,
              sourceItemCount: 1,
              cursorStatus: cursorNotInstalled
          ) == nil,
          cursorListeningEmptyPresentation(
              sourceFilter: .cursor,
              sourceItemCount: 0,
              cursorStatus: cursorStatusUnknown
          )?.title == "还听不到 Cursor 的执行"
    else {
        fputs("dynamic island cursor listening copy self-test failed\n", stderr)
        exit(1)
    }
    controller.apply(
        collection: collection,
        sourceFilter: .cursor,
        preferredTaskKey: nil,
        agentStatuses: [cursorNotInstalled]
    )
    var inspectAgentsCount = 0
    controller.onInspectAgents = { inspectAgentsCount += 1 }
    controller.performOpenSelectedTaskForSelfTest()
    guard controller.visibleTaskKeysForSelfTest().isEmpty,
          controller.accessibilitySnapshotForSelfTest()
              .contains("还听不到 Cursor 的执行"),
          controller.accessibilitySnapshotForSelfTest().contains("监听未安装"),
          controller.accessibilitySnapshotForSelfTest()
              .contains("查看 Agents 状态"),
          controller.accessibilitySnapshotForSelfTest().contains("稍后再装"),
          controller.accessibilitySnapshotForSelfTest().contains("集成状态"),
          !controller.accessibilitySnapshotForSelfTest()
              .contains("打开当前任务"),
          controller.openButtonTitleForSelfTest() == "查看 Agents 状态",
          inspectAgentsCount == 1
    else {
        fputs("dynamic island cursor listening empty self-test failed\n", stderr)
        exit(1)
    }
    controller.setStateFilterForSelfTest(.failed)
    guard controller.accessibilitySnapshotForSelfTest()
              .contains("还听不到 Cursor 的执行"),
          controller.openButtonTitleForSelfTest() == "查看 Agents 状态"
    else {
        fputs("dynamic island cursor listening filter persistence self-test failed\n", stderr)
        exit(1)
    }

    controller.setStateFilterForSelfTest(.all)
    controller.apply(
        collection: collection,
        sourceFilter: .codex,
        preferredTaskKey: nil
    )
    let selectedBeforeHover = controller.selectedTaskKeyForSelfTest()
    controller.showHoverForSelfTest(item: codexRunning)
    guard controller.hoverEventTextsForSelfTest()
        == ["safe event 3", "safe event 4", fullActivityText],
          controller.selectedTaskKeyForSelfTest() == selectedBeforeHover
    else {
        fputs("dynamic island task hover self-test failed\n", stderr)
        exit(1)
    }
    controller.hideHoverForSelfTest()

    let laterNow = now.addingTimeInterval(3_600)
    guard taskProgressDurationText(for: codexCompleted, now: now) == "00:42",
          taskProgressDurationText(for: codexCompleted, now: laterNow) == "00:42",
          taskProgressDurationText(for: codexRunning, now: now) == "01:30",
          taskProgressDurationText(for: codexRunning, now: laterNow) == "1:01:30"
    else {
        fputs("dynamic island task stable terminal time self-test failed\n", stderr)
        exit(1)
    }

    let workspace = DynamicIslandWorkspaceViewController()
    workspace.view.frame = NSRect(origin: .zero, size: dynamicIslandTaskSize)
    workspace.view.layoutSubtreeIfNeeded()
    var emittedSourceFilters: [TaskSourceFilter] = []
    workspace.onSourceFilterChange = { emittedSourceFilters.append($0) }
    workspace.apply(
        snapshot: ActivityDashboardSnapshot(taskCollection: collection),
        state: .expanded(.tasks)
    )
    let topLevelTabLabels = workspace.topLevelTabLabelsForSelfTest().map {
        $0.trimmingCharacters(in: .whitespaces)
    }
    guard !workspace.sourceFilterIsHiddenForSelfTest(),
          topLevelTabLabels == [
              "任务 \(collection.items.count)",
              "Agents 5",
              "额度",
          ],
          workspace.sourceFilterLabelsForSelfTest()
              == ["全部", "Codex", "Claude", "Cursor", "ZCode", "Pi"],
          workspace.selectedTopLevelTabForSelfTest() == 0,
          !workspace.accessibilitySnapshotForSelfTest().contains("确认")
    else {
        fputs("dynamic island task source filter visibility self-test failed\n", stderr)
        exit(1)
    }
    workspace.setSourceFilterForSelfTest(.claudeCode)
    guard emittedSourceFilters.last == .claudeCode,
          workspace.taskVisibleKeysForSelfTest() == [
              claudeWaiting.identityKey,
              claudeFailed.identityKey,
          ]
    else {
        fputs("dynamic island task source action self-test failed\n", stderr)
        exit(1)
    }

    let mockAgentID = AgentID(rawValue: "mockSixth")
    let mockTask = TaskProgressItem(
        title: "Mock sixth running",
        kind: .running,
        startedAt: now,
        source: mockAgentID,
        threadID: "mock-sixth-session"
    )
    let extendedCollection = TaskProgressCollectionSnapshot.displaying(
        collection.items + [mockTask]
    )
    workspace.apply(
        snapshot: ActivityDashboardSnapshot(
            taskCollection: extendedCollection,
            availableAgentIDs: AgentID.builtInOrder + [mockAgentID]
        ),
        state: .expanded(.tasks)
    )
    workspace.setSourceFilterForSelfTest(TaskSourceFilter(agentID: mockAgentID))
    guard workspace.sourceFilterLabelsForSelfTest().last == "mockSixth",
          emittedSourceFilters.last?.agentID == mockAgentID,
          workspace.taskVisibleKeysForSelfTest() == [mockTask.identityKey]
    else {
        fputs("dynamic island sixth agent rendering self-test failed\n", stderr)
        exit(1)
    }

    var agentHealthSnapshot = ActivityDashboardSnapshot(
        taskCollection: collection
    )
    agentHealthSnapshot.agentEventChannelAvailable = false
    agentHealthSnapshot.agentStatuses = builtInAgentMetadata().map { metadata in
        let components: [AgentVersionComponent]
        switch metadata.id {
        case .codex:
            components = [
                AgentVersionComponent(
                    key: "version",
                    label: "Version",
                    value: "0.145.0"
                ),
            ]
        case .claudeCode:
            components = [
                AgentVersionComponent(
                    key: "version",
                    label: "Version",
                    value: "2.1.226"
                ),
            ]
        case .cursor:
            components = [
                AgentVersionComponent(
                    key: "desktop",
                    label: "Desktop",
                    value: "3.15.19"
                ),
                AgentVersionComponent(
                    key: "agentCLI",
                    label: "Agent CLI",
                    value: "2026.04.14-ee4b43a"
                ),
            ]
        case .zcode:
            components = []
        case .pi:
            components = [
                AgentVersionComponent(
                    key: "version",
                    label: "Version",
                    value: "0.84.1"
                ),
            ]
        default:
            components = []
        }
        return AgentRuntimeStatus(
            metadata: metadata,
            discovery: versionValidatedAgentDiscovery(
                agentID: metadata.id,
                isInstalled: metadata.id != .zcode,
                components: components
            ),
            integrationStatus: metadata.id == .cursor ? .installed : nil,
            diagnostics: AgentDiagnostics(
                health: metadata.id == .zcode ? .unavailable : .healthy,
                summary: metadata.id == .zcode ? "未发现 ZCode" : "本机可用",
                counters: [:]
            ),
            activeSessionCount: metadata.id == .codex ? 2 : 0,
            attentionCount: metadata.id == .claudeCode ? 1 : 0
        )
    }
    workspace.apply(
        snapshot: agentHealthSnapshot,
        state: .expanded(.agents)
    )
    let agentHealthRows = workspace.agentHealthRowSummariesForSelfTest()
    let validationProfiles = builtInAgentValidationProfiles()
    guard workspace.sourceFilterIsHiddenForSelfTest(),
          workspace.selectedTopLevelTabForSelfTest() == 1,
          agentHealthRows.count == 5,
          zip(AgentID.builtInOrder, agentHealthRows).allSatisfy({
              agentID, summary in
              guard let profile = validationProfiles[agentID] else {
                  return false
              }
              let capabilityIsTruthful: Bool
              if agentID == .cursor {
                  capabilityIsTruthful = summary.contains("unvalidated")
                      && !summary.contains(profile.supportedCapabilitiesSummary)
              } else if agentID == .zcode {
                  capabilityIsTruthful = summary.contains("本机未检测到")
                      && !summary.contains(profile.supportedCapabilitiesSummary)
              } else {
                  capabilityIsTruthful = summary.contains(
                      profile.supportedCapabilitiesSummary
                  )
              }
              return summary.contains("测试 \(profile.testedVersion)")
                  && capabilityIsTruthful
                  && summary.contains(profile.knownLimitation)
                  && !summary.contains("真实会话")
                  && !summary.contains("personal-ready")
                  && !summary.contains("experimental")
                  && !summary.contains("主人复核")
          }),
          agentHealthRows.first?.contains(
              "本机 0.145.0 · 已验证 · 测试 0.145.0"
          ) == true,
          agentHealthRows.first(where: { $0.contains("Cursor") })?.contains(
              "Desktop 3.15.19 · Agent CLI 2026.04.14-ee4b43a · unvalidated"
          ) == true,
          workspace.agentHealthAccessibilitySnapshotForSelfTest()
              .contains("本地事件通道已降级"),
          workspace.agentHealthAccessibilitySnapshotForSelfTest()
              .contains("Cursor"),
          workspace.agentHealthAccessibilitySnapshotForSelfTest()
              .contains("集成已安装"),
          workspace.agentHealthAccessibilitySnapshotForSelfTest()
              .contains("未发现 ZCode")
    else {
        fputs("dynamic island agent health workspace self-test failed\n", stderr)
        exit(1)
    }

    var missingVersionHealthSnapshot = agentHealthSnapshot
    missingVersionHealthSnapshot.agentStatuses = agentHealthSnapshot.agentStatuses.map {
        status in
        guard status.metadata.id == .zcode else { return status }
        return AgentRuntimeStatus(
            metadata: status.metadata,
            discovery: versionValidatedAgentDiscovery(
                agentID: .zcode,
                isInstalled: true,
                components: []
            ),
            integrationStatus: status.integrationStatus,
            diagnostics: AgentDiagnostics(
                health: .healthy,
                summary: "本机可用",
                counters: [:]
            ),
            activeSessionCount: 0,
            attentionCount: 0
        )
    }
    workspace.apply(
        snapshot: missingVersionHealthSnapshot,
        state: .expanded(.agents)
    )
    guard workspace.agentHealthRowSummariesForSelfTest()
        .first(where: { $0.contains("ZCode") })?
        .contains("本机版本未知 · unvalidated · 测试 3.7.6") == true
    else {
        fputs("dynamic island missing agent version validation self-test failed\n", stderr)
        exit(1)
    }

    workspace.setSourceFilterForSelfTest(.claudeCode)
    workspace.apply(
        snapshot: ActivityDashboardSnapshot(taskCollection: collection),
        state: .expanded(.quota)
    )
    guard workspace.sourceFilterIsHiddenForSelfTest() else {
        fputs("dynamic island quota duplicate source filter self-test failed\n", stderr)
        exit(1)
    }
    workspace.apply(
        snapshot: ActivityDashboardSnapshot(taskCollection: collection),
        state: .expanded(.confirmation)
    )
    guard workspace.sourceFilterIsHiddenForSelfTest(),
          workspace.selectedTopLevelTabForSelfTest() == nil,
          !workspace.accessibilitySnapshotForSelfTest().contains("确认")
    else {
        fputs("dynamic island transient confirmation navigation self-test failed\n", stderr)
        exit(1)
    }
    workspace.apply(
        snapshot: ActivityDashboardSnapshot(taskCollection: collection),
        state: .expanded(.tasks)
    )
    guard !workspace.sourceFilterIsHiddenForSelfTest() else {
        fputs("dynamic island source filter restoration self-test failed\n", stderr)
        exit(1)
    }

    var openedItems: [TaskProgressItem] = []
    var copiedPaths: [String] = []
    var acknowledgedDetails: [String] = []
    let openStore = ActivityDashboardStore(snapshot: ActivityDashboardSnapshot(
        taskCollection: collection
    ))
    let windowController = DynamicIslandWindowController(store: openStore)
    windowController.onOpenTask = {
        openedItems.append($0)
        return .exactSession
    }
    windowController.onCopyWorkingDirectory = {
        copiedPaths.append($0)
        return normalizedAbsolutePath($0) != nil
    }
    windowController.onTaskDetailOpened = {
        acknowledgedDetails.append($0.identityKey)
    }
    windowController.expand(.tasks, selectedTaskKey: codexRunning.identityKey)
    guard acknowledgedDetails == [codexRunning.identityKey],
          windowController.copyWorkingDirectoryForSelfTest("/tmp/threadhelm/../threadhelm"),
          copiedPaths == ["/tmp/threadhelm/../threadhelm"]
    else {
        fputs(
            "dynamic island task appdelegate action routing self-test failed "
                + "ack=\(acknowledgedDetails) copy=\(copiedPaths)\n",
            stderr
        )
        exit(1)
    }
    acknowledgedDetails.removeAll()
    windowController.performOpenSelectedTaskForSelfTest()
    guard openedItems.map(\.identityKey) == [codexRunning.identityKey],
          acknowledgedDetails.isEmpty
    else {
        fputs(
            "dynamic island task open propagation or ack isolation failed "
                + "opened=\(openedItems.map(\.identityKey)) "
                + "ack=\(acknowledgedDetails)\n",
            stderr
        )
        exit(1)
    }
    openStore.update { $0.isTaskRefreshing = true }
    guard acknowledgedDetails.isEmpty else {
        fputs("dynamic island passive refresh acknowledgement self-test failed\n", stderr)
        exit(1)
    }

    windowController.rootControllerForSelfTest()
        .showTaskHoverForSelfTest(item: codexRunning)
    guard windowController.rootControllerForSelfTest()
        .taskHoverVisibleForSelfTest()
    else {
        fputs("dynamic island task hover visible setup self-test failed\n", stderr)
        exit(1)
    }
    windowController.collapse()
    guard !windowController.rootControllerForSelfTest()
        .taskHoverVisibleForSelfTest()
    else {
        fputs("dynamic island task hover collapse self-test failed\n", stderr)
        exit(1)
    }
    windowController.expand(.tasks, selectedTaskKey: codexRunning.identityKey)
    windowController.rootControllerForSelfTest()
        .showTaskHoverForSelfTest(item: codexRunning)
    guard windowController.rootControllerForSelfTest()
        .taskHoverVisibleForSelfTest()
    else {
        fputs("dynamic island task hover visible reset self-test failed\n", stderr)
        exit(1)
    }
    windowController.hide()
    guard !windowController.rootControllerForSelfTest()
        .taskHoverVisibleForSelfTest()
    else {
        fputs("dynamic island task hover hide self-test failed\n", stderr)
        exit(1)
    }
}

private func assertDynamicIslandQuotaWorkspace() {
    _ = NSApplication.shared
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let codexResetCredits = CodexResetCreditsSnapshot(
        credits: (1...5).map { index in
            CodexResetCredit(
                id: "credit-\(index)",
                status: .available,
                expiresAt: now.addingTimeInterval(TimeInterval(index) * 3_600)
            )
        },
        reportedAvailableCount: 5,
        updatedAt: now
    )
    let codexState = QuotaProviderState(
        rows: [QuotaRow(
            name: "周额度",
            remainingPercent: 64,
            resetsAt: now.addingTimeInterval(7 * 24 * 60 * 60)
        )],
        resetCredits: codexResetCredits,
        statusText: "8月7日 08:59 重置 · 1分钟",
        errorText: nil,
        updatedAt: now,
        isRefreshing: false,
        isStale: true
    )
    let claudeState = QuotaProviderState(
        rows: [
            QuotaRow(
                name: "5 小时",
                remainingPercent: 91,
                resetsAt: now.addingTimeInterval(5 * 60 * 60)
            ),
            QuotaRow(
                name: "周额度",
                remainingPercent: 93,
                resetsAt: now.addingTimeInterval(7 * 24 * 60 * 60)
            ),
            QuotaRow(
                name: "Fable",
                remainingPercent: 97,
                resetsAt: nil,
                resetDescription: "Jul 30 at 12pm"
            ),
        ],
        resetCredits: nil,
        statusText: "12:00 更新 · 1分钟",
        errorText: nil,
        updatedAt: now,
        isRefreshing: true,
        isStale: false
    )

    let controller = DynamicIslandQuotaViewController()
    var selectedProviders: [QuotaProvider] = []
    var refreshCount = 0
    controller.onSelectProvider = { selectedProviders.append($0) }
    controller.onRefresh = { refreshCount += 1 }
    controller.apply(ActivityDashboardSnapshot(
        quotaStates: [
            .codex: codexState,
            .claudeCode: claudeState,
        ],
        availableProviders: QuotaProvider.allCases,
        selectedQuotaProvider: .codex,
        isTaskRefreshing: false,
        codexDesktopRunning: true
    ))

    let codexSnapshot = controller.accessibilitySnapshotForSelfTest()
    guard controller.providerNamesForSelfTest() == ["Codex", "Claude Code"],
          controller.leftPaneWidthForSelfTest() == 228,
          controller.selectedProviderForSelfTest() == .codex,
          controller.providerButtonImagesAreConcreteForSelfTest(),
          controller.providerButtonIconsUseResourcesForSelfTest(),
          controller.selectedSummaryPercentForSelfTest() == 64,
          controller.detailRowNamesForSelfTest() == ["周额度"],
          controller.detailResetTextsForSelfTest().contains(where: {
              $0.contains("重置")
          }),
          controller.resetCreditExpiryLineCountForSelfTest() == 2,
          !controller.isRefreshEnabledForSelfTest(),
          codexSnapshot.contains("缓存数据"),
          codexSnapshot.contains("5 次可用"),
          codexSnapshot.contains("周额度 64%"),
          codexSnapshot.contains("刷新与生命周期"),
          !codexSnapshot.contains("checkmark.circle"),
          !codexSnapshot.contains("arrow.triangle"),
          !codexSnapshot.contains("exclamationmark")
    else {
        fputs("dynamic island quota codex workspace self-test failed \(codexSnapshot)\n", stderr)
        exit(1)
    }

    controller.selectProviderForSelfTest(.claudeCode)
    guard selectedProviders == [.claudeCode] else {
        fputs("dynamic island quota selection callback self-test failed\n", stderr)
        exit(1)
    }
    controller.apply(ActivityDashboardSnapshot(
        quotaStates: [
            .codex: codexState,
            .claudeCode: claudeState,
        ],
        availableProviders: QuotaProvider.allCases,
        selectedQuotaProvider: .claudeCode,
        isTaskRefreshing: false,
        codexDesktopRunning: true
    ))
    guard controller.detailRowNamesForSelfTest() == ["5 小时", "周额度", "Fable"],
          controller.accessibilitySnapshotForSelfTest().contains("Fable 97%"),
          controller.accessibilitySnapshotForSelfTest().contains("正在更新"),
          controller.detailScrollIsConfiguredForSelfTest(),
          controller.detailLayoutHasNoOverlapForSelfTest(),
          controller.detailHeadlineIsVisibleForSelfTest()
    else {
        fputs("dynamic island quota claude rows self-test failed\n", stderr)
        exit(1)
    }

    controller.apply(ActivityDashboardSnapshot(
        quotaStates: [
            .codex: QuotaProviderState(
                rows: [],
                resetCredits: nil,
                statusText: "没有可确认的额度数据",
                errorText: nil,
                updatedAt: now,
                isRefreshing: false,
                isStale: false
            )
        ],
        availableProviders: [.codex],
        selectedQuotaProvider: .codex,
        isTaskRefreshing: true,
        codexDesktopRunning: true
    ))
    guard controller.accessibilitySnapshotForSelfTest()
        .contains("没有可确认的额度数据"),
          !controller.accessibilitySnapshotForSelfTest().contains("未安装"),
          !controller.isRefreshEnabledForSelfTest()
    else {
        fputs("dynamic island quota empty current self-test failed\n", stderr)
        exit(1)
    }

    controller.apply(ActivityDashboardSnapshot(
        quotaStates: [
            .claudeCode: QuotaProviderState(
                rows: [],
                resetCredits: nil,
                statusText: "登录后点击刷新",
                errorText: "请先登录 Claude Code",
                updatedAt: nil,
                isRefreshing: false,
                isStale: false
            )
        ],
        availableProviders: QuotaProvider.allCases,
        selectedQuotaProvider: .claudeCode,
        isTaskRefreshing: false,
        codexDesktopRunning: true
    ))
    guard controller.accessibilitySnapshotForSelfTest()
        .contains("请先登录 Claude Code"),
          controller.accessibilitySnapshotForSelfTest()
        .contains("登录后点击刷新")
    else {
        fputs("dynamic island quota first failure self-test failed\n", stderr)
        exit(1)
    }

    controller.apply(ActivityDashboardSnapshot(
        quotaStates: [:],
        availableProviders: [.codex],
        selectedQuotaProvider: .claudeCode,
        isTaskRefreshing: false,
        codexDesktopRunning: true
    ))
    guard controller.accessibilitySnapshotForSelfTest().contains("未安装"),
          controller.isRefreshEnabledForSelfTest()
    else {
        fputs("dynamic island quota unavailable self-test failed\n", stderr)
        exit(1)
    }

    controller.refreshForSelfTest()
    guard refreshCount == 1 else {
        fputs("dynamic island quota refresh callback self-test failed\n", stderr)
        exit(1)
    }

    let workspace = DynamicIslandWorkspaceViewController()
    var workspaceRefreshCount = 0
    workspace.onRefresh = { workspaceRefreshCount += 1 }
    let manualSnapshot = ActivityDashboardSnapshot(
        quotaStates: [
            .codex: codexState,
            .claudeCode: QuotaProviderState(
                rows: [],
                resetCredits: nil,
                statusText: "正在读取额度…",
                errorText: nil,
                updatedAt: nil,
                isRefreshing: false,
                isStale: false
            ),
        ],
        availableProviders: QuotaProvider.allCases,
        selectedQuotaProvider: .codex,
        isTaskRefreshing: false,
        codexDesktopRunning: true
    )
    workspace.apply(snapshot: manualSnapshot, state: .expanded(.quota))
    workspace.refreshForSelfTest()
    guard workspaceRefreshCount == 1,
          dynamicIslandDashboardRefreshQuotaProviders(snapshot: manualSnapshot)
              == QuotaProvider.allCases
    else {
        fputs("dynamic island manual dashboard refresh self-test failed\n", stderr)
        exit(1)
    }

    let store = ActivityDashboardStore(snapshot: manualSnapshot)
    let windowController = DynamicIslandWindowController(store: store)
    var taskRefreshCount = 0
    var refreshedProviders: [QuotaProvider] = []
    DynamicIslandDashboardActionBinding(
        refreshDashboard: DynamicIslandDashboardRefreshDispatcher(
            availableProviders: { store.snapshot.availableProviders },
            refreshTasks: { taskRefreshCount += 1 },
            refreshQuotaProvider: { refreshedProviders.append($0) }
        ).refreshDashboard,
        selectQuotaProvider: { selectedProviders.append($0) }
    ).bind(to: windowController)
    windowController.expand(.quota)
    windowController.completeAnimationForSelfTest()
    windowController.rootControllerForSelfTest()
        .performTopRefreshButtonClickForSelfTest()
    guard taskRefreshCount == 1,
          refreshedProviders == QuotaProvider.allCases
    else {
        fputs(
            "dynamic island window refresh action self-test failed "
                + "tasks=\(taskRefreshCount) providers=\(refreshedProviders)\n",
            stderr
        )
        exit(1)
    }

    let selectionStartCount = selectedProviders.count
    windowController.rootControllerForSelfTest()
        .performQuotaProviderButtonClickForSelfTest(.claudeCode)
    guard Array(selectedProviders.dropFirst(selectionStartCount)) == [.claudeCode] else {
        fputs(
            "dynamic island window provider action self-test failed "
                + "selected=\(selectedProviders)\n",
            stderr
        )
        exit(1)
    }
    windowController.hide()
}

private func assertDynamicIslandPreviewRendering() {
    let expectedStates = [
        "capsule-confirmation",
        "capsule-running",
        "capsule-waiting",
        "capsule-completed",
        "capsule-failed",
        "capsule-idle",
        "capsule-codex-exited",
        "tasks",
        "confirm-tool",
        "confirm-question",
        "confirm-plan",
        "quota-codex",
        "quota-claude",
        "quota-refreshing",
        "quota-loading",
        "quota-stale",
        "quota-first-failure",
        "quota-unavailable",
    ]
    guard dynamicIslandPreviewStateNames() == expectedStates,
          DynamicIslandPreviewState(rawValue: "unknown") == nil
    else {
        fputs("dynamic island preview state parser self-test failed\n", stderr)
        exit(1)
    }

    let expectedSizes: [DynamicIslandPreviewState: NSSize] = [
        .capsuleConfirmation: dynamicIslandCapsuleSize,
        .capsuleRunning: dynamicIslandCapsuleSize,
        .capsuleWaiting: dynamicIslandCapsuleSize,
        .capsuleCompleted: dynamicIslandCapsuleSize,
        .capsuleFailed: dynamicIslandCapsuleSize,
        .capsuleIdle: dynamicIslandCapsuleSize,
        .capsuleCodexExited: dynamicIslandCapsuleSize,
        .tasks: dynamicIslandTaskSize,
        .confirmTool: dynamicIslandConfirmationSize,
        .confirmQuestion: dynamicIslandConfirmationSize,
        .confirmPlan: dynamicIslandConfirmationSize,
        .quotaCodex: dynamicIslandQuotaSize,
        .quotaClaude: dynamicIslandQuotaSize,
        .quotaRefreshing: dynamicIslandQuotaSize,
        .quotaLoading: dynamicIslandQuotaSize,
        .quotaStale: dynamicIslandQuotaSize,
        .quotaFirstFailure: dynamicIslandQuotaSize,
        .quotaUnavailable: dynamicIslandQuotaSize,
    ]
    guard expectedSizes.allSatisfy({
        dynamicIslandPreviewSize(for: $0.key) == $0.value
    }) else {
        fputs("dynamic island preview dimensions self-test failed\n", stderr)
        exit(1)
    }

    let temporaryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("threadhelm-dynamic-island-preview-self-test.png")
    do {
        try? FileManager.default.removeItem(at: temporaryURL)
        try renderDynamicIslandPreview(state: .tasks, to: temporaryURL)
        guard let image = NSImage(contentsOf: temporaryURL),
              let rep = image.representations.first as? NSBitmapImageRep,
              rep.pixelsWide == Int(dynamicIslandTaskSize.width) * 2,
              rep.pixelsHigh == Int(dynamicIslandTaskSize.height) * 2
        else {
            fputs("dynamic island preview render seam dimensions failed\n", stderr)
            exit(1)
        }
        try? FileManager.default.removeItem(at: temporaryURL)
        try renderDynamicIslandPreview(
            state: .capsuleRunning,
            to: temporaryURL
        )
        guard let capsuleImage = NSImage(contentsOf: temporaryURL),
              let capsuleRep = capsuleImage.representations.first
                  as? NSBitmapImageRep,
              capsuleRep.pixelsWide == 808,
              capsuleRep.pixelsHigh == 116
        else {
            fputs("dynamic island capsule preview dimensions failed\n", stderr)
            exit(1)
        }
        try? FileManager.default.removeItem(at: temporaryURL)

        let terminalStates: [DynamicIslandPreviewState] = [
            .capsuleFailed,
            .capsuleCompleted,
            .capsuleIdle,
        ]
        var terminalPreviewData: [Data] = []
        for state in terminalStates {
            let stateURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "threadhelm-dynamic-island-\(state.rawValue)-self-test.png"
                )
            try? FileManager.default.removeItem(at: stateURL)
            try renderDynamicIslandPreview(state: state, to: stateURL)
            terminalPreviewData.append(try Data(contentsOf: stateURL))
            try? FileManager.default.removeItem(at: stateURL)
        }
        guard Set(terminalPreviewData).count == terminalStates.count else {
            fputs("dynamic island terminal capsule previews are identical\n", stderr)
            exit(1)
        }
    } catch {
        fputs("dynamic island preview render seam failed: \(error)\n", stderr)
        exit(1)
    }
}

private func assertDynamicIslandPlacement() {
    let visible = NSRect(x: -1_440, y: 0, width: 1_440, height: 900)
    let capsule = dynamicIslandFrame(
        size: dynamicIslandCapsuleSize,
        visibleFrame: visible,
        topGap: 6
    )
    guard capsule.midX == visible.midX,
          capsule.maxY == visible.maxY - 6
    else {
        fputs("dynamic island capsule placement self-test failed\n", stderr)
        exit(1)
    }

    let oddWidthVisible = NSRect(x: -1_135, y: 37, width: 1_135, height: 758)
    let pixelAlignedCapsule = dynamicIslandFrame(
        size: dynamicIslandCapsuleSize,
        visibleFrame: oddWidthVisible,
        topGap: 6
    )
    guard pixelAlignedCapsule.origin.x == -770,
          abs(pixelAlignedCapsule.midX - oddWidthVisible.midX) == 0.5
    else {
        fputs("dynamic island pixel-aligned placement self-test failed\n", stderr)
        exit(1)
    }

    let expanded = dynamicIslandFrame(
        size: NSSize(width: 820, height: 560),
        visibleFrame: visible,
        topGap: 6
    )
    guard expanded.maxY == capsule.maxY else {
        fputs("dynamic island top anchor self-test failed\n", stderr)
        exit(1)
    }

    let largeVisible = NSRect(x: 0, y: 0, width: 1_600, height: 1_000)
    let preferred = dynamicIslandPreferredExpandedSize(visibleFrame: largeVisible)
    guard preferred.width > dynamicIslandTaskSize.width,
          preferred.height > dynamicIslandTaskSize.height,
          preferred.width <= dynamicIslandExpandedComfortMaxSize.width,
          preferred.height <= dynamicIslandExpandedComfortMaxSize.height
    else {
        fputs("dynamic island preferred expanded size self-test failed\n", stderr)
        exit(1)
    }

    let narrowVisible = NSRect(x: 0, y: 0, width: 700, height: 900)
    let narrowSize = dynamicIslandFittedSize(
        requested: dynamicIslandTaskSize,
        visibleFrame: narrowVisible
    )
    guard narrowSize.width == narrowVisible.width - 16 else {
        fputs("dynamic island narrow-screen width self-test failed\n", stderr)
        exit(1)
    }

    let shortVisible = NSRect(x: 0, y: 0, width: 1_200, height: 400)
    let shortSize = dynamicIslandFittedSize(
        requested: dynamicIslandConfirmationSize,
        visibleFrame: shortVisible
    )
    guard shortSize.height == shortVisible.height - 12 else {
        fputs("dynamic island short-screen height self-test failed\n", stderr)
        exit(1)
    }

    let notchSafeVisible = NSRect(x: 0, y: 80, width: 1_512, height: 858)
    let notchFrame = dynamicIslandFrame(
        size: dynamicIslandCapsuleSize,
        visibleFrame: notchSafeVisible,
        topGap: dynamicIslandTopGap
    )
    let auxiliaryLeft = NSRect(x: 0, y: 938, width: 624, height: 44)
    let auxiliaryRight = NSRect(x: 888, y: 938, width: 624, height: 44)
    guard notchFrame.maxY <= notchSafeVisible.maxY,
          !notchFrame.intersects(auxiliaryLeft),
          !notchFrame.intersects(auxiliaryRight)
    else {
        fputs("dynamic island notch-safe placement self-test failed\n", stderr)
        exit(1)
    }

    guard capsule.minX < 0,
          capsule.maxX < 0,
          capsule.minY >= visible.minY
    else {
        fputs("dynamic island negative-coordinate self-test failed\n", stderr)
        exit(1)
    }

    guard !dynamicIslandCapsuleDragExceededThreshold(
              from: NSPoint(x: 20, y: 20),
              to: NSPoint(x: 23, y: 20)
          ),
          dynamicIslandCapsuleDragExceededThreshold(
              from: NSPoint(x: 20, y: 20),
              to: NSPoint(x: 24, y: 20)
          ),
          dynamicIslandCapsuleDragExceededThreshold(
              from: NSPoint(x: 20, y: 20),
              to: NSPoint(x: 17, y: 17)
          )
    else {
        fputs("dynamic island capsule drag threshold self-test failed\n", stderr)
        exit(1)
    }
}

private func assertDynamicIslandStateAndLevel() {
    _ = NSApplication.shared
    let controller = DynamicIslandWindowController()
    guard controller.state == .hidden else { exit(1) }

    controller.showCapsule()
    guard controller.state == .capsule,
          !controller.panel.allowsKeyWindow,
          controller.panel.level == panelDefaultWindowLevel,
          controller.panel.isMovable,
          !controller.panel.isMovableByWindowBackground
    else {
        fputs("dynamic island show capsule self-test failed\n", stderr)
        exit(1)
    }

    if let targetScreen = NSScreen.screens.first(where: {
        dynamicIslandDisplayID(for: $0) != controller.targetDisplayID
    }) ?? NSScreen.screens.first,
       let targetDisplayID = dynamicIslandDisplayID(for: targetScreen)
    {
        let releasePoint = NSPoint(
            x: targetScreen.frame.midX,
            y: targetScreen.frame.midY
        )
        controller.rootControllerForSelfTest()
            .performCapsuleDragEndedForSelfTest(at: releasePoint)
        let expectedFrame = dynamicIslandFrame(
            size: dynamicIslandCapsuleSize,
            visibleFrame: targetScreen.visibleFrame
        )
        guard controller.targetDisplayID == targetDisplayID,
              controller.panel.frame == expectedFrame
        else {
            fputs("dynamic island cross-screen capsule snap self-test failed\n", stderr)
            exit(1)
        }
    }

    controller.expand(.tasks)
    controller.completeAnimationForSelfTest()
    let visibleFrame = controller.visibleFrameForSelfTest()
    let expectedExpandedSize = dynamicIslandPreferredExpandedSize(
        visibleFrame: visibleFrame
    )
    guard controller.state == .expanded(.tasks),
          controller.panel.allowsKeyWindow,
          controller.panel.styleMask.contains(.resizable),
          controller.panel.frame.size == expectedExpandedSize
    else {
        fputs("dynamic island expand tasks self-test failed\n", stderr)
        exit(1)
    }

    controller.setAnimationInProgressForSelfTest(true)
    controller.expand(.confirmation)
    guard controller.state == .expanded(.tasks) else {
        fputs("dynamic island animation gate self-test failed\n", stderr)
        exit(1)
    }
    controller.setAnimationInProgressForSelfTest(false)

    controller.expand(.quota)
    controller.completeAnimationForSelfTest()
    guard controller.state == .expanded(.quota),
          controller.panel.frame.size == expectedExpandedSize
    else {
        fputs("dynamic island tab switch self-test failed\n", stderr)
        exit(1)
    }

    let collapseInput = DynamicIslandFirstResponderProbe(
        frame: NSRect(x: 0, y: 0, width: 120, height: 24)
    )
    controller.panel.contentView?.addSubview(collapseInput)
    _ = controller.panel.makeFirstResponder(collapseInput)
    guard controller.panel.firstResponder === collapseInput else {
        fputs("dynamic island collapse key setup self-test failed\n", stderr)
        exit(1)
    }
    controller.handleEscapeForSelfTest()
    controller.completeAnimationForSelfTest()
    let collapseClearedFirstResponder =
        controller.panel.firstResponder !== collapseInput
    guard controller.state == .capsule,
          controller.panel.isVisible,
          controller.panel.frame.size == dynamicIslandFittedSize(
              requested: dynamicIslandCapsuleSize,
              visibleFrame: visibleFrame
          ),
          !controller.panel.styleMask.contains(.resizable),
          !controller.panel.allowsKeyWindow,
          !controller.panel.isKeyWindow,
          collapseClearedFirstResponder
    else {
        fputs("dynamic island escape collapse self-test failed\n", stderr)
        exit(1)
    }

    controller.expand(.tasks)
    controller.completeAnimationForSelfTest()
    controller.handleOutsideClickForSelfTest()
    controller.completeAnimationForSelfTest()
    guard controller.state == .capsule,
          controller.panel.isVisible,
          controller.panel.frame.size == dynamicIslandFittedSize(
              requested: dynamicIslandCapsuleSize,
              visibleFrame: visibleFrame
          )
    else {
        fputs("dynamic island outside collapse self-test failed\n", stderr)
        exit(1)
    }

    controller.expand(.confirmation)
    controller.completeAnimationForSelfTest()
    let hideInput = DynamicIslandFirstResponderProbe(
        frame: NSRect(x: 0, y: 0, width: 120, height: 24)
    )
    controller.panel.contentView?.addSubview(hideInput)
    controller.setConfirmationInputActive(true)
    _ = controller.panel.makeFirstResponder(hideInput)
    guard controller.panel.firstResponder === hideInput else {
        fputs("dynamic island key setup self-test failed\n", stderr)
        exit(1)
    }
    controller.setConfirmationInputActive(false)
    guard controller.panel.firstResponder !== hideInput,
          !controller.panel.isKeyWindow
    else {
        fputs("dynamic island confirmation focus release self-test failed\n", stderr)
        exit(1)
    }
    controller.setConfirmationInputActive(true)
    _ = controller.panel.makeFirstResponder(hideInput)
    controller.hide()
    let hideClearedFirstResponder =
        controller.panel.firstResponder !== hideInput
    guard controller.state == .hidden,
          controller.panel.level == panelDefaultWindowLevel,
          !controller.panel.isKeyWindow,
          hideClearedFirstResponder
    else {
        fputs("dynamic island hide self-test failed\n", stderr)
        exit(1)
    }

    controller.showCapsule()
    let panelEntry = WindowStackEntry(
        number: CGWindowID(controller.panel.windowNumber),
        ownerProcessID: 100,
        ownerName: "ThreadHelm 额度面板",
        name: "",
        alpha: 1,
        bounds: controller.panel.frame
    )
    let intersectingActivity = WindowStackEntry(
        number: 20,
        ownerProcessID: 200,
        ownerName: "ChatGPT",
        name: "Codex Pet Activity Stack Backing",
        alpha: 1,
        bounds: controller.panel.frame.insetBy(dx: 10, dy: 10)
    )
    controller.reconcileWindowLevel(entries: [panelEntry, intersectingActivity])
    guard controller.panel.level == panelNativeActivityWindowLevel,
          controller.panel.level.rawValue == panelDefaultWindowLevel.rawValue + 1,
          controller.panel.level.rawValue
              != NSWindow.Level.statusBar.rawValue + 2
    else {
        fputs("dynamic island native level self-test failed\n", stderr)
        exit(1)
    }

    controller.reconcileWindowLevel(entries: [panelEntry])
    guard controller.panel.level == panelDefaultWindowLevel else {
        fputs("dynamic island default level self-test failed\n", stderr)
        exit(1)
    }

    controller.hide()
}

private func assertDynamicIslandConfirmationWorkspace() {
    _ = NSApplication.shared
    let now = Date(timeIntervalSince1970: 40_000)
    let singleQuestion = ClaudeQuestion(
        answerKey: "format",
        header: "格式",
        options: [
            ClaudeQuestionOption(label: "简洁", detail: "只给结论"),
            ClaudeQuestionOption(label: "详细", detail: "包含解释"),
        ],
        allowsMultipleSelection: false
    )
    let multiQuestion = ClaudeQuestion(
        answerKey: "checks",
        header: "验证",
        options: [
            ClaudeQuestionOption(label: "单元测试", detail: nil),
            ClaudeQuestionOption(label: "构建检查", detail: nil),
        ],
        allowsMultipleSelection: true
    )
    let freeTextQuestion = ClaudeQuestion(
        answerKey: "notes",
        header: "备注",
        options: [],
        allowsMultipleSelection: false
    )

    guard dynamicIslandAnswerValue(
        question: singleQuestion,
        draft: DynamicIslandQuestionAnswerDraft(
            selectedOptionIndexes: [1],
            customText: "  自定义回答  "
        )
    ) as? String == "自定义回答",
          dynamicIslandAnswerValue(
              question: singleQuestion,
              draft: DynamicIslandQuestionAnswerDraft(
                  selectedOptionIndexes: [1],
                  customText: ""
              )
          ) as? String == "详细",
          dynamicIslandAnswerValue(
              question: multiQuestion,
              draft: DynamicIslandQuestionAnswerDraft(
                  selectedOptionIndexes: [1, 0],
                  customText: ""
              )
          ) as? String == "单元测试, 构建检查",
          dynamicIslandAnswerValue(
              question: singleQuestion,
              draft: DynamicIslandQuestionAnswerDraft()
          ) == nil
    else {
        fputs("dynamic island question draft value self-test failed\n", stderr)
        exit(1)
    }

    let questionPrompt = ClaudePermissionPrompt(
        requestID: UUID(),
        interactionKind: .askUserQuestion,
        toolName: "AskUserQuestion",
        sessionID: "12345678-1234-1234-1234-123456789abc",
        workingDirectory: "/tmp/threadhelm",
        title: "回答问题",
        message: "需要你的回答",
        planText: nil,
        questions: [singleQuestion, multiQuestion],
        originalToolInput: ["questions": []],
        suggestions: []
    )
    let questionController = DynamicIslandConfirmationViewController()
    var questionDecisions: [ClaudePermissionUserDecision] = []
    questionController.onDecision = { questionDecisions.append($0) }
    questionController.apply(ClaudePermissionPresentation(
        prompt: questionPrompt,
        queue: ClaudePermissionQueueSnapshot(
            current: ClaudePermissionQueueItem(
                requestID: questionPrompt.requestID,
                interactionKind: .askUserQuestion,
                title: questionPrompt.title,
                sessionID: questionPrompt.sessionID,
                arrivedAt: now
            )
        ),
        onDecision: { questionDecisions.append($0) }
    ))
    let questionFocusWindow = DynamicIslandWindowController()
    let questionFocusController = DynamicIslandConfirmationViewController()
    let questionFocusPresenter = questionFocusWindow.makeConfirmationPresenter(
        viewController: questionFocusController
    )
    questionFocusPresenter.setPresentationActive(true)
    questionFocusPresenter.present(ClaudePermissionPresentation(
        prompt: questionPrompt,
        queue: ClaudePermissionQueueSnapshot(
            current: ClaudePermissionQueueItem(
                requestID: questionPrompt.requestID,
                interactionKind: .askUserQuestion,
                title: questionPrompt.title,
                sessionID: questionPrompt.sessionID,
                arrivedAt: now
            )
        ),
        onDecision: { _ in }
    ))
    questionFocusWindow.completeAnimationForSelfTest()
    guard let questionInput = questionFocusController.initialInputResponder()
        as? NSTextField,
          questionInput.currentEditor() === questionFocusWindow.panel.firstResponder
    else {
        fputs("dynamic island question initial focus self-test failed\n", stderr)
        exit(1)
    }
    questionFocusWindow.hide()
    guard questionController.questionProgressTextForSelfTest().contains("已回答 0 / 2")
    else {
        fputs("dynamic island question progress initial self-test failed\n", stderr)
        exit(1)
    }
    questionController.clickQuestionOptionForSelfTest(index: 1, optionIndex: 0)
    questionController.buttonForSelfTest(title: "提交回答")?.performClick(nil)
    guard questionDecisions.isEmpty,
          questionController.currentQuestionIndexForSelfTest() == 0,
          questionController.validationTextForSelfTest()
              == "请先回答第 1 题，或选择“回到终端”。"
    else {
        fputs("dynamic island missing question navigation self-test failed\n", stderr)
        exit(1)
    }
    questionController.clickQuestionOptionForSelfTest(index: 0, optionIndex: 1)
    guard questionController.questionProgressTextForSelfTest().contains("已回答 2 / 2")
    else {
        fputs("dynamic island question progress answered self-test failed\n", stderr)
        exit(1)
    }
    questionController.buttonForSelfTest(title: "下一题")?.performClick(nil)
    guard questionController.currentQuestionIndexForSelfTest() == 1,
          questionController.questionDraftForSelfTest(index: 0)
            .selectedOptionIndexes == [1],
          questionController.questionDraftForSelfTest(index: 1)
            .selectedOptionIndexes == [0]
    else {
        fputs("dynamic island real question paging draft self-test failed\n", stderr)
        exit(1)
    }
    questionController.buttonForSelfTest(title: "上一题")?.performClick(nil)
    guard questionController.questionDraftForSelfTest(index: 0)
        .selectedOptionIndexes == [1]
    else {
        fputs("dynamic island real previous-page draft self-test failed\n", stderr)
        exit(1)
    }
    questionController.buttonForSelfTest(title: "下一题")?.performClick(nil)
    questionController.buttonForSelfTest(title: "提交回答")?.performClick(nil)
    guard questionDecisions.count == 1 else {
        fputs("dynamic island question submit self-test failed\n", stderr)
        exit(1)
    }

    let freeTextPrompt = ClaudePermissionPrompt(
        requestID: UUID(),
        interactionKind: .askUserQuestion,
        toolName: "AskUserQuestion",
        sessionID: nil,
        workingDirectory: "/tmp/threadhelm",
        title: "自由输入",
        message: "自由输入",
        planText: nil,
        questions: [freeTextQuestion],
        originalToolInput: [:],
        suggestions: []
    )
    let freeTextController = DynamicIslandConfirmationViewController()
    var freeTextAnswers: [String: Any] = [:]
    freeTextController.onDecision = {
        if case .submitAnswers(let answers) = $0 {
            freeTextAnswers = answers
        }
    }
    freeTextController.apply(ClaudePermissionPresentation(
        prompt: freeTextPrompt,
        queue: ClaudePermissionQueueSnapshot(current: ClaudePermissionQueueItem(
            requestID: freeTextPrompt.requestID,
            interactionKind: .askUserQuestion,
            title: freeTextPrompt.title,
            sessionID: nil,
            arrivedAt: now
        )),
        onDecision: { _ in }
    ))
    freeTextController.setQuestionTextForSelfTest(index: 0, text: "free answer")
    freeTextController.buttonForSelfTest(title: "提交回答")?.performClick(nil)
    guard freeTextAnswers["notes"] as? String == "free answer" else {
        fputs("dynamic island 1-question 0-option self-test failed\n", stderr)
        exit(1)
    }

    let boundaryQuestions = (0..<5).map { index in
        ClaudeQuestion(
            answerKey: "q\(index)",
            header: "边界 \(index)",
            options: (0..<5).map {
                ClaudeQuestionOption(label: "选项 \(index)-\($0)", detail: "说明")
            },
            allowsMultipleSelection: index == 2
        )
    }
    let boundaryPrompt = ClaudePermissionPrompt(
        requestID: UUID(),
        interactionKind: .askUserQuestion,
        toolName: "AskUserQuestion",
        sessionID: nil,
        workingDirectory: "/tmp/threadhelm",
        title: "边界问题",
        message: "边界",
        planText: nil,
        questions: boundaryQuestions,
        originalToolInput: [:],
        suggestions: []
    )
    let boundaryController = DynamicIslandConfirmationViewController()
    var boundaryAnswers: [String: Any] = [:]
    boundaryController.onDecision = {
        if case .submitAnswers(let answers) = $0 {
            boundaryAnswers = answers
        }
    }
    boundaryController.apply(ClaudePermissionPresentation(
        prompt: boundaryPrompt,
        queue: ClaudePermissionQueueSnapshot(current: ClaudePermissionQueueItem(
            requestID: boundaryPrompt.requestID,
            interactionKind: .askUserQuestion,
            title: boundaryPrompt.title,
            sessionID: nil,
            arrivedAt: now
        )),
        onDecision: { _ in }
    ))
    for index in 0..<5 {
        boundaryController.setCurrentQuestionIndexForSelfTest(index)
        if index == 2 {
            boundaryController.clickQuestionOptionForSelfTest(index: index, optionIndex: 1)
            boundaryController.clickQuestionOptionForSelfTest(index: index, optionIndex: 3)
        } else {
            boundaryController.clickQuestionOptionForSelfTest(index: index, optionIndex: 4)
        }
    }
    boundaryController.buttonForSelfTest(title: "提交回答")?.performClick(nil)
    guard boundaryAnswers["q0"] as? String == "选项 0-4",
          boundaryAnswers["q2"] as? String == "选项 2-1, 选项 2-3",
          boundaryAnswers["q4"] as? String == "选项 4-4"
    else {
        fputs("dynamic island real boundary question submit self-test failed\n", stderr)
        exit(1)
    }

    let maxSuggestions = (0..<20).map {
        ClaudePermissionSuggestion(
            title: "建议 \($0)",
            rawValue: ["id": $0, "type": "addRules"]
        )
    }
    let toolPrompt = ClaudePermissionPrompt(
        requestID: UUID(),
        interactionKind: .toolApproval,
        toolName: "Bash",
        sessionID: nil,
        workingDirectory: "/tmp/threadhelm",
        title: "允许 Bash",
        message: "运行项目测试",
        planText: nil,
        questions: [],
        originalToolInput: [
            "command": "swift test --very-long-secret-argument-that-must-be-bounded-in-ui",
            "description": "运行项目测试",
        ],
        suggestions: maxSuggestions
    )
    var inputActivationRequests: [Bool] = []
    let activationPresenter = DynamicIslandConfirmationPresenter(
        show: { _ in },
        dismissView: {},
        repositionWindow: {}
    )
    activationPresenter.setPresentationActive(true)
    activationPresenter.onSetKeyWindowEligibility = {
        inputActivationRequests.append($0)
    }
    activationPresenter.present(ClaudePermissionPresentation(
        prompt: toolPrompt,
        queue: ClaudePermissionQueueSnapshot(current: ClaudePermissionQueueItem(
            requestID: toolPrompt.requestID,
            interactionKind: .toolApproval,
            title: toolPrompt.title,
            sessionID: nil,
            arrivedAt: now
        )),
        onDecision: { _ in }
    ))
    activationPresenter.present(ClaudePermissionPresentation(
        prompt: questionPrompt,
        queue: ClaudePermissionQueueSnapshot(current: ClaudePermissionQueueItem(
            requestID: questionPrompt.requestID,
            interactionKind: .askUserQuestion,
            title: questionPrompt.title,
            sessionID: questionPrompt.sessionID,
            arrivedAt: now
        )),
        onDecision: { _ in }
    ))
    guard inputActivationRequests == [false, true] else {
        fputs("dynamic island confirmation activation policy self-test failed\n", stderr)
        exit(1)
    }
    var staleReturnCount = 0
    let stalePresenter = DynamicIslandConfirmationPresenter(
        show: { _ in },
        dismissView: {},
        repositionWindow: {}
    )
    stalePresenter.onReturnToPriorTab = { _ in staleReturnCount += 1 }
    stalePresenter.setPresentationActive(true)
    stalePresenter.present(ClaudePermissionPresentation(
        prompt: toolPrompt,
        queue: ClaudePermissionQueueSnapshot(current: ClaudePermissionQueueItem(
            requestID: toolPrompt.requestID,
            interactionKind: .toolApproval,
            title: toolPrompt.title,
            sessionID: nil,
            arrivedAt: now
        )),
        onDecision: { _ in }
    ))
    stalePresenter.dismiss()
    stalePresenter.setPresentationActive(false)
    stalePresenter.setPresentationActive(true)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    guard staleReturnCount == 0 else {
        fputs("dynamic island stale mode callback self-test failed\n", stderr)
        exit(1)
    }

    let terminalFallbackController = DynamicIslandConfirmationViewController()
    var terminalFallbackCount = 0
    var terminalFallbackDecisions: [ClaudePermissionUserDecision] = []
    terminalFallbackController.onReturnToTerminal = {
        terminalFallbackCount += 1
    }
    terminalFallbackController.onDecision = {
        terminalFallbackDecisions.append($0)
    }
    terminalFallbackController.apply(ClaudePermissionPresentation(
        prompt: toolPrompt,
        queue: ClaudePermissionQueueSnapshot(current: ClaudePermissionQueueItem(
            requestID: toolPrompt.requestID,
            interactionKind: .toolApproval,
            title: toolPrompt.title,
            sessionID: nil,
            arrivedAt: now
        )),
        onDecision: { terminalFallbackDecisions.append($0) }
    ))
    terminalFallbackController.buttonForSelfTest(title: "回到终端")?
        .performClick(nil)
    terminalFallbackController.buttonForSelfTest(title: "回到终端")?
        .performClick(nil)
    guard terminalFallbackCount == 1,
          terminalFallbackDecisions.count == 1,
          {
              if case .nativeFallback = terminalFallbackDecisions[0] {
                  return true
              }
              return false
          }()
    else {
        fputs("dynamic island terminal fallback exactly-once self-test failed\n", stderr)
        exit(1)
    }
    let nextPromptID = UUID()
    let nextPrompt = ClaudePermissionPrompt(
        requestID: nextPromptID,
        interactionKind: .exitPlanMode,
        toolName: "ExitPlanMode",
        sessionID: nil,
        workingDirectory: "/tmp/threadhelm",
        title: "Next Plan",
        message: "下一项",
        planText: "继续下一项。",
        questions: [],
        originalToolInput: [:],
        suggestions: []
    )
    let windowController = DynamicIslandWindowController()
    let inlineController = DynamicIslandConfirmationViewController()
    var emittedToolDecisions: [ClaudePermissionUserDecision] = []
    inlineController.onDecision = { emittedToolDecisions.append($0) }
    let presenter = windowController.makeConfirmationPresenter(
        viewController: inlineController
    )
    presenter.setPresentationActive(true)
    windowController.expand(.tasks)
    windowController.completeAnimationForSelfTest()
    presenter.present(ClaudePermissionPresentation(
        prompt: toolPrompt,
        queue: ClaudePermissionQueueSnapshot(
            current: ClaudePermissionQueueItem(
                requestID: toolPrompt.requestID,
                interactionKind: .toolApproval,
                title: toolPrompt.title,
                sessionID: nil,
                arrivedAt: now
            )
        ),
        onDecision: { emittedToolDecisions.append($0) }
    ))
    windowController.completeAnimationForSelfTest()
    inlineController.view.layoutSubtreeIfNeeded()
    guard inlineController.initialInputResponder() == nil,
          inlineController.queueRowCountForSelfTest() == 1,
          inlineController.queueTitlesForSelfTest() == [toolPrompt.title],
          inlineController.selectedQueueRowForSelfTest() == 0,
          inlineController.queueRowIsCurrentForSelfTest(0),
          !inlineController.queueShouldSelectRowForSelfTest(1),
          inlineController.keyEquivalentForButtonForSelfTest(title: "允许一次") == "\r",
          inlineController.keyEquivalentForButtonForSelfTest(title: "回到终端") == "",
          inlineController.keyEquivalentForButtonForSelfTest(title: "拒绝") == "",
          inlineController.keyEquivalentForButtonForSelfTest(title: "长期允许 建议 0") == "",
          inlineController.toolSuggestionButtonFramesForSelfTest().count == 20,
          inlineController.toolSuggestionButtonFramesForSelfTest().isNonOverlappingVertically
    else {
        fputs(
            "dynamic island tool max suggestions layout self-test failed "
                + "rows=\(inlineController.queueRowCountForSelfTest()) "
                + "selected=\(inlineController.selectedQueueRowForSelfTest()) "
                + "allowKey=\(inlineController.keyEquivalentForButtonForSelfTest(title: "允许一次") ?? "nil") "
                + "terminalKey=\(inlineController.keyEquivalentForButtonForSelfTest(title: "回到终端") ?? "nil") "
                + "denyKey=\(inlineController.keyEquivalentForButtonForSelfTest(title: "拒绝") ?? "nil") "
                + "suggestionKey=\(inlineController.keyEquivalentForButtonForSelfTest(title: "长期允许 建议 0") ?? "nil") "
                + "frames=\(inlineController.toolSuggestionButtonFramesForSelfTest())\n",
            stderr
        )
        exit(1)
    }
    inlineController.buttonForSelfTest(title: "长期允许 建议 12")?.performClick(nil)
    inlineController.buttonForSelfTest(title: "拒绝")?.performClick(nil)
    guard case .expanded(.confirmation) = windowController.state,
          emittedToolDecisions.count == 1,
          inlineController.decisionControlsEnabledForSelfTest() == false,
          inlineController.rawSummaryForSelfTest().count <= 90,
          {
              if case .allowWithSuggestion(let raw) = emittedToolDecisions[0] {
                  return raw["id"] as? Int == 12
              }
              return false
          }()
    else {
        fputs("dynamic island tool presenter decision self-test failed\n", stderr)
        exit(1)
    }
    let pendingQueue = ClaudePermissionQueueSnapshot(
        current: ClaudePermissionQueueItem(
            requestID: toolPrompt.requestID,
            interactionKind: .toolApproval,
            title: toolPrompt.title,
            sessionID: nil,
            arrivedAt: now
        ),
        pending: [
            ClaudePermissionQueueItem(
                requestID: nextPromptID,
                interactionKind: .exitPlanMode,
                title: "Pending",
                sessionID: nil,
                arrivedAt: now.addingTimeInterval(1)
            ),
        ]
    )
    windowController.rootControllerForSelfTest().apply(
        snapshot: ActivityDashboardSnapshot(permissionQueue: pendingQueue),
        state: .expanded(.confirmation)
    )
    guard inlineController.queueRowCountForSelfTest() == 2,
          inlineController.selectedQueueRowForSelfTest() == 0,
          inlineController.queueRowIsCurrentForSelfTest(0),
          !inlineController.queueRowIsCurrentForSelfTest(1),
          !inlineController.queueShouldSelectRowForSelfTest(1),
          inlineController.decisionControlsEnabledForSelfTest() == false
    else {
        fputs("dynamic island live queue update self-test failed\n", stderr)
        exit(1)
    }
    let transientQueue = ClaudePermissionQueueSnapshot(
        current: nil,
        pending: [
            ClaudePermissionQueueItem(
                requestID: nextPromptID,
                interactionKind: .exitPlanMode,
                title: "Pending",
                sessionID: nil,
                arrivedAt: now.addingTimeInterval(1)
            ),
        ]
    )
    windowController.rootControllerForSelfTest().apply(
        snapshot: ActivityDashboardSnapshot(permissionQueue: transientQueue),
        state: .expanded(.confirmation)
    )
    guard inlineController.queueRowCountForSelfTest() == 2,
          inlineController.selectedQueueRowForSelfTest() == 0,
          inlineController.queueRowIsCurrentForSelfTest(0),
          !inlineController.queueRowIsCurrentForSelfTest(1),
          !inlineController.queueShouldSelectRowForSelfTest(1),
          inlineController.decisionControlsEnabledForSelfTest() == false
    else {
        fputs("dynamic island transient queue advance self-test failed\n", stderr)
        exit(1)
    }
    presenter.present(ClaudePermissionPresentation(
        prompt: nextPrompt,
        queue: ClaudePermissionQueueSnapshot(current: ClaudePermissionQueueItem(
            requestID: nextPromptID,
            interactionKind: .exitPlanMode,
            title: nextPrompt.title,
            sessionID: nil,
            arrivedAt: now.addingTimeInterval(1)
        )),
        onDecision: { _ in }
    ))
    windowController.completeAnimationForSelfTest()
    guard inlineController.queueRowCountForSelfTest() == 1,
          inlineController.selectedQueueRowForSelfTest() == 0,
          inlineController.queueRowIsCurrentForSelfTest(0),
          inlineController.decisionControlsEnabledForSelfTest()
    else {
        fputs("dynamic island queue advance apply-next self-test failed\n", stderr)
        exit(1)
    }
    presenter.dismiss()
    windowController.handleEscapeForSelfTest()
    guard emittedToolDecisions.count == 1,
          case .capsule = windowController.state
    else {
        fputs("dynamic island dismiss/escape no-decision self-test failed\n", stderr)
        exit(1)
    }

    let planPrompt = ClaudePermissionPrompt(
        requestID: UUID(),
        interactionKind: .exitPlanMode,
        toolName: "ExitPlanMode",
        sessionID: nil,
        workingDirectory: "/tmp/threadhelm",
        title: "审批计划",
        message: "Claude 请求继续",
        planText: "先检查，再修改，最后验证。",
        questions: [],
        originalToolInput: [:],
        suggestions: []
    )
    let planFocusWindow = DynamicIslandWindowController()
    let planFocusController = DynamicIslandConfirmationViewController()
    let planFocusPresenter = planFocusWindow.makeConfirmationPresenter(
        viewController: planFocusController
    )
    planFocusPresenter.setPresentationActive(true)
    planFocusPresenter.present(ClaudePermissionPresentation(
        prompt: planPrompt,
        queue: ClaudePermissionQueueSnapshot(
            current: ClaudePermissionQueueItem(
                requestID: planPrompt.requestID,
                interactionKind: .exitPlanMode,
                title: planPrompt.title,
                sessionID: nil,
                arrivedAt: now
            )
        ),
        onDecision: { _ in }
    ))
    planFocusWindow.completeAnimationForSelfTest()
    guard let planInput = planFocusController.initialInputResponder()
        as? NSTextView,
          planFocusWindow.panel.firstResponder === planInput
    else {
        fputs("dynamic island plan initial focus self-test failed\n", stderr)
        exit(1)
    }
    planFocusWindow.hide()
    let planController = DynamicIslandConfirmationViewController()
    var planDecision: ClaudePermissionUserDecision?
    planController.onDecision = { planDecision = $0 }
    planController.apply(ClaudePermissionPresentation(
        prompt: planPrompt,
        queue: ClaudePermissionQueueSnapshot(
            current: ClaudePermissionQueueItem(
                requestID: planPrompt.requestID,
                interactionKind: .exitPlanMode,
                title: planPrompt.title,
                sessionID: nil,
                arrivedAt: now
            )
        ),
        onDecision: { planDecision = $0 }
    ))
    guard planController.planImpactTextForSelfTest().contains("批准后 Claude 将继续执行")
    else {
        fputs("dynamic island plan impact summary self-test failed\n", stderr)
        exit(1)
    }
    planController.buttonForSelfTest(title: "让 Claude 修改")?.performClick(nil)
    guard planDecision == nil,
          planController.validationTextForSelfTest()
              == "请先填写希望 Claude 修改的内容。"
    else {
        fputs("dynamic island empty plan feedback self-test failed\n", stderr)
        exit(1)
    }
    planController.setPlanFeedbackForSelfTest("请补充风险")
    planController.buttonForSelfTest(title: "让 Claude 修改")?.performClick(nil)
    guard planDecision != nil,
          planController.keyEquivalentForButtonForSelfTest(title: "批准并继续") == "\r",
          planController.keyEquivalentForButtonForSelfTest(title: "让 Claude 修改") == "",
          planController.keyEquivalentForButtonForSelfTest(title: "回到终端") == ""
    else {
        fputs("dynamic island plan feedback self-test failed\n", stderr)
        exit(1)
    }
}

func runDynamicIslandSelfTest() -> Never {
    let suite = "threadhelm-dynamic-island-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let now = Date()
    let active = (0..<7).map {
        TaskProgressItem(
            title: "Active \($0)",
            kind: .running,
            startedAt: now,
            updatedAt: now.addingTimeInterval(TimeInterval($0))
        )
    }
    let terminal = TaskProgressItem(
        title: "Done",
        kind: .completed,
        startedAt: now,
        updatedAt: now
    )
    let collection = TaskProgressCollectionSnapshot.displaying(active + [terminal])
    guard collection.items.count == 8,
          collection.compactProjection().items.count == 7,
          collection.compactProjection().isScrollable
    else { exit(1) }

    let store = ActivityDashboardStore()
    var observed: [ActivityDashboardSnapshot] = []
    let token = store.observe { observed.append($0) }
    store.update { $0.codexDesktopRunning = true }
    store.removeObserver(token)
    store.update { $0.codexDesktopRunning = false }
    guard observed.count == 2, observed.last?.codexDesktopRunning == true else {
        exit(1)
    }

    assertDynamicIslandPlacement()
    assertDynamicIslandStateAndLevel()
    assertDynamicIslandCapsulePresentation()
    assertDynamicIslandChromeAccessibility()
    assertDynamicIslandTaskWorkspace()
    assertDynamicIslandQuotaWorkspace()
    assertDynamicIslandConfirmationWorkspace()
    assertDynamicIslandPreviewRendering()

    let firstPromptID = UUID()
    let secondPromptID = UUID()
    let firstPrompt = ClaudePermissionPrompt(
        requestID: firstPromptID,
        interactionKind: .toolApproval,
        toolName: "Bash",
        sessionID: "12345678-1234-1234-1234-123456789abc",
        workingDirectory: "/tmp/threadhelm",
        title: "First",
        message: "First request",
        planText: nil,
        questions: [],
        originalToolInput: [:],
        suggestions: []
    )
    let secondPrompt = ClaudePermissionPrompt(
        requestID: secondPromptID,
        interactionKind: .toolApproval,
        toolName: "Read",
        sessionID: "87654321-4321-4321-4321-cba987654321",
        workingDirectory: "/tmp/threadhelm",
        title: "Second",
        message: "Second request",
        planText: nil,
        questions: [],
        originalToolInput: [:],
        suggestions: []
    )

    var openedTerminalPrompts: [UUID] = []
    var queueSnapshots: [ClaudePermissionQueueSnapshot] = []
    let coordinator = ClaudePermissionCoordinator(
        now: { now },
        openTerminal: { openedTerminalPrompts.append($0.requestID) },
        onQueueChange: { queueSnapshots.append($0) }
    )
    let firstPresenter = ClaudePermissionPresenterSpy()
    coordinator.setPresenter(firstPresenter)

    var firstDecisions: [ClaudePermissionUserDecision] = []
    var duplicateCompleted = false
    var secondDecisions: [ClaudePermissionUserDecision] = []
    coordinator.enqueue(prompt: firstPrompt) {
        firstDecisions.append($0)
    }
    coordinator.enqueue(prompt: firstPrompt) { _ in
        duplicateCompleted = true
    }
    coordinator.enqueue(prompt: secondPrompt) {
        secondDecisions.append($0)
    }
    guard queueSnapshots.map(\.count).suffix(2) == [1, 2],
          firstPresenter.presentations.count == 1,
          firstPresenter.presentations.last?.prompt.requestID == firstPromptID,
          firstPresenter.presentations.last?.queue.count == 1,
          !duplicateCompleted
    else { exit(1) }

    let secondPresenter = ClaudePermissionPresenterSpy()
    coordinator.setPresenter(secondPresenter)
    guard firstPresenter.dismissCount == 1,
          secondPresenter.presentations.count == 1,
          secondPresenter.presentations.last?.prompt.requestID == firstPromptID,
          firstDecisions.isEmpty,
          secondDecisions.isEmpty
    else { exit(1) }

    let decision = secondPresenter.presentations[0].onDecision
    decision(.allowOnce)
    decision(.deny("second tap must be ignored"))
    guard firstDecisions.count == 1,
          secondDecisions.isEmpty,
          secondPresenter.presentations.count == 2,
          secondPresenter.presentations.last?.prompt.requestID == secondPromptID,
          openedTerminalPrompts.isEmpty
    else { exit(1) }

    coordinator.expire(requestID: secondPromptID)
    guard secondDecisions.isEmpty,
          queueSnapshots.last == .empty,
          secondPresenter.dismissCount == 2
    else { exit(1) }

    var staleDecision: ((ClaudePermissionUserDecision) -> Void)?
    weak var releasedCompletionProbe: ClaudePermissionLifetimeProbe?
    do {
        let lifetimeCoordinator = ClaudePermissionCoordinator(
            now: { now },
            openTerminal: { _ in },
            onQueueChange: { _ in }
        )
        let lifetimePresenter = ClaudePermissionPresenterSpy()
        lifetimeCoordinator.setPresenter(lifetimePresenter)
        let probe = ClaudePermissionLifetimeProbe()
        releasedCompletionProbe = probe
        lifetimeCoordinator.enqueue(prompt: firstPrompt) { [probe] _ in
            _ = probe
        }
        staleDecision = lifetimePresenter.presentations.first?.onDecision
        lifetimeCoordinator.expire(requestID: firstPromptID)
    }
    guard staleDecision != nil,
          releasedCompletionProbe == nil
    else { exit(1) }
    staleDecision?(.allowOnce)
    guard releasedCompletionProbe == nil else { exit(1) }
    staleDecision = nil

    let terminalCoordinator = ClaudePermissionCoordinator(
        now: { now },
        openTerminal: { openedTerminalPrompts.append($0.requestID) },
        onQueueChange: { queueSnapshots.append($0) }
    )
    let terminalPresenter = ClaudePermissionPresenterSpy()
    terminalCoordinator.setPresenter(terminalPresenter)
    var terminalDecisions: [ClaudePermissionUserDecision] = []
    terminalCoordinator.enqueue(prompt: firstPrompt) {
        terminalDecisions.append($0)
    }
    let runningTask = TaskProgressItem(
        title: "Claude",
        kind: .running,
        source: .claudeCode,
        sessionID: firstPrompt.sessionID?.uppercased(),
        workingDirectory: "/tmp/threadhelm"
    )
    let waitingTask = TaskProgressItem(
        title: "Claude",
        kind: .waitingForInput,
        source: .claudeCode,
        sessionID: firstPrompt.sessionID?.uppercased(),
        workingDirectory: "/tmp/threadhelm"
    )
    guard !terminalCoordinator.dismissIfAnsweredInTerminal(in: [runningTask]),
          !terminalCoordinator.dismissIfAnsweredInTerminal(in: [waitingTask]),
          terminalCoordinator.dismissIfAnsweredInTerminal(in: [runningTask]),
          terminalDecisions.count == 1,
          openedTerminalPrompts.isEmpty
    else { exit(1) }

    let cancelCoordinator = ClaudePermissionCoordinator(
        now: { now },
        openTerminal: { openedTerminalPrompts.append($0.requestID) },
        onQueueChange: { queueSnapshots.append($0) }
    )
    var cancelDecisions: [ClaudePermissionUserDecision] = []
    cancelCoordinator.enqueue(prompt: firstPrompt) { cancelDecisions.append($0) }
    cancelCoordinator.enqueue(prompt: secondPrompt) { cancelDecisions.append($0) }
    cancelCoordinator.cancelAll()
    guard cancelDecisions.count == 2,
          cancelDecisions.allSatisfy({
              if case .nativeFallback = $0 { return true }
              return false
          }),
          openedTerminalPrompts.isEmpty
    else { exit(1) }

    print(
        "dynamic-island: presentation=dynamic-island-only "
            + "placement=notch-safe+negative-screen+small-screen "
            + "capsule-drag=threshold+cross-screen-snap "
            + "state-machine=pass "
            + "capsule-priority=7/7 fake-progress=absent "
            + "activity-sanitizer=pass selected-task-key=preserved "
            + "brand=ThreadHelm controls=accessible palette=independent "
            + "fonts=min-12 preview=18-states+2x "
            + "collection=full+compact store-observer=pass quota-snapshot=pass "
            + "quota-workspace=left-228+rows+reset-credits "
            + "quota-phases=6/6 stale-data=preserved+scroll-no-overlap "
            + "top-tabs=tasks+agents+quota confirmation=transient "
            + "manual-refresh=tasks+all-providers "
            + "window-actions=refresh+hide+provider+copy+detail-ack "
            + "passive-refresh=no-ack "
            + "filters=source+state selection=stable "
            + "detail-events=all-safe+scroll current-activity=latest copy-path=absolute-only "
            + "source-action=immediate open-callback=forwarded "
            + "hover=no-selection-change+collapse-hide "
            + "terminal-time=stable "
            + "permission-coordinator=dedupe+fifo presenter-switch=no-completion "
            + "decision=exactly-once expire=no-completion "
            + "stale-presentation=releases-completion "
            + "terminal-auto-dismiss=gated cancel-all=no-terminal "
            + "confirmation=draft+missing-answer+tool+plan+dismiss+escape "
            + "confirmation-round1=live-queue+real-controls+factory"
            + "+keys+max-suggestions "
            + "confirmation-round2=transient-advance"
    )
    exit(0)
}
