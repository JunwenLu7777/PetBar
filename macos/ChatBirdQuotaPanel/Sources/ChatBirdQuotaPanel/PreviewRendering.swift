//
//  PreviewRendering.swift
//  ChatBirdQuotaPanel
//
//  模块职责：--render-preview 离屏渲染——按命令行旗标组装任务列表与
//  额度行，把 QuotaPanelView 绘制成 2x PNG 预览图并写入指定路径。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

func renderPreviewOnce(to outputPath: String) -> Never {
    _ = NSApplication.shared
    let previewNow = Date(timeIntervalSince1970: 1_786_354_140)
    var previewTaskTemplates = [
        TaskProgressItem(title: "制作 ChatBird 宠物", kind: .running, startedAt: previewNow),
        TaskProgressItem(
            title: "等待确认视觉方向",
            kind: .waitingForInput,
            startedAt: previewNow
        ),
        TaskProgressItem(
            title: "检查 Claude 运行结果",
            kind: .running,
            startedAt: previewNow,
            source: .claudeCode,
            sessionID: "b687a9ef-4535-4bb4-a9d5-e692bbcdb0a6",
            workingDirectory: "/tmp"
        ),
        TaskProgressItem(
            title: "检查额度面板比例",
            kind: .running,
            startedAt: previewNow
        ),
        TaskProgressItem(
            title: "生成发布包",
            kind: .waitingForInput,
            startedAt: previewNow
        ),
    ]
    if CommandLine.arguments.contains("--preview-completed") {
        previewTaskTemplates[0] = TaskProgressItem(
            title: "检查完成状态图标",
            kind: .completed,
            startedAt: previewNow
        )
    } else if CommandLine.arguments.contains("--preview-waiting") {
        previewTaskTemplates[0] = TaskProgressItem(
            title: "等待用户确认",
            kind: .waitingForInput,
            startedAt: previewNow
        )
    } else if CommandLine.arguments.contains("--preview-failed") {
        previewTaskTemplates[0] = TaskProgressItem(
            title: "检查失败状态图标",
            kind: .failed,
            startedAt: previewNow
        )
    }
    let countFlag = "--preview-task-count"
    let requestedPreviewCount: Int
    if let flagIndex = CommandLine.arguments.firstIndex(of: countFlag),
       CommandLine.arguments.indices.contains(flagIndex + 1),
       let parsedCount = Int(CommandLine.arguments[flagIndex + 1]) {
        requestedPreviewCount = parsedCount
    } else {
        requestedPreviewCount = 3
    }
    let previewCount = max(1, min(maximumVisibleTaskRows, requestedPreviewCount))
    let previewTasks: TaskProgressSnapshot
    if CommandLine.arguments.contains("--preview-scrollable") {
        previewTasks = TaskProgressSnapshot.displaying((0..<7).map { index in
            let isClaude = !index.isMultiple(of: 2)
            return TaskProgressItem(
                title: "活跃任务 \(index + 1)",
                kind: index == 1 ? .waitingForInput : .running,
                startedAt: previewNow,
                updatedAt: previewNow.addingTimeInterval(Double(index)),
                source: isClaude ? .claudeCode : .codex,
                sessionID: isClaude
                    ? String(format: "b687a9ef-4535-4bb4-a9d5-%012d", index + 1)
                    : nil,
                workingDirectory: isClaude ? "/tmp" : nil
            )
        })
    } else {
        previewTasks = TaskProgressSnapshot(
            items: Array(previewTaskTemplates.prefix(previewCount))
        )
    }
    let quotaFlag = "--preview-quota"
    let previewRemaining: Int
    if let flagIndex = CommandLine.arguments.firstIndex(of: quotaFlag),
       CommandLine.arguments.indices.contains(flagIndex + 1),
       let parsedRemaining = Int(CommandLine.arguments[flagIndex + 1])
    {
        previewRemaining = max(0, min(100, parsedRemaining))
    } else {
        previewRemaining = 94
    }
    let previewPanelSize = panelSizeForTaskRows(previewTasks.rowCount)
    let view = QuotaPanelView(frame: NSRect(origin: .zero, size: previewPanelSize))
    view.currentDateProvider = { previewNow }
    view.pointerSide = .bottom
    view.providerRemainingPercents = [
        .codex: CommandLine.arguments.contains("--preview-claude-quota")
            ? 97
            : previewRemaining,
        .claudeCode: CommandLine.arguments.contains("--preview-claude-quota")
            ? previewRemaining
            : 85,
    ]
    view.codexResetCredits = CodexResetCreditsSnapshot(
        credits: [
            CodexResetCredit(
                id: "preview-tomorrow",
                status: .available,
                expiresAt: Calendar.current.date(
                    byAdding: .hour,
                    value: 19,
                    to: previewNow
                )
            ),
            CodexResetCredit(
                id: "preview-next-week",
                status: .available,
                expiresAt: Calendar.current.date(
                    byAdding: .day,
                    value: 6,
                    to: previewNow
                )
            ),
            CodexResetCredit(
                id: "preview-later",
                status: .available,
                expiresAt: Calendar.current.date(
                    byAdding: .day,
                    value: 18,
                    to: previewNow
                )
            ),
        ],
        reportedAvailableCount: 3,
        updatedAt: previewNow
    )
    if CommandLine.arguments.contains("--preview-claude-quota") {
        view.selectedQuotaProvider = .claudeCode
        view.rows = [
            QuotaRow(
                name: "5 小时",
                remainingPercent: previewRemaining,
                resetsAt: Calendar.current.date(
                    byAdding: .hour,
                    value: 4,
                    to: previewNow
                )
            ),
            QuotaRow(
                name: "周额度",
                remainingPercent: 63,
                resetsAt: Calendar.current.date(
                    byAdding: .day,
                    value: 5,
                    to: previewNow
                )
            ),
            QuotaRow(
                name: "Fable",
                remainingPercent: 97,
                resetsAt: Calendar.current.date(
                    byAdding: .day,
                    value: 5,
                    to: previewNow
                )
            ),
        ]
    } else {
        view.rows = [QuotaRow(
            name: "周额度",
            remainingPercent: previewRemaining,
            resetsAt: Calendar.current.date(
                byAdding: .day,
                value: 7,
                to: previewNow
            )
        )]
    }
    view.statusText = quotaSuccessStatusText(
        provider: view.selectedQuotaProvider,
        rows: view.rows,
        updatedAt: previewNow
    )
    view.taskProgress = previewTasks
    view.layoutSubtreeIfNeeded()

    let scale: CGFloat = 2
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(previewPanelSize.width * scale),
        pixelsHigh: Int(previewPanelSize.height * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fputs("无法创建预览画布\n", stderr)
        exit(1)
    }
    bitmap.size = previewPanelSize

    view.cacheDisplay(in: view.bounds, to: bitmap)

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fputs("无法编码预览图片\n", stderr)
        exit(1)
    }

    do {
        try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        print(outputPath)
        exit(0)
    } catch {
        fputs("写入预览失败：\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
