# ChatBird macOS Dynamic Island Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second, independently styled macOS presentation mode that starts as a 404×58pt top-centered capsule and expands into complete task, confirmation, and quota workspaces without changing the existing pet panel.

**Architecture:** Keep the current Swift 5/AppKit process and local data readers. Move task, quota, provider, Codex lifecycle, refresh, and Claude confirmation queue state into one main-thread `ActivityDashboardStore`; the existing `QuotaPanelView` and a new `DynamicIslandWindowController` become separate snapshot consumers. Extract Claude request ownership into one `ClaudePermissionCoordinator` that binds exactly one presenter at a time, so switching modes never duplicates or loses a request.

**Tech Stack:** Swift 5, AppKit, Foundation, CoreGraphics, existing direct-`swiftc` build, macOS 12.3+, Apple silicon arm64, no new dependencies.

## Global Constraints

- The existing pet panel remains the default for existing and new users and keeps its current geometry, blue visual language, pet anchoring, hover behavior, and double-click behavior.
- Dynamic Island is a second presentation mode, not a reskin or conditional branch inside `QuotaPanelView`.
- User-facing product copy in this scope is `ChatBird`. Renaming the product or bundle to `PetBar` is outside this plan.
- The capsule is exactly 404×58pt at its design size. It uses one line containing a status dot, concise status, task title, elapsed time, and trailing chevron. Expanded base sizes remain tasks 820×560pt, confirmation 820×600pt, and quota 820×470pt.
- The window is centered below the menu bar with a 6pt top gap. It does not occupy or imitate the physical notch area and never covers menu items.
- Expansion keeps the top edge fixed and grows downward. Small screens reduce content height and introduce scrolling; they do not reduce body text below 13pt or detail text below 12pt.
- V1 never displays `3/5`, a guessed percentage, or any inferred step count. Running work uses a green status dot plus state and elapsed time.
- Recent activity is limited to the newest three sanitized public commentary/assistant messages, generic tool categories, or lifecycle events. Thinking, reasoning, commands, tool arguments, raw tool output, credentials, and arbitrary payloads never enter the dashboard snapshot.
- The current task readers keep their freshness, process-identity, filtering, single-flight, and timeout protections.
- A quota refresh failure preserves the last successful rows and Codex reset-credit snapshot and marks them stale.
- A Claude request has one owner and one completion. Mode switches move presentation only; they do not complete, duplicate, reorder, or reread the request.
- Clicking outside or pressing Escape collapses an expanded Dynamic Island but never answers or cancels a Claude request.
- Codex exit continues to cancel ChatBird-hosted Claude confirmation UI safely; Dynamic Island remains visible with a `Codex 已退出` system state.
- The capsule never becomes key and ordinary browsing does not activate ChatBird. An expanded nonactivating workspace may become key on direct interaction so Tab/Escape work without activating the app; confirmation text entry may explicitly activate ChatBird and become first responder.
- Reduce Motion, Reduce Transparency, keyboard navigation, VoiceOver labels, multi-Space behavior, full-screen auxiliary behavior, and display-disconnect recovery are part of V1 acceptance.
- Do not add SwiftUI, ActivityKit, WidgetKit, a network service, telemetry, cloud sync, task history, search, or third-party packages.
- Do not reset, stash, clean, overwrite, or delete existing user work. The current untracked `output/` visual artifacts and technical-review document must be preserved.
- This plan defines local commit checkpoints, but the executor must skip `git add`/`git commit`/`git push` unless the user explicitly authorizes those Git mutations for the execution turn.

## File Structure

### Create

- `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ActivityDashboardModels.swift`
  - Presentation mode, tabs, task filters, bounded activity events, full task collection, quota/provider state, permission queue summary, and the aggregate dashboard snapshot.
- `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ActivityDashboardStore.swift`
  - Main-thread state owner, observer lifecycle, and presentation-mode preference.
- `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ClaudePermissionCoordinator.swift`
  - FIFO request ownership, expiry, terminal-transition handling, presenter binding, and exactly-once decisions.
- `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandPlacement.swift`
  - Pure top-anchor geometry, screen identity, size fitting, and target-screen recovery.
- `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandWindowController.swift`
  - Independent `NSPanel`, hidden/capsule/expanded state machine, animation, key-window policy, outside-click handling, and screen changes.
- `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandView.swift`
  - Neutral palette, capsule, shared workspace chrome, tabs, provider filter, refresh/collapse controls, and root child-controller routing.
- `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandTaskView.swift`
  - Task filters, list, stable selection, detail view, recent events, hover preview, and task actions.
- `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandConfirmationView.swift`
  - FIFO list plus independent tool approval, paged questions, and plan-review views.
- `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandQuotaView.swift`
  - Provider list, quota/reset-credit details, and loading/current/stale/error/unavailable states.
- `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandPreviewRendering.swift`
  - Deterministic offscreen fixtures and PNG rendering for every capsule/workspace state.
- `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandSelfTest.swift`
  - Pure model, store, placement, state-machine, filtering, priority, quota-cache, and coordinator regression coverage.

### Modify

- `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/TaskProgressModels.swift:50-325`
  - Carry bounded events and delegate compact projection to the full collection.
- `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/CodexTaskProgress.swift:47-103,105-259`
  - Return a full collection, extract `session_meta.cwd`, and build safe events.
- `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ClaudeTaskProgress.swift:308-405,420-584,827-845`
  - Return a full collection and build safe events without exposing thinking or tool payloads.
- `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/QuotaPanelView.swift:16-83`
  - Apply a dashboard snapshot while retaining current drawing and interaction code.
- `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ClaudeHookSupport.swift:18-62,736-978`
  - Add value conformances and move queue tests to the coordinator while preserving wire protocol behavior.
- `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ClaudePermissionPanel.swift:13-199`
  - Convert the current controller into the legacy pet-mode presenter; leave its existing blue prompt views intact.
- `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/AppDelegate.swift:16-817`
  - Own the store, publish refresh results, bind presenters, switch modes, build the status menu, and route actions without reading view state.
- `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/PanelLifecycle.swift:15-58`
  - Add pure mode/visibility transition helpers used by lifecycle tests.
- `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/QuotaSelfTests.swift`
  - Lock stale quota/reset-credit preservation.
- `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/TaskProgressSelfTest.swift`
  - Lock full collection, cwd propagation, bounded events, privacy, filtering, and compact-projection compatibility.
- `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/LifecycleSelfTest.swift`
  - Lock mode defaults, visibility, status-menu commands, and Codex-exit behavior.
- `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/main.swift:60-94,168-187`
  - Register the Dynamic Island self-test and preview renderer.
- `macos/ChatBirdQuotaPanel/README.md`
  - Document mode switching and new verification commands after behavior is complete.

---

### Task 1: Lock Shared Dashboard Models, Store, and Mode Preference

**Files:**
- Create: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ActivityDashboardModels.swift`
- Create: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ActivityDashboardStore.swift`
- Create: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandSelfTest.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ClaudeHookSupport.swift:18-62`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/main.swift:60-94`

**Interfaces:**
- Consumes: existing `TaskProgressItem`, `TaskProgressKind`, `TaskSource`, `TaskProgressSnapshot`, `QuotaProvider`, `QuotaRow`, `CodexResetCreditsSnapshot`, and `ClaudePermissionInteractionKind`.
- Produces: `PresentationMode`, `DynamicIslandTab`, `TaskSourceFilter`, `TaskStateFilter`, `TaskActivityEvent`, `TaskProgressCollectionSnapshot`, `QuotaProviderState`, `ClaudePermissionQueueSnapshot`, `ActivityDashboardSnapshot`, `terminalTaskAcknowledgementKey(for:)`, `ActivityDashboardStore.observe(_:)`, and `PresentationModePreference`.

- [ ] **Step 1: Add the failing model/store self-test**

Register this branch in `main.swift` before the app launch:

```swift
if CommandLine.arguments.contains("--self-test-dynamic-island") {
    runDynamicIslandSelfTest()
}
```

Start `runDynamicIslandSelfTest()` with isolated defaults, full-versus-compact collection assertions, and observer assertions:

```swift
func runDynamicIslandSelfTest() -> Never {
    let suite = "chatbird-dynamic-island-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let preference = PresentationModePreference(defaults: defaults)
    guard preference.mode == .petPanel else { exit(1) }
    preference.mode = .dynamicIsland
    guard PresentationModePreference(defaults: defaults).mode == .dynamicIsland else {
        exit(1)
    }

    let now = Date()
    let active = (0..<7).map {
        TaskProgressItem(
            title: "Active \($0)",
            kind: .running,
            startedAt: now,
            updatedAt: now.addingTimeInterval(TimeInterval($0))
        )
    }
    let terminal = TaskProgressItem(
        title: "Done",
        kind: .completed,
        startedAt: now,
        updatedAt: now
    )
    let collection = TaskProgressCollectionSnapshot.displaying(active + [terminal])
    guard collection.items.count == 8,
          collection.compactProjection().items.count == 7,
          collection.compactProjection().isScrollable
    else { exit(1) }

    let store = ActivityDashboardStore()
    var observed: [ActivityDashboardSnapshot] = []
    let token = store.observe { observed.append($0) }
    store.update { $0.codexDesktopRunning = true }
    store.removeObserver(token)
    store.update { $0.codexDesktopRunning = false }
    guard observed.count == 2, observed.last?.codexDesktopRunning == true else {
        exit(1)
    }

    print(
        "dynamic-island: mode-default=pet mode-persistence=pass "
            + "collection=full+compact store-observer=pass"
    )
    exit(0)
}
```

- [ ] **Step 2: Build to prove the self-test is red**

Run:

```bash
./macos/ChatBirdQuotaPanel/scripts/build.sh
```

Expected: compilation fails because the new dashboard types and `runDynamicIslandSelfTest` implementation dependencies do not exist yet.

- [ ] **Step 3: Implement the stable model surface**

Make `ClaudePermissionInteractionKind` conform to `Equatable`. Add these exact public-to-module types in `ActivityDashboardModels.swift`:

```swift
enum PresentationMode: String, CaseIterable {
    case petPanel = "pet-panel"
    case dynamicIsland = "dynamic-island"
}

enum DynamicIslandTab: String, CaseIterable {
    case tasks
    case confirmation
    case quota
}

enum TaskSourceFilter: String, CaseIterable {
    case all
    case codex
    case claudeCode
}

enum TaskStateFilter: String, CaseIterable {
    case all
    case running
    case waitingForInput
    case completed
    case failed
}

enum TaskActivityEventKind: String, Equatable {
    case commentary
    case tool
    case lifecycle
}

struct TaskActivityEvent: Equatable {
    let kind: TaskActivityEventKind
    let occurredAt: Date
    let text: String
}

struct TaskProgressCollectionSnapshot: Equatable {
    let items: [TaskProgressItem]

    static func displaying(
        _ sourceItems: [TaskProgressItem]
    ) -> TaskProgressCollectionSnapshot {
        let sorted = sourceItems.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.title < $1.title }
            return $0.updatedAt > $1.updatedAt
        }
        var seenKeys = Set<String>()
        return TaskProgressCollectionSnapshot(items: sorted.filter {
            seenKeys.insert($0.deduplicationKey).inserted
        })
    }

    func compactProjection(
        maximumVisibleRows: Int = maximumVisibleTaskRows
    ) -> TaskProgressSnapshot {
        guard maximumVisibleRows > 0, !items.isEmpty else { return .idle }
        let active = items.filter(\.kind.isActive)
        if active.count > maximumVisibleRows {
            return TaskProgressSnapshot(items: active, isScrollable: true)
        }
        let terminal = items.filter {
            $0.kind == .completed || $0.kind == .failed
        }
        let rows = Array((active + terminal).prefix(maximumVisibleRows))
        return rows.isEmpty ? .idle : TaskProgressSnapshot(items: rows)
    }

    func filtered(
        source: TaskSourceFilter,
        state: TaskStateFilter
    ) -> [TaskProgressItem] {
        items.filter { item in
            let sourceMatches: Bool
            switch source {
            case .all: sourceMatches = true
            case .codex: sourceMatches = item.source == .codex
            case .claudeCode: sourceMatches = item.source == .claudeCode
            }
            let stateMatches: Bool
            switch state {
            case .all: stateMatches = true
            case .running: stateMatches = item.kind == .running
            case .waitingForInput:
                stateMatches = item.kind == .waitingForInput
            case .completed: stateMatches = item.kind == .completed
            case .failed: stateMatches = item.kind == .failed
            }
            return sourceMatches && stateMatches
        }
    }

    func count(state: TaskStateFilter) -> Int {
        filtered(source: .all, state: state).count
    }
}

struct QuotaProviderState: Equatable {
    var rows: [QuotaRow] = []
    var resetCredits: CodexResetCreditsSnapshot?
    var statusText = "正在读取额度…"
    var errorText: String?
    var updatedAt: Date?
    var isRefreshing = false
    var isStale = false
}

struct ClaudePermissionQueueItem: Equatable {
    let requestID: UUID
    let interactionKind: ClaudePermissionInteractionKind
    let title: String
    let sessionID: String?
    let arrivedAt: Date
}

struct ClaudePermissionQueueSnapshot: Equatable {
    var current: ClaudePermissionQueueItem? = nil
    var pending: [ClaudePermissionQueueItem] = []
    static let empty = ClaudePermissionQueueSnapshot()
    var count: Int { (current == nil ? 0 : 1) + pending.count }
}

struct ActivityDashboardSnapshot: Equatable {
    var taskCollection = TaskProgressCollectionSnapshot(
        items: TaskProgressSnapshot.reading.items
    )
    var quotaStates: [QuotaProvider: QuotaProviderState] = [:]
    var availableProviders: [QuotaProvider] = [.codex]
    var selectedQuotaProvider: QuotaProvider = .codex
    var permissionQueue = ClaudePermissionQueueSnapshot.empty
    var acknowledgedTerminalTaskKeys = Set<String>()
    var isTaskRefreshing = false
    var codexDesktopRunning = false
}

func terminalTaskAcknowledgementKey(
    for item: TaskProgressItem
) -> String? {
    guard item.kind == .completed || item.kind == .failed else { return nil }
    let updatedMilliseconds = Int64(
        (item.updatedAt.timeIntervalSince1970 * 1_000).rounded()
    )
    return "\(item.identityKey)|\(item.kind.rawValue)|\(updatedMilliseconds)"
}
```

`TaskProgressCollectionSnapshot.displaying(_:)` must sort by `updatedAt` descending, deduplicate by `deduplicationKey`, and keep every active/currently visible terminal item. `compactProjection(maximumVisibleRows:)` must reproduce the current rule exactly: all active rows remain scrollable when active count exceeds the limit; otherwise active rows are followed by newest completed/failed rows up to the limit; an empty result returns `.idle`.

`acknowledgedTerminalTaskKeys` is the sole in-memory source for whether a particular completed/failed occurrence has already been opened in the current process. It stores `terminalTaskAcknowledgementKey(for:)`, which includes identity, terminal kind, and terminal update time so a later run of the same Claude session can surface again. The set is never persisted; Task 6 consumes it and Task 10 updates it through the store.

- [ ] **Step 4: Implement the main-thread store and preference**

Add this ownership contract in `ActivityDashboardStore.swift`:

```swift
final class ActivityDashboardStore {
    typealias Observer = (ActivityDashboardSnapshot) -> Void

    private(set) var snapshot: ActivityDashboardSnapshot
    private var observers: [UUID: Observer] = [:]

    init(snapshot: ActivityDashboardSnapshot = ActivityDashboardSnapshot()) {
        self.snapshot = snapshot
    }

    @discardableResult
    func observe(_ observer: @escaping Observer) -> UUID {
        precondition(Thread.isMainThread)
        let token = UUID()
        observers[token] = observer
        observer(snapshot)
        return token
    }

    func removeObserver(_ token: UUID) {
        precondition(Thread.isMainThread)
        observers.removeValue(forKey: token)
    }

    func update(_ mutation: (inout ActivityDashboardSnapshot) -> Void) {
        precondition(Thread.isMainThread)
        let previous = snapshot
        mutation(&snapshot)
        guard snapshot != previous else { return }
        for observer in observers.values {
            observer(snapshot)
        }
    }
}

final class PresentationModePreference {
    private let defaults: UserDefaults
    private let key = "presentation-mode"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var mode: PresentationMode {
        get {
            guard let raw = defaults.string(forKey: key),
                  let mode = PresentationMode(rawValue: raw)
            else { return .petPanel }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: key) }
    }
}
```

- [ ] **Step 5: Build and run the new self-test**

Run:

```bash
./macos/ChatBirdQuotaPanel/scripts/build.sh
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-dynamic-island
```

Expected: exit code 0 after printing a summary that includes `mode-default=pet`, `mode-persistence=pass`, `collection=full+compact`, and `store-observer=pass`.

- [ ] **Step 6: Record the local checkpoint if Git mutation is authorized**

```bash
git add \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ActivityDashboardModels.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ActivityDashboardStore.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandSelfTest.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ClaudeHookSupport.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/main.swift
git commit \
  -m "让两套展示共享同一份可验证状态" \
  -m "Constraint: 现有宠物面板仍是默认模式" \
  -m "Rejected: 让两套视图互相读取属性 | 会造成双向状态漂移" \
  -m "Confidence: high" \
  -m "Scope-risk: moderate" \
  -m "Directive: 新展示只能订阅 ActivityDashboardStore" \
  -m "Tested: --self-test-dynamic-island" \
  -m "Not-tested: 尚未接入运行时刷新"
```

If Git mutation is not authorized, do not stage anything; record the passing command and continue to Task 2.

---

### Task 2: Produce the Full Task Collection, Safe Events, and Codex Working Directory

**Files:**
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/TaskProgressModels.swift:50-325`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/CodexTaskProgress.swift:47-103,105-259`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ClaudeTaskProgress.swift:308-405,420-584,827-845`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/TaskProgressSelfTest.swift:139-678`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/AppDelegate.swift:331-335,785-815`

**Interfaces:**
- Consumes: `TaskProgressCollectionSnapshot.displaying(_:)` and the existing reader caches/freshness filters.
- Produces: `TaskProgressItem.events`, `CodexTaskProgressReader.readCollection()`, `ClaudeTaskProgressReader.readCollection()`, `CombinedTaskProgressReader.readCollection(claudeCodeAvailable:)`, and a compact compatibility `read(...)` for the pet panel.

- [ ] **Step 1: Add failing full-collection, cwd, event, and privacy assertions**

Extend `--self-test-task-progress` with:

```swift
let sessionMeta = #"{"type":"session_meta","payload":{"cwd":"/tmp/chatbird","thread_source":"root"}}"#
let parsedWithDirectory = CodexTaskProgressReader.parse(
    lines: [sessionMeta, timestampedStarted, publicCommentary, commandStarted],
    modificationDate: now,
    now: now
)
guard parsedWithDirectory.items.first?.workingDirectory == "/tmp/chatbird",
      parsedWithDirectory.items.first?.events.count == 3,
      parsedWithDirectory.items.first?.events.allSatisfy({
          $0.text.count <= 280
              && !$0.text.contains("secret")
              && !$0.text.contains("隐藏推理")
      }) == true
else { exit(1) }

let full = TaskProgressCollectionSnapshot.displaying(
    (0..<7).map {
        TaskProgressItem(
            title: "Run \($0)",
            kind: .running,
            startedAt: now,
            updatedAt: now.addingTimeInterval(TimeInterval($0))
        )
    } + [
        TaskProgressItem(title: "Failed", kind: .failed, startedAt: now)
    ]
)
guard full.items.count == 8,
      full.compactProjection().items.count == 7,
      full.filtered(source: .all, state: .failed).count == 1
else { exit(1) }
```

Add equivalent Claude transcript assertions for three most-recent public text/generic tool events and for exclusion of `thinking`, `tool_use.input`, and `tool_result` content.

- [ ] **Step 2: Run the existing task self-test to prove it is red**

Run:

```bash
./macos/ChatBirdQuotaPanel/scripts/build.sh
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-task-progress
```

Expected: compilation or assertions fail because `events`, full collection reads, and Codex cwd propagation are absent.

- [ ] **Step 3: Carry bounded events on every task**

Add `let events: [TaskActivityEvent]` to `TaskProgressItem`. Append this argument to its initializer and assign it so every existing call site keeps compiling:

```swift
init(
    title: String,
    kind: TaskProgressKind,
    startedAt: Date = .distantPast,
    updatedAt: Date? = nil,
    source: TaskSource = .codex,
    activityText: String? = nil,
    statusOverride: String? = nil,
    threadID: String? = nil,
    sessionID: String? = nil,
    workingDirectory: String? = nil,
    processID: Int32? = nil,
    processStartIdentity: String? = nil,
    events: [TaskActivityEvent] = []
) {
    self.title = title
    self.kind = kind
    self.startedAt = startedAt
    self.updatedAt = updatedAt ?? startedAt
    self.source = source
    self.activityText = activityText
    self.statusOverride = statusOverride
    self.threadID = threadID
    self.sessionID = sessionID
    self.workingDirectory = workingDirectory.flatMap(normalizedAbsolutePath)
    self.processID = processID
    self.processStartIdentity = processStartIdentity
    self.events = events
}
```

Add this shared bounded append helper:

```swift
func appendingTaskActivityEvent(
    _ event: TaskActivityEvent,
    to events: [TaskActivityEvent],
    limit: Int = 3,
    maximumCharacters: Int = 280
) -> [TaskActivityEvent] {
    guard limit > 0, maximumCharacters > 0 else { return [] }
    let boundedEvent = TaskActivityEvent(
        kind: event.kind,
        occurredAt: event.occurredAt,
        text: String(event.text.prefix(maximumCharacters))
    )
    var next = events.filter {
        !($0.kind == boundedEvent.kind && $0.text == boundedEvent.text)
    }
    next.append(boundedEvent)
    next.sort {
        if $0.occurredAt == $1.occurredAt { return $0.text < $1.text }
        return $0.occurredAt < $1.occurredAt
    }
    return Array(next.suffix(limit))
}
```

Change `TaskProgressSnapshot.displaying(_:)` to:

```swift
static func displaying(_ sourceItems: [TaskProgressItem]) -> TaskProgressSnapshot {
    TaskProgressCollectionSnapshot.displaying(sourceItems).compactProjection()
}
```

This preserves the pet panel's current projection while allowing the new workspace to consume the full collection.

- [ ] **Step 4: Extract Codex cwd and safe events**

Allow `session_meta` lines through the parser's cheap line filter. Before requiring `payload.type`, recognize:

```swift
if record["type"] as? String == "session_meta",
   let payload = record["payload"] as? [String: Any],
   let rawCwd = payload["cwd"] as? String,
   let cwd = normalizedAbsolutePath(rawCwd) {
    workingDirectory = cwd
    continue
}
```

Track `workingDirectory: String?` and `events: [TaskActivityEvent]`. Append only:

- `任务开始`/`等待输入`/`任务完成`/`任务失败` lifecycle labels.
- `sanitizedPublicCommentary(_:)` output from public `agent_message` records.
- `safeToolActivity(name:)` generic labels at tool start.

Never read `arguments` or output fields when creating an event. Carry `workingDirectory` and `events` through the resolved-title reconstruction at `CodexTaskProgress.swift:78-86`.

Rename the current `CodexTaskProgressReader.read()` implementation to `readCollection()`. Keep its existing cache lookup, freshness checks, unread-state checks, title resolution, visibility filtering, and single scan in the renamed body; change only its return type and final projection. Then add the compact wrapper:

```swift
func readCollection() -> TaskProgressCollectionSnapshot {
    let now = Date()
    let threadTitles = readThreadTitleIndex()
    let unreadState = readUnreadThreadState()
    var items: [TaskProgressItem] = []

    for candidate in recentRollouts(
        at: now,
        unreadThreadIDs: unreadState.ids
    ) {
        let cacheKey = candidate.url.path
        let snapshot: TaskProgressSnapshot
        if let cached = parsedCache[cacheKey],
           cached.modificationDate == candidate.modificationDate {
            snapshot = cached.snapshot
        } else {
            guard let lines = readTailLines(from: candidate.url) else {
                continue
            }
            snapshot = Self.parse(
                lines: lines,
                modificationDate: candidate.modificationDate,
                now: now
            )
            parsedCache[cacheKey] = ParsedCacheEntry(
                modificationDate: candidate.modificationDate,
                snapshot: snapshot
            )
        }
        guard var item = snapshot.items.first, item.kind != .idle else {
            continue
        }
        let resolvedTitle = Self.resolvedTitle(
            for: candidate.url,
            indexedTitles: threadTitles,
            fallback: item.title
        )
        let threadID = Self.threadID(from: candidate.url)
        item = TaskProgressItem(
            title: resolvedTitle,
            kind: item.kind,
            startedAt: item.startedAt,
            updatedAt: item.updatedAt,
            activityText: item.activityText,
            statusOverride: item.statusOverride,
            threadID: threadID,
            workingDirectory: item.workingDirectory,
            events: item.events
        )
        guard Self.shouldDisplay(
            kind: item.kind,
            threadID: threadID,
            modificationDate: candidate.modificationDate,
            now: now,
            unreadState: unreadState,
            fallbackVisibility: completedTaskVisibility
        ) else { continue }
        items.append(item)
    }

    return .displaying(items)
}

func read() -> TaskProgressSnapshot {
    readCollection().compactProjection()
}
```

This is a mechanical extraction of the existing scan, not a second reader path. Do not sort or project inside the loop; `TaskProgressCollectionSnapshot.displaying(_:)` performs the one final sort/deduplication pass.

- [ ] **Step 5: Extract Claude safe events and full collection**

In `parseTranscript`, append `TaskActivityEvent` values only for assistant `text` blocks after `taskActivityParagraph(from:)` sanitization, generic `safeToolActivity(name:)` labels, and lifecycle changes. Ignore `thinking` blocks, every `tool_use.input` value, and every `tool_result` body.

Rename the current `ClaudeTaskProgressReader.read()` body to `readCollection()`, change its return type to `TaskProgressCollectionSnapshot`, and keep the candidate/agent cache and transcript loop unchanged through its final `return .displaying(items)`. Add this wrapper immediately below it so `claude agents` and transcript scans still run once:

```swift
func read() -> TaskProgressSnapshot {
    readCollection().compactProjection()
}
```

Change `CombinedTaskProgressReader` to:

```swift
func readCollection(
    claudeCodeAvailable: Bool = true
) -> TaskProgressCollectionSnapshot {
    let codexItems = codexReader.readCollection().items.filter {
        $0.kind != .idle && $0.kind != .reading
    }
    let claudeItems = claudeCodeAvailable
        ? claudeReader.readCollection().items.filter {
            $0.kind != .idle && $0.kind != .reading
        }
        : []
    return .displaying(combinedTaskProgressItems(
        codexItems: codexItems,
        claudeItems: claudeItems,
        claudeCodeAvailable: claudeCodeAvailable
    ))
}

func read(claudeCodeAvailable: Bool = true) -> TaskProgressSnapshot {
    readCollection(claudeCodeAvailable: claudeCodeAvailable)
        .compactProjection()
}
```

- [ ] **Step 6: Publish the full collection without using the view as a data source**

Add `private let dashboardStore = ActivityDashboardStore()` and an observer token to `AppDelegate`. Set the refresh bit only after the existing gate accepts a generation:

```swift
guard let generation = taskProgressRefreshGate.begin() else { return }
dashboardStore.update { $0.isTaskRefreshing = true }
```

During the background read and main-queue completion, preserve the reader lease and stale-generation rules exactly:

```swift
let collection = reader.readCollection(
    claudeCodeAvailable: claudeCodeAvailable
)
DispatchQueue.main.async {
    guard let self else {
        readerStore.releaseReader(for: generation, reuse: false)
        return
    }
    let shouldApply = self.taskProgressRefreshGate.complete(
        generation: generation
    )
    readerStore.releaseReader(for: generation, reuse: shouldApply)
    guard shouldApply else { return }

    self.dashboardStore.update {
        $0.taskCollection = collection
        $0.isTaskRefreshing = false
    }
    let compact = collection.compactProjection()
    self.quotaView.taskProgress = compact
    self.claudePermissionPanelController?
        .dismissIfAnsweredInTerminal(in: collection.items)
    let nextBaseSize = panelSizeForTaskRows(compact.rowCount)
    if nextBaseSize != self.currentBasePanelSize {
        self.currentBasePanelSize = nextBaseSize
        self.followPet()
    }
}
```

Task 2 deliberately continues calling the existing `claudePermissionPanelController`; Task 4 performs the coordinator migration after the shared task collection is stable. Change `openTerminalForClaudePermission` to use `dashboardStore.snapshot.taskCollection.items` instead of `quotaView.taskProgress.items`.

- [ ] **Step 7: Run task and legacy panel regressions**

Run:

```bash
./macos/ChatBirdQuotaPanel/scripts/build.sh
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-task-progress
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-lifecycle
```

Expected: both exit 0; the task summary includes `full-collection=pass`, `codex-cwd=pass`, `events=bounded-3`, and `privacy=pass` while all existing task assertions remain present.

- [ ] **Step 8: Record the local checkpoint if Git mutation is authorized**

```bash
git add \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/TaskProgressModels.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/CodexTaskProgress.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ClaudeTaskProgress.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/TaskProgressSelfTest.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/AppDelegate.swift
git commit \
  -m "让完整任务细节可用而不扩大隐私面" \
  -m "Constraint: 旧面板仍使用原有五行投影" \
  -m "Rejected: 从文本猜测步骤进度 | 没有结构化数据来源" \
  -m "Confidence: high" \
  -m "Scope-risk: moderate" \
  -m "Directive: 最近事件只接受白名单公开内容且最多三条" \
  -m "Tested: --self-test-task-progress; --self-test-lifecycle" \
  -m "Not-tested: 灵动岛任务工作台尚未绘制"
```

---

### Task 3: Move Quota State Into the Store and Preserve Stale Reset Credits

**Files:**
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/AppDelegate.swift:34-37,609-783`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/QuotaPanelView.swift:16-83`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/QuotaSelfTests.swift:77-342`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandSelfTest.swift`

**Interfaces:**
- Consumes: `ActivityDashboardSnapshot.quotaStates` and existing `CodexQuotaClient`/`ClaudeQuotaClient` results.
- Produces: per-provider single-flight refresh state, `QuotaPanelView.applyDashboardSnapshot(_:)`, and stale-data preservation for both rows and reset credits.

- [ ] **Step 1: Add a failing stale-cache regression**

Extract a pure reducer and test it with existing Codex rows/reset credits:

```swift
let cached = QuotaProviderState(
    rows: [QuotaRow(
        name: "周额度",
        remainingPercent: 64,
        resetsAt: resetReferenceDate
    )],
    resetCredits: resetCredits,
    statusText: "12:00 更新",
    errorText: nil,
    updatedAt: resetReferenceDate,
    isRefreshing: true,
    isStale: false
)
let failed = quotaProviderStateAfterFailure(
    cached,
    error: QuotaClientError.noResponse,
    provider: .codex
)
guard failed.rows == cached.rows,
      failed.resetCredits == resetCredits,
      failed.isStale,
      failed.isRefreshing == false
else { exit(1) }
```

Also assert a first-ever failure has empty rows, no reset credits, `isStale == false`, and the existing provider-specific error copy. Assert a successful response with zero rows records `updatedAt`, is not stale, and uses `没有可确认的额度数据` rather than remaining indistinguishable from first load.

- [ ] **Step 2: Run weekly quota self-test to prove it is red**

Run:

```bash
./macos/ChatBirdQuotaPanel/scripts/build.sh
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-weekly-quota
```

Expected: compilation or assertion failure because the reducer does not exist and the current failure branch clears Codex reset credits.

- [ ] **Step 3: Implement quota success/failure reducers**

Add pure functions next to `QuotaProviderState`:

```swift
func quotaProviderStateAfterSuccess(
    _ previous: QuotaProviderState,
    rows: [QuotaRow],
    resetCredits: CodexResetCreditsSnapshot?,
    provider: QuotaProvider,
    updatedAt: Date
) -> QuotaProviderState {
    var next = previous
    next.rows = rows
    next.resetCredits = provider == .codex ? resetCredits : nil
    next.statusText = rows.isEmpty
        ? "没有可确认的额度数据"
        : quotaSuccessStatusText(
            provider: provider,
            rows: rows,
            updatedAt: updatedAt
        )
    next.errorText = nil
    next.updatedAt = updatedAt
    next.isRefreshing = false
    next.isStale = false
    return next
}

func quotaProviderStateAfterFailure(
    _ previous: QuotaProviderState,
    error: Error,
    provider: QuotaProvider
) -> QuotaProviderState {
    let hasCachedValues = !previous.rows.isEmpty
        || previous.resetCredits != nil
    let presentation = quotaFailurePresentation(
        for: error,
        hasExistingRows: hasCachedValues,
        provider: provider
    )
    var next = previous
    next.statusText = presentation.statusText
    next.errorText = presentation.errorText
    next.isRefreshing = false
    next.isStale = hasCachedValues
    return next
}
```

The successful-empty branch deliberately records `updatedAt` and uses explicit empty-data copy so it is distinguishable from first load. The failure reducer keeps rows, reset credits, and the last successful timestamp unchanged.

- [ ] **Step 4: Replace view-owned quota state in AppDelegate**

Replace `isRefreshing`, `quotaRowsByProvider`, and `currentCodexResetCreditsSnapshot` with:

```swift
private var refreshingQuotaProviders = Set<QuotaProvider>()
```

Implement:

```swift
private func refreshQuota(provider requestedProvider: QuotaProvider? = nil) {
    let provider = requestedProvider
        ?? dashboardStore.snapshot.selectedQuotaProvider
    guard dashboardStore.snapshot.availableProviders.contains(provider),
          refreshingQuotaProviders.insert(provider).inserted
    else { return }

    dashboardStore.update {
        var state = $0.quotaStates[provider] ?? QuotaProviderState()
        state.isRefreshing = true
        state.statusText = state.rows.isEmpty ? "正在读取额度…" : "正在更新…"
        $0.quotaStates[provider] = state
    }

    switch provider {
    case .codex:
        quotaClient.fetch { [weak self] result in
            let payloadResult = result.map { response in
                QuotaRefreshPayload(
                    rows: Self.makeRows(from: response),
                    resetCredits: makeCodexResetCreditsSnapshot(
                        from: response,
                        now: Date()
                    )
                )
            }
            DispatchQueue.main.async {
                self?.completeQuotaRefresh(
                    provider: provider,
                    result: payloadResult
                )
            }
        }
    case .claudeCode:
        claudeQuotaClient.fetch { [weak self] result in
            let payloadResult = result.map {
                QuotaRefreshPayload(rows: $0.rows, resetCredits: nil)
            }
            DispatchQueue.main.async {
                self?.completeQuotaRefresh(
                    provider: provider,
                    result: payloadResult
                )
            }
        }
    }
}

private func completeQuotaRefresh(
    provider: QuotaProvider,
    result: Result<QuotaRefreshPayload, Error>
) {
    refreshingQuotaProviders.remove(provider)
    let previous = dashboardStore.snapshot.quotaStates[provider]
        ?? QuotaProviderState()
    let next: QuotaProviderState
    switch result {
    case .success(let payload):
        next = quotaProviderStateAfterSuccess(
            previous,
            rows: payload.rows,
            resetCredits: payload.resetCredits,
            provider: provider,
            updatedAt: Date()
        )
    case .failure(let error):
        next = quotaProviderStateAfterFailure(
            previous,
            error: error,
            provider: provider
        )
    }
    dashboardStore.update { $0.quotaStates[provider] = next }
}
```

`synchronizeQuotaProviderAvailability()` writes `availableProviders` and the resolved selection to the store and persists a fallback from unavailable Claude to Codex. `selectQuotaProvider(_:)` validates against `dashboardStore.snapshot.availableProviders`, updates the preference and store selection, then refreshes that provider. At launch, replace the separate selected/background calls with `availableProviders.forEach { refreshQuota(provider: $0) }`; delete `refreshBackgroundQuotaSummary(for:)` and `cacheQuotaRows(_:for:)`. The 60-second timer calls `refreshQuota()` so only the selected provider refreshes automatically. No branch may read `quotaView.rows` or `quotaView.selectedQuotaProvider`.

- [ ] **Step 5: Make the old view a snapshot consumer**

Add:

```swift
func applyDashboardSnapshot(_ snapshot: ActivityDashboardSnapshot) {
    let provider = snapshot.selectedQuotaProvider
    let quota = snapshot.quotaStates[provider] ?? QuotaProviderState()
    availableQuotaProviders = snapshot.availableProviders
    selectedQuotaProvider = provider
    rows = quota.rows
    codexResetCredits = snapshot.quotaStates[.codex]?.resetCredits
    statusText = quota.statusText
    errorText = quota.errorText
    isQuotaRefreshing = quota.isRefreshing
    taskProgress = snapshot.taskCollection.compactProjection()
    providerRemainingPercents = quotaProviderRemainingPercents(
        from: snapshot.quotaStates
    )
}
```

Replace the incremental view-summary helper with a deterministic projection from store state:

```swift
func quotaProviderRemainingPercents(
    from states: [QuotaProvider: QuotaProviderState]
) -> [QuotaProvider: Int] {
    var result: [QuotaProvider: Int] = [:]
    for provider in QuotaProvider.allCases {
        guard let remaining = states[provider]?.rows.first(where: {
            $0.name == provider.summaryRowName
        })?.remainingPercent else { continue }
        result[provider] = remaining
    }
    return result
}
```

The AppDelegate store observer calls this method immediately and after every store mutation. Once that observer is installed, delete the direct `quotaView.taskProgress = compact` write introduced as Task 2's compatibility bridge; keep the `compact.rowCount` panel-size calculation so pet-mode geometry remains unchanged. All view values now arrive through `applyDashboardSnapshot(_:)`. Keep every existing callback (`onRequestHide`, `onOpenTask`, `onRequestQuotaRefresh`, `onSelectQuotaProvider`, `onHoverRunningTask`) unchanged.

- [ ] **Step 6: Run quota, task, and client regressions**

Run:

```bash
./macos/ChatBirdQuotaPanel/scripts/build.sh
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-weekly-quota
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-claude-quota
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-task-progress
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-client-contract
```

Expected: all exit 0; weekly quota reports `stale-reset-credits=preserved` and the old provider visibility/fallback assertions still pass.

- [ ] **Step 7: Record the local checkpoint if Git mutation is authorized**

```bash
git add \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/AppDelegate.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/QuotaPanelView.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/QuotaSelfTests.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandSelfTest.swift
git commit \
  -m "让额度刷新失败仍保留最后可信数据" \
  -m "Constraint: 两套展示必须看到相同 provider 状态" \
  -m "Rejected: 失败时清空重置额度 | 会把缓存误呈现为无额度" \
  -m "Confidence: high" \
  -m "Scope-risk: moderate" \
  -m "Directive: AppDelegate 不再读取 QuotaPanelView 作为状态源" \
  -m "Tested: weekly quota; Claude quota; task progress; client contract" \
  -m "Not-tested: 灵动岛额度页尚未绘制"
```

---

### Task 4: Extract One Claude Permission Coordinator and Preserve the Legacy Presenter

**Files:**
- Create: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ClaudePermissionCoordinator.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ClaudePermissionPanel.swift:13-199`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ClaudeHookSupport.swift:736-978`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/AppDelegate.swift:24-25,133-138,266-312,785-810`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandSelfTest.swift`

**Interfaces:**
- Consumes: existing `ClaudePermissionPrompt`, `ClaudePermissionUserDecision`, `claudeTaskItem(forSessionID:in:)`, and existing blue `ClaudePermissionPromptViewController`.
- Produces: `ClaudePermissionPresentation`, `ClaudePermissionPresenting`, `ClaudePermissionCoordinator`, and `ClaudePermissionPanelPresenter`.

- [ ] **Step 1: Add failing coordinator tests before moving queue code**

Add a presenter spy and assertions to `DynamicIslandSelfTest.swift`:

```swift
private final class ClaudePermissionPresenterSpy: ClaudePermissionPresenting {
    var presentations: [ClaudePermissionPresentation] = []
    var dismissCount = 0
    func present(_ presentation: ClaudePermissionPresentation) {
        presentations.append(presentation)
    }
    func dismiss() { dismissCount += 1 }
    func reposition() {}
}
```

Create two prompts with distinct request IDs. Assert:

- Duplicate IDs are ignored.
- FIFO queue counts are `1` then `2`.
- Binding a second presenter dismisses the first and re-presents the same current request without completing it.
- One user decision invokes one completion.
- Expiring the current request advances to the next request without invoking the expired completion.
- Terminal auto-dismiss happens only after the matching session is first observed as `waitingForInput` and then as non-waiting.
- `cancelAll()` completes every outstanding server request with `.nativeFallback` but does not open a terminal.

- [ ] **Step 2: Run Claude Hook self-test to prove extraction is red**

Run:

```bash
./macos/ChatBirdQuotaPanel/scripts/build.sh
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-claude-hook
```

Expected: compilation fails because the coordinator/presenter interfaces do not exist.

- [ ] **Step 3: Implement the presenter contract and coordinator**

Add these exact interfaces:

```swift
struct ClaudePermissionPresentation {
    let prompt: ClaudePermissionPrompt
    let queue: ClaudePermissionQueueSnapshot
    let onDecision: (ClaudePermissionUserDecision) -> Void
}

protocol ClaudePermissionPresenting: AnyObject {
    func present(_ presentation: ClaudePermissionPresentation)
    func dismiss()
    func reposition()
}

final class ClaudePermissionCoordinator {
    private struct Entry {
        let prompt: ClaudePermissionPrompt
        let arrivedAt: Date
        let completion: (ClaudePermissionUserDecision) -> Void
    }

    init(
        now: @escaping () -> Date = Date.init,
        openTerminal: @escaping (ClaudePermissionPrompt) -> Void,
        onQueueChange: @escaping (ClaudePermissionQueueSnapshot) -> Void
    )

    func setPresenter(_ presenter: ClaudePermissionPresenting?)
    func enqueue(
        prompt: ClaudePermissionPrompt,
        completion: @escaping (ClaudePermissionUserDecision) -> Void
    )
    func expire(requestID: UUID)
    func dismissIfAnsweredInTerminal(in tasks: [TaskProgressItem]) -> Bool
    func handoffToTerminalIfPresenting(_ task: TaskProgressItem) -> Bool
    func cancelAll()
}
```

Coordinator rules:

1. `currentEntry` and `entries` are the only request owners.
2. `setPresenter` dismisses the previous presenter, stores the new one, and presents the current entry with the current queue snapshot.
3. `finishCurrent(decision:openTerminal:)` clears the current entry before calling completion, so a reentrant callback cannot complete it twice.
4. User-selected `.nativeFallback` and task-row handoff call `openTerminal`. Terminal state auto-dismiss and `cancelAll` do not open a terminal.
5. `expire(requestID:)` removes ownership without calling the now-disconnected server completion.
6. Every mutation publishes `ClaudePermissionQueueSnapshot` before presenting the next request.

- [ ] **Step 4: Convert the current controller into a legacy presenter**

Rename `ClaudePermissionPanelController` to `ClaudePermissionPanelPresenter` and make it conform to `ClaudePermissionPresenting`. Delete its `Entry`, `entries`, `currentEntry`, terminal-transition, completion, and cancellation fields/methods.

Its `present(_:)` implementation must:

```swift
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
```

`dismiss()` retains the existing `orderOut`/content cleanup behavior. `reposition()` retains the existing anchor-window geometry. The existing blue visual controllers remain byte-for-byte behaviorally equivalent.

- [ ] **Step 5: Rewire AppDelegate to the coordinator**

Replace the controller property with:

```swift
private var claudePermissionCoordinator: ClaudePermissionCoordinator!
private var claudePermissionPanelPresenter: ClaudePermissionPanelPresenter!
```

Build both in `startClaudePermissionHook()`. Publish queue changes to the store:

```swift
claudePermissionCoordinator = ClaudePermissionCoordinator(
    openTerminal: { [weak self] prompt in
        self?.openTerminalForClaudePermission(prompt)
    },
    onQueueChange: { [weak self] queue in
        self?.dashboardStore.update { $0.permissionQueue = queue }
    }
)
claudePermissionPanelPresenter = ClaudePermissionPanelPresenter(
    anchorWindowProvider: { [weak self] in self?.panel }
)
claudePermissionCoordinator.setPresenter(claudePermissionPanelPresenter)
```

Hook `onPrompt`/`onRequestExpired`, Codex exit, app termination, task auto-dismiss, and Claude task handoff all call the coordinator. Preserve `shouldPresentClaudePermissionPanel(cached:live:)` and its live-state-wins behavior.

- [ ] **Step 6: Run coordinator and current-UI regressions**

Run:

```bash
./macos/ChatBirdQuotaPanel/scripts/build.sh
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-dynamic-island
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-claude-hook
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-lifecycle
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-task-progress
```

Expected: all exit 0. Existing Hook output still reports protocol, question paging, handoff, terminal auto-dismiss, auth, queue-limit, install/uninstall, and disconnect coverage; new output reports `presenter-switch=no-completion` and `decision=exactly-once`.

- [ ] **Step 7: Render and compare the unchanged legacy confirmation states**

Run:

```bash
mkdir -p output/audit/dynamic-island-implementation/legacy-confirmation
BIN="macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel"
"$BIN" --render-claude-hook-preview tool output/audit/dynamic-island-implementation/legacy-confirmation/tool.png
"$BIN" --render-claude-hook-preview question output/audit/dynamic-island-implementation/legacy-confirmation/question.png
"$BIN" --render-claude-hook-preview plan output/audit/dynamic-island-implementation/legacy-confirmation/plan.png
```

Compare them to `output/audit/dynamic-island-review/02-current-confirm-tool.png`, `03-current-confirm-question.png`, and `04-current-confirm-plan.png`. Any visual change is a regression and must be corrected before Task 5.

- [ ] **Step 8: Record the local checkpoint if Git mutation is authorized**

```bash
git add \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ClaudePermissionCoordinator.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ClaudePermissionPanel.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ClaudeHookSupport.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/AppDelegate.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandSelfTest.swift
git commit \
  -m "让确认请求在切换展示时仍只有一个所有者" \
  -m "Constraint: Hook 协议和旧确认窗口表现必须保持" \
  -m "Rejected: 两套窗口各自维护队列 | 会重复回答同一请求" \
  -m "Confidence: high" \
  -m "Scope-risk: broad" \
  -m "Directive: presenter 只能展示，不能拥有请求生命周期" \
  -m "Tested: dynamic-island; Claude Hook; lifecycle; task progress; three legacy renders" \
  -m "Not-tested: 新确认工作台尚未接入"
```

---

### Task 5: Build Pure Top Placement and the Independent Window State Machine

**Files:**
- Create: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandPlacement.swift`
- Create: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandWindowController.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandSelfTest.swift`

**Interfaces:**
- Consumes: `DynamicIslandTab`, `ActivityDashboardStore`, `NSScreen`, accessibility display preferences, `WindowStackEntry`, and the existing native-activity intersection/occlusion helpers.
- Produces: `DynamicIslandPresentationState`, `DynamicIslandPanel`, `dynamicIslandFrame(size:visibleFrame:topGap:)`, `dynamicIslandFittedSize(requested:visibleFrame:)`, and `DynamicIslandWindowController` visibility/state/level methods.

- [ ] **Step 1: Add failing placement and transition tests**

Assert exact geometry for:

```swift
let visible = NSRect(x: -1440, y: 0, width: 1440, height: 900)
let capsule = dynamicIslandFrame(
    size: NSSize(width: 404, height: 58),
    visibleFrame: visible,
    topGap: 6
)
guard capsule.midX == visible.midX,
      capsule.maxY == visible.maxY - 6
else { exit(1) }

let expanded = dynamicIslandFrame(
    size: NSSize(width: 820, height: 560),
    visibleFrame: visible,
    topGap: 6
)
guard expanded.maxY == capsule.maxY else { exit(1) }
```

Also assert:

- A 700pt-wide screen fits width to `visibleFrame.width - 16`.
- A short screen fits height to `visibleFrame.height - 12`.
- A notched screen fixture with populated safe-area/auxiliary top regions still places the entire panel below `visibleFrame.maxY`; no frame is proposed inside either auxiliary menu-bar region.
- Negative screen coordinates remain valid.
- `hidden -> capsule -> expanded(.tasks) -> expanded(.quota) -> capsule -> hidden` is accepted.
- A second expansion request during animation is ignored.
- Escape/outside click from expanded produces capsule, never hidden.
- A visible Dynamic Island temporarily uses `panelNativeActivityWindowLevel` only while a Codex native-activity stack intersects it, returns to `panelDefaultWindowLevel` afterward, and never adopts the legacy confirmation panel's `statusBar + 2` level.

- [ ] **Step 2: Run the Dynamic Island self-test to prove it is red**

Run:

```bash
./macos/ChatBirdQuotaPanel/scripts/build.sh
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-dynamic-island
```

Expected: compilation fails because placement/state types do not exist.

- [ ] **Step 3: Implement pure geometry and screen identity**

Add:

```swift
enum DynamicIslandPresentationState: Equatable {
    case hidden
    case capsule
    case expanded(DynamicIslandTab)
}

let dynamicIslandCapsuleSize = NSSize(width: 404, height: 58)
let dynamicIslandTaskSize = NSSize(width: 820, height: 560)
let dynamicIslandConfirmationSize = NSSize(width: 820, height: 600)
let dynamicIslandQuotaSize = NSSize(width: 820, height: 470)
let dynamicIslandTopGap: CGFloat = 6
let dynamicIslandHorizontalMargin: CGFloat = 8
let dynamicIslandBottomMargin: CGFloat = 6

func dynamicIslandRequestedSize(
    for state: DynamicIslandPresentationState
) -> NSSize {
    switch state {
    case .hidden, .capsule:
        return dynamicIslandCapsuleSize
    case .expanded(.tasks):
        return dynamicIslandTaskSize
    case .expanded(.confirmation):
        return dynamicIslandConfirmationSize
    case .expanded(.quota):
        return dynamicIslandQuotaSize
    }
}

func dynamicIslandFittedSize(
    requested: NSSize,
    visibleFrame: NSRect
) -> NSSize {
    NSSize(
        width: min(
            requested.width,
            max(1, visibleFrame.width - 2 * dynamicIslandHorizontalMargin)
        ),
        height: min(
            requested.height,
            max(
                1,
                visibleFrame.height
                    - dynamicIslandTopGap
                    - dynamicIslandBottomMargin
            )
        )
    )
}

func dynamicIslandFrame(
    size requested: NSSize,
    visibleFrame: NSRect,
    topGap: CGFloat = dynamicIslandTopGap
) -> NSRect {
    let size = dynamicIslandFittedSize(
        requested: requested,
        visibleFrame: visibleFrame
    )
    let top = visibleFrame.maxY - topGap
    return NSRect(
        x: visibleFrame.midX - size.width / 2,
        y: top - size.height,
        width: size.width,
        height: size.height
    )
}
```

Use `NSScreenNumber` from `screen.deviceDescription` as `CGDirectDisplayID`. Read `frame`, `visibleFrame`, `safeAreaInsets`, `auxiliaryTopLeftArea`, and `auxiliaryTopRightArea` from the selected `NSScreen`; placement always uses the menu-bar-excluding `visibleFrame`, while safe/auxiliary values are retained for assertions that the result never enters the physical notch or menu-item bands. On first creation choose the screen containing `NSEvent.mouseLocation`, falling back to `NSScreen.main`; after that the controller stores only the selected display ID. When that ID disappears, replace it with the main screen ID; reconnecting the prior display does not switch back automatically.

- [ ] **Step 4: Implement the panel and state controller**

Add:

```swift
final class DynamicIslandPanel: NSPanel {
    var allowsKeyWindow = false
    override var canBecomeKey: Bool { allowsKeyWindow }
    override var canBecomeMain: Bool { false }
}

final class DynamicIslandWindowController {
    private(set) var state: DynamicIslandPresentationState = .hidden
    private(set) var targetDisplayID: CGDirectDisplayID?
    private(set) var isAnimating = false

    func showCapsule()
    func expand(_ tab: DynamicIslandTab)
    func collapse()
    func hide()
    func moveToScreenContainingMouse()
    func screenParametersDidChange()
    func setConfirmationInputActive(_ active: Bool)
    func reconcileWindowLevel(entries: [WindowStackEntry])
}
```

Create a separate `DynamicIslandPanel` with `[.borderless, .nonactivatingPanel]`, clear background, shadow, `statusBar` level, `hidesOnDeactivate = false`, `isMovable = false`, `isReleasedWhenClosed = false`, and `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`. Do not reuse `AppDelegate.panel`.

`expand(_:)` sets `allowsKeyWindow = true` and uses the nonactivating-panel behavior to receive Tab/Escape after direct interaction without activating ChatBird. `collapse()`/`hide()` resign key status and reset `allowsKeyWindow = false`, so the capsule never steals focus. `setConfirmationInputActive(true)` explicitly activates ChatBird only for text/question/feedback input, makes the panel key, and assigns the intended field as first responder. Passing `false` ends text-input activation while retaining the expanded workspace's nonactivating key policy.

`reconcileWindowLevel(entries:)` uses the controller panel's real `windowNumber` with `nativeActivityStackIntersectsPanel` and `nativeActivityStackOccludesPanel`. It selects only `panelDefaultWindowLevel` or `panelNativeActivityWindowLevel`, and calls `orderFrontRegardless()` only when the level changed or the intersecting native-activity stack currently occludes the panel. `hide()` always restores `panelDefaultWindowLevel`.

Use 220ms expansion and 180ms collapse with the same frame `maxY`. When `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` is true, replace frame morphing with a 100ms alpha transition. Lock `isAnimating` until completion.

- [ ] **Step 5: Implement outside click and Escape without cancellation**

Install one local monitor for `[.leftMouseDown, .keyDown]` and one global monitor for `[.leftMouseDown]` only while expanded:

```swift
if event.type == .keyDown, event.keyCode == 53 {
    collapse()
    return nil
}
if event.type == .leftMouseDown,
   panel.frame.contains(NSEvent.mouseLocation) == false {
    collapse()
}
```

Remove both monitors on collapse, hide, and deinit. These monitors only compare coordinates/key code; they never create or post input events.

- [ ] **Step 6: Run placement/state self-tests**

Run:

```bash
./macos/ChatBirdQuotaPanel/scripts/build.sh
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-dynamic-island
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-placement
```

Expected: both exit 0; new output includes `placement=notch-safe+negative-screen+small-screen` and `state-machine=pass`, while all pet placement assertions remain unchanged.

- [ ] **Step 7: Record the local checkpoint if Git mutation is authorized**

```bash
git add \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandPlacement.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandWindowController.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandSelfTest.swift
git commit \
  -m "让第二套窗口安全停在菜单栏下方" \
  -m "Constraint: 404pt 胶囊无法进入当前内屏约 185pt 刘海间隙" \
  -m "Rejected: 覆盖菜单栏或物理刘海 | 会遮挡系统交互" \
  -m "Confidence: high" \
  -m "Scope-risk: narrow" \
  -m "Directive: 展开和收起必须保持同一 top anchor" \
  -m "Tested: dynamic-island placement/state; existing placement" \
  -m "Not-tested: 尚未安装真实内容视图"
```

---

### Task 6: Build the Neutral Capsule and Shared Expanded Workspace Chrome

**Files:**
- Create: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandView.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandWindowController.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandSelfTest.swift`

**Interfaces:**
- Consumes: `ActivityDashboardSnapshot`, its `acknowledgedTerminalTaskKeys`, `DynamicIslandPresentationState`, and later task/confirmation/quota child controllers.
- Produces: `DynamicIslandCapsulePresentation`, `dynamicIslandCapsulePresentation(snapshot:now:)`, `DynamicIslandRootViewController`, `DynamicIslandCapsuleViewController`, and `DynamicIslandWorkspaceViewController`.

- [ ] **Step 1: Add failing capsule-priority and no-fake-progress tests**

Construct snapshots for queue, waiting, running, failed, completed, idle quota, and Codex-exited states. Assert priority in that order and assert every title/subtitle/accessibility value excludes `3/5` and `%` when representing task progress:

```swift
let model = dynamicIslandCapsulePresentation(
    snapshot: runningSnapshot,
    now: now
)
guard model.title == runningTask.title,
      model.statusText == "正在执行",
      model.progressStyle == .indeterminate,
      !model.accessibilityValue.contains("3/5"),
      !model.accessibilityValue.contains("%")
else { exit(1) }
```

Also assert a pending confirmation always wins over a running task and exposes the real queue count. For failed/completed fixtures, assert the terminal task is selected before its `terminalTaskAcknowledgementKey(for:)` value is acknowledged, and that the same occurrence is skipped after that key is inserted into `acknowledgedTerminalTaskKeys`.

- [ ] **Step 2: Run the Dynamic Island self-test to prove it is red**

Run:

```bash
./macos/ChatBirdQuotaPanel/scripts/build.sh
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-dynamic-island
```

Expected: compilation fails because capsule presentation types do not exist.

- [ ] **Step 3: Implement presentation policy and duration formatting**

Add:

```swift
enum DynamicIslandProgressStyle: Equatable {
    case indeterminate
    case waiting
    case completed
    case failed
    case idle
}

struct DynamicIslandCapsulePresentation: Equatable {
    let title: String
    let statusText: String
    let activityText: String?
    let elapsedText: String?
    let providerText: String?
    let badgeText: String?
    let progressStyle: DynamicIslandProgressStyle
    let preferredTab: DynamicIslandTab
    let selectedTaskKey: String?
    let accessibilityValue: String
}

func taskElapsedText(
    from startedAt: Date,
    to now: Date
) -> String {
    let totalSeconds = max(0, Int(now.timeIntervalSince(startedAt)))
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let seconds = totalSeconds % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%02d:%02d", minutes, seconds)
}

func dynamicIslandCapsulePresentation(
    snapshot: ActivityDashboardSnapshot,
    now: Date = Date()
) -> DynamicIslandCapsulePresentation {
    func accessibility(
        title: String,
        status: String,
        activity: String?,
        elapsed: String?,
        badge: String?
    ) -> String {
        [title, status, activity, elapsed, badge].compactMap { $0 }
            .joined(separator: "，")
    }

    func taskModel(
        _ item: TaskProgressItem,
        style: DynamicIslandProgressStyle
    ) -> DynamicIslandCapsulePresentation {
        let elapsed = taskElapsedText(from: item.startedAt, to: now)
        let provider = item.source == .codex ? "Codex" : "Claude Code"
        return DynamicIslandCapsulePresentation(
            title: item.title,
            statusText: item.statusText,
            activityText: item.activityText,
            elapsedText: elapsed,
            providerText: provider,
            badgeText: nil,
            progressStyle: style,
            preferredTab: .tasks,
            selectedTaskKey: item.identityKey,
            accessibilityValue: accessibility(
                title: item.title,
                status: item.statusText,
                activity: item.activityText,
                elapsed: elapsed,
                badge: nil
            )
        )
    }

    if snapshot.permissionQueue.count > 0 {
        let current = snapshot.permissionQueue.current
        let typeText: String
        switch current?.interactionKind {
        case .toolApproval: typeText = "工具授权"
        case .askUserQuestion: typeText = "问题待回答"
        case .exitPlanMode: typeText = "计划待审批"
        case nil: typeText = "请求待确认"
        }
        let title = current?.title ?? "Claude 等待确认"
        let elapsed = current.map {
            taskElapsedText(from: $0.arrivedAt, to: now)
        }
        let badge = "\(snapshot.permissionQueue.count)"
        return DynamicIslandCapsulePresentation(
            title: title,
            statusText: "等待确认",
            activityText: typeText,
            elapsedText: elapsed,
            providerText: "Claude Code",
            badgeText: badge,
            progressStyle: .waiting,
            preferredTab: .confirmation,
            selectedTaskKey: nil,
            accessibilityValue: accessibility(
                title: title,
                status: "等待确认",
                activity: typeText,
                elapsed: elapsed,
                badge: "队列 \(badge) 项"
            )
        )
    }

    if let item = snapshot.taskCollection.items.first(where: {
        $0.kind == .waitingForInput
    }) {
        return taskModel(item, style: .waiting)
    }
    if let item = snapshot.taskCollection.items.first(where: {
        $0.kind == .running
    }) {
        return taskModel(item, style: .indeterminate)
    }
    if let item = snapshot.taskCollection.items.first(where: {
        guard $0.kind == .failed,
              let key = terminalTaskAcknowledgementKey(for: $0)
        else { return false }
        return !snapshot.acknowledgedTerminalTaskKeys.contains(key)
    }) {
        return taskModel(item, style: .failed)
    }
    if let item = snapshot.taskCollection.items.first(where: {
        guard $0.kind == .completed,
              let key = terminalTaskAcknowledgementKey(for: $0)
        else { return false }
        return !snapshot.acknowledgedTerminalTaskKeys.contains(key)
    }) {
        return taskModel(item, style: .completed)
    }

    if snapshot.codexDesktopRunning
        || snapshot.availableProviders.contains(.claudeCode) {
        let provider = snapshot.selectedQuotaProvider
        let state = snapshot.quotaStates[provider]
        let remaining = state?.rows.first(where: {
            $0.name == provider.summaryRowName
        })?.remainingPercent
        let activity = remaining.map { "\($0)% 可用" }
        let title = "ChatBird 空闲"
        let status = state?.statusText ?? "等待新任务"
        return DynamicIslandCapsulePresentation(
            title: title,
            statusText: status,
            activityText: activity,
            elapsedText: nil,
            providerText: provider.displayName,
            badgeText: nil,
            progressStyle: .idle,
            preferredTab: .quota,
            selectedTaskKey: nil,
            accessibilityValue: accessibility(
                title: title,
                status: status,
                activity: activity,
                elapsed: nil,
                badge: nil
            )
        )
    }

    return DynamicIslandCapsulePresentation(
        title: "Codex 已退出",
        statusText: "等待 Codex 启动",
        activityText: nil,
        elapsedText: nil,
        providerText: nil,
        badgeText: nil,
        progressStyle: .idle,
        preferredTab: .tasks,
        selectedTaskKey: nil,
        accessibilityValue: "Codex 已退出，等待 Codex 启动"
    )
}
```

The selection order is permission queue, waiting input, running, unacknowledged failed, unacknowledged completed, quota/idle, then Codex exited. A terminal occurrence is unacknowledged exactly when the set does not contain its `terminalTaskAcknowledgementKey(for:)` value. The quota/idle branch applies only while Codex is running or Claude remains an available provider; otherwise the final branch renders `Codex 已退出`. Use state, elapsed time, and sanitized `activityText` only. Do not derive numerical progress from events or text.

- [ ] **Step 4: Implement the independent visual system**

Create a palette with neutral near-black surfaces, white/gray text, green success/running, amber waiting, and red failure. Do not reference `ClaudePanelPalette`, `QuotaPanelView` colors, blue glow, pointer geometry, pet assets, or pixel-art assets.

Use these base values:

```swift
enum DynamicIslandPalette {
    static let background = NSColor(
        calibratedWhite: 0.055,
        alpha: 0.98
    )
    static let raised = NSColor(
        calibratedWhite: 0.10,
        alpha: 0.96
    )
    static let hairline = NSColor.white.withAlphaComponent(0.12)
    static let primaryText = NSColor.white.withAlphaComponent(0.94)
    static let secondaryText = NSColor.white.withAlphaComponent(0.62)
    static let green = NSColor(
        calibratedRed: 0.40,
        green: 0.83,
        blue: 0.08,
        alpha: 1
    )
    static let amber = NSColor(
        calibratedRed: 1.00,
        green: 0.67,
        blue: 0.08,
        alpha: 1
    )
    static let red = NSColor(
        calibratedRed: 1.00,
        green: 0.31,
        blue: 0.29,
        alpha: 1
    )
}
```

When Reduce Transparency is enabled, use an opaque `background` and 1pt hairline. Otherwise use `NSVisualEffectView` with `.hudWindow` material behind the opaque-enough neutral tint.

- [ ] **Step 5: Build capsule and workspace controllers**

`DynamicIslandCapsuleViewController` must lay out one 404×58pt row:

- A 10pt state-colored dot, 12pt concise status, and 14pt semibold single-line title.
- A 12pt monospaced elapsed time and trailing `chevron.right`.
- No rendered activity/source row, badge, or independent “打开” button; those details stay in the model, accessibility value, and expanded workspace.
- One frontmost full-capsule accessibility button/hit target that calls `onExpand(preferredTab, selectedTaskKey)`.

`DynamicIslandWorkspaceViewController` must create a fixed 56pt top bar with:

- `ChatBird 活动`.
- Real task/confirmation/quota tab controls with counts.
- `全部 / Codex / Claude` source filter.
- A refresh button that disables while task or quota refresh is active.
- A collapse button.
- A child container below the top bar.

Expose:

```swift
final class DynamicIslandRootViewController: NSViewController {
    var onExpand: ((DynamicIslandTab, String?) -> Void)?
    var onCollapse: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onTabChange: ((DynamicIslandTab) -> Void)?
    var onSourceFilterChange: ((TaskSourceFilter) -> Void)?

    func apply(
        snapshot: ActivityDashboardSnapshot,
        state: DynamicIslandPresentationState
    )
}
```

Every control gets a Chinese accessibility label and value. Status is always represented by both text and symbol.

- [ ] **Step 6: Install the root controller into the independent panel**

`DynamicIslandWindowController` owns one root controller and calls `apply(snapshot:state:)` from its store observation. Expansion from the capsule uses the model's `preferredTab` and optional task identity. Tab changes resize between 560/600/470pt while retaining the same top edge.

- [ ] **Step 7: Run model, build, and accessibility-label assertions**

Run:

```bash
./macos/ChatBirdQuotaPanel/scripts/build.sh
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-dynamic-island
```

Expected: exit 0 with `capsule-priority=7/7`, `fake-progress=absent`, `brand=ChatBird`, `controls=accessible`, and `palette=independent`.

- [ ] **Step 8: Record the local checkpoint if Git mutation is authorized**

```bash
git add \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandView.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandWindowController.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandSelfTest.swift
git commit \
  -m "让顶部胶囊只表达真实且可操作的状态" \
  -m "Constraint: V1 没有结构化步骤总数" \
  -m "Rejected: 显示 3/5 或猜测百分比 | 会制造虚假精度" \
  -m "Confidence: high" \
  -m "Scope-risk: moderate" \
  -m "Directive: 胶囊视觉不得复用宠物面板语言" \
  -m "Tested: capsule priority; no fake progress; accessibility labels" \
  -m "Not-tested: 三个展开内容页尚未完成"
```

---

### Task 7: Implement the Complete Task Workspace

**Files:**
- Create: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandTaskView.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandView.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandWindowController.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandSelfTest.swift`

**Interfaces:**
- Consumes: `TaskProgressCollectionSnapshot`, global source filter, safe events, cwd/thread/session identities, and capsule-selected task key.
- Produces: `DynamicIslandTaskViewController`, stable selection helpers, neutral hover preview, `onOpenTask`, and `onCopyWorkingDirectory`.

- [ ] **Step 1: Add failing filtering and selection-recovery tests**

Add pure helpers and tests for:

```swift
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
```

Assert:

- Source and state filters compose.
- Existing selection survives a refresh.
- A vanished selection chooses `preferredKey` when visible, otherwise the first priority-sorted task.
- Empty filters show an explicit empty state.
- Short IDs use four uppercase trailing characters and nil stays nil.
- Hover uses only `events.suffix(3)` and never changes selection.

- [ ] **Step 2: Run the Dynamic Island self-test to prove it is red**

Run:

```bash
./macos/ChatBirdQuotaPanel/scripts/build.sh
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-dynamic-island
```

Expected: compilation fails because task workspace helpers/controller do not exist.

- [ ] **Step 3: Build the left task queue with real AppKit controls**

Implement:

```swift
final class DynamicIslandTaskViewController:
    NSViewController,
    NSTableViewDataSource,
    NSTableViewDelegate
{
    var onOpenTask: ((TaskProgressItem) -> Void)?
    var onCopyWorkingDirectory: ((String) -> Void)?

    func apply(
        collection: TaskProgressCollectionSnapshot,
        sourceFilter: TaskSourceFilter,
        preferredTaskKey: String?
    )
}
```

The left pane is 316pt wide and contains:

- `全部`, running, waiting, completed, and failed filter buttons with real counts; `全部` is the deterministic reset for the state filter.
- An `NSTableView` in an `NSScrollView` containing the complete filtered collection.
- Provider icon/text, title, state text, elapsed/completed time, and a state symbol per row.
- Stable `identityKey` selection.

The list must not reuse `QuotaPanelView.displayedTaskItems` or its five-row projection.

- [ ] **Step 4: Build the right task details**

The detail pane contains:

- Provider and `ChatBird` project context.
- Title, text+symbol state, and elapsed time.
- Normalized absolute working directory or `工作目录不可用`.
- Current sanitized activity.
- A `最近事件` stack with no more than three timestamped safe events.
- `打开 Codex` for Codex or `回到终端` for Claude, enabled only when `item.canOpen`.
- `复制路径` enabled only for a normalized absolute directory.
- `Thread XXXX` or `Session XXXX` as secondary text.

Use a scroll view for detail content below 560pt fitted height. Do not shrink fonts.

- [ ] **Step 5: Implement copy/open actions without moving data ownership into the view**

The view emits `TaskProgressItem` or path only. AppDelegate remains responsible for existing deep-link/terminal logic. Clipboard writing occurs in one action closure:

```swift
private func copyWorkingDirectory(_ path: String) {
    guard let normalizedPath = normalizedAbsolutePath(path) else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects([normalizedPath as NSString])
}
```

After a successful write, the button reads `已复制` for 1.2 seconds and then returns to `复制路径`.

- [ ] **Step 6: Add the independent neutral hover preview**

Create `DynamicIslandTaskHoverController` in the same file. It uses a borderless nonactivating 360×96pt neutral panel, displays the task title plus at most three safe event lines, positions beside the expanded panel while clamping to `visibleFrame`, and hides on mouse exit, selection change, collapse, or mode switch. It never uses `TaskActivityPreviewController` or pet-panel colors.

- [ ] **Step 7: Run task workspace and legacy task regressions**

Run:

```bash
./macos/ChatBirdQuotaPanel/scripts/build.sh
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-dynamic-island
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-task-progress
```

Expected: both exit 0; new output includes `filters=source+state`, `selection=stable`, `detail-events=3-safe`, `copy-path=absolute-only`, and `hover=no-selection-change`.

- [ ] **Step 8: Record the local checkpoint if Git mutation is authorized**

```bash
git add \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandTaskView.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandView.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandWindowController.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandSelfTest.swift
git commit \
  -m "让展开面板展示完整任务上下文" \
  -m "Constraint: 旧面板仍只消费紧凑投影" \
  -m "Rejected: 从旧视图读取当前五行 | 会永久丢失任务细节" \
  -m "Confidence: high" \
  -m "Scope-risk: moderate" \
  -m "Directive: 任务详情只能显示安全事件和规范化路径" \
  -m "Tested: dynamic task workspace; existing task progress" \
  -m "Not-tested: 确认与额度工作台尚未完成"
```

---

### Task 8: Implement the Full Inline Claude Confirmation Workspace

**Files:**
- Create: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandConfirmationView.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandView.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandWindowController.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ClaudeHookSupport.swift:736-978`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandSelfTest.swift`

**Interfaces:**
- Consumes: `ClaudePermissionPresentation`, `ClaudePermissionQueueSnapshot`, existing protocol limits, permission suggestions, and `ClaudePermissionUserDecision`.
- Produces: `DynamicIslandConfirmationPresenter`, `DynamicIslandConfirmationViewController`, independent question input views, and all three decision flows.

- [ ] **Step 1: Add failing question-answer and presenter tests**

Define a view-independent draft:

```swift
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
```

Test:

- Custom text wins over selected options.
- Single-select returns one label.
- Multi-select returns selected labels joined with `", "` in option order.
- No selection/custom value returns nil.
- Submission finds the first unanswered question and does not emit a decision.
- A presenter receives a tool prompt, expands confirmation, and emits exactly one `allowOnce`.
- Presenter `dismiss()` clears UI without emitting a decision.
- Escape collapses the window but leaves the coordinator queue count unchanged.

- [ ] **Step 2: Run Dynamic Island and Hook self-tests to prove they are red**

Run:

```bash
./macos/ChatBirdQuotaPanel/scripts/build.sh
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-dynamic-island
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-claude-hook
```

Expected: compilation fails because the new presenter and question draft are absent.

- [ ] **Step 3: Build the FIFO queue pane**

Implement:

```swift
final class DynamicIslandConfirmationViewController:
    NSViewController,
    NSTableViewDataSource,
    NSTableViewDelegate
{
    var onDecision: ((ClaudePermissionUserDecision) -> Void)?
    var onReturnToTerminal: (() -> Void)?

    func apply(_ presentation: ClaudePermissionPresentation)
    func clear()
}
```

The 248pt left pane uses `NSTableView` to show current followed by pending FIFO items. Each row includes interaction type, safe title, arrival time, and current/pending state. Pending rows are informational and cannot be selected to reorder the queue. The current row stays selected.

- [ ] **Step 4: Build the independent tool-approval form**

The right pane for `.toolApproval` shows:

- Tool category and `prompt.message`.
- A bounded one-line summary from `command`, `file_path`, `path`, `url`, `query`, or `description`, capped at 90 characters.
- Permission suggestion titles and one `长期允许` action per suggestion.
- `回到终端`, `拒绝`, and `允许一次`.

The form emits:

```swift
.nativeFallback
.deny("用户在 ChatBird 中拒绝了这次操作")
.allowOnce
.allowWithSuggestion(prompt.suggestions[index].rawValue)
```

The raw input is visible only in this explicit approval context and only through the bounded summary keys already used by the legacy prompt. It must never be copied into recent task events.

- [ ] **Step 5: Build paged questions with full validation**

Create independent neutral `DynamicIslandQuestionInputView` instances. Support 1–5 questions, 0–5 options, single-select, multi-select, and free text. Keep drafts while paging.

Controls:

- `上一题` and `下一题` with `问题 N / M`.
- An internal scroll view for long option/detail content.
- `回到终端` and `提交回答`.
- Validation text `请先回答第 N 题，或选择“回到终端”。` and automatic navigation to the missing page.

Submission builds `[String: Any]` keyed by `ClaudeQuestion.answerKey` and emits `.submitAnswers(answers)`.

- [ ] **Step 6: Build scrollable plan review**

For `.exitPlanMode`:

- Show `prompt.planText` in a selectable, vertically scrollable region.
- Show a multi-line feedback field.
- Provide `回到终端`, `让 Claude 修改`, and `批准并继续`.
- Empty feedback displays `请先填写希望 Claude 修改的内容。`.
- Feedback emits `.planFeedback(feedback)` and approval emits `.allowOnce`.

Only `提交回答`, `允许一次`, or `批准并继续` may use Return as the safe primary key. `拒绝` and `回到终端` never get a default key equivalent.

- [ ] **Step 7: Implement the Dynamic Island presenter**

Add:

```swift
final class DynamicIslandConfirmationPresenter: ClaudePermissionPresenting {
    init(
        show: @escaping (ClaudePermissionPresentation) -> Void,
        dismissView: @escaping () -> Void,
        repositionWindow: @escaping () -> Void
    )

    func present(_ presentation: ClaudePermissionPresentation)
    func dismiss()
    func reposition()
}
```

`present` stores no request ownership; it sends the presentation to the view, records the prior non-confirmation tab, expands `.confirmation`, and enables key-window status. When the coordinator advances directly to another request, replace content without collapsing. When the queue becomes empty, return to the prior tab and disable key-window status. Collapsing manually leaves the form draft and coordinator request intact; clicking the yellow capsule badge reopens it.

Disable every decision control immediately after the first emitted decision. The next request re-enables controls with a fresh view state.

- [ ] **Step 8: Run all Claude decision regressions**

Run:

```bash
./macos/ChatBirdQuotaPanel/scripts/build.sh
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-dynamic-island
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-claude-hook
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-lifecycle
```

Expected: all exit 0 with coverage for tool decisions, suggestions, 1–5 question paging, missing-answer navigation, plan approval/feedback, exactly-once emission, collapse-without-cancel, terminal transition, expiry, and Codex exit.

- [ ] **Step 9: Record the local checkpoint if Git mutation is authorized**

```bash
git add \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandConfirmationView.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandView.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandWindowController.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ClaudeHookSupport.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandSelfTest.swift
git commit \
  -m "让 Claude 确认在展开工作台内完整完成" \
  -m "Constraint: 三类 Hook 决策语义与限制不能变化" \
  -m "Rejected: 复用蓝色旧确认视图 | 违反第二套视觉边界" \
  -m "Confidence: high" \
  -m "Scope-risk: broad" \
  -m "Directive: 收起窗口不能完成或取消请求" \
  -m "Tested: dynamic-island; Claude Hook; lifecycle" \
  -m "Not-tested: 额度工作台与最终模式切换尚未完成"
```

---

### Task 9: Implement the Complete Quota Workspace and Combined Refresh

**Files:**
- Create: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandQuotaView.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandView.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/AppDelegate.swift:635-783`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/QuotaSelfTests.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandSelfTest.swift`

**Interfaces:**
- Consumes: `QuotaProviderState` for every available provider, `CodexResetCreditsSnapshot`, and existing quota formatting.
- Produces: `DynamicIslandQuotaViewController`, provider selection, complete state presentation, and `refreshDashboard()` that refreshes tasks plus all available provider quotas without overlap.

- [ ] **Step 1: Add failing quota presentation tests**

Define:

```swift
enum DynamicIslandQuotaPresentationPhase: Equatable {
    case firstLoad
    case refreshing
    case current
    case stale
    case firstFailure
    case unavailable
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
```

Assert:

- Missing state + available provider is `firstLoad`.
- Cached rows + refreshing is `refreshing` while rows stay visible.
- Cached rows + error/stale is `stale`.
- Empty rows + error is `firstFailure`.
- Empty rows + non-nil `updatedAt` + no error is `current` and renders `没有可确认的额度数据`.
- Missing provider is `unavailable`.
- Codex reset credits remain visible in stale state.
- Codex rows include weekly quota/reset time; Claude rows include 5-hour, weekly, and Fable when supplied.

- [ ] **Step 2: Run quota self-tests to prove they are red**

Run:

```bash
./macos/ChatBirdQuotaPanel/scripts/build.sh
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-weekly-quota
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-claude-quota
```

Expected: compilation fails because Dynamic Island quota presentation is absent.

- [ ] **Step 3: Build provider list and quota details**

Implement:

```swift
final class DynamicIslandQuotaViewController: NSViewController {
    var onSelectProvider: ((QuotaProvider) -> Void)?
    var onRefresh: (() -> Void)?

    func apply(_ snapshot: ActivityDashboardSnapshot)
}
```

The 228pt left pane shows available providers, summary percent, and current/stale/unavailable status. The right pane shows:

- Provider title and last-success time.
- All current rows with remaining percent and reset description/time.
- Codex reset-credit count and up to four expiry values via `codexResetCreditsPresentation`.
- A visible stale banner while preserving cached values.
- Explicit not-installed, not-logged-in, first-failure, and empty-data copy.

Use text and symbols in addition to color. Keep values selectable but not editable.

- [ ] **Step 4: Implement combined manual refresh with per-provider single flight**

Add:

```swift
private func refreshDashboard() {
    refreshTaskProgress()
    for provider in dashboardStore.snapshot.availableProviders {
        refreshQuota(provider: provider)
    }
}
```

The top refresh button calls this once. Existing `TaskProgressRefreshGate` rejects overlapping task reads; `refreshingQuotaProviders` rejects overlapping provider reads. The button remains disabled while `isTaskRefreshing` is true or any available provider state has `isRefreshing == true`.

Automatic 60-second refresh may continue refreshing only the selected quota provider. A manual refresh covers all available providers.

- [ ] **Step 5: Run quota, client, and Dynamic Island regressions**

Run:

```bash
./macos/ChatBirdQuotaPanel/scripts/build.sh
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-dynamic-island
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-weekly-quota
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-claude-quota
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-client-contract
```

Expected: all exit 0 with `quota-phases=6/6`, `stale-data=preserved`, `manual-refresh=tasks+all-providers`, and existing protocol contract assertions.

- [ ] **Step 6: Record the local checkpoint if Git mutation is authorized**

```bash
git add \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandQuotaView.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandView.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/AppDelegate.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/QuotaSelfTests.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandSelfTest.swift
git commit \
  -m "让额度工作台区分缓存失败与真实空数据" \
  -m "Constraint: 手动刷新需要同时覆盖任务和所有可用 provider" \
  -m "Rejected: 失败时隐藏上次数据 | 会让用户误判额度" \
  -m "Confidence: high" \
  -m "Scope-risk: moderate" \
  -m "Directive: 每个 provider 保持独立 single-flight 状态" \
  -m "Tested: dynamic-island; weekly quota; Claude quota; client contract" \
  -m "Not-tested: 模式菜单与真实窗口切换尚未接入"
```

---

### Task 10: Integrate Mode Switching, Status Menu, Actions, and Runtime Lifecycle

**Files:**
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/AppDelegate.swift:16-817`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/PanelLifecycle.swift:15-58`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/LifecycleSelfTest.swift:16-293`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandWindowController.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandSelfTest.swift`

**Interfaces:**
- Consumes: all completed store, coordinator, legacy presenter, Dynamic Island controller, and action closures.
- Produces: persisted mode switching, always-available status menu, one visible presentation, correct presenter binding, display movement, and full runtime lifecycle.

- [ ] **Step 1: Add failing mode-transition and menu-command tests**

Add pure:

```swift
enum PresentationCommand: Equatable {
    case toggleVisibility
    case selectMode(PresentationMode)
    case moveToCurrentDisplay
    case quit
}

struct PresentationRuntimeDecision: Equatable {
    let showPetPanel: Bool
    let showDynamicIsland: Bool
    let bindLegacyPermissionPresenter: Bool
    let bindDynamicPermissionPresenter: Bool
}

func presentationRuntimeDecision(
    mode: PresentationMode,
    hiddenByUser: Bool
) -> PresentationRuntimeDecision {
    PresentationRuntimeDecision(
        showPetPanel: !hiddenByUser && mode == .petPanel,
        showDynamicIsland: !hiddenByUser && mode == .dynamicIsland,
        bindLegacyPermissionPresenter: mode == .petPanel,
        bindDynamicPermissionPresenter: mode == .dynamicIsland
    )
}
```

Assert:

- Pet mode shows only pet and binds only legacy.
- Dynamic mode shows only Dynamic Island and binds only dynamic.
- Hidden state shows neither but keeps the presenter matching the selected mode, so a new confirmation can reveal the correct surface.
- Switching modes preserves `ActivityDashboardSnapshot` values and coordinator queue count.
- Selecting a completed/failed task inserts its `terminalTaskAcknowledgementKey(for:)` value into `acknowledgedTerminalTaskKeys`; selecting an active task does not.
- Codex exit hides pet mode but leaves Dynamic Island in capsule/system state.
- `moveToCurrentDisplay` is enabled only in Dynamic Island mode.

- [ ] **Step 2: Run lifecycle tests to prove integration is red**

Run:

```bash
./macos/ChatBirdQuotaPanel/scripts/build.sh
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-lifecycle
"macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" --self-test-dynamic-island
```

Expected: compilation or assertions fail because runtime integration is absent.

- [ ] **Step 3: Construct both presenters and the Dynamic Island controller**

Keep the single `dashboardStore` and observer token created in Tasks 2–3; do not instantiate a second store. Add these retained runtime properties:

```swift
private let presentationModePreference = PresentationModePreference()
private var presentationMode: PresentationMode = .petPanel
private var dynamicIslandController: DynamicIslandWindowController!
private var dynamicIslandConfirmationPresenter:
    DynamicIslandConfirmationPresenter!
```

During launch:

1. Read `presentationModePreference.mode`.
2. Create the existing pet panel.
3. Create the Dynamic Island controller with store and action closures.
4. Start Codex/Hook monitoring.
5. Build the status menu.
6. Bind the permission presenter for the selected mode.
7. Apply initial visibility.
8. Start existing refresh timers.

- [ ] **Step 4: Build the always-available status menu**

Replace the current hidden-only status button behavior with an `NSMenu` containing:

```text
显示 / 隐藏
────────
宠物面板      ✓ when selected
灵动岛        ✓ when selected
移到当前显示器
────────
退出 ChatBird
```

Each item maps to `PresentationCommand` and has a real target/action. Keep the status item visible in both modes so users can always switch back. Update menu item titles/checkmarks in `menuNeedsUpdate(_:)`. Do not remove pet double-click behavior.

- [ ] **Step 5: Implement atomic mode switching**

Add:

```swift
private func selectPresentationMode(_ mode: PresentationMode) {
    guard presentationMode != mode else { return }
    hideCurrentPresentation()
    taskActivityPreviewController.hide()
    presentationMode = mode
    presentationModePreference.mode = mode
    bindClaudePermissionPresenter(for: mode)
    showCurrentPresentation()
    updateStatusMenu()
}
```

For pet mode:

- Hide Dynamic Island and its hover preview.
- Bind `ClaudePermissionPanelPresenter`.
- Resume `followPet(forceLocationPoll: true)`.

For Dynamic Island mode:

- Order out pet panel and disable pet task animations.
- Bind `DynamicIslandConfirmationPresenter`.
- Show capsule on its selected display.
- `followPet` returns before locating a pet, eliminating the 30ms placement work in this mode. Its cheap timestamp branch still calls `dynamicIslandController.reconcileWindowLevel(entries:)` at no more than the existing `overlayStateRefreshInterval` (250ms), so native Codex activity windows cannot silently cover the new panel.

The store and coordinator are never recreated during switching.

- [ ] **Step 6: Route every action through AppDelegate/store**

Wire:

- Capsule/task row Codex action -> existing `codexThreadURL` and `NSWorkspace.shared.open`.
- Claude action -> coordinator handoff first, then existing `openClaudeTerminal`.
- Copy path -> validated pasteboard function.
- Provider choice -> `dashboardStore.snapshot.selectedQuotaProvider` plus preference.
- Refresh -> `refreshDashboard()`.
- Collapse/hide -> controller state only.
- Move display -> `dynamicIslandController.moveToScreenContainingMouse()`.
- Task selection -> mark terminal task acknowledged for the current process so the capsule does not repeat an already-viewed completion/failure.

Use the Task 1 store field as the only owner:

```swift
private func acknowledgeTerminalTask(_ item: TaskProgressItem) {
    guard let key = terminalTaskAcknowledgementKey(for: item) else { return }
    dashboardStore.update {
        $0.acknowledgedTerminalTaskKeys.insert(key)
    }
}
```

Call this after the detail pane opens for either a user-selected row or the capsule's `selectedTaskKey`. A passive refresh that merely preserves an existing selection must not acknowledge anything. Do not persist the set or any task content, and do not mirror it in `DynamicIslandWindowController`.

- [ ] **Step 7: Integrate screen and Codex lifecycle changes**

Observe `NSApplication.didChangeScreenParametersNotification` and call `dynamicIslandController.screenParametersDidChange()`. Remove the observer at termination.

`updateCodexDesktopRunningState(_:)` must:

```swift
dashboardStore.update { $0.codexDesktopRunning = isRunning }
if !isRunning {
    claudePermissionCoordinator.cancelAll()
}
if presentationMode == .petPanel {
    followPet(forceLocationPoll: true)
} else {
    dynamicIslandController.showCapsule()
}
```

App termination removes every observer/event monitor, cancels coordinator requests, stops the Hook server, hides both windows, stops animation timers, removes the status item, and writes final health state.

- [ ] **Step 8: Run the complete built-in suite**

Run:

```bash
./macos/ChatBirdQuotaPanel/scripts/build.sh
BIN="macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel"
"$BIN" --self-test-placement
"$BIN" --self-test-lifecycle
"$BIN" --self-test-native-notification-state
"$BIN" --self-test-task-progress
"$BIN" --self-test-weekly-quota
"$BIN" --self-test-claude-quota
"$BIN" --self-test-claude-hook
"$BIN" --self-test-client-contract
"$BIN" --self-test-chatbird-edition
"$BIN" --self-test-dynamic-island
```

Expected: all ten commands exit 0. The original nine summaries retain their prior assertions; Dynamic Island reports mode, placement, state, capsule, task, confirmation, quota, and accessibility coverage.

- [ ] **Step 9: Record the local checkpoint if Git mutation is authorized**

```bash
git add \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/AppDelegate.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/PanelLifecycle.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/LifecycleSelfTest.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandWindowController.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandSelfTest.swift
git commit \
  -m "让用户可在两套展示间安全切换" \
  -m "Constraint: 同一时刻只能有一套主面板和一个确认 presenter" \
  -m "Rejected: 切换模式时重建数据读取器 | 会丢状态并增加进程开销" \
  -m "Confidence: high" \
  -m "Scope-risk: broad" \
  -m "Directive: 模式切换只改变 presenter 和窗口可见性" \
  -m "Tested: ten built-in self-tests" \
  -m "Not-tested: 真实多屏和全屏交互仍需手动验证"
```

---

### Task 11: Add Deterministic Previews, Visual QA, Accessibility, and Final Verification

**Files:**
- Create: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandPreviewRendering.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/main.swift:168-187`
- Modify: `macos/ChatBirdQuotaPanel/README.md`
- Verify without modifying: `output/imagegen/petbar-dynamic-island-interactions-01-task-workspace.png`
- Verify without modifying: `output/imagegen/petbar-dynamic-island-interactions-02-confirmation-workflows.png`
- Verify without modifying: `output/imagegen/petbar-dynamic-island-interactions-03-quota-system-states.png`
- Verify without modifying: `output/audit/dynamic-island-review/01-current-panel.png` through `04-current-confirm-plan.png`

**Interfaces:**
- Consumes: completed view controllers and deterministic dashboard/permission fixtures.
- Produces: `--render-dynamic-island-preview <state> <path>`, an inspected visual matrix, documentation, and release-quality evidence without publishing.

- [ ] **Step 1: Add the preview command and supported-state parser**

Register:

```swift
if let flag = CommandLine.arguments.firstIndex(
    of: "--render-dynamic-island-preview"
), CommandLine.arguments.indices.contains(flag + 2) {
    let state = CommandLine.arguments[flag + 1]
    let outputURL = URL(
        fileURLWithPath: CommandLine.arguments[flag + 2]
    )
    do {
        try renderDynamicIslandPreview(state: state, to: outputURL)
        print(outputURL.path)
        exit(0)
    } catch {
        fputs(
            "写入灵动岛预览失败：\(error.localizedDescription)\n",
            stderr
        )
        exit(1)
    }
}
```

Accept exactly:

```text
capsule-confirmation
capsule-running
capsule-waiting
capsule-completed
capsule-failed
capsule-idle
capsule-codex-exited
tasks
confirm-tool
confirm-question
confirm-plan
quota-codex
quota-claude
quota-loading
quota-stale
quota-first-failure
quota-unavailable
```

Unknown values return a nonzero error. Rendering uses a 2× `NSBitmapImageRep`, deterministic `Date` values, and the same view controllers used at runtime.

- [ ] **Step 2: Build and render the full matrix**

Run:

```bash
./macos/ChatBirdQuotaPanel/scripts/build.sh
BIN="macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel"
OUT="output/audit/dynamic-island-implementation/previews"
mkdir -p "$OUT"
for STATE in \
  capsule-confirmation capsule-running capsule-waiting capsule-completed \
  capsule-failed capsule-idle capsule-codex-exited \
  tasks confirm-tool confirm-question confirm-plan \
  quota-codex quota-claude quota-loading quota-stale \
  quota-first-failure quota-unavailable
do
  "$BIN" --render-dynamic-island-preview "$STATE" "$OUT/$STATE.png"
done
```

Expected: 17 valid PNG files at their exact design dimensions and 2× pixel density.

- [ ] **Step 3: Perform source-and-render visual comparison**

For each group, inspect the design target and implementation render together in the same comparison:

- Task/capsule renders against `01-task-workspace.png`.
- Three confirmation renders against `02-confirmation-workflows.png`.
- Quota/loading/stale/first-failure/unavailable renders against `03-quota-system-states.png`.
- Current pet/legacy confirmation renders against their four baseline captures.

Record a pass/fail verdict for:

- Correct 404×58 and 820×560/600/470 proportions.
- Fixed top anchor and downward expansion.
- No cropped text, controls, scroll content, or badges.
- Consistent 12pt minimum detail and 13pt minimum body text.
- Neutral black/gray/green/amber/red system with no blue pet glow or pointer.
- Real `ChatBird` copy and no `PetBar`/`3/5`.
- Complete buttons and form details in all three confirmation states.
- Stale quota values remain visible with a clear stale label.
- First-failure and unavailable quota states contain explicit recovery copy and no misleading cached values.
- Old pet panel and old confirmation views have no visual drift.

Fix every visible mismatch, rerender the affected state, and compare again before continuing.

- [ ] **Step 4: Verify keyboard and accessibility behavior**

Using the built app:

- Tab through capsule action, top tabs, filters, task list, detail actions, confirmation form, and quota controls in visual order.
- Confirm VoiceOver reads main capsule state, tab counts, provider, task state, quota values, queue position, and button purpose.
- Confirm Return triggers only the safe primary confirmation action.
- Confirm Escape collapses without completing a request.
- Confirm Reduce Motion removes morphing and Reduce Transparency produces an opaque readable surface.
- Confirm every state uses text/symbol plus color.

Document any manual-only result separately from built-in self-test evidence.

- [ ] **Step 5: Verify real window behavior on macOS**

Run:

```bash
./script/build_and_run.sh --verify
```

Manually verify:

- Internal notched display: capsule below menu bar, centered, no menu-item overlap.
- External non-notched display.
- A display with negative coordinates.
- Dock on left, bottom, and right.
- Menu bar auto-hide.
- Display disconnect moves to main; reconnect does not jump back.
- Full-screen Space visibility and `statusBar` layering.
- Ordinary capsule does not steal focus.
- Confirmation text fields become first responder.
- Outside click and Escape collapse.
- Pending confirmation remains represented by the yellow badge after collapse.
- Mode switching retains task selection, quota cache, and the current confirmation.
- Codex exit cancels confirmation safely and leaves Dynamic Island system state visible.

- [ ] **Step 6: Run repository, privacy, and release verification**

Run:

```bash
./macos/ChatBirdQuotaPanel/scripts/build.sh
BIN="macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel"
"$BIN" --self-test-placement
"$BIN" --self-test-lifecycle
"$BIN" --self-test-native-notification-state
"$BIN" --self-test-task-progress
"$BIN" --self-test-weekly-quota
"$BIN" --self-test-claude-quota
"$BIN" --self-test-claude-hook
"$BIN" --self-test-client-contract
"$BIN" --self-test-chatbird-edition
"$BIN" --self-test-dynamic-island
./scripts/tests/test-layout-validator.py
./scripts/tests/test-build-macos-release-verify-only.sh
./scripts/privacy-audit.sh
./scripts/build-macos-release.sh --verify-only
git diff --check
git status --short
```

Expected:

- All ten self-tests exit 0.
- Layout validator and release-script regression exit 0.
- Privacy audit reports no forbidden data/assets.
- Verify-only accepts macOS 12.3+, arm64, signature, current sources, and staging checks.
- `git diff --check` is empty.
- `git status --short` contains only explicitly planned source/docs plus preserved pre-existing `output/` artifacts.

Do not run the normal release packager, modify `dist/`, install a LaunchAgent, commit, or push unless the user separately authorizes that action.

- [ ] **Step 7: Update developer documentation**

Document in `macos/ChatBirdQuotaPanel/README.md`:

- `宠物面板` and `灵动岛` mode selection.
- Default mode and `presentation-mode` persistence.
- Status-menu show/hide and move-to-current-display behavior.
- `--self-test-dynamic-island`.
- `--render-dynamic-island-preview <state> <path>` with the exact supported state list.
- The full local verification command sequence.
- The privacy boundary for recent events and the absence of numerical step progress.

- [ ] **Step 8: Record the final local checkpoint if Git mutation is authorized**

```bash
git add \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ActivityDashboardModels.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ActivityDashboardStore.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ClaudePermissionCoordinator.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandPlacement.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandWindowController.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandView.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandTaskView.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandConfirmationView.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandQuotaView.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandPreviewRendering.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandSelfTest.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/TaskProgressModels.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/CodexTaskProgress.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ClaudeTaskProgress.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/QuotaPanelView.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ClaudeHookSupport.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ClaudePermissionPanel.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/AppDelegate.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/PanelLifecycle.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/QuotaSelfTests.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/TaskProgressSelfTest.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/LifecycleSelfTest.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/main.swift \
  macos/ChatBirdQuotaPanel/README.md
git commit \
  -m "让 ChatBird 提供完整且独立的顶部工作台" \
  -m "Constraint: macOS 12.3 arm64 AppKit 且不改变现有宠物面板" \
  -m "Rejected: SwiftUI 迁移或 ActivityKit | 与当前平台和构建链不匹配" \
  -m "Confidence: high" \
  -m "Scope-risk: broad" \
  -m "Reversibility: clean" \
  -m "Directive: 保持两套 presenter 共享 store 和单一确认 coordinator" \
  -m "Tested: ten self-tests; visual matrix; runtime multi-screen; privacy; release verify-only" \
  -m "Not-tested: 若手动多屏或 VoiceOver 项未完成，必须在此列出具体缺口"
```

Do not push this commit until the user explicitly requests publication and remote verification.

---

## Plan Self-Review Checklist

Self-review completed on 2026-08-10. This checks plan coverage and interface consistency; it is not evidence that the product implementation or runtime acceptance tests have run.

| Technical review coverage | Implementation tasks |
|---|---|
| §3 product boundaries and two modes | Tasks 1, 4, 10 |
| §4 size, notch/menu-bar placement, panel behavior, animation | Tasks 5, 6, 11 |
| §5 state machine and collapse/confirmation lifecycle | Tasks 4, 5, 8, 10 |
| §6 capsule priority and truthful progress | Tasks 1, 6, 10 |
| §7 task, confirmation, and quota workspaces | Tasks 6–9 |
| §8 data/action mapping | Tasks 1–4, 7, 9, 10 |
| §9 code ownership boundaries | Tasks 1–5, 8, 10 |
| §10 V1 delivery scope | Tasks 5–11 |
| §11 acceptance and verification | Tasks 1–11, with final evidence gates in Task 11 |
| §12 legacy baseline preservation | Tasks 4, 7, 10, 11 |
| §13 confirmed brand/progress Gates | Global Constraints, Tasks 6 and 11 |
| §14 staged implementation order | Tasks 1–11 in document order |

- [x] Every requirement in `docs/superpowers/specs/2026-08-10-petbar-dynamic-island-technical-review.md` maps to at least one Task 1–11 step.
- [x] Every new type used by a later task is introduced in an earlier task with the same spelling and signature.
- [x] `ActivityDashboardStore` is the only shared presentation state source.
- [x] `ClaudePermissionCoordinator` is the only request queue owner and binds one presenter.
- [x] Existing pet panel drawing/placement and blue legacy confirmation views remain separate and regression-rendered.
- [x] Full task collection and compact pet projection are both tested by explicit implementation-time steps.
- [x] Codex cwd and no-more-than-three safe events are tested against hidden reasoning/tool payload fixtures.
- [x] Quota failure retains rows and reset credits through a pure reducer and regression step.
- [x] No numerical task progress appears; real quota percentages remain allowed.
- [x] No new dependency, SwiftUI, ActivityKit, network service, telemetry, history, or cloud sync appears.
- [x] All ten self-tests, 17 visual states, manual window states, accessibility checks, privacy audit, and verify-only release gate have explicit verification steps.
- [x] Git mutation and publication remain separately authorized actions.
