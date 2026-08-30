#!/usr/bin/env python3
"""Validate the owner-only five-agent truth fixture contract."""

from __future__ import annotations

import json
import re
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FIXTURE_ROOT = ROOT / "macos/ThreadHelm/Tests/Fixtures/Agents"
SCENARIO_ROOT = FIXTURE_ROOT / "scenarios"
AGENTS = ("codex", "claudeCode", "cursor", "zcode", "omp")
BASELINE_COMMIT = "8a0792ded390272977e4183ee8596bfbf0633f68"
PREVIEW_STATES = (
    "capsule-confirmation",
    "capsule-running",
    "capsule-waiting",
    "capsule-completed",
    "capsule-failed",
    "capsule-idle",
    "capsule-codex-exited",
    "tasks",
    "confirm-tool",
    "confirm-question",
    "confirm-plan",
    "quota-codex",
    "quota-claude",
    "quota-refreshing",
    "quota-loading",
    "quota-stale",
    "quota-first-failure",
    "quota-unavailable",
)
EXPECTED_SCENARIO_COUNTS = {
    "codex": 16,
    "claudeCode": 17,
    "cursor": 16,
    "zcode": 16,
    "omp": 16,
}

EXPECTED_ENUMS = {
    "executionState": {
        "discovering", "idle", "running", "completed", "failed",
        "stale", "offline", "unknown",
    },
    "attentionReason": {
        "permission", "question", "planApproval", "blocked",
        "reviewReady", "taskFailure", "none", "unknown",
    },
    "actionability": {
        "inApp", "openExactNativeSession", "openNativeApp",
        "openWorkingDirectory", "viewOnly", "unknown",
    },
    "evidenceQuality": {
        "officialHook", "officialAPI", "nativeState", "transcript",
        "processObservation", "inferred", "unknown",
    },
    "freshness": {"fresh", "stale", "notApplicable", "unknown"},
    "openResult": {
        "exactSession", "appFocused", "workingDirectoryFallback",
        "unavailable", "failed", "notAttempted", "unknown",
    },
    "interruptDecision": {"interrupt", "nonInterrupt"},
}

FORBIDDEN_TEXT = (
    "/" + "Users/",
    "junwenlu",
    "authorization:",
    "bearer ",
    "gho_",
    "BEGIN PRIVATE KEY",
)
FORBIDDEN_PATTERNS = (
    (re.compile(r"(?i)(?:^|[^a-z0-9])sk-[a-z0-9_-]{8,}"), "secret-key-shaped value"),
)
FORBIDDEN_KEYS = {
    "prompt", "rawPrompt", "hiddenReasoning", "toolArguments",
    "toolOutput", "commandOutput", "workingDirectory", "secret", "token",
}
REQUIRED_REDACTIONS = {
    "rawPrompt", "hiddenReasoning", "fullToolArguments", "toolOutput",
    "secrets", "personalPaths",
}


def load_json(path: Path) -> object:
    assert path.is_file(), f"missing truth artifact: {path.relative_to(ROOT)}"
    return json.loads(path.read_text(encoding="utf-8"))


def walk_keys(value: object) -> set[str]:
    if isinstance(value, dict):
        result = set(value)
        for child in value.values():
            result.update(walk_keys(child))
        return result
    if isinstance(value, list):
        result: set[str] = set()
        for child in value:
            result.update(walk_keys(child))
        return result
    return set()


index = load_json(FIXTURE_ROOT / "index.json")
versions = load_json(FIXTURE_ROOT / "versions.json")
previews = load_json(FIXTURE_ROOT / "baseline-previews.json")
matrix_path = FIXTURE_ROOT / "capability-matrix.md"
spec_path = ROOT / "docs/superpowers/specs/2026-08-12-threadhelm-truth-spec.md"

assert isinstance(index, dict)
assert index["schemaVersion"] == 1
assert index["baselineCommit"] == BASELINE_COMMIT
assert tuple(index["agents"]) == AGENTS
assert set(index["scenarioFiles"]) == set(AGENTS)

assert isinstance(versions, dict)
assert versions["schemaVersion"] == 1
assert versions["baselineCommit"] == BASELINE_COMMIT
assert set(versions["agents"]) == set(AGENTS)
for agent_id, record in versions["agents"].items():
    assert record["agentId"] == agent_id
    assert isinstance(record["version"], str) and record["version"]
    assert record["revalidateOnVersionChange"] is True
    assert record["discovery"]["status"] in {"installed", "unknown"}
    assert record["evidence"]["kind"] in {
        "localCommand", "bundleMetadata", "localObservation",
    }

all_scenarios: list[dict[str, object]] = []
scenario_ids: set[str] = set()
per_agent_counts: Counter[str] = Counter()
per_agent_interrupts: Counter[str] = Counter()
per_agent_negatives: Counter[str] = Counter()

for agent_id in AGENTS:
    relative_path = Path(index["scenarioFiles"][agent_id])
    document = load_json(FIXTURE_ROOT / relative_path)
    assert isinstance(document, dict)
    assert document["schemaVersion"] == 1
    assert document["agentId"] == agent_id
    assert document["observedAgentVersion"] == versions["agents"][agent_id]["version"]
    assert document["baselineCommit"] == BASELINE_COMMIT
    assert document["redaction"]["status"] == "redacted"
    assert set(document["redaction"]["excluded"]) >= REQUIRED_REDACTIONS
    assert isinstance(document["scenarios"], list)

    serialized = json.dumps(document, ensure_ascii=False)
    lowered = serialized.lower()
    for forbidden in FORBIDDEN_TEXT:
        assert forbidden.lower() not in lowered, (
            f"{relative_path} contains forbidden private text: {forbidden}"
        )
    for pattern, description in FORBIDDEN_PATTERNS:
        assert pattern.search(serialized) is None, (
            f"{relative_path} contains forbidden private text: {description}"
        )
    assert not (walk_keys(document) & FORBIDDEN_KEYS), (
        f"{relative_path} contains forbidden raw-data keys: "
        f"{sorted(walk_keys(document) & FORBIDDEN_KEYS)}"
    )

    for scenario in document["scenarios"]:
        assert scenario["agentId"] == agent_id
        assert scenario["id"] not in scenario_ids
        scenario_ids.add(scenario["id"])
        assert scenario["capabilityStatus"] in {
            "supported", "unsupported", "unknown",
        }
        assert isinstance(scenario["scenario"], str) and scenario["scenario"]
        assert isinstance(scenario["captureSource"], str) and scenario["captureSource"]
        assert isinstance(scenario["capturedAt"], str) and scenario["capturedAt"].endswith("Z")
        assert scenario["observedAgentVersion"] == document["observedAgentVersion"]
        assert scenario["input"]["redacted"] is True
        assert isinstance(scenario["input"]["signal"], str)
        assert isinstance(scenario["expected"], dict)
        for field, allowed in EXPECTED_ENUMS.items():
            assert scenario["expected"][field] in allowed, (
                f"{scenario['id']} has invalid {field}"
            )
        assert isinstance(scenario["evidence"], list) and scenario["evidence"]
        assert all(
            item["kind"] in {
                "localCode", "executableSelfTest", "officialDocumentation",
                "bundledDocumentation", "localObservation", "syntheticPolicy",
            }
            and isinstance(item["reference"], str)
            and item["reference"]
            for item in scenario["evidence"]
        )
        evidence_kinds = {item["kind"] for item in scenario["evidence"]}
        if evidence_kinds == {"syntheticPolicy"}:
            assert scenario["expected"]["evidenceQuality"] in {
                "inferred", "unknown",
            }, f"{scenario['id']} overstates synthetic evidence quality"
        if agent_id == "omp":
            assert scenario["expected"]["actionability"] not in {
                "inApp", "openNativeApp", "openWorkingDirectory",
            }, f"{scenario['id']} violates the OMP resume-only boundary"
            assert scenario["expected"]["openResult"] not in {
                "exactSession", "appFocused", "workingDirectoryFallback",
            }, f"{scenario['id']} overstates OMP resume navigation"
        if agent_id in {"codex", "cursor", "zcode", "omp"}:
            assert scenario["expected"]["openResult"] != "exactSession", (
                f"{scenario['id']} lacks independent exact-return confirmation"
            )
        if scenario["expected"]["openResult"] == "exactSession":
            assert scenario["expected"]["actionability"] == (
                "openExactNativeSession"
            ), f"{scenario['id']} reports exact without an exact target"
        assert isinstance(scenario["explicitUnknowns"], list)

        per_agent_counts[agent_id] += 1
        if scenario["expected"]["interruptDecision"] == "interrupt":
            per_agent_interrupts[agent_id] += 1
        else:
            per_agent_negatives[agent_id] += 1
        all_scenarios.append(scenario)

assert len(all_scenarios) == 81
for agent_id in AGENTS:
    assert per_agent_counts[agent_id] == EXPECTED_SCENARIO_COUNTS[agent_id]
    assert per_agent_interrupts[agent_id] >= 5
    assert per_agent_negatives[agent_id] >= 5
assert index["counts"]["total"] == len(all_scenarios)
assert index["counts"]["byAgent"] == dict(per_agent_counts)
assert index["counts"]["byAgent"] == EXPECTED_SCENARIO_COUNTS

assert isinstance(previews, dict)
assert previews["schemaVersion"] == 1
assert previews["baselineCommit"] == BASELINE_COMMIT
assert previews["threadHelmVersion"] == "1.1.0"
assert previews["renderScale"] == 2
assert tuple(item["state"] for item in previews["previews"]) == PREVIEW_STATES
assert len({item["sha256"] for item in previews["previews"]}) == len(PREVIEW_STATES)
for item in previews["previews"]:
    assert re.fullmatch(r"[0-9a-f]{64}", item["sha256"])
    if item["state"].startswith("capsule-"):
        assert (item["pixelWidth"], item["pixelHeight"]) == (808, 116)
    elif item["state"] == "tasks":
        assert (item["pixelWidth"], item["pixelHeight"]) == (1640, 1120)
    elif item["state"].startswith("confirm-"):
        assert (item["pixelWidth"], item["pixelHeight"]) == (1640, 1200)
    else:
        assert (item["pixelWidth"], item["pixelHeight"]) == (1640, 940)

readme = (ROOT / "macos/ThreadHelm/README.md").read_text(encoding="utf-8")
documented_states = re.search(
    r"支持的 `state` 固定为：\s*```text\n(.*?)\n```",
    readme,
    re.DOTALL,
)
assert documented_states is not None
assert tuple(documented_states.group(1).splitlines()) == PREVIEW_STATES

matrix = matrix_path.read_text(encoding="utf-8")
for agent_id in AGENTS:
    assert versions["agents"][agent_id]["displayName"] in matrix
    assert versions["agents"][agent_id]["version"] in matrix
for heading in (
    "Installation discovery", "Lifecycle events", "Stable identity",
    "Exact return", "Fallback return", "Permission / question / plan",
    "Quota", "Offline behavior", "Freshness", "Duplicate / out-of-order",
    "Supported attention", "Unsupported or unknown",
):
    assert heading in matrix
for stale_claim in (
    "the current ThreadHelm runtime has no Cursor reader yet",
    "the future adapter must expose",
    "Future reducer must",
):
    assert stale_claim not in matrix, (
        f"capability matrix still describes pre-implementation state: {stale_claim}"
    )

spec = spec_path.read_text(encoding="utf-8")
for term in (
    "hard-attention opportunity", "miss", "false alert", "duplicate",
    "exact-return attempt", "exact success", "Replay contract",
    "Redaction contract",
):
    assert term in spec

print(
    "five-agent truth fixtures passed: "
    f"agents={len(AGENTS)} scenarios={len(all_scenarios)} "
    f"previews={len(PREVIEW_STATES)}"
)
