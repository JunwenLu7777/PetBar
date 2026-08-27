//
//  PanelLifecycle.swift
//  ThreadHelm
//
//  模块职责：动态岛显隐决策，以及运行时健康状态文件
//  （panel-health.json）的节流写入。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

func shouldPresentClaudePermissionPanel(
    cachedCodexDesktopRunning: Bool,
    liveCodexDesktopRunning: Bool,
    claudePermissionCapability: AgentCapabilityStatus
) -> Bool {
    shouldPresentPermissionPanel(
        agentID: .claudeCode,
        cachedCodexDesktopRunning: cachedCodexDesktopRunning,
        liveCodexDesktopRunning: liveCodexDesktopRunning,
        permissionCapability: claudePermissionCapability
    )
}

/// 判据是「ThreadHelm 实现了这家的闸门吗」，不是「本机版本对不对得上」。
///
/// 曾经这里要求 compatibility == .validated。后果是：上游一发版，请求照常
/// 打到面板，面板却一言不发地把裁决交回去——对 Cursor/Codex 是功能凭空
/// 消失，对 ZCode 更糟：它的兜底是**主动拒绝**，于是每一次工具调用都被
/// 自动拒掉，而理由写的是「请在 ThreadHelm 中确认闸门在线」，用户按这句
/// 话什么也做不了。手里已经攥着一条真实请求，还要拿版本号去否定它，是
/// 把最强的证据让位给最弱的推断。
func shouldPresentPermissionPanel(
    agentID: AgentID,
    cachedCodexDesktopRunning: Bool,
    liveCodexDesktopRunning: Bool,
    permissionCapability: AgentCapabilityStatus
) -> Bool {
    guard permissionCapability != .unsupported else { return false }
    // 请求来自 Codex 自己时，「用户正在用 Codex」已经由请求本身证明，
    // 再要求 Codex Desktop 在跑就会把纯 CLI 用户挡在门外——闸门静默
    // 交还原生 UI，看起来就像功能没生效。
    guard agentID != .codex else { return true }
    // Workspace lifecycle notifications can arrive after a Claude hook
    // request. A stale cached true must never activate UI after Codex exits.
    guard cachedCodexDesktopRunning == liveCodexDesktopRunning else {
        return liveCodexDesktopRunning
    }
    return cachedCodexDesktopRunning
}

enum PresentationCommand: Equatable {
    case toggleVisibility
    case moveToCurrentDisplay
    case quit
}

enum DynamicIslandVisibilityAction: Equatable {
    case hidden
    case capsule
    case confirmation
}

func dynamicIslandVisibilityAction(
    hiddenByUser: Bool,
    hasCurrentPermissionRequest: Bool
) -> DynamicIslandVisibilityAction {
    guard !hiddenByUser else { return .hidden }
    return hasCurrentPermissionRequest ? .confirmation : .capsule
}

func acknowledgeTerminalTask(
    _ item: TaskProgressItem,
    in keys: inout Set<String>
) {
    guard let key = terminalTaskAcknowledgementKey(for: item) else { return }
    keys.insert(key)
}

final class RuntimeHealthWriter {
    typealias DirectoryCreator = (URL, Bool) throws -> Void
    typealias DataWriter = (Data, URL) throws -> Void
    typealias FailureLogger = (String) -> Void

    private let fileURL: URL
    private let createDirectory: DirectoryCreator
    private let writeData: DataWriter
    private let logFailure: FailureLogger
    private var lastSignature = ""
    private var lastWriteAt: CFAbsoluteTime = 0
    private var didLogWriteFailure = false

    init(
        fileURL: URL = RuntimeHealthWriter.defaultFileURL(),
        createDirectory: @escaping DirectoryCreator = { url, createIntermediates in
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: createIntermediates
            )
        },
        writeData: @escaping DataWriter = { data, url in
            try data.write(to: url, options: .atomic)
        },
        logFailure: @escaping FailureLogger = { message in
            fputs("\(message)\n", stderr)
        }
    ) {
        self.fileURL = fileURL
        self.createDirectory = createDirectory
        self.writeData = writeData
        self.logFailure = logFailure
    }

    func write(
        status: String,
        panelVisible: Bool,
        agentEventChannelAvailable: Bool? = nil,
        force: Bool = false
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        let eventChannel = agentEventChannelAvailable.map {
            $0 ? "healthy" : "degraded"
        } ?? "unknown"
        let signature = "\(status)|\(panelVisible)|\(eventChannel)"
        guard force || signature != lastSignature || now - lastWriteAt >= 15 else { return }

        var payload: [String: Any] = [
            "version": panelVersion,
            "edition": panelEdition,
            "productID": threadHelmProductID,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "status": status,
            "panelVisible": panelVisible,
            "codexWeeklyQuotaOnly": true,
            "claudeQuotaPeriods": ["5h", "weekly", "fable"],
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if agentEventChannelAvailable != nil {
            payload["agentEventChannel"] = eventChannel
        }
        do {
            try createDirectory(fileURL.deletingLastPathComponent(), true)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try writeData(data, fileURL)
            lastSignature = signature
            lastWriteAt = now
            didLogWriteFailure = false
        } catch {
            if !didLogWriteFailure {
                didLogWriteFailure = true
                logFailure(
                    "ThreadHelm health write failed: \(error.localizedDescription)"
                )
            }
        }
    }

    private static func defaultFileURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["THREADHELM_PANEL_HEALTH_FILE"],
           !override.isEmpty
        {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Caches/\(threadHelmBundleIdentifier)/panel-health.json"
            )
    }
}
