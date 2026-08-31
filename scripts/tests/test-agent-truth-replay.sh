#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h:h}"
BINARY="${THREADHELM_TRUTH_REPLAY_BINARY:-$ROOT/macos/ThreadHelm/build/ThreadHelm.app/Contents/MacOS/ThreadHelm}"
SOURCE_FIXTURES="$ROOT/macos/ThreadHelm/Tests/Fixtures/Agents"
TEST_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/threadhelm-truth-replay-test.XXXXXX")"
STDOUT_PATH="$TEST_ROOT/replay.out"
STDERR_PATH="$TEST_ROOT/replay.err"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT

fail() {
  /bin/echo "test failure: $1" >&2
  exit 1
}

run_replay() {
  "$BINARY" --verify-agent-truth "$1" >"$STDOUT_PATH" 2>"$STDERR_PATH"
}

fresh_fixture_copy() {
  local name="$1"
  local target="$TEST_ROOT/$name"
  /usr/bin/ditto "$SOURCE_FIXTURES" "$target"
  print -r -- "$target"
}

mutate_fixture() {
  local fixture_root="$1"
  local mutation="$2"
  /usr/bin/python3 - "$fixture_root" "$mutation" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
mutation = sys.argv[2]


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def save(path: Path, value: dict) -> None:
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


index_path = root / "index.json"
versions_path = root / "versions.json"
codex_path = root / "scenarios/codex.json"
cursor_path = root / "scenarios/cursor.json"

if mutation == "index-baseline":
    value = load(index_path)
    value["baselineCommit"] = "0" * 40
    save(index_path, value)
elif mutation == "versions-baseline":
    value = load(versions_path)
    value["baselineCommit"] = "0" * 40
    save(versions_path, value)
elif mutation == "scenario-baseline":
    value = load(codex_path)
    value["baselineCommit"] = "0" * 40
    save(codex_path, value)
elif mutation == "duplicate-scenario-id":
    codex = load(codex_path)
    cursor = load(cursor_path)
    cursor["scenarios"][0]["id"] = codex["scenarios"][0]["id"]
    save(cursor_path, cursor)
elif mutation == "empty-capture-source":
    value = load(codex_path)
    value["scenarios"][0]["captureSource"] = ""
    save(codex_path, value)
elif mutation == "invalid-evidence-class":
    value = load(codex_path)
    value["scenarios"][0]["evidence"][0]["kind"] = "inventedEvidence"
    save(codex_path, value)
else:
    raise SystemExit(f"unknown mutation: {mutation}")
PY
}

expect_reject() {
  local mutation="$1"
  local fixture_root
  fixture_root="$(fresh_fixture_copy "$mutation")"
  mutate_fixture "$fixture_root" "$mutation"
  if run_replay "$fixture_root"; then
    fail "$mutation fixture unexpectedly passed production replay"
  fi
  [[ -s "$STDERR_PATH" ]] || fail "$mutation rejection did not explain the failure"
}

[[ -x "$BINARY" ]] || fail "missing built ThreadHelm binary: $BINARY"

valid_root="$(fresh_fixture_copy valid)"
run_replay "$valid_root" || {
  /bin/cat "$STDERR_PATH" >&2 || true
  fail "valid truth fixture failed production replay"
}
/usr/bin/grep -q \
  'agent-truth-replay: agents=6 scenarios=98 persistent-state=unchanged' \
  "$STDOUT_PATH" || fail "valid truth replay summary is incomplete"

for mutation in \
  index-baseline \
  versions-baseline \
  scenario-baseline \
  duplicate-scenario-id \
  empty-capture-source \
  invalid-evidence-class
do
  expect_reject "$mutation"
done

/bin/echo "agent truth production replay integrity tests passed"
