# ChatBird Live Task Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add one-minute quota refresh, risk colors, updated-time task ordering, state-specific icons, five-row scrolling, and safe segmented-live hover activity to the existing ChatBird macOS panel.

**Architecture:** Keep the existing single-file AppKit application and separate the change through type boundaries inside `main.swift`: parsing produces safe task data, snapshots select and order rows, the main view handles fixed-height scrolling and drawing, and a nonactivating hover panel presents already-sanitized activity. The app continues to read rollout files and never attaches to the Codex stdio app-server.

**Tech Stack:** Swift 5, AppKit, Foundation, CoreGraphics, existing shell build and release scripts, no new dependencies.

## Global Constraints

- Only the current weekly quota is displayed; the retired 5-hour quota is not restored.
- Quota refresh interval is exactly 60 seconds.
- Quota colors are blue for `50%–100%`, yellow for `20%–49%`, red for `1%–19%`, and a gray empty arc with red `0%` text at `0%`.
- Tasks are ordered by `updatedAt` descending.
- Waiting-for-input tasks count as active tasks.
- More than five active tasks produces an active-only scrollable list with exactly five visible rows.
- Five or fewer active tasks are followed by the newest terminal tasks, with at most five rows total.
- Hover activity is segmented-live from public commentary and sanitized tool categories only.
- `agent_reasoning`, tool arguments, command text, tool output, credentials, and raw app-server streams are never displayed.
- No `CGEvent`, mouse injection, keyboard injection, or simulated click fallback may be added.
- Existing `codex://threads/{threadID}` task navigation remains unchanged.

## File Structure

- Modify `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/main.swift`
  - Constants and quota presentation policy.
  - Task data model, rollout parser, ordering, and display selection.
  - Main panel drawing, task scrolling, refresh interaction, and hover callbacks.
  - Nonactivating activity preview panel.
  - App lifecycle wiring and built-in regression tests.
- Modify `macos/ChatBirdQuotaPanel/docs/chatbird-panel-preview.png`
  - Replace the checked-in preview only after the new rendering passes visual review.
- Modify `shared/preview/chatbird-nt/`
  - Replace release preview assets only with the visually approved render.
- Modify `dist/ChatBird-NT-macOS-Universal-1.0.0.zip`
  - Regenerate the Universal release archive after all tests pass.
- Modify `dist/ChatBird-NT-macOS-Universal-1.0.0.zip.sha256`
  - Regenerate the archive digest from the final release.

---

### Task 1: Safe Task Activity Model, Parsing, and Selection

**Files:**
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/main.swift:1083-1562`
- Test: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/main.swift:4374-4628`

**Interfaces:**
- Consumes: rollout JSONL records, rollout modification dates, existing `TaskProgressKind`, and `maximumVisibleTaskRows`.
- Produces: `TaskProgressItem.updatedAt: Date`, `TaskProgressItem.activityText: String?`, `TaskProgressKind.isActive: Bool`, `TaskProgressSnapshot.isScrollable: Bool`, and `TaskProgressSnapshot.displaying(_:)`.

- [ ] **Step 1: Add failing task parser and selection assertions**

Add timestamped fixtures for public commentary, hidden reasoning, tool start/output, and seven active tasks:

```swift
let commentary = #"{"timestamp":"2026-07-25T10:02:00Z","type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"正在检查任务排序。第二行。第四行会被截断。","agent_reasoning":"绝不显示"}}"#
let commandStart = #"{"timestamp":"2026-07-25T10:03:00Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"tool-1","arguments":"secret command"}}"#
let commandOutput = #"{"timestamp":"2026-07-25T10:04:00Z","type":"response_item","payload":{"type":"function_call_output","call_id":"tool-1","output":"secret output"}}"#
let parsed = CodexTaskProgressReader.parse(
    lines: [started, commentary, commandStart],
    modificationDate: now,
    now: now
)
guard parsed.items.first?.updatedAt == ISO8601DateFormatter().date(from: "2026-07-25T10:03:00Z"),
      parsed.items.first?.activityText == "正在运行命令",
      parsed.items.first?.activityText?.contains("secret") == false
else { exit(1) }
```

Add assertions that tool output falls back to the latest public commentary, hidden reasoning is absent, active rows over five remain available for scrolling, active rows under five are backfilled by terminal rows, waiting-for-input counts as active, and all results are ordered by `updatedAt`.

- [ ] **Step 2: Build and run the task self-test to verify failure**

Run:

```bash
macos/ChatBirdQuotaPanel/scripts/build.sh
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-task-progress
```

Expected: build or self-test fails because `updatedAt`, `activityText`, active-only scrolling selection, and safe activity parsing are not implemented.

- [ ] **Step 3: Extend the task model and selection policy**

Implement the model surface:

```swift
private extension TaskProgressKind {
    var isActive: Bool {
        self == .running || self == .waitingForInput
    }
}

private struct TaskProgressItem: Equatable {
    let title: String
    let kind: TaskProgressKind
    let startedAt: Date
    let updatedAt: Date
    let activityText: String?
    let statusOverride: String?
    let threadID: String?

    init(
        title: String,
        kind: TaskProgressKind,
        startedAt: Date = .distantPast,
        updatedAt: Date? = nil,
        activityText: String? = nil,
        statusOverride: String? = nil,
        threadID: String? = nil
    ) {
        self.title = title
        self.kind = kind
        self.startedAt = startedAt
        self.updatedAt = updatedAt ?? startedAt
        self.activityText = activityText
        self.statusOverride = statusOverride
        self.threadID = threadID
    }
}

private struct TaskProgressSnapshot: Equatable {
    let items: [TaskProgressItem]
    let isScrollable: Bool

    init(items: [TaskProgressItem], isScrollable: Bool = false) {
        self.items = items
        self.isScrollable = isScrollable
    }
}
```

`TaskProgressSnapshot.displaying(_:)` must normalize titles for deduplication, prefer the newer duplicate, sort all rows by `updatedAt` descending, and then apply:

```swift
let active = deduplicated.filter(\.kind.isActive)
if active.count > maximumVisibleTaskRows {
    return TaskProgressSnapshot(items: active, isScrollable: true)
}
let terminal = deduplicated.filter { $0.kind == .completed || $0.kind == .failed }
let rows = Array((active + terminal).prefix(maximumVisibleTaskRows))
return TaskProgressSnapshot(items: rows, isScrollable: false)
```

- [ ] **Step 4: Parse safe segmented-live activity and last update time**

Keep the existing two-second internal task refresh timer for segmented-live
rollout pickup, without exposing that interval as UI copy. In
`CodexTaskProgressReader.parse`, track:

```swift
var activeTools: [String: (text: String, updatedAt: Date)] = [:]
var latestPublicCommentary: String?
var lastUpdatedAt = modificationDate
```

Update `lastUpdatedAt` from each accepted record timestamp. Accept public commentary only when `payload.type == "agent_message"` and `payload.phase == "commentary"`. Sanitize it with a helper that removes Markdown markers, folds whitespace, limits it to three non-empty lines and 200 characters, and never reads `agent_reasoning`.

Map tool names through a closed allowlist:

```swift
private static func safeToolActivity(name: String) -> String {
    switch name.lowercased() {
    case "exec_command": return "正在运行命令"
    case "apply_patch": return "正在编辑文件"
    case let value where value.contains("web")
        || value.contains("browser")
        || value.contains("search"):
        return "正在搜索或检查网页"
    default:
        return "正在使用工具"
    }
}
```

Insert a mapped description and record timestamp on
`function_call`/`custom_tool_call`, remove it on the matching output, and choose
`activeTools.values.max(by: { $0.updatedAt < $1.updatedAt })?.text`, then public
commentary, then `"正在思考"` for a running task. Carry `updatedAt` and
`activityText` through cached and resolved-title items. Sort reader output only
by `updatedAt` descending before snapshot selection.

- [ ] **Step 5: Run the task self-test to verify it passes**

Run:

```bash
macos/ChatBirdQuotaPanel/scripts/build.sh
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-task-progress
```

Expected: exit code 0 with assertions covering lifecycle, updated-time sorting, active-list policy, safe commentary, safe tools, and no hidden-content leakage.

- [ ] **Step 6: Commit the task model change**

```bash
git add macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/main.swift
git commit -m "让任务列表反映最新公开进度" \
  -m "Constraint: 活动摘要只能来自公开 commentary 和安全化工具类别" \
  -m "Rejected: 读取 agent_reasoning 或原始工具输出 | 违反隐私边界" \
  -m "Confidence: high" \
  -m "Scope-risk: moderate" \
  -m "Directive: 保持 updatedAt 为唯一排序依据" \
  -m "Tested: --self-test-task-progress" \
  -m "Not-tested: AppKit 滚动与悬停尚未实现"
```

### Task 2: Quota Risk Colors, One-Minute Refresh, State Icons, and Five-Row Scrolling

**Files:**
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/main.swift:6-17`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/main.swift:1818-2350`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/main.swift:3317-3668`
- Test: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/main.swift:4374-4748`

**Interfaces:**
- Consumes: `TaskProgressSnapshot.items`, `TaskProgressSnapshot.isScrollable`, `TaskProgressItem.kind`, and `QuotaRow.remainingPercent`.
- Produces: `QuotaLevel`, `quotaLevel(for:)`, `visibleTaskItems`, `taskScrollOffset`, `onRequestQuotaRefresh`, and `isQuotaRefreshing`.

- [ ] **Step 1: Add failing quota, icon, refresh, and scrolling assertions**

Add a pure quota policy and assert exact boundaries:

```swift
guard quotaLevel(for: 100) == .healthy,
      quotaLevel(for: 50) == .healthy,
      quotaLevel(for: 49) == .warning,
      quotaLevel(for: 20) == .warning,
      quotaLevel(for: 19) == .critical,
      quotaLevel(for: 1) == .critical,
      quotaLevel(for: 0) == .exhausted,
      refreshInterval == 60
else { exit(1) }
```

Extend `--self-test-task-progress` to assert the four status symbol names are `arrow.triangle.2.circlepath`, `questionmark.circle.fill`, `checkmark.circle.fill`, and `exclamationmark.triangle.fill`. Create seven active rows, apply two scroll-wheel steps, and assert the visible slice changes while remaining five rows long. Assert non-scrollable mixed lists ignore scroll-wheel changes and task click hit-testing uses the scrolled row.

- [ ] **Step 2: Build and run both self-tests to verify failure**

Run:

```bash
macos/ChatBirdQuotaPanel/scripts/build.sh
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-weekly-quota
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-task-progress
```

Expected: self-tests fail because the interval, quota policy, status symbols, and scrolling are still old.

- [ ] **Step 3: Implement quota policy and refresh interaction**

Change `refreshInterval` to `60`. Add:

```swift
private enum QuotaLevel {
    case healthy, warning, critical, exhausted
}

private func quotaLevel(for remaining: Int) -> QuotaLevel {
    switch max(0, min(100, remaining)) {
    case 50...100: return .healthy
    case 20...49: return .warning
    case 1...19: return .critical
    default: return .exhausted
    }
}
```

Use a single level color for the visible arc. At zero, draw only the gray track, render `0%` in red, and draw “额度已耗尽” beneath it. Add a refresh hit target beside `statusText`, an `onRequestQuotaRefresh` callback, and `isQuotaRefreshing`. Draw `arrow.clockwise` and rotate it from a view animation timer only while a refresh is active. Wire the callback to `AppDelegate.refreshQuota()`, and set `isQuotaRefreshing` true before fetch and false on both success and failure. Success text ends in `· 1分钟`; failure text is `1 分钟后自动重试`.

- [ ] **Step 4: Implement status icons and fixed-height scrolling**

Use:

```swift
running -> "arrow.triangle.2.circlepath" / blue
waitingForInput -> "questionmark.circle.fill" / yellow
completed -> "checkmark.circle.fill" / green
failed -> "exclamationmark.triangle.fill" / red
```

Maintain `taskScrollOffset` as an integer row index. `visibleTaskItems` returns the five-row slice when `isScrollable`, otherwise all snapshot items. Override `scrollWheel(with:)` only when the pointer lies within the task list and the snapshot is scrollable, increment or decrement the offset, clamp it to `0...(items.count - 5)`, then rebuild task symbols, tracking areas, cursor rectangles, and display.

Draw a narrow vertical scrollbar only for scrollable snapshots. Its thumb size is proportional to `5 / items.count`, and its position is proportional to `taskScrollOffset / (items.count - 5)`. All row drawing, tracking, clicking, hover indexing, and symbol views must use `visibleTaskItems`.

- [ ] **Step 5: Run both self-tests to verify they pass**

Run:

```bash
macos/ChatBirdQuotaPanel/scripts/build.sh
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-weekly-quota
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-task-progress
```

Expected: both commands exit 0 and report the new threshold, interval, icon, scroll, and click assertions as passing.

- [ ] **Step 6: Commit quota and list interaction changes**

```bash
git add macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/main.swift
git commit -m "让额度风险与多任务状态一眼可辨" \
  -m "Constraint: 主面板固定为五行视觉高度且额度每 60 秒刷新" \
  -m "Rejected: 随任务数量扩大面板 | 会破坏宠物上方的固定布局" \
  -m "Confidence: high" \
  -m "Scope-risk: moderate" \
  -m "Directive: 所有任务命中测试必须基于 visibleTaskItems" \
  -m "Tested: --self-test-weekly-quota; --self-test-task-progress" \
  -m "Not-tested: 悬停活动窗口尚未接入"
```

### Task 3: Nonactivating Segmented-Live Hover Preview

**Files:**
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/main.swift:1818-2130`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/main.swift:3317-3668`
- Test: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/main.swift:4374-4628`

**Interfaces:**
- Consumes: `TaskProgressItem.activityText`, `TaskProgressItem.kind`, the hovered row screen rect, and refreshed `TaskProgressSnapshot`.
- Produces: `TaskActivityPreviewController.show(item:anchorRect:)`, `update(item:)`, `hide()`, and `QuotaPanelView.onHoverRunningTask`.

- [ ] **Step 1: Add failing hover eligibility and safe update assertions**

Define and test a pure hover payload constructor:

```swift
guard taskActivityPreviewPayload(
    for: TaskProgressItem(
        title: "运行任务",
        kind: .running,
        updatedAt: now,
        activityText: "正在编辑文件"
    )
)?.body == "正在编辑文件",
taskActivityPreviewPayload(
    for: TaskProgressItem(title: "完成任务", kind: .completed, updatedAt: now)
) == nil
else { exit(1) }
```

Add a controller test using an offscreen `NSPanel`: show a running item, update the same item to a new public activity string, assert the text view changes without recreating the panel, then hide and assert `isVisible == false`.

- [ ] **Step 2: Build and run the task self-test to verify failure**

Run:

```bash
macos/ChatBirdQuotaPanel/scripts/build.sh
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-task-progress
```

Expected: build fails because the preview payload, controller, and hover callback do not exist.

- [ ] **Step 3: Implement the preview panel**

Create `TaskActivityPreviewController` inside `main.swift` with one reusable `.borderless` and `.nonactivatingPanel` `NSPanel`, `level = .statusBar`, `hidesOnDeactivate = false`, `ignoresMouseEvents = true`, and `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`. Its content view draws:

```text
Codex 正在处理
<最多三行的 activityText>
```

Use a 248-point width and a compact 72-point height. Place the preview above the anchor row when it fits, otherwise below; clamp the final frame to the row screen’s visible frame with an 8-point margin. Do not call `makeKey`, `activate`, or any input synthesis API.

- [ ] **Step 4: Wire hover lifecycle and segmented-live updates**

Expose:

```swift
var onHoverRunningTask: ((TaskProgressItem?, NSRect?) -> Void)?
```

When entering a visible running row, convert its rect from view coordinates to window and then screen coordinates and emit the item and anchor. When leaving it, scrolling, hiding the panel, losing the pet, or terminating, emit `nil` and hide the preview.

In `refreshTaskProgress()`, if the view still hovers the same thread and that refreshed item remains running, update the preview controller with the new `activityText`. If the task changes state or disappears, hide it.

- [ ] **Step 5: Run task and lifecycle self-tests**

Run:

```bash
macos/ChatBirdQuotaPanel/scripts/build.sh
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-task-progress
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-lifecycle
```

Expected: both commands exit 0; task tests report preview eligibility, live text update, and non-running suppression as passing.

- [ ] **Step 6: Commit hover preview**

```bash
git add macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/main.swift
git commit -m "让运行任务悬停时呈现安全的最新进度" \
  -m "Constraint: 独立面板只能分段读取 rollout 的公开内容" \
  -m "Rejected: 连接官方 stdio app-server | 会争用 Codex 当前客户端连接" \
  -m "Confidence: high" \
  -m "Scope-risk: moderate" \
  -m "Directive: 预览窗口永远不可激活且不得读取原始工具内容" \
  -m "Tested: --self-test-task-progress; --self-test-lifecycle" \
  -m "Not-tested: 最终宠物锚点上的视觉效果尚未截图验证"
```

### Task 4: Full Regression, Visual QA, Privacy Audit, and Universal Release

**Files:**
- Modify: `macos/ChatBirdQuotaPanel/docs/chatbird-panel-preview.png`
- Modify: `shared/preview/chatbird-nt/`
- Modify: `dist/ChatBird-NT-macOS-Universal-1.0.0.zip`
- Modify: `dist/ChatBird-NT-macOS-Universal-1.0.0.zip.sha256`
- Verify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/main.swift`
- Verify: `scripts/privacy-audit.sh`
- Verify: `scripts/build-macos-release.sh`

**Interfaces:**
- Consumes: completed source implementation and the existing preview/release scripts.
- Produces: checked preview assets, passing audits, a signed Universal app, release ZIP, and SHA-256.

- [ ] **Step 1: Render visual states**

Run:

```bash
mkdir -p build/visual-qa
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --render-preview build/visual-qa/healthy.png --preview-task-count 5
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --render-preview build/visual-qa/waiting.png --preview-waiting --preview-task-count 5
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --render-preview build/visual-qa/failed.png --preview-failed --preview-task-count 5
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --render-preview build/visual-qa/completed.png --preview-completed --preview-task-count 5
```

Inspect all four images at original resolution. Verify the panel is landscape, quota and tasks are legible, icons do not overlap text, exactly five rows fit, and the refresh icon is not clipped.

- [ ] **Step 2: Replace approved preview assets**

After the rendered image passes inspection, update the checked-in preview image and the existing files under `shared/preview/chatbird-nt/` with the final render using the repository’s existing asset naming. Do not replace pet sprites or unrelated artwork.

- [ ] **Step 3: Run all built-in self-tests**

Run:

```bash
for flag in \
  --self-test-placement \
  --self-test-lifecycle \
  --self-test-native-notification-state \
  --self-test-task-progress \
  --self-test-chatbird-edition \
  --self-test-weekly-quota
do
  "macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" "$flag"
done
```

Expected: every command exits 0.

- [ ] **Step 4: Run source and privacy audits**

Run:

```bash
git diff --check
rg -n "CGEvent|keyboardPost|mousePost|keyCode|agent_reasoning|arguments.*draw|output.*draw" macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/main.swift
scripts/privacy-audit.sh
```

Expected: `git diff --check` and the privacy audit pass. The source scan finds no input injection and no code path that draws hidden reasoning, arguments, or raw tool output.

- [ ] **Step 5: Build and verify the Universal release**

Run:

```bash
scripts/build-macos-release.sh
scripts/build-macos-release.sh --verify-only
/usr/bin/lipo "macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" -verify_arch arm64
/usr/bin/lipo "macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" -verify_arch x86_64
/usr/bin/codesign --verify --deep --strict "macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app"
/usr/bin/shasum -a 256 dist/ChatBird-NT-macOS-Universal-1.0.0.zip
```

Expected: all checks pass and the digest matches `dist/ChatBird-NT-macOS-Universal-1.0.0.zip.sha256`.

- [ ] **Step 6: Install once and perform final live smoke test**

Run the existing ChatBird installer once after the final binary is stable. Verify the panel remains above the pet, the refresh button triggers an update, the list scrolls only when active tasks exceed five, hover activity updates without taking focus, and clicking a row opens the correct Codex task.

- [ ] **Step 7: Commit verified previews and release**

```bash
git add \
  macos/ChatBirdQuotaPanel/docs/chatbird-panel-preview.png \
  shared/preview/chatbird-nt \
  dist/ChatBird-NT-macOS-Universal-1.0.0.zip \
  dist/ChatBird-NT-macOS-Universal-1.0.0.zip.sha256
git commit -m "交付可验证的 ChatBird 实时任务面板" \
  -m "Constraint: 发布包必须同时支持 arm64 与 x86_64" \
  -m "Rejected: 在实现未稳定前反复安装 | 会重复影响辅助功能授权" \
  -m "Confidence: high" \
  -m "Scope-risk: narrow" \
  -m "Directive: 后续发布必须保留隐私审计与全部内置自测" \
  -m "Tested: all self-tests; privacy audit; visual QA; Universal build; codesign; SHA-256" \
  -m "Not-tested: 无"
```
