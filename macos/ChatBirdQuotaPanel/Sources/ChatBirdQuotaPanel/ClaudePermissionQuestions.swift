//
//  ClaudePermissionQuestions.swift
//  ChatBirdQuotaPanel
//
//  模块职责：Claude 权限面板的问答表单组件——选项按钮、单题输入卡片、
//  翻转滚动文档视图，以及 --render-claude-hook-preview 预览渲染。
//  视觉常量与复用组件见 ClaudePermissionViews.swift。
//

import AppKit

private final class ClaudeChoiceButton: NSButton {
    let optionIndex: Int
    let allowsMultipleSelection: Bool
    let preferredHeight: CGFloat

    private let option: ClaudeQuestionOption

    init(
        option: ClaudeQuestionOption,
        index: Int,
        allowsMultipleSelection: Bool,
        target: AnyObject,
        action: Selector
    ) {
        optionIndex = index
        self.allowsMultipleSelection = allowsMultipleSelection
        self.option = option
        preferredHeight = option.detail == nil ? 32 : 50
        super.init(frame: .zero)
        title = option.label
        toolTip = option.detail
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        imagePosition = .imageLeading
        imageHugsTitle = true
        alignment = .left
        font = .systemFont(ofSize: 12, weight: .medium)
        cell?.usesSingleLineMode = false
        cell?.wraps = true
        cell?.lineBreakMode = .byTruncatingTail
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.8
        setSelected(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSelected(_ selected: Bool) {
        state = selected ? .on : .off
        let symbol: String
        if allowsMultipleSelection {
            symbol = selected ? "checkmark.square.fill" : "square"
        } else {
            symbol = selected ? "record.circle.fill" : "circle"
        }
        image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: selected ? "已选择" : "未选择"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        )
        let foreground = selected
            ? ClaudePanelPalette.primaryText
            : ClaudePanelPalette.secondaryText
        contentTintColor = selected ? ClaudePanelPalette.cyan : ClaudePanelPalette.mutedText
        let copy = NSMutableAttributedString(
            string: option.label,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: foreground,
            ]
        )
        if let detail = option.detail {
            copy.append(NSAttributedString(
                string: "\n\(detail)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
                    .foregroundColor: selected
                        ? ClaudePanelPalette.secondaryText
                        : ClaudePanelPalette.mutedText,
                ]
            ))
        }
        attributedTitle = copy
        layer?.backgroundColor = (
            selected
                ? ClaudePanelPalette.blue.withAlphaComponent(0.13)
                : NSColor.white.withAlphaComponent(0.025)
        ).cgColor
        layer?.borderColor = (
            selected
                ? ClaudePanelPalette.cyan.withAlphaComponent(0.5)
                : ClaudePanelPalette.cyan.withAlphaComponent(0.12)
        ).cgColor
    }
}

final class ClaudeQuestionInput: NSObject {
    let question: ClaudeQuestion
    let view: NSView

    private var choiceButtons: [ClaudeChoiceButton] = []
    private let otherField = NSTextField()

    init(question: ClaudeQuestion) {
        self.question = question
        let card = ClaudeInsetCardView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -11),
        ])

        if let header = question.header {
            let headerLabel = NSTextField(labelWithString: header.uppercased())
            headerLabel.font = .systemFont(ofSize: 10, weight: .semibold)
            headerLabel.textColor = ClaudePanelPalette.cyan
            stack.addArrangedSubview(headerLabel)
        }

        let promptLabel = NSTextField(wrappingLabelWithString: question.answerKey)
        promptLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        promptLabel.textColor = ClaudePanelPalette.primaryText
        promptLabel.maximumNumberOfLines = 3
        stack.addArrangedSubview(promptLabel)
        promptLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        self.view = card
        super.init()

        for (index, option) in question.options.enumerated() {
            let button = ClaudeChoiceButton(
                option: option,
                index: index,
                allowsMultipleSelection: question.allowsMultipleSelection,
                target: self,
                action: #selector(toggleChoice)
            )
            button.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(button)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalTo: stack.widthAnchor),
                button.heightAnchor.constraint(equalToConstant: button.preferredHeight),
            ])
            choiceButtons.append(button)
        }

        let placeholder = question.options.isEmpty
            ? "输入你的回答"
            : "其他回答（填写后优先使用）"
        styleOtherField(placeholder: placeholder)
        stack.addArrangedSubview(otherField)
        NSLayoutConstraint.activate([
            otherField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            otherField.heightAnchor.constraint(equalToConstant: 76),
        ])
    }

    var answerValue: Any? {
        let custom = otherField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            return custom
        }
        let selections = zip(question.options, choiceButtons).compactMap { option, button in
            button.state == .on ? option.label : nil
        }
        if question.allowsMultipleSelection {
            return selections.isEmpty ? nil : selections.joined(separator: ", ")
        }
        return selections.first
    }

    @objc private func toggleChoice(_ sender: ClaudeChoiceButton) {
        if question.allowsMultipleSelection {
            sender.setSelected(sender.state != .on)
            return
        }
        for button in choiceButtons {
            button.setSelected(button === sender)
        }
    }

    private func styleOtherField(placeholder: String) {
        otherField.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: ClaudePanelPalette.mutedText,
            ]
        )
        otherField.font = .systemFont(ofSize: 11)
        otherField.textColor = ClaudePanelPalette.primaryText
        otherField.isBordered = false
        otherField.drawsBackground = true
        otherField.backgroundColor = NSColor.black.withAlphaComponent(0.16)
        otherField.focusRingType = .none
        otherField.maximumNumberOfLines = 3
        otherField.lineBreakMode = .byWordWrapping
        otherField.cell?.usesSingleLineMode = false
        otherField.cell?.wraps = true
        otherField.cell?.isScrollable = false
        otherField.wantsLayer = true
        otherField.layer?.cornerRadius = 7
        otherField.layer?.borderColor = ClaudePanelPalette.cyan
            .withAlphaComponent(0.15)
            .cgColor
        otherField.layer?.borderWidth = 0.7
    }
}

final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

func renderClaudePermissionPreview(kind: String, to outputURL: URL) throws {
    _ = NSApplication.shared
    let fixture: String
    switch kind {
    case "question", "question-second":
        fixture = """
        {
          "tool_name": "AskUserQuestion",
          "session_id": "12345678-1234-1234-1234-123456789abc",
          "cwd": "/tmp/chatbird",
          "tool_input": {
            "questions": [
              {
                "question": "你希望任务完成后生成哪种交付物？",
                "header": "交付方式",
                "options": [
                  {"label": "只提交代码", "description": "保留最小变更"},
                  {"label": "代码和说明", "description": "同时提供使用说明"}
                ],
                "multiSelect": false
              },
              {
                "question": "需要执行哪些验证？",
                "header": "验证",
                "options": [
                  {"label": "单元测试"},
                  {"label": "构建检查"}
                ],
                "multiSelect": true
              }
            ]
          }
        }
        """
    case "plan":
        fixture = """
        {
          "tool_name": "ExitPlanMode",
          "tool_input": {
            "plan": "1. 检查当前 Hook 配置和冲突。\\n2. 启动本地权限服务。\\n3. 为确认、提问和计划审查显示原生弹窗。\\n4. 完成构建与协议验证。"
          }
        }
        """
    default:
        fixture = """
        {
          "tool_name": "Bash",
          "tool_input": {
            "command": "swift test",
            "description": "用于确认当前修改没有破坏现有功能。"
          },
          "permission_suggestions": [{
            "type": "addRules",
            "rules": [{"toolName": "Bash", "ruleContent": "swift test"}]
          }]
        }
        """
    }

    let prompt = try ClaudePermissionProtocol.decodePrompt(from: Data(fixture.utf8))
    let controller = ClaudePermissionPromptViewController(prompt: prompt)
    let size = controller.preferredPanelSize
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isOpaque = false
    window.backgroundColor = .clear
    window.contentViewController = controller
    controller.view.frame = NSRect(origin: .zero, size: size)
    if kind == "question-second" {
        controller.showQuestionPage(at: 1)
    }
    controller.view.layoutSubtreeIfNeeded()
    window.displayIfNeeded()

    let scale: CGFloat = 2
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width * scale),
        pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(
            domain: "ChatBirdClaudeHook",
            code: 20,
            userInfo: [NSLocalizedDescriptionKey: "无法创建 Hook 预览画布"]
        )
    }
    bitmap.size = size
    controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(
            domain: "ChatBirdClaudeHook",
            code: 21,
            userInfo: [NSLocalizedDescriptionKey: "无法编码 Hook 预览"]
        )
    }
    try png.write(to: outputURL, options: .atomic)
}
