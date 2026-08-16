//
//  DynamicIslandAgentHealthView.swift
//  ThreadHelm
//
//  模块职责：只读展示五个本地 Agent 的发现、观察与集成健康状态。
//

import AppKit
import Foundation

enum AgentIntegrationRowTransientState: Equatable {
    case idle
    case configuring
    case noop(String)
    case failed(String)
}

enum AgentIntegrationRowEmphasis: Equatable {
    case normal
    case warning
    case error
}

/// 行内集成控件的渲染决策。抽成纯函数以便自测在不实例化 NSTableView 行视图的
/// 前提下断言三态渲染与按钮可用性。
enum AgentIntegrationRowAction: Equatable {
    case button(title: String, operation: AgentIntegrationOperation?, isEnabled: Bool)
    case text(String, tooltip: String?, emphasis: AgentIntegrationRowEmphasis)
}

/// `.configuring` 的兜底超时。正常路径由 AppDelegate 在操作结束时显式置回
/// `.idle`；此计时器只用于防止任何异常路径把行永久锁在禁用态。
private let agentIntegrationConfiguringWatchdogDelay: TimeInterval = 20.0
private let agentIntegrationTransientResetDelay: TimeInterval = 3.0
/// 首次开启自动集成时，二次确认的等待窗口。超时自动撤销，避免误触后一直
/// 停在待确认态。
private let autoIntegrationConfirmWindow: TimeInterval = 8.0

/// 自动集成开关的渲染决策。抽成纯函数，理由同 `agentIntegrationRowAction`：
/// 让自测能在不驱动 AppKit 的前提下断言"首次开启必须二次确认"。
enum AgentAutoIntegrationControl: Equatable {
    case off(title: String, tooltip: String)
    case awaitingConfirmation(title: String, tooltip: String)
    case on(title: String, tooltip: String)
}

func agentAutoIntegrationControl(
    isEnabled: Bool,
    hasConfirmed: Bool,
    isAwaitingConfirmation: Bool
) -> AgentAutoIntegrationControl {
    if isEnabled {
        return .on(
            title: "自动集成：开启",
            tooltip: "已开启：检测到新安装的已验证 Agent 时自动写入其受管配置"
        )
    }
    if isAwaitingConfirmation {
        return .awaitingConfirmation(
            title: "再点一次确认",
            tooltip: "开启后 ThreadHelm 会在后台自动写入已验证 Agent 的厂商配置"
                + "（如 ~/.claude/settings.json），并在写入前保存本机恢复点。"
                + "再点一次确认开启。"
        )
    }
    return .off(
        title: "自动集成：关闭",
        tooltip: hasConfirmed
            ? "点击开启：检测到新安装的已验证 Agent 时自动集成"
            : "点击开启：会先请你确认一次，之后才会自动写入厂商配置（默认关闭）"
    )
}

func agentIntegrationRowAction(
    status: AgentRuntimeStatus,
    transientState: AgentIntegrationRowTransientState
) -> AgentIntegrationRowAction {
    switch transientState {
    case .configuring:
        return .button(title: "正在配置…", operation: nil, isEnabled: false)
    case .noop(let message):
        return .text(message, tooltip: message, emphasis: .warning)
    case .failed(let message):
        // 行内 label 只有 270pt 且尾部截断，而回滚结论恰好拼在消息末尾，
        // 长错误会把"原配置已恢复 / 自动恢复未完成"截掉——这正是用户最需要
        // 知道的部分。完整文案同时放进 tooltip 兜底。
        return .text(message, tooltip: message, emphasis: .error)
    case .idle:
        break
    }

    let readOnlyText = agentRuntimeIntegrationText(status)
    let isValidated = status.discovery.compatibility == .validated

    switch status.integrationStatus {
    case .notInstalled where isValidated:
        return .button(title: "一键安装", operation: .install, isEnabled: true)
    case .needsRepair where isValidated:
        return .button(title: "立即修复", operation: .repair, isEnabled: true)
    case .notInstalled, .needsRepair:
        return .text(
            readOnlyText,
            tooltip: "版本未经真值验证，暂不改写厂商配置",
            emphasis: .normal
        )
    case .checkFailed:
        return .text(
            readOnlyText,
            tooltip: "无法读取本地配置，写入不安全",
            emphasis: .normal
        )
    case .disabled:
        return .text(
            readOnlyText,
            tooltip: "已在厂商配置中显式停用",
            emphasis: .normal
        )
    case .installed, .notManaged, .unsupportedVersion, .none:
        return .text(readOnlyText, tooltip: nil, emphasis: .normal)
    }
}

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
    private let autoIntegrationButton = DynamicIslandButton(
        title: "自动集成：关闭",
        style: .secondary
    )
    private let tableScrollView = NSScrollView()
    private let tableView = NSTableView()

    private var statuses: [AgentRuntimeStatus] = []
    private let validationProfiles = builtInAgentValidationProfiles()
    private var eventChannelAvailable: Bool?
    private var isAutoIntegrationEnabled = false
    private var hasConfirmedAutoIntegration = false
    private var isAwaitingAutoIntegrationConfirmation = false
    private var autoIntegrationConfirmTimer: Timer?
    private var transientStates: [AgentID: AgentIntegrationRowTransientState] = [:]
    private var transientResetTimers: [AgentID: Timer] = [:]
    var onPerformIntegration: ((AgentID, AgentIntegrationOperation) -> Void)?
    var onToggleAutoIntegration: ((Bool) -> Void)?

    deinit {
        for timer in transientResetTimers.values {
            timer.invalidate()
        }
        transientResetTimers.removeAll()
        autoIntegrationConfirmTimer?.invalidate()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        for timer in transientResetTimers.values {
            timer.invalidate()
        }
        transientResetTimers.removeAll()
        transientStates.removeAll()
        // 面板关闭即撤销未完成的确认，确认必须是一次连续的显式动作。
        autoIntegrationConfirmTimer?.invalidate()
        autoIntegrationConfirmTimer = nil
        isAwaitingAutoIntegrationConfirmation = false
    }

    func setTransientState(
        _ state: AgentIntegrationRowTransientState,
        for agentID: AgentID
    ) {
        // AppDelegate 可能在灵动岛从未展开过时就设置瞬态，先确保视图已加载，
        // 否则下面的 reloadData 落在一个还没接 dataSource 的表上。
        _ = view
        transientResetTimers[agentID]?.invalidate()
        transientResetTimers[agentID] = nil
        transientStates[agentID] = state

        switch state {
        case .noop, .failed:
            scheduleTransientReset(
                for: agentID,
                delay: agentIntegrationTransientResetDelay
            )
        case .configuring:
            // 兜底：正常路径由 AppDelegate 在操作结束时显式置回 .idle。
            // 万一那条路径没走到（例如刷新回调丢失），也绝不能把行永久锁死。
            scheduleTransientReset(
                for: agentID,
                delay: agentIntegrationConfiguringWatchdogDelay
            )
        case .idle:
            break
        }

        tableView.reloadData()
        // 与 apply(_:) 保持一致，让后续布局把行视图重新建出来。
        view.needsLayout = true
    }

    /// 供自测断言行内集成控件的渲染结果，不实例化行视图。
    /// 注意：**不得**并入 `rowSummariesForSelfTest()`，否则会破坏既有无障碍快照契约。
    func integrationActionSummariesForSelfTest() -> [String] {
        statuses.map { status in
            let action = agentIntegrationRowAction(
                status: status,
                transientState: transientStates[status.metadata.id] ?? .idle
            )
            switch action {
            case .button(let title, let operation, let isEnabled):
                return [
                    status.metadata.id.rawValue,
                    "button",
                    title,
                    operation?.rawValue ?? "-",
                    isEnabled ? "enabled" : "disabled",
                ].joined(separator: "|")
            case .text(let text, let tooltip, let emphasis):
                return [
                    status.metadata.id.rawValue,
                    "text",
                    text,
                    tooltip ?? "-",
                    String(describing: emphasis),
                ].joined(separator: "|")
            }
        }
    }

    func performToggleAutoIntegrationForSelfTest() {
        _ = view
        handleAutoIntegrationToggle()
    }

    func isAutoIntegrationEnabledForSelfTest() -> Bool {
        isAutoIntegrationEnabled
    }

    /// 供预览渲染把开关摆到待确认态，不触发任何回调、不落 defaults。
    func armAutoIntegrationConfirmationForPreview() {
        _ = view
        isAwaitingAutoIntegrationConfirmation = true
        autoIntegrationConfirmTimer?.invalidate()
        autoIntegrationConfirmTimer = nil
        renderAutoIntegrationStatus()
    }

    /// 模拟确认窗口超时（8 秒计时器到点）走的那条撤销路径。
    func expireAutoIntegrationConfirmationForSelfTest() {
        _ = view
        autoIntegrationConfirmTimer?.invalidate()
        autoIntegrationConfirmTimer = nil
        isAwaitingAutoIntegrationConfirmation = false
        renderAutoIntegrationStatus()
    }

    /// 面板关闭走的那条撤销路径。
    func dismissAutoIntegrationConfirmationForSelfTest() {
        _ = view
        viewDidDisappear()
    }

    func autoIntegrationControlForSelfTest() -> AgentAutoIntegrationControl {
        _ = view
        return agentAutoIntegrationControl(
            isEnabled: isAutoIntegrationEnabled,
            hasConfirmed: hasConfirmedAutoIntegration,
            isAwaitingConfirmation: isAwaitingAutoIntegrationConfirmation
        )
    }

    private func scheduleTransientReset(for agentID: AgentID, delay: TimeInterval) {
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.transientStates[agentID] = .idle
            self.transientResetTimers[agentID] = nil
            self.tableView.reloadData()
        }
        transientResetTimers[agentID] = timer
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 560))
        view.wantsLayer = true
        view.addSubview(titleField)
        view.addSubview(localOnlyField)
        view.addSubview(channelCard)
        channelCard.addSubview(channelDot)
        channelCard.addSubview(channelTitleField)
        channelCard.addSubview(channelDetailField)
        channelCard.addSubview(autoIntegrationButton)
        view.addSubview(tableScrollView)

        titleField.stringValue = "Agents / Integrations"
        titleField.setAccessibilityLabel("Agents 和 Integrations 健康状态")
        localOnlyField.stringValue = "仅检查这台 Mac；不上传任务内容"
        localOnlyField.textColor = DynamicIslandPalette.secondaryText
        localOnlyField.alignment = .right

        channelDot.wantsLayer = true
        channelDot.layer?.cornerRadius = 5
        channelDetailField.textColor = DynamicIslandPalette.secondaryText

        autoIntegrationButton.target = self
        autoIntegrationButton.action = #selector(handleAutoIntegrationToggle)
        renderAutoIntegrationStatus()

        tableView.headerView = nil
        tableView.rowHeight = 104
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
        let autoButtonWidth: CGFloat = 130
        autoIntegrationButton.frame = NSRect(
            x: max(280, channelCard.bounds.width - autoButtonWidth - 12),
            y: 12,
            width: autoButtonWidth,
            height: 28
        )
        channelDetailField.frame = NSRect(
            x: 36,
            y: 8,
            width: max(1, autoIntegrationButton.frame.minX - 44),
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

    @objc private func handleAutoIntegrationToggle() {
        autoIntegrationConfirmTimer?.invalidate()
        autoIntegrationConfirmTimer = nil

        if isAutoIntegrationEnabled {
            // 关闭无需确认。
            isAutoIntegrationEnabled = false
            isAwaitingAutoIntegrationConfirmation = false
            renderAutoIntegrationStatus()
            onToggleAutoIntegration?(false)
            return
        }

        // 首次开启必须二次确认：这条路径会让 ThreadHelm 在无人值守时写入
        // 厂商配置，单击不足以构成同意。
        if !hasConfirmedAutoIntegration, !isAwaitingAutoIntegrationConfirmation {
            isAwaitingAutoIntegrationConfirmation = true
            renderAutoIntegrationStatus()
            autoIntegrationConfirmTimer = Timer.scheduledTimer(
                withTimeInterval: autoIntegrationConfirmWindow,
                repeats: false
            ) { [weak self] _ in
                guard let self else { return }
                self.isAwaitingAutoIntegrationConfirmation = false
                self.autoIntegrationConfirmTimer = nil
                self.renderAutoIntegrationStatus()
            }
            return
        }

        isAwaitingAutoIntegrationConfirmation = false
        isAutoIntegrationEnabled = true
        hasConfirmedAutoIntegration = true
        renderAutoIntegrationStatus()
        onToggleAutoIntegration?(true)
    }

    private func renderAutoIntegrationStatus() {
        switch agentAutoIntegrationControl(
            isEnabled: isAutoIntegrationEnabled,
            hasConfirmed: hasConfirmedAutoIntegration,
            isAwaitingConfirmation: isAwaitingAutoIntegrationConfirmation
        ) {
        case .on(let title, let tooltip):
            autoIntegrationButton.setDisplayTitle(title)
            autoIntegrationButton.setVisualStyle(.primary)
            autoIntegrationButton.toolTip = tooltip
            autoIntegrationButton.setAccessibilityLabel("自动集成开关，当前已开启")
        case .awaitingConfirmation(let title, let tooltip):
            autoIntegrationButton.setDisplayTitle(title)
            autoIntegrationButton.setVisualStyle(.destructive)
            autoIntegrationButton.toolTip = tooltip
            autoIntegrationButton.setAccessibilityLabel("自动集成开关，等待确认开启")
        case .off(let title, let tooltip):
            autoIntegrationButton.setDisplayTitle(title)
            autoIntegrationButton.setVisualStyle(.secondary)
            autoIntegrationButton.toolTip = tooltip
            autoIntegrationButton.setAccessibilityLabel("自动集成开关，当前已关闭")
        }
    }

    func apply(_ snapshot: ActivityDashboardSnapshot) {
        _ = view
        eventChannelAvailable = snapshot.agentEventChannelAvailable
        isAutoIntegrationEnabled = snapshot.isAutoIntegrationEnabled
        hasConfirmedAutoIntegration = snapshot.hasConfirmedAutoIntegration
        if isAutoIntegrationEnabled {
            isAwaitingAutoIntegrationConfirmation = false
        }
        renderAutoIntegrationStatus()
        statuses = (snapshot.agentStatuses.isEmpty
            ? agentRuntimeStatusPlaceholders()
            : snapshot.agentStatuses).sorted {
                $0.metadata.id < $1.metadata.id
            }
        // 注意：这里**不**清除 `.configuring`。快照刷新由额度/任务等多条无关链路
        // 频繁触发，条件清除既可能提前解锁按钮，也可能在状态未收敛时永远清不掉。
        // `.configuring` 的解除统一由 AppDelegate 在操作结束时显式驱动，
        // 并由 setTransientState 的看门狗计时器兜底。
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
        let status = statuses[row]
        let transientState = transientStates[status.metadata.id] ?? .idle
        return DynamicIslandAgentHealthRowView(
            status: status,
            profile: validationProfile(for: status.metadata.id),
            transientState: transientState,
            onPerformIntegration: { [weak self] agentID, op in
                self?.onPerformIntegration?(agentID, op)
            }
        )
    }

    func tableView(
        _ tableView: NSTableView,
        shouldSelectRow row: Int
    ) -> Bool {
        false
    }

    func rowSummariesForSelfTest() -> [String] {
        statuses.map { status in
            agentRuntimeAccessibilitySummary(
                status,
                profile: validationProfile(for: status.metadata.id)
            )
        }
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
        // 在 Optional<Bool> 上直接匹配 true/false/nil 只有较新的 Swift 认作穷尽，
        // CI runner 的编译器会要求补 .some(_)。先解包再分支，任何版本都成立。
        switch eventChannelAvailable {
        case .some(let isAvailable) where isAvailable:
            title = "本地事件通道正常"
            detail = "实时事件可用；本地轮询继续作为兜底"
            color = DynamicIslandPalette.green
        case .some:
            title = "本地事件通道已降级"
            detail = "实时事件暂不可用；本地轮询仍会继续工作"
            color = DynamicIslandPalette.amber
        case .none:
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

    private func validationProfile(
        for agentID: AgentID
    ) -> AgentValidationProfile {
        validationProfiles[agentID] ?? AgentValidationProfile(
            agentID: agentID,
            testedVersion: "尚无本机真值版本",
            supportedCapabilitiesSummary: "支持：以适配器声明为准",
            knownLimitation: "限制：尚未建立固定版本真值基线"
        )
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
    private let actionButton = DynamicIslandButton(title: "一键安装", style: .primary)
    private let activityField = DynamicIslandAgentHealthLabel(size: 11, weight: .regular)
    private let capabilityField = DynamicIslandAgentHealthLabel(size: 11, weight: .regular)
    private let limitationField = DynamicIslandAgentHealthLabel(size: 11, weight: .regular)

    private let agentID: AgentID
    private var targetOperation: AgentIntegrationOperation?
    private let onPerformIntegration: ((AgentID, AgentIntegrationOperation) -> Void)?

    init(
        status: AgentRuntimeStatus,
        profile: AgentValidationProfile,
        transientState: AgentIntegrationRowTransientState = .idle,
        onPerformIntegration: ((AgentID, AgentIntegrationOperation) -> Void)? = nil
    ) {
        self.agentID = status.metadata.id
        self.onPerformIntegration = onPerformIntegration
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
            actionButton,
            activityField,
            capabilityField,
            limitationField,
        ] {
            card.addSubview(subview)
        }

        actionButton.target = self
        actionButton.action = #selector(handleActionButtonClick)

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
        versionField.stringValue = agentRuntimeVersionText(
            status,
            testedVersion: profile.testedVersion
        )
        versionField.textColor = DynamicIslandPalette.secondaryText
        capabilityField.stringValue = agentRuntimeCapabilityText(
            status,
            profile: profile
        )
        capabilityField.textColor = DynamicIslandPalette.secondaryText
        limitationField.stringValue = profile.knownLimitation
        limitationField.textColor = DynamicIslandPalette.tertiaryText

        let healthColor = agentRuntimeHealthColor(status.diagnostics.health)
        healthDot.wantsLayer = true
        healthDot.layer?.cornerRadius = 4
        healthDot.layer?.backgroundColor = healthColor.cgColor
        healthField.stringValue = status.diagnostics.summary
        healthField.textColor = healthColor
        activityField.stringValue = "运行 \(status.activeSessionCount) · 需你 \(status.attentionCount)"
        activityField.textColor = DynamicIslandPalette.tertiaryText

        configureIntegrationUI(status: status, transientState: transientState)

        let summary = agentRuntimeAccessibilitySummary(
            status,
            profile: profile
        )
        setAccessibilityLabel(status.metadata.displayName)
        setAccessibilityValue(summary)
    }

    private func configureIntegrationUI(
        status: AgentRuntimeStatus,
        transientState: AgentIntegrationRowTransientState
    ) {
        // 渲染决策全部来自纯函数，视图只负责把决策翻译成 AppKit 属性。
        switch agentIntegrationRowAction(
            status: status,
            transientState: transientState
        ) {
        case .button(let title, let operation, let isEnabled):
            actionButton.isHidden = false
            actionButton.setDisplayTitle(title)
            actionButton.setVisualStyle(.primary)
            actionButton.isEnabled = isEnabled
            integrationField.isHidden = true
            integrationField.toolTip = nil
            targetOperation = operation
        case .text(let text, let tooltip, let emphasis):
            actionButton.isHidden = true
            actionButton.isEnabled = false
            integrationField.isHidden = false
            integrationField.stringValue = text
            integrationField.toolTip = tooltip
            targetOperation = nil
            switch emphasis {
            case .normal:
                integrationField.textColor = DynamicIslandPalette.secondaryText
            case .warning:
                integrationField.textColor = DynamicIslandPalette.amber
            case .error:
                integrationField.textColor = DynamicIslandPalette.red
            }
        }
    }

    @objc private func handleActionButtonClick() {
        guard let targetOperation else { return }
        onPerformIntegration?(agentID, targetOperation)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        card.frame = bounds.insetBy(dx: 4, dy: 2)
        iconBadge.frame = NSRect(x: 12, y: 32, width: 36, height: 36)
        iconView.frame = NSRect(x: 20, y: 40, width: 20, height: 20)
        // 右列从卡片右边缘反推，而不是用一个固定下限。原来的 max(500, …) 在
        // 实际渲染宽度（卡片约 758pt）下会让 500+270 超出卡片 12pt，所有右对齐
        // 文本都贴边溢出被裁；瞬态文案更长，裁得更明显。
        let rightColumnWidth: CGFloat = 270
        let rightInset: CGFloat = 12
        let rightX = max(
            200,
            card.bounds.width - rightColumnWidth - rightInset
        )
        let leftWidth = max(180, rightX - 76)
        nameField.frame = NSRect(x: 60, y: 74, width: leftWidth, height: 18)
        versionField.frame = NSRect(x: 60, y: 55, width: leftWidth, height: 17)
        capabilityField.frame = NSRect(x: 60, y: 35, width: leftWidth, height: 17)
        limitationField.frame = NSRect(x: 60, y: 15, width: leftWidth, height: 17)
        healthDot.frame = NSRect(x: rightX, y: 79, width: 8, height: 8)
        healthField.frame = NSRect(
            x: rightX + 18,
            y: 73,
            width: 252,
            height: 19
        )
        integrationField.frame = NSRect(
            x: rightX,
            y: 52,
            width: 270,
            height: 19
        )
        actionButton.frame = NSRect(
            x: card.bounds.width - 108,
            y: 47,
            width: 96,
            height: 26
        )
        activityField.frame = NSRect(
            x: rightX,
            y: 22,
            width: 270,
            height: 17
        )
        healthField.alignment = .right
        integrationField.alignment = .right
        activityField.alignment = .right
    }
}

private func agentRuntimeVersionText(
    _ status: AgentRuntimeStatus,
    testedVersion: String
) -> String {
    if status.diagnostics.health == .unknown,
       status.diagnostics.summary == "尚未检查"
    {
        return "本机检查中 · 测试 \(testedVersion)"
    }
    guard status.discovery.isInstalled else {
        return "本机未检测到 · 测试 \(testedVersion)"
    }
    let validation: String
    switch status.discovery.compatibility {
    case .validated:
        validation = "已验证"
    case .unvalidated:
        validation = "unvalidated"
    case .unknown:
        validation = "验证状态未知"
    }
    let components = status.discovery.versionComponents
    guard !components.isEmpty else {
        return "本机版本未知 · \(validation) · 测试 \(testedVersion)"
    }
    let localVersion: String
    if components.count == 1 {
        localVersion = components[0].value
    } else {
        localVersion = components.map { "\($0.label) \($0.value)" }
            .joined(separator: " · ")
    }
    return "本机 \(localVersion) · \(validation) · 测试 \(testedVersion)"
}

private func agentRuntimeCapabilityText(
    _ status: AgentRuntimeStatus,
    profile: AgentValidationProfile
) -> String {
    guard status.discovery.compatibility == .validated else {
        return "能力：当前本机版本未经固定真值验证"
    }
    return profile.supportedCapabilitiesSummary
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
    case .checkFailed: return "集成状态未能读取"
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
    _ status: AgentRuntimeStatus,
    profile: AgentValidationProfile
) -> String {
    [
        status.metadata.displayName,
        agentRuntimeVersionText(status, testedVersion: profile.testedVersion),
        agentRuntimeCapabilityText(status, profile: profile),
        profile.knownLimitation,
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
