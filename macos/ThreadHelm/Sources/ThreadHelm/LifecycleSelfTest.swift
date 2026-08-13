//
//  LifecycleSelfTest.swift
//  ThreadHelm
//
//  模块职责：--self-test-lifecycle 自测——Codex 桌面应用识别、动态岛显隐
//  决策、原生活动窗口/无障碍标签匹配、屏外摆放、活动开关点击目标
//  与抑制策略。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

func runLifecycleSelfTest() -> Never {
    struct DesktopCase {
        let bundleIdentifier: String?
        let localizedName: String?
        let bundlePath: String?
        let activationPolicy: NSApplication.ActivationPolicy
        let expected: Bool
    }

    let desktopCases = [
        DesktopCase(
            bundleIdentifier: "com.openai.codex",
            localizedName: "ChatGPT",
            bundlePath: "/Applications/ChatGPT.app",
            activationPolicy: .regular,
            expected: true
        ),
        DesktopCase(
            bundleIdentifier: "com.openai.chatgpt",
            localizedName: "ChatGPT",
            bundlePath: "/Applications/ChatGPT.app",
            activationPolicy: .regular,
            expected: true
        ),
        DesktopCase(
            bundleIdentifier: nil,
            localizedName: "Codex",
            bundlePath: "/Applications/Codex.app",
            activationPolicy: .regular,
            expected: true
        ),
        DesktopCase(
            bundleIdentifier: threadHelmBundleIdentifier,
            localizedName: "ThreadHelm",
            bundlePath: "/Applications/ThreadHelm.app",
            activationPolicy: .regular,
            expected: false
        ),
        DesktopCase(
            bundleIdentifier: legacyThreadHelmBundleIdentifiers[0],
            localizedName: "ChatBird",
            bundlePath: "/Applications/ChatBird.app",
            activationPolicy: .regular,
            expected: false
        ),
        DesktopCase(
            bundleIdentifier: legacyThreadHelmBundleIdentifiers[1],
            localizedName: "ChatBird 额度面板",
            bundlePath: "/Applications/ChatBird 额度面板.app",
            activationPolicy: .accessory,
            expected: false
        ),
        DesktopCase(
            bundleIdentifier: nil,
            localizedName: "codex",
            bundlePath: "/usr/local/bin/codex",
            activationPolicy: .prohibited,
            expected: false
        ),
    ]

    for (index, test) in desktopCases.enumerated() {
        let actual = isCodexDesktopApplication(
            bundleIdentifier: test.bundleIdentifier,
            localizedName: test.localizedName,
            bundleURL: test.bundlePath.map { URL(fileURLWithPath: $0) },
            activationPolicy: test.activationPolicy
        )
        guard actual == test.expected else {
            fputs("desktop lifecycle case \(index + 1) failed\n", stderr)
            exit(1)
        }
    }

    guard dynamicIslandVisibilityAction(
        hiddenByUser: false,
        hasCurrentPermissionRequest: false
    ) == .capsule,
          dynamicIslandVisibilityAction(
              hiddenByUser: false,
              hasCurrentPermissionRequest: true
          ) == .confirmation,
          dynamicIslandVisibilityAction(
              hiddenByUser: true,
              hasCurrentPermissionRequest: true
          ) == .hidden
    else {
        fputs("dynamic-island-only visibility decision failed\n", stderr)
        exit(1)
    }

    let presentationCommands: [PresentationCommand] = [
        .toggleVisibility,
        .moveToCurrentDisplay,
        .quit,
    ]
    guard presentationCommands.count == 3 else {
        fputs("dynamic-island-only command coverage failed\n", stderr)
        exit(1)
    }

    let statusButton = NSStatusBarButton(frame: .zero)
    configureThreadHelmStatusButton(statusButton)
    guard let dockIcon = makeThreadHelmDockIcon(),
          threadHelmStatusItemLength == NSStatusItem.variableLength,
          statusButton.title == "ThreadHelm",
          statusButton.image == nil,
          statusButton.imagePosition == .noImage,
          statusButton.toolTip?.contains("显示/隐藏") == true,
          dockIcon.size.width >= 512,
          dockIcon.size.height >= 512,
          dockIcon.isTemplate == false,
          dockIcon.accessibilityDescription == "ThreadHelm",
          threadHelmActivationPolicy(panelHidden: false) == .regular,
          threadHelmActivationPolicy(panelHidden: true) == .regular,
          threadHelmVisibilityHotKeyKeyEquivalent == "b",
          threadHelmVisibilityHotKeyModifierMask == [.command, .option],
          threadHelmVisibilityHotKeyDisplayName == "⌥⌘B"
    else {
        fputs("status item recovery configuration failed\n", stderr)
        exit(1)
    }

    let preferenceSuite = "threadhelm-app-migration-\(UUID().uuidString)"
    guard let migratedDefaults = UserDefaults(suiteName: preferenceSuite) else {
        exit(1)
    }
    defer { migratedDefaults.removePersistentDomain(forName: preferenceSuite) }
    migratedDefaults.set(
        QuotaProvider.codex.rawValue,
        forKey: "selected-quota-provider"
    )
    let migratedKeys = migrateLegacyThreadHelmPreferences(
        from: [
            [
                "presentation-mode": "pet-panel",
                "pet-enabled": true,
                "selected-quota-provider": QuotaProvider.claudeCode.rawValue,
                "chatbird-pet-origin": [120.0, 240.0],
                "unrelated-value": "must-not-migrate",
            ],
            [
                "selected-quota-provider": QuotaProvider.claudeCode.rawValue,
            ],
        ],
        to: migratedDefaults
    )
    guard threadHelmBundleIdentifier == "dev.threadhelm.app",
          threadHelmLaunchAgentLabel == threadHelmBundleIdentifier,
          legacyThreadHelmBundleIdentifiers == [
              "dev.chatbird.app",
              "dev.chatbird.codex-quota-panel",
          ],
          migratedKeys.isEmpty,
          migratedDefaults.object(forKey: "presentation-mode") == nil,
          migratedDefaults.object(forKey: "pet-enabled") == nil,
          migratedDefaults.object(forKey: "chatbird-pet-origin") == nil,
          QuotaProviderPreference(defaults: migratedDefaults).selectedProvider
            == .codex,
          migratedDefaults.object(forKey: "unrelated-value") == nil
    else {
        fputs("ThreadHelm identity or preference migration failed\n", stderr)
        exit(1)
    }

    let now = Date(timeIntervalSince1970: 12_345)
    let activeTask = TaskProgressItem(
        title: "Active",
        kind: .running,
        updatedAt: now
    )
    let completedTask = TaskProgressItem(
        title: "Done",
        kind: .completed,
        updatedAt: now
    )
    let failedTask = TaskProgressItem(
        title: "Failed",
        kind: .failed,
        updatedAt: now
    )
    var acknowledgementKeys = Set<String>()
    acknowledgeTerminalTask(completedTask, in: &acknowledgementKeys)
    acknowledgeTerminalTask(activeTask, in: &acknowledgementKeys)
    guard let completedKey = terminalTaskAcknowledgementKey(for: completedTask),
          acknowledgementKeys == [completedKey]
    else {
        fputs("completed task acknowledgement failed\n", stderr)
        exit(1)
    }
    acknowledgeTerminalTask(failedTask, in: &acknowledgementKeys)
    guard let failedKey = terminalTaskAcknowledgementKey(for: failedTask),
          acknowledgementKeys == [completedKey, failedKey]
    else {
        fputs("failed task acknowledgement failed\n", stderr)
        exit(1)
    }

    let claudePermissionVisibilityCases = [
        (cached: true, live: true, expected: true),
        (cached: false, live: true, expected: true),
        (cached: true, live: false, expected: false),
        (cached: false, live: false, expected: false),
    ]
    for (index, test) in claudePermissionVisibilityCases.enumerated() {
        let actual = shouldPresentClaudePermissionPanel(
            cachedCodexDesktopRunning: test.cached,
            liveCodexDesktopRunning: test.live
        )
        guard actual == test.expected else {
            fputs("Claude permission visibility case \(index + 1) failed\n", stderr)
            exit(1)
        }
    }

    let activityWindowTitles: [(String?, Bool)] = [
        ("Codex Pet Composition Surface", true),
        ("  CODEX PET COMPOSITION SURFACE  ", true),
        ("Codex Pet Activity Stack Backing", false),
        ("ChatGPT", false),
        (nil, false),
    ]
    for (title, expected) in activityWindowTitles {
        guard isNativeActivityPillWindowTitle(title) == expected else {
            fputs(
                "activity-window title '\(title ?? "nil")' did not match expected=\(expected)\n",
                stderr
            )
            exit(1)
        }
    }

    let showActivityLabels = [
        ("Show activity, 1 item", true),
        ("  SHOW ACTIVITY, 27 ITEMS  ", true),
        ("显示活动，1 项", true),
        ("显示活动, 12项", true),
        ("Show activity", false),
        ("Show activity, one item", false),
        ("Hide activity", false),
    ]
    for (label, expected) in showActivityLabels {
        guard isShowActivityAccessibilityLabel(label) == expected else {
            fputs(
                "show-activity label '\(label)' did not match expected=\(expected)\n",
                stderr
            )
            exit(1)
        }
    }

    let badgeWindowCases: [(String?, Bool, Bool)] = [
        ("Codex Pet Composition Surface", true, true),
        ("Codex Pet Composition Surface", false, false),
        ("Codex Pet Activity Stack Backing", true, false),
    ]
    for (title, hasShowActivityButton, expected) in badgeWindowCases {
        guard shouldHideNativeActivityBadgeWindow(
            title: title,
            hasShowActivityButton: hasShowActivityButton
        ) == expected
        else {
            fputs("native activity badge-window selection failed\n", stderr)
            exit(1)
        }
    }

    let displayBounds = [
        CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080),
        CGRect(x: 0, y: -180, width: 2_560, height: 1_440),
    ]
    let badgeWindowSize = CGSize(width: 34, height: 34)
    guard let hiddenBadgeOrigin = offscreenOrigin(
        displayBounds: displayBounds,
        windowSize: badgeWindowSize,
        margin: 64
    ),
          abs(hiddenBadgeOrigin.x - (-2_018)) <= 0.01,
          abs(hiddenBadgeOrigin.y - (-278)) <= 0.01,
          displayBounds.allSatisfy({
              !$0.intersects(
                  CGRect(origin: hiddenBadgeOrigin, size: badgeWindowSize)
              )
          }),
          offscreenOrigin(
              displayBounds: [],
              windowSize: badgeWindowSize
          ) == nil,
          offscreenOrigin(
              displayBounds: displayBounds,
              windowSize: .zero
          ) == nil
    else {
        fputs("native activity badge offscreen placement failed\n", stderr)
        exit(1)
    }

    guard isNativeActivityToggleWindowTitle("Codex Pet Voice Controls Backing"),
          !isNativeActivityToggleWindowTitle("Codex Pet Activity Stack Backing"),
          let togglePoint = nativeActivityToggleClickPoint(
              position: CGPoint(x: 1_768, y: 836),
              size: CGSize(width: 24, height: 24)
          ),
          abs(togglePoint.x - 1_780) <= 0.01,
          abs(togglePoint.y - 848) <= 0.01,
          nativeActivityToggleClickPoint(
              position: CGPoint(x: 1_700, y: 800),
              size: CGSize(width: 120, height: 120)
          ) == nil
    else {
        fputs("activity-toggle target validation failed\n", stderr)
        exit(1)
    }

    let accessibilityLabels = [
        ("Hide activity", true),
        ("隐藏活动", true),
        ("Show activity, 1 item", false),
        ("显示活动，1 项", false),
        ("Hide ThreadHelm", false),
    ]
    for (label, expected) in accessibilityLabels {
        guard isHideActivityAccessibilityLabel(label) == expected else {
            fputs(
                "accessibility-label '\(label)' did not match expected=\(expected)\n",
                stderr
            )
            exit(1)
        }
    }

    let muteTaskMenuTitles = [
        ("Mute task", true),
        ("  MUTE TASK  ", true),
        ("静音任务", true),
        ("Hide activity", false),
        ("Unmute task", false),
    ]
    guard muteTaskMenuTitles.allSatisfy({
        isMuteTaskMenuItemTitle($0.0) == $0.1
    }) else {
        fputs("mute-task menu title matching failed\n", stderr)
        exit(1)
    }

    guard nativeActivitySuppressionStrategy(notificationButtonCount: 0) == .wait,
          nativeActivitySuppressionStrategy(notificationButtonCount: 1) == .muteViaMenu
    else {
        fputs("native activity suppression strategy failed\n", stderr)
        exit(1)
    }

    print("lifecycle-self-test: desktop-app=6/6 standalone-identity=pass legacy-preferences=pet-keys-ignored dynamic-island-only=visibility+commands status-item=restore dock-icon=resource activation=regular terminal-ack=active-skipped+terminal-memory claude-permission-visibility=4/4 live-state-wins=2/2 activity-window=5/5 show-activity-label=7/7 badge-window-selection=3/3 offscreen-placement=5/5 activity-toggle-target=6/6 accessibility-label=5/5 mute-menu=5/5 no-input-injection=2/2 hidden-window=orderOut")
    exit(0)
}
