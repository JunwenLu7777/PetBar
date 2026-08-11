# Remove the ChatBird Desktop Pet

**Date:** 2026-08-12
**Status:** Approved design
**Scope:** ChatBird macOS app, release packaging, tests, and current product documentation

## Goal

Remove the blue desktop robot and the complete desktop-pet/pet-panel product path. ChatBird becomes a dynamic-island-only macOS app while preserving its task activity, Claude permission confirmation, quota, notification suppression, menu-bar recovery, Dock recovery, and multi-display behavior.

## Product Behavior

- ChatBird launches directly into the dynamic-island capsule.
- The status menu keeps show/hide, move-to-current-display, and quit actions.
- The status menu no longer contains desktop-pet or presentation-mode actions.
- The dynamic-island capsule no longer contains the button that switches to the pet panel.
- Stored `presentation-mode` or `pet-enabled` preferences cannot restore or expose the removed interface.
- Hiding and reopening ChatBird affects the dynamic island only.
- Claude permission requests continue to use the dynamic-island confirmation presenter.

## Code and Asset Boundaries

Delete production code that exists only to render, animate, position, follow, click, drag, enable, or present the desktop pet and pet panel. Delete the robot spritesheet and pet-only preview/validation assets. Remove build and release requirements that copy or validate those assets.

Retain code that is still used by the dynamic island, including task/quota models, dynamic-island window placement, window-stack reconciliation, native activity suppression, Claude Hook integration, Dock/status recovery, and any generic geometry helper with a remaining non-pet caller.

Historical migration cleanup may continue to recognize the legacy `custom:chatbird-nt` identifier so upgrades do not reactivate an old Codex pet. Historical design and implementation records remain unchanged.

## State and Migration

Presentation mode is no longer user-selectable. Runtime decisions always target the dynamic island. Legacy `presentation-mode` and `pet-enabled` values are ignored; implementation may remove those keys during startup when doing so is local, safe, and testable.

The app identity, bundle identifier, edition identifier, LaunchAgent label, and health-file location do not change.

## Packaging and Documentation

- `ChatBird.app` must not contain `ChatBirdPetSpritesheet.webp`.
- Release verification must not require pet source or preview directories.
- Repository layout and privacy audit allowlists must be updated for the removed current assets without weakening checks for unrelated legacy paths.
- Current README, privacy, and asset notices must stop advertising or licensing the removed desktop-pet assets.

## Testing

Tests must prove:

1. startup and reopen decisions expose only the dynamic island;
2. menus and capsule controls have no pet enable/mode-switch action;
3. legacy preference values cannot restore pet UI;
4. dynamic-island task, confirmation, quota, placement, and visibility behavior remains intact;
5. local and release builds succeed without pet assets;
6. the installed app contains no pet spritesheet, has a valid signature, launches through its LaunchAgent, and reports healthy runtime state.

## Completion Criteria

- No shipped UI, runtime branch, menu action, or bundled resource can display the blue robot or pet panel.
- Pet-only source and current pet/preview assets are removed.
- Relevant self-tests, repository validation, privacy audit, release verification, full build, signing verification, and reinstall verification pass.
- Pre-existing unrelated working-tree edits remain preserved.
