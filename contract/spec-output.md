# The agent-friendly output convention — protocol

Version 1.0. The key words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are used
as in RFC 2119.

This document defines the rules for making a CLI's output safe for programmatic
consumption by AI agents. A conforming tool follows all six rules below.

---

## 1. Stream separation

### stdout = data only

- Primary output (the answer to the command) MUST go to stdout.
- stdout MUST be parseable: JSON (`--json` flag or JSON-by-default) or
  line-based text (key-value, TSV, one record per line).
- stdout MUST NOT contain progress indicators, logs, warnings, or ANSI escape
  codes when stdout is not a TTY.
- stdout is a **versioned API contract**. Adding fields is allowed (additive).
  Removing or renaming fields is a breaking change and MUST be gated by a
  version bump or a flag.
- The output SHOULD include a `version` field so consumers can detect schema
  changes: `{"ok":true,"version":"1.0",...}`.

### stderr = context only

- Progress indicators, warnings, logs, and informational messages MUST go to
  stderr.
- stderr MUST NEVER contain primary data. An agent that ignores stderr entirely
  MUST still get the full result from stdout.
- Progress on stderr SHOULD be incremental for long-running operations (so the
  agent knows the tool is not hung).

### No mixing

- A tool MUST NOT print data to stderr "for context" and MUST NOT print logs to
  stdout "for visibility". The streams have one job each.

---

## 2. Semantic exit codes

Exit codes communicate actionable information to agents.

| Range | Category | Agent action |
|---|---|---|
| `0` | success | proceed to next step |
| `80-89` | input/validation | don't retry; fix arguments/permissions first |
| `90-99` | precondition/resource | ask for clarification or try alternate resource |
| `100-109` | external/integration | retry with backoff (likely transient) |
| `110-119` | internal/bug | report bug, don't retry |

Recommended subdivisions:

| Code | Meaning |
|---|---|
| `80` | invalid arguments |
| `82` | validation error (missing required field) |
| `85` | invalid argument value |
| `90` | not authenticated / not logged in |
| `92` | resource not found |
| `95` | already exists / conflict |
| `100` | connection error / network unreachable |
| `105` | external API error / timeout |
| `110` | internal error / panic |

- Exit code `1` MAY be used for backward compatibility but SHOULD be avoided in
  new tools — it carries no semantic information.
- The exit code MUST match the `error.code` field in the typed error body (§3).

---

## 3. Typed errors

Errors MUST be structured JSON when `--json` is used, and SHOULD be structured
even in text mode (on stderr).

### Error shape

```json
{
  "ok": false,
  "error": {
    "code": 90,
    "type": "not_authenticated",
    "message": "not logged in",
    "recoverable": false,
    "suggestions": ["myapp signup <email>"]
  }
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `ok` | boolean | yes | always `false` on error |
| `error.code` | integer | yes | the exit code (matches `$?`) |
| `error.type` | string | yes | machine-readable error category (snake_case) |
| `error.message` | string | yes | human-readable explanation |
| `error.recoverable` | boolean | yes | should the agent retry? `true` for transient (100-109), `false` for input/bug |
| `error.suggestions` | string[] | no | next actions the agent can take |

- The `type` SHOULD be stable across versions (agents branch on it).
- The `message` MAY change between versions (humans read it, agents don't).
- `suggestions` SHOULD include the exact command that fixes the problem, so the
  agent can execute it directly.

### No internal retries

- The tool MUST NOT retry internally on transient failures. It reports the error
  with `recoverable: true` and exits. The agent decides whether to retry, back
  off, or escalate.
- Internal retry loops hide failures, consume timeout budget, and break
  deterministic pipelines.

---

## 4. Self-describing introspection — `help-json`

A conforming tool MUST expose a machine-readable command catalog.

### `<tool> help-json` (or `--help-json`)

```json
{
  "version": "1.0.0",
  "output": "json",
  "commands": {
    "signup": { "args": ["email"], "auth": false },
    "leads": { "args": [], "flags": ["--new","--status <s>","--csv"], "auth": true },
    "update": { "args": [], "flags": ["--check","--force"], "auth": false }
  },
  "exit_codes": {
    "0": "success",
    "80": "input/validation",
    "90": "precondition/resource",
    "100": "external/integration",
    "110": "internal"
  },
  "env": ["MYAPP_SERVER", "MYAPP_TIMEOUT"]
}
```

- The catalog MUST include every public command with its args, flags, and auth
  requirement.
- The catalog MUST include the exit code mapping.
- The catalog MUST include relevant environment variables.
- Unknown fields MUST be ignored (forward compatibility).

### Relation to `guide`

`help-json` is the **command catalog** (what commands and flags exist). `guide`
(cli-guide-spec) is the **mental model** (when to use what, the loop, gotchas).
A conforming tool SHOULD have both; `help-json`'s `see_also` SHOULD point at
`guide`.

---

## 5. Output formats

A conforming tool SHOULD support multiple output formats:

| Format | Flag | Use case |
|---|---|---|
| JSON | `--json` (or JSON-by-default) | agents, programmatic consumption |
| Text | (default) | humans, line-based parsing |
| CSV | `--csv` | spreadsheet export, bulk operations |

- JSON output MUST be on stdout, one JSON object per command invocation.
- Text output SHOULD be line-based (key-value or TSV) so it's parseable with
  `grep`/`awk`/`jq`.
- CSV output MUST be valid CSV with a header row.
- The format flag MUST be consistent across all commands (`--json` everywhere,
  not `-o json` in some and `--json` in others).

---

## 6. Non-interactive by default

- Every command MUST support non-interactive execution. An agent cannot answer a
  stdin prompt.
- `--no-interactive` / `--yes` / `-y` flags MUST disable all prompts and use
  defaults.
- Credentials MUST come from flags, environment variables, or config files —
  never from an interactive prompt on the happy path.
- A no-echo prompt MAY be used as a last resort (e.g., first-time password entry),
  but MUST be skippable via an env var or flag.

---

## 7. Conformance summary

A **tool** conforms if it:

- separates streams per §1 (data on stdout, context on stderr, no mixing);
- uses semantic exit codes per §2 (0 + 80-119 ranges);
- emits typed errors per §3 (code, type, message, recoverable, suggestions);
- does not retry internally (§3);
- exposes `help-json` per §4 (machine-readable command catalog);
- supports `--json` output per §5;
- is non-interactive by default per §6 (`--no-interactive` / `--yes`).
