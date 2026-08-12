#!/usr/bin/env python3
"""Validate the tracked ThreadHelm product and release boundaries."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DIST_ARCHIVE = re.compile(
    r"^dist/ThreadHelm-macOS-arm64-\d+\.\d+\.\d+\.zip$"
)
ALLOWED_TOP_LEVEL = {
    ".gitattributes",
    ".github",
    ".gitignore",
    "ASSET-NOTICE.md",
    "LICENSE",
    "PRIVACY.md",
    "README.md",
    "dist",
    "docs",
    "macos",
    "script",
    "scripts",
}
ALLOWED_MACOS_PATHS = {
    "macos/README.md",
    "macos/VERSION.txt",
}
ALLOWED_MACOS_PREFIXES = (
    "macos/ThreadHelm/",
    "macos/package/",
)
ALLOWED_SCRIPT_PATHS = {
    "script/build_and_run.sh",
    "scripts/build-macos-release.sh",
    "scripts/privacy-audit.sh",
    "scripts/update-readme-downloads.sh",
    "scripts/validate-repository-layout.py",
}
ALLOWED_SCRIPT_PREFIXES = (
    "scripts/tests/",
)
FORBIDDEN_PATH_MARKERS = (
    "bubu",
    "chatbird",
    "mayday",
    "orange",
    "windows",
    "卜卜",
)
FORBIDDEN_TEXT = re.compile(
    r"mayday|bubu|卜卜|binance|\bbitcoin\b|\bbtc\b|codex-only|"
    r"jingjing-nx|io\.github\.mayday-materials",
    re.IGNORECASE,
)
CONTENT_SCAN_EXCLUDED_PATHS = {
    "scripts/validate-repository-layout.py",
}
CONTENT_SCAN_EXCLUDED_PREFIXES = (
    "scripts/tests/",
)
HISTORICAL_DOCUMENT_PREFIXES = (
    "docs/superpowers/plans/",
    "docs/superpowers/specs/",
)
LEGACY_BRAND = re.compile(r"chatbird", re.IGNORECASE)
LEGACY_BRAND_COMPATIBILITY_FILES = {
    "macos/ThreadHelm/Sources/ThreadHelm/ClaudeHookSupport.swift",
    "macos/ThreadHelm/Sources/ThreadHelm/LifecycleSelfTest.swift",
    "macos/ThreadHelm/Sources/ThreadHelm/QuotaSelfTests.swift",
    "macos/ThreadHelm/Sources/ThreadHelm/TaskProgressSelfTestPhase2.swift",
    "macos/ThreadHelm/Sources/ThreadHelm/ThreadHelmApplicationIdentity.swift",
    "macos/ThreadHelm/scripts/build.sh",
    "macos/ThreadHelm/scripts/install.sh",
    "macos/ThreadHelm/scripts/uninstall.sh",
    "macos/package/卸载ThreadHelm.command",
    "macos/package/安装ThreadHelm.command",
    "macos/package/检查ThreadHelm.command",
    "scripts/tests/test-layout-validator.py",
    "scripts/tests/test-threadhelm-brand-contract.py",
    "scripts/validate-repository-layout.py",
}
LEGACY_BRAND_LINE_ALLOWLIST = {
    "PRIVACY.md": (
        re.compile(r"`custom:chatbird-nt`", re.IGNORECASE),
    ),
    "scripts/build-macos-release.sh": (
        re.compile(r"markers=\(chatbird\b", re.IGNORECASE),
        re.compile(r'"\$marker" == "chatbird"', re.IGNORECASE),
        re.compile(r'"\$component" == chatbird\*', re.IGNORECASE),
    ),
    "scripts/privacy-audit.sh": (
        re.compile(
            r"docs/superpowers/plans/2026-08-12-remove-chatbird-pet\.md",
            re.IGNORECASE,
        ),
    ),
}
REQUIRED_FILES = {
    "macos/ThreadHelm/Resources/Info.plist",
    "macos/ThreadHelm/Resources/ThreadHelm.entitlements",
    "macos/ThreadHelm/Resources/dev.threadhelm.app.plist.in",
    "macos/ThreadHelm/Sources/ThreadHelm/main.swift",
    "macos/ThreadHelm/scripts/build.sh",
    "macos/package/卸载ThreadHelm.command",
    "macos/package/安装ThreadHelm.command",
    "macos/package/检查ThreadHelm.command",
}


def tracked_files() -> set[str]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=ROOT,
        check=True,
        stdout=subprocess.PIPE,
    )
    paths = {
        raw.decode("utf-8", errors="surrogateescape")
        for raw in result.stdout.split(b"\0")
        if raw
    }
    return {path for path in paths if (ROOT / path).exists()}


def path_has_forbidden_marker(path: str) -> bool:
    """Match legacy path markers as components or separator-delimited tokens."""
    for component in path.casefold().split("/"):
        tokens = [token for token in re.split(r"[^0-9a-z]+", component) if token]
        for marker in FORBIDDEN_PATH_MARKERS:
            folded_marker = marker.casefold()
            if (
                component == folded_marker
                or folded_marker in tokens
                or (folded_marker == "chatbird" and component.startswith(folded_marker))
            ):
                return True
    return False


def is_historical_document(path: str) -> bool:
    return path.startswith(HISTORICAL_DOCUMENT_PREFIXES)


def legacy_brand_violation(path: str, text: str) -> tuple[int, str] | None:
    """Return the first unapproved legacy-brand occurrence in current text."""
    if is_historical_document(path) or path in LEGACY_BRAND_COMPATIBILITY_FILES:
        return None

    allowed_patterns = LEGACY_BRAND_LINE_ALLOWLIST.get(path, ())
    for line_number, line in enumerate(text.splitlines(), start=1):
        candidate = line
        for pattern in allowed_patterns:
            candidate = pattern.sub("", candidate)
        match = LEGACY_BRAND.search(candidate)
        if match is not None:
            return line_number, match.group(0)
    return None


def validate(paths: set[str]) -> list[str]:
    violations: list[str] = []

    for path in sorted(paths):
        top_level = path.split("/", maxsplit=1)[0]
        if top_level not in ALLOWED_TOP_LEVEL:
            violations.append(f"{path}: unexpected top-level repository content")

        if path.startswith("macos/") and (
            path not in ALLOWED_MACOS_PATHS
            and not path.startswith(ALLOWED_MACOS_PREFIXES)
        ):
            violations.append(f"{path}: unexpected macOS product path")

        if (
            path.startswith(("script/", "scripts/"))
            and path not in ALLOWED_SCRIPT_PATHS
            and not path.startswith(ALLOWED_SCRIPT_PREFIXES)
        ):
            violations.append(f"{path}: unexpected repository script")

        if path.startswith("macos/ThreadHelm/Resources/Airplane/"):
            violations.append(f"{path}: unused legacy resource is forbidden")

        if path_has_forbidden_marker(path) and not is_historical_document(path):
            violations.append(f"{path}: legacy product name is forbidden in tracked paths")

        if path.startswith("dist/"):
            if path.endswith(".zip"):
                if not DIST_ARCHIVE.fullmatch(path):
                    violations.append(f"{path}: unexpected release archive")
            elif path.endswith(".zip.sha256"):
                archive = path.removesuffix(".sha256")
                if not DIST_ARCHIVE.fullmatch(archive):
                    violations.append(f"{path}: unexpected release checksum")
            else:
                violations.append(f"{path}: unexpected file in dist")

        file_path = ROOT / path
        if file_path.is_file():
            data = file_path.read_bytes()
            if b"\0" not in data:
                try:
                    text = data.decode("utf-8")
                except UnicodeDecodeError:
                    text = ""

                brand_violation = legacy_brand_violation(path, text)
                if brand_violation is not None:
                    line_number, legacy_name = brand_violation
                    violations.append(
                        f"{path}:{line_number}: legacy product brand is forbidden "
                        f"({legacy_name})"
                    )

                if (
                    path not in CONTENT_SCAN_EXCLUDED_PATHS
                    and not path.startswith(CONTENT_SCAN_EXCLUDED_PREFIXES)
                ):
                    for line_number, line in enumerate(text.splitlines(), start=1):
                        match = FORBIDDEN_TEXT.search(line)
                        if match is None:
                            continue
                        if (
                            path == "scripts/build-macos-release.sh"
                            and ("local forbidden" in line or "markers=(" in line)
                        ):
                            continue
                        violations.append(
                            f"{path}:{line_number}: legacy product text is forbidden "
                            f"({match.group(0)})"
                        )
                        break

    missing = sorted(REQUIRED_FILES - paths)
    violations.extend(f"{path}: required ThreadHelm source is missing" for path in missing)

    archives = sorted(path for path in paths if path.startswith("dist/") and path.endswith(".zip"))
    checksums = sorted(
        path for path in paths if path.startswith("dist/") and path.endswith(".zip.sha256")
    )
    if len(archives) != 1:
        violations.append(f"dist: expected exactly one ThreadHelm archive, found {len(archives)}")
    if len(checksums) != 1:
        violations.append(f"dist: expected exactly one ThreadHelm checksum, found {len(checksums)}")
    if len(archives) == 1 and checksums != [f"{archives[0]}.sha256"]:
        violations.append("dist: checksum must match the single ThreadHelm archive")

    return violations


def main() -> int:
    violations = validate(tracked_files())
    if violations:
        print("repository layout validation failed:", file=sys.stderr)
        for violation in violations:
            print(f"- {violation}", file=sys.stderr)
        return 1

    print("repository layout validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
