//
//  ZCodeAgentAdapterSelfTest.swift
//  ThreadHelm
//
//  模块职责：ZCode Phase 4 lane 的隔离自测。只读写临时目录，绝不触碰真实
//  ~/.zcode/cli/config.json。
//

import Foundation

func runZCodeAgentAdapterSelfTest() {
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-zcode-adapter-self-test-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? manager.removeItem(at: temporaryRoot) }

    do {
        try manager.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        try runZCodeDiscoveryAndLifecycleSelfTest(at: temporaryRoot)
        try runZCodeSemanticMergeSelfTest(at: temporaryRoot)
        try runZCodeKeyOrderPreservationSelfTest(at: temporaryRoot)
        try runZCodeMalformedConfigPreservationSelfTest(at: temporaryRoot)
        try runZCodeDisabledHooksSelfTest(at: temporaryRoot)
        try runZCodeFreshConfigurationEnabledSelfTest(at: temporaryRoot)
        try runZCodeFreshConfigurationUninstallSelfTest(at: temporaryRoot)
        try runZCodeMissingOwnershipMarkerRepairSelfTest(at: temporaryRoot)
        try runZCodeResidualOwnershipMarkerRepairSelfTest(at: temporaryRoot)
        try runZCodeDisabledMissingMarkerRepairSelfTest(at: temporaryRoot)
        try runZCodeCorruptOwnershipMarkerRepairSelfTest(at: temporaryRoot)
        try runZCodeCorruptOrphanMarkerRepairSelfTest(at: temporaryRoot)
        try runZCodeV1OwnershipMarkerMigrationSelfTest(at: temporaryRoot)
        try runZCodeLegacyOwnedConfigurationMigrationSelfTest(
            at: temporaryRoot
        )
        try runZCodeExistingEnabledOnlyConfigPreservationSelfTest(
            at: temporaryRoot
        )
        try runZCodeDefaultDisabledSelfTest(at: temporaryRoot)
        try runZCodeObservationSelfTest()
        try runZCodeOpenSelfTest()
    } catch {
        fputs("zcode-adapter-self-test failed: \(error)\n", stderr)
        exit(1)
    }
}

private func runZCodeFreshConfigurationEnabledSelfTest(at root: URL) throws {
    let scopeRoot = root.appendingPathComponent(
        "fresh-enabled",
        isDirectory: true
    )
    let configURL = zcodeSelfTestConfigURL(root: scopeRoot)
    let adapter = zcodeSelfTestAdapter()
    let scope = AgentIntegrationScope.isolated(at: scopeRoot)

    guard !FileManager.default.fileExists(atPath: configURL.path),
          adapter.integrationStatus(in: scope) == .notInstalled,
          try adapter.installIntegration(in: scope) == .installed,
          adapter.integrationStatus(in: scope) == .installed,
          try adapter.installIntegration(in: scope) == .unchanged
    else {
        throw ZCodeSelfTestError.failure(
            "fresh ThreadHelm-owned config must enable ZCode hooks"
        )
    }
    let installed = try zcodeSelfTestJSON(at: configURL)
    let hooks = installed["hooks"] as? [String: Any]
    guard hooks?["enabled"] as? Bool == true,
          hooks?["events"] is [String: Any]
    else {
        throw ZCodeSelfTestError.failure(
            "fresh ThreadHelm-owned config did not persist enabled hooks"
        )
    }
}

private func runZCodeFreshConfigurationUninstallSelfTest(at root: URL) throws {
    let scopeRoot = root.appendingPathComponent(
        "fresh-uninstall",
        isDirectory: true
    )
    let configURL = zcodeSelfTestConfigURL(root: scopeRoot)
    let adapter = zcodeSelfTestAdapter()
    let scope = AgentIntegrationScope.isolated(at: scopeRoot)

    guard try adapter.installIntegration(in: scope) == .installed,
          try adapter.uninstallIntegration(in: scope) == .uninstalled,
          !FileManager.default.fileExists(atPath: configURL.path),
          adapter.integrationStatus(in: scope) == .notInstalled
    else {
        throw ZCodeSelfTestError.failure(
            "uninstall must remove a fully ThreadHelm-owned fresh config"
        )
    }
}

private func runZCodeMissingOwnershipMarkerRepairSelfTest(
    at root: URL
) throws {
    let scopeRoot = root.appendingPathComponent(
        "missing-ownership-marker",
        isDirectory: true
    )
    let configURL = zcodeSelfTestConfigURL(root: scopeRoot)
    let ownershipURL = configURL.deletingLastPathComponent()
        .appendingPathComponent(".threadhelm-config-owner")
    let adapter = zcodeSelfTestAdapter()
    let scope = AgentIntegrationScope.isolated(at: scopeRoot)

    guard try adapter.installIntegration(in: scope) == .installed else {
        throw ZCodeSelfTestError.failure(
            "missing-marker setup did not install"
        )
    }
    try FileManager.default.removeItem(at: ownershipURL)
    guard adapter.integrationStatus(in: scope) == .needsRepair,
          try adapter.repairIntegration(in: scope) == .repaired,
          adapter.integrationStatus(in: scope) == .installed,
          try adapter.uninstallIntegration(in: scope) == .uninstalled,
          FileManager.default.fileExists(atPath: configURL.path),
          !FileManager.default.fileExists(atPath: ownershipURL.path),
          let hooks = try zcodeSelfTestJSON(at: configURL)["hooks"]
            as? [String: Any],
          hooks["enabled"] as? Bool == true,
          hooks["events"] == nil
    else {
        throw ZCodeSelfTestError.failure(
            "missing ZCode ownership marker was not safely repaired"
        )
    }
}

private func runZCodeResidualOwnershipMarkerRepairSelfTest(
    at root: URL
) throws {
    let scopeRoot = root.appendingPathComponent(
        "residual-ownership-marker",
        isDirectory: true
    )
    let configURL = zcodeSelfTestConfigURL(root: scopeRoot)
    let ownershipURL = configURL.deletingLastPathComponent()
        .appendingPathComponent(".threadhelm-config-owner")
    let adapter = zcodeSelfTestAdapter()
    let scope = AgentIntegrationScope.isolated(at: scopeRoot)

    guard try adapter.installIntegration(in: scope) == .installed else {
        throw ZCodeSelfTestError.failure(
            "residual-marker setup did not install"
        )
    }
    try zcodeSelfTestWriteJSON(["theme": "keep"], to: configURL)
    guard adapter.integrationStatus(in: scope) == .needsRepair,
          try adapter.repairIntegration(in: scope) == .repaired,
          adapter.integrationStatus(in: scope) == .installed,
          try adapter.uninstallIntegration(in: scope) == .uninstalled,
          FileManager.default.fileExists(atPath: configURL.path),
          !FileManager.default.fileExists(atPath: ownershipURL.path),
          try zcodeSelfTestJSON(at: configURL)["theme"] as? String == "keep",
          (try zcodeSelfTestJSON(at: configURL))["hooks"] == nil
    else {
        throw ZCodeSelfTestError.failure(
            "residual ZCode ownership marker was not safely repaired"
        )
    }
}

private func runZCodeDisabledMissingMarkerRepairSelfTest(
    at root: URL
) throws {
    let scopeRoot = root.appendingPathComponent(
        "disabled-missing-marker",
        isDirectory: true
    )
    let configURL = zcodeSelfTestConfigURL(root: scopeRoot)
    let ownershipURL = configURL.deletingLastPathComponent()
        .appendingPathComponent(".threadhelm-config-owner")
    let adapter = zcodeSelfTestAdapter()
    let scope = AgentIntegrationScope.isolated(at: scopeRoot)

    guard try adapter.installIntegration(in: scope) == .installed else {
        throw ZCodeSelfTestError.failure(
            "disabled missing-marker setup did not install"
        )
    }
    var config = try zcodeSelfTestJSON(at: configURL)
    var hooks = config["hooks"] as? [String: Any] ?? [:]
    hooks["enabled"] = false
    config["hooks"] = hooks
    try zcodeSelfTestWriteJSON(config, to: configURL)
    try FileManager.default.removeItem(at: ownershipURL)

    guard adapter.integrationStatus(in: scope) == .needsRepair,
          try adapter.repairIntegration(in: scope) == .repaired,
          adapter.integrationStatus(in: scope) == .disabled,
          FileManager.default.fileExists(atPath: ownershipURL.path),
          try adapter.uninstallIntegration(in: scope) == .uninstalled,
          FileManager.default.fileExists(atPath: configURL.path),
          !FileManager.default.fileExists(atPath: ownershipURL.path),
          let remainingHooks = try zcodeSelfTestJSON(at: configURL)["hooks"]
            as? [String: Any],
          remainingHooks["enabled"] as? Bool == false,
          remainingHooks["events"] == nil
    else {
        throw ZCodeSelfTestError.failure(
            "disabled ZCode config did not repair its missing marker safely"
        )
    }
}

private func runZCodeCorruptOwnershipMarkerRepairSelfTest(
    at root: URL
) throws {
    let scopeRoot = root.appendingPathComponent(
        "corrupt-ownership-marker",
        isDirectory: true
    )
    let configURL = zcodeSelfTestConfigURL(root: scopeRoot)
    let ownershipURL = configURL.deletingLastPathComponent()
        .appendingPathComponent(".threadhelm-config-owner")
    try FileManager.default.createDirectory(
        at: configURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try zcodeSelfTestWriteJSON([
        "theme": "keep",
        "hooks": ["enabled": true],
    ], to: configURL)

    let adapter = zcodeSelfTestAdapter()
    let scope = AgentIntegrationScope.isolated(at: scopeRoot)
    guard try adapter.installIntegration(in: scope) == .installed else {
        throw ZCodeSelfTestError.failure(
            "corrupt-marker setup did not install"
        )
    }
    try Data("corrupt-owner\n".utf8).write(to: ownershipURL)

    guard adapter.integrationStatus(in: scope) == .needsRepair,
          try adapter.repairIntegration(in: scope) == .repaired,
          adapter.integrationStatus(in: scope) == .installed,
          try adapter.uninstallIntegration(in: scope) == .uninstalled,
          FileManager.default.fileExists(atPath: configURL.path),
          !FileManager.default.fileExists(atPath: ownershipURL.path),
          try zcodeSelfTestJSON(at: configURL)["theme"] as? String == "keep",
          let remainingHooks = try zcodeSelfTestJSON(at: configURL)["hooks"]
            as? [String: Any],
          remainingHooks["enabled"] as? Bool == true,
          remainingHooks["events"] == nil
    else {
        throw ZCodeSelfTestError.failure(
            "corrupt ZCode ownership marker was not safely repaired"
        )
    }
}

private func runZCodeCorruptOrphanMarkerRepairSelfTest(
    at root: URL
) throws {
    let scopeRoot = root.appendingPathComponent(
        "corrupt-orphan-marker",
        isDirectory: true
    )
    let configURL = zcodeSelfTestConfigURL(root: scopeRoot)
    let ownershipURL = configURL.deletingLastPathComponent()
        .appendingPathComponent(".threadhelm-config-owner")
    try FileManager.default.createDirectory(
        at: configURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("corrupt-owner\n".utf8).write(to: ownershipURL)

    let adapter = zcodeSelfTestAdapter()
    let scope = AgentIntegrationScope.isolated(at: scopeRoot)
    guard adapter.integrationStatus(in: scope) == .needsRepair,
          try adapter.repairIntegration(in: scope) == .repaired,
          adapter.integrationStatus(in: scope) == .installed,
          try adapter.uninstallIntegration(in: scope) == .uninstalled,
          !FileManager.default.fileExists(atPath: configURL.path),
          !FileManager.default.fileExists(atPath: ownershipURL.path)
    else {
        throw ZCodeSelfTestError.failure(
            "orphaned corrupt ZCode marker was not safely repaired"
        )
    }
}

private func runZCodeV1OwnershipMarkerMigrationSelfTest(
    at root: URL
) throws {
    let scopeRoot = root.appendingPathComponent(
        "v1-ownership-marker",
        isDirectory: true
    )
    let configURL = zcodeSelfTestConfigURL(root: scopeRoot)
    let ownershipURL = configURL.deletingLastPathComponent()
        .appendingPathComponent(".threadhelm-config-owner")
    let adapter = zcodeSelfTestAdapter()
    let scope = AgentIntegrationScope.isolated(at: scopeRoot)

    guard try adapter.installIntegration(in: scope) == .installed else {
        throw ZCodeSelfTestError.failure(
            "v1 ownership-marker setup did not install"
        )
    }
    try Data("threadhelm-managed-zcode-config-v1\n".utf8)
        .write(to: ownershipURL)

    guard adapter.integrationStatus(in: scope) == .needsRepair,
          try adapter.repairIntegration(in: scope) == .repaired,
          adapter.integrationStatus(in: scope) == .installed,
          try adapter.uninstallIntegration(in: scope) == .uninstalled,
          !FileManager.default.fileExists(atPath: configURL.path),
          !FileManager.default.fileExists(atPath: ownershipURL.path)
    else {
        throw ZCodeSelfTestError.failure(
            "v1 ZCode ownership marker was not migrated as created"
        )
    }
}

private func runZCodeExistingEnabledOnlyConfigPreservationSelfTest(
    at root: URL
) throws {
    let scopeRoot = root.appendingPathComponent(
        "existing-enabled-only",
        isDirectory: true
    )
    let configURL = zcodeSelfTestConfigURL(root: scopeRoot)
    try FileManager.default.createDirectory(
        at: configURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try zcodeSelfTestWriteJSON([
        "hooks": ["enabled": true],
    ], to: configURL)

    let adapter = zcodeSelfTestAdapter()
    let scope = AgentIntegrationScope.isolated(at: scopeRoot)
    guard try adapter.installIntegration(in: scope) == .installed,
          try adapter.uninstallIntegration(in: scope) == .uninstalled,
          FileManager.default.fileExists(atPath: configURL.path),
          let hooks = try zcodeSelfTestJSON(at: configURL)["hooks"]
            as? [String: Any],
          hooks["enabled"] as? Bool == true,
          hooks["events"] == nil
    else {
        throw ZCodeSelfTestError.failure(
            "uninstall removed an existing enabled-only ZCode config"
        )
    }
}

private func runZCodeLegacyOwnedConfigurationMigrationSelfTest(
    at root: URL
) throws {
    let scopeRoot = root.appendingPathComponent(
        "legacy-owned-migration",
        isDirectory: true
    )
    let configURL = zcodeSelfTestConfigURL(root: scopeRoot)
    try FileManager.default.createDirectory(
        at: configURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let eventNames = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PostToolUseFailure",
        "Stop",
    ]
    var events: [String: Any] = [:]
    for eventName in eventNames {
        events[eventName] = [[
            "hooks": [zcodeSelfTestOwnedHook(
                eventName: eventName,
                executablePath: "/tmp/threadhelm-zcode-adapter"
            )],
        ]]
    }
    try zcodeSelfTestWriteJSON([
        "hooks": ["events": events],
    ], to: configURL)

    let adapter = zcodeSelfTestAdapter()
    let scope = AgentIntegrationScope.isolated(at: scopeRoot)
    guard adapter.integrationStatus(in: scope) == .needsRepair,
          try adapter.installIntegration(in: scope) == .installed,
          adapter.integrationStatus(in: scope) == .installed,
          try adapter.uninstallIntegration(in: scope) == .uninstalled,
          !FileManager.default.fileExists(atPath: configURL.path)
    else {
        throw ZCodeSelfTestError.failure(
            "legacy ThreadHelm-only ZCode config was not migrated"
        )
    }
}

private func runZCodeKeyOrderPreservationSelfTest(at root: URL) throws {
    let scopeRoot = root.appendingPathComponent(
        "key-order",
        isDirectory: true
    )
    let configURL = zcodeSelfTestConfigURL(root: scopeRoot)
    try FileManager.default.createDirectory(
        at: configURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let original = #"""
    {
      "zetaRoot": 1,
      "hooks": {
        "zetaHook": 2,
        "events": {
          "CustomBefore": [{"hooks": [{"command": "before"}]}],
          "SessionStart": [
            {"hooks": [{
              "zetaUserField": "first",
              "type": "command",
              "command": "keep-user-hook",
              "alphaUserField": "last"
            }]},
            {"hooks": [{
              "type": "process",
              "command": "/tmp/old-threadhelm",
              "args": ["--agent-hook", "zcode", "SessionStart"],
              "timeoutMs": 250,
              "statusMessage": "ThreadHelm state observer"
            }]}
          ],
          "CustomAfter": [{"hooks": [{"command": "after"}]}]
        },
        "enabled": true,
        "alphaHook": 3
      },
      "alphaRoot": 4
    }
    """#
    try Data(original.utf8).write(to: configURL)

    let adapter = zcodeSelfTestAdapter()
    let scope = AgentIntegrationScope.isolated(at: scopeRoot)
    guard try adapter.installIntegration(in: scope) == .installed else {
        throw ZCodeSelfTestError.failure("ordered install changed=false")
    }
    let installed = try String(contentsOf: configURL, encoding: .utf8)
    guard zcodeSelfTestTokensAppearInOrder(
        [#""zetaRoot""#, #""hooks""#, #""alphaRoot""#],
        in: installed
    ), zcodeSelfTestTokensAppearInOrder(
        [#""zetaHook""#, #""events""#, #""enabled""#, #""alphaHook""#],
        in: installed
    ), zcodeSelfTestTokensAppearInOrder(
        [
            #""CustomBefore""#,
            #""SessionStart""#,
            #""CustomAfter""#,
            #""UserPromptSubmit""#,
            #""PreToolUse""#,
            #""PostToolUse""#,
            #""PostToolUseFailure""#,
            #""Stop""#,
        ],
        in: installed
    ), zcodeSelfTestTokensAppearInOrder(
        [
            #""zetaUserField""#,
            #""type""#,
            #""command""#,
            #""alphaUserField""#,
        ],
        in: installed
    ) else {
        throw ZCodeSelfTestError.failure(
            "install reordered existing config keys or events"
        )
    }

    guard try adapter.uninstallIntegration(in: scope) == .uninstalled else {
        throw ZCodeSelfTestError.failure("ordered uninstall changed=false")
    }
    let uninstalled = try String(contentsOf: configURL, encoding: .utf8)
    guard zcodeSelfTestTokensAppearInOrder(
        [#""zetaRoot""#, #""hooks""#, #""alphaRoot""#],
        in: uninstalled
    ), zcodeSelfTestTokensAppearInOrder(
        [#""zetaHook""#, #""events""#, #""enabled""#, #""alphaHook""#],
        in: uninstalled
    ), zcodeSelfTestTokensAppearInOrder(
        [#""CustomBefore""#, #""SessionStart""#, #""CustomAfter""#],
        in: uninstalled
    ), zcodeSelfTestTokensAppearInOrder(
        [
            #""zetaUserField""#,
            #""type""#,
            #""command""#,
            #""alphaUserField""#,
        ],
        in: uninstalled
    ) else {
        throw ZCodeSelfTestError.failure(
            "uninstall reordered surviving config keys or events"
        )
    }
}

private func runZCodeDiscoveryAndLifecycleSelfTest(at root: URL) throws {
    let manager = FileManager.default
    let scopeRoot = root.appendingPathComponent("lifecycle", isDirectory: true)
    let scope = AgentIntegrationScope.isolated(at: scopeRoot)
    let configURL = zcodeSelfTestConfigURL(root: scopeRoot)
    let adapter = zcodeSelfTestAdapter()

    try FileManager.default.createDirectory(
        at: configURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try zcodeSelfTestWriteJSON([
        "hooks": [
            "enabled": true,
            "events": [String: Any](),
        ],
    ], to: configURL)

    guard adapter.discover().isInstalled,
          adapter.integrationStatus(in: scope) == .notInstalled,
          manager.fileExists(atPath: configURL.path)
    else {
        throw ZCodeSelfTestError.failure("discovery/config-absent")
    }

    guard try adapter.installIntegration(in: scope) == .installed,
          adapter.integrationStatus(in: scope) == .installed,
          try adapter.installIntegration(in: scope) == .unchanged,
          manager.fileExists(atPath: configURL.path)
    else {
        throw ZCodeSelfTestError.failure("install/status/idempotency")
    }

    var corruptConfig = try zcodeSelfTestJSON(at: configURL)
    var hooks = corruptConfig["hooks"] as? [String: Any] ?? [:]
    var events = hooks["events"] as? [String: Any] ?? [:]
    events.removeValue(forKey: "Stop")
    events["PermissionRequest"] = [[
        "hooks": [zcodeSelfTestOwnedHook(
            eventName: "PermissionRequest",
            executablePath: "/tmp/old-threadhelm"
        )],
    ]]
    hooks["events"] = events
    corruptConfig["hooks"] = hooks
    try zcodeSelfTestWriteJSON(corruptConfig, to: configURL)

    guard adapter.integrationStatus(in: scope) == .needsRepair,
          try adapter.repairIntegration(in: scope) == .repaired,
          adapter.integrationStatus(in: scope) == .installed,
          try adapter.uninstallIntegration(in: scope) == .uninstalled,
          try adapter.uninstallIntegration(in: scope) == .unchanged,
          adapter.integrationStatus(in: scope) == .notInstalled
    else {
        throw ZCodeSelfTestError.failure("repair/uninstall")
    }

    let liveHomeScope = AgentIntegrationScope.isolated(
        at: manager.homeDirectoryForCurrentUser
    )
    do {
        _ = try adapter.installIntegration(in: liveHomeScope)
        throw ZCodeSelfTestError.failure("live-home write was not guarded")
    } catch AgentIntegrationError.liveConfigurationWriteDenied {
    }

    let unavailableRoot = root.appendingPathComponent(
        "unavailable",
        isDirectory: true
    )
    let unavailableAdapter = zcodeSelfTestAdapter(installed: false)
    guard try unavailableAdapter.installIntegration(
        in: .isolated(at: unavailableRoot)
    ) == .unchanged,
    !manager.fileExists(
        atPath: zcodeSelfTestConfigURL(root: unavailableRoot).path
    )
    else {
        throw ZCodeSelfTestError.failure("unavailable must not write")
    }
}

private func runZCodeSemanticMergeSelfTest(at root: URL) throws {
    let scopeRoot = root.appendingPathComponent("merge", isDirectory: true)
    let configURL = zcodeSelfTestConfigURL(root: scopeRoot)
    try FileManager.default.createDirectory(
        at: configURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let initialConfig: [String: Any] = [
        "theme": "keep",
        "hooks": [
            "enabled": true,
            "timeoutMs": 4_321,
            "events": [
              "SessionStart": [
                [
                    "matcher": "startup",
                    "hooks": [[
                        "type": "command",
                        "command": "first-unrelated",
                        "timeout": 3,
                    ]],
                ],
                [
                    "hooks": [
                        zcodeSelfTestOwnedHook(
                            eventName: "SessionStart",
                            executablePath: "/tmp/old-threadhelm"
                        ),
                    ],
                ],
                [
                    "matcher": "resume",
                    "hooks": [[
                        "type": "process",
                        "command": "/tmp/last-unrelated",
                        "args": ["--keep"],
                        "timeoutMs": 999,
                    ]],
                ],
              ],
              "UserPromptSubmit": [
                [
                    "hooks": [[
                        "type": "command",
                        "command": "keep-user-submit",
                    ]],
                ],
              ],
              "PermissionRequest": [
                [
                    "hooks": [[
                        "type": "command",
                        "command": "keep-native-permission",
                    ]],
                ],
              ],
              "LegacyThreadHelmEvent": [
                [
                    "hooks": [
                        [
                            "type": "command",
                            "command": "keep-legacy-neighbor",
                        ],
                        zcodeSelfTestOwnedHook(
                            eventName: "LegacyThreadHelmEvent",
                            executablePath: "/tmp/old-threadhelm"
                        ),
                    ],
                ],
              ],
            ],
        ],
    ]
    try zcodeSelfTestWriteJSON(initialConfig, to: configURL)

    let adapter = zcodeSelfTestAdapter()
    guard try adapter.installIntegration(
        in: .isolated(at: scopeRoot)
    ) == .installed else {
        throw ZCodeSelfTestError.failure("semantic install changed=false")
    }

    let merged = try zcodeSelfTestJSON(at: configURL)
    guard merged["theme"] as? String == "keep",
          let hooks = merged["hooks"] as? [String: Any],
          hooks["enabled"] as? Bool == true,
          hooks["timeoutMs"] as? Int == 4_321,
          let events = hooks["events"] as? [String: Any],
          let permission = events["PermissionRequest"] as? [[String: Any]],
          // 审批闸门接入后 ThreadHelm 也往这个事件里挂自己的 hook，
          // 但用户原有的那条必须原样留着——ZCode 会把多个裁决按
          // 「任一 deny 即 deny」合并，共存是安全的。
          permission.count == 2,
          zcodeSelfTestFirstCommand(in: permission.first)
            == "keep-native-permission",
          zcodeSelfTestOwnedHooks(in: permission).count == 1,
          ZCodeHookConfiguration.managedEvents.allSatisfy({
              let matchers = events[$0] as? [[String: Any]] ?? []
              return zcodeSelfTestOwnedHooks(in: matchers).count == 1
          }),
          let legacy = events["LegacyThreadHelmEvent"] as? [[String: Any]],
          zcodeSelfTestOwnedHooks(in: legacy).isEmpty,
          zcodeSelfTestFirstCommand(in: legacy.first) == "keep-legacy-neighbor"
    else {
        throw ZCodeSelfTestError.failure("semantic preservation")
    }

    let sessionStart = events["SessionStart"] as? [[String: Any]] ?? []
    guard sessionStart.count == 3,
          zcodeSelfTestFirstCommand(in: sessionStart[0])
            == "first-unrelated",
          zcodeSelfTestOwnedHooks(in: [sessionStart[1]]).count == 1,
          zcodeSelfTestFirstCommand(in: sessionStart[2])
            == "/tmp/last-unrelated",
          let owned = zcodeSelfTestOwnedHooks(in: sessionStart).first,
          Set(owned.keys) == Set([
              "type",
              "command",
              "args",
              "timeoutMs",
              "statusMessage",
          ]),
          owned["type"] as? String == "process",
          owned["command"] as? String == "/tmp/threadhelm-zcode-adapter",
          owned["args"] as? [String]
            == ["--agent-hook", "zcode", "SessionStart"],
          owned["timeoutMs"] as? Int
            == AgentHookCommandContract.observationHookTimeoutMilliseconds
    else {
        throw ZCodeSelfTestError.failure(
            "official hooks.events schema/order/managed process hook"
        )
    }
}

private func runZCodeMalformedConfigPreservationSelfTest(at root: URL) throws {
    let scopeRoot = root.appendingPathComponent("malformed", isDirectory: true)
    let configURL = zcodeSelfTestConfigURL(root: scopeRoot)
    try FileManager.default.createDirectory(
        at: configURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let malformedShape = Data(
        #"{"theme":"keep","hooks":[{"user":"content"}]}"#.utf8
    )
    try malformedShape.write(to: configURL)
    let adapter = zcodeSelfTestAdapter()
    let scope = AgentIntegrationScope.isolated(at: scopeRoot)
    guard adapter.integrationStatus(in: scope) == .needsRepair else {
        throw ZCodeSelfTestError.failure("malformed hooks shape status")
    }
    do {
        _ = try adapter.repairIntegration(in: scope)
        throw ZCodeSelfTestError.failure("malformed hooks shape was overwritten")
    } catch ZCodeHookConfigurationError.invalidConfig {
    }
    guard try Data(contentsOf: configURL) == malformedShape else {
        throw ZCodeSelfTestError.failure("malformed hooks shape was not preserved")
    }
}

private func runZCodeDisabledHooksSelfTest(at root: URL) throws {
    let scopeRoot = root.appendingPathComponent("disabled", isDirectory: true)
    let configURL = zcodeSelfTestConfigURL(root: scopeRoot)
    try FileManager.default.createDirectory(
        at: configURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try zcodeSelfTestWriteJSON([
        "hooks": [
            "enabled": false,
            "events": [
                "SessionStart": [[
                    "hooks": [[
                        "type": "command",
                        "command": "user-disabled-hook",
                    ]],
                ]],
            ],
        ],
    ], to: configURL)

    let adapter = zcodeSelfTestAdapter()
    guard adapter.integrationStatus(in: .isolated(at: scopeRoot)) == .disabled,
          try adapter.installIntegration(
              in: .isolated(at: scopeRoot)
          ) == .unchanged
    else {
        throw ZCodeSelfTestError.failure("hooks.enabled=false respected")
    }
    let config = try zcodeSelfTestJSON(at: configURL)
    let hooks = config["hooks"] as? [String: Any]
    guard hooks?["enabled"] as? Bool == false,
          let events = hooks?["events"] as? [String: Any],
          let sessionStart = events["SessionStart"] as? [[String: Any]],
          sessionStart.count == 1,
          zcodeSelfTestFirstCommand(in: sessionStart.first)
            == "user-disabled-hook"
    else {
        throw ZCodeSelfTestError.failure("disabled config mutated")
    }
}

private func runZCodeDefaultDisabledSelfTest(at root: URL) throws {
    let scopeRoot = root.appendingPathComponent(
        "default-disabled",
        isDirectory: true
    )
    let configURL = zcodeSelfTestConfigURL(root: scopeRoot)
    try FileManager.default.createDirectory(
        at: configURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try zcodeSelfTestWriteJSON(["theme": "keep"], to: configURL)

    let adapter = zcodeSelfTestAdapter()
    let scope = AgentIntegrationScope.isolated(at: scopeRoot)
    guard try adapter.installIntegration(in: scope) == .installed,
          adapter.integrationStatus(in: scope) == .disabled,
          try adapter.installIntegration(in: scope) == .unchanged
    else {
        throw ZCodeSelfTestError.failure(
            "missing hooks.enabled must remain safely disabled"
        )
    }
    let installed = try zcodeSelfTestJSON(at: configURL)
    let hooks = installed["hooks"] as? [String: Any]
    guard installed["theme"] as? String == "keep",
          hooks?["enabled"] == nil,
          hooks?["events"] is [String: Any]
    else {
        throw ZCodeSelfTestError.failure(
            "default-disabled install changed unrelated configuration"
        )
    }

    guard try adapter.uninstallIntegration(in: scope) == .uninstalled,
          try zcodeSelfTestJSON(at: configURL)["theme"] as? String == "keep",
          (try zcodeSelfTestJSON(at: configURL))["hooks"] == nil
    else {
        throw ZCodeSelfTestError.failure(
            "default-disabled uninstall did not restore original shape"
        )
    }
}

private func runZCodeObservationSelfTest() throws {
    let base = Date(timeIntervalSince1970: 1_786_600_000)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    func data(_ envelope: ZCodeHookEnvelope) throws -> Data {
        try encoder.encode(envelope)
    }

    let adapter = zcodeSelfTestAdapter(
        now: { base },
        readEnvelopeData: {
            [
                try data(ZCodeHookEnvelope(
                    eventID: "dup",
                    sessionID: "z-session-1",
                    sequence: 1,
                    eventType: "UserPromptSubmit",
                    observedAt: base
                )),
                try data(ZCodeHookEnvelope(
                    eventID: "tool-failed",
                    sessionID: "z-session-1",
                    sequence: 2,
                    eventType: "PostToolUseFailure",
                    observedAt: base.addingTimeInterval(1),
                    outcome: "failed"
                )),
                try data(ZCodeHookEnvelope(
                    eventID: "terminal-failed",
                    sessionID: "z-session-1",
                    sequence: 3,
                    eventType: "Stop",
                    observedAt: base.addingTimeInterval(2),
                    outcome: "taskError"
                )),
                try data(ZCodeHookEnvelope(
                    eventID: "dup",
                    sessionID: "z-session-1",
                    sequence: 1,
                    eventType: "UserPromptSubmit",
                    observedAt: base.addingTimeInterval(-5)
                )),
                Data("{\"eventType\":".utf8),
            ]
        }
    )
    guard let snapshot = try adapter.observe().snapshots.first,
          snapshot.identity.agentID == .zcode,
          snapshot.identity.nativeID == "z-session-1",
          snapshot.executionState == .failed,
          snapshot.attentionReason == .taskFailure,
          snapshot.actionability == .openNativeApp,
          snapshot.evidenceQuality == .inferred,
          snapshot.latestEventID == "terminal-failed"
    else {
        throw ZCodeSelfTestError.failure("duplicate/out-of-order/task failure")
    }

    let toolFailureOnly = zcodeSelfTestAdapter(
        now: { base },
        readEnvelopeData: {
            [try data(ZCodeHookEnvelope(
                eventID: "tool-failure-only",
                sessionID: "z-session-2",
                eventType: "PostToolUseFailure",
                observedAt: base
            ))]
        }
    )
    guard let toolSnapshot = try toolFailureOnly.observe().snapshots.first,
          toolSnapshot.executionState == .running,
          toolSnapshot.attentionReason == .none
    else {
        throw ZCodeSelfTestError.failure("ordinary tool failure no attention")
    }

    let staleAdapter = zcodeSelfTestAdapter(
        now: { base.addingTimeInterval(20 * 60) },
        readEnvelopeData: {
            [try data(ZCodeHookEnvelope(
                eventID: "stale",
                sessionID: "z-session-stale",
                eventType: "SessionStart",
                observedAt: base
            ))]
        }
    )
    guard let stale = try staleAdapter.observe().snapshots.first,
          stale.executionState == .stale,
          stale.attentionReason == .none,
          stale.actionability == .viewOnly,
          stale.freshness.staleReason == "zcode-session-expired"
    else {
        throw ZCodeSelfTestError.failure("stale expiry")
    }

    let offlineAdapter = zcodeSelfTestAdapter(
        readEnvelopeData: { throw ZCodeSelfTestError.failure("offline") }
    )
    guard try offlineAdapter.observe().snapshots.isEmpty else {
        throw ZCodeSelfTestError.failure("offline fail-open")
    }

    let malformedAdapter = zcodeSelfTestAdapter(
        readEnvelopeData: { [Data("not-json".utf8)] }
    )
    guard try malformedAdapter.observe().snapshots.isEmpty else {
        throw ZCodeSelfTestError.failure("malformed fail-open")
    }
}

private func runZCodeOpenSelfTest() throws {
    let now = Date(timeIntervalSince1970: 1_786_600_000)
    let snapshot = AgentSessionSnapshot(
        identity: AgentSessionIdentity(agentID: .zcode, nativeID: "z-open"),
        adapterVersion: "self-test",
        executionState: .running,
        attentionReason: .none,
        actionability: .openNativeApp,
        evidenceQuality: .officialHook,
        freshness: Freshness(
            observedAt: now,
            expiresAt: now.addingTimeInterval(60)
        ),
        title: "ZCode",
        activitySummary: nil,
        workingDirectory: "/tmp/threadhelm-zcode",
        latestEventID: "open",
        updatedAt: now
    )
    let appReport = zcodeSelfTestAdapter(
        activateApplication: { .appFocused },
        openWorkingDirectory: { _ in false }
    ).open(session: snapshot)
    let directoryReport = zcodeSelfTestAdapter(
        activateApplication: { .failed },
        openWorkingDirectory: { _ in true }
    ).open(session: snapshot)
    let unknownReport = zcodeSelfTestAdapter(
        activateApplication: { .unknown },
        openWorkingDirectory: { _ in false }
    ).open(session: snapshot)
    guard appReport.result == .appFocused,
          directoryReport.result == .workingDirectoryFallback,
          unknownReport.result == .unknown,
          [appReport, directoryReport, unknownReport].allSatisfy({
              !$0.exactAttempted && !$0.independentlyConfirmedIdentity
          })
    else {
        throw ZCodeSelfTestError.failure("open result boundary")
    }

    let failedReport = zcodeSelfTestAdapter(
        activateApplication: { .failed },
        openWorkingDirectory: { _ in false }
    ).open(session: snapshot)
    let unavailableReport = zcodeSelfTestAdapter(
        installed: false,
        activateApplication: { .unavailable },
        openWorkingDirectory: { _ in false }
    ).open(session: snapshot)
    guard failedReport.result == .failed,
          unavailableReport.result == .unavailable
    else {
        throw ZCodeSelfTestError.failure("failed/unavailable open boundary")
    }
}

private func zcodeSelfTestAdapter(
    installed: Bool = true,
    now: @escaping () -> Date = Date.init,
    readEnvelopeData: @escaping () throws -> [Data] = { [] },
    activateApplication: @escaping () -> OpenResult = { .failed },
    openWorkingDirectory: @escaping (String) -> Bool = { _ in false }
) -> ZCodeAgentAdapter {
    ZCodeAgentAdapter(
        discovery: {
            AgentDiscovery(
                isInstalled: installed,
                version: installed ? "self-test-zcode" : nil,
                compatibility: installed ? .supported : .unknown
            )
        },
        readEnvelopeData: readEnvelopeData,
        now: now,
        executablePath: { "/tmp/threadhelm-zcode-adapter" },
        activateApplication: activateApplication,
        openWorkingDirectory: openWorkingDirectory
    )
}

private func zcodeSelfTestConfigURL(root: URL) -> URL {
    root
        .appendingPathComponent(".zcode", isDirectory: true)
        .appendingPathComponent("cli", isDirectory: true)
        .appendingPathComponent("config.json")
}

private func zcodeSelfTestJSON(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    guard let object = try JSONSerialization.jsonObject(with: data)
        as? [String: Any]
    else {
        throw ZCodeSelfTestError.failure("invalid json")
    }
    return object
}

private func zcodeSelfTestWriteJSON(
    _ object: [String: Any],
    to url: URL
) throws {
    let data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    try data.write(to: url)
}

private func zcodeSelfTestOwnedHook(
    eventName: String,
    executablePath: String
) -> [String: Any] {
    // 审批 hook 与观测 hook 形状不同：另一个旗标、另一套超时预算。
    if ZCodeHookConfiguration.isPermissionEvent(eventName) {
        return [
            "type": "process",
            "command": executablePath,
            "args": [ZCodePermissionHookConstants.flag],
            "timeoutMs": ZCodePermissionHookConstants.hookTimeoutMilliseconds,
            "statusMessage": ZCodePermissionHookConstants.statusMessage,
        ]
    }
    return [
        "type": "process",
        "command": executablePath,
        "args": ["--agent-hook", "zcode", eventName],
        "timeoutMs": AgentHookCommandContract
            .observationHookTimeoutMilliseconds,
        "statusMessage": "ThreadHelm state observer",
    ]
}

private func zcodeSelfTestOwnedHooks(
    in matchers: [[String: Any]]
) -> [[String: Any]] {
    matchers.flatMap { matcher -> [[String: Any]] in
        let hooks = matcher["hooks"] as? [[String: Any]] ?? []
        return hooks.filter { hook in
            guard hook["type"] as? String == "process" else { return false }
            let args = hook["args"] as? [String] ?? []
            if args == [ZCodePermissionHookConstants.flag] {
                return hook["statusMessage"] as? String
                    == ZCodePermissionHookConstants.statusMessage
            }
            return hook["statusMessage"] as? String
                == "ThreadHelm state observer"
                && Array(args.prefix(2)) == ["--agent-hook", "zcode"]
        }
    }
}

private func zcodeSelfTestFirstCommand(
    in matcher: [String: Any]?
) -> String? {
    let hooks = matcher?["hooks"] as? [[String: Any]]
    return hooks?.first?["command"] as? String
}

private func zcodeSelfTestTokensAppearInOrder(
    _ tokens: [String],
    in text: String
) -> Bool {
    var remaining = text.startIndex..<text.endIndex
    for token in tokens {
        guard let range = text.range(of: token, range: remaining) else {
            return false
        }
        remaining = range.upperBound..<text.endIndex
    }
    return true
}

private enum ZCodeSelfTestError: Error, CustomStringConvertible {
    case failure(String)

    var description: String {
        switch self {
        case let .failure(message): return message
        }
    }
}
