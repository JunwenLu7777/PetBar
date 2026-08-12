//
//  DynamicIslandAgentHealthView.swift
//  ThreadHelm
//
//  模块职责：只读展示五个本地 Agent 的发现、观察与集成健康状态。
//

import AppKit
import Foundation

final class DynamicIslandAgentHealthViewController:
    NSViewController,
    NSTableViewDataSource,
    NSTableViewDelegate
{
    private let titleField = DynamicIslandAgentHealthLabel(
        size: 15,
        weight: .semibold
    )
    private let localOnlyField = DynamicIslandAgentHealthLabel(
        size: 11,
        weight: .regular
    )
    private let channelCard = DynamicIslandCardView(
        cornerRadius: 9,
        backgroundColor: DynamicIslandPalette.surface
    )
    private let channelDot = NSView()
    private let channelTitleField = DynamicIslandAgentHealthLabel(
        size: 13,
        weight: .semibold
    )
    private let channelDetailField = DynamicIslandAgentHealthLabel(
        size: 11,
        weight: .regular
    )
    private let tableScrollView = NSScrollView()
    private let tableView = NSTableView()

    private var statuses: [AgentRuntimeStatus] = []
    private var eventChannelAvailable: Bool?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 560))
        view.wantsLayer = true
        view.addSubview(titleField)
        view.addSubview(localOnlyField)
        view.addSubview(channelCard)
        channelCard.addSubview(channelDot)
        channelCard.addSubview(channelTitleField)
        channelCard.addSubview(channelDetailField)
        view.addSubview(tableScrollView)

        titleField.stringValue = "Agents / Integrations"
        titleField.setAccessibilityLabel("Agents 和 Integrations 健康状态")
        localOnlyField.stringValue = "仅检查这台 Mac；不上传任务内容"
        localOnlyField.textColor = DynamicIslandPalette.secondaryText
        localOnlyField.alignment = .right

        channelDot.wantsLayer = true
        channelDot.layer?.cornerRadius = 5
        channelDetailField.textColor = DynamicIslandPalette.secondaryText

        tableView.headerView = nil
        tableView.rowHeight = 76
        tableView.intercellSpacing = NSSize(width: 0, height: 6)
        tableView.selectionHighlightStyle = .none
        tableView.addTableColumn(NSTableColumn(identifier: .init("agent-health")))
        tableView.delegate = self
        tableView.dataSource = self
        tableView.backgroundColor = .clear
        tableView.setAccessibilityLabel("本地 Agent 与集成健康列表")

        tableScrollView.documentView = tableView
        tableScrollView.hasVerticalScroller = true
        tableScrollView.drawsBackground = false
        renderChannelStatus()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = view.bounds.width
        let height = view.bounds.height
        titleField.frame = NSRect(x: 8, y: height - 30, width: 220, height: 20)
        localOnlyField.frame = NSRect(
            x: max(236, width - 300),
            y: height - 28,
            width: 292,
            height: 18
        )
        channelCard.frame = NSRect(
            x: 8,
            y: height - 94,
            width: max(1, width - 16),
            height: 52
        )
        channelDot.frame = NSRect(x: 14, y: 21, width: 10, height: 10)
        channelTitleField.frame = NSRect(x: 36, y: 27, width: 240, height: 17)
        channelDetailField.frame = NSRect(
            x: 36,
            y: 8,
            width: max(1, channelCard.bounds.width - 50),
            height: 16
        )
        tableScrollView.frame = NSRect(
            x: 4,
            y: 4,
            width: max(1, width - 8),
            height: max(1, height - 108)
        )
        tableView.tableColumns.first?.width = tableScrollView.contentSize.width
    }

    func apply(_ snapshot: ActivityDashboardSnapshot) {
        _ = view
        eventChannelAvailable = snapshot.agentEventChannelAvailable
        statuses = (snapshot.agentStatuses.isEmpty
            ? agentRuntimeStatusPlaceholders()
            : snapshot.agentStatuses).sorted {
                $0.metadata.id < $1.metadata.id
            }
        renderChannelStatus()
        tableView.reloadData()
        view.needsLayout = true
        updateAccessibility()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        statuses.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard statuses.indices.contains(row) else { return nil }
        return DynamicIslandAgentHealthRowView(status: statuses[row])
    }

    func tableView(
        _ tableView: NSTableView,
        shouldSelectRow row: Int
    ) -> Bool {
        false
    }

    func rowSummariesForSelfTest() -> [String] {
        statuses.map(agentRuntimeAccessibilitySummary)
    }

    func accessibilitySnapshotForSelfTest() -> String {
        _ = view
        return ([
            channelTitleField.stringValue,
            channelDetailField.stringValue,
            localOnlyField.stringValue,
        ] + rowSummariesForSelfTest()).joined(separator: "，")
    }

    private func renderChannelStatus() {
        let title: String
        let detail: String
        let color: NSColor
        switch eventChannelAvailable {
        case true:
            title = "本地事件通道正常"
            detail = "实时事件可用；本地轮询继续作为兜底"
            color = DynamicIslandPalette.green
        case false:
            title = "本地事件通道已降级"
            detail = "实时事件暂不可用；本地轮询仍会继续工作"
            color = DynamicIslandPalette.amber
        case nil:
            title = "本地事件通道检查中"
            detail = "尚未拿到通道状态；本地轮询仍会继续工作"
            color = DynamicIslandPalette.secondaryText
        }
        channelTitleField.stringValue = title
        channelTitleField.textColor = color
        channelDetailField.stringValue = detail
        channelDot.layer?.backgroundColor = color.cgColor
        channelCard.setAccessibilityLabel(title)
        channelCard.setAccessibilityValue(detail)
    }

    private func updateAccessibility() {
        view.setAccessibilityLabel("Agents 和 Integrations 健康状态")
        view.setAccessibilityValue(accessibilitySnapshotForSelfTest())
    }
}

private final class DynamicIslandAgentHealthRowView: NSTableCellView {
    private let card = DynamicIslandCardView(
        cornerRadius: 9,
        backgroundColor: DynamicIslandPalette.surface
    )
    private let iconBadge = NSView()
    private let iconView = NSImageView()
    private let nameField = DynamicIslandAgentHealthLabel(size: 13, weight: .semibold)
    private let versionField = DynamicIslandAgentHealthLabel(size: 11, weight: .regular)
    private let healthDot = NSView()
    private let healthField = DynamicIslandAgentHealthLabel(size: 12, weight: .medium)
    private let integrationField = DynamicIslandAgentHealthLabel(size: 12, weight: .medium)
    private let activityField = DynamicIslandAgentHealthLabel(size: 11, weight: .regular)

    init(status: AgentRuntimeStatus) {
        super.init(frame: .zero)
        addSubview(card)
        for subview in [
            iconBadge,
            iconView,
            nameField,
            versionField,
            healthDot,
            healthField,
            integrationField,
            activityField,
        ] {
            card.addSubview(subview)
        }

        let brandColor = status.metadata.brandColor.color
        iconBadge.wantsLayer = true
        iconBadge.layer?.cornerRadius = 18
        iconBadge.layer?.backgroundColor = brandColor.withAlphaComponent(0.15).cgColor
        iconBadge.layer?.borderWidth = 1
        iconBadge.layer?.borderColor = brandColor.withAlphaComponent(0.64).cgColor
        iconView.image = agentIconImage(for: status.metadata.id)
        iconView.contentTintColor = brandColor
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setAccessibilityElement(false)

        nameField.stringValue = status.metadata.displayName
        versionField.stringValue = agentRuntimeVersionText(status)
        versionField.textColor = DynamicIslandPalette.secondaryText

        let healthColor = agentRuntimeHealthColor(status.diagnostics.health)
        healthDot.wantsLayer = true
        healthDot.layer?.cornerRadius = 4
        healthDot.layer?.backgroundColor = healthColor.cgColor
        healthField.stringValue = status.diagnostics.summary
        healthField.textColor = healthColor
        integrationField.stringValue = agentRuntimeIntegrationText(status)
        integrationField.textColor = DynamicIslandPalette.secondaryText
        activityField.stringValue = "运行 \(status.activeSessionCount) · 需你 \(status.attentionCount)"
        activityField.textColor = DynamicIslandPalette.tertiaryText

        let summary = agentRuntimeAccessibilitySummary(status)
        setAccessibilityLabel(status.metadata.displayName)
        setAccessibilityValue(summary)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        card.frame = bounds.insetBy(dx: 4, dy: 2)
        iconBadge.frame = NSRect(x: 12, y: 18, width: 36, height: 36)
        iconView.frame = NSRect(x: 20, y: 26, width: 20, height: 20)
        nameField.frame = NSRect(x: 60, y: 40, width: 138, height: 18)
        versionField.frame = NSRect(x: 60, y: 18, width: 190, height: 17)
        healthDot.frame = NSRect(x: 270, y: 43, width: 8, height: 8)
        healthField.frame = NSRect(x: 288, y: 37, width: 190, height: 19)
        integrationField.frame = NSRect(
            x: max(486, card.bounds.width - 210),
            y: 37,
            width: 190,
            height: 19
        )
        activityField.frame = NSRect(
            x: max(486, card.bounds.width - 210),
            y: 16,
            width: 190,
            height: 17
        )
        integrationField.alignment = .right
        activityField.alignment = .right
    }
}

private func agentRuntimeVersionText(_ status: AgentRuntimeStatus) -> String {
    if status.diagnostics.health == .unknown,
       status.diagnostics.summary == "尚未检查"
    {
        return "安装状态检查中"
    }
    guard status.discovery.isInstalled else { return "未检测到本机安装" }
    guard let version = status.discovery.version, !version.isEmpty else {
        return "已检测到 · 版本未知"
    }
    return "已检测到 · \(version)"
}

private func agentRuntimeIntegrationText(_ status: AgentRuntimeStatus) -> String {
    guard let integrationStatus = status.integrationStatus else {
        return "集成未检查"
    }
    switch integrationStatus {
    case .notManaged: return "无需集成"
    case .notInstalled: return "集成未安装"
    case .installed: return "集成已安装"
    case .disabled: return "集成已停用"
    case .needsRepair: return "集成需修复"
    case .unsupportedVersion: return "版本不兼容"
    }
}

private func agentRuntimeHealthColor(_ health: AgentHealth) -> NSColor {
    switch health {
    case .healthy: return DynamicIslandPalette.green
    case .degraded: return DynamicIslandPalette.amber
    case .unavailable: return DynamicIslandPalette.red
    case .unknown: return DynamicIslandPalette.secondaryText
    }
}

private func agentRuntimeAccessibilitySummary(
    _ status: AgentRuntimeStatus
) -> String {
    [
        status.metadata.displayName,
        agentRuntimeVersionText(status),
        status.diagnostics.summary,
        agentRuntimeIntegrationText(status),
        "运行 \(status.activeSessionCount)",
        "需你 \(status.attentionCount)",
    ].joined(separator: "，")
}

private final class DynamicIslandAgentHealthLabel: NSTextField {
    init(size: CGFloat, weight: NSFont.Weight) {
        super.init(frame: .zero)
        isBezeled = false
        isEditable = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        textColor = DynamicIslandPalette.primaryText
        font = .systemFont(ofSize: size, weight: weight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
