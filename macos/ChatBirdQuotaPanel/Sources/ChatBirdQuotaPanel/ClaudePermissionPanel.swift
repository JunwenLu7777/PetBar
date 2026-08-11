//
//  ClaudePermissionPanel.swift
//  ChatBirdQuotaPanel
//
//  模块职责：Claude 权限面板展示器与提示页——面板定位与展示、
//  工具审批/问答/计划审查三种交互的视图构建、用户决策回调。
//  视觉组件见 ClaudePermissionViews.swift，问答表单见
//  ClaudePermissionQuestions.swift。
//

import AppKit

final class ClaudePermissionPanelPresenter: ClaudePermissionPresenting {
    private let anchorWindowProvider: () -> NSWindow?
    private var panel: ClaudePermissionPanel?
    private var promptController: ClaudePermissionPromptViewController?

    init(anchorWindowProvider: @escaping () -> NSWindow?) {
        self.anchorWindowProvider = anchorWindowProvider
    }

    func present(_ presentation: ClaudePermissionPresentation) {
        let controller = ClaudePermissionPromptViewController(
            prompt: presentation.prompt,
            queueCount: presentation.queue.count
        )
        controller.onDecision = presentation.onDecision
        promptController = controller
        let panel = makeOrReusePanel(size: controller.preferredPanelSize)
        panel.setContentSize(controller.preferredPanelSize)
        panel.contentViewController = controller
        reposition()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel?.contentViewController = nil
        promptController = nil
    }

    func reposition() {
        guard let panel, panel.isVisible else { return }
        let anchorFrame = anchorWindowProvider()?.frame
        let screen = anchorWindowProvider()?.screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }

        let proposedX: CGFloat
        let proposedY: CGFloat
        if let anchorFrame {
            proposedX = anchorFrame.midX - panel.frame.width / 2
            proposedY = anchorFrame.minY
        } else {
            proposedX = visibleFrame.maxX - panel.frame.width - 24
            proposedY = visibleFrame.maxY - panel.frame.height - 24
        }
        let origin = NSPoint(
            x: min(
                max(proposedX, visibleFrame.minX + 8),
                visibleFrame.maxX - panel.frame.width - 8
            ),
            y: min(
                max(proposedY, visibleFrame.minY + 8),
                visibleFrame.maxY - panel.frame.height - 8
            )
        )
        panel.setFrameOrigin(origin)
    }

    private func makeOrReusePanel(size: NSSize) -> ClaudePermissionPanel {
        if let panel { return panel }
        let created = ClaudePermissionPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = true
        created.level = NSWindow.Level(
            rawValue: NSWindow.Level.statusBar.rawValue + 2
        )
        created.hidesOnDeactivate = false
        created.isMovable = false
        created.isReleasedWhenClosed = false
        created.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
        ]
        panel = created
        return created
    }
}

final class ClaudePermissionPromptViewController: NSViewController {
    var onDecision: ((ClaudePermissionUserDecision) -> Void)?

    let preferredPanelSize: NSSize

    private let prompt: ClaudePermissionPrompt
    private let queueCount: Int
    private var questionInputs: [ClaudeQuestionInput] = []
    private var currentQuestionIndex = 0
    private var questionPageIndicator: NSTextField?
    private var previousQuestionButton: NSButton?
    private var nextQuestionButton: NSButton?
    private weak var planTextLabel: NSTextField?
    private var planFeedbackField: NSTextField?
    private var validationLabel: NSTextField?

    init(prompt: ClaudePermissionPrompt, queueCount: Int = 1) {
        self.prompt = prompt
        self.queueCount = queueCount
        switch prompt.interactionKind {
        case .toolApproval:
            preferredPanelSize = NSSize(
                width: claudePermissionPanelWidth,
                height: 304
            )
        case .askUserQuestion:
            preferredPanelSize = NSSize(
                width: claudePermissionPanelWidth,
                height: claudeQuestionPanelHeight(
                    questionCount: prompt.questions.count
                )
            )
        case .exitPlanMode:
            preferredPanelSize = NSSize(width: claudePermissionPanelWidth, height: 478)
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let chrome = ClaudePermissionChromeView()
        chrome.translatesAutoresizingMaskIntoConstraints = false
        // 面板尺寸由 preferredPanelSize 单方面决定：窗口在 contentViewController
        // 赋值时会按 view 的 fittingSize 定尺，缺少绝对锚点时长选项文本的内在
        // 宽度会把面板撑宽。这两条约束让内容适配面板，而不是面板迁就内容。
        NSLayoutConstraint.activate([
            chrome.widthAnchor.constraint(equalToConstant: preferredPanelSize.width),
            chrome.heightAnchor.constraint(equalToConstant: preferredPanelSize.height),
        ])

        let bodySurface = NSView()
        bodySurface.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(bodySurface)
        NSLayoutConstraint.activate([
            bodySurface.leadingAnchor.constraint(equalTo: chrome.leadingAnchor),
            bodySurface.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            bodySurface.topAnchor.constraint(equalTo: chrome.topAnchor),
            bodySurface.bottomAnchor.constraint(
                equalTo: chrome.bottomAnchor,
                constant: -claudePermissionPanelPointerHeight
            ),
        ])

        let header = makeHeader()
        let footer = makeFooter()
        let content = makeContent()
        bodySurface.addSubview(header)
        bodySurface.addSubview(content)
        bodySurface.addSubview(footer)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: bodySurface.leadingAnchor, constant: 26),
            header.trailingAnchor.constraint(equalTo: bodySurface.trailingAnchor, constant: -26),
            header.topAnchor.constraint(equalTo: bodySurface.topAnchor, constant: 19),
            header.heightAnchor.constraint(equalToConstant: 34),

            content.leadingAnchor.constraint(equalTo: bodySurface.leadingAnchor, constant: 27),
            content.trailingAnchor.constraint(equalTo: bodySurface.trailingAnchor, constant: -27),
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 17),
            content.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: -14),

            footer.leadingAnchor.constraint(equalTo: bodySurface.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: bodySurface.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bodySurface.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: footerHeight),
        ])

        self.view = chrome
    }

    private var footerHeight: CGFloat {
        switch prompt.interactionKind {
        case .toolApproval:
            return 82
        case .askUserQuestion, .exitPlanMode:
            return 74
        }
    }

    private var statusTitle: String {
        switch prompt.interactionKind {
        case .toolApproval:
            return "需要你的确认"
        case .askUserQuestion:
            return "需要你的回答"
        case .exitPlanMode:
            return "需要你审阅计划"
        }
    }

    private var headline: String {
        switch prompt.interactionKind {
        case .toolApproval:
            switch prompt.toolName.lowercased() {
            case "bash":
                return "允许 Claude 运行这个命令吗？"
            case "edit":
                return "允许 Claude 修改这个文件吗？"
            case "write":
                return "允许 Claude 写入这个文件吗？"
            case "webfetch", "websearch":
                return "允许 Claude 访问网络吗？"
            default:
                return "允许 Claude 使用 \(safeSingleLine(prompt.toolName)) 吗？"
            }
        case .askUserQuestion:
            if prompt.questions.count == 1 {
                return "Claude 有一个问题需要你回答"
            }
            return "Claude 有 \(prompt.questions.count) 个问题需要你回答"
        case .exitPlanMode:
            return "批准 Claude 的执行计划吗？"
        }
    }

    private func makeHeader() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let source = ClaudeSourceBadgeView()
        source.translatesAutoresizingMaskIntoConstraints = false

        let status = NSTextField(labelWithString: statusTitle)
        status.font = .systemFont(ofSize: 15, weight: .semibold)
        status.textColor = NSColor(
            calibratedRed: 0.75,
            green: 0.85,
            blue: 0.96,
            alpha: 1
        )
        status.alignment = .center
        status.translatesAutoresizingMaskIntoConstraints = false

        let leftDot = headerDot()
        let rightDot = headerDot()
        let statusRow = NSStackView(views: [leftDot, status, rightDot])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        let count = ClaudeCountBadgeView(count: queueCount)
        count.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(source)
        container.addSubview(statusRow)
        container.addSubview(count)
        NSLayoutConstraint.activate([
            source.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            source.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            statusRow.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            statusRow.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            statusRow.leadingAnchor.constraint(greaterThanOrEqualTo: source.trailingAnchor, constant: 8),
            statusRow.trailingAnchor.constraint(lessThanOrEqualTo: count.leadingAnchor, constant: -8),
            count.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            count.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func headerDot() -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 2
        dot.layer?.backgroundColor = ClaudePanelPalette.mutedText
            .withAlphaComponent(0.72)
            .cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 4),
            dot.heightAnchor.constraint(equalToConstant: 4),
        ])
        return dot
    }

    private func makeContent() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(wrappingLabelWithString: headline)
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        title.textColor = ClaudePanelPalette.primaryText
        title.maximumNumberOfLines = prompt.interactionKind == .askUserQuestion ? 2 : 1
        title.lineBreakMode = .byWordWrapping
        title.setContentCompressionResistancePriority(.required, for: .vertical)
        stack.addArrangedSubview(title)
        title.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        switch prompt.interactionKind {
        case .toolApproval:
            buildToolApproval(in: stack)
        case .askUserQuestion:
            buildQuestionForm(in: stack)
        case .exitPlanMode:
            buildPlanReview(in: stack)
        }
        return stack
    }

    private func buildToolApproval(in stack: NSStackView) {
        let message = multilineLabel(prompt.message, fontSize: 13)
        message.maximumNumberOfLines = 1
        message.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(message)
        message.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(10, after: message)

        let commandRow = NSStackView()
        commandRow.orientation = .horizontal
        commandRow.alignment = .centerY
        commandRow.spacing = 12

        let icon = ClaudeToolIconView(
            symbolName: toolSymbolName,
            accessibilityDescription: prompt.toolName
        )
        commandRow.addArrangedSubview(icon)

        let command = NSTextField(labelWithString: toolSummary)
        command.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
        command.textColor = ClaudePanelPalette.primaryText.withAlphaComponent(0.9)
        command.lineBreakMode = .byTruncatingMiddle
        command.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        commandRow.addArrangedSubview(command)

        let divider = ClaudeSeparatorView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = ClaudePanelPalette.hairline.cgColor
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 28),
        ])
        commandRow.addArrangedSubview(divider)

        let tool = NSTextField(labelWithString: safeSingleLine(prompt.toolName))
        tool.font = .systemFont(ofSize: 13, weight: .semibold)
        tool.textColor = ClaudePanelPalette.blue
        tool.setContentCompressionResistancePriority(.required, for: .horizontal)
        commandRow.addArrangedSubview(tool)
        stack.addArrangedSubview(commandRow)
        NSLayoutConstraint.activate([
            commandRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            commandRow.heightAnchor.constraint(equalToConstant: 40),
        ])

        let detailsTitle = prompt.suggestions.isEmpty
            ? "本次授权不会更改长期权限"
            : "查看权限详情"
        let details = ClaudeActionButton(
            title: detailsTitle,
            symbolName: prompt.suggestions.isEmpty ? "lock.shield" : "chevron.right",
            style: .link,
            target: self,
            action: prompt.suggestions.isEmpty ? nil : #selector(showPermissionDetails)
        )
        details.alignment = .left
        details.toolTip = prompt.suggestions.first?.title
        details.heightAnchor.constraint(equalToConstant: 20).isActive = true
        stack.addArrangedSubview(details)
    }

    private func buildQuestionForm(in stack: NSStackView) {
        let message = multilineLabel(prompt.message, fontSize: 12)
        message.maximumNumberOfLines = 1
        stack.addArrangedSubview(message)
        message.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(12, after: message)

        for question in prompt.questions {
            let input = ClaudeQuestionInput(question: question)
            questionInputs.append(input)
        }

        let previous = ClaudeActionButton(
            title: "上一题",
            symbolName: "chevron.left",
            style: .secondary,
            target: self,
            action: #selector(showPreviousQuestion)
        )
        previous.translatesAutoresizingMaskIntoConstraints = false
        previousQuestionButton = previous

        let indicator = NSTextField(labelWithString: "")
        indicator.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        indicator.textColor = ClaudePanelPalette.secondaryText
        indicator.alignment = .center
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.setContentHuggingPriority(.defaultLow, for: .horizontal)
        questionPageIndicator = indicator

        let next = ClaudeActionButton(
            title: "下一题",
            symbolName: "chevron.right",
            style: .secondary,
            target: self,
            action: #selector(showNextQuestion)
        )
        next.translatesAutoresizingMaskIntoConstraints = false
        nextQuestionButton = next

        let navigation = NSStackView(views: [previous, indicator, next])
        navigation.orientation = .horizontal
        navigation.alignment = .centerY
        navigation.spacing = 10
        stack.addArrangedSubview(navigation)
        NSLayoutConstraint.activate([
            navigation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            navigation.heightAnchor.constraint(equalToConstant: 32),
            previous.widthAnchor.constraint(equalToConstant: 112),
            previous.heightAnchor.constraint(equalToConstant: 30),
            next.widthAnchor.constraint(equalToConstant: 112),
            next.heightAnchor.constraint(equalToConstant: 30),
        ])
        stack.setCustomSpacing(9, after: navigation)

        let pageContainer = NSView()
        pageContainer.translatesAutoresizingMaskIntoConstraints = false
        for input in questionInputs {
            input.view.translatesAutoresizingMaskIntoConstraints = false
            input.view.isHidden = true
            pageContainer.addSubview(input.view)
            NSLayoutConstraint.activate([
                input.view.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
                input.view.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
                input.view.topAnchor.constraint(equalTo: pageContainer.topAnchor),
                input.view.bottomAnchor.constraint(
                    equalTo: pageContainer.bottomAnchor
                ),
            ])
        }
        stack.addArrangedSubview(pageContainer)
        NSLayoutConstraint.activate([
            pageContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // 面板总高固定 620，这里用掉 content 区剩余额度的绝大部分，让常见的
            // 2~3 个带说明选项连同"其他回答"输入框一次性显示完；选项更多时由
            // 卡片内的滚动视图兜底。
            pageContainer.heightAnchor.constraint(equalToConstant: 316),
        ])

        let validation = makeValidationLabel()
        validationLabel = validation
        stack.addArrangedSubview(validation)
        validation.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        showQuestionPage(at: 0)
    }

    @objc private func showPreviousQuestion() {
        hideValidation()
        showQuestionPage(at: currentQuestionIndex - 1)
    }

    @objc private func showNextQuestion() {
        hideValidation()
        showQuestionPage(at: currentQuestionIndex + 1)
    }

    // 预览渲染（ClaudePermissionQuestions.swift）会切到第二页，保持 internal。
    func showQuestionPage(at proposedIndex: Int) {
        currentQuestionIndex = clampedClaudeQuestionPageIndex(
            proposedIndex,
            count: questionInputs.count
        )
        for (index, input) in questionInputs.enumerated() {
            input.view.isHidden = index != currentQuestionIndex
        }

        let count = questionInputs.count
        questionPageIndicator?.stringValue = count == 0
            ? "暂无问题"
            : "问题 \(currentQuestionIndex + 1) / \(count)"
        let hasMultipleQuestions = count > 1
        previousQuestionButton?.isHidden = !hasMultipleQuestions
        nextQuestionButton?.isHidden = !hasMultipleQuestions
        previousQuestionButton?.isEnabled = currentQuestionIndex > 0
        nextQuestionButton?.isEnabled = currentQuestionIndex + 1 < count
        previousQuestionButton?.alphaValue = currentQuestionIndex > 0 ? 1 : 0.36
        nextQuestionButton?.alphaValue = currentQuestionIndex + 1 < count ? 1 : 0.36
    }

    func preparePlanForPreviewRendering() -> Bool {
        guard prompt.interactionKind == .exitPlanMode,
              let planTextLabel,
              let cell = planTextLabel.cell
        else { return false }
        planTextLabel.isSelectable = false
        cell.isHighlighted = false
        return !planTextLabel.isSelectable && !cell.isHighlighted
    }

    private func buildPlanReview(in stack: NSStackView) {
        let message = multilineLabel(prompt.message, fontSize: 12)
        message.maximumNumberOfLines = 1
        stack.addArrangedSubview(message)
        message.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(10, after: message)

        let planText = prompt.planText ?? "Claude 已完成计划。完整计划可在终端中查看。"
        let planLabel = NSTextField(wrappingLabelWithString: planText)
        planTextLabel = planLabel
        planLabel.isSelectable = true
        planLabel.font = .systemFont(ofSize: 12)
        planLabel.textColor = ClaudePanelPalette.primaryText.withAlphaComponent(0.86)
        planLabel.maximumNumberOfLines = 0
        planLabel.lineBreakMode = .byWordWrapping
        let planStack = NSStackView(views: [planLabel])
        planStack.orientation = .vertical
        planStack.alignment = .leading
        planLabel.widthAnchor.constraint(equalTo: planStack.widthAnchor).isActive = true
        let scroll = makeScrollView(contentStack: planStack, height: 176)
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(10, after: scroll)

        let feedback = NSTextField()
        styleTextField(feedback, placeholder: "需要调整？在这里告诉 Claude")
        planFeedbackField = feedback
        stack.addArrangedSubview(feedback)
        NSLayoutConstraint.activate([
            feedback.widthAnchor.constraint(equalTo: stack.widthAnchor),
            feedback.heightAnchor.constraint(equalToConstant: 34),
        ])

        let validation = makeValidationLabel()
        validationLabel = validation
        stack.addArrangedSubview(validation)
        validation.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func makeFooter() -> NSView {
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.wantsLayer = true
        footer.layer?.backgroundColor = NSColor(
            calibratedRed: 0.01,
            green: 0.055,
            blue: 0.11,
            alpha: 0.38
        ).cgColor

        let divider = ClaudeSeparatorView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(divider)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            divider.topAnchor.constraint(equalTo: footer.topAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
        ])

        let buttons: [NSButton]
        switch prompt.interactionKind {
        case .toolApproval:
            buttons = [
                footerButton(
                    title: "回到终端",
                    symbolName: "terminal",
                    style: .plain,
                    selector: #selector(useNativeFallback),
                    width: 150
                ),
                footerButton(
                    title: "拒绝",
                    symbolName: "xmark",
                    style: .danger,
                    selector: #selector(denyTool),
                    width: 126
                ),
                footerButton(
                    title: "允许一次",
                    symbolName: "checkmark",
                    style: .primary,
                    selector: #selector(allowOnce),
                    width: 196,
                    keyEquivalent: "\r"
                ),
            ]
        case .askUserQuestion:
            buttons = [
                footerButton(
                    title: "回到终端",
                    symbolName: "terminal",
                    style: .plain,
                    selector: #selector(useNativeFallback),
                    width: 170
                ),
                footerButton(
                    title: "提交回答",
                    symbolName: "paperplane.fill",
                    style: .primary,
                    selector: #selector(submitAnswers),
                    width: 250,
                    keyEquivalent: "\r"
                ),
            ]
        case .exitPlanMode:
            buttons = [
                footerButton(
                    title: "回到终端",
                    symbolName: "terminal",
                    style: .plain,
                    selector: #selector(useNativeFallback),
                    width: 140
                ),
                footerButton(
                    title: "让 Claude 修改",
                    symbolName: "arrow.uturn.backward",
                    style: .secondary,
                    selector: #selector(submitPlanFeedback),
                    width: 160
                ),
                footerButton(
                    title: "批准并继续",
                    symbolName: "checkmark",
                    style: .primary,
                    selector: #selector(allowOnce),
                    width: 180,
                    keyEquivalent: "\r"
                ),
            ]
        }

        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(row)

        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            row.topAnchor.constraint(equalTo: footer.topAnchor, constant: 13),
            row.heightAnchor.constraint(equalToConstant: 42),
        ])

        if prompt.interactionKind == .toolApproval {
            let helper = NSTextField(labelWithString: "仅允许本次操作")
            helper.font = .systemFont(ofSize: 10, weight: .medium)
            helper.textColor = ClaudePanelPalette.blue
            helper.alignment = .center
            helper.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(helper)
            NSLayoutConstraint.activate([
                helper.centerXAnchor.constraint(equalTo: buttons[2].centerXAnchor),
                helper.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 3),
            ])
        }

        return footer
    }

    private func footerButton(
        title: String,
        symbolName: String,
        style: ClaudeActionButtonStyle,
        selector: Selector,
        width: CGFloat,
        keyEquivalent: String = ""
    ) -> NSButton {
        let button = ClaudeActionButton(
            title: title,
            symbolName: symbolName,
            style: style,
            target: self,
            action: selector
        )
        button.keyEquivalent = keyEquivalent
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: width),
            button.heightAnchor.constraint(equalToConstant: 42),
        ])
        return button
    }

    private var toolSymbolName: String {
        switch prompt.toolName.lowercased() {
        case "bash":
            return "terminal"
        case "edit", "write":
            return "doc.badge.ellipsis"
        case "read":
            return "doc.text.magnifyingglass"
        case "webfetch", "websearch":
            return "network"
        default:
            return "lock.shield"
        }
    }

    private var toolSummary: String {
        let candidateKeys = [
            "command",
            "file_path",
            "path",
            "url",
            "query",
            "description",
        ]
        for key in candidateKeys {
            if let value = prompt.originalToolInput[key] as? String {
                let text = safeSingleLine(value)
                if !text.isEmpty {
                    return String(text.prefix(90))
                }
            }
        }
        return safeSingleLine(prompt.toolName)
    }

    private func multilineLabel(_ text: String, fontSize: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: fontSize)
        label.textColor = ClaudePanelPalette.secondaryText
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        return label
    }

    private func makeValidationLabel() -> NSTextField {
        let validation = NSTextField(labelWithString: "")
        validation.font = .systemFont(ofSize: 11, weight: .medium)
        validation.textColor = ClaudePanelPalette.red
        validation.isHidden = true
        return validation
    }

    private func styleTextField(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: ClaudePanelPalette.mutedText,
            ]
        )
        field.font = .systemFont(ofSize: 12)
        field.textColor = ClaudePanelPalette.primaryText
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = ClaudePanelPalette.insetFill
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.cornerRadius = 9
        field.layer?.borderColor = ClaudePanelPalette.cyan
            .withAlphaComponent(0.2)
            .cgColor
        field.layer?.borderWidth = 0.8
    }

    private func makeScrollView(contentStack: NSStackView, height: CGFloat) -> NSScrollView {
        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 5),
            contentStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -9),
            contentStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 6),
            contentStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -6),
        ])

        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = ClaudePanelPalette.insetFill
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 11
        scroll.layer?.borderColor = ClaudePanelPalette.cyan
            .withAlphaComponent(0.16)
            .cgColor
        scroll.layer?.borderWidth = 0.8
        scroll.heightAnchor.constraint(equalToConstant: max(100, height)).isActive = true
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        return scroll
    }

    private func safeSingleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    @objc private func allowOnce() {
        onDecision?(.allowOnce)
    }

    @objc private func denyTool() {
        onDecision?(.deny("用户在 ChatBird 中拒绝了这次操作"))
    }

    @objc private func useNativeFallback() {
        onDecision?(.nativeFallback)
    }

    @objc private func showPermissionDetails(_ sender: NSButton) {
        guard !prompt.suggestions.isEmpty else { return }
        let menu = NSMenu(title: "权限详情")
        menu.autoenablesItems = false
        for (index, suggestion) in prompt.suggestions.enumerated() {
            let detail = NSMenuItem(title: suggestion.title, action: nil, keyEquivalent: "")
            detail.isEnabled = false
            menu.addItem(detail)

            let apply = NSMenuItem(
                title: "应用这条长期允许",
                action: #selector(applySuggestionFromMenu),
                keyEquivalent: ""
            )
            apply.target = self
            apply.tag = index
            menu.addItem(apply)
            if index < prompt.suggestions.count - 1 {
                menu.addItem(.separator())
            }
        }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: sender.bounds.minX, y: sender.bounds.maxY + 3),
            in: sender
        )
    }

    @objc private func applySuggestionFromMenu(_ sender: NSMenuItem) {
        guard prompt.suggestions.indices.contains(sender.tag) else { return }
        onDecision?(.allowWithSuggestion(prompt.suggestions[sender.tag].rawValue))
    }

    @objc private func submitAnswers() {
        var answers: [String: Any] = [:]
        for (index, input) in questionInputs.enumerated() {
            guard let value = input.answerValue else {
                showQuestionPage(at: index)
                showValidation("请先回答第 \(index + 1) 题，或选择“回到终端”。")
                return
            }
            answers[input.question.answerKey] = value
        }
        hideValidation()
        onDecision?(.submitAnswers(answers))
    }

    @objc private func submitPlanFeedback() {
        let feedback = planFeedbackField?.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !feedback.isEmpty else {
            showValidation("请先填写希望 Claude 修改的内容。")
            return
        }
        hideValidation()
        onDecision?(.planFeedback(feedback))
    }

    private func showValidation(_ message: String) {
        validationLabel?.stringValue = message
        validationLabel?.isHidden = false
    }

    private func hideValidation() {
        validationLabel?.stringValue = ""
        validationLabel?.isHidden = true
    }
}
