import AppKit
import Foundation

private struct DynamicIslandDisplayedActivityEvent: Equatable {
    let kind: TaskActivityEventKind
    let occurredAt: Date
    let sourceOrder: UInt64
    let text: String
}

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

func dynamicIslandTint(for kind: TaskProgressKind) -> NSColor {
    switch kind {
    case .running:
        return DynamicIslandPalette.green
    case .waitingForInput:
        return DynamicIslandPalette.amber
    case .failed:
        return DynamicIslandPalette.red
    case .completed, .reading, .idle:
        return DynamicIslandPalette.secondaryText
    }
}

struct CursorListeningEmptyFact: Equatable {
    let label: String
    let value: String
}

struct CursorListeningEmptyPresentation: Equatable {
    let eyebrow: String
    let title: String
    let body: String
    let meta: String
    let facts: [CursorListeningEmptyFact]
}

func cursorListeningEmptyPresentation(
    sourceFilter: TaskSourceFilter,
    sourceItemCount: Int,
    cursorStatus: AgentRuntimeStatus?,
    totalTaskCount: Int = 0
) -> CursorListeningEmptyPresentation? {
    guard sourceFilter == .cursor, sourceItemCount == 0 else { return nil }
    guard let cursorStatus else { return nil }
    let eyebrow: String
    let body: String
    let statusValue: String
    let hookValue: String
    switch cursorStatus.integrationStatus {
    case .notInstalled:
        eyebrow = "Cursor · 监听未安装"
        body = "ThreadHelm 还没装上 Cursor 生命周期钩子，所以这边一直是 0。"
        statusValue = "未安装"
        hookValue = "~/.cursor/hooks.json 为空"
    case .disabled:
        eyebrow = "Cursor · 监听已停用"
        body = "Cursor 钩子还在，但 ThreadHelm 这条被停用了，所以执行不会出现在这里。"
        statusValue = "已停用"
        hookValue = "钩子仍在，但已停用"
    case .needsRepair:
        eyebrow = "Cursor · 监听需修复"
        body = "Cursor 钩子配置不完整，ThreadHelm 现在听不到执行。"
        statusValue = "需修复"
        hookValue = "配置不完整"
    case .checkFailed:
        eyebrow = "Cursor · 集成状态未能读取"
        body = "ThreadHelm 这次没能读到 Cursor 钩子配置，所以无法判断监听是否就位。"
        statusValue = "未能读取"
        hookValue = "配置未被读取"
    case .unsupportedVersion:
        eyebrow = "Cursor · 版本不兼容"
        body = "当前 Cursor 版本还没纳入验证，安装会被跳过，所以这边一直是 0。"
        statusValue = "版本不兼容"
        hookValue = "安装被跳过"
    case .none:
        guard cursorStatus.discovery.compatibility == .unvalidated else {
            return nil
        }
        eyebrow = "Cursor · 监听未安装"
        body = "ThreadHelm 还没装上 Cursor 生命周期钩子，所以这边一直是 0。"
        statusValue = "未安装"
        hookValue = "~/.cursor/hooks.json 为空"
    case .installed, .notManaged:
        return nil
    }
    var detail = body
    let localDesktop = cursorStatus.discovery.versionComponents.first {
        $0.key == "desktop"
    }?.value
    let testedDesktop = builtInAgentValidationProfiles()[.cursor]?
        .testedVersionComponents.first { $0.key == "desktop" }?.value
    if cursorStatus.discovery.compatibility == .unvalidated,
       let localDesktop,
       let testedDesktop,
       localDesktop != testedDesktop
    {
        detail += "本机 Cursor 是 \(localDesktop)，已超出当前验证版本 \(testedDesktop)，安装会被跳过。"
    }
    let taskCountText = totalTaskCount > 0
        ? "所以「任务 \(totalTaskCount)」不是 Cursor"
        : "所以顶栏任务数不是 Cursor"
    return CursorListeningEmptyPresentation(
        eyebrow: eyebrow,
        title: "还听不到 Cursor 的执行",
        body: detail,
        meta: "集成状态 \(statusValue) · \(hookValue)",
        facts: [
            CursorListeningEmptyFact(label: "集成状态", value: statusValue),
            CursorListeningEmptyFact(label: "钩子文件", value: hookValue),
            CursorListeningEmptyFact(
                label: "Codex",
                value: "仍可从本地 session 看到（\(taskCountText)）"
            ),
        ]
    )
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

private enum DynamicIslandTaskQueueRow {
    case task(TaskProgressItem)

    var item: TaskProgressItem? {
        switch self {
        case .task(let item):
            return item
        }
    }
}

final class DynamicIslandTaskViewController:
    NSViewController,
    NSTableViewDataSource,
    NSTableViewDelegate
{
    var onOpenTask: ((TaskProgressItem) -> OpenResult)?
    var onCopyWorkingDirectory: ((String) -> Bool)?
    var onSelectedTaskKeyChange: ((String?) -> Void)?
    var onInspectAgents: (() -> Void)?
    var onDeferCursorSetup: (() -> Void)?

    private let leftPane = DynamicIslandCardView(
        cornerRadius: 0,
        backgroundColor: NSColor.clear,
        borderColor: NSColor.clear
    )
    private let paneDivider = DynamicIslandDividerView()
    private let detailScrollView = NSScrollView()
    private let detailContentView = NSView()
    private let queueTitleField = DynamicIslandTaskLabel(
        size: 15,
        weight: .semibold
    )
    private let queueCountField = DynamicIslandTaskLabel(size: 12, weight: .medium)
    private let queueDivider = DynamicIslandDividerView()
    private let stateFilterList = DynamicIslandStateFilterList()
    private let tableScrollView = NSScrollView()
    private let tableView = NSTableView()
    private let emptyField = DynamicIslandTaskLabel(size: 13, weight: .medium)
    private let providerField = DynamicIslandTaskLabel(size: 12, weight: .medium)
    private let titleField = DynamicIslandTaskLabel(size: 20, weight: .semibold)
    private let stateBadge = DynamicIslandCardView(
        cornerRadius: 6,
        backgroundColor: NSColor.clear,
        borderColor: DynamicIslandPalette.green
    )
    private let stateField = DynamicIslandTaskLabel(size: 12, weight: .medium)
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
    private let openResultField = DynamicIslandTaskLabel(
        size: 12,
        weight: .regular
    )
    private let detailHeaderDivider = DynamicIslandDividerView()
    private let eventsTitleField = DynamicIslandTaskLabel(
        size: 12,
        weight: .semibold
    )
    private let eventsCard = DynamicIslandCardView(
        cornerRadius: 12,
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
    private let deferButton = DynamicIslandButton(
        title: "稍后再装",
        style: .bare
    )
    private let emptyDetailContainer = NSView()
    private let emptyEyebrowField = DynamicIslandTaskLabel(size: 13, weight: .medium)
    private let emptyTitleField = DynamicIslandTaskLabel(size: 22, weight: .semibold)
    private let emptyBodyField = DynamicIslandTaskLabel(size: 13, weight: .regular)
    private let emptyFactCard = DynamicIslandCardView(
        cornerRadius: 12,
        backgroundColor: DynamicIslandPalette.raised
    )
    private var emptyFactRows: [DynamicIslandEmptyFactRow] = []
    private let hoverController = DynamicIslandTaskHoverController()

    private var collection = TaskProgressCollectionSnapshot(items: [])
    private var sourceFilter = TaskSourceFilter.all
    private var stateFilter = TaskStateFilter.all
    private var agentStatuses: [AgentRuntimeStatus] = []
    private var taskOpenEvidence: [String: TaskOpenEvidence] = [:]
    private var visibleSections: [TaskQueueSection] = []
    private var queueRows: [DynamicIslandTaskQueueRow] = []
    private var visibleItems: [TaskProgressItem] = []
    private var selectedTaskKey: String?
    private var selectedItem: TaskProgressItem?
    private var displayedEvents: [DynamicIslandDisplayedActivityEvent] = []
    private var trackingArea: NSTrackingArea?
    private var copyFeedbackWorkItem: DispatchWorkItem?
    private var openFeedbackWorkItem: DispatchWorkItem?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 560))
        view.wantsLayer = true

        view.addSubview(leftPane)
        view.addSubview(paneDivider)
        view.addSubview(detailScrollView)
        leftPane.setSurface(
            backgroundColor: NSColor.clear,
            borderColor: NSColor.clear,
            borderWidth: 0
        )
        leftPane.addSubview(queueTitleField)
        leftPane.addSubview(queueCountField)
        leftPane.addSubview(stateFilterList)
        leftPane.addSubview(queueDivider)
        leftPane.addSubview(tableScrollView)
        leftPane.addSubview(emptyField)

        queueTitleField.stringValue = "任务队列"
        queueTitleField.setAccessibilityLabel("任务队列")
        queueCountField.alignment = .right
        queueCountField.textColor = DynamicIslandPalette.secondaryText
        stateFilterList.onSelectionChange = { [weak self] index in
            self?.stateFilterChanged(index: index)
        }
        stateFilterList.selectIndex(0)
        stateFilterList.setAccessibilityLabel("任务状态筛选")

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
        detailContentView.addSubview(stateBadge)
        stateBadge.addSubview(stateField)
        detailContentView.addSubview(startedField)
        detailContentView.addSubview(elapsedField)
        detailContentView.addSubview(workingDirectoryField)
        detailContentView.addSubview(openResultField)
        detailContentView.addSubview(detailHeaderDivider)
        detailContentView.addSubview(eventsTitleField)
        detailContentView.addSubview(eventsCard)
        eventsCard.addSubview(eventsScrollView)
        detailContentView.addSubview(identityField)
        detailContentView.addSubview(footerDivider)
        detailContentView.addSubview(openButton)
        detailContentView.addSubview(copyButton)
        detailContentView.addSubview(deferButton)
        detailContentView.addSubview(emptyDetailContainer)
        emptyDetailContainer.addSubview(emptyEyebrowField)
        emptyDetailContainer.addSubview(emptyTitleField)
        emptyDetailContainer.addSubview(emptyBodyField)
        emptyDetailContainer.addSubview(emptyFactCard)
        emptyFactRows = (0..<3).map { _ in DynamicIslandEmptyFactRow() }
        for row in emptyFactRows {
            emptyFactCard.addSubview(row)
        }

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
        emptyField.textColor = DynamicIslandPalette.tertiaryText

        emptyDetailContainer.isHidden = true
        emptyEyebrowField.textColor = DynamicIslandPalette.amber
        emptyTitleField.maximumNumberOfLines = 2
        emptyBodyField.textColor = DynamicIslandPalette.secondaryText
        emptyBodyField.lineBreakMode = .byWordWrapping
        emptyBodyField.maximumNumberOfLines = 0
        emptyBodyField.cell?.wraps = true
        emptyBodyField.cell?.usesSingleLineMode = false
        deferButton.target = self
        deferButton.action = #selector(deferCursorSetup)
        deferButton.setAccessibilityLabel("稍后再装")
        deferButton.isHidden = true

        eventsTitleField.stringValue = "最近事件"
        eventsTitleField.setAccessibilityLabel("最近事件，全部活动记录")
        eventsTitleField.textColor = DynamicIslandPalette.secondaryText
        providerField.textColor = DynamicIslandPalette.secondaryText
        workingDirectoryField.textColor = DynamicIslandPalette.secondaryText
        openResultField.textColor = DynamicIslandPalette.secondaryText
        identityField.textColor = DynamicIslandPalette.secondaryText
        openButton.target = self
        openButton.action = #selector(openSelectedTask)
        openButton.setAccessibilityLabel("打开当前任务")
        copyButton.target = self
        copyButton.action = #selector(copySelectedWorkingDirectory)
        copyButton.setAccessibilityLabel("复制工作目录")
        copyButton.imageHugsTitle = true
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        leftPane.frame = NSRect(
            x: 0,
            y: 0,
            width: sidebarWidth,
            height: view.bounds.height
        )
        paneDivider.frame = NSRect(
            x: sidebarWidth + 8,
            y: 8,
            width: 1,
            height: max(1, view.bounds.height - 16)
        )
        detailScrollView.frame = NSRect(
            x: sidebarWidth + 20,
            y: 0,
            width: max(1, view.bounds.width - sidebarWidth - 20),
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
        let filterHeight: CGFloat = DynamicIslandStateFilterList.preferredHeight
        stateFilterList.frame = NSRect(
            x: 10,
            y: leftPane.bounds.height - 40 - filterHeight,
            width: leftPane.bounds.width - 20,
            height: filterHeight
        )
        queueDivider.frame = NSRect(
            x: 12,
            y: stateFilterList.frame.minY - 10,
            width: leftPane.bounds.width - 24,
            height: 1
        )
        let tableTop = queueDivider.frame.minY - 8
        tableScrollView.frame = NSRect(
            x: 8,
            y: 8,
            width: leftPane.bounds.width - 16,
            height: max(1, tableTop - 8)
        )
        emptyField.frame = NSRect(
            x: 16,
            y: 16,
            width: leftPane.bounds.width - 32,
            height: 22
        )
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
        guard row >= 0,
              queueRows.indices.contains(row),
              let item = queueRows[row].item
        else {
            hoverController.hide()
            return
        }
        let rowRect = tableView.rect(ofRow: row)
        let screenRect = tableView.window?.convertToScreen(
            tableView.convert(rowRect, to: nil)
        ) ?? rowRect
        hoverController.show(item: item, sourceRect: screenRect)
    }

    func apply(
        collection: TaskProgressCollectionSnapshot,
        sourceFilter: TaskSourceFilter,
        preferredTaskKey: String?,
        agentStatuses: [AgentRuntimeStatus]? = nil,
        taskOpenEvidence: [String: TaskOpenEvidence]? = nil
    ) {
        _ = view
        self.collection = collection
        self.sourceFilter = sourceFilter
        if let agentStatuses {
            self.agentStatuses = agentStatuses
        }
        if let taskOpenEvidence {
            self.taskOpenEvidence = taskOpenEvidence
        }
        updateCounts()
        // An explicit navigation target must beat the controller's incidental
        // prior selection. Grouping puts Needs you first, so retaining an old
        // first row here could otherwise open a different task than requested.
        let previousKey = preferredTaskKey == nil
            || preferredTaskKey == selectedTaskKey
            ? selectedTaskKey
            : nil
        let filteredItems = collection.filtered(
            source: sourceFilter,
            state: stateFilter
        )
        visibleSections = taskQueueSections(for: filteredItems)
        visibleItems = visibleSections.flatMap(\.items)
        queueRows = visibleItems.map { .task($0) }
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
        return queueRows.count
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
                highlighted: eventRowIsHighlighted(row)
            )
        }
        guard queueRows.indices.contains(row),
              let item = queueRows[row].item
        else { return nil }
        let cell = DynamicIslandTaskRowView()
        cell.apply(
            item: item,
            selected: item.identityKey == selectedTaskKey
        )
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if tableView === eventsTableView {
            guard displayedEvents.indices.contains(row) else { return 32 }
            return dynamicIslandTaskEventRowHeight(
                text: displayedEvents[row].text,
                availableWidth: max(1, eventsScrollView.contentSize.width)
            )
        }
        guard queueRows.indices.contains(row) else { return tableView.rowHeight }
        return tableView.rowHeight
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelectedItemFromTable()
    }

    func tableView(
        _ tableView: NSTableView,
        shouldSelectRow row: Int
    ) -> Bool {
        guard tableView !== eventsTableView,
              queueRows.indices.contains(row)
        else { return false }
        return queueRows[row].item != nil
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
        if cursorListeningEmpty != nil {
            onInspectAgents?()
            return
        }
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
        guard row >= 0,
              queueRows.indices.contains(row),
              let item = queueRows[row].item
        else { return }
        selectedItem = item
        selectedTaskKey = selectedItem?.identityKey
        hoverController.hide()
        renderDetail()
        tableView.reloadData()
        onSelectedTaskKeyChange?(selectedTaskKey)
    }

    private func syncSelectionToTable() {
        guard let selectedTaskKey,
              let row = queueRows.firstIndex(where: {
                  $0.item?.identityKey == selectedTaskKey
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
        var items: [DynamicIslandStateFilterItem] = []
        for entry in labels {
            let count = filteredBySource.filtered(
                source: .all,
                state: entry.1
            ).count
            items.append(
                DynamicIslandStateFilterItem(
                    title: entry.0,
                    count: count,
                    symbolName: DynamicIslandStateFilterList.symbolName(for: entry.1),
                    dimmed: count == 0
                )
            )
        }
        stateFilterList.apply(
            items: items,
            selectedIndex: segmentIndex(for: stateFilter)
        )
        queueCountField.stringValue = "\(filteredBySource.items.count) 项"
        stateFilterList.setAccessibilityValue(
            items.map { "\($0.title) \($0.count)" }.joined(separator: "，")
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

    private var cursorListeningEmpty: CursorListeningEmptyPresentation? {
        cursorListeningEmptyPresentation(
            sourceFilter: sourceFilter,
            sourceItemCount: collection.filtered(
                source: sourceFilter,
                state: .all
            ).count,
            cursorStatus: agentStatuses.first { $0.metadata.id == .cursor },
            totalTaskCount: collection.items.count
        )
    }

    private func renderDetail() {
        emptyField.isHidden = !visibleItems.isEmpty
        tableScrollView.isHidden = visibleItems.isEmpty
        queueDivider.isHidden = visibleItems.isEmpty
        emptyField.stringValue = cursorListeningEmpty == nil
            ? "没有匹配任务"
            : "这个筛选下没有任务"
        emptyField.setAccessibilityLabel(emptyField.stringValue)
        guard let item = selectedItem else {
            if let empty = cursorListeningEmpty {
                renderCursorListeningEmpty(empty)
                return
            }
            setCursorEmptyVisible(false)
            providerField.stringValue = "ThreadHelm"
            providerField.textColor = DynamicIslandPalette.secondaryText
            titleField.stringValue = "没有匹配任务"
            applyStateBadge(text: "无任务", tint: DynamicIslandPalette.secondaryText)
            startedField.stringValue = ""
            elapsedField.stringValue = ""
            workingDirectoryField.stringValue = "工作目录不可用"
            openResultField.stringValue = "返回结果 · 尚未尝试"
            identityField.stringValue = ""
            openButton.setVisualStyle(.bare)
            openButton.setDisplayTitle("仅查看状态")
            openButton.setAccessibilityLabel("仅查看状态")
            openButton.isEnabled = false
            copyButton.isHidden = false
            copyButton.setVisualStyle(.secondary)
            copyButton.isEnabled = false
            copyButton.setDisplayTitle("复制路径")
            copyButton.setAccessibilityLabel("复制工作目录")
            renderEvents([AgentActivityEntry]())
            updateDetailAccessibility()
            view.needsLayout = true
            return
        }
        setCursorEmptyVisible(false)
        providerField.stringValue = "\(providerName(for: item.source)) · ThreadHelm"
        providerField.textColor = DynamicIslandPalette.secondaryText
        titleField.stringValue = item.title
        applyStateBadge(text: item.statusText, tint: tintColor(for: item.kind))
        startedField.stringValue = "开始 \(eventTimeFormatter.string(from: item.startedAt))"
        let durationText = taskProgressDurationText(
            for: item,
            now: dynamicIslandCurrentDate()
        )
        elapsedField.stringValue = "持续 \(durationText)"
        workingDirectoryField.stringValue = copyPathForSelfTest()
            ?? "工作目录不可用"
        openResultField.stringValue = openResultText(for: item)
        identityField.stringValue = secondaryIdentityText(for: item) ?? ""
        openButton.setDisplayTitle(item.openButtonTitle)
        openButton.setAccessibilityLabel("打开当前任务")
        openButton.setVisualStyle(item.canOpen ? .secondary : .bare)
        openButton.isEnabled = item.canOpen
        copyButton.isHidden = false
        copyButton.setVisualStyle(.secondary)
        copyButton.isEnabled = copyPathForSelfTest() != nil
        copyButton.setDisplayTitle("复制路径")
        copyButton.setAccessibilityLabel("复制工作目录")
        renderEvents(item.projection.publicMessages)
        updateDetailAccessibility()
        view.needsLayout = true
    }

    private func renderCursorListeningEmpty(
        _ empty: CursorListeningEmptyPresentation
    ) {
        setCursorEmptyVisible(true)
        emptyEyebrowField.stringValue = empty.eyebrow
        emptyTitleField.stringValue = empty.title
        emptyBodyField.stringValue = empty.body
        for (index, row) in emptyFactRows.enumerated() {
            if empty.facts.indices.contains(index) {
                row.apply(empty.facts[index], showsDivider: index < empty.facts.count - 1)
                row.isHidden = false
            } else {
                row.isHidden = true
            }
        }
        openButton.setDisplayTitle("查看 Agents 状态")
        openButton.setAccessibilityLabel("查看 Agents 状态")
        openButton.setVisualStyle(.secondary)
        openButton.isEnabled = true
        copyButton.isHidden = true
        copyButton.setDisplayTitle("复制路径")
        copyButton.setAccessibilityLabel("复制工作目录")
        deferButton.isHidden = false
        renderEvents([AgentActivityEntry]())
        updateDetailAccessibility()
        view.needsLayout = true
    }

    private func setCursorEmptyVisible(_ visible: Bool) {
        emptyDetailContainer.isHidden = !visible
        deferButton.isHidden = !visible
        for view in [
            providerField,
            titleField,
            stateBadge,
            startedField,
            elapsedField,
            workingDirectoryField,
            openResultField,
            detailHeaderDivider,
            eventsTitleField,
            eventsCard,
            identityField,
            footerDivider,
        ] {
            view.isHidden = visible
        }
    }

    private func applyStateBadge(text: String, tint: NSColor) {
        stateField.stringValue = text
        stateField.textColor = tint
        stateField.alignment = .center
        stateField.sizeToFit()
        stateBadge.setSurface(
            backgroundColor: tint.withAlphaComponent(0.12),
            borderColor: tint.withAlphaComponent(0.55),
            borderWidth: 1
        )
    }

    @objc private func deferCursorSetup() {
        onDeferCursorSetup?()
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
            y: contentHeight - 60,
            width: fieldWidth - 108,
            height: 28
        )
        let badgeWidth = min(
            88,
            max(56, stateField.intrinsicContentSize.width + 16)
        )
        stateBadge.frame = NSRect(
            x: width - inset - badgeWidth,
            y: contentHeight - 56,
            width: badgeWidth,
            height: 22
        )
        stateField.frame = stateBadge.bounds.insetBy(dx: 6, dy: 2)
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
        openResultField.frame = NSRect(
            x: inset,
            y: contentHeight - 114,
            width: fieldWidth,
            height: 20
        )
        detailHeaderDivider.frame = NSRect(
            x: inset,
            y: contentHeight - 132,
            width: fieldWidth,
            height: 1
        )
        eventsTitleField.frame = NSRect(
            x: inset,
            y: contentHeight - 158,
            width: fieldWidth,
            height: 18
        )
        eventsCard.frame = NSRect(
            x: inset,
            y: 64,
            width: fieldWidth,
            height: max(96, contentHeight - 234)
        )
        eventsScrollView.frame = eventsCard.bounds.insetBy(dx: 10, dy: 10)
        layoutEventsTable()
        showEventsScroller()
        footerDivider.frame = NSRect(x: inset, y: 52, width: fieldWidth, height: 1)
        if cursorListeningEmpty == nil {
            let openWidth: CGFloat = 112
            let copyWidth = min(
                92,
                max(88, ceil(copyButton.intrinsicContentSize.width + 16))
            )
            openButton.frame = NSRect(x: inset, y: 10, width: openWidth, height: 32)
            copyButton.frame = NSRect(
                x: inset + openWidth + 14,
                y: 10,
                width: copyWidth,
                height: 32
            )
            deferButton.frame = .zero
        }
        let identityMinX = copyButton.isHidden
            ? openButton.frame.maxX + 16
            : copyButton.frame.maxX + 16
        identityField.frame = NSRect(
            x: max(identityMinX, width - 132),
            y: 16,
            width: 116,
            height: 20
        )
        identityField.alignment = .right
        layoutEmptyDetail(width: width, height: contentHeight)
    }

    private func layoutEmptyDetail(width: CGFloat, height: CGFloat) {
        let inset: CGFloat = 28
        let fieldWidth = max(1, width - inset * 2)
        emptyDetailContainer.frame = NSRect(
            x: 0,
            y: 0,
            width: width,
            height: height
        )
        emptyEyebrowField.frame = NSRect(
            x: inset,
            y: height - 48,
            width: fieldWidth,
            height: 18
        )
        emptyTitleField.frame = NSRect(
            x: inset,
            y: height - 96,
            width: fieldWidth,
            height: 36
        )
        let bodyFont = emptyBodyField.font ?? .systemFont(ofSize: 13)
        let bodyHeight = max(
            48,
            ceil(
                (emptyBodyField.stringValue as NSString).boundingRect(
                    with: NSSize(width: fieldWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: bodyFont]
                ).height
            )
        )
        emptyBodyField.frame = NSRect(
            x: inset,
            y: height - 112 - bodyHeight,
            width: fieldWidth,
            height: bodyHeight
        )
        let factHeight: CGFloat = 118
        emptyFactCard.frame = NSRect(
            x: inset,
            y: emptyBodyField.frame.minY - 20 - factHeight,
            width: fieldWidth,
            height: factHeight
        )
        let rowHeight = floor(emptyFactCard.bounds.height / 3)
        for (index, row) in emptyFactRows.enumerated() {
            row.frame = NSRect(
                x: 0,
                y: emptyFactCard.bounds.height - CGFloat(index + 1) * rowHeight,
                width: emptyFactCard.bounds.width,
                height: rowHeight
            )
        }
        if cursorListeningEmpty != nil {
            let openWidth: CGFloat = 148
            let buttonY = max(16, emptyFactCard.frame.minY - 52)
            openButton.frame = NSRect(
                x: inset,
                y: buttonY,
                width: openWidth,
                height: 32
            )
            deferButton.frame = NSRect(
                x: inset + openWidth + 8,
                y: buttonY,
                width: 88,
                height: 32
            )
        }
    }

    private func renderEvents(_ events: [AgentActivityEntry]) {
        displayedEvents = events.sorted {
            if $0.occurredAt != $1.occurredAt {
                return $0.occurredAt > $1.occurredAt
            }
            return $0.sourceOrder > $1.sourceOrder
        }.map {
            DynamicIslandDisplayedActivityEvent(
                kind: .commentary,
                occurredAt: $0.occurredAt,
                sourceOrder: $0.sourceOrder,
                text: $0.text
            )
        }
        eventsTableView.reloadData()
        layoutEventsTable()
        showEventsScroller()
        if !displayedEvents.isEmpty {
            eventsTableView.scrollRowToVisible(0)
            eventsScrollView.reflectScrolledClipView(eventsScrollView.contentView)
        }
    }

    private func eventRowIsHighlighted(_ row: Int) -> Bool {
        displayedEvents.indices.contains(row)
            && row == displayedEvents.startIndex
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
        let value: String
        if let empty = cursorListeningEmpty {
            value = (
                [empty.eyebrow, empty.title, empty.body]
                    + empty.facts.map { "\($0.label) \($0.value)" }
                    + ["查看 Agents 状态", "稍后再装"]
            ).joined(separator: "，")
        } else {
            value = [
                providerField.stringValue,
                titleField.stringValue,
                stateField.stringValue,
                startedField.stringValue,
                elapsedField.stringValue,
                workingDirectoryField.stringValue,
                openResultField.stringValue,
                "最近事件",
            ].joined(separator: "，")
        }
        detailContentView.setAccessibilityLabel("任务详情")
        detailContentView.setAccessibilityValue(value)
    }

    private func providerName(for source: TaskSource) -> String {
        agentPresentation(for: source).displayName
    }

    private func tintColor(for kind: TaskProgressKind) -> NSColor {
        dynamicIslandTint(for: kind)
    }

    private var sidebarWidth: CGFloat {
        min(380, max(316, view.bounds.width * 0.34))
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

    private func openResultText(for item: TaskProgressItem) -> String {
        guard let evidence = taskOpenEvidence[item.identityKey] else {
            return "返回结果 · 尚未尝试"
        }
        return "返回结果 · \(evidence.result.feedbackDescription) · "
            + eventTimeFormatter.string(from: evidence.recordedAt)
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
        stateFilterList.selectIndex(segmentIndex(for: filter))
        apply(
            collection: collection,
            sourceFilter: sourceFilter,
            preferredTaskKey: nil
        )
    }

    func accessibilitySnapshotForSelfTest() -> String {
        _ = view
        return [
            stateFilterList.accessibilityValue() as? String,
            emptyField.stringValue,
            detailContentView.accessibilityValue() as? String,
            openButton.accessibilityLabel(),
            copyButton.accessibilityLabel(),
            deferButton.isHidden ? nil : deferButton.accessibilityLabel(),
        ].compactMap { $0 }.joined(separator: " ")
    }

    func detailEventTextsForSelfTest() -> [String] {
        _ = view
        return displayedEvents.map(\.text)
    }

    func highlightedEventTextsForSelfTest() -> [String] {
        _ = view
        return displayedEvents.indices
            .filter(eventRowIsHighlighted)
            .map { displayedEvents[$0].text }
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
        return queueRows.indices.filter {
            queueRows[$0].item != nil
        }.allSatisfy { row in
            guard let cell = tableView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: true
            ) as? DynamicIslandTaskRowView else { return false }
            return cell.providerIconIsConcreteForSelfTest
        }
    }

    func visibleTaskGroupSummariesForSelfTest() -> [String] {
        visibleSections.map { "\($0.group.title) \($0.items.count)" }
    }

    func footerButtonGapForSelfTest() -> CGFloat {
        _ = view
        view.layoutSubtreeIfNeeded()
        return copyButton.frame.minX - openButton.frame.maxX
    }

    func copyButtonUsesCompactContentLayoutForSelfTest() -> Bool {
        _ = view
        view.layoutSubtreeIfNeeded()
        guard copyButton.imageHugsTitle,
              let cell = copyButton.cell
        else { return false }
        let contentRect = cell.imageRect(forBounds: copyButton.bounds)
            .union(cell.titleRect(forBounds: copyButton.bounds))
        return copyButton.frame.width <= 92
            && copyButton.bounds.insetBy(dx: 8, dy: 0).contains(contentRect)
    }

    func copyPathForSelfTest() -> String? {
        selectedItem?.workingDirectory.flatMap(normalizedAbsolutePath)
    }

    func openButtonTitleForSelfTest() -> String {
        _ = view
        return openButton.title
    }

    func openResultTextForSelfTest() -> String {
        _ = view
        return openResultField.stringValue
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
        currentEventTexts = Array(item.projection.publicMessages.prefix(3)).map(\.text)
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
        layer?.cornerRadius = 10
        layer?.borderWidth = 0
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
        selectionAccent.frame = NSRect(x: 0, y: 0, width: 4, height: bounds.height)
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
        let tint = dynamicIslandTint(for: item.kind)
        selectionAccent.layer?.backgroundColor = tint.cgColor
        selectionAccent.isHidden = !selected
        layer?.backgroundColor = selected
            ? DynamicIslandPalette.selectedFill.cgColor
            : NSColor.clear.cgColor
        layer?.borderWidth = 0
        layer?.borderColor = NSColor.clear.cgColor
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
        statusField.textColor = DynamicIslandPalette.secondaryText
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
    private let connector = NSView()
    private let dot = NSView()
    private let timeField = DynamicIslandTaskLabel(
        size: 12,
        weight: .medium,
        monospaced: true
    )
    private let textField = DynamicIslandTaskLabel(size: 12, weight: .regular)

    init(time: String, text: String, highlighted: Bool) {
        super.init(frame: .zero)
        connector.wantsLayer = true
        connector.layer?.backgroundColor = DynamicIslandPalette.hairline.cgColor
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
        addSubview(connector)
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
        connector.frame = NSRect(x: 3, y: 0, width: 1, height: bounds.height)
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

struct DynamicIslandStateFilterItem: Equatable {
    let title: String
    let count: Int
    let symbolName: String
    let dimmed: Bool
}

private final class DynamicIslandStateFilterList: NSView {
    static let rowHeight: CGFloat = 30
    static let preferredHeight: CGFloat = rowHeight * 5

    var onSelectionChange: ((Int) -> Void)?
    private var rows: [DynamicIslandStateFilterRow] = []
    private(set) var selectedIndex: Int = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityRole(.group)
        rebuild(itemCount: 5)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func symbolName(for filter: TaskStateFilter) -> String {
        switch filter {
        case .all: return "line.3.horizontal"
        case .running: return "play.fill"
        case .waitingForInput: return "hourglass"
        case .completed: return "checkmark.circle"
        case .failed: return "xmark.circle"
        }
    }

    func selectIndex(_ index: Int) {
        selectedIndex = index
        for (rowIndex, row) in rows.enumerated() {
            row.setSelected(rowIndex == index)
        }
    }

    func apply(items: [DynamicIslandStateFilterItem], selectedIndex: Int) {
        if items.count != rows.count {
            rebuild(itemCount: items.count)
        }
        self.selectedIndex = selectedIndex
        for (index, item) in items.enumerated() where rows.indices.contains(index) {
            rows[index].apply(item, selected: index == selectedIndex)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = max(1, bounds.width)
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(
                x: 0,
                y: bounds.height - CGFloat(index + 1) * Self.rowHeight,
                width: width,
                height: Self.rowHeight
            )
        }
    }

    private func rebuild(itemCount: Int) {
        rows.forEach { $0.removeFromSuperview() }
        rows = (0..<itemCount).map { index in
            let row = DynamicIslandStateFilterRow()
            row.onClick = { [weak self] in
                self?.selectedIndex = index
                self?.onSelectionChange?(index)
            }
            addSubview(row)
            return row
        }
        needsLayout = true
    }
}

private final class DynamicIslandStateFilterRow: NSView {
    var onClick: (() -> Void)?
    private let iconView = NSImageView()
    private let titleField = DynamicIslandTaskLabel(size: 13, weight: .medium)
    private let countField = DynamicIslandTaskLabel(size: 12, weight: .medium)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setAccessibilityElement(false)
        countField.alignment = .right
        addSubview(iconView)
        addSubview(titleField)
        addSubview(countField)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(x: 10, y: 7, width: 16, height: 16)
        titleField.frame = NSRect(x: 32, y: 6, width: max(1, bounds.width - 72), height: 18)
        countField.frame = NSRect(x: bounds.width - 36, y: 6, width: 24, height: 18)
    }

    func apply(_ item: DynamicIslandStateFilterItem, selected: Bool) {
        titleField.stringValue = item.title
        countField.stringValue = "\(item.count)"
        iconView.image = NSImage(
            systemSymbolName: item.symbolName,
            accessibilityDescription: item.title
        )
        setSelected(selected)
        let color = selected
            ? DynamicIslandPalette.primaryText
            : DynamicIslandPalette.secondaryText
        titleField.textColor = color
        countField.textColor = color
        iconView.contentTintColor = color
        alphaValue = item.dimmed && !selected ? 0.55 : 1
        setAccessibilityLabel("\(item.title) \(item.count)")
    }

    func setSelected(_ selected: Bool) {
        layer?.backgroundColor = selected
            ? DynamicIslandPalette.selectedFill.cgColor
            : NSColor.clear.cgColor
    }

    override func mouseDown(with _: NSEvent) {
        onClick?()
    }
}

private final class DynamicIslandEmptyFactRow: NSView {
    private let labelField = DynamicIslandTaskLabel(size: 12, weight: .medium)
    private let valueField = DynamicIslandTaskLabel(size: 12, weight: .regular)
    private let divider = DynamicIslandDividerView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        labelField.textColor = DynamicIslandPalette.secondaryText
        valueField.textColor = DynamicIslandPalette.primaryText
        valueField.alignment = .right
        valueField.lineBreakMode = .byTruncatingTail
        addSubview(labelField)
        addSubview(valueField)
        addSubview(divider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        labelField.frame = NSRect(x: 14, y: 10, width: 72, height: 16)
        valueField.frame = NSRect(
            x: 90,
            y: 10,
            width: max(1, bounds.width - 104),
            height: 16
        )
        divider.frame = NSRect(x: 14, y: 0, width: max(1, bounds.width - 28), height: 1)
    }

    func apply(_ fact: CursorListeningEmptyFact, showsDivider: Bool) {
        labelField.stringValue = fact.label
        valueField.stringValue = fact.value
        divider.isHidden = !showsDivider
        setAccessibilityLabel("\(fact.label) \(fact.value)")
    }
}
