#!/usr/bin/env python3
"""Regression tests for repository layout path marker matching."""

from __future__ import annotations

import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VALIDATOR_PATH = ROOT / "scripts" / "validate-repository-layout.py"


spec = importlib.util.spec_from_file_location("validate_repository_layout", VALIDATOR_PATH)
assert spec is not None and spec.loader is not None
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


def base_paths() -> set[str]:
    return set(validator.REQUIRED_FILES) | {
        ".gitattributes",
        ".gitignore",
        "ASSET-NOTICE.md",
        "LICENSE",
        "PRIVACY.md",
        "README.md",
        "macos/README.md",
        "macos/VERSION.txt",
        "scripts/build-macos-release.sh",
        "scripts/privacy-audit.sh",
        "scripts/update-readme-downloads.sh",
        "scripts/validate-repository-layout.py",
        "dist/ThreadHelm-macOS-arm64-1.1.0.zip",
        "dist/ThreadHelm-macOS-arm64-1.1.0.zip.sha256",
    }


def assert_no_legacy_path(paths: set[str]) -> None:
    violations = validator.validate(paths)
    legacy_path_violations = [
        violation for violation in violations
        if "legacy product name is forbidden in tracked paths" in violation
    ]
    assert legacy_path_violations == [], legacy_path_violations


def assert_legacy_path(path: str) -> None:
    violations = validator.validate(base_paths() | {path})
    assert any(
        violation.startswith(f"{path}:")
        and "legacy product name is forbidden in tracked paths" in violation
        for violation in violations
    ), violations


assert_no_legacy_path(
    base_paths()
    | {
        "macos/ThreadHelm/Sources/ThreadHelm/WindowStackGeometry.swift",
        "docs/superpowers/specs/2026-07-25-chatbird-live-task-panel-design.md",
    }
)
assert_legacy_path("macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/main.swift")
assert_legacy_path("macos/package/Windows/legacy.txt")
assert_legacy_path("shared/pet/chatbird-nt/Bubu/legacy.txt")
shared_violations = validator.validate(
    base_paths() | {"shared/pet/chatbird-nt/pet.json"}
)
assert any(
    violation.startswith("shared/pet/chatbird-nt/pet.json:")
    and "unexpected top-level repository content" in violation
    for violation in shared_violations
), shared_violations

assert validator.legacy_brand_violation(
    "macos/ThreadHelm/Sources/ThreadHelm/main.swift",
    'print("ChatBird 活动")',
) is not None
assert validator.legacy_brand_violation(
    "macos/ThreadHelm/Sources/ThreadHelm/ThreadHelmApplicationIdentity.swift",
    'let legacyBundleID = "dev.chatbird.app"',
) is None
assert validator.legacy_brand_violation(
    "docs/superpowers/specs/2026-07-25-chatbird-live-task-panel-design.md",
    "# ChatBird live task panel",
) is None

print("layout validator path marker tests passed")
