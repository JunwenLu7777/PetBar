import AppKit
import Foundation

enum DynamicIslandQuotaPresentationPhase: Equatable {
    case firstLoad
    case refreshing
    case current
    case stale
    case firstFailure
    case unavailable
}

func dynamicIslandTintedSymbolImage(
    named symbolName: String,
    color: NSColor,
    accessibilityDescription: String
) -> NSImage? {
    guard let base = NSImage(
        systemSymbolName: symbolName,
        accessibilityDescription: accessibilityDescription
    )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
    else { return nil }
    let size = NSSize(width: 16, height: 16)
    let image = NSImage(size: size)
    image.lockFocus()
    let rect = NSRect(origin: .zero, size: size)
    color.setFill()
    rect.fill()
    base.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
    image.unlockFocus()
    image.isTemplate = false
    image.accessibilityDescription = accessibilityDescription
    return image
}

func dynamicIslandQuotaPhase(
    state: QuotaProviderState?,
    providerAvailable: Bool
) -> DynamicIslandQuotaPresentationPhase {
    guard providerAvailable else { return .unavailable }
    guard let state else { return .firstLoad }
    let hasCachedValues = !state.rows.isEmpty || state.resetCredits != nil
    if state.isRefreshing {
        return hasCachedValues ? .refreshing : .firstLoad
    }
    if state.isStale || (state.errorText != nil && hasCachedValues) {
        return .stale
    }
    if state.errorText != nil { return .firstFailure }
    if state.updatedAt == nil && !hasCachedValues { return .firstLoad }
    return .current
}

func dynamicIslandDashboardRefreshEnabled(
    snapshot: ActivityDashboardSnapshot
) -> Bool {
    guard !snapshot.isTaskRefreshing else { return false }
    return !snapshot.availableProviders.contains { provider in
        snapshot.quotaStates[provider]?.isRefreshing == true
    }
}

final class DynamicIslandQuotaViewController: NSViewController {
    var onSelectProvider: ((QuotaProvider) -> Void)?
    var onRefresh: (() -> Void)?

    private let leftPane = DynamicIslandCardView(
        cornerRadius: 10,
        backgroundColor: DynamicIslandPalette.surface
    )
    private let rightPane = DynamicIslandCardView(
        cornerRadius: 10,
        backgroundColor: DynamicIslandPalette.surface
    )
    private let titleField = DynamicIslandQuotaLabel(size: 14, weight: .semibold)
    private let statusField = DynamicIslandQuotaLabel(size: 13, weight: .medium)
    private let providerDivider = DynamicIslandDividerView()
    private let refreshButton = DynamicIslandButton(
        title: "",
        style: .icon,
        imageName: "arrow.clockwise"
    )
    private let providerStack = NSStackView()
    private let detailStack = NSStackView()
    private var providerButtons: [QuotaProvider: NSButton] = [:]
    private var latestSnapshot = ActivityDashboardSnapshot()
    private var detailRowNames: [String] = []
    private var detailResetTexts: [String] = []
    private var resetCreditExpiryLineCount = 0
    private var detailAccessibilityTexts: [String] = []

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: dynamicIslandQuotaSize))
        view.addSubview(leftPane)
        view.addSubview(rightPane)
        leftPane.addSubview(titleField)
        leftPane.addSubview(statusField)
        leftPane.addSubview(providerDivider)
        leftPane.addSubview(providerStack)
        rightPane.addSubview(refreshButton)
        rightPane.addSubview(detailStack)

        titleField.stringValue = "提供商"
        titleField.setAccessibilityLabel("额度提供商")
        statusField.setAccessibilityLabel("额度状态摘要")
        statusField.textColor = DynamicIslandPalette.secondaryText

        providerStack.orientation = .vertical
        providerStack.alignment = .leading
        providerStack.spacing = 8

        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 10

        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        refreshButton.setAccessibilityLabel("刷新任务和全部额度")
        refreshButton.toolTip = "刷新任务与全部额度"
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let leftWidth: CGFloat = 228
        leftPane.frame = NSRect(
            x: 0,
            y: 0,
            width: leftWidth,
            height: view.bounds.height
        )
        rightPane.frame = NSRect(
            x: leftWidth + 12,
            y: 0,
            width: max(1, view.bounds.width - leftWidth - 12),
            height: view.bounds.height
        )
        titleField.frame = NSRect(
            x: 16,
            y: leftPane.bounds.height - 30,
            width: leftPane.bounds.width - 32,
            height: 20
        )
        statusField.frame = NSRect(
            x: 16,
            y: leftPane.bounds.height - 54,
            width: leftPane.bounds.width - 32,
            height: 18
        )
        providerDivider.frame = NSRect(
            x: 12,
            y: leftPane.bounds.height - 68,
            width: leftPane.bounds.width - 24,
            height: 1
        )
        providerStack.frame = NSRect(
            x: 12,
            y: 14,
            width: leftPane.bounds.width - 24,
            height: max(1, leftPane.bounds.height - 92)
        )
        refreshButton.frame = NSRect(
            x: rightPane.bounds.width - 48,
            y: rightPane.bounds.height - 46,
            width: 34,
            height: 34
        )
        detailStack.frame = NSRect(
            x: 14,
            y: 14,
            width: max(1, rightPane.bounds.width - 28),
            height: max(1, rightPane.bounds.height - 28)
        )
    }

    func apply(_ snapshot: ActivityDashboardSnapshot) {
        _ = view
        latestSnapshot = snapshot
        refreshButton.isEnabled = dynamicIslandDashboardRefreshEnabled(
            snapshot: snapshot
        )
        rebuildProviders(snapshot)
        rebuildDetails(snapshot)
    }

    private func rebuildProviders(_ snapshot: ActivityDashboardSnapshot) {
        providerStack.arrangedSubviews.forEach {
            providerStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        providerButtons.removeAll()

        let selectedProvider = snapshot.selectedQuotaProvider
        for provider in snapshot.availableProviders {
            let state = snapshot.quotaStates[provider]
            let phase = dynamicIslandQuotaPhase(
                state: state,
                providerAvailable: true
            )
            let remaining = state?.rows.first(where: {
                $0.name == provider.summaryRowName
            })?.remainingPercent
            let title = [
                provider.displayName,
                remaining.map { "\($0)%" } ?? "--",
            ].compactMap { $0 }.joined(separator: "  ")
            let button = DynamicIslandButton(title: title, style: .secondary)
            button.target = self
            button.action = #selector(selectProvider(_:))
            button.setSelected(
                provider == selectedProvider,
                accent: DynamicIslandPalette.green
            )
            let symbolColor = provider == selectedProvider
                ? DynamicIslandPalette.green
                : DynamicIslandPalette.primaryText
            button.image = dynamicIslandTintedSymbolImage(
                named: symbolName(for: phase),
                color: symbolColor,
                accessibilityDescription: statusText(for: phase, state: state)
            )
            button.imagePosition = .imageLeading
            button.tag = provider == .codex ? 0 : 1
            button.font = .systemFont(ofSize: 13, weight: provider == selectedProvider ? .semibold : .regular)
            button.contentTintColor = provider == selectedProvider
                ? DynamicIslandPalette.green
                : DynamicIslandPalette.primaryText
            button.setAccessibilityLabel("选择 \(provider.displayName) 额度")
            button.setAccessibilityValue(statusText(for: phase, state: state))
            button.widthAnchor.constraint(equalToConstant: 204).isActive = true
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            providerStack.addArrangedSubview(button)
            providerButtons[provider] = button
        }

        statusField.stringValue = selectedSummaryText(snapshot)
    }

    private func rebuildDetails(_ snapshot: ActivityDashboardSnapshot) {
        detailStack.arrangedSubviews.forEach {
            detailStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        detailRowNames = []
        detailResetTexts = []
        resetCreditExpiryLineCount = 0
        detailAccessibilityTexts = []

        let provider = snapshot.selectedQuotaProvider
        let providerAvailable = snapshot.availableProviders.contains(provider)
        let state = snapshot.quotaStates[provider]
        let phase = dynamicIslandQuotaPhase(
            state: state,
            providerAvailable: providerAvailable
        )
        let remaining = state?.rows.first(where: {
            $0.name == provider.summaryRowName
        })?.remainingPercent
        let headline = DynamicIslandQuotaHeadlineView(
            provider: provider,
            percent: remaining,
            phaseText: phaseBadgeText(for: phase),
            phaseColor: tintColor(for: phase),
            updatedText: state?.updatedAt.map {
                "最近成功：\(quotaResetTimeDescription($0))"
            }
        )
        detailStack.addArrangedSubview(headline)
        headline.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
        detailAccessibilityTexts.append(headline.accessibilityText)

        switch phase {
        case .firstLoad:
            addStateCard(
                title: "正在读取额度",
                message: "正在连接 \(provider.displayName) 并读取最新额度…",
                symbolName: "arrow.triangle.2.circlepath",
                color: DynamicIslandPalette.secondaryText
            )
        case .unavailable:
            addStateCard(
                title: provider == .claudeCode ? "未安装 Claude Code" : "未安装 Codex",
                message: "安装或登录后点击刷新，额度卡会自动出现。",
                symbolName: "exclamationmark.triangle",
                color: DynamicIslandPalette.red
            )
        case .firstFailure:
            addStateCard(
                title: state?.errorText ?? "额度服务暂不可用",
                message: state?.statusText ?? "1 分钟后自动重试，也可以手动刷新。",
                symbolName: "exclamationmark.triangle",
                color: DynamicIslandPalette.red
            )
        case .refreshing:
            addPhaseBanner(
                "正在更新，继续显示上次数据",
                color: DynamicIslandPalette.green
            )
            addRowsAndCredits(provider: provider, state: state)
        case .stale:
            addPhaseBanner(
                "缓存数据 · 刷新失败后继续显示",
                color: DynamicIslandPalette.amber
            )
            addRowsAndCredits(provider: provider, state: state)
        case .current:
            if state?.rows.isEmpty != false && state?.resetCredits == nil {
                addStateCard(
                    title: "暂无额度数据",
                    message: "当前没有可确认的额度数据，稍后会自动刷新。",
                    symbolName: "checkmark.circle",
                    color: DynamicIslandPalette.secondaryText
                )
            } else {
                addRowsAndCredits(provider: provider, state: state)
            }
        }
        addLifecycleCard(provider: provider, state: state, phase: phase)
    }

    private func addRowsAndCredits(
        provider: QuotaProvider,
        state: QuotaProviderState?
    ) {
        guard let state else { return }
        for row in state.rows {
            detailRowNames.append(row.name)
            let resetText = row.resetDescription
                ?? row.resetsAt.map { "\(quotaResetTimeDescription($0)) 重置" }
                ?? "重置时间未知"
            detailResetTexts.append(resetText)
            let meter = DynamicIslandQuotaMeterView(
                name: row.name,
                percent: row.remainingPercent,
                resetText: resetText
            )
            detailStack.addArrangedSubview(meter)
            meter.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
            detailAccessibilityTexts.append(meter.accessibilityText)
        }
        guard provider == .codex else { return }
        let presentation = codexResetCreditsPresentation(
            snapshot: state.resetCredits
        )
        resetCreditExpiryLineCount = presentation.expiryLines.count
        let resetCard = DynamicIslandResetCreditsView(
            availableText: presentation.availableText,
            expiryLines: presentation.expiryLines,
            hasAvailableCredits: presentation.hasAvailableCredits
        )
        detailStack.addArrangedSubview(resetCard)
        resetCard.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
        detailAccessibilityTexts.append(resetCard.accessibilityText)
    }

    private func addPhaseBanner(_ text: String, color: NSColor) {
        let banner = DynamicIslandQuotaBannerView(text: text, color: color)
        detailStack.addArrangedSubview(banner)
        banner.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
        detailAccessibilityTexts.append(text)
    }

    private func addLifecycleCard(
        provider: QuotaProvider,
        state: QuotaProviderState?,
        phase: DynamicIslandQuotaPresentationPhase
    ) {
        let refreshText = phase == .refreshing || phase == .firstLoad
            ? "正在刷新"
            : "每 1 分钟"
        let updatedText = state?.updatedAt.map {
            quotaResetTimeDescription($0)
        } ?? "尚无成功数据"
        let lifecycle = DynamicIslandQuotaLifecycleView(
            refreshText: refreshText,
            stateText: phaseBadgeText(for: phase),
            sourceText: provider.displayName,
            updatedText: updatedText,
            stateColor: tintColor(for: phase)
        )
        detailStack.addArrangedSubview(lifecycle)
        lifecycle.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
        detailAccessibilityTexts.append(lifecycle.accessibilityText)
    }

    private func addStateCard(
        title: String,
        message: String,
        symbolName: String,
        color: NSColor
    ) {
        let card = DynamicIslandQuotaStateView(
            title: title,
            message: message,
            symbolName: symbolName,
            color: color
        )
        detailStack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
        detailAccessibilityTexts.append("\(title) \(message)")
    }

    private func addDetailLine(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight,
        selectable: Bool = true,
        symbolName: String? = nil
    ) {
        if let symbolName {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            let imageView = NSImageView()
            imageView.image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: text
            )
            imageView.contentTintColor = DynamicIslandPalette.primaryText
            imageView.widthAnchor.constraint(equalToConstant: 16).isActive = true
            imageView.heightAnchor.constraint(equalToConstant: 16).isActive = true
            let field = DynamicIslandQuotaLabel(
                size: size,
                weight: weight,
                selectable: selectable
            )
            field.stringValue = text
            field.setAccessibilityLabel(text)
            field.widthAnchor.constraint(
                lessThanOrEqualToConstant: max(220, rightPane.bounds.width - 52)
            ).isActive = true
            row.addArrangedSubview(imageView)
            row.addArrangedSubview(field)
            row.setAccessibilityLabel(text)
            detailStack.addArrangedSubview(row)
            return
        }
        let field = DynamicIslandQuotaLabel(
            size: size,
            weight: weight,
            selectable: selectable
        )
        field.stringValue = text
        field.setAccessibilityLabel(text)
        field.widthAnchor.constraint(
            lessThanOrEqualToConstant: max(240, rightPane.bounds.width - 28)
        ).isActive = true
        detailStack.addArrangedSubview(field)
    }

    private func selectedSummaryText(
        _ snapshot: ActivityDashboardSnapshot
    ) -> String {
        let provider = snapshot.selectedQuotaProvider
        let providerAvailable = snapshot.availableProviders.contains(provider)
        let state = snapshot.quotaStates[provider]
        let phase = dynamicIslandQuotaPhase(
            state: state,
            providerAvailable: providerAvailable
        )
        let remaining = state?.rows.first(where: {
            $0.name == provider.summaryRowName
        })?.remainingPercent
        return [
            remaining.map { "\($0)% 可用" },
            statusText(for: phase, state: state),
        ].compactMap { $0 }.joined(separator: " · ")
    }

    private func statusText(
        for phase: DynamicIslandQuotaPresentationPhase,
        state: QuotaProviderState?
    ) -> String {
        switch phase {
        case .firstLoad:
            return "首次读取"
        case .refreshing:
            return "正在更新"
        case .current:
            return state?.statusText ?? "当前"
        case .stale:
            return "缓存数据"
        case .firstFailure:
            return state?.errorText ?? "首次读取失败"
        case .unavailable:
            return "未安装"
        }
    }

    private func symbolName(
        for phase: DynamicIslandQuotaPresentationPhase
    ) -> String {
        switch phase {
        case .firstLoad, .refreshing:
            return "arrow.triangle.2.circlepath"
        case .current:
            return "checkmark.circle"
        case .stale:
            return "exclamationmark.arrow.triangle.2.circlepath"
        case .firstFailure, .unavailable:
            return "exclamationmark.triangle"
        }
    }

    private func tintColor(
        for phase: DynamicIslandQuotaPresentationPhase
    ) -> NSColor {
        switch phase {
        case .current, .refreshing:
            return DynamicIslandPalette.green
        case .stale:
            return DynamicIslandPalette.amber
        case .firstFailure, .unavailable:
            return DynamicIslandPalette.red
        case .firstLoad:
            return DynamicIslandPalette.secondaryText
        }
    }

    private func phaseBadgeText(
        for phase: DynamicIslandQuotaPresentationPhase
    ) -> String {
        switch phase {
        case .firstLoad: return "读取中"
        case .refreshing: return "更新中"
        case .current: return "当前"
        case .stale: return "缓存"
        case .firstFailure: return "失败"
        case .unavailable: return "不可用"
        }
    }

    @objc private func selectProvider(_ sender: NSButton) {
        onSelectProvider?(sender.tag == 0 ? .codex : .claudeCode)
    }

    @objc private func refresh() {
        onRefresh?()
    }

    func accessibilitySnapshotForSelfTest() -> String {
        _ = view
        let providerText = providerButtons.values
            .map(\.title)
            .sorted()
            .joined(separator: " ")
        let detailText = detailStack.arrangedSubviews.compactMap {
            ($0 as? NSTextField)?.stringValue
        }.joined(separator: " ") + " "
            + detailAccessibilityTexts.joined(separator: " ")
        return [
            titleField.stringValue,
            statusField.stringValue,
            providerText,
            detailText,
        ].joined(separator: " ")
    }

    func providerNamesForSelfTest() -> [String] {
        latestSnapshot.availableProviders.map(\.displayName)
    }

    func leftPaneWidthForSelfTest() -> Int {
        _ = view
        view.layoutSubtreeIfNeeded()
        return Int(leftPane.frame.width.rounded())
    }

    func selectedProviderForSelfTest() -> QuotaProvider {
        latestSnapshot.selectedQuotaProvider
    }

    func selectedSummaryPercentForSelfTest() -> Int? {
        latestSnapshot.quotaStates[latestSnapshot.selectedQuotaProvider]?
            .rows
            .first(where: {
                $0.name == latestSnapshot.selectedQuotaProvider.summaryRowName
            })?
            .remainingPercent
    }

    func detailRowNamesForSelfTest() -> [String] {
        detailRowNames
    }

    func detailResetTextsForSelfTest() -> [String] {
        detailResetTexts
    }

    func resetCreditExpiryLineCountForSelfTest() -> Int {
        resetCreditExpiryLineCount
    }

    func providerButtonImagesAreConcreteForSelfTest() -> Bool {
        _ = view
        return providerButtons.values.allSatisfy { button in
            guard let image = button.image else { return false }
            return !image.isTemplate && image.size.width >= 16 && image.size.height >= 16
        }
    }

    func isRefreshEnabledForSelfTest() -> Bool {
        refreshButton.isEnabled
    }

    func selectProviderForSelfTest(_ provider: QuotaProvider) {
        onSelectProvider?(provider)
    }

    func performProviderButtonClickForSelfTest(_ provider: QuotaProvider) {
        providerButtons[provider]?.performClick(nil)
    }

    func refreshForSelfTest() {
        refresh()
    }
}

private final class DynamicIslandQuotaHeadlineView: NSView {
    private let providerField = DynamicIslandQuotaLabel(size: 18, weight: .semibold)
    private let percentField = DynamicIslandQuotaLabel(size: 22, weight: .bold)
    private let phaseField = DynamicIslandQuotaLabel(size: 11, weight: .semibold)
    private let updatedField = DynamicIslandQuotaLabel(size: 11, weight: .regular)
    private let phaseDot = NSView()
    let accessibilityText: String

    init(
        provider: QuotaProvider,
        percent: Int?,
        phaseText: String,
        phaseColor: NSColor,
        updatedText: String?
    ) {
        accessibilityText = [
            "\(provider.displayName) 额度",
            percent.map { "\($0)% 可用" },
            phaseText,
            updatedText,
        ].compactMap { $0 }.joined(separator: " ")
        super.init(frame: .zero)
        providerField.stringValue = "\(provider.displayName) 额度"
        percentField.stringValue = percent.map { "\($0)%" } ?? "--"
        percentField.textColor = phaseColor
        phaseField.stringValue = phaseText
        phaseField.textColor = phaseColor
        updatedField.stringValue = updatedText ?? "尚无成功更新时间"
        updatedField.textColor = DynamicIslandPalette.secondaryText
        updatedField.alignment = .right
        phaseDot.wantsLayer = true
        phaseDot.layer?.cornerRadius = 4
        phaseDot.layer?.backgroundColor = phaseColor.cgColor
        for subview in [
            providerField,
            percentField,
            phaseDot,
            phaseField,
            updatedField,
        ] {
            addSubview(subview)
        }
        setAccessibilityLabel(accessibilityText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 500, height: 62)
    }

    override func layout() {
        super.layout()
        // The parent keeps a 34pt refresh control in the upper-right corner.
        // Reserve that area explicitly so long phase labels never render under it.
        providerField.frame = NSRect(
            x: 0,
            y: 32,
            width: max(120, bounds.width - 304),
            height: 25
        )
        percentField.frame = NSRect(
            x: bounds.width - 300,
            y: 30,
            width: 88,
            height: 28
        )
        phaseDot.frame = NSRect(
            x: bounds.width - 196,
            y: 42,
            width: 8,
            height: 8
        )
        phaseField.frame = NSRect(
            x: bounds.width - 182,
            y: 36,
            width: 108,
            height: 18
        )
        updatedField.frame = NSRect(
            x: bounds.width - 330,
            y: 5,
            width: 256,
            height: 18
        )
    }
}

private final class DynamicIslandQuotaMeterView: NSView {
    private let nameField = DynamicIslandQuotaLabel(size: 13, weight: .semibold)
    private let percentField = DynamicIslandQuotaLabel(size: 18, weight: .bold)
    private let resetField = DynamicIslandQuotaLabel(size: 11, weight: .regular)
    private let segments = (0..<7).map { _ in NSView() }
    private let tint: NSColor
    private let filledSegmentCount: Int
    let accessibilityText: String

    init(name: String, percent: Int, resetText: String) {
        tint = percent >= 75
            ? DynamicIslandPalette.green
            : percent >= 35
                ? DynamicIslandPalette.amber
                : DynamicIslandPalette.red
        filledSegmentCount = max(0, min(7, Int((Double(percent) / 100 * 7).rounded(.up))))
        accessibilityText = "\(name) \(percent)% 可用 \(resetText)"
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = DynamicIslandPalette.raised.cgColor
        layer?.borderColor = DynamicIslandPalette.hairline.cgColor
        layer?.borderWidth = 1
        nameField.stringValue = name
        percentField.stringValue = "\(percent)%"
        percentField.textColor = tint
        resetField.stringValue = resetText
        resetField.textColor = DynamicIslandPalette.secondaryText
        resetField.alignment = .right
        addSubview(nameField)
        addSubview(percentField)
        addSubview(resetField)
        for (index, segment) in segments.enumerated() {
            segment.wantsLayer = true
            segment.layer?.cornerRadius = 2
            segment.layer?.backgroundColor = (
                index < filledSegmentCount
                    ? tint
                    : NSColor.white.withAlphaComponent(0.10)
            ).cgColor
            addSubview(segment)
        }
        setAccessibilityLabel(accessibilityText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 500, height: 72)
    }

    override func layout() {
        super.layout()
        nameField.frame = NSRect(x: 14, y: 40, width: 120, height: 20)
        percentField.frame = NSRect(x: 142, y: 37, width: 70, height: 24)
        resetField.frame = NSRect(x: bounds.width - 206, y: 42, width: 192, height: 18)
        let barX: CGFloat = 14
        let barWidth = max(1, bounds.width - 28)
        let spacing: CGFloat = 5
        let segmentWidth = max(1, (barWidth - spacing * 6) / 7)
        for (index, segment) in segments.enumerated() {
            segment.frame = NSRect(
                x: barX + CGFloat(index) * (segmentWidth + spacing),
                y: 16,
                width: segmentWidth,
                height: 7
            )
        }
    }
}

private final class DynamicIslandResetCreditsView: NSView {
    private let titleField = DynamicIslandQuotaLabel(size: 12, weight: .semibold)
    private let valueField = DynamicIslandQuotaLabel(size: 18, weight: .bold)
    private let expiryField = DynamicIslandQuotaLabel(size: 11, weight: .regular)
    let accessibilityText: String

    init(
        availableText: String,
        expiryLines: [String],
        hasAvailableCredits: Bool
    ) {
        accessibilityText = (
            ["重置额度 \(availableText)"] + expiryLines.map { "过期：\($0)" }
        ).joined(separator: " ")
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = DynamicIslandPalette.green
            .withAlphaComponent(hasAvailableCredits ? 0.10 : 0.04).cgColor
        layer?.borderColor = (
            hasAvailableCredits
                ? DynamicIslandPalette.green.withAlphaComponent(0.48)
                : DynamicIslandPalette.hairline
        ).cgColor
        layer?.borderWidth = 1
        titleField.stringValue = "重置额度"
        titleField.textColor = DynamicIslandPalette.secondaryText
        valueField.stringValue = availableText
        valueField.textColor = hasAvailableCredits
            ? DynamicIslandPalette.green
            : DynamicIslandPalette.secondaryText
        expiryField.stringValue = expiryLines.isEmpty
            ? "暂无过期时间"
            : expiryLines.map { "过期 \($0)" }.joined(separator: "   ")
        expiryField.textColor = DynamicIslandPalette.secondaryText
        expiryField.alignment = .right
        addSubview(titleField)
        addSubview(valueField)
        addSubview(expiryField)
        setAccessibilityLabel(accessibilityText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 500, height: 68)
    }

    override func layout() {
        super.layout()
        titleField.frame = NSRect(x: 14, y: 40, width: 100, height: 18)
        valueField.frame = NSRect(x: 14, y: 13, width: 150, height: 25)
        expiryField.frame = NSRect(x: 174, y: 21, width: max(1, bounds.width - 188), height: 20)
    }
}

private final class DynamicIslandQuotaBannerView: NSView {
    private let dot = NSView()
    private let label = DynamicIslandQuotaLabel(size: 11, weight: .medium)

    init(text: String, color: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = color.withAlphaComponent(0.09).cgColor
        layer?.borderColor = color.withAlphaComponent(0.32).cgColor
        layer?.borderWidth = 1
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = color.cgColor
        label.stringValue = text
        label.textColor = color
        addSubview(dot)
        addSubview(label)
        setAccessibilityLabel(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 500, height: 30)
    }

    override func layout() {
        super.layout()
        dot.frame = NSRect(x: 12, y: 11, width: 7, height: 7)
        label.frame = NSRect(x: 28, y: 6, width: max(1, bounds.width - 40), height: 18)
    }
}

private final class DynamicIslandQuotaLifecycleView: NSView {
    private let titleField = DynamicIslandQuotaLabel(size: 10.5, weight: .semibold)
    private let refreshLabel = DynamicIslandQuotaLabel(size: 9.5, weight: .medium)
    private let refreshValue = DynamicIslandQuotaLabel(size: 11, weight: .semibold)
    private let stateLabel = DynamicIslandQuotaLabel(size: 9.5, weight: .medium)
    private let stateValue = DynamicIslandQuotaLabel(size: 11, weight: .semibold)
    private let sourceLabel = DynamicIslandQuotaLabel(size: 9.5, weight: .medium)
    private let sourceValue = DynamicIslandQuotaLabel(size: 11, weight: .semibold)
    private let updatedField = DynamicIslandQuotaLabel(size: 9.5, weight: .regular)
    let accessibilityText: String

    init(
        refreshText: String,
        stateText: String,
        sourceText: String,
        updatedText: String,
        stateColor: NSColor
    ) {
        accessibilityText =
            "刷新与生命周期，更新节奏 \(refreshText)，当前状态 \(stateText)，数据来源 \(sourceText)，最近成功 \(updatedText)"
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = DynamicIslandPalette.raised.cgColor
        layer?.borderColor = DynamicIslandPalette.hairline.cgColor
        layer?.borderWidth = 1
        titleField.stringValue = "刷新与生命周期"
        titleField.textColor = DynamicIslandPalette.secondaryText
        refreshLabel.stringValue = "更新节奏"
        refreshValue.stringValue = refreshText
        stateLabel.stringValue = "当前状态"
        stateValue.stringValue = stateText
        stateValue.textColor = stateColor
        sourceLabel.stringValue = "数据来源"
        sourceValue.stringValue = sourceText
        updatedField.stringValue = "最近成功 · \(updatedText)"
        for label in [refreshLabel, stateLabel, sourceLabel, updatedField] {
            label.textColor = DynamicIslandPalette.tertiaryText
        }
        for subview in [
            titleField,
            refreshLabel,
            refreshValue,
            stateLabel,
            stateValue,
            sourceLabel,
            sourceValue,
            updatedField,
        ] {
            addSubview(subview)
        }
        setAccessibilityLabel(accessibilityText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 500, height: 72)
    }

    override func layout() {
        super.layout()
        titleField.frame = NSRect(x: 14, y: 48, width: 150, height: 16)
        let columnWidth = max(72, (bounds.width - 42) / 3)
        let columns: [(NSTextField, NSTextField)] = [
            (refreshLabel, refreshValue),
            (stateLabel, stateValue),
            (sourceLabel, sourceValue),
        ]
        for (index, pair) in columns.enumerated() {
            let x = 14 + CGFloat(index) * (columnWidth + 7)
            pair.0.frame = NSRect(x: x, y: 27, width: columnWidth, height: 14)
            pair.1.frame = NSRect(x: x, y: 10, width: columnWidth, height: 16)
        }
        updatedField.frame = NSRect(
            x: max(14, bounds.width - 230),
            y: 49,
            width: min(216, bounds.width - 28),
            height: 14
        )
        updatedField.alignment = .right
    }
}

private final class DynamicIslandQuotaStateView: NSView {
    private let symbolView = NSImageView()
    private let titleField = DynamicIslandQuotaLabel(size: 16, weight: .semibold)
    private let messageField = DynamicIslandQuotaLabel(size: 12, weight: .regular)

    init(title: String, message: String, symbolName: String, color: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = DynamicIslandPalette.raised.cgColor
        layer?.borderColor = color.withAlphaComponent(0.38).cgColor
        layer?.borderWidth = 1
        symbolView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: title
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        )
        symbolView.contentTintColor = color
        titleField.stringValue = title
        titleField.alignment = .center
        messageField.stringValue = message
        messageField.textColor = DynamicIslandPalette.secondaryText
        messageField.alignment = .center
        messageField.lineBreakMode = .byWordWrapping
        messageField.maximumNumberOfLines = 2
        addSubview(symbolView)
        addSubview(titleField)
        addSubview(messageField)
        setAccessibilityLabel("\(title) \(message)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 500, height: 180)
    }

    override func layout() {
        super.layout()
        symbolView.frame = NSRect(x: bounds.midX - 20, y: 116, width: 40, height: 40)
        titleField.frame = NSRect(x: 20, y: 78, width: max(1, bounds.width - 40), height: 24)
        messageField.frame = NSRect(x: 36, y: 34, width: max(1, bounds.width - 72), height: 34)
    }
}

private final class DynamicIslandQuotaLabel: NSTextField {
    init(
        size: CGFloat,
        weight: NSFont.Weight,
        selectable: Bool = false
    ) {
        super.init(frame: .zero)
        isBezeled = false
        isEditable = false
        isSelectable = selectable
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 2
        textColor = DynamicIslandPalette.primaryText
        font = .systemFont(ofSize: size, weight: weight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
