import AppKit
import Foundation

struct DynamicIslandQuestionAnswerDraft: Equatable {
    var selectedOptionIndexes = Set<Int>()
    var customText = ""
}

func dynamicIslandAnswerValue(
    question: ClaudeQuestion,
    draft: DynamicIslandQuestionAnswerDraft
) -> Any? {
    let custom = draft.customText.trimmingCharacters(
        in: .whitespacesAndNewlines
    )
    if !custom.isEmpty { return custom }
    let selectedLabels = question.options.enumerated().compactMap {
        index, option in
        draft.selectedOptionIndexes.contains(index) ? option.label : nil
    }
    if question.allowsMultipleSelection {
        return selectedLabels.isEmpty
            ? nil
            : selectedLabels.joined(separator: ", ")
    }
    return selectedLabels.first
}

final class DynamicIslandConfirmationPresenter: ClaudePermissionPresenting {
    var onExpand: ((DynamicIslandTab) -> Void)?
    var onReturnToPriorTab: ((DynamicIslandTab) -> Void)?
    var onSetKeyWindowEligibility: ((Bool) -> Void)?
    var currentTab: (() -> DynamicIslandTab?)?

    private let show: (ClaudePermissionPresentation) -> Void
    private let dismissView: () -> Void
    private let repositionWindow: () -> Void
    private var priorTab: DynamicIslandTab = .tasks
    private var isPresenting = false
    private var isPresentationActive = false
    private var pendingDismissGeneration = 0

    init(
        show: @escaping (ClaudePermissionPresentation) -> Void,
        dismissView: @escaping () -> Void,
        repositionWindow: @escaping () -> Void
    ) {
        self.show = show
        self.dismissView = dismissView
        self.repositionWindow = repositionWindow
    }

    func setPresentationActive(_ active: Bool) {
        pendingDismissGeneration += 1
        isPresentationActive = active
        guard !active else { return }
        isPresenting = false
        dismissView()
        onSetKeyWindowEligibility?(false)
    }

    func present(_ presentation: ClaudePermissionPresentation) {
        guard isPresentationActive else { return }
        pendingDismissGeneration += 1
        if !isPresenting,
           let tab = currentTab?(),
           tab != .confirmation
        {
            priorTab = tab
        }
        show(presentation)
        isPresenting = true
        onExpand?(.confirmation)
        let requiresTextInput: Bool
        switch presentation.prompt.interactionKind {
        case .toolApproval:
            requiresTextInput = false
        case .askUserQuestion, .exitPlanMode:
            requiresTextInput = true
        }
        onSetKeyWindowEligibility?(requiresTextInput)
    }

    func dismiss() {
        pendingDismissGeneration += 1
        let generation = pendingDismissGeneration
        guard isPresentationActive else {
            isPresenting = false
            dismissView()
            onSetKeyWindowEligibility?(false)
            return
        }
        guard isPresenting else {
            dismissView()
            onSetKeyWindowEligibility?(false)
            return
        }
        isPresenting = false
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isPresentationActive,
                  !self.isPresenting,
                  generation == self.pendingDismissGeneration
            else { return }
            self.dismissView()
            self.onReturnToPriorTab?(self.priorTab)
            self.onSetKeyWindowEligibility?(false)
        }
    }

    func reposition() {
        repositionWindow()
    }

    func setPriorTabForSelfTest(_ tab: DynamicIslandTab) {
        priorTab = tab
    }
}

final class DynamicIslandConfirmationViewController:
    NSViewController,
    NSTableViewDataSource,
    NSTableViewDelegate
{
    private struct QueueRow {
        let item: ClaudePermissionQueueItem
        let isCurrent: Bool
    }

    var onDecision: ((ClaudePermissionUserDecision) -> Void)?
    var onReturnToTerminal: (() -> Void)?

    private let queueScrollView = NSScrollView()
    private let queueTableView = NSTableView()
    private let queuePanelView = NSView()
    private let queueTitleField = confirmationLabel(size: 13, weight: .semibold)
    private let queueCountField = confirmationLabel(size: 11, weight: .semibold)
    private let queueStack = NSStackView()
    private let contentContainer = NSView()
    private let validationField = confirmationLabel(size: 12, weight: .regular)
    private let historyTitleField = confirmationLabel(size: 18, weight: .semibold)
    private let historyPrivacyField = wrappingLabel(size: 12, weight: .regular)
    private let historyEmptyField = confirmationLabel(size: 13, weight: .regular)
    private let historyScrollView = NSScrollView()
    private let historyTableView = NSTableView()
    private let overlineField = confirmationLabel(size: 11, weight: .semibold)
    private let questionPageField = confirmationLabel(size: 12, weight: .medium)
    private let questionProgressView = DynamicIslandQuestionProgressView()
    private let formTitleField = confirmationLabel(size: 18, weight: .bold)
    private let formMessageField = wrappingLabel(size: 13, weight: .regular)
    private let toolScrollView = NSScrollView()
    private let toolDocumentView = NSView()
    private let toolCommandCard = DynamicIslandCardView(
        cornerRadius: 8,
        backgroundColor: DynamicIslandPalette.card,
        borderColor: DynamicIslandPalette.strongHairline,
        accentColor: DynamicIslandPalette.amber
    )
    private let toolRiskCard = DynamicIslandCardView(
        cornerRadius: 8,
        backgroundColor: DynamicIslandPalette.raised,
        borderColor: DynamicIslandPalette.hairline
    )
    private let toolSuggestionCard = DynamicIslandCardView(
        cornerRadius: 8,
        backgroundColor: DynamicIslandPalette.amber.withAlphaComponent(0.11),
        borderColor: DynamicIslandPalette.amber.withAlphaComponent(0.62),
        accentColor: DynamicIslandPalette.amber
    )
    private let toolCommandOverline = confirmationLabel(size: 11, weight: .semibold)
    private let toolCommandField = wrappingLabel(size: 14, weight: .semibold)
    private let toolCommandKindField = confirmationLabel(size: 11, weight: .medium)
    private let toolRiskTitleField = confirmationLabel(size: 11, weight: .semibold)
    private let toolRiskBodyField = wrappingLabel(size: 12, weight: .regular)
    private let toolPermissionTitleField = confirmationLabel(size: 11, weight: .semibold)
    private let toolPermissionBodyField = wrappingLabel(size: 12, weight: .regular)
    private var planTitleField: NSTextField?
    private var planMessageField: NSTextField?
    private var planScrollView: NSScrollView?
    private var planFeedbackHintField: NSTextField?
    private var planFeedbackScrollView: NSScrollView?
    private let planImpactCard = DynamicIslandCardView(
        cornerRadius: 8,
        backgroundColor: DynamicIslandPalette.amber.withAlphaComponent(0.08),
        borderColor: DynamicIslandPalette.amber.withAlphaComponent(0.34),
        accentColor: DynamicIslandPalette.amber
    )
    private let planImpactTitleField = confirmationLabel(size: 11, weight: .semibold)
    private let planImpactBodyField = wrappingLabel(size: 12, weight: .regular)
    private var presentation: ClaudePermissionPresentation?
    private var queueRows: [QueueRow] = []
    private var historyRecords: [PermissionDecisionHistoryRecord] = []
    private var questionDrafts: [DynamicIslandQuestionAnswerDraft] = []
    private var questionViews: [DynamicIslandQuestionInputView] = []
    private var currentQuestionIndex = 0
    private var decisionControls: [NSControl] = []
    private var toolSuggestionButtons: [NSButton] = []
    private var toolFooterButtons: [NSButton] = []
    private var didEmitDecision = false
    private var planFeedbackView: NSTextView?
    private var rawSummary = ""

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: dynamicIslandConfirmationSize))
        view.wantsLayer = true
        view.layer?.backgroundColor = DynamicIslandPalette.raised.cgColor
        view.addSubview(queuePanelView)
        view.addSubview(contentContainer)
        view.addSubview(validationField)
        queuePanelView.wantsLayer = true
        queuePanelView.layer?.backgroundColor =
            DynamicIslandPalette.surface.cgColor
        queuePanelView.layer?.cornerRadius = 10
        queuePanelView.layer?.borderWidth = 1
        queuePanelView.layer?.borderColor = DynamicIslandPalette.hairline.cgColor
        queuePanelView.addSubview(queueTitleField)
        queuePanelView.addSubview(queueCountField)
        queuePanelView.addSubview(queueStack)
        queueTitleField.stringValue = "待确认队列"
        queueTitleField.setAccessibilityLabel("待确认队列")
        queueTitleField.textColor = DynamicIslandPalette.primaryText
        queueCountField.alignment = .right
        queueCountField.textColor = DynamicIslandPalette.amber
        queueCountField.setAccessibilityLabel("待确认数量")
        queueStack.orientation = .vertical
        queueStack.alignment = .leading
        queueStack.spacing = 8

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("queue"))
        column.title = "确认队列"
        queueTableView.addTableColumn(column)
        queueTableView.headerView = nil
        queueTableView.delegate = self
        queueTableView.dataSource = self
        queueTableView.rowHeight = 66
        queueTableView.intercellSpacing = NSSize(width: 0, height: 4)
        queueTableView.backgroundColor = .clear
        queueTableView.selectionHighlightStyle = .regular
        queueTableView.setAccessibilityLabel("确认队列")
        queueScrollView.documentView = queueTableView
        queueScrollView.hasVerticalScroller = true
        queueScrollView.drawsBackground = false
        let historyColumn = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("history")
        )
        historyColumn.title = "审批历史"
        historyTableView.addTableColumn(historyColumn)
        historyTableView.headerView = nil
        historyTableView.delegate = self
        historyTableView.dataSource = self
        historyTableView.rowHeight = 58
        historyTableView.intercellSpacing = NSSize(width: 0, height: 5)
        historyTableView.selectionHighlightStyle = .none
        historyTableView.backgroundColor = .clear
        historyTableView.setAccessibilityLabel("最近审批历史")
        historyScrollView.documentView = historyTableView
        historyScrollView.hasVerticalScroller = true
        historyScrollView.drawsBackground = false
        toolScrollView.documentView = toolDocumentView
        toolScrollView.hasVerticalScroller = true
        toolScrollView.drawsBackground = false
        overlineField.stringValue = "CLAUDE · THREADHELM"
        overlineField.textColor = DynamicIslandPalette.tertiaryText
        toolCommandOverline.textColor = DynamicIslandPalette.tertiaryText
        toolCommandKindField.textColor = DynamicIslandPalette.amber
        toolRiskTitleField.textColor = DynamicIslandPalette.secondaryText
        toolRiskBodyField.textColor = DynamicIslandPalette.primaryText
        toolPermissionTitleField.textColor = DynamicIslandPalette.secondaryText
        toolPermissionBodyField.textColor = DynamicIslandPalette.primaryText

        validationField.textColor = DynamicIslandPalette.amber
        validationField.setAccessibilityLabel("确认表单提示")
        historyTitleField.stringValue = "最近审批"
        historyTitleField.setAccessibilityLabel("最近审批")
        historyPrivacyField.stringValue =
            "只保存 Agent、请求类型、裁决、时间、耗时和版本；不保存请求或回答正文。"
        historyPrivacyField.textColor = DynamicIslandPalette.secondaryText
        historyEmptyField.stringValue = "还没有审批记录"
        historyEmptyField.textColor = DynamicIslandPalette.tertiaryText
        historyEmptyField.alignment = .center
        buildHistoryContent()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let bounds = view.bounds
        let queueWidth: CGFloat = min(236, max(216, bounds.width * 0.30))
        queueScrollView.frame = NSRect(
            x: 0,
            y: 0,
            width: queueWidth,
            height: bounds.height
        ).insetBy(dx: 0, dy: 8)
        queuePanelView.frame = queueScrollView.frame
        queueTableView.frame = queueScrollView.bounds
        queueTableView.tableColumns.first?.width = max(
            1,
            queueScrollView.bounds.width - 4
        )
        queueTitleField.frame = NSRect(
            x: 14,
            y: queuePanelView.bounds.height - 32,
            width: queuePanelView.bounds.width - 80,
            height: 20
        )
        queueCountField.frame = NSRect(
            x: queuePanelView.bounds.width - 70,
            y: queuePanelView.bounds.height - 31,
            width: 56,
            height: 18
        )
        queueStack.frame = NSRect(
            x: 10,
            y: 10,
            width: queuePanelView.bounds.width - 20,
            height: max(1, queuePanelView.bounds.height - 52)
        )
        contentContainer.frame = NSRect(
            x: queuePanelView.frame.maxX + 14,
            y: 44,
            width: max(1, bounds.width - queuePanelView.frame.maxX - 22),
            height: max(1, bounds.height - 52)
        )
        validationField.frame = NSRect(
            x: contentContainer.frame.minX,
            y: 12,
            width: contentContainer.frame.width,
            height: 22
        )
        layoutVisibleContent()
    }

    func apply(_ presentation: ClaudePermissionPresentation) {
        _ = view
        self.presentation = presentation
        didEmitDecision = false
        decisionControls = []
        validationField.stringValue = ""
        rawSummary = ""
        applyQueueRows(from: presentation.queue)
        formTitleField.stringValue = promptContextTitle(presentation.prompt)
        formMessageField.stringValue = presentation.prompt.message

        questionDrafts = presentation.prompt.questions.map { _ in
            DynamicIslandQuestionAnswerDraft()
        }
        questionViews = []
        currentQuestionIndex = 0
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        toolSuggestionButtons = []
        toolFooterButtons = []
        planFeedbackView = nil
        planTitleField = nil
        planMessageField = nil
        planScrollView = nil
        planFeedbackHintField = nil
        planFeedbackScrollView = nil
        switch presentation.prompt.interactionKind {
        case .toolApproval:
            buildToolApproval(prompt: presentation.prompt)
        case .askUserQuestion:
            buildQuestions(prompt: presentation.prompt)
        case .exitPlanMode:
            buildPlanReview(prompt: presentation.prompt)
        }
        layoutVisibleContent()
    }

    func updateQueue(_ snapshot: ClaudePermissionQueueSnapshot) {
        _ = view
        guard presentation == nil || snapshot.current != nil else { return }
        applyQueueRows(from: snapshot)
    }

    func updateHistory(_ records: [PermissionDecisionHistoryRecord]) {
        _ = view
        historyRecords = Array(records.prefix(200))
        historyTableView.reloadData()
        if presentation == nil {
            buildHistoryContent()
            layoutVisibleContent()
        }
    }

    func clear() {
        presentation = nil
        queueRows = []
        queueTableView.reloadData()
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        toolDocumentView.subviews.forEach { $0.removeFromSuperview() }
        validationField.stringValue = ""
        decisionControls = []
        toolSuggestionButtons = []
        toolFooterButtons = []
        didEmitDecision = false
        questionDrafts = []
        questionViews = []
        planFeedbackView = nil
        planTitleField = nil
        planMessageField = nil
        planScrollView = nil
        planFeedbackHintField = nil
        planFeedbackScrollView = nil
        rawSummary = ""
        buildHistoryContent()
    }

    func initialInputResponder() -> NSResponder? {
        guard let interactionKind = presentation?.prompt.interactionKind else {
            return nil
        }
        switch interactionKind {
        case .toolApproval:
            return nil
        case .askUserQuestion:
            return questionViews.first?.initialInputResponder
        case .exitPlanMode:
            return planFeedbackView
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === historyTableView {
            return historyRecords.count
        }
        return queueRows.count
    }

    func tableView(
        _ tableView: NSTableView,
        shouldSelectRow row: Int
    ) -> Bool {
        if tableView === historyTableView { return false }
        guard queueRows.indices.contains(row) else { return false }
        return queueRows[row].isCurrent
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        if tableView === historyTableView {
            guard historyRecords.indices.contains(row) else { return nil }
            return historyCell(for: historyRecords[row])
        }
        guard row < queueRows.count else { return nil }
        let rowModel = queueRows[row]
        let item = rowModel.item
        let cell = NSTableCellView()
        let title = confirmationLabel(size: 13, weight: .semibold)
        let detail = confirmationLabel(size: 12, weight: .regular)
        title.stringValue =
            "\(rowModel.isCurrent ? "当前" : "待处理") · \(kindTitle(item.interactionKind))"
        detail.stringValue = "\(item.title) · \(timeText(item.arrivedAt))"
        detail.textColor = DynamicIslandPalette.secondaryText
        cell.addSubview(title)
        cell.addSubview(detail)
        title.frame = NSRect(x: 10, y: 36, width: 220, height: 18)
        detail.frame = NSRect(x: 10, y: 14, width: 220, height: 18)
        cell.setAccessibilityLabel(title.stringValue)
        cell.setAccessibilityValue(detail.stringValue)
        return cell
    }

    private func applyQueueRows(from snapshot: ClaudePermissionQueueSnapshot) {
        queueRows = queueRows(from: snapshot)
        queueCountField.stringValue = "\(queueRows.count) 个"
        queueCountField.setAccessibilityValue("\(queueRows.count) 个待确认请求")
        queueTableView.reloadData()
        rebuildQueueStack()
        if let selectedIndex = queueRows.firstIndex(where: \.isCurrent) {
            queueTableView.selectRowIndexes(
                IndexSet(integer: selectedIndex),
                byExtendingSelection: false
            )
        } else {
            queueTableView.deselectAll(nil)
        }
    }

    private func queueRows(
        from snapshot: ClaudePermissionQueueSnapshot
    ) -> [QueueRow] {
        let currentRows = snapshot.current.map {
            [QueueRow(item: $0, isCurrent: true)]
        } ?? []
        let pendingRows = snapshot.pending.map {
            QueueRow(item: $0, isCurrent: false)
        }
        return currentRows + pendingRows
    }

    private func rebuildQueueStack() {
        queueStack.arrangedSubviews.forEach {
            queueStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        if queueRows.isEmpty {
            let label = confirmationLabel(size: 12, weight: .regular)
            label.stringValue = "暂无待确认请求"
            label.textColor = DynamicIslandPalette.tertiaryText
            label.setAccessibilityLabel(label.stringValue)
            queueStack.addArrangedSubview(label)
            return
        }
        for (index, row) in queueRows.enumerated() {
            let rowView = DynamicIslandQueueRowView(
                index: index + 1,
                item: row.item,
                isCurrent: row.isCurrent
            )
            rowView.widthAnchor.constraint(equalToConstant: max(1, queuePanelView.bounds.width - 20)).isActive = true
            rowView.heightAnchor.constraint(equalToConstant: 60).isActive = true
            queueStack.addArrangedSubview(rowView)
        }
    }

    private func agentQueueCode(_ agentID: AgentID) -> String {
        agentPresentation(for: agentID).shortName.uppercased()
    }

    private func buildHistoryContent() {
        guard presentation == nil else { return }
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        for child in [
            historyTitleField,
            historyPrivacyField,
            historyScrollView,
            historyEmptyField,
        ] {
            contentContainer.addSubview(child)
        }
        historyScrollView.isHidden = historyRecords.isEmpty
        historyEmptyField.isHidden = !historyRecords.isEmpty
        historyTableView.reloadData()
        view.needsLayout = true
    }

    private func historyCell(
        for record: PermissionDecisionHistoryRecord
    ) -> NSView {
        let cell = NSTableCellView()
        cell.wantsLayer = true
        cell.layer?.cornerRadius = 7
        cell.layer?.backgroundColor = DynamicIslandPalette.card.cgColor
        cell.layer?.borderWidth = 1
        cell.layer?.borderColor = DynamicIslandPalette.hairline.cgColor
        let title = confirmationLabel(size: 12.5, weight: .semibold)
        let detail = confirmationLabel(size: 10.5, weight: .regular)
        let agent = agentPresentation(for: record.agentID).displayName
        title.stringValue = "\(agent) · \(record.requestKind.displayTitle)"
            + " · \(record.outcome.displayTitle)"
        let version = record.agentVersionSignature.map {
            String($0.prefix(72))
        } ?? "版本未知"
        detail.stringValue = "\(timeText(record.decidedAt))"
            + " · 耗时 \(historyDurationText(record.durationSeconds))"
            + " · \(version)"
        detail.textColor = DynamicIslandPalette.secondaryText
        cell.addSubview(title)
        cell.addSubview(detail)
        let contentWidth = max(1, historyTableView.bounds.width - 38)
        title.frame = NSRect(x: 12, y: 31, width: contentWidth, height: 18)
        detail.frame = NSRect(x: 12, y: 10, width: contentWidth, height: 16)
        title.autoresizingMask = [.width]
        detail.autoresizingMask = [.width]
        cell.setAccessibilityLabel(title.stringValue)
        cell.setAccessibilityValue(detail.stringValue)
        return cell
    }

    private func historyDurationText(_ seconds: Int) -> String {
        if seconds < 1 { return "<1 秒" }
        if seconds < 60 { return "\(seconds) 秒" }
        return "\(seconds / 60) 分 \(seconds % 60) 秒"
    }

    private func buildToolApproval(prompt: ClaudePermissionPrompt) {
        overlineField.stringValue = "\(agentQueueCode(prompt.agentID)) · THREADHELM"
        formTitleField.stringValue = "\(kindTitle(prompt.interactionKind)) · \(prompt.toolName)"
        formMessageField.stringValue = prompt.message
        rawSummary = boundedRawSummary(from: prompt.originalToolInput)
        toolCommandOverline.stringValue = "工具命令"
        toolCommandField.stringValue = rawSummary.isEmpty
            ? prompt.toolName
            : rawSummary
        toolCommandKindField.stringValue = prompt.toolName
        toolRiskTitleField.stringValue = "风险"
        toolRiskBodyField.stringValue = riskSummary(for: prompt)
        toolPermissionTitleField.stringValue = "权限建议"
        toolPermissionBodyField.stringValue = permissionSummary(for: prompt)
        toolDocumentView.subviews.forEach { $0.removeFromSuperview() }
        toolDocumentView.addSubview(toolCommandCard)
        toolDocumentView.addSubview(toolRiskCard)
        toolDocumentView.addSubview(toolSuggestionCard)
        for view in [
            toolCommandOverline,
            toolCommandField,
            toolCommandKindField,
            toolRiskTitleField,
            toolRiskBodyField,
            toolPermissionTitleField,
            toolPermissionBodyField,
        ] {
            toolDocumentView.addSubview(view)
        }

        toolSuggestionButtons = prompt.suggestions.enumerated().map { index, suggestion in
            actionButton(title: "长期允许 \(suggestion.title)") { [weak self] in
                self?.emit(.allowWithSuggestion(prompt.suggestions[index].rawValue))
            }
        }
        toolSuggestionButtons.forEach { toolDocumentView.addSubview($0) }
        toolFooterButtons = [
            actionButton(title: "回到终端") { [weak self] in
                self?.emitAndReturnToTerminal()
            },
            actionButton(title: "拒绝") { [weak self] in
                self?.emit(.deny("用户在 ThreadHelm 中拒绝了这次操作"))
            },
            actionButton(title: "允许一次", keyEquivalent: "\r") { [weak self] in
                self?.emit(.allowOnce)
            },
        ]
        toolFooterButtons[0].setVisualStyleForConfirmation(.secondary)
        toolFooterButtons[1].setVisualStyleForConfirmation(.destructive)
        toolFooterButtons[2].setVisualStyleForConfirmation(.primary)
        contentContainer.addSubview(overlineField)
        contentContainer.addSubview(formTitleField)
        contentContainer.addSubview(formMessageField)
        contentContainer.addSubview(toolScrollView)
        toolFooterButtons.forEach { contentContainer.addSubview($0) }
        decisionControls = toolSuggestionButtons + toolFooterButtons
    }

    private func buildQuestions(prompt: ClaudePermissionPrompt) {
        overlineField.stringValue = "\(agentQueueCode(prompt.agentID)) · THREADHELM"
        contentContainer.addSubview(overlineField)
        contentContainer.addSubview(formTitleField)
        contentContainer.addSubview(formMessageField)
        questionViews = prompt.questions.enumerated().map { index, question in
            let input = DynamicIslandQuestionInputView(question: question)
            input.onDraftChange = { [weak self] draft in
                guard let self,
                      self.questionDrafts.indices.contains(index)
                else { return }
                self.questionDrafts[index] = draft
                self.updateQuestionProgress()
            }
            return input
        }
        questionViews.forEach { contentContainer.addSubview($0) }
        contentContainer.addSubview(questionProgressView)
        updateQuestionProgress()
        let previous = actionButton(title: "上一题") { [weak self] in
            self?.moveQuestionPage(delta: -1)
        }
        let next = actionButton(title: "下一题") { [weak self] in
            self?.moveQuestionPage(delta: 1)
        }
        let terminal = actionButton(title: "回到终端") { [weak self] in
            self?.emitAndReturnToTerminal()
        }
        let submit = actionButton(title: "提交回答", keyEquivalent: "\r") { [weak self] in
            self?.submitAnswers()
        }
        terminal.setVisualStyleForConfirmation(.secondary)
        submit.setVisualStyleForConfirmation(.primary)
        previous.setVisualStyleForConfirmation(.subtle)
        next.setVisualStyleForConfirmation(.secondary)
        previous.identifier = NSUserInterfaceItemIdentifier("previous")
        next.identifier = NSUserInterfaceItemIdentifier("next")
        questionPageField.setAccessibilityLabel("问题页码")
        contentContainer.addSubview(questionPageField)
        for button in [previous, next, terminal, submit] {
            contentContainer.addSubview(button)
        }
        decisionControls = [terminal, submit]
    }

    private func buildPlanReview(prompt: ClaudePermissionPrompt) {
        overlineField.stringValue = "\(agentQueueCode(prompt.agentID)) · THREADHELM"
        formTitleField.stringValue = "计划审批"
        formMessageField.stringValue = prompt.message
        let planScroll = NSScrollView()
        let planText = NSTextView()
        planText.string = prompt.planText ?? ""
        planText.isEditable = false
        planText.isSelectable = true
        planText.drawsBackground = true
        planText.backgroundColor = DynamicIslandPalette.background
        planText.textColor = DynamicIslandPalette.primaryText
        planText.font = .systemFont(ofSize: 13)
        planText.textContainerInset = NSSize(width: 12, height: 10)
        planScroll.documentView = planText
        planScroll.hasVerticalScroller = true
        planScroll.wantsLayer = true
        planScroll.drawsBackground = true
        planScroll.backgroundColor = DynamicIslandPalette.background
        planScroll.layer?.backgroundColor = DynamicIslandPalette.background.cgColor
        planScroll.layer?.borderWidth = 1
        planScroll.layer?.borderColor = DynamicIslandPalette.strongHairline.cgColor
        planScroll.layer?.cornerRadius = 8
        planScroll.setAccessibilityLabel("Claude 计划内容")

        let feedbackScroll = NSScrollView()
        let feedback = NSTextView()
        feedbackScroll.wantsLayer = true
        feedbackScroll.layer?.borderWidth = 1.5
        feedbackScroll.layer?.borderColor = DynamicIslandPalette.amber
            .withAlphaComponent(0.85).cgColor
        let feedbackBackground = NSColor(calibratedWhite: 0.14, alpha: 1)
        feedbackScroll.layer?.backgroundColor = feedbackBackground.cgColor
        feedbackScroll.layer?.cornerRadius = 8
        feedback.drawsBackground = true
        feedback.backgroundColor = feedbackBackground
        feedback.textColor = DynamicIslandPalette.primaryText
        feedback.font = .systemFont(ofSize: 13)
        feedback.textContainerInset = NSSize(width: 10, height: 8)
        feedback.wantsLayer = true
        feedback.layer?.borderWidth = 0
        feedback.setAccessibilityLabel("计划修改反馈")
        feedbackScroll.documentView = feedback
        feedbackScroll.hasVerticalScroller = true
        feedbackScroll.drawsBackground = true
        feedbackScroll.backgroundColor = feedbackBackground
        planFeedbackView = feedback
        let feedbackHint = confirmationLabel(size: 12, weight: .medium)
        feedbackHint.stringValue = "需要调整？填写修改意见后让 Claude 修改。"
        feedbackHint.textColor = DynamicIslandPalette.amber
        let stepCount = max(
            1,
            (prompt.planText ?? "")
                .split(whereSeparator: \.isNewline)
                .filter {
                    !String($0)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                }
                .count
        )
        planImpactTitleField.stringValue = "执行影响"
        planImpactTitleField.textColor = DynamicIslandPalette.amber
        planImpactBodyField.stringValue =
            "批准后 Claude 将继续执行 \(stepCount) 个步骤；可能运行命令或修改文件，请先确认范围与验证覆盖。"
        planImpactBodyField.textColor = DynamicIslandPalette.secondaryText
        planImpactCard.addSubview(planImpactTitleField)
        planImpactCard.addSubview(planImpactBodyField)

        let terminal = actionButton(title: "回到终端") { [weak self] in
            self?.emitAndReturnToTerminal()
        }
        let feedbackButton = actionButton(title: "让 Claude 修改") { [weak self] in
            self?.sendPlanFeedback()
        }
        let approve = actionButton(title: "批准并继续", keyEquivalent: "\r") { [weak self] in
            self?.emit(.allowOnce)
        }
        terminal.setVisualStyleForConfirmation(.secondary)
        feedbackButton.setVisualStyleForConfirmation(.secondary)
        approve.setVisualStyleForConfirmation(.primary)
        planTitleField = formTitleField
        planMessageField = formMessageField
        planScrollView = planScroll
        planFeedbackHintField = feedbackHint
        planFeedbackScrollView = feedbackScroll
        for view in [
            overlineField,
            formTitleField,
            formMessageField,
            planScroll,
            planImpactCard,
            feedbackHint,
            feedbackScroll,
            terminal,
            feedbackButton,
            approve,
        ] {
            contentContainer.addSubview(view)
        }
        decisionControls = [terminal, feedbackButton, approve]
    }

    private func layoutVisibleContent() {
        let bounds = contentContainer.bounds
        guard let presentation else {
            layoutHistoryContent(bounds)
            return
        }
        switch presentation.prompt.interactionKind {
        case .toolApproval:
            layoutToolContent(bounds)
        case .askUserQuestion:
            layoutQuestionContent(bounds)
        case .exitPlanMode:
            layoutPlanContent(bounds)
        }
    }

    private func layoutHistoryContent(_ bounds: NSRect) {
        historyTitleField.frame = NSRect(
            x: 0,
            y: bounds.height - 34,
            width: bounds.width,
            height: 24
        )
        historyPrivacyField.frame = NSRect(
            x: 0,
            y: bounds.height - 68,
            width: bounds.width,
            height: 30
        )
        historyScrollView.frame = NSRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: max(1, bounds.height - 78)
        )
        historyTableView.tableColumns.first?.width = max(
            1,
            historyScrollView.bounds.width - 4
        )
        historyEmptyField.frame = NSRect(
            x: 0,
            y: max(0, bounds.midY - 12),
            width: bounds.width,
            height: 24
        )
    }

    private func layoutToolContent(_ bounds: NSRect) {
        overlineField.frame = NSRect(x: 0, y: bounds.height - 24, width: bounds.width, height: 14)
        formTitleField.frame = NSRect(x: 0, y: bounds.height - 58, width: bounds.width, height: 28)
        formMessageField.frame = NSRect(x: 0, y: bounds.height - 92, width: bounds.width, height: 30)
        toolScrollView.frame = NSRect(
            x: 0,
            y: 48,
            width: bounds.width,
            height: max(1, bounds.height - 146)
        )
        let footerWidth = min(bounds.width, 328)
        let footerX = max(0, bounds.width - footerWidth)
        let footerFrames = [
            NSRect(x: footerX, y: 4, width: 96, height: 32),
            NSRect(x: footerX + 104, y: 4, width: 82, height: 32),
            NSRect(x: footerX + 194, y: 4, width: 126, height: 32),
        ]
        for (index, button) in toolFooterButtons.enumerated() {
            button.frame = footerFrames[min(index, footerFrames.count - 1)]
        }

        let documentWidth = max(1, bounds.width - 18)
        let documentHeight = max(
            toolScrollView.bounds.height,
            220 + CGFloat(toolSuggestionButtons.count) * 38
        )
        toolDocumentView.frame = NSRect(
            x: 0,
            y: 0,
            width: documentWidth,
            height: documentHeight
        )
        toolCommandCard.frame = NSRect(
            x: 0,
            y: documentHeight - 78,
            width: documentWidth,
            height: 72
        )
        toolCommandOverline.frame = NSRect(x: 18, y: documentHeight - 30, width: 120, height: 14)
        toolCommandField.frame = NSRect(x: 18, y: documentHeight - 58, width: documentWidth - 126, height: 24)
        toolCommandKindField.frame = NSRect(x: documentWidth - 94, y: documentHeight - 56, width: 74, height: 18)
        toolRiskCard.frame = NSRect(
            x: 0,
            y: documentHeight - 156,
            width: min(documentWidth, 360),
            height: 64
        )
        toolRiskTitleField.frame = NSRect(x: 18, y: documentHeight - 112, width: 90, height: 16)
        toolRiskBodyField.frame = NSRect(x: 18, y: documentHeight - 145, width: min(documentWidth, 360) - 34, height: 32)
        var y = documentHeight - 194
        let suggestionWidth = min(documentWidth, 440)
        if toolSuggestionButtons.isEmpty {
            toolSuggestionCard.isHidden = true
            toolPermissionTitleField.isHidden = true
            toolPermissionBodyField.isHidden = true
        } else {
            toolSuggestionCard.isHidden = false
            toolPermissionTitleField.isHidden = false
            toolPermissionBodyField.isHidden = false
            toolSuggestionCard.frame = NSRect(
                x: 0,
                y: y - CGFloat(toolSuggestionButtons.count) * 38 - 50,
                width: suggestionWidth,
                height: CGFloat(toolSuggestionButtons.count) * 38 + 58
            )
            toolPermissionTitleField.frame = NSRect(x: 18, y: y - 20, width: suggestionWidth - 36, height: 16)
            toolPermissionBodyField.frame = NSRect(x: 18, y: y - 44, width: suggestionWidth - 36, height: 22)
        }
        y -= 82
        for button in toolSuggestionButtons {
            button.frame = NSRect(
                x: 16,
                y: y,
                width: suggestionWidth - 32,
                height: 30
            )
            y -= 36
        }
    }

    private func layoutQuestionContent(_ bounds: NSRect) {
        overlineField.frame = NSRect(x: 0, y: bounds.height - 24, width: bounds.width, height: 14)
        formTitleField.frame = NSRect(
            x: 0,
            y: bounds.height - 56,
            width: bounds.width,
            height: 28
        )
        formMessageField.frame = NSRect(
            x: 0,
            y: bounds.height - 86,
            width: bounds.width,
            height: 24
        )

        let hasMultipleQuestions = questionViews.count > 1
        let sidebarWidth: CGFloat = hasMultipleQuestions ? 172 : 0
        let questionWidth: CGFloat = hasMultipleQuestions
            ? max(220, bounds.width - sidebarWidth - 14)
            : bounds.width

        for (index, questionView) in questionViews.enumerated() {
            questionView.isHidden = index != currentQuestionIndex
            questionView.frame = NSRect(
                x: 0,
                y: 48,
                width: questionWidth,
                height: max(1, bounds.height - 142)
            )
        }

        questionProgressView.isHidden = !hasMultipleQuestions
        if hasMultipleQuestions {
            questionProgressView.frame = NSRect(
                x: questionWidth + 14,
                y: 48,
                width: max(1, bounds.width - questionWidth - 14),
                height: max(1, bounds.height - 142)
            )
        }
        updateQuestionProgress()

        let buttons = contentContainer.subviews.compactMap { $0 as? NSButton }
        let titles = buttons.reduce(into: [String: NSButton]()) { $0[$1.title] = $1 }

        if hasMultipleQuestions {
            titles["上一题"]?.isHidden = false
            titles["下一题"]?.isHidden = false
            questionPageField.isHidden = false
            titles["上一题"]?.frame = NSRect(x: 0, y: 6, width: 74, height: 32)
            titles["下一题"]?.frame = NSRect(x: 82, y: 6, width: 74, height: 32)
            questionPageField.frame = NSRect(x: 164, y: 12, width: 90, height: 20)
            questionPageField.stringValue =
                "问题 \(min(currentQuestionIndex + 1, questionViews.count)) / \(questionViews.count)"
            titles["上一题"]?.isEnabled = currentQuestionIndex > 0 && !didEmitDecision
            titles["下一题"]?.isEnabled = currentQuestionIndex + 1 < questionViews.count
                && !didEmitDecision
        } else {
            titles["上一题"]?.isHidden = true
            titles["下一题"]?.isHidden = true
            questionPageField.isHidden = true
        }

        titles["回到终端"]?.frame = NSRect(x: bounds.width - 236, y: 6, width: 96, height: 32)
        titles["提交回答"]?.frame = NSRect(x: bounds.width - 130, y: 6, width: 130, height: 32)
    }

    private func layoutPlanContent(_ bounds: NSRect) {
        overlineField.frame = NSRect(x: 0, y: bounds.height - 24, width: bounds.width, height: 14)
        formTitleField.frame = NSRect(x: 0, y: bounds.height - 58, width: bounds.width, height: 28)
        formMessageField.frame = NSRect(
            x: 0,
            y: bounds.height - 92,
            width: bounds.width,
            height: 30
        )
        planScrollView?.frame = NSRect(
            x: 0,
            y: 224,
            width: bounds.width,
            height: max(96, bounds.height - 332)
        )
        planImpactCard.frame = NSRect(
            x: 0,
            y: 164,
            width: bounds.width,
            height: 50
        )
        planImpactTitleField.frame = NSRect(
            x: 14,
            y: 27,
            width: 76,
            height: 15
        )
        planImpactBodyField.frame = NSRect(
            x: 92,
            y: 8,
            width: max(1, bounds.width - 106),
            height: 34
        )
        planFeedbackHintField?.frame = NSRect(
            x: 0,
            y: 136,
            width: bounds.width,
            height: 20
        )
        planFeedbackScrollView?.frame = NSRect(
            x: 0,
            y: 48,
            width: bounds.width,
            height: 80
        )
        let buttons = contentContainer.subviews.compactMap { $0 as? NSButton }
        let widths: [CGFloat] = [96, 126, 126]
        var x = max(0, bounds.width - widths.reduce(0, +) - 16)
        for (index, button) in buttons.enumerated() {
            let width = widths[min(index, widths.count - 1)]
            button.frame = NSRect(x: x, y: 4, width: width, height: 30)
            x += width + 8
        }
    }

    private func moveQuestionPage(delta: Int) {
        saveCurrentQuestionDraft()
        currentQuestionIndex = max(
            0,
            min(questionViews.count - 1, currentQuestionIndex + delta)
        )
        validationField.stringValue = ""
        layoutQuestionContent(contentContainer.bounds)
    }

    private func submitAnswers() {
        saveCurrentQuestionDraft()
        guard let prompt = presentation?.prompt else { return }
        var answers: [String: Any] = [:]
        for (index, question) in prompt.questions.enumerated() {
            let draft = questionDrafts.indices.contains(index)
                ? questionDrafts[index]
                : DynamicIslandQuestionAnswerDraft()
            guard let answer = dynamicIslandAnswerValue(
                question: question,
                draft: draft
            ) else {
                currentQuestionIndex = index
                validationField.stringValue =
                    "请先回答第 \(index + 1) 题，或选择“回到终端”。"
                layoutQuestionContent(contentContainer.bounds)
                return
            }
            answers[question.answerKey] = answer
        }
        emit(.submitAnswers(answers))
    }

    private func saveCurrentQuestionDraft() {
        guard questionDrafts.indices.contains(currentQuestionIndex),
              questionViews.indices.contains(currentQuestionIndex)
        else { return }
        questionDrafts[currentQuestionIndex] =
            questionViews[currentQuestionIndex].currentDraft()
        updateQuestionProgress()
    }

    private func updateQuestionProgress() {
        guard let questions = presentation?.prompt.questions else { return }
        questionProgressView.apply(
            questions: questions,
            drafts: questionDrafts,
            currentIndex: currentQuestionIndex
        )
    }

    private func sendPlanFeedback() {
        let feedback = planFeedbackView?.string.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        guard !feedback.isEmpty else {
            validationField.stringValue = "请先填写希望 Claude 修改的内容。"
            return
        }
        emit(.planFeedback(feedback))
    }

    private func emit(_ decision: ClaudePermissionUserDecision) {
        guard !didEmitDecision else { return }
        didEmitDecision = true
        decisionControls.forEach { $0.isEnabled = false }
        if let onDecision {
            onDecision(decision)
        } else {
            presentation?.onDecision(decision)
        }
    }

    private func emitAndReturnToTerminal() {
        guard !didEmitDecision else { return }
        didEmitDecision = true
        decisionControls.forEach { $0.isEnabled = false }
        onReturnToTerminal?()
        if let onDecision {
            onDecision(.nativeFallback)
        } else {
            presentation?.onDecision(.nativeFallback)
        }
    }

    private func kindTitle(_ kind: ClaudePermissionInteractionKind) -> String {
        switch kind {
        case .toolApproval: return "工具授权"
        case .askUserQuestion: return "问题回答"
        case .exitPlanMode: return "计划审批"
        }
    }

    private func kindIcon(_ kind: ClaudePermissionInteractionKind) -> String {
        switch kind {
        case .toolApproval: return "⌘"
        case .askUserQuestion: return "?"
        case .exitPlanMode: return "≡"
        }
    }

    private func promptContextTitle(_ prompt: ClaudePermissionPrompt) -> String {
        switch prompt.interactionKind {
        case .toolApproval:
            return "工具授权 · \(prompt.toolName)"
        case .askUserQuestion:
            return prompt.title
        case .exitPlanMode:
            return "计划审批"
        }
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func compactQueueAgeText(_ date: Date) -> String {
        let elapsed = max(0, dynamicIslandCurrentDate().timeIntervalSince(date))
        if elapsed < 60 { return "刚刚" }
        if elapsed < 3_600 { return "\(max(1, Int(elapsed / 60))) 分" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func boundedRawSummary(from input: [String: Any]) -> String {
        for key in ["command", "file_path", "path", "url", "query", "description"] {
            guard let value = input[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let oneLine = trimmed.replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            let summary = "\(key): \(oneLine)"
            guard summary.count > 90 else { return summary }
            let cutoff = summary.index(summary.startIndex, offsetBy: 89)
            return String(summary[..<cutoff]) + "…"
        }
        return ""
    }

    private func riskSummary(for prompt: ClaudePermissionPrompt) -> String {
        switch prompt.interactionKind {
        case .toolApproval:
            if prompt.toolName.localizedCaseInsensitiveContains("bash") {
                return "命令会在当前项目上下文执行；确认命令、目录和参数后再允许。"
            }
            if prompt.toolName.localizedCaseInsensitiveContains("write")
                || prompt.toolName.localizedCaseInsensitiveContains("edit")
            {
                return "该工具可能修改文件；建议确认路径和修改范围。"
            }
            if prompt.toolName.localizedCaseInsensitiveContains("read") {
                return "读取操作通常低风险；仍需确认路径属于本项目。"
            }
            return "请确认工具名称、目标路径和本次操作意图匹配。"
        case .askUserQuestion:
            return "回答会直接进入 Claude 当前会话，避免输入敏感凭据。"
        case .exitPlanMode:
            return "批准后 Claude 会按计划继续执行；先确认步骤和验证覆盖。"
        }
    }

    private func permissionSummary(for prompt: ClaudePermissionPrompt) -> String {
        if prompt.suggestions.isEmpty {
            return "本次没有可保存的长期授权建议。"
        }
        return "可只允许一次；只有在范围明确且会重复使用时，再选择长期授权。"
    }

    private func actionButton(
        title: String,
        keyEquivalent: String = "",
        action: @escaping () -> Void
    ) -> NSButton {
        let button = DynamicIslandActionButton(title: title, handler: action)
        let isPrimary = title == "允许一次"
            || title == "批准并继续"
            || title == "提交回答"
        button.setVisualStyle(isPrimary ? .primary : .secondary)
        button.font = .systemFont(ofSize: 13)
        button.keyEquivalent = keyEquivalent
        button.setAccessibilityLabel(title)
        return button
    }

    func setQuestionDraftForSelfTest(
        index: Int,
        draft: DynamicIslandQuestionAnswerDraft
    ) {
        guard questionDrafts.indices.contains(index),
              questionViews.indices.contains(index)
        else { return }
        questionDrafts[index] = draft
        questionViews[index].draft = draft
        updateQuestionProgress()
    }

    func updateQueueForSelfTest(_ snapshot: ClaudePermissionQueueSnapshot) {
        updateQueue(snapshot)
    }

    func buttonForSelfTest(title: String) -> NSButton? {
        _ = view
        view.layoutSubtreeIfNeeded()
        return descendantButtons(in: view).first { $0.title == title }
    }

    func keyEquivalentForButtonForSelfTest(title: String) -> String? {
        buttonForSelfTest(title: title)?.keyEquivalent
    }

    func clickQuestionOptionForSelfTest(index: Int, optionIndex: Int) {
        guard questionViews.indices.contains(index),
              let button = questionViews[index].optionButtonForSelfTest(
                  index: optionIndex
              )
        else { return }
        button.performClick(nil)
        questionDrafts[index] = questionViews[index].currentDraft()
    }

    func setQuestionTextForSelfTest(index: Int, text: String) {
        guard questionViews.indices.contains(index) else { return }
        questionViews[index].setCustomTextForSelfTest(text)
        questionDrafts[index] = questionViews[index].currentDraft()
        updateQuestionProgress()
    }

    func setCurrentQuestionIndexForSelfTest(_ index: Int) {
        saveCurrentQuestionDraft()
        currentQuestionIndex = max(0, min(index, questionViews.count - 1))
        layoutQuestionContent(contentContainer.bounds)
    }

    func questionDraftForSelfTest(
        index: Int
    ) -> DynamicIslandQuestionAnswerDraft {
        guard questionViews.indices.contains(index) else {
            return DynamicIslandQuestionAnswerDraft()
        }
        return questionViews[index].currentDraft()
    }

    func queueRowCountForSelfTest() -> Int {
        queueRows.count
    }

    func queueTitlesForSelfTest() -> [String] {
        queueRows.map(\.item.title)
    }

    func selectedQueueRowForSelfTest() -> Int {
        queueTableView.selectedRow
    }

    func queueShouldSelectRowForSelfTest(_ row: Int) -> Bool {
        tableView(queueTableView, shouldSelectRow: row)
    }

    func queueRowIsCurrentForSelfTest(_ row: Int) -> Bool {
        guard queueRows.indices.contains(row) else { return false }
        return queueRows[row].isCurrent
    }

    func historyRowSummariesForSelfTest() -> [String] {
        _ = view
        return historyRecords.map {
            "\(agentPresentation(for: $0.agentID).displayName) "
                + "\($0.requestKind.displayTitle) \($0.outcome.displayTitle) "
                + "\($0.durationSeconds)"
        }
    }

    func historyEmptyStateIsVisibleForSelfTest() -> Bool {
        _ = view
        return !historyEmptyField.isHidden && historyScrollView.isHidden
    }

    func toolSuggestionButtonFramesForSelfTest() -> [NSRect] {
        _ = view
        view.layoutSubtreeIfNeeded()
        return toolSuggestionButtons.map(\.frame)
    }

    func submitAnswersForSelfTest() {
        submitAnswers()
    }

    func allowOnceForSelfTest() {
        emit(.allowOnce)
    }

    func denyForSelfTest() {
        emit(.deny("用户在 ThreadHelm 中拒绝了这次操作"))
    }

    func sendPlanFeedbackForSelfTest() {
        sendPlanFeedback()
    }

    func setPlanFeedbackForSelfTest(_ text: String) {
        planFeedbackView?.string = text
    }

    func currentQuestionIndexForSelfTest() -> Int {
        currentQuestionIndex
    }

    func questionProgressTextForSelfTest() -> String {
        _ = view
        return questionProgressView.accessibilityValue() as? String ?? ""
    }

    func planImpactTextForSelfTest() -> String {
        planImpactBodyField.stringValue
    }

    func validationTextForSelfTest() -> String {
        validationField.stringValue
    }

    func decisionControlsEnabledForSelfTest() -> Bool {
        decisionControls.contains { $0.isEnabled }
    }

    func rawSummaryForSelfTest() -> String {
        rawSummary
    }

    private func descendantButtons(in view: NSView) -> [NSButton] {
        let current = (view as? NSButton).map { [$0] } ?? []
        return current + view.subviews.flatMap(descendantButtons)
    }
}

private final class DynamicIslandQueueRowView: NSView {
    override var isFlipped: Bool { true }

    init(index: Int, item: ClaudePermissionQueueItem, isCurrent: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1

        let backgroundColor: NSColor
        let borderColor: NSColor
        if isCurrent {
            backgroundColor = DynamicIslandPalette.amber.withAlphaComponent(0.12)
            borderColor = DynamicIslandPalette.amber.withAlphaComponent(0.48)
        } else {
            backgroundColor = DynamicIslandPalette.card
            borderColor = DynamicIslandPalette.hairline
        }
        layer?.backgroundColor = backgroundColor.cgColor
        layer?.borderColor = borderColor.cgColor

        if isCurrent {
            let accent = NSView(frame: NSRect(x: 0, y: 7, width: 3, height: 46))
            accent.wantsLayer = true
            accent.layer?.cornerRadius = 1.5
            accent.layer?.backgroundColor = DynamicIslandPalette.amber.cgColor
            accent.setAccessibilityElement(false)
            addSubview(accent)
        }

        let iconBadge = NSView(frame: NSRect(x: 10, y: 16, width: 28, height: 28))
        iconBadge.wantsLayer = true
        iconBadge.layer?.cornerRadius = 14
        iconBadge.layer?.backgroundColor = (isCurrent
            ? DynamicIslandPalette.amber.withAlphaComponent(0.20)
            : NSColor.white.withAlphaComponent(0.06)).cgColor
        iconBadge.setAccessibilityElement(false)

        let iconLabel = confirmationLabel(size: 13, weight: .bold)
        iconLabel.stringValue = kindIcon(item.interactionKind)
        iconLabel.textColor = isCurrent ? DynamicIslandPalette.amber : DynamicIslandPalette.secondaryText
        iconLabel.alignment = .center
        iconLabel.frame = NSRect(x: 0, y: 4, width: 28, height: 20)
        iconLabel.setAccessibilityElement(false)
        iconBadge.addSubview(iconLabel)
        addSubview(iconBadge)

        let title = confirmationLabel(size: 12.5, weight: .semibold)
        title.stringValue = item.title
        title.textColor = DynamicIslandPalette.primaryText
        title.frame = NSRect(x: 46, y: 11, width: 110, height: 18)
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)

        let detail = confirmationLabel(size: 11, weight: .regular)
        let agentCode = agentPresentation(for: item.agentID).shortName.uppercased()
        detail.stringValue = "\(kindTitle(item.interactionKind)) · \(agentCode)"
        detail.textColor = DynamicIslandPalette.secondaryText
        detail.frame = NSRect(x: 46, y: 32, width: 156, height: 16)
        addSubview(detail)

        let time = confirmationLabel(size: 10.5, weight: .medium)
        time.stringValue = compactQueueAgeText(item.arrivedAt)
        time.alignment = .right
        time.textColor = isCurrent ? DynamicIslandPalette.amber : DynamicIslandPalette.tertiaryText
        time.frame = NSRect(x: 156, y: 11, width: 44, height: 16)
        addSubview(time)

        setAccessibilityLabel("\(index) \(item.title)")
        setAccessibilityValue("\(detail.stringValue)，\(time.stringValue)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func kindTitle(_ kind: ClaudePermissionInteractionKind) -> String {
        switch kind {
        case .toolApproval: return "工具授权"
        case .askUserQuestion: return "问题回答"
        case .exitPlanMode: return "计划审批"
        }
    }

    private func kindIcon(_ kind: ClaudePermissionInteractionKind) -> String {
        switch kind {
        case .toolApproval: return "⌘"
        case .askUserQuestion: return "?"
        case .exitPlanMode: return "≡"
        }
    }

    private func compactQueueAgeText(_ date: Date) -> String {
        let elapsed = max(0, dynamicIslandCurrentDate().timeIntervalSince(date))
        if elapsed < 60 { return "刚刚" }
        if elapsed < 3_600 { return "\(max(1, Int(elapsed / 60))) 分" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

private final class DynamicIslandQuestionProgressView: NSView {
    private let titleField = confirmationLabel(size: 12, weight: .semibold)
    private let summaryField = confirmationLabel(size: 11, weight: .medium)
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = DynamicIslandPalette.surface.cgColor
        layer?.borderColor = DynamicIslandPalette.hairline.cgColor
        layer?.borderWidth = 1
        titleField.stringValue = "回答进度"
        titleField.textColor = DynamicIslandPalette.primaryText
        summaryField.textColor = DynamicIslandPalette.secondaryText
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        addSubview(titleField)
        addSubview(summaryField)
        addSubview(stack)
        setAccessibilityRole(.group)
        setAccessibilityLabel("问题回答进度")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        titleField.frame = NSRect(
            x: 12,
            y: bounds.height - 30,
            width: max(1, bounds.width - 24),
            height: 18
        )
        summaryField.frame = NSRect(
            x: 12,
            y: 12,
            width: max(1, bounds.width - 24),
            height: 16
        )
        stack.frame = NSRect(
            x: 8,
            y: 36,
            width: max(1, bounds.width - 16),
            height: max(1, bounds.height - 74)
        )
    }

    func apply(
        questions: [ClaudeQuestion],
        drafts: [DynamicIslandQuestionAnswerDraft],
        currentIndex: Int
    ) {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        var answeredCount = 0
        for (index, question) in questions.enumerated() {
            let draft = drafts.indices.contains(index)
                ? drafts[index]
                : DynamicIslandQuestionAnswerDraft()
            let answered = dynamicIslandAnswerValue(
                question: question,
                draft: draft
            ) != nil
            if answered { answeredCount += 1 }
            let row = DynamicIslandQuestionProgressRowView(
                index: index + 1,
                title: question.header ?? question.answerKey,
                isCurrent: index == currentIndex,
                isAnswered: answered
            )
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: 44).isActive = true
        }
        summaryField.stringValue = "已回答 \(answeredCount) / \(questions.count)"
        setAccessibilityValue(
            "当前第 \(min(currentIndex + 1, max(questions.count, 1))) 题，"
                + summaryField.stringValue
        )
        needsLayout = true
    }
}

private final class DynamicIslandQuestionProgressRowView: NSView {
    override var isFlipped: Bool { true }

    private let stepBadge = NSView()
    private let stepNumber = confirmationLabel(size: 10.5, weight: .bold)
    private let titleField = confirmationLabel(size: 11.5, weight: .medium)
    private let stateField = confirmationLabel(size: 10, weight: .medium)

    init(index: Int, title: String, isCurrent: Bool, isAnswered: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = (
            isCurrent
                ? DynamicIslandPalette.amber.withAlphaComponent(0.10)
                : DynamicIslandPalette.card.withAlphaComponent(0.60)
        ).cgColor
        layer?.borderColor = (
            isCurrent
                ? DynamicIslandPalette.amber.withAlphaComponent(0.50)
                : DynamicIslandPalette.hairline
        ).cgColor
        layer?.borderWidth = 1

        stepBadge.wantsLayer = true
        stepBadge.layer?.cornerRadius = 9
        if isAnswered {
            stepBadge.layer?.backgroundColor = DynamicIslandPalette.green.cgColor
            stepNumber.stringValue = "✓"
            stepNumber.textColor = NSColor(calibratedWhite: 0.1, alpha: 1)
        } else if isCurrent {
            stepBadge.layer?.backgroundColor = DynamicIslandPalette.amber.withAlphaComponent(0.25).cgColor
            stepBadge.layer?.borderColor = DynamicIslandPalette.amber.cgColor
            stepBadge.layer?.borderWidth = 1
            stepNumber.stringValue = "\(index)"
            stepNumber.textColor = DynamicIslandPalette.amber
        } else {
            stepBadge.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            stepNumber.stringValue = "\(index)"
            stepNumber.textColor = DynamicIslandPalette.secondaryText
        }
        stepNumber.alignment = .center
        stepNumber.setAccessibilityElement(false)
        stepBadge.addSubview(stepNumber)
        addSubview(stepBadge)

        titleField.stringValue = title
        titleField.lineBreakMode = .byTruncatingTail
        titleField.textColor = isCurrent ? DynamicIslandPalette.primaryText : DynamicIslandPalette.secondaryText
        addSubview(titleField)

        stateField.stringValue = isAnswered
            ? "已完成"
            : (isCurrent ? "当前" : "待回答")
        stateField.textColor = isAnswered
            ? DynamicIslandPalette.green
            : (isCurrent ? DynamicIslandPalette.amber : DynamicIslandPalette.tertiaryText)
        addSubview(stateField)

        setAccessibilityLabel("问题 \(index) \(title)")
        setAccessibilityValue(stateField.stringValue)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        stepBadge.frame = NSRect(x: 8, y: 13, width: 18, height: 18)
        stepNumber.frame = NSRect(x: 0, y: 1, width: 18, height: 16)
        titleField.frame = NSRect(
            x: 32,
            y: 7,
            width: max(1, bounds.width - 40),
            height: 16
        )
        stateField.frame = NSRect(
            x: 32,
            y: 24,
            width: max(1, bounds.width - 40),
            height: 14
        )
    }
}

final class DynamicIslandQuestionInputView: NSView {
    var onDraftChange: ((DynamicIslandQuestionAnswerDraft) -> Void)?
    var draft = DynamicIslandQuestionAnswerDraft() {
        didSet { applyDraftToControls() }
    }

    private let question: ClaudeQuestion
    private let scrollView = NSScrollView()
    private let documentView = NSView()
    private let headerBadge = NSTextField(labelWithString: "")
    private let headerField = wrappingLabel(size: 15, weight: .semibold)
    private let inputContainer = NSView()
    private let textField = NSTextField()
    private let footnoteField = confirmationLabel(size: 11.5, weight: .regular)
    private var optionButtons: [NSButton] = []

    var initialInputResponder: NSResponder { textField }

    init(question: ClaudeQuestion) {
        self.question = question
        super.init(frame: .zero)
        addSubview(scrollView)
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let selectionText = question.allowsMultipleSelection ? "多选题" : "单选题"
        headerBadge.stringValue = selectionText
        headerBadge.font = .systemFont(ofSize: 11, weight: .semibold)
        headerBadge.textColor = DynamicIslandPalette.amber
        headerBadge.alignment = .center
        headerBadge.wantsLayer = true
        headerBadge.layer?.cornerRadius = 4
        headerBadge.layer?.backgroundColor = DynamicIslandPalette.amber.withAlphaComponent(0.14).cgColor
        headerBadge.setAccessibilityElement(false)
        documentView.addSubview(headerBadge)

        headerField.stringValue = question.header ?? question.answerKey
        headerField.font = .systemFont(ofSize: 15, weight: .semibold)
        headerField.textColor = DynamicIslandPalette.primaryText
        headerField.setAccessibilityLabel("问题")
        documentView.addSubview(headerField)

        optionButtons = question.options.enumerated().map { index, option in
            let button = DynamicIslandQuestionOptionButton(
                label: option.label,
                detail: option.detail,
                allowsMultipleSelection: question.allowsMultipleSelection
            )
            button.tag = index
            button.target = self
            button.action = #selector(optionChanged)
            button.setAccessibilityLabel(option.label)
            button.setAccessibilityValue(option.detail ?? "")
            documentView.addSubview(button)
            return button
        }

        let placeholder = question.options.isEmpty ? "输入回答..." : "输入自定义回答 (覆盖上方选项)..."
        inputContainer.wantsLayer = true
        inputContainer.layer?.cornerRadius = 8
        inputContainer.layer?.borderWidth = 1
        inputContainer.layer?.borderColor = DynamicIslandPalette.hairline.cgColor
        inputContainer.layer?.backgroundColor = DynamicIslandPalette.card.cgColor
        documentView.addSubview(inputContainer)

        textField.placeholderString = placeholder
        textField.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: DynamicIslandPalette.tertiaryText,
                .font: NSFont.systemFont(ofSize: 12.5, weight: .regular),
            ]
        )
        textField.font = .systemFont(ofSize: 12.5)
        textField.textColor = DynamicIslandPalette.primaryText
        textField.drawsBackground = false
        textField.isBezeled = false
        textField.focusRingType = .none
        textField.setAccessibilityLabel("自定义回答")
        textField.target = self
        textField.action = #selector(customTextChanged)
        inputContainer.addSubview(textField)

        footnoteField.stringValue = question.options.isEmpty
            ? "💡 自由输入 · 切换题目会自动保存回答。"
            : "💡 \(question.allowsMultipleSelection ? "多选" : "单选") · 自定义回答会覆盖选项；切换题目会自动保存回答。"
        footnoteField.textColor = DynamicIslandPalette.secondaryText
        footnoteField.setAccessibilityLabel("回答规则，\(footnoteField.stringValue)")
        documentView.addSubview(footnoteField)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let width = max(1, bounds.width - 16)

        var optionHeights: [CGFloat] = []
        for button in optionButtons {
            let h = (button as? DynamicIslandQuestionOptionButton)?.calculatedHeight(forWidth: width) ?? 50
            optionHeights.append(h)
        }
        let totalOptionsHeight = optionHeights.reduce(0, +) + CGFloat(max(0, optionButtons.count - 1) * 8)

        let headerHeight: CGFloat = 28
        let inputHeight: CGFloat = 36
        let footnoteHeight: CGFloat = 18
        let spacing: CGFloat = 10

        let contentHeight = headerHeight
            + (optionButtons.isEmpty ? 0 : (totalOptionsHeight + spacing))
            + inputHeight + spacing + footnoteHeight + 20
        let documentHeight = max(bounds.height, contentHeight)
        documentView.frame = NSRect(
            x: 0,
            y: 0,
            width: width,
            height: documentHeight
        )

        var y = documentHeight - headerHeight
        headerBadge.frame = NSRect(x: 0, y: y + 2, width: 48, height: 22)
        headerField.frame = NSRect(x: 54, y: y, width: max(1, width - 54), height: 26)

        if !optionButtons.isEmpty {
            y -= (spacing + 2)
            for (index, button) in optionButtons.enumerated() {
                let btnHeight = optionHeights[index]
                y -= btnHeight
                button.frame = NSRect(x: 0, y: max(0, y), width: width, height: btnHeight)
                y -= 8
            }
            y += 8
        }

        y -= (spacing + 4)
        inputContainer.frame = NSRect(x: 0, y: max(0, y - inputHeight), width: width, height: inputHeight)
        textField.frame = NSRect(x: 12, y: (inputHeight - 20) / 2, width: max(1, width - 24), height: 20)
        y -= inputHeight

        y -= (spacing - 2)
        footnoteField.frame = NSRect(x: 2, y: max(0, y - footnoteHeight), width: width - 4, height: footnoteHeight)
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        applyDraftToControls()
    }

    @objc private func optionChanged(_ sender: NSButton) {
        if question.allowsMultipleSelection {
            if sender.state == .on {
                draft.selectedOptionIndexes.insert(sender.tag)
            } else {
                draft.selectedOptionIndexes.remove(sender.tag)
            }
            (sender as? DynamicIslandQuestionOptionButton)?.setSelected(sender.state == .on)
        } else {
            draft.selectedOptionIndexes = sender.state == .on ? [sender.tag] : []
            clearOtherOptionButtons(selectedTag: sender.tag)
            (sender as? DynamicIslandQuestionOptionButton)?.setSelected(sender.state == .on)
        }
        onDraftChange?(currentDraft())
    }

    @objc private func customTextChanged() {
        draft.customText = textField.stringValue
        onDraftChange?(currentDraft())
    }

    func currentDraft() -> DynamicIslandQuestionAnswerDraft {
        var current = draft
        current.customText = textField.stringValue
        return current
    }

    private func applyDraftToControls() {
        for button in optionButtons {
            let isSelected = draft.selectedOptionIndexes.contains(button.tag)
            button.state = isSelected ? .on : .off
            (button as? DynamicIslandQuestionOptionButton)?.setSelected(isSelected)
        }
        textField.stringValue = draft.customText
    }

    private func clearOtherOptionButtons(selectedTag: Int) {
        for button in optionButtons where button.tag != selectedTag {
            button.state = .off
            (button as? DynamicIslandQuestionOptionButton)?.setSelected(false)
        }
    }

    func optionButtonForSelfTest(index: Int) -> NSButton? {
        guard optionButtons.indices.contains(index) else { return nil }
        return optionButtons[index]
    }

    func setCustomTextForSelfTest(_ text: String) {
        textField.stringValue = text
        draft.customText = text
        onDraftChange?(currentDraft())
    }
}

final class DynamicIslandQuestionOptionButton: NSButton {
    override var isFlipped: Bool { true }

    private let optionLabel: String
    private let optionDetail: String?
    private let allowsMultipleSelection: Bool
    private var isHovered = false

    private let indicatorView = NSView()
    private let indicatorDot = NSView()
    private let indicatorCheck = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    init(
        label: String,
        detail: String?,
        allowsMultipleSelection: Bool
    ) {
        self.optionLabel = label
        self.optionDetail = detail
        self.allowsMultipleSelection = allowsMultipleSelection
        super.init(frame: .zero)
        self.title = ""
        self.attributedTitle = NSAttributedString(string: "")
        isBordered = false
        focusRingType = .none
        setButtonType(.toggle)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1

        setupSubviews()
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupSubviews() {
        indicatorView.wantsLayer = true
        indicatorView.layer?.borderWidth = 1.5
        indicatorView.layer?.cornerRadius = allowsMultipleSelection ? 4 : 9
        indicatorView.setAccessibilityElement(false)
        addSubview(indicatorView)

        if allowsMultipleSelection {
            indicatorCheck.font = .systemFont(ofSize: 11, weight: .bold)
            indicatorCheck.alignment = .center
            indicatorCheck.textColor = NSColor(calibratedWhite: 0.1, alpha: 1)
            indicatorCheck.stringValue = "✓"
            indicatorCheck.setAccessibilityElement(false)
            indicatorView.addSubview(indicatorCheck)
        } else {
            indicatorDot.wantsLayer = true
            indicatorDot.layer?.cornerRadius = 3
            indicatorDot.layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 1).cgColor
            indicatorDot.setAccessibilityElement(false)
            indicatorView.addSubview(indicatorDot)
        }

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = DynamicIslandPalette.primaryText
        titleLabel.stringValue = optionLabel
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityElement(false)
        addSubview(titleLabel)

        if let optionDetail, !optionDetail.isEmpty {
            detailLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
            detailLabel.textColor = DynamicIslandPalette.secondaryText
            detailLabel.stringValue = optionDetail
            detailLabel.lineBreakMode = .byWordWrapping
            detailLabel.maximumNumberOfLines = 2
            detailLabel.setAccessibilityElement(false)
            addSubview(detailLabel)
        }
    }

    override var state: NSControl.StateValue {
        didSet { updateAppearance() }
    }

    func setSelected(_ selected: Bool) {
        state = selected ? .on : .off
        updateAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        updateAppearance()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func layout() {
        super.layout()
        let hasDetail = optionDetail != nil && !(optionDetail!.isEmpty)
        let indicatorSize: CGFloat = 18
        let indicatorX: CGFloat = 14

        if hasDetail {
            indicatorView.frame = NSRect(x: indicatorX, y: 13, width: indicatorSize, height: indicatorSize)
            titleLabel.frame = NSRect(
                x: 42,
                y: 10,
                width: max(1, bounds.width - 54),
                height: 18
            )
            detailLabel.frame = NSRect(
                x: 42,
                y: 30,
                width: max(1, bounds.width - 54),
                height: max(14, bounds.height - 38)
            )
        } else {
            let midY = (bounds.height - indicatorSize) / 2
            indicatorView.frame = NSRect(x: indicatorX, y: midY, width: indicatorSize, height: indicatorSize)
            titleLabel.frame = NSRect(
                x: 42,
                y: (bounds.height - 18) / 2,
                width: max(1, bounds.width - 54),
                height: 18
            )
        }

        if allowsMultipleSelection {
            indicatorCheck.frame = NSRect(x: 0, y: 1, width: indicatorSize, height: indicatorSize - 2)
        } else {
            indicatorDot.frame = NSRect(x: 6, y: 6, width: 6, height: 6)
        }
    }

    func calculatedHeight(forWidth width: CGFloat) -> CGFloat {
        guard let optionDetail, !optionDetail.isEmpty else {
            return 42
        }
        if optionDetail.count > 35 {
            return 58
        }
        return 50
    }

    private func updateAppearance() {
        let selected = state == .on
        let backgroundColor: NSColor
        let borderColor: NSColor

        if selected {
            backgroundColor = DynamicIslandPalette.amber.withAlphaComponent(0.12)
            borderColor = DynamicIslandPalette.amber.withAlphaComponent(0.65)
        } else if isHovered {
            backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 0.90)
            borderColor = NSColor.white.withAlphaComponent(0.22)
        } else {
            backgroundColor = DynamicIslandPalette.card
            borderColor = DynamicIslandPalette.hairline
        }

        layer?.backgroundColor = backgroundColor.cgColor
        layer?.borderColor = borderColor.cgColor

        if selected {
            indicatorView.layer?.backgroundColor = DynamicIslandPalette.amber.cgColor
            indicatorView.layer?.borderColor = DynamicIslandPalette.amber.cgColor
            indicatorDot.isHidden = false
            indicatorCheck.isHidden = false
        } else {
            indicatorView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
            indicatorView.layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
            indicatorDot.isHidden = true
            indicatorCheck.isHidden = true
        }

        titleLabel.textColor = DynamicIslandPalette.primaryText
        detailLabel.textColor = selected
            ? DynamicIslandPalette.primaryText.withAlphaComponent(0.75)
            : DynamicIslandPalette.secondaryText
    }
}

private final class DynamicIslandActionButton: NSButton {
    private let handler: () -> Void
    private var visualStyle: DynamicIslandButtonStyle = .secondary
    private var isHovered = false

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        target = self
        action = #selector(performAction)
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func performAction() {
        handler()
    }

    override var isEnabled: Bool {
        didSet { applyAppearance() }
    }

    func setVisualStyle(_ style: DynamicIslandButtonStyle) {
        visualStyle = style
        applyAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        applyAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        applyAppearance()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    private func applyAppearance() {
        let foreground: NSColor
        let background: NSColor
        let border: NSColor
        switch visualStyle {
        case .primary:
            foreground = NSColor(calibratedWhite: 0.08, alpha: 1)
            background = isHovered
                ? NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.16, alpha: 1)
                : DynamicIslandPalette.amber
            border = DynamicIslandPalette.amber
        case .destructive:
            foreground = DynamicIslandPalette.red
            background = isHovered
                ? DynamicIslandPalette.red.withAlphaComponent(0.18)
                : DynamicIslandPalette.red.withAlphaComponent(0.10)
            border = DynamicIslandPalette.red.withAlphaComponent(0.50)
        case .subtle:
            foreground = isHovered
                ? DynamicIslandPalette.primaryText
                : DynamicIslandPalette.tertiaryText
            background = isHovered
                ? NSColor.white.withAlphaComponent(0.06)
                : NSColor.white.withAlphaComponent(0.02)
            border = DynamicIslandPalette.hairline.withAlphaComponent(0.45)
        case .icon:
            foreground = DynamicIslandPalette.primaryText
            background = isHovered ? DynamicIslandPalette.card : DynamicIslandPalette.raised
            border = DynamicIslandPalette.strongHairline
        case .secondary:
            foreground = DynamicIslandPalette.primaryText
            background = isHovered
                ? NSColor(calibratedWhite: 0.22, alpha: 0.95)
                : NSColor(calibratedWhite: 0.16, alpha: 0.85)
            border = isHovered
                ? NSColor.white.withAlphaComponent(0.24)
                : NSColor.white.withAlphaComponent(0.12)
        case .bare:
            foreground = isHovered
                ? DynamicIslandPalette.primaryText
                : DynamicIslandPalette.secondaryText
            background = NSColor.clear
            border = NSColor.clear
        }
        let effectiveForeground = isEnabled
            ? foreground
            : foreground.withAlphaComponent(0.34)
        layer?.backgroundColor = background
            .withAlphaComponent(isEnabled ? background.alphaComponent : 0.45)
            .cgColor
        layer?.borderColor = border
            .withAlphaComponent(isEnabled ? border.alphaComponent : 0.35)
            .cgColor
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: effectiveForeground,
                .font: font ?? NSFont.systemFont(ofSize: 12.5, weight: .medium),
            ]
        )
    }
}

private extension NSButton {
    func setVisualStyleForConfirmation(_ style: DynamicIslandButtonStyle) {
        (self as? DynamicIslandActionButton)?.setVisualStyle(style)
    }
}

private func confirmationLabel(
    size: CGFloat,
    weight: NSFont.Weight
) -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = DynamicIslandPalette.primaryText
    label.lineBreakMode = .byTruncatingTail
    return label
}

private func wrappingLabel(
    size: CGFloat,
    weight: NSFont.Weight
) -> NSTextField {
    let label = confirmationLabel(size: size, weight: weight)
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 0
    return label
}
