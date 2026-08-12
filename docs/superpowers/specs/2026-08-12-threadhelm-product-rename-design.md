# Rename ChatBird to ThreadHelm

**Date:** 2026-08-12
**Status:** Approved design
**Scope:** Current macOS product identity, source naming, migration, packaging, tests, documentation, and local installation

## Goal

Rename the complete current product from **ChatBird** to **ThreadHelm**. The new name reflects a macOS control surface for Codex and Claude task threads: it monitors execution, presents permission requests, shows quota state, and returns the user to the originating session.

The rename is complete only when users install, launch, view, operate, diagnose, package, and uninstall a product called ThreadHelm. Changing only the activity-window title is not sufficient.

## Product Identity

The canonical current identity becomes:

| Surface | Identity |
| --- | --- |
| Product and display name | `ThreadHelm` |
| Activity title | `ThreadHelm 活动` |
| Idle title | `ThreadHelm 空闲` |
| App bundle | `ThreadHelm.app` |
| Executable | `ThreadHelm` |
| Bundle identifier | `dev.threadhelm.app` |
| LaunchAgent label | `dev.threadhelm.app` |
| App icon resources | `ThreadHelm.icns`, `ThreadHelm-AppIcon-1024.png` |
| Release archive | `ThreadHelm-macOS-arm64-1.1.0.zip` |
| Package commands | `安装ThreadHelm.command`, `检查ThreadHelm.command`, `卸载ThreadHelm.command` |
| Installed log | `~/Library/Logs/ThreadHelm.log` |
| Health directory | `~/Library/Caches/dev.threadhelm.app/` |

The existing icon artwork remains unchanged because its stacked-thread visual fits ThreadHelm and contains no bird or pet branding. Only the resource identity changes. Version `1.1.0` remains unchanged for this rename, matching the approved release example; the archive and checksum are regenerated under the new product identity.

## Current Source and Repository Naming

Current product code and tooling use ThreadHelm naming throughout:

- rename `macos/ChatBirdQuotaPanel` to `macos/ThreadHelm`;
- rename its source directory, identity source, entitlement, icon, LaunchAgent template, and current product-facing symbols where they contain `ChatBird`;
- rename active environment variables, script variables, diagnostics, self-test names, UI/accessibility strings, comments, fixture paths, workflow labels, and release-validation expectations;
- update current README, privacy notice, asset notice, package documentation, CI, and release tooling;
- replace the tracked ChatBird archive and checksum with the equivalent ThreadHelm archive and checksum.

The remote repository URL and local checkout directory remain `JunwenLu7777/PetBar` and `PetBar`; changing an external repository is a separate networked operation and is not required for the installed product identity.

Historical specifications and implementation plans remain unchanged so that they continue to describe the product state and decisions at the time they were written. They may therefore mention ChatBird. Production compatibility code may also retain narrowly named legacy constants and paths when required to migrate or remove an old installation. No current user-visible surface may use the old name.

## Upgrade and State Migration

Changing the bundle identifier creates a new macOS preferences domain. On first ThreadHelm launch, the app migrates supported preferences from both prior domains, in newest-to-oldest order:

1. `dev.chatbird.app`;
2. `dev.chatbird.codex-quota-panel`.

Migration copies only known product preferences, never overwrites an existing ThreadHelm value, and remains idempotent. Removed pet and presentation preferences are not reactivated. Tests cover the selected quota provider and every still-supported persisted UI preference.

The installer performs an in-place product transition:

1. build and verify `ThreadHelm.app`;
2. stop the ThreadHelm LaunchAgent plus both known ChatBird LaunchAgents;
3. stop only the exact ThreadHelm and legacy ChatBird process names;
4. migrate the native-notification backup to a ThreadHelm-named path when needed, without overwriting newer ThreadHelm state;
5. recognize an installed ChatBird-owned Claude permission hook as this product's legacy hook and replace it with the ThreadHelm command instead of reporting a third-party conflict;
6. install and sign `~/Applications/ThreadHelm.app`;
7. install and start `dev.threadhelm.app`;
8. verify health from the new executable and LaunchAgent;
9. remove the old ChatBird apps, plists, logs, and obsolete health caches only after the new app is installed successfully.

The transition must never leave ThreadHelm and ChatBird running together. Cleanup remains safe to repeat after partial or interrupted installation. Unrelated Claude hooks, Codex configuration, credentials, sessions, and user files are preserved.

Because macOS may treat the new bundle identifier as a new app for Accessibility permission, ThreadHelm continues to work without that permission and documents that notification-suppression automation may need to be granted again. Installation success does not depend on that optional permission.

## Compatibility Boundaries

Legacy ChatBird names are allowed only where the software must recognize previous state for migration or cleanup, including:

- old bundle identifiers and LaunchAgent labels;
- old app, executable, log, cache, backup, and hook command paths;
- the historical `custom:chatbird-nt` Codex pet identifier;
- old preference domains;
- historical design and implementation documents.

New builds, launch templates, headers, environment variables, backup files, health files, diagnostics, package contents, and user-facing text use ThreadHelm. Compatibility aliases are input-only; newly written state never uses the old identity.

## Functional Behavior

The rename does not alter task collection, running/completed classification, duration handling, task previews, permission decisions, quota retrieval, panel placement, hotkeys, Codex notification suppression, or session restoration. In particular, the existing fix for stopped Claude transcripts incorrectly appearing as running remains intact and its regression tests continue to pass.

Permission-denial messages, hook status messages, menu labels, Dock/status accessibility descriptions, provider subtitles, health diagnostics, and CLI output all use ThreadHelm.

## Testing and Verification

Tests and checks must prove:

1. all current UI, accessibility, CLI, app metadata, build paths, package files, and release payloads expose ThreadHelm identity;
2. production source has no unapproved ChatBird occurrence outside the explicit compatibility allowlist;
3. supported preferences migrate from `dev.chatbird.app` and the older quota-panel domain without overwriting existing ThreadHelm values;
4. an owned legacy Claude hook upgrades, while an unrelated third-party hook remains untouched;
5. installer cleanup targets exact legacy artifacts and does not remove unrelated files;
6. the stopped-Claude-transcript regression tests and all existing self-tests still pass;
7. repository layout, privacy audit, shell syntax, build, signing, release construction, checksum verification, and verify-only release checks pass;
8. the installed app is `~/Applications/ThreadHelm.app`, its executable and bundle identifier are correct, `dev.threadhelm.app` is healthy, and no legacy ChatBird process or LaunchAgent remains loaded;
9. the installed UI visibly says `ThreadHelm 活动` or `ThreadHelm 空闲` as appropriate.

## Completion Criteria

- The current product is consistently named ThreadHelm from source tree to installed UI and release archive.
- Existing user preferences and product-owned integration state survive the identity transition where still applicable.
- No duplicate or stale ChatBird runtime remains after reinstall.
- Historical records and explicit migration compatibility remain truthful and narrowly isolated.
- The prior running-state bug fix remains present and verified.
- Pre-existing unrelated working-tree edits are not lost or accidentally folded into the design-document commit.
