# ThreadHelm Product Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the complete current ChatBird macOS product identity with ThreadHelm, preserve supported local state and the stopped-Claude-transcript fix, then build, verify, and reinstall the renamed app.

**Architecture:** Keep the current single AppKit executable and dynamic-island behavior. Introduce one canonical ThreadHelm identity boundary in Swift, treat old ChatBird identifiers only as migration inputs, upgrade the product-owned Claude hook in place, and make build/install/release validation enforce the new identity end to end.

**Tech Stack:** Swift 5/AppKit, zsh packaging and LaunchAgent scripts, Python repository validation, GitHub Actions, macOS `swiftc`, `codesign`, `launchctl`, `plutil`, and shell/Python regression tests.

## Global Constraints

- Canonical name: `ThreadHelm`; app: `ThreadHelm.app`; executable: `ThreadHelm`.
- Bundle ID and LaunchAgent label: `dev.threadhelm.app`.
- Version remains `1.1.0`; target remains Apple silicon arm64 on macOS 12.3+.
- Current UI, accessibility text, CLI output, active paths, headers, environment variables, package contents, and documentation use ThreadHelm.
- Legacy ChatBird names are input-only and limited to migration, cleanup, and historical documents.
- The existing icon pixels remain unchanged; only `ThreadHelm.icns` and `ThreadHelm-AppIcon-1024.png` resource names change.
- The remote repository and checkout remain `JunwenLu7777/PetBar` and `PetBar`.
- No new dependencies and no unrelated behavior or UI changes.
- Preserve and verify the stopped Claude transcript regression fix before the broad rename.
- Do not overwrite existing ThreadHelm preferences or third-party Claude hooks.

---

### Task 1: Preserve the stopped-Claude-transcript fix as an isolated change

**Files:**
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ClaudeTaskProgress.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/TaskProgressSelfTest.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/TaskProgressSelfTestPhase2.swift`

**Interfaces:**
- Consumes: `ClaudeTaskProgressReader.parseTranscript(lines:sessionID:fallbackTitle:workingDirectory:activeKind:startedAt:modificationDate:)`.
- Produces: transcript items only when agent state or transcript evidence proves activity; metadata-only inactive transcripts return `nil`.

- [ ] **Step 1: Review the existing focused diff**

Run:

```bash
git diff -- macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ClaudeTaskProgress.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/TaskProgressSelfTest.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/TaskProgressSelfTestPhase2.swift
```

Expected: the 30-minute modification-time fallback is removed, the unused `now` argument is removed, and the metadata-only named-session regression returns `nil`.

- [ ] **Step 2: Build and run the task-progress regression suite**

Run:

```bash
./macos/ChatBirdQuotaPanel/scripts/build.sh
macos/ChatBirdQuotaPanel/build/ChatBird.app/Contents/MacOS/ChatBird --self-test-task-progress
```

Expected: build succeeds and the task-progress self-test exits 0 without `inactive Claude metadata transcript reported as running`.

- [ ] **Step 3: Commit only the regression fix**

```bash
git add macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ClaudeTaskProgress.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/TaskProgressSelfTest.swift \
  macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/TaskProgressSelfTestPhase2.swift
git commit -m "Stop treating inactive Claude transcripts as live work" \
  -m $'Constraint: Transcript recency alone cannot prove a Claude process is active\nRejected: Extend the freshness timeout | It preserves the same false-running failure mode\nConfidence: high\nScope-risk: narrow\nDirective: Require agent state or transcript lifecycle evidence before reporting Claude work as running\nTested: arm64 build and task-progress self-test'
```

### Task 2: Define ThreadHelm identity and migrate only supported preferences

**Files:**
- Rename: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ChatBirdApplicationIdentity.swift` → `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ThreadHelmApplicationIdentity.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ThreadHelmApplicationIdentity.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/AppDelegate.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/LifecycleSelfTest.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/TaskProgressSelfTestPhase2.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/PanelFoundation.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/PanelCLI.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/QuotaSelfTests.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/main.swift`

**Interfaces:**
- Consumes: persistent domains `dev.chatbird.app` then `dev.chatbird.codex-quota-panel`.
- Produces: `threadHelmBundleIdentifier`, `threadHelmLaunchAgentLabel`, `legacyThreadHelmBundleIdentifiers`, `migrateLegacyThreadHelmPreferences(from:to:) -> [String]`, and `migrateLegacyThreadHelmPreferencesIfNeeded(defaults:) -> [String]`.

- [ ] **Step 1: Change self-tests to express the new identity and migration contract**

Add assertions equivalent to:

```swift
let target = UserDefaults(suiteName: suite)!
target.set("codex", forKey: "selected-quota-provider")
let migrated = migrateLegacyThreadHelmPreferences(
    from: [
        ["selected-quota-provider": "claude-code"],
        ["selected-quota-provider": "codex"],
    ],
    to: target
)
guard migrated.isEmpty,
      target.string(forKey: "selected-quota-provider") == "codex",
      threadHelmBundleIdentifier == "dev.threadhelm.app",
      legacyThreadHelmBundleIdentifiers == [
          "dev.chatbird.app",
          "dev.chatbird.codex-quota-panel",
      ]
else { exit(1) }
```

Also verify that `presentation-mode`, `pet-enabled`, and `chatbird-pet-origin` are not migrated into a clean ThreadHelm domain.

- [ ] **Step 2: Run the identity tests and confirm they fail**

Run:

```bash
./macos/ChatBirdQuotaPanel/scripts/build.sh
```

Expected: compilation or identity assertions fail because ThreadHelm constants and migration functions do not yet exist.

- [ ] **Step 3: Implement canonical identity and ordered preference migration**

Implement this shape:

```swift
let threadHelmBundleIdentifier = "dev.threadhelm.app"
let threadHelmLaunchAgentLabel = threadHelmBundleIdentifier
let legacyThreadHelmBundleIdentifiers = [
    "dev.chatbird.app",
    "dev.chatbird.codex-quota-panel",
]

private let migratableThreadHelmPreferenceKeys = [
    "selected-quota-provider",
]

@discardableResult
func migrateLegacyThreadHelmPreferences(
    from legacyDomains: [[String: Any]],
    to defaults: UserDefaults
) -> [String] {
    var migrated: [String] = []
    for domain in legacyDomains {
        for key in migratableThreadHelmPreferenceKeys
        where defaults.object(forKey: key) == nil {
            guard let value = domain[key] else { continue }
            defaults.set(value, forKey: key)
            migrated.append(key)
        }
    }
    return migrated
}
```

At startup, read both old persistent domains in the declared order. Rename `panelEdition` to `"threadhelm"`, rename the active product-ID symbol to `threadHelmProductID`, update the health/config output, and expose `--self-test-threadhelm-edition`.

- [ ] **Step 4: Run the focused identity and lifecycle tests**

Run:

```bash
./macos/ChatBirdQuotaPanel/scripts/build.sh
BIN=macos/ChatBirdQuotaPanel/build/ChatBird.app/Contents/MacOS/ChatBird
"$BIN" --self-test-lifecycle
"$BIN" --self-test-threadhelm-edition
"$BIN" --self-test-task-progress
```

Expected: all commands exit 0; edition output contains `edition=threadhelm app-id=dev.threadhelm.app` and the task-progress regression remains green.

- [ ] **Step 5: Commit the identity boundary**

Stage only the files in this task and commit with Lore trailers describing the new preference-domain boundary and legacy-domain order.

### Task 3: Rename the app tree, executable, resources, Swift symbols, and visible copy

**Files:**
- Rename: `macos/ChatBirdQuotaPanel` → `macos/ThreadHelm`
- Rename: `macos/ThreadHelm/Sources/ChatBirdQuotaPanel` → `macos/ThreadHelm/Sources/ThreadHelm`
- Rename: `macos/ThreadHelm/Resources/ChatBirdQuotaPanel.entitlements` → `macos/ThreadHelm/Resources/ThreadHelm.entitlements`
- Rename: `macos/ThreadHelm/Resources/ChatBird.icns` → `macos/ThreadHelm/Resources/ThreadHelm.icns`
- Rename: `macos/ThreadHelm/Resources/ChatBird-AppIcon-1024.png` → `macos/ThreadHelm/Resources/ThreadHelm-AppIcon-1024.png`
- Rename: `macos/ThreadHelm/Resources/dev.chatbird.app.plist.in` → `macos/ThreadHelm/Resources/dev.threadhelm.app.plist.in`
- Modify: `macos/ThreadHelm/Resources/Info.plist`
- Modify: `macos/ThreadHelm/Resources/dev.threadhelm.app.plist.in`
- Modify: `macos/ThreadHelm/scripts/build.sh`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/AppDelegate.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/BoundedProcessCapture.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/ClaudePermissionQuestions.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/ClaudePermissionViews.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/ClaudeTaskProgress.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/ClientContractSelfTest.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/CodexDesktopIntegration.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/CodexTaskProgress.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/DynamicIslandView.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/DynamicIslandTaskView.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/DynamicIslandConfirmationView.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/DynamicIslandPreviewRendering.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/DynamicIslandSelfTest.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/ClaudePermissionPanel.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/GlobalHotKey.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/NativeActivitySuppression.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/NativeNotificationSelfTest.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/OverlayNotificationSync.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/PanelLifecycle.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/PanelPlacement.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/PanelCLI.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/PetPixelTracking.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/PetWindowLocator.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/PlacementSelfTest.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/PreviewRendering.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/QuotaClients.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/QuotaModels.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/QuotaPanelView.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/QuotaPanelViewDrawing.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/TaskActivityPreview.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/TaskProgressModels.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/TaskProgressSelfTest.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/TaskProgressSelfTestPhase2.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/WindowStackGeometry.swift`

**Interfaces:**
- Consumes: ThreadHelm identity constants from Task 2.
- Produces: `ThreadHelm.app/Contents/MacOS/ThreadHelm`, ThreadHelm-named icon resources, `THREADHELM_PANEL_HEALTH_FILE`, `THREADHELM_CODEX_STATE_FILE`, and `THREADHELM_TASK_ROLLOUT_FILE`.

- [ ] **Step 1: Rename tracked paths with `git mv`**

Run explicit `git mv` operations for the project tree, source directory, identity file, entitlements, icons, and LaunchAgent template. Do not rename historical files under `docs/superpowers/specs/` or `docs/superpowers/plans/`.

- [ ] **Step 2: Update the build and metadata contract before implementation**

Set `Info.plist` to:

```xml
<key>CFBundleDisplayName</key><string>ThreadHelm</string>
<key>CFBundleExecutable</key><string>ThreadHelm</string>
<key>CFBundleIdentifier</key><string>dev.threadhelm.app</string>
<key>CFBundleIconFile</key><string>ThreadHelm.icns</string>
<key>CFBundleName</key><string>ThreadHelm</string>
```

Update `build.sh` to compile `Sources/ThreadHelm/*.swift`, emit `build/ThreadHelm.app`, copy the renamed resources, sign with `ThreadHelm.entitlements`, and retain the last good build on compiler failure.

- [ ] **Step 3: Run the renamed build and confirm expected string assertions fail**

Run:

```bash
./macos/ThreadHelm/scripts/build.sh
```

Expected: compilation or self-test expected strings identify remaining ChatBird symbols/copy that still require conversion.

- [ ] **Step 4: Rename current Swift symbols and user-visible strings**

Use `ThreadHelm` for status item, menu, Dock icon, accessibility labels, activity/idle titles, provider subtitles, denial messages, diagnostics, temporary-file prefixes, and self-test output. Rename active `ChatBird...` Swift functions/types to `ThreadHelm...`. Change active hook/state environment variables to the three `THREADHELM_...` names from the interface block.

Keep exact old names only in constants or branches that read legacy state. Do not blanket-replace `custom:chatbird-nt`, old bundle IDs, old executable names, or historical document text.

- [ ] **Step 5: Run all executable self-tests**

Run:

```bash
BIN=macos/ThreadHelm/build/ThreadHelm.app/Contents/MacOS/ThreadHelm
for flag in \
  --self-test-placement \
  --self-test-lifecycle \
  --self-test-native-notification-state \
  --self-test-task-progress \
  --self-test-threadhelm-edition \
  --self-test-weekly-quota \
  --self-test-claude-quota \
  --self-test-claude-hook \
  --self-test-client-contract \
  --self-test-dynamic-island; do
  "$BIN" "$flag" >/dev/null
done
```

Expected: every command exits 0.

- [ ] **Step 6: Commit app-tree and visible-brand rename**

Stage the renamed project tree and commit with Lore trailers. Record legacy compatibility names as the rejected target for global replacement.

### Task 4: Upgrade the product-owned Claude hook without touching third-party hooks

**Files:**
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/ClaudeHookSupport.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/ClaudePermissionHookServer.swift`
- Modify: `macos/ThreadHelm/Sources/ThreadHelm/main.swift`

**Interfaces:**
- Consumes: legacy URL `http://127.0.0.1:27841/chatbird/claude/permission` and header `X-ChatBird-Hook-Token`.
- Produces: current URL `http://127.0.0.1:27841/threadhelm/claude/permission`, header `X-ThreadHelm-Hook-Token`, status text `等待 ThreadHelm 确认…`, and owned-handler upgrade/removal behavior.

- [ ] **Step 1: Add a failing legacy-hook upgrade test**

Write a temporary Claude `settings.json` containing the legacy HTTP handler, legacy auth header, unrelated top-level settings, and no third-party permission handler. Assert that `install`:

```swift
guard try ClaudeHookConfiguration.install(
    at: legacySettingsURL,
    isClaudeAvailable: { true }
), try ClaudeHookConfiguration.status(at: legacySettingsURL) == .installed,
   let data = try? Data(contentsOf: legacySettingsURL),
   let text = String(data: data, encoding: .utf8),
   text.contains("/threadhelm/claude/permission"),
   text.contains("X-ThreadHelm-Hook-Token"),
   !text.contains("/chatbird/claude/permission"),
   !text.contains("X-ChatBird-Hook-Token")
else { exit(1) }
```

Keep the existing command-hook conflict assertion and add an uninstall assertion that removes both current and legacy owned handlers.

- [ ] **Step 2: Run the hook self-test and confirm failure**

Run:

```bash
./macos/ThreadHelm/scripts/build.sh
macos/ThreadHelm/build/ThreadHelm.app/Contents/MacOS/ThreadHelm --self-test-claude-hook
```

Expected: the new legacy-upgrade assertion fails before implementation.

- [ ] **Step 3: Separate current, legacy, and third-party handler classification**

Implement private predicates with these responsibilities:

```swift
private static func isCurrentManagedHandler(_ handler: [String: Any]) -> Bool
private static func isLegacyManagedHandler(_ handler: [String: Any]) -> Bool
private static func isOwnedManagedHandler(_ handler: [String: Any]) -> Bool
private static func upgradedManagedHandler(
    _ handler: [String: Any],
    token: String
) -> [String: Any]
```

`status` reports installed only for the authenticated current handler. `install` treats both current and legacy handlers as owned, upgrades legacy URL/header/status in place, and preserves entry matchers and unrelated settings. Conflict detection continues to reject unrelated `PermissionRequest` handlers without writing the file. `uninstall` removes both owned forms.

- [ ] **Step 4: Run the hook and task suites**

Run the hook, task-progress, and client-contract self-tests. Expected: all exit 0 and the hook output reports the current ThreadHelm protocol.

- [ ] **Step 5: Commit the hook migration**

Stage only the three hook/entry-point files and commit with Lore trailers emphasizing preservation of third-party handlers.

### Task 5: Make source and packaged installers perform an atomic product transition

**Files:**
- Modify: `macos/ThreadHelm/scripts/install.sh`
- Modify: `macos/ThreadHelm/scripts/uninstall.sh`
- Rename: `macos/package/安装ChatBird.command` → `macos/package/安装ThreadHelm.command`
- Rename: `macos/package/检查ChatBird.command` → `macos/package/检查ThreadHelm.command`
- Rename: `macos/package/卸载ChatBird.command` → `macos/package/卸载ThreadHelm.command`
- Modify: `macos/package/安装ThreadHelm.command`
- Modify: `macos/package/检查ThreadHelm.command`
- Modify: `macos/package/卸载ThreadHelm.command`
- Create: `scripts/tests/test-threadhelm-brand-contract.py`

**Interfaces:**
- Consumes: old labels `dev.chatbird.app`, `dev.chatbird.codex-quota-panel`; exact old process/app/log/cache paths; old backup `~/.codex/chatbird-native-notification-backup.json`.
- Produces: installed `~/Applications/ThreadHelm.app`, label `dev.threadhelm.app`, log `ThreadHelm.log`, health edition `threadhelm`, and backup `~/.codex/threadhelm-native-notification-backup.json`.

- [ ] **Step 1: Add a failing static migration contract test**

The Python test reads the three package commands plus source install/uninstall scripts and asserts:

```python
assert 'dev.threadhelm.app' in installer
assert 'dev.chatbird.app' in installer
assert 'dev.chatbird.codex-quota-panel' in installer
assert 'ThreadHelm.app' in installer
assert 'ChatBird.app' in installer
assert 'threadhelm-native-notification-backup.json' in installer
assert 'chatbird-native-notification-backup.json' in installer
assert installer.index('wait_for_panel_health') < installer.rindex('ChatBird.app')
```

Use more precise function/marker matching where raw ordering would match declarations rather than cleanup. Assert the checker reports legacy app, process, and LaunchAgent residue as failures.

- [ ] **Step 2: Run the contract test and confirm failure**

Run:

```bash
python3 scripts/tests/test-threadhelm-brand-contract.py
```

Expected: missing ThreadHelm package paths and transition checks fail.

- [ ] **Step 3: Implement install transition ordering**

Both installers must:

1. verify `ThreadHelm.app` before mutation;
2. boot out all three exact labels and stop exact `ThreadHelm`, `ChatBird`, and `ChatBirdQuotaPanel` processes;
3. move the old notification backup to the new path only when the new path does not exist;
4. install/sign ThreadHelm, upgrade the owned Claude hook, prepare notifications, create the new plist, and verify new health;
5. only after health succeeds, remove old ChatBird apps, plists, logs, and health caches.

Do not recursively delete a path derived from an unresolved variable. Keep all cleanup targets explicit.

- [ ] **Step 4: Implement check and uninstall compatibility**

The check command fails if either old app exists, either old label is loaded/present, or either old process is running. The uninstall command uses the ThreadHelm binary first, falls back to either legacy binary for cleanup, restores from the new backup with old-backup fallback, and removes exact new and legacy product artifacts.

- [ ] **Step 5: Verify script syntax and migration contract**

Run:

```bash
zsh -n macos/package/*.command macos/ThreadHelm/scripts/*.sh
python3 scripts/tests/test-threadhelm-brand-contract.py
```

Expected: all checks pass.

- [ ] **Step 6: Commit installer migration**

Stage the two source scripts, three renamed package commands, and the new regression test. Commit with Lore trailers describing the health-before-legacy-cleanup constraint.

### Task 6: Rename current documentation, repository validation, CI, and release payload

**Files:**
- Modify: `README.md`
- Modify: `PRIVACY.md`
- Modify: `ASSET-NOTICE.md`
- Modify: `macos/README.md`
- Modify: `macos/ThreadHelm/README.md`
- Modify: `script/build_and_run.sh`
- Modify: `scripts/build-macos-release.sh`
- Modify: `scripts/privacy-audit.sh`
- Modify: `scripts/update-readme-downloads.sh`
- Modify: `scripts/validate-repository-layout.py`
- Modify: `scripts/tests/test-layout-validator.py`
- Modify: `scripts/tests/test-build-macos-release-verify-only.sh`
- Modify: `.github/workflows/validate.yml`
- Modify: `.github/workflows/update-download-links.yml`
- Delete: `dist/ChatBird-macOS-arm64-1.1.0.zip`
- Delete: `dist/ChatBird-macOS-arm64-1.1.0.zip.sha256`
- Create: `dist/ThreadHelm-macOS-arm64-1.1.0.zip`
- Create: `dist/ThreadHelm-macOS-arm64-1.1.0.zip.sha256`

**Interfaces:**
- Consumes: built `macos/ThreadHelm/build/ThreadHelm.app` and the three ThreadHelm package commands.
- Produces: one tracked arm64 release archive, checksum, ThreadHelm-only current documentation, and CI/repository checks that allow legacy names only in approved compatibility and historical locations.

- [ ] **Step 1: Update validator tests to require ThreadHelm paths and archive names**

Change fixture expectations to `macos/ThreadHelm`, `Sources/ThreadHelm`, `ThreadHelm.app`, `dev.threadhelm.app.plist.in`, the three renamed commands, and `ThreadHelm-macOS-arm64-1.1.0.zip`. Add a negative case proving a new current source string such as `ChatBird 活动` is rejected while an explicit legacy identifier or historical spec is allowed.

- [ ] **Step 2: Run repository and release tests and confirm failure**

Run:

```bash
python3 scripts/tests/test-layout-validator.py
zsh scripts/tests/test-build-macos-release-verify-only.sh
```

Expected: tests fail against old validator and release identities.

- [ ] **Step 3: Update current docs and tooling**

Replace current product prose, install paths, commands, executable examples, privacy/asset identity, workflow job/artifact names, and download-update logic. Rename active script variables to `THREADHELM_RELEASE_ROOT`, `THREADHELM_SKIP_APP_BINARY_CHECKS`, and `THREADHELM_PRIVACY_AUDIT_ROOT`.

Keep `JunwenLu7777/PetBar`, `custom:chatbird-nt`, old install artifacts in migration docs/code, and historical specs/plans unchanged.

- [ ] **Step 4: Enforce current-brand boundaries**

Update repository validation so current source, scripts, package files, workflow files, and current docs reject unapproved `ChatBird`/`chatbird` occurrences. Use an explicit allowlist for migration constants/branches and historical documentation rather than a broad directory exclusion.

- [ ] **Step 5: Run all local validators and script tests**

Run:

```bash
python3 scripts/validate-repository-layout.py
python3 scripts/tests/test-layout-validator.py
for script in scripts/tests/*.sh; do zsh "$script"; done
./scripts/privacy-audit.sh
zsh -n macos/package/*.command macos/ThreadHelm/scripts/*.sh script/*.sh scripts/*.sh
```

Expected: every command exits 0.

- [ ] **Step 6: Build the release and replace the tracked archive**

Run:

```bash
./scripts/build-macos-release.sh
./scripts/build-macos-release.sh --verify-only
unzip -tq dist/ThreadHelm-macOS-arm64-1.1.0.zip
```

Expected: exactly one ThreadHelm archive/checksum pair is tracked; payload contains ThreadHelm app, plist, and commands and no current ChatBird app/package path.

- [ ] **Step 7: Commit current docs, CI, validators, and release**

Stage only the files in this task, review the binary/archive rename in `git status`, and commit with Lore trailers including all validators and release checks run.

### Task 7: Run full verification and reinstall ThreadHelm

**Files:**
- Verify: `macos/ThreadHelm/build/ThreadHelm.app`
- Verify: `dist/ThreadHelm-macOS-arm64-1.1.0.zip`
- Verify installed: `~/Applications/ThreadHelm.app`
- Verify installed: `~/Library/LaunchAgents/dev.threadhelm.app.plist`

**Interfaces:**
- Consumes: all commits and release artifacts from Tasks 1–6.
- Produces: a signed, healthy, locally installed ThreadHelm instance with no loaded/running ChatBird predecessor.

- [ ] **Step 1: Review the complete diff and working tree**

Run:

```bash
git status --short
git diff HEAD~6 --check
git diff HEAD~6 --stat
```

Expected: no whitespace errors, no unexplained files, and historical/compatibility old-name occurrences are narrowly justified.

- [ ] **Step 2: Run full build and executable verification**

Run the build, all ten self-test flags from Task 3, repository validator, privacy audit, Python/shell regression tests, shell syntax, release build, verify-only, `codesign --verify --deep --strict`, `lipo -archs`, and `plutil` checks for display name, executable, bundle ID, icon, version, and minimum macOS.

- [ ] **Step 3: Verify the packaged installer without mutation**

Extract the release into a temporary directory and run:

```bash
./安装ThreadHelm.command --verify-only
```

Expected: package completeness and signature checks pass.

- [ ] **Step 4: Install the renamed product**

Run the packaged `安装ThreadHelm.command`. This is authorized by the user's request to fix, rename, and reinstall the app.

- [ ] **Step 5: Verify installed runtime and legacy cleanup**

Run `检查ThreadHelm.command`, then independently verify:

```bash
test -x "$HOME/Applications/ThreadHelm.app/Contents/MacOS/ThreadHelm"
test ! -e "$HOME/Applications/ChatBird.app"
launchctl print "gui/$(id -u)/dev.threadhelm.app"
! launchctl print "gui/$(id -u)/dev.chatbird.app"
! launchctl print "gui/$(id -u)/dev.chatbird.codex-quota-panel"
! pgrep -x ChatBird
! pgrep -x ChatBirdQuotaPanel
```

Expected: ThreadHelm is healthy and both legacy labels/processes/apps are absent.

- [ ] **Step 6: Capture visual proof**

Open the installed app, capture the expanded activity surface, and inspect that the header reads `ThreadHelm 活动` (or `ThreadHelm 空闲` when no task is running) with the rest of the UI unchanged.

- [ ] **Step 7: Report completion evidence**

Report changed identity, preference/hook/install migration behavior, test/build/release results, installed paths and label, visual title verification, the optional Accessibility reauthorization caveat, and any remaining historical/compatibility ChatBird references.
