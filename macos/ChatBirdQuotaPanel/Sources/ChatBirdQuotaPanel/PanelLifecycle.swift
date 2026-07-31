//
//  PanelLifecycle.swift
//  ChatBirdQuotaPanel
//
//  模块职责：面板显隐决策（运行状态/用户隐藏/宠物定位）、宠物点击行为
//  判定，以及运行时健康状态文件（panel-health.json）的节流写入。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

func shouldPresentPanel(
    codexDesktopRunning: Bool,
    hiddenByUser: Bool,
    hasPetLocation: Bool
) -> Bool {
    codexDesktopRunning && !hiddenByUser && hasPetLocation
}

func shouldPresentClaudePermissionPanel(
    cachedCodexDesktopRunning: Bool,
    liveCodexDesktopRunning: Bool
) -> Bool {
    // Workspace lifecycle notifications can arrive after a Claude hook
    // request. A stale cached true must never activate UI after Codex exits.
    guard cachedCodexDesktopRunning == liveCodexDesktopRunning else {
        return liveCodexDesktopRunning
    }
    return cachedCodexDesktopRunning
}

enum PetPanelClickAction: Equatable {
    case none
    case show
    case hide
}

func petPanelClickAction(
    clickCount: Int,
    clickLocation: NSPoint,
    petVisibleRect: NSRect,
    panelHidden: Bool,
    suppressVisibleDoubleClick: Bool
) -> PetPanelClickAction {
    guard petVisibleRect.contains(clickLocation) else {
        return .none
    }
    if panelHidden {
        return .show
    }
    guard !suppressVisibleDoubleClick, clickCount == 2 else {
        return .none
    }
    return .hide
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
        locationSource: String?,
        gap: CGFloat? = nil,
        centerError: CGFloat? = nil,
        panelScale: CGFloat = 1,
        panelSize: NSSize? = nil,
        force: Bool = false
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        let safeScale = normalizedPanelScale(panelScale)
        let livePanelSize = panelSize ?? scaledPanelSize(expandedPanelSize, scale: safeScale)
        // Do not turn a live resize into 30 disk writes per second. Scale and
        // dimensions are included in the periodic payload, while the signature
        // remains limited to meaningful visibility/source changes.
        let signature = "\(status)|\(panelVisible)|\(locationSource ?? "none")"
        guard force || signature != lastSignature || now - lastWriteAt >= 15 else { return }

        var payload: [String: Any] = [
            "version": panelVersion,
            "edition": panelEdition,
            "petID": chatBirdPetID,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "status": status,
            "panelVisible": panelVisible,
            "codexWeeklyQuotaOnly": true,
            "claudeQuotaPeriods": ["5h", "weekly", "fable"],
            "panelBaseHeightPoints": expandedPanelSize.height,
            "panelWidthPoints": livePanelSize.width,
            "panelHeightPoints": livePanelSize.height,
            "panelScale": safeScale,
            "locationSource": locationSource ?? NSNull(),
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let gap { payload["petGapPoints"] = gap }
        if let centerError { payload["pointerCenterErrorPoints"] = centerError }

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
                    "ChatBird health write failed: \(error.localizedDescription)"
                )
            }
        }
    }

    private static func defaultFileURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["CHATBIRD_PANEL_HEALTH_FILE"],
           !override.isEmpty
        {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/dev.chatbird.codex-quota-panel/panel-health.json")
    }
}
