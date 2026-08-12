# Remove ChatBird Desktop Pet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the complete blue desktop-pet and pet-panel path so ChatBird ships and runs as a dynamic-island-only macOS app.

**Architecture:** Collapse presentation state to one dynamic-island runtime, remove the pet mode switch from the capsule, then delete the unreachable AppKit pet/panel stack. Keep the dynamic island's dashboard store, task/quota views, Claude confirmation presenter, window-level reconciliation, recovery controls, and legacy Codex-pet cleanup.

**Tech Stack:** Swift 5, AppKit, Foundation, CoreGraphics, zsh release scripts, Python repository validator, direct `swiftc` build, macOS 12.3+ arm64.

## Global Constraints

- Preserve task activity, Claude permission confirmation, quota, notification suppression, menu-bar recovery, Dock recovery, and multi-display behavior.
- Keep `dev.chatbird.app`, `chatbird-nt`, `dev.chatbird.app` LaunchAgent state, and the current health-file location unchanged.
- Keep legacy `custom:chatbird-nt` recognition only for safe migration cleanup.
- Do not add dependencies.
- Preserve the pre-existing uncommitted edits in `DynamicIslandView.swift`, `DynamicIslandSelfTest.swift`, and the app-icon assets.
- The final `ChatBird.app` must not contain `ChatBirdPetSpritesheet.webp`.

---

### Task 1: Lock Dynamic-Island-Only Runtime State

**Files:**
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/LifecycleSelfTest.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/TaskProgressSelfTestPhase2.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ActivityDashboardModels.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ActivityDashboardStore.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/PanelLifecycle.swift`

**Interfaces:**
- Produces: `dynamicIslandVisibilityAction(hiddenByUser:hasCurrentPermissionRequest:) -> DynamicIslandVisibilityAction`.
- Produces: `PresentationCommand` with only `.toggleVisibility`, `.moveToCurrentDisplay`, and `.quit`.
- Preserves: `shouldPresentClaudePermissionPanel(cachedCodexDesktopRunning:liveCodexDesktopRunning:)` and terminal-task acknowledgement helpers.

- [ ] **Step 1: Replace pet-mode lifecycle assertions with dynamic-only assertions**

Add assertions equivalent to:

```swift
guard dynamicIslandVisibilityAction(
    hiddenByUser: false,
    hasCurrentPermissionRequest: false
) == .capsule,
dynamicIslandVisibilityAction(
    hiddenByUser: false,
    hasCurrentPermissionRequest: true
) == .confirmation,
dynamicIslandVisibilityAction(
    hiddenByUser: true,
    hasCurrentPermissionRequest: true
) == .hidden
else {
    fputs("dynamic-island-only visibility decision failed\n", stderr)
    exit(1)
}
```

Update preference migration assertions so stored `presentation-mode=pet-panel` and `pet-enabled=true` do not affect runtime state. Remove assertions that select, click, enable, or position a pet.

- [ ] **Step 2: Build to confirm the old runtime contract now fails**

Run: `macos/ChatBirdQuotaPanel/scripts/build.sh`

Expected: compilation fails because the new two-argument visibility function and reduced command enum do not exist yet.

- [ ] **Step 3: Remove presentation and pet state from models**

Delete `PresentationMode`, `PresentationModePreference`, `PetEnabledPreference`, and `ActivityDashboardSnapshot.petEnabled`. Replace the runtime decision API with:

```swift
enum PresentationCommand: Equatable {
    case toggleVisibility
    case moveToCurrentDisplay
    case quit
}

func dynamicIslandVisibilityAction(
    hiddenByUser: Bool,
    hasCurrentPermissionRequest: Bool
) -> DynamicIslandVisibilityAction {
    guard !hiddenByUser else { return .hidden }
    return hasCurrentPermissionRequest ? .confirmation : .capsule
}
```

Delete `shouldPresentPanel`, `shouldPresentDetachedPetPanel`, `PresentationRuntimeDecision`, `codexExitPresentationDecision`, `codexLifecyclePresentationDecision`, `shouldHandlePetClick`, `isPresentationCommandEnabled`, `dashboardSnapshotPreservedAcrossPresentationSwitch`, `PetPanelClickAction`, and `petPanelClickAction`.

- [ ] **Step 4: Run targeted lifecycle tests**

Run:

```bash
macos/ChatBirdQuotaPanel/scripts/build.sh
macos/ChatBirdQuotaPanel/build/ChatBird.app/Contents/MacOS/ChatBird --self-test-lifecycle
macos/ChatBirdQuotaPanel/build/ChatBird.app/Contents/MacOS/ChatBird --self-test-task-progress
```

Expected: both self-tests exit 0 and lifecycle output names dynamic-island-only visibility.

- [ ] **Step 5: Commit only isolated state changes**

Stage only the named files; use `git add -p` for files that contained earlier edits. Commit with a Lore message whose intent is “Make dynamic island the only presentation state,” and record the two self-tests under `Tested:`.

---

### Task 2: Remove the Pet Switch from the Capsule

**Files:**
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandView.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandWindowController.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/DynamicIslandSelfTest.swift`

**Interfaces:**
- Preserves: `dynamicIslandCapsuleSize == NSSize(width: 404, height: 58)`.
- Removes: every `onRequestPetPanel`, `setPetPanelAvailable`, `requestPetPanel`, and mode-switch snapshot member.
- Produces: one full-capsule `hitTargetButton` plus the existing chevron.

- [ ] **Step 1: Change capsule layout assertions first**

Update `DynamicIslandCapsuleLayoutSnapshot` expectations to require:

```swift
capsuleLayout.bounds.size == NSSize(width: 404, height: 58)
capsuleLayout.chevronFrame == NSRect(x: 380, y: 21, width: 8, height: 16)
capsuleLayout.hitTargetFrame == NSRect(x: 0, y: 0, width: 404, height: 58)
capsuleLayout.buttonCount == 1
capsuleLayout.hasVisibleButtonTitle == false
capsuleLayout.hitTargetAccessibilityHelp
    == "点击展开灵动岛功能面板；拖动可移到其他屏幕"
```

Remove tests for `modeSwitchFrame`, title, tooltip, accessibility label, disabled-pet tooltip, and simulated pet-mode clicks.

- [ ] **Step 2: Run the dynamic-island self-test to verify failure**

Run: `macos/ChatBirdQuotaPanel/build/ChatBird.app/Contents/MacOS/ChatBird --self-test-dynamic-island`

Expected: FAIL in capsule chrome assertions while the mode-switch button still exists.

- [ ] **Step 3: Delete the mode-switch implementation and reflow capsule content**

Remove the mode-switch button, callback, availability state, setup, target-action, and self-test hooks. Lay out the remaining right edge as:

```swift
let chevronFrame = NSRect(
    x: max(0, view.bounds.width - 24),
    y: centerY - 8,
    width: 8,
    height: 16
)
chevronView.frame = chevronFrame
elapsedField.frame = NSRect(
    x: max(0, chevronFrame.minX - 104),
    y: centerY - 10,
    width: 96,
    height: 20
)
hitTargetButton.frame = view.bounds
```

Set the help text exactly to `点击展开灵动岛功能面板；拖动可移到其他屏幕`. Expand the quota summary to end before the chevron without overlapping it. Remove callback plumbing from the root and window controllers.

- [ ] **Step 4: Rebuild and run the dynamic-island self-test**

Run:

```bash
macos/ChatBirdQuotaPanel/scripts/build.sh
macos/ChatBirdQuotaPanel/build/ChatBird.app/Contents/MacOS/ChatBird --self-test-dynamic-island
```

Expected: build and self-test exit 0; capsule snapshot reports one untitled button and no pet control.

- [ ] **Step 5: Commit the capsule cleanup without staging earlier unrelated hunks**

Use `git add -p` on the two pre-dirty files. Commit with intent “Give the dynamic island one unambiguous interaction surface” and include the dynamic-island self-test under `Tested:`.

---

### Task 3: Delete Pet and Pet-Panel AppKit Production Paths

**Files:**
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/AppDelegate.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/PanelFoundation.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/PanelLifecycle.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/PanelCLI.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/WindowStackGeometry.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/main.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ClaudeHookSupport.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/TaskProgressModels.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/TaskProgressSelfTest.swift`
- Modify: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/QuotaSelfTests.swift`
- Delete: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ChatBirdPetWindowController.swift`
- Delete: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/ClaudePermissionPanel.swift`
- Delete: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/PanelPlacement.swift`
- Delete: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/PetPixelTracking.swift`
- Delete: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/PetWindowLocator.swift`
- Delete: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/PlacementSelfTest.swift`
- Delete: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/PreviewRendering.swift`
- Delete: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/QuotaPanelView.swift`
- Delete: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/QuotaPanelViewDrawing.swift`
- Delete: `macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/TaskActivityPreview.swift`
- Delete: `macos/ChatBirdQuotaPanel/docs/chatbird-panel-preview.png`

**Interfaces:**
- App startup creates only `DynamicIslandWindowController` and its `DynamicIslandConfirmationPresenter`.
- Dashboard updates continue through `DynamicIslandWindowController(store:)`.
- Window-stack code retains `WindowStackEntry`, `currentWindowStackEntries`, `nativeActivityStackIntersectsPanel`, and `nativeActivityStackOccludesPanel`.
- Runtime health retains `version`, `edition`, `pid`, `status`, `panelVisible`, quota metadata, and timestamps, but drops `petID`, pet gap, pointer error, and pet-panel scale fields.

- [ ] **Step 1: Add absence and startup assertions before deleting code**

Update lifecycle and hook self-tests to assert that startup binds `DynamicIslandConfirmationPresenter`, menu command coverage is exactly visibility/move/quit, and health JSON has no `petID`. Remove legacy panel-presenter UI assertions and retain coordinator behavior using a lightweight test presenter conforming to `ClaudePermissionPresenting`.

- [ ] **Step 2: Run the affected self-tests to capture failure**

Run:

```bash
macos/ChatBirdQuotaPanel/scripts/build.sh
BIN="macos/ChatBirdQuotaPanel/build/ChatBird.app/Contents/MacOS/ChatBird"
"$BIN" --self-test-lifecycle
"$BIN" --self-test-claude-hook
```

Expected: at least one assertion fails because the pet/panel presenter and `petID` health field still exist.

- [ ] **Step 3: Simplify `AppDelegate` to one presentation**

Remove the legacy `NSPanel`, `QuotaPanelView`, task-hover preview, pet controller, pet preferences, presentation mode, panel geometry, pet fallback display, and follow timer. Create a `windowStackRefreshTimer` at `overlayStateRefreshInterval` and implement:

```swift
private func reconcileDynamicIslandWindowLevel() {
    dynamicIslandController?.reconcileWindowLevel(
        entries: currentWindowStackEntries()
    )
}

private func showCurrentPresentation() {
    switch dynamicIslandVisibilityAction(
        hiddenByUser: isPanelHiddenByUser,
        hasCurrentPermissionRequest:
            dashboardStore.snapshot.permissionQueue.current != nil
    ) {
    case .hidden:
        dynamicIslandController?.hide()
    case .capsule:
        dynamicIslandController?.showCapsule()
    case .confirmation:
        dynamicIslandController?.expand(.confirmation)
    }
}
```

Bind the confirmation coordinator directly to `dynamicIslandConfirmationPresenter`; screen-change handling updates only the dynamic-island controller and window level. Status-menu construction contains show/hide, move-to-current-display, and quit.

- [ ] **Step 4: Delete pet-only UI, geometry, CLI, and preview code**

Delete the listed files. Remove `--print-panel-location`, `--print-saved-panel-location`, `--self-test-placement`, and `--render-preview` dispatch from `main.swift`. Remove their README commands. Trim `PanelFoundation.swift` to shared quota/date/task constants, and trim `WindowStackGeometry.swift` to the four dynamic-island/native-activity interfaces listed above.

Delete `TaskActivityPreviewPayload` and its builder after removing the corresponding legacy-view self-tests. Remove `QuotaPanelView`-specific tests from quota/task suites; keep model and dynamic-island UI coverage. Replace `ClaudePermissionPanelPresenter` self-tests with a fake presenter so hook queue, expiry, and fallback behavior remain covered.

- [ ] **Step 5: Rebuild and run all surviving self-tests**

Run:

```bash
macos/ChatBirdQuotaPanel/scripts/build.sh
BIN="macos/ChatBirdQuotaPanel/build/ChatBird.app/Contents/MacOS/ChatBird"
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

Expected: every command exits 0; no placement self-test remains.

- [ ] **Step 6: Commit the production deletion**

Stage the exact production/test deletions and modifications only. Commit with intent “Remove the desktop-pet runtime so ChatBird has one supported UI,” `Scope-risk: broad`, and list all surviving self-tests under `Tested:`.

---

### Task 4: Remove Robot Assets and Release Requirements

**Files:**
- Modify: `macos/ChatBirdQuotaPanel/scripts/build.sh`
- Modify: `scripts/build-macos-release.sh`
- Modify: `scripts/tests/test-build-macos-release-verify-only.sh`
- Modify: `scripts/validate-repository-layout.py`
- Modify: `scripts/tests/test-layout-validator.py`
- Modify: `scripts/privacy-audit.sh`
- Modify: `README.md`
- Modify: `macos/ChatBirdQuotaPanel/README.md`
- Modify: `macos/README.md`
- Modify: `PRIVACY.md`
- Modify: `ASSET-NOTICE.md`
- Delete: `shared/pet/chatbird-nt/pet.json`
- Delete: `shared/pet/chatbird-nt/spritesheet.webp`
- Delete: `shared/pet/chatbird-nt/validation.json`
- Delete: `shared/preview/chatbird-nt/contact-sheet.png`
- Delete: `shared/preview/chatbird-nt/look-directions.png`
- Delete: `shared/preview/chatbird-nt/panel-preview.png`
- Delete: `shared/preview/chatbird-nt/run-summary.json`
- Delete: `shared/preview/chatbird-nt/validation.json`

**Interfaces:**
- Local build copies only `Info.plist`, entitlement-dependent binary resources, provider SVGs, app PNG, and `.icns`.
- Release staging contains no `pet/` or `preview-qa/` directory.
- Repository validator no longer requires or allowlists current `shared/pet` and `shared/preview` content.
- Privacy audit still scans every tracked file plus app/package untracked inputs.

- [ ] **Step 1: Make packaging tests reject the old resource**

Change the release fixture so `verify_stage` fails if `ChatBirdPetSpritesheet.webp`, `pet/`, or `preview-qa/` exists. Add an explicit assertion after a passing fixture build:

```bash
[[ ! -e "$stage/ChatBird.app/Contents/Resources/ChatBirdPetSpritesheet.webp" ]]
[[ ! -e "$stage/pet" ]]
[[ ! -e "$stage/preview-qa" ]]
```

Update layout-validator tests so removed current shared paths are rejected while historical forbidden markers remain rejected.

- [ ] **Step 2: Run packaging tests to verify failure**

Run:

```bash
zsh scripts/tests/test-build-macos-release-verify-only.sh
python3 scripts/tests/test-layout-validator.py
```

Expected: fail until the release and validator scripts stop requiring pet inputs.

- [ ] **Step 3: Remove build/release pet inputs and assets**

Remove `PET_SPRITESHEET` from the app build, `PET_SOURCE`, `PREVIEW_QA_SOURCE`, strict pet-media verification, pet/preview staging, pet resource requirements, and pet/preview freshness inputs from release scripts. Delete the listed assets. If the `shared` directory has no remaining tracked files, remove `shared` from `ALLOWED_TOP_LEVEL`.

Keep legacy configuration cleanup in install/uninstall/check scripts because it prevents old Codex Pet state from resurfacing.

- [ ] **Step 4: Update current product and privacy documentation**

Describe ChatBird as a dynamic-island task/quota companion. Remove desktop-pet, pet-panel, sprite, preview-QA, and mode-switch claims. Keep historical spec/plan documents unchanged. Remove pet asset licensing entries and state that no desktop-pet media ships.

- [ ] **Step 5: Run repository and release-script verification**

Run:

```bash
python3 scripts/validate-repository-layout.py
python3 scripts/tests/test-layout-validator.py
zsh scripts/privacy-audit.sh
zsh scripts/tests/test-build-macos-release-verify-only.sh
```

Expected: all four commands exit 0.

- [ ] **Step 6: Commit packaging and documentation cleanup**

Commit only the listed scripts, docs, and removed assets with intent “Stop shipping the robot after removing its runtime,” and record all four verification commands in `Tested:`.

---

### Task 5: Full Verification, Release Build, Reinstall, and Runtime Proof

**Files:**
- Verify: `macos/ChatBirdQuotaPanel/build/ChatBird.app`
- Verify: `dist/ChatBird-macOS-arm64-1.1.0.zip`
- Install: `/Users/junwenlu/Applications/ChatBird.app`

**Interfaces:**
- Installed executable: `/Users/junwenlu/Applications/ChatBird.app/Contents/MacOS/ChatBird`.
- LaunchAgent: `gui/$(id -u)/dev.chatbird.app`.
- Health file: `/Users/junwenlu/Library/Caches/dev.chatbird.app/panel-health.json`.

- [ ] **Step 1: Prove current product code has no pet UI path**

Run:

```bash
rg -n "ChatBirdPet|PetWindowLocator|PetPixelTracking|宠物面板|桌面宠物|ChatBirdPetSpritesheet|onRequestPetPanel|togglePet|petEnabled|pet-panel" \
  macos/ChatBirdQuotaPanel/Sources \
  macos/ChatBirdQuotaPanel/Resources \
  macos/ChatBirdQuotaPanel/scripts \
  README.md macos/README.md macos/ChatBirdQuotaPanel/README.md
```

Expected: no matches. Run a separate search for `custom:chatbird-nt`; matches are allowed only in legacy migration cleanup and historical documents.

- [ ] **Step 2: Run the full local verification sequence**

Run the repository checks and all surviving self-tests from Tasks 3 and 4, then render every state listed by `DynamicIslandPreviewState.allCases` through `--render-dynamic-island-preview`. Expected: zero nonzero exits and every output PNG is nonempty.

- [ ] **Step 3: Build and verify the release archive**

Run:

```bash
./scripts/build-macos-release.sh
./scripts/build-macos-release.sh --verify-only
```

Expected: both commands exit 0; archive inspection finds no `ChatBirdPetSpritesheet.webp`, `/pet/`, or `/preview-qa/` entry.

- [ ] **Step 4: Reinstall and verify the running app**

Run:

```bash
macos/ChatBirdQuotaPanel/scripts/install.sh
codesign --verify --deep --strict /Users/junwenlu/Applications/ChatBird.app
test ! -e /Users/junwenlu/Applications/ChatBird.app/Contents/Resources/ChatBirdPetSpritesheet.webp
launchctl print "gui/$(id -u)/dev.chatbird.app"
pgrep -fl '^.*ChatBird.app/Contents/MacOS/ChatBird$'
test -s /Users/junwenlu/Library/Caches/dev.chatbird.app/panel-health.json
```

Expected: installer prints `/Users/junwenlu/Applications/ChatBird.app`; signature is valid; the resource absence check passes; LaunchAgent and process are running; health file is nonempty.

- [ ] **Step 5: Review final diff and report evidence**

Run `git diff --check`, `git status --short`, and `git diff --stat`. Confirm pre-existing app-icon changes remain present and no unrelated user edits were reverted. Report deleted production files/assets, preserved dynamic-island capabilities, verification commands, installed path, and any historical-only `chatbird-nt` references.
