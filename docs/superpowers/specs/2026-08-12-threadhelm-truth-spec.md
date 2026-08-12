# ThreadHelm five-agent truth specification

Date: 2026-08-12

Scope: one owner, one Mac, five pinned local agent versions

Baseline: `f7cb4843eea3aa5aae9ee6045092c007f7cd9452`

## Purpose

The fixture package is the source of truth for normalizing Codex, Claude Code, Cursor, ZCode, and Pi. It records what was observed, what ThreadHelm should show, and what remains unsupported or unknown. It is not permission to install integrations or mutate live agent configuration.

## Replay contract

1. Read `index.json`, verify the schema and baseline, then load `versions.json` and each file named by `scenarioFiles`.
2. Refuse to treat an adapter as validated when its observed version differs from the pinned version until its scenarios have been captured and reviewed again.
3. For each scenario, feed only the redacted `input.signal` classification to the future adapter/reducer. Compare all fields in `expected`; do not infer a missing field.
4. Preserve event identity, ordering metadata, and capture-source class where the native surface supplies them. Replays of duplicate or out-of-order scenarios must be deterministic.
5. `capabilityStatus=unsupported` means no UI control or success claim may be exposed. `capabilityStatus=unknown` must remain visibly unknown and cannot be promoted by inference.
6. An `openResult` is an expected classification, not proof that a launch occurred during fixture replay. Exact return requires a separate independent identity check.
7. A fixture joins the accepted truth set only after its expected label is reviewed separately from capture. Synthetic policy cases are allowed for destructive or rare failures but must identify that evidence class.

## Redaction contract

Fixtures contain classifications and bounded metadata only. They exclude raw user requests, hidden reasoning, full tool arguments, tool and command output, secrets, credentials, and personal filesystem paths. Session/thread values are synthetic labels unless a non-sensitive native identifier is required for a deterministic local test.

Redaction happens before a fixture is written. A later log scrubber is not an acceptable substitute. Evidence references name source files, commands, or bundled documentation without copying sensitive payloads. The validator rejects known private-path and credential patterns as a second line of defense.

The same rule applies to future hook transport and diagnostics: only allowlisted fields may leave the hook/extension process, and diagnostics must never record titles, request text, commands, output, or raw project paths.

## State and attention rules

- Execution state and attention reason are independent. `idle` never means “needs input.”
- An ordinary tool failure is not a task failure.
- Completion is `reviewReady` and non-interrupting by default.
- A terminal failure is `taskFailure` and interrupting.
- A stale or inferred snapshot must say so; it cannot silently override fresher official/native evidence.
- For Pi, `agent_end` alone is not completion because retry or compaction may follow. `agent_settled`, shutdown, or a documented expiry is needed.
- For ZCode, the lack of SessionEnd requires Stop/process/expiry reconciliation; no synthetic SessionEnd may be invented.
- A missing native identity changes actionability and return quality, not necessarily the observed task state.

## Measurement definitions

A **hard-attention opportunity** is a truth-labeled supported transition for permission, question, plan approval, verified blocked state, or task-level failure. Unsupported capabilities do not enter that adapter’s denominator.

A **miss** is a hard-attention opportunity with no matching visible attention item before the adapter’s documented freshness deadline.

A **false alert** is an interrupting item or notification with no matching hard-attention opportunity in the truth set.

A **duplicate** is a second visible item or notification for the same agent, native session identity, and reason while the first remains unresolved or within the 60-second merge window.

An **exact-return attempt** begins only when ThreadHelm advertises and invokes an exact native session/thread/run target. Opening an application, terminal, or project location does not count as an exact-return attempt.

An **exact success** requires independent confirmation that the destination carries the same native identity. App focus, a generic terminal, or a project-location fallback is never exact success.

Report per adapter with raw numerator, denominator, tested version, and collection window:

```text
miss_rate = misses / hard-attention opportunities
false_alert_rate = false alerts / negative no-interrupt truth decisions
duplicate_rate = duplicate visible attention items / all visible attention items
exact_return_success_rate = independently confirmed exact successes / exact-return attempts
```

Aggregate five-agent numbers are supplementary and cannot hide a weak adapter.

## Capability and return contract

Actionability is one of in-app action, exact native return, native app focus, project-location fallback, or view-only. The future UI must announce which class is available. If a stronger path fails, the returned result changes to the actual fallback class; it must not preserve an earlier success label.

Only Claude Code has a verified in-app permission/question/plan response path in this baseline. Codex opens its native thread for input. Cursor and ZCode remain native-surface-only in the first adapter. Pi is strictly state-only and cannot call approval, message injection, cancellation, navigation, or session-mutation APIs.

## Version and configuration boundary

These truth labels apply only to Codex 0.145.0, Claude Code 2.1.226, Cursor 3.15.6, ZCode 3.7.6 (build 3.7.6.4691), and Pi 0.84.1 on the captured Mac. Discovery is read-only. In particular, it must not create the absent ZCode user CLI configuration or edit existing Claude, Cursor, or Pi integration files.
