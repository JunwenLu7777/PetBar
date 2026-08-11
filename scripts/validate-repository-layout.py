#!/usr/bin/env python3
"""Validate that the tracked repository contains only the ChatBird macOS product."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DIST_ARCHIVE = re.compile(
    r"^dist/ChatBird(?:-NT)?-macOS-arm64-\d+\.\d+\.\d+\.zip$"
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
    "shared",
}
ALLOWED_MACOS_PATHS = {
    "macos/README.md",
    "macos/VERSION.txt",
}
ALLOWED_MACOS_PREFIXES = (
    "macos/ChatBirdQuotaPanel/",
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
ALLOWED_SHARED_PREFIXES = (
    "shared/pet/chatbird-nt/",
    "shared/preview/chatbird-nt/",
)
FORBIDDEN_PATH_MARKERS = (
    "bubu",
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
REQUIRED_FILES = {
    "macos/ChatBirdQuotaPanel/Resources/ChatBirdQuotaPanel.entitlements",
    "macos/ChatBirdQuotaPanel/Resources/Info.plist",
    "macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/main.swift",
    "macos/ChatBirdQuotaPanel/scripts/build.sh",
    "shared/pet/chatbird-nt/pet.json",
    "shared/pet/chatbird-nt/spritesheet.webp",
    "shared/preview/chatbird-nt/panel-preview.png",
}


def tracked_files() -> set[str]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=ROOT,
        check=True,
        stdout=subprocess.PIPE,
    )
    return {
        raw.decode("utf-8", errors="surrogateescape")
        for raw in result.stdout.split(b"\0")
        if raw
    }


def path_has_forbidden_marker(path: str) -> bool:
    """Match legacy path markers as components or separator-delimited tokens."""
    for component in path.casefold().split("/"):
        tokens = [token for token in re.split(r"[^0-9a-z]+", component) if token]
        for marker in FORBIDDEN_PATH_MARKERS:
            folded_marker = marker.casefold()
            if component == folded_marker or folded_marker in tokens:
                return True
    return False


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

        if path.startswith("shared/") and not path.startswith(ALLOWED_SHARED_PREFIXES):
            violations.append(f"{path}: unexpected shared product content")

        if path.startswith("macos/ChatBirdQuotaPanel/Resources/Airplane/"):
            violations.append(f"{path}: unused legacy resource is forbidden")

        if path_has_forbidden_marker(path):
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

        if (
            path not in CONTENT_SCAN_EXCLUDED_PATHS
            and not path.startswith(CONTENT_SCAN_EXCLUDED_PREFIXES)
        ):
            file_path = ROOT / path
            if file_path.is_file():
                data = file_path.read_bytes()
                if b"\0" not in data:
                    try:
                        text = data.decode("utf-8")
                    except UnicodeDecodeError:
                        text = ""
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
    violations.extend(f"{path}: required ChatBird source is missing" for path in missing)

    archives = sorted(path for path in paths if path.startswith("dist/") and path.endswith(".zip"))
    checksums = sorted(
        path for path in paths if path.startswith("dist/") and path.endswith(".zip.sha256")
    )
    if len(archives) != 1:
        violations.append(f"dist: expected exactly one ChatBird archive, found {len(archives)}")
    if len(checksums) != 1:
        violations.append(f"dist: expected exactly one ChatBird checksum, found {len(checksums)}")
    if len(archives) == 1 and checksums != [f"{archives[0]}.sha256"]:
        violations.append("dist: checksum must match the single ChatBird archive")

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
