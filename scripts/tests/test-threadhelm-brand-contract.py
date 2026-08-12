#!/usr/bin/env python3
"""Static regression checks for the ThreadHelm install transition."""

from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


package_installer = read("macos/package/安装ThreadHelm.command")
package_checker = read("macos/package/检查ThreadHelm.command")
package_uninstaller = read("macos/package/卸载ThreadHelm.command")
source_installer = read("macos/ThreadHelm/scripts/install.sh")
source_uninstaller = read("macos/ThreadHelm/scripts/uninstall.sh")

for installer in (package_installer, source_installer):
    for required in (
        "dev.threadhelm.app",
        "dev.chatbird.app",
        "dev.chatbird.codex-quota-panel",
        "ThreadHelm.app",
        "ChatBird.app",
        "ThreadHelm",
        "ChatBirdQuotaPanel",
        "threadhelm-native-notification-backup.json",
        "chatbird-native-notification-backup.json",
        "cleanup_legacy_products",
    ):
        assert required in installer, (required, installer[:200])

    health_marker = (
        "wait_for_panel_health" if "wait_for_panel_health" in installer
        else "claudeQuotaPeriods"
    )
    assert installer.rindex(health_marker) < installer.rindex(
        "cleanup_legacy_products"
    ), "legacy cleanup must happen only after ThreadHelm health verification"

for required in (
    'LEGACY_LABEL="dev.chatbird.app"',
    'OLDER_LEGACY_LABEL="dev.chatbird.codex-quota-panel"',
    'LEGACY_APP="$HOME/Applications/ChatBird.app"',
    'ChatBirdQuotaPanel',
    "legacy-app",
    "legacy-launch-agent",
    "legacy-process",
):
    assert required in package_checker, required

for uninstaller in (package_uninstaller, source_uninstaller):
    for required in (
        "ThreadHelm.app",
        "ChatBird.app",
        "ChatBird 额度面板.app",
        "dev.threadhelm.app",
        "dev.chatbird.app",
        "dev.chatbird.codex-quota-panel",
        "threadhelm-native-notification-backup.json",
        "chatbird-native-notification-backup.json",
    ):
        assert required in uninstaller, required

print("ThreadHelm install transition contract tests passed")
