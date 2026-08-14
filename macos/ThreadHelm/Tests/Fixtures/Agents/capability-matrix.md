# ThreadHelm five-agent capability matrix

Captured against baseline `f7cb4843eea3aa5aae9ee6045092c007f7cd9452` on 2026-08-12. This is an owner-only, version-pinned description of the locally installed tools. “Unknown” is deliberate: it means the behavior was not proven end to end on this Mac and must not be advertised.

| Agent | Installed version | Installation discovery | Lifecycle events | Stable identity |
| --- | --- | --- | --- | --- |
| Codex | 0.145.0 | `codex --version`, local process/session state | Existing ThreadHelm reader observes active turns, terminal states, and retained recent sessions | Supported: native thread UUID |
| Claude Code | 2.1.226 | `claude --version`, `claude agents --json` | Agent snapshot, top-level transcript, live process, and existing permission hook | Supported: Claude session ID plus a separately checked live process |
| Cursor | Desktop 3.15.6; Agent CLI 2026.04.14-ee4b43a | Application bundle plus separate desktop and Agent CLI commands | The managed hook adapter normalizes official session/tool/stop signals into the bounded local event store; installed-hook replay remains pending | Candidate `session_id` is documented; resumable identity mapping remains unknown until an end-to-end fixture passes |
| ZCode | 3.7.6 (build 3.7.6.4691) | Application bundle `dev.zcode.app`; bundled CLI exists inside the app | The managed hook adapter observes the documented lifecycle subset without inventing SessionEnd; installed-hook replay remains pending | Unknown; no stable session identity has been proven from this installed version |
| OMP | 17.3.2 | `omp --version`, installed package, bundled extension documentation | The state-only extension adapter observes session, agent, tool, compact, and shutdown events; `agent_end.willContinue` distinguishes continuing from terminal turns; installed-extension replay remains pending | Candidate session ID/path exists in the CLI; exact mapping remains unknown until an end-to-end fixture passes |

## Exact return

| Agent | Result on this Mac |
| --- | --- |
| Codex | A native thread UUID supplies a targeted `codex://threads/<UUID>` deep link, but ThreadHelm currently confirms only dispatch. The result remains Unknown until the destination thread identity is checked independently. |
| Claude Code | Exact only when a matching live process plus process-start identity is located at its exact terminal tab. Launching `claude --resume` remains Unknown until the destination identity is checked independently. |
| Cursor | Unknown. `cursor agent --resume [chatId]` exists, but arbitrary desktop-session mapping is not proven. |
| ZCode | Unknown. The `zcode` URL scheme and bundled CLI do not prove arbitrary-session return. |
| OMP | Unsupported by the state-only adapter. `--resume` and `--session` exist, but ThreadHelm does not call them. |

## Fallback return

| Agent | Result on this Mac |
| --- | --- |
| Codex | Focus the native Codex application; label this as app focus, never exact return. |
| Claude Code | Resume by session when possible, then open the recorded project location in a terminal as an explicitly labeled fallback. |
| Cursor | Open/focus Cursor or open a project location; do not report an arbitrary IDE window as exact. |
| ZCode | Focus ZCode, then use a project-location fallback only when locally available. |
| OMP | Unsupported in the first state-only adapter. ThreadHelm does not focus a terminal, navigate, or call OMP session APIs. |

## Permission / question / plan

| Agent | Result on this Mac |
| --- | --- |
| Codex | A pending `request_user_input` is observable as a question that needs attention; ThreadHelm opens Codex rather than answering it in-app. Generic permission and plan controls are unsupported. |
| Claude Code | Existing ThreadHelm behavior supports a bounded local permission/question/plan queue and the verified in-app response path. |
| Cursor | Native handling only in the first local adapter. Detection of blocked/input states is unknown until an official payload proves it. |
| ZCode | PermissionRequest exists in bundled hook documentation, but the first local adapter intentionally does not register or intercept it. Question/plan semantics are unknown. |
| OMP | Unsupported by ThreadHelm. The first adapter is state-only and must not invoke approval, message, cancellation, navigation, or session-mutation APIs. |

## Quota

| Agent | Result on this Mac |
| --- | --- |
| Codex | Supported by the existing local app-server rate-limit reader. |
| Claude Code | Supported by the existing read-only local usage reader. |
| Cursor | Unsupported in this project scope. |
| ZCode | Unsupported in this project scope. |
| OMP | Unsupported in this project scope. |

## Offline behavior

| Agent | Result on this Mac |
| --- | --- |
| Codex | Existing local snapshot reads do not block Codex. |
| Claude Code | Existing state reads fail independently; the verified native Claude path remains available. |
| Cursor | Isolated runtime self-tests verify that hooks return a valid success response quickly when ThreadHelm is absent and failures remain contained. Replay through the currently installed live hook is still pending. |
| ZCode | Isolated runtime self-tests verify that managed hooks fail open and never prevent ZCode work. Replay through the currently installed live hook is still pending. |
| OMP | Isolated runtime self-tests verify that extension failures are contained and OMP continues normally. Replay through the currently installed live extension is still pending. |

## Freshness

| Agent | Rule |
| --- | --- |
| Codex | Explicit active/terminal state wins. Retained terminal sessions may remain visible for up to 24 hours; an ambiguous non-terminal record becomes stale after the existing 30-minute freshness window. |
| Claude Code | Live process and agents snapshot are strongest; transcript-only state is bounded by existing stale/process checks. |
| Cursor | The shared live store expires active evidence after 5 minutes, idle evidence after 30 minutes, and terminal evidence after 24 hours; installed-hook restart timing remains unverified. |
| ZCode | Stop plus process observation and a documented stale timeout are required because SessionEnd is unavailable in the bundled hook list. |
| OMP | `agent_end` remains running when `willContinue=true`; otherwise it is terminal. Shutdown plus expiry cleans up non-terminal snapshots. |

## Duplicate / out-of-order

| Agent | Rule |
| --- | --- |
| Codex | Native thread UUID is the deduplication identity; terminal state must not regress to an older active snapshot. |
| Claude Code | Session/request identity and FIFO coordinator semantics are authoritative; completed requests must not be resurrected by older transcript data. |
| Cursor | The shared reducer deduplicates by agent plus native session candidate, scopes event IDs to the session, and ignores regressive sequences. |
| ZCode | The shared reducer tolerates repeated hooks and timestamps without inventing a SessionEnd event. |
| OMP | The shared reducer keeps `agent_end.willContinue=true` running, deduplicates repeated terminal `agent_end` events, and ignores regressive sequences. |

## Supported attention

| Agent | Interrupting reasons supported by this truth set | Default non-interrupting results |
| --- | --- | --- |
| Codex | Question requiring user input; task-level failure | Running, ordinary tool failure, completion/review-ready, idle |
| Claude Code | Permission, question, plan approval, task-level failure | Running, ordinary tool failure, completion/review-ready, idle |
| Cursor | Verified task-level failure only; blocked/input remains unknown | Lifecycle churn, ordinary tool failure, completion/review-ready |
| ZCode | Verified task-level failure only in the first adapter | Lifecycle churn, ordinary tool failure, completion/review-ready |
| OMP | Verified terminal `agent_end` task-level failure only; state-only | Lifecycle churn, continuing `agent_end`, ordinary tool failure, completion/review-ready |

## Unsupported or unknown

- Cursor cloud agents are out of scope; Cursor in-app approval and arbitrary IDE-session deep links are not claimed.
- ZCode user CLI configuration was absent at capture time. Its absence does not mean ZCode is uninstalled, and discovery must not create the file.
- ZCode exact return, already-running-session hook pickup, question/plan semantics, and SessionEnd are unknown or unavailable in the observed surface.
- OMP approval, input injection, cancellation, navigation, exact return, and other session mutation are intentionally unsupported.
- No adapter may turn a normal tool failure into a task failure, an app focus into exact success, or an inferred state into official evidence.

This matrix must be revalidated whenever any listed installed version changes.
