# ThreadHelm local agent core contract

Date: 2026-08-12

Scope: the owner's Mac; Codex, Claude Code, Cursor, ZCode, and Pi; schema version 1.

## Stable core

`AgentID` is an extensible, bounded token. The built-in order is `codex`,
`claudeCode`, `cursor`, `zcode`, `pi`; a new ID sorts after built-ins without a
UI vendor switch. Task sources and quota providers are separate registries.
Only Codex and Claude Code are quota providers.

Adapters expose discovery/version, managed-integration lifecycle, observation,
capabilities, freshness, opening, and privacy-safe diagnostics. Unsupported and
unknown are different states. In particular, Cursor, ZCode, and Pi exact return
remain unknown; Pi navigation and all Pi mutation/action capabilities are
unsupported.

The reducer keys a session by agent plus native identity, scopes event IDs to a
session, removes duplicates, and chooses sequence, same-host monotonic time, or
observed time in that order when the relevant ordering signal is complete. A
tie is resolved by stable content fields, never input order. One failed source
retains its previous frame while healthy sources continue updating.

## Envelope version 1

The serialized envelope contains only:

- schema version;
- bounded agent, adapter-version, event-ID, and event-type tokens;
- an optional bounded native-session candidate;
- optional native sequence;
- same-host monotonic nanoseconds;
- a classification-only `redactedPayload`.

Allowed payload classifications are execution state, attention reason,
actionability, evidence quality, freshness class, integration status, bounded
error class, duration bucket, and payload-disposition/size bucket. Raw prompts,
hidden reasoning, titles, commands, arguments, command/tool output, secrets,
credentials, and filesystem paths are not valid fields. Unknown keys or invalid
values force a metadata-only envelope rather than being copied or truncated.

Serialized output is capped at 64 KiB. Oversized input becomes a metadata-only
event with a coarse size bucket. The synchronous agent-facing path has a 250 ms
deadline, no synchronous retry, and an empty success response on offline,
timeout, malformed response, or encoding failure. Stdout is reserved for the
vendor protocol; diagnostics must not be printed there.

An eventual asynchronous queue may contain normalized envelopes only. It is
bounded to 256 events and 1 MiB per adapter, coalesces non-attention churn, and
drops the oldest non-attention entry first. This queue is not permission to
retain rejected raw input.

## Local endpoint

The preferred endpoint is a user-owned Unix-domain socket inside a mode-0700
directory. A loopback TCP fallback, if ever needed, must reject non-loopback
peers and require a per-install random token stored mode 0600. The receiving app
must validate the expected local user before accepting an event.

No live vendor hook or extension may be installed until its adapter passes this
contract in an isolated configuration copy, including app-offline, slow-server,
malformed-response, oversize, idempotent install/repair/uninstall, and
non-managed-config-preservation cases.
