# ThreadHelm six-agent capability matrix

Captured against baseline `f7cb4843eea3aa5aae9ee6045092c007f7cd9452` on 2026-08-12. This is an owner-only, version-pinned description of the locally installed tools. “Unknown” is deliberate: it means the behavior was not proven end to end on this Mac and must not be advertised.

| Agent | Installed version | Installation discovery | Lifecycle events | Stable identity |
| --- | --- | --- | --- | --- |
| Codex | 0.150.1 | `codex --version`, local process/session state | Existing ThreadHelm reader observes active turns, terminal states, and retained recent sessions | Supported: native thread UUID |
| Claude Code | 2.1.226 | `claude --version`, `claude agents --json` | Agent snapshot, top-level transcript, live process, and existing permission hook | Supported: Claude session ID plus a separately checked live process |
| Cursor | Desktop 3.17.21; Agent CLI 2026.04.14-ee4b43a | Application bundle plus separate desktop and Agent CLI commands | The managed hook adapter normalizes official session/tool/stop signals into the bounded local event store; installed-hook replay remains pending | Candidate `session_id` is documented; resumable identity mapping remains unknown until an end-to-end fixture passes |
| ZCode | 3.9.1 (build 3.9.1.5853) | Application bundle `dev.zcode.app`; bundled CLI exists inside the app | The managed hook adapter observes the documented lifecycle subset without inventing SessionEnd; installed-hook replay remains pending | Unknown; no stable session identity has been proven from this installed version |
| Antigravity | 1.1.22 | `agy --version`, shared `~/.gemini/config/hooks.json` | The managed named hook observes `PreInvocation`, `PostToolUse`, and `Stop`; agy has no session start/end event, so `Stop` is the only terminal signal and `fullyIdle=false` keeps the session running | Supported: the native `conversationId` is a UUID and was observed unchanged across a `--conversation` resume |
| OMP | 17.3.5 | `omp --version`, installed package, bundled extension documentation | The classification-only extension observes session, agent, tool, compact, and shutdown events; the GUI separately performs a bounded read of public assistant text and cwd from the matching local transcript; `agent_end.willContinue` distinguishes continuing from terminal turns; installed-extension replay remains pending | Candidate session ID/path exists in the CLI; exact mapping remains unknown until an end-to-end fixture passes |

## Exact return

| Agent | Result on this Mac |
| --- | --- |
| Codex | A native thread UUID supplies a targeted `codex://threads/<UUID>` deep link, but ThreadHelm currently confirms only dispatch. The result remains Unknown until the destination thread identity is checked independently. |
| Claude Code | Exact only when a matching live process plus process-start identity is located at its exact terminal tab. Launching `claude --resume` remains Unknown until the destination identity is checked independently. |
| Cursor | Unknown. `cursor agent --resume [chatId]` exists, but arbitrary desktop-session mapping is not proven. |
| ZCode | Unknown. The `zcode` URL scheme and bundled CLI do not prove arbitrary-session return. |
| Antigravity | Unknown. `agy --conversation <id>` was observed restoring the prior context (the model recalled earlier tool output without re-running it), but the restored session is a newly opened terminal, not the user's original window. |
| OMP | Unknown. ThreadHelm dispatches `omp --resume <session-id>` in the preferred terminal, but does not independently confirm the destination session. |

## Fallback return

| Agent | Result on this Mac |
| --- | --- |
| Codex | Focus the native Codex application; label this as app focus, never exact return. |
| Claude Code | Resume by session when possible, then open the recorded project location in a terminal as an explicitly labeled fallback. |
| Cursor | Open/focus Cursor or open a project location; do not report an arbitrary IDE window as exact. |
| ZCode | Focus ZCode, then use a project-location fallback only when locally available. |
| Antigravity | Open the preferred terminal and dispatch `agy --conversation <id>`, cd-ing to the recorded workspace first. There is no application to focus: agy CLI sessions do not appear in the Antigravity IDE, so a missing conversation ID degrades to view-only rather than an app fallback. |
| OMP | Open the preferred terminal and dispatch the native session resume target; existing-terminal process focus remains unsupported. |

## Permission / question / plan

| Agent | Result on this Mac |
| --- | --- |
| Codex | Tool approval is answered in-app: a managed `PermissionRequest` command hook in `~/.codex/hooks.json` forwards the request to the same local gate and blocks until the user decides. Verified on 0.150.1 — deny hard-blocks the tool and the reason reaches the model verbatim. Two caveats: Codex only loads hooks after the user trusts them once inside Codex (until then the hook is skipped silently), and the gate only fires when Codex itself asks, i.e. `approval_policy` is not `never`. A pending `request_user_input` is still only observable as a question; question answering and plan approval have no Codex hook event. |
| Claude Code | Existing ThreadHelm behavior supports a bounded local permission/question/plan queue and the verified in-app response path. |
| Cursor | Tool approval is answered in-app via `preToolUse`. Cursor has no PermissionRequest equivalent — its internal event map writes that entry as null — so the gate rides the per-tool-call event instead of an ask-the-user event. It is therefore scoped to `Shell` and `Write`; read-only tools pass straight through, because a prompt on every Read would train the user to dismiss prompts. Two filters enforce that: an anchored `matcher` in hooks.json avoids most process spawns, and the hook re-checks `tool_name` itself, since Cursor treats an invalid matcher regex as matching everything. The response supports `permission: allow|deny|ask` plus `updated_input`, and multiple hooks on one event merge as "any deny wins", so the approval entry coexists safely with the observation entry. `timeout` is in seconds (default 60, set to 600) and `failClosed: true` is set because Cursor otherwise ignores a failed hook and runs the tool. Contract read from the CLI's hooks module; a real Cursor-initiated approval has not been exercised end to end (the local cursor-agent is not logged in). |
| ZCode | Tool approval is answered in-app. ThreadHelm registers a managed `PermissionRequest` hook in `~/.zcode/cli/config.json` whose payload and decision wire format match Claude field for field — ZCode emits a snake_case compatibility layer (`hook_event_name`, `tool_name`, `tool_input`, `permission_suggestions`) and accepts `hookSpecificOutput.decision.behavior` with `updatedPermissions` and `updatedInput`, so long-term grants survive. The approval hook is registered with a 600 s budget, separate from the 250 ms observation hooks; the observation budget would kill an approval in a quarter second and ZCode fails **open** on every hook failure, so ThreadHelm returns an explicit deny whenever it cannot reach the gate. `yolo` mode never asks, so the gate does not fire there. Question answering and plan approval have no ZCode hook event. Contract read from the in-app runtime schema and the hook payload constructor; a real GUI-initiated approval has not been exercised end to end on this Mac. |
| Antigravity | Tool approval is answered in-app through the managed `PreToolUse` hook. Three contract details were established by local measurement, not documentation. (1) The payload is protojson camelCase (`conversationId`, `toolCall.name`, `toolCall.args`), unlike every other agent here, so it needs its own decoder. (2) An empty `{}` response means **deny**, not "no opinion" — a pass-through therefore has to write `{"decision":"allow"}` explicitly. (3) agy is fail-**closed**: a hook exiting non-zero blocks the tool and reports the failure to the model, the opposite of ZCode. Because of (3) the fallback is `{"decision":"ask"}`, handing the choice back to agy's own prompt rather than fabricating a denial. The gate runs on every tool with a read-only allowlist passing through in-process; the allowlist is the safe direction, since missing a read-only tool costs one extra prompt while missing a writing tool would silently disable the gate. Question answering and plan approval have no agy hook event. |
| OMP | Tool approval is answered in-app through the managed extension's `tool_call` handler. OMP is the only one of the four with built-in fail-closed: `emitToolCall` substitutes `{block:true, reason}` when a handler times out or throws. That backstop only fires when the handler genuinely fails, so the gate handler never swallows an exception and returns undefined -- every failure path returns an explicit block. The handler timeout (`extensionHandlers.toolCallTimeoutMs`) defaults to 30000ms of wall-clock active work, with waiting on the panel counted; install raises it via `omp config set` and uninstall restores the prior value. A larger value the user set is left alone. ThreadHelm still must not invoke message, cancellation, or other session-control APIs. Contract read from the built-in settings schema and the emitToolCall implementation; a real OMP-initiated approval has not been exercised end to end here, though the generated extension is confirmed to load in the local OMP runtime. |

## Quota

| Agent | Result on this Mac |
| --- | --- |
| Codex | Supported by the existing local app-server rate-limit reader. |
| Claude Code | Supported by the existing read-only local usage reader. |
| Cursor | Unsupported in this project scope. |
| ZCode | Unsupported in this project scope. |
| Antigravity | Supported by `agy -p "/quota"`, which prints tab-separated rows of model group, window, **remaining** percent, and ISO8601 reset time. Both the weekly and five-hour windows are reported for the Gemini and Claude/GPT model groups. |
| OMP | Unsupported in this project scope. |

## Offline behavior

| Agent | Result on this Mac |
| --- | --- |
| Codex | Existing local snapshot reads do not block Codex. |
| Claude Code | Existing state reads fail independently; the verified native Claude path remains available. |
| Cursor | Isolated runtime self-tests verify that hooks return a valid success response quickly when ThreadHelm is absent and failures remain contained. Replay through the currently installed live hook is still pending. |
| ZCode | Isolated runtime self-tests verify that managed hooks fail open and never prevent ZCode work. Replay through the currently installed live hook is still pending. |
| Antigravity | Observation hooks keep stdout empty and always exit 0; an empty observation response was measured not to disturb the run. The approval hook is the one place where ThreadHelm being absent matters, and there agy's fail-closed behavior blocks the tool rather than running it unchecked. Replay through the currently installed live hook is still pending. |
| OMP | Isolated runtime self-tests verify that extension failures are contained and OMP continues normally. Replay through the currently installed live extension is still pending. |

## Freshness

| Agent | Rule |
| --- | --- |
| Codex | Explicit active/terminal state wins. Retained terminal sessions may remain visible for up to 24 hours; an ambiguous non-terminal record becomes stale after the existing 30-minute freshness window. |
| Claude Code | Live process and agents snapshot are strongest; transcript-only state is bounded by existing stale/process checks. |
| Cursor | The shared live store expires active evidence after 5 minutes, idle evidence after 30 minutes, and terminal evidence after 24 hours; installed-hook restart timing remains unverified. |
| ZCode | Stop plus process observation and a documented stale timeout are required because SessionEnd is unavailable in the bundled hook list. |
| Antigravity | `Stop` with `fullyIdle=false` remains running; otherwise it is terminal. Failure is only claimed when `error` is non-empty or `terminationReason` is `error` — a normal finish reports `NO_TOOL_CALL`, so treating unrecognized reasons as failures would mark most healthy sessions red. |
| OMP | `agent_end` remains running when `willContinue=true`; otherwise it is terminal. Shutdown plus expiry cleans up non-terminal snapshots. |

## Duplicate / out-of-order

| Agent | Rule |
| --- | --- |
| Codex | Native thread UUID is the deduplication identity; terminal state must not regress to an older active snapshot. |
| Claude Code | Session/request identity and FIFO coordinator semantics are authoritative; completed requests must not be resurrected by older transcript data. |
| Cursor | The shared reducer deduplicates by agent plus native session candidate, scopes event IDs to the session, and ignores regressive sequences. |
| ZCode | The shared reducer tolerates repeated hooks and timestamps without inventing a SessionEnd event. |
| Antigravity | The shared reducer deduplicates by agent plus `conversationId`, keeps a non-idle `Stop` running, and ignores regressive sequences. |
| OMP | The shared reducer keeps `agent_end.willContinue=true` running, deduplicates repeated terminal `agent_end` events, and ignores regressive sequences. |

## Supported attention

| Agent | Interrupting reasons supported by this truth set | Default non-interrupting results |
| --- | --- | --- |
| Codex | Question requiring user input; task-level failure | Running, ordinary tool failure, completion/review-ready, idle |
| Claude Code | Permission, question, plan approval, task-level failure | Running, ordinary tool failure, completion/review-ready, idle |
| Cursor | Verified task-level failure only; blocked/input remains unknown | Lifecycle churn, ordinary tool failure, completion/review-ready |
| ZCode | Verified task-level failure only in the first adapter | Lifecycle churn, ordinary tool failure, completion/review-ready |
| Antigravity | Verified terminal `Stop` task-level failure only; no approval/input interception beyond the tool gate | Lifecycle churn, non-idle `Stop`, ordinary tool failure, completion/review-ready |
| OMP | Verified terminal `agent_end` task-level failure only; no approval/input interception | Lifecycle churn, continuing `agent_end`, ordinary tool failure, completion/review-ready |

## Unsupported or unknown

- Cursor cloud agents are out of scope; Cursor in-app approval and arbitrary IDE-session deep links are not claimed.
- ZCode user CLI configuration was absent at capture time. Its absence does not mean ZCode is uninstalled, and discovery must not create the file.
- ZCode exact return, already-running-session hook pickup, question/plan semantics, and SessionEnd are unknown or unavailable in the observed surface.
- OMP approval, input injection, cancellation, and other session controls remain unsupported. Resume navigation is supported; exact landing remains unknown.
- OMP transcript projection is local and read-only: public assistant text and cwd are allowed after redaction; thinking, tool arguments, tool results, raw JSON payloads, and detected credentials are excluded.
- Antigravity question answering, plan approval, session mutation, and cancellation are unsupported: agy exposes only PreToolUse, PostToolUse, PreInvocation, PostInvocation, and Stop. Resume navigation is supported; exact landing in the user's original terminal remains unknown.
- Antigravity hooks must live in the cross-product `~/.gemini/config/hooks.json`. The CLI-specific `~/.gemini/antigravity-cli/hooks.json` is counted in the hooks_manager load log but its hooks never execute (probe-verified on 1.1.22, 2026-08-31); agy's changelog also describes writing that path as a fixed bug. Non-CLI sessions (IDE, Antigravity 2.0) firing the shared hooks are filtered in-process by the `transcriptPath` product directory (`antigravity-cli` vs `antigravity-ide` vs `antigravity`).
- Antigravity's documented `PostToolUse` input lists only `stepIdx` and `error`; the observed payload also carries the full `toolCall`. Parsing tolerates both.
- Version drift does not change an observed waiting/running classification; it limits capability claims, automatic interaction, and interrupting attention.
- No adapter may turn a normal tool failure into a task failure, an app focus into exact success, or an inferred state into official evidence.

This matrix must be revalidated whenever any listed installed version changes.
