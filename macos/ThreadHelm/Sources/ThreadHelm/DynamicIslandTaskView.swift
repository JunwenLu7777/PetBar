import AppKit
import Foundation

func resolvedSelectedTaskKey(
    previousKey: String?,
    preferredKey: String?,
    visibleItems: [TaskProgressItem]
) -> String? {
    let visibleKeys = Set(visibleItems.map(\.identityKey))
    if let previousKey, visibleKeys.contains(previousKey) {
        return previousKey
    }
    if let preferredKey, visibleKeys.contains(preferredKey) {
        return preferredKey
    }
    return visibleItems.first?.identityKey
}

func shortenedTaskIdentifier(_ value: String?) -> String? {
    guard let value else { return nil }
    let compact = value.filter { $0.isLetter || $0.isNumber }
    guard !compact.isEmpty else { return nil }
    return String(compact.suffix(4)).uppercased()
}

func taskProgressDurationText(for item: TaskProgressItem, now: Date) -> String {
    let endDate: Date
    switch item.kind {
    case .completed, .failed:
        endDate = item.updatedAt
    default:
        endDate = now
    }
    return taskElapsedText(from: item.startedAt, to: endDate)
}

func taskProgressStartAndDurationText(
    for item: TaskProgressItem,
    now: Date
) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    let started = formatter.string(from: item.startedAt)
    let duration = taskProgressDurationText(for: item, now: now)
    return "\(started) · \(duration)"
}

func dynamicIslandTaskEventRowHeight(
    text: String,
    availableWidth: CGFloat
) -> CGFloat {
    let font = NSFont.systemFont(ofSize: 12, weight: .regular)
    let textWidth = max(1, availableWidth - 92)
    let bounds = (text as NSString).boundingRect(
        with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: font]
    )
    return max(30, ceil(bounds.height) + 12)
}

final class DynamicIslandTaskViewController:
    NSViewController,
    NSTableViewDataSource,
    NSTableViewDelegate
{
    var onOpenTask: ((TaskProgressItem) -> OpenResult)?
    var onCopyWorkingDirectory: ((String) -> Bool)?
    var onSelectedTaskKeyChange: ((String?) -> Void)?

    private let leftPane = DynamicIslandCardView(
        cornerRadius: 10,
        backgroundColor: DynamicIslandPalette.surface
    )
    private let paneDivider = DynamicIslandDividerView()
    private let detailScrollView = NSScrollView()
    private let detailContentView = NSView()
    private let queueTitleField = DynamicIslandTaskLabel(
        size: 14,
        weight: .semibold
    )
    private let queueCountField = DynamicIslandTaskLabel(size: 12, weight: .medium)
    private let queueDivider = DynamicIslandDividerView()
    private let stateFilterControl = DynamicIslandSegmentedControl(
        labels: ["全部", "运行", "等待", "完成", "失败"]
    )
    private let tableScrollView = NSScrollView()
    private let tableView = NSTableView()
    private let emptyField = DynamicIslandTaskLabel(size: 13, weight: .medium)
    private let providerField = DynamicIslandTaskLabel(size: 11, weight: .medium)
    private let titleField = DynamicIslandTaskLabel(size: 19, weight: .semibold)
    private let stateSymbol = NSImageView()
    private let stateField = DynamicIslandTaskLabel(size: 13, weight: .medium)
    private let startedField = DynamicIslandTaskLabel(
        size: 12,
        weight: .regular,
        monospaced: true
    )
    private let elapsedField = DynamicIslandTaskLabel(
        size: 12,
        weight: .regular,
        monospaced: true
    )
    private let workingDirectoryField = DynamicIslandTaskLabel(
        size: 12,
        weight: .regular
    )
    private let detailHeaderDivider = DynamicIslandDividerView()
    private let activityTitleField = DynamicIslandTaskLabel(
        size: 12,
        weight: .semibold
    )
    private let activityCard = DynamicIslandCardView(
        cornerRadius: 9,
        backgroundColor: DynamicIslandPalette.raised
    )
    private let activityScrollView = NSScrollView()
    private let activityTextView = NSTextView()
    private let activityMetaField = DynamicIslandTaskLabel(
        size: 10.5,
        weight: .medium,
        monospaced: true
    )
    private let eventsTitleField = DynamicIslandTaskLabel(
        size: 12,
        weight: .semibold
    )
    private let eventsCard = DynamicIslandCardView(
        cornerRadius: 9,
        backgroundColor: DynamicIslandPalette.surface
    )
    private let eventsScrollView = NSScrollView()
    private let eventsTableView = NSTableView()
    private let identityField = DynamicIslandTaskLabel(size: 12, weight: .regular)
    private let footerDivider = DynamicIslandDividerView()
    private let openButton = DynamicIslandButton(
        title: "打开 Codex",
        style: .secondary,
        imageName: "arrow.up.forward.square"
    )
    private let copyButton = DynamicIslandButton(
        title: "复制路径",
        style: .secondary,
        imageName: "doc.on.doc"
    )
    private let hoverController = DynamicIslandTaskHoverController()

    private var collection = TaskProgressCollectionSnapshot(items: [])
    private var sourceFilter = TaskSourceFilter.all
    private var stateFilter = TaskStateFilter.all
    private var visibleItems: [TaskProgressItem] = []
    private var selectedTaskKey: String?
    private var selectedItem: TaskProgressItem?
    private var displayedEvents: [TaskActivityEvent] = []
    private var trackingArea: NSTrackingArea?
    private var copyFeedbackWorkItem: DispatchWorkItem?
    private var openFeedbackWorkItem: DispatchWorkItem?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 560))
        view.wantsLayer = true

        view.addSubview(leftPane)
        view.addSubview(paneDivider)
        view.addSubview(detailScrollView)
        leftPane.addSubview(queueTitleField)
        leftPane.addSubview(queueCountField)
        leftPane.addSubview(stateFilterControl)
        leftPane.addSubview(queueDivider)
        leftPane.addSubview(tableScrollView)
        leftPane.addSubview(emptyField)

        queueTitleField.stringValue = "任务队列"
        queueTitleField.setAccessibilityLabel("任务队列")
        queueCountField.alignment = .right
        queueCountField.textColor = DynamicIslandPalette.secondaryText
        stateFilterControl.onSelectionChange = { [weak self] index in
            self?.stateFilterChanged(index: index)
        }
        stateFilterControl.selectSegment(0)
        stateFilterControl.setAccessibilityLabel("任务状态筛选")
        stateFilterControl.setAccentColor(DynamicIslandPalette.green, forSegment: 0)
        stateFilterControl.setAccentColor(DynamicIslandPalette.green, forSegment: 1)
        stateFilterControl.setAccentColor(DynamicIslandPalette.amber, forSegment: 2)
        stateFilterControl.setAccentColor(DynamicIslandPalette.secondaryText, forSegment: 3)
        stateFilterControl.setAccentColor(DynamicIslandPalette.red, forSegment: 4)

        tableView.headerView = nil
        tableView.rowHeight = 66
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.selectionHighlightStyle = .none
        tableView.addTableColumn(NSTableColumn(identifier: .init("task")))
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.action = #selector(tableSelectionChanged)
        tableView.setAccessibilityLabel("完整任务列表")

        tableScrollView.documentView = tableView
        tableScrollView.hasVerticalScroller = true
        tableScrollView.drawsBackground = false
        tableView.backgroundColor = .clear

        detailScrollView.documentView = detailContentView
        detailScrollView.hasVerticalScroller = true
        detailScrollView.drawsBackground = false
        detailContentView.addSubview(providerField)
        detailContentView.addSubview(titleField)
        detailContentView.addSubview(stateSymbol)
        detailContentView.addSubview(stateField)
        detailContentView.addSubview(startedField)
        detailContentView.addSubview(elapsedField)
        detailContentView.addSubview(workingDirectoryField)
        detailContentView.addSubview(detailHeaderDivider)
        detailContentView.addSubview(activityTitleField)
        detailContentView.addSubview(activityCard)
        activityCard.addSubview(activityScrollView)
        detailContentView.addSubview(activityMetaField)
        detailContentView.addSubview(eventsTitleField)
        detailContentView.addSubview(eventsCard)
        eventsCard.addSubview(eventsScrollView)
        detailContentView.addSubview(identityField)
        detailContentView.addSubview(footerDivider)
        detailContentView.addSubview(openButton)
        detailContentView.addSubview(copyButton)

        eventsTableView.headerView = nil
        eventsTableView.selectionHighlightStyle = .none
        eventsTableView.intercellSpacing = NSSize(width: 0, height: 4)
        eventsTableView.addTableColumn(NSTableColumn(identifier: .init("event")))
        eventsTableView.delegate = self
        eventsTableView.dataSource = self
        eventsTableView.backgroundColor = .clear
        eventsTableView.setAccessibilityLabel("全部安全活动记录")
        let verticalScroller = NSScroller(frame: .zero)
        verticalScroller.controlSize = .small
        verticalScroller.knobStyle = .light
        eventsScrollView.verticalScroller = verticalScroller
        eventsScrollView.documentView = eventsTableView
        eventsScrollView.hasVerticalScroller = true
        eventsScrollView.autohidesScrollers = false
        eventsScrollView.scrollerStyle = .legacy
        eventsScrollView.drawsBackground = false

        emptyField.alignment = .center
        emptyField.stringValue = "没有匹配任务"
        emptyField.setAccessibilityLabel("没有匹配任务")

        eventsTitleField.stringValue = "最近事件 · 全部"
        eventsTitleField.setAccessibilityLabel("最近事件，全部活动记录")
        activityTitleField.stringValue = "当前活动"
        activityTitleField.setAccessibilityLabel("当前活动")
        activityTitleField.textColor = DynamicIslandPalette.secondaryText
        eventsTitleField.textColor = DynamicIslandPalette.secondaryText
        providerField.textColor = DynamicIslandPalette.secondaryText
        workingDirectoryField.textColor = DynamicIslandPalette.secondaryText
        identityField.textColor = DynamicIslandPalette.secondaryText
        activityMetaField.textColor = DynamicIslandPalette.tertiaryText
        configureActivityScrollView()
        openButton.target = self
        openButton.action = #selector(openSelectedTask)
        openButton.setAccessibilityLabel("打开当前任务")
        copyButton.target = self
        copyButton.action = #selector(copySelectedWorkingDirectory)
        copyButton.setAccessibilityLabel("复制工作目录")
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        leftPane.frame = NSRect(
            x: 0,
            y: 0,
            width: 316,
            height: view.bounds.height
        )
        paneDivider.frame = NSRect(x: 324, y: 8, width: 1, height: max(1, view.bounds.height - 16))
        detailScrollView.frame = NSRect(
            x: 336,
            y: 0,
            width: max(1, view.bounds.width - 336),
            height: view.bounds.height
        )
        queueTitleField.frame = NSRect(
            x: 14,
            y: leftPane.bounds.height - 30,
            width: 160,
            height: 20
        )
        queueCountField.frame = NSRect(
            x: leftPane.bounds.width - 84,
            y: leftPane.bounds.height - 29,
            width: 68,
            height: 18
        )
        stateFilterControl.frame = NSRect(
            x: 12,
            y: leftPane.bounds.height - 72,
            width: leftPane.bounds.width - 24,
            height: 32
        )
        queueDivider.frame = NSRect(
            x: 12,
            y: leftPane.bounds.height - 82,
            width: leftPane.bounds.width - 24,
            height: 1
        )
        tableScrollView.frame = NSRect(
            x: 8,
            y: 8,
            width: leftPane.bounds.width - 16,
            height: max(1, leftPane.bounds.height - 96)
        )
        emptyField.frame = tableScrollView.frame.insetBy(dx: 10, dy: 10)
        layoutDetail()
        refreshTrackingArea()
    }

    private func refreshTrackingArea() {
        if let trackingArea {
            tableView.removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: tableView.bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        tableView.addTrackingArea(area)
        trackingArea = area
    }

    override func mouseExited(with event: NSEvent) {
        hoverController.hide()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = tableView.convert(event.locationInWindow, from: nil)
        let row = tableView.row(at: point)
        guard row >= 0, visibleItems.indices.contains(row) else {
            hoverController.hide()
            return
        }
        let rowRect = tableView.rect(ofRow: row)
        let screenRect = tableView.window?.convertToScreen(
            tableView.convert(rowRect, to: nil)
        ) ?? rowRect
        hoverController.show(item: visibleItems[row], sourceRect: screenRect)
    }

    func apply(
        collection: TaskProgressCollectionSnapshot,
        sourceFilter: TaskSourceFilter,
        preferredTaskKey: String?
    ) {
        _ = view
        self.collection = collection
        self.sourceFilter = sourceFilter
        updateCounts()
        let previousKey = selectedTaskKey
        visibleItems = collection.filtered(source: sourceFilter, state: stateFilter)
        selectedTaskKey = resolvedSelectedTaskKey(
            previousKey: previousKey,
            preferredKey: preferredTaskKey,
            visibleItems: visibleItems
        )
        selectedItem = visibleItems.first { $0.identityKey == selectedTaskKey }
        tableView.reloadData()
        syncSelectionToTable()
        renderDetail()
        onSelectedTaskKeyChange?(selectedTaskKey)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === eventsTableView {
            return max(1, displayedEvents.count)
        }
        return visibleItems.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        if tableView === eventsTableView {
            guard displayedEvents.indices.contains(row) else {
                let label = DynamicIslandTaskLabel(size: 12, weight: .regular)
                label.stringValue = "暂无安全事件"
                label.textColor = DynamicIslandPalette.secondaryText
                label.setAccessibilityLabel("暂无安全事件")
                return label
            }
            let event = displayedEvents[row]
            return DynamicIslandTaskEventRowView(
                time: eventTimeFormatter.string(from: event.occurredAt),
                text: event.text,
                highlighted: row == displayedEvents.count - 1
            )
        }
        guard visibleItems.indices.contains(row) else { return nil }
        let cell = DynamicIslandTaskRowView()
        cell.apply(
            item: visibleItems[row],
            selected: visibleItems[row].identityKey == selectedTaskKey
        )
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard tableView === eventsTableView,
              displayedEvents.indices.contains(row)
        else { return tableView === eventsTableView ? 32 : tableView.rowHeight }
        return dynamicIslandTaskEventRowHeight(
            text: displayedEvents[row].text,
            availableWidth: max(1, eventsScrollView.contentSize.width)
        )
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelectedItemFromTable()
    }

    func tableView(
        _ tableView: NSTableView,
        shouldSelectRow row: Int
    ) -> Bool {
        tableView !== eventsTableView
    }

    @objc private func tableSelectionChanged() {
        updateSelectedItemFromTable()
    }

    private func stateFilterChanged(index: Int) {
        switch index {
        case 1: stateFilter = .running
        case 2: stateFilter = .waitingForInput
        case 3: stateFilter = .completed
        case 4: stateFilter = .failed
        default: stateFilter = .all
        }
        hoverController.hide()
        apply(
            collection: collection,
            sourceFilter: sourceFilter,
            preferredTaskKey: nil
        )
    }

    @objc private func openSelectedTask() {
        guard let selectedItem, selectedItem.canOpen else { return }
        guard let result = onOpenTask?(selectedItem) else { return }
        openFeedbackWorkItem?.cancel()
        openButton.setDisplayTitle(result.feedbackTitle)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let item = self.selectedItem else { return }
            self.openButton.setDisplayTitle(item.openButtonTitle)
        }
        openFeedbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: workItem)
    }

    @objc private func copySelectedWorkingDirectory() {
        guard let path = copyPathForSelfTest() else { return }
        guard onCopyWorkingDirectory?(path) == true else { return }
        copyButton.setDisplayTitle("已复制")
        copyFeedbackWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.copyButton.setDisplayTitle("复制路径")
        }
        copyFeedbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
    }

    private func updateSelectedItemFromTable() {
        let row = tableView.selectedRow
        guard row >= 0, visibleItems.indices.contains(row) else { return }
        selectedItem = visibleItems[row]
        selectedTaskKey = selectedItem?.identityKey
        hoverController.hide()
        renderDetail()
        tableView.reloadData()
        onSelectedTaskKeyChange?(selectedTaskKey)
    }

    private func syncSelectionToTable() {
        guard let selectedTaskKey,
              let row = visibleItems.firstIndex(where: {
                  $0.identityKey == selectedTaskKey
              })
        else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func updateCounts() {
        let filteredBySource = TaskProgressCollectionSnapshot(
            items: collection.filtered(source: sourceFilter, state: .all)
        )
        let labels: [(String, TaskStateFilter)] = [
            ("全部", .all),
            ("运行", .running),
            ("等待", .waitingForInput),
            ("完成", .completed),
            ("失败", .failed),
        ]
        for (index, entry) in labels.enumerated() {
            let count = filteredBySource.filtered(
                source: .all,
                state: entry.1
            ).count
            stateFilterControl.setLabel(
                "  \(entry.0) \(count)",
                forSegment: index
            )
        }
        queueCountField.stringValue = "\(filteredBySource.items.count) 项"
        stateFilterControl.selectSegment(segmentIndex(for: stateFilter))
        stateFilterControl.setAccessibilityValue(
            labels.map {
                "\($0.0) \(filteredBySource.filtered(source: .all, state: $0.1).count)"
            }.joined(separator: "，")
        )
    }

    private func segmentIndex(for filter: TaskStateFilter) -> Int {
        switch filter {
        case .all: return 0
        case .running: return 1
        case .waitingForInput: return 2
        case .completed: return 3
        case .failed: return 4
        }
    }

    private func renderDetail() {
        emptyField.isHidden = !visibleItems.isEmpty
        tableScrollView.isHidden = visibleItems.isEmpty
        guard let item = selectedItem else {
            providerField.stringValue = "ThreadHelm"
            titleField.stringValue = "没有匹配任务"
            stateField.stringValue = "无任务"
            startedField.stringValue = ""
            elapsedField.stringValue = ""
            workingDirectoryField.stringValue = "工作目录不可用"
            renderCurrentActivity("当前没有符合筛选条件的任务")
            activityMetaField.stringValue = "0 条安全事件"
            identityField.stringValue = ""
            stateSymbol.image = NSImage(
                systemSymbolName: "circle",
                accessibilityDescription: "无任务"
            )
            openButton.isEnabled = false
            copyButton.isEnabled = false
            renderEvents([])
            view.needsLayout = true
            return
        }
        providerField.stringValue = "\(providerName(for: item.source)) · ThreadHelm"
        titleField.stringValue = item.title
        stateField.stringValue = item.statusText
        startedField.stringValue = "开始 \(eventTimeFormatter.string(from: item.startedAt))"
        let durationText = taskProgressDurationText(
            for: item,
            now: dynamicIslandCurrentDate()
        )
        elapsedField.stringValue = "持续 \(durationText)"
        workingDirectoryField.stringValue = copyPathForSelfTest()
            ?? "工作目录不可用"
        let currentActivity = (item.events.last?.text ?? item.activityText)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        renderCurrentActivity(
            currentActivity.flatMap { $0.isEmpty ? nil : $0 }
                ?? "暂无当前活动"
        )
        activityMetaField.stringValue = "\(item.events.count) 条安全事件 · 更新 \(eventTimeFormatter.string(from: item.updatedAt))"
        identityField.stringValue = secondaryIdentityText(for: item) ?? ""
        stateSymbol.image = NSImage(
            systemSymbolName: taskProgressSymbolName(for: item.kind),
            accessibilityDescription: item.statusText
        )
        stateSymbol.contentTintColor = tintColor(for: item.kind)
        openButton.setDisplayTitle(item.openButtonTitle)
        openButton.isEnabled = item.canOpen
        copyButton.isEnabled = copyPathForSelfTest() != nil
        copyButton.setDisplayTitle("复制路径")
        renderEvents(item.events)
        updateDetailAccessibility()
        view.needsLayout = true
    }

    private func layoutDetail() {
        let width = max(1, detailScrollView.bounds.width)
        let contentHeight = max(470, detailScrollView.bounds.height)
        detailContentView.frame = NSRect(
            x: 0,
            y: 0,
            width: width,
            height: contentHeight
        )
        let inset: CGFloat = 16
        let fieldWidth = max(1, width - inset * 2)
        providerField.frame = NSRect(
            x: inset,
            y: contentHeight - 27,
            width: fieldWidth,
            height: 16
        )
        titleField.frame = NSRect(
            x: inset,
            y: contentHeight - 58,
            width: fieldWidth - 138,
            height: 25
        )
        stateSymbol.frame = NSRect(
            x: width - 130,
            y: contentHeight - 55,
            width: 15,
            height: 15
        )
        stateField.frame = NSRect(
            x: width - 108,
            y: contentHeight - 58,
            width: 92,
            height: 20
        )
        startedField.frame = NSRect(
            x: width - 260,
            y: contentHeight - 88,
            width: 120,
            height: 20
        )
        startedField.alignment = .right
        elapsedField.frame = NSRect(
            x: width - 132,
            y: contentHeight - 88,
            width: 116,
            height: 20
        )
        elapsedField.alignment = .right
        workingDirectoryField.frame = NSRect(
            x: inset,
            y: contentHeight - 90,
            width: fieldWidth - 250,
            height: 20
        )
        detailHeaderDivider.frame = NSRect(
            x: inset,
            y: contentHeight - 108,
            width: fieldWidth,
            height: 1
        )
        activityTitleField.frame = NSRect(
            x: inset,
            y: contentHeight - 134,
            width: fieldWidth,
            height: 18
        )
        activityCard.frame = NSRect(
            x: inset,
            y: contentHeight - 218,
            width: fieldWidth,
            height: 72
        )
        activityScrollView.frame = NSRect(
            x: 12,
            y: 26,
            width: activityCard.bounds.width - 24,
            height: 34
        )
        layoutActivityTextView()
        activityMetaField.frame = NSRect(
            x: activityCard.frame.minX + 13,
            y: activityCard.frame.minY + 8,
            width: activityCard.frame.width - 26,
            height: 16
        )
        eventsTitleField.frame = NSRect(
            x: inset,
            y: contentHeight - 246,
            width: fieldWidth,
            height: 18
        )
        eventsCard.frame = NSRect(
            x: inset,
            y: 64,
            width: fieldWidth,
            height: max(96, contentHeight - 320)
        )
        eventsScrollView.frame = eventsCard.bounds.insetBy(dx: 10, dy: 10)
        layoutEventsTable()
        showEventsScroller()
        footerDivider.frame = NSRect(x: inset, y: 52, width: fieldWidth, height: 1)
        openButton.frame = NSRect(x: inset, y: 10, width: 112, height: 32)
        copyButton.frame = NSRect(x: inset + 126, y: 10, width: 100, height: 32)
        identityField.frame = NSRect(
            x: max(inset + 232, width - 132),
            y: 16,
            width: 116,
            height: 20
        )
        identityField.alignment = .right
    }

    private func renderEvents(_ events: [TaskActivityEvent]) {
        displayedEvents = events
        eventsTableView.reloadData()
        layoutEventsTable()
        showEventsScroller()
        if let latestRow = displayedEvents.indices.last {
            eventsTableView.scrollRowToVisible(latestRow)
            eventsScrollView.reflectScrolledClipView(eventsScrollView.contentView)
        }
    }

    private func configureActivityScrollView() {
        activityTextView.isEditable = false
        activityTextView.isSelectable = true
        activityTextView.drawsBackground = false
        activityTextView.textColor = DynamicIslandPalette.primaryText
        activityTextView.font = .systemFont(ofSize: 13, weight: .regular)
        activityTextView.textContainerInset = .zero
        activityTextView.textContainer?.lineFragmentPadding = 0
        activityTextView.textContainer?.lineBreakMode = .byWordWrapping
        activityTextView.textContainer?.maximumNumberOfLines = 0
        activityTextView.textContainer?.widthTracksTextView = true
        activityTextView.isHorizontallyResizable = false
        activityTextView.isVerticallyResizable = true
        activityTextView.autoresizingMask = [.width]
        activityTextView.setAccessibilityLabel("当前活动完整内容")

        let verticalScroller = NSScroller(frame: .zero)
        verticalScroller.controlSize = .small
        verticalScroller.knobStyle = .light
        activityScrollView.verticalScroller = verticalScroller
        activityScrollView.documentView = activityTextView
        activityScrollView.hasVerticalScroller = true
        activityScrollView.hasHorizontalScroller = false
        activityScrollView.autohidesScrollers = false
        activityScrollView.scrollerStyle = .legacy
        activityScrollView.drawsBackground = false
        activityScrollView.borderType = .noBorder
        activityScrollView.setAccessibilityLabel("当前活动，可滚动查看完整内容")
    }

    private func renderCurrentActivity(_ text: String) {
        activityTextView.string = text
        layoutActivityTextView()
        activityScrollView.contentView.scroll(to: .zero)
        activityScrollView.reflectScrolledClipView(activityScrollView.contentView)
    }

    private func layoutActivityTextView() {
        let contentSize = activityScrollView.contentSize
        let width = max(1, contentSize.width)
        activityTextView.textContainer?.containerSize = NSSize(
            width: width,
            height: .greatestFiniteMagnitude
        )
        activityTextView.setFrameSize(NSSize(
            width: width,
            height: max(1, contentSize.height)
        ))
        guard let layoutManager = activityTextView.layoutManager,
              let textContainer = activityTextView.textContainer
        else { return }
        layoutManager.ensureLayout(for: textContainer)
        let textHeight = ceil(layoutManager.usedRect(for: textContainer).height)
        activityTextView.setFrameSize(NSSize(
            width: width,
            height: max(contentSize.height, textHeight)
        ))
        activityScrollView.tile()
        activityScrollView.verticalScroller?.isHidden = false
        activityScrollView.verticalScroller?.alphaValue = 1
    }

    private func layoutEventsTable() {
        let width = max(1, eventsScrollView.contentSize.width)
        eventsTableView.tableColumns.first?.width = width
        let rowCount = max(1, displayedEvents.count)
        let rowHeights: [CGFloat]
        if displayedEvents.isEmpty {
            rowHeights = [32]
        } else {
            rowHeights = displayedEvents.map {
                dynamicIslandTaskEventRowHeight(
                    text: $0.text,
                    availableWidth: width
                )
            }
        }
        let totalHeight = rowHeights.reduce(0, +)
            + CGFloat(max(0, rowCount - 1)) * eventsTableView.intercellSpacing.height
        eventsTableView.frame = NSRect(
            x: 0,
            y: 0,
            width: width,
            height: max(eventsScrollView.contentSize.height, totalHeight)
        )
        eventsTableView.noteHeightOfRows(
            withIndexesChanged: IndexSet(integersIn: 0..<rowCount)
        )
    }

    private func showEventsScroller() {
        eventsScrollView.tile()
        eventsScrollView.verticalScroller?.isHidden = false
        eventsScrollView.verticalScroller?.alphaValue = 1
    }

    private func updateDetailAccessibility() {
        let value = [
            providerField.stringValue,
            titleField.stringValue,
            stateField.stringValue,
            startedField.stringValue,
            elapsedField.stringValue,
            workingDirectoryField.stringValue,
            activityTextView.string,
            activityMetaField.stringValue,
            "最近事件",
        ].joined(separator: "，")
        detailContentView.setAccessibilityLabel("任务详情")
        detailContentView.setAccessibilityValue(value)
    }

    private func providerName(for source: TaskSource) -> String {
        agentPresentation(for: source).displayName
    }

    private func tintColor(for kind: TaskProgressKind) -> NSColor {
        switch kind {
        case .running, .completed:
            return DynamicIslandPalette.green
        case .waitingForInput:
            return DynamicIslandPalette.amber
        case .failed:
            return DynamicIslandPalette.red
        case .reading, .idle:
            return DynamicIslandPalette.secondaryText
        }
    }

    private func secondaryIdentityText(for item: TaskProgressItem) -> String? {
        if let thread = shortenedTaskIdentifier(item.threadID) {
            return "Thread \(thread)"
        }
        if let session = shortenedTaskIdentifier(item.sessionID) {
            return "Session \(session)"
        }
        return nil
    }

    private var eventTimeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }

    func visibleTaskKeysForSelfTest() -> [String] {
        _ = view
        return visibleItems.map(\.identityKey)
    }

    func selectedTaskKeyForSelfTest() -> String? {
        _ = view
        return selectedTaskKey
    }

    func setStateFilterForSelfTest(_ filter: TaskStateFilter) {
        _ = view
        stateFilter = filter
        stateFilterControl.selectSegment(segmentIndex(for: filter))
        apply(
            collection: collection,
            sourceFilter: sourceFilter,
            preferredTaskKey: nil
        )
    }

    func accessibilitySnapshotForSelfTest() -> String {
        _ = view
        return [
            stateFilterControl.accessibilityValue() as? String,
            emptyField.stringValue,
            detailContentView.accessibilityValue() as? String,
            openButton.accessibilityLabel(),
            copyButton.accessibilityLabel(),
        ].compactMap { $0 }.joined(separator: " ")
    }

    func detailEventTextsForSelfTest() -> [String] {
        selectedItem?.events.map(\.text) ?? []
    }

    func currentActivityTextForSelfTest() -> String {
        _ = view
        return activityTextView.string
    }

    func activityScrollerIsEnabledForSelfTest() -> Bool {
        _ = view
        view.layoutSubtreeIfNeeded()
        return activityScrollView.hasVerticalScroller
            && !activityScrollView.autohidesScrollers
            && activityScrollView.scrollerStyle == .legacy
            && activityScrollView.documentView === activityTextView
            && activityTextView.textContainer?.maximumNumberOfLines == 0
            && activityTextView.frame.height > activityScrollView.contentSize.height
    }

    func eventsScrollerIsEnabledForSelfTest() -> Bool {
        _ = view
        return eventsScrollView.hasVerticalScroller
            && !eventsScrollView.autohidesScrollers
            && eventsScrollView.scrollerStyle == .legacy
            && eventsTableView.numberOfRows == max(1, displayedEvents.count)
    }

    func visibleProviderIconsAreConcreteForSelfTest() -> Bool {
        _ = view
        view.layoutSubtreeIfNeeded()
        return visibleItems.indices.allSatisfy { row in
            guard let cell = tableView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: true
            ) as? DynamicIslandTaskRowView else { return false }
            return cell.providerIconIsConcreteForSelfTest
        }
    }

    func footerButtonGapForSelfTest() -> CGFloat {
        _ = view
        view.layoutSubtreeIfNeeded()
        return copyButton.frame.minX - openButton.frame.maxX
    }

    func copyPathForSelfTest() -> String? {
        selectedItem?.workingDirectory.flatMap(normalizedAbsolutePath)
    }

    func openButtonTitleForSelfTest() -> String {
        _ = view
        return openButton.title
    }

    func showHoverForSelfTest(item: TaskProgressItem) {
        hoverController.show(
            item: item,
            sourceRect: NSRect(x: 0, y: 0, width: 1, height: 1)
        )
    }

    func hideHoverForSelfTest() {
        hoverController.hide()
    }

    func hoverEventTextsForSelfTest() -> [String] {
        hoverController.eventTextsForSelfTest()
    }

    func hoverVisibleForSelfTest() -> Bool {
        hoverController.isVisibleForSelfTest()
    }

    func performOpenSelectedTaskForSelfTest() {
        openSelectedTask()
    }
}

final class DynamicIslandTaskHoverController {
    private let panel: NSPanel
    private let titleField = DynamicIslandTaskLabel(size: 13, weight: .semibold)
    private let stack = NSStackView()
    private var currentEventTexts: [String] = []

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 96),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let content = NSView(frame: panel.contentView?.bounds ?? .zero)
        content.wantsLayer = true
        content.layer?.backgroundColor = DynamicIslandPalette.raised.cgColor
        content.layer?.cornerRadius = 8
        content.layer?.borderWidth = 1
        content.layer?.borderColor = DynamicIslandPalette.hairline.cgColor
        panel.contentView = content
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        content.addSubview(titleField)
        content.addSubview(stack)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
    }

    func show(item: TaskProgressItem, sourceRect: NSRect) {
        titleField.stringValue = item.title
        currentEventTexts = Array(item.events.suffix(3)).map(\.text)
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let lines = currentEventTexts.isEmpty ? ["暂无安全事件"] : currentEventTexts
        for text in lines {
            let label = DynamicIslandTaskLabel(size: 12, weight: .regular)
            label.stringValue = text
            label.setAccessibilityLabel(text)
            stack.addArrangedSubview(label)
        }
        layout()
        panel.setFrameOrigin(clampedOrigin(beside: sourceRect))
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func eventTextsForSelfTest() -> [String] {
        currentEventTexts
    }

    func isVisibleForSelfTest() -> Bool {
        panel.isVisible
    }

    private func layout() {
        guard let content = panel.contentView else { return }
        titleField.frame = NSRect(x: 12, y: 68, width: 336, height: 18)
        stack.frame = NSRect(x: 12, y: 12, width: 336, height: 52)
        content.frame = NSRect(origin: .zero, size: panel.frame.size)
    }

    private func clampedOrigin(beside sourceRect: NSRect) -> NSPoint {
        let visibleFrame = NSScreen.screens.first(where: {
            $0.visibleFrame.intersects(sourceRect)
        })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_024, height: 768)
        let size = panel.frame.size
        var origin = NSPoint(x: sourceRect.maxX + 12, y: sourceRect.midY - size.height / 2)
        if origin.x + size.width > visibleFrame.maxX {
            origin.x = sourceRect.minX - size.width - 12
        }
        origin.x = min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - size.width)
        origin.y = min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - size.height)
        return origin
    }
}

private final class DynamicIslandTaskRowView: NSTableCellView {
    private let selectionAccent = NSView()
    private let providerBadge = NSView()
    private let providerIconView = NSImageView()
    private let statusDot = NSView()
    private let providerField = DynamicIslandTaskLabel(size: 12, weight: .medium)
    private let titleField = DynamicIslandTaskLabel(size: 13, weight: .semibold)
    private let statusField = DynamicIslandTaskLabel(size: 12, weight: .regular)
    private let timeField = DynamicIslandTaskLabel(
        size: 12,
        weight: .regular,
        monospaced: true
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        providerBadge.wantsLayer = true
        providerBadge.layer?.cornerRadius = 17
        providerBadge.layer?.borderWidth = 1
        providerBadge.layer?.borderColor = DynamicIslandPalette.strongHairline.cgColor
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        selectionAccent.wantsLayer = true
        for subview in [
            selectionAccent,
            providerBadge,
            providerIconView,
            statusDot,
            providerField,
            titleField,
            statusField,
            timeField,
        ] {
            addSubview(subview)
        }
        providerIconView.imageScaling = .scaleProportionallyDown
        providerIconView.setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        selectionAccent.frame = NSRect(x: 0, y: 0, width: 3, height: bounds.height)
        providerBadge.frame = NSRect(x: 10, y: 16, width: 34, height: 34)
        providerIconView.frame = NSRect(x: 17, y: 23, width: 20, height: 20)
        providerField.frame = NSRect(x: 54, y: 38, width: 90, height: 16)
        titleField.frame = NSRect(x: 54, y: 17, width: bounds.width - 152, height: 20)
        statusDot.frame = NSRect(x: bounds.width - 20, y: 40, width: 8, height: 8)
        statusField.frame = NSRect(x: bounds.width - 100, y: 35, width: 72, height: 17)
        timeField.frame = NSRect(x: bounds.width - 100, y: 15, width: 88, height: 17)
        statusField.alignment = .right
        timeField.alignment = .right
    }

    func apply(item: TaskProgressItem, selected: Bool) {
        let provider = agentPresentation(for: item.source)
        let tint: NSColor
        switch item.kind {
        case .running, .completed:
            tint = DynamicIslandPalette.green
        case .waitingForInput:
            tint = DynamicIslandPalette.amber
        case .failed:
            tint = DynamicIslandPalette.red
        case .reading, .idle:
            tint = DynamicIslandPalette.secondaryText
        }
        selectionAccent.layer?.backgroundColor = tint.cgColor
        selectionAccent.isHidden = !selected
        layer?.backgroundColor = selected
            ? tint.withAlphaComponent(0.13).cgColor
            : NSColor.clear.cgColor
        layer?.borderColor = selected
            ? tint.withAlphaComponent(0.42).cgColor
            : NSColor.clear.cgColor
        statusDot.layer?.backgroundColor = tint.cgColor
        providerBadge.layer?.backgroundColor = provider.brandColor.color
            .withAlphaComponent(0.16).cgColor
        providerBadge.layer?.borderColor = provider.brandColor.color
            .withAlphaComponent(0.76).cgColor
        providerIconView.image = agentIconImage(for: item.source)
        providerIconView.contentTintColor = provider.brandColor.color
        providerField.stringValue = provider.shortName
        providerField.textColor = DynamicIslandPalette.secondaryText
        titleField.stringValue = item.title
        statusField.stringValue = item.statusText
        statusField.textColor = tint
        timeField.stringValue = taskProgressStartAndDurationText(
            for: item,
            now: dynamicIslandCurrentDate()
        )
        setAccessibilityLabel(
            "\(providerField.stringValue)，\(item.title)，\(item.statusText)"
        )
        setAccessibilityValue(timeField.stringValue)
    }

    var providerIconIsConcreteForSelfTest: Bool {
        guard let image = providerIconView.image else { return false }
        return !(image.accessibilityDescription ?? "").isEmpty
    }
}

private final class DynamicIslandTaskEventRowView: NSView {
    private let dot = NSView()
    private let timeField = DynamicIslandTaskLabel(
        size: 11,
        weight: .medium,
        monospaced: true
    )
    private let textField = DynamicIslandTaskLabel(size: 12, weight: .regular)

    init(time: String, text: String, highlighted: Bool) {
        super.init(frame: .zero)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = (highlighted
            ? DynamicIslandPalette.green
            : DynamicIslandPalette.secondaryText).cgColor
        timeField.stringValue = time
        timeField.textColor = DynamicIslandPalette.secondaryText
        textField.stringValue = text
        textField.lineBreakMode = .byWordWrapping
        textField.maximumNumberOfLines = 0
        textField.cell?.wraps = true
        textField.cell?.usesSingleLineMode = false
        addSubview(dot)
        addSubview(timeField)
        addSubview(textField)
        setAccessibilityLabel("\(time) \(text)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: 360,
            height: dynamicIslandTaskEventRowHeight(
                text: textField.stringValue,
                availableWidth: max(1, bounds.width)
            )
        )
    }

    override func layout() {
        super.layout()
        let top = max(6, bounds.height - 22)
        dot.frame = NSRect(x: 0, y: top + 5, width: 7, height: 7)
        timeField.frame = NSRect(x: 16, y: top, width: 62, height: 18)
        textField.frame = NSRect(
            x: 84,
            y: 6,
            width: max(1, bounds.width - 84),
            height: max(18, bounds.height - 12)
        )
    }
}

private final class DynamicIslandTaskLabel: NSTextField {
    init(size: CGFloat, weight: NSFont.Weight, monospaced: Bool = false) {
        super.init(frame: .zero)
        isBezeled = false
        isEditable = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        textColor = DynamicIslandPalette.primaryText
        font = monospaced
            ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
            : .systemFont(ofSize: size, weight: weight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
