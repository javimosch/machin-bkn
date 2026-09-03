# The daemon lifecycle convention — protocol

Version 1.0. The key words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are used as in
RFC 2119.

This document defines a convention with three parts: a **bind-configurable serve
command**, two **HTTP endpoints** (`/_health`, `/_shutdown`), and a **daemon
lifecycle command** (`start`/`stop`/`status`) built on them. A conforming tool
implements all three, or the PID-file variant of §5 if it has no embedded HTTP
server.

This spec is scoped to **process lifecycle only** — starting, stopping, and
probing a long-running process for the duration of a login session or a
supervisor's lifetime. It deliberately does NOT cover OS-level boot persistence
(systemd/launchd unit registration); see [README.md](README.md#scope) for why.

---

## 1. The serve command — `<tool> serve`

A conforming tool exposes:

```
<tool> serve [--host HOST] [--port PORT]
```

- Runs the tool's HTTP server in the **foreground** — it blocks until stopped
  (Ctrl-C, a signal, or `/_shutdown`). This is the primitive; §4's `daemon start`
  is what backgrounds it.
- `--port` MUST have a documented, compiled-in default (surfaced via
  `help-json`, per [cli-output-spec](https://github.com/javimosch/cli-output-spec)).
- `--host` default MUST be `127.0.0.1` (loopback-only). A tool MUST NOT default
  to `0.0.0.0` (all interfaces) — see §6 for why this is the load-bearing rule
  in this spec. Binding to `0.0.0.0` or a specific LAN/public address MUST be an
  explicit, deliberate choice by the caller via `--host`.
- A tool MAY additionally accept `--bind HOST:PORT` as shorthand for both. If a
  tool supports both forms, `--host`/`--port` SHOULD take precedence when both
  are given.
- Env var overrides SHOULD be consulted when the flag is absent, flags winning
  when both are present: `<TOOL>_HOST` / `<TOOL>_PORT` (or a single
  `<TOOL>_LISTEN=host:port`).
- MUST print one confirmation line to **stderr** (never stdout — this is
  context, not data, per cli-output-spec §1) once bound and before entering the
  accept loop:
  ```
  [serve] listening on http://127.0.0.1:8080
  ```
  An agent scripting "launch, then poll health" needs this to exist and to be
  flushed immediately (many runtimes/agents pipe a daemon's stdio; fully
  buffered output means the line never arrives before a reader's timeout).

---

## 2. Health — `GET /_health`

- MUST be **open** (no auth) — the same rationale as
  [cli-update-spec](https://github.com/javimosch/cli-update-spec)'s `/version`:
  a liveness probe that requires auth can't be used to detect "auth itself is
  broken".
- MUST return `200` with `{"ok":true,"service":"<tool>","pid":<int>}` when
  healthy.
- SHOULD return `503` with `{"ok":false,"service":"<tool>"}` if the tool
  considers itself unhealthy (e.g. it lost its database connection) rather than
  reporting `200` unconditionally just because the HTTP listener is up.
- SHOULD respond in well under a second — no heavy checks (a deep DB round
  trip, an outbound API call) on this path. A tool that needs a deeper check
  SHOULD expose it as a separate route (e.g. `/_ready`), not overload
  `/_health`.

---

## 3. Shutdown — `POST /_shutdown`

- Triggers a graceful `exit(0)` of the process.
- MUST respond `200 {"ok":true,"stopping":true}` **before** exiting — the
  socket write must complete first, so the caller's HTTP client sees a clean
  response, not a connection reset.
- SHOULD stop accepting new connections immediately and MAY allow in-flight
  requests a bounded grace period (reference: 2 seconds) before exiting
  unconditionally.
- **Bind-aware gating.** If the process is bound to a **non-loopback** host
  (`--host` is not `127.0.0.1`/`localhost`), `/_shutdown` MUST require a
  shared-secret bearer token:
  - `Authorization: Bearer <token>`, compared against a value generated at
    startup and written to a local file the CLI's own `daemon stop` can read
    (reference: `~/.<tool>/shutdown.token`, mode `0600`, regenerated on every
    `serve`/`daemon start`).
  - A request without a valid token MUST get `403`, and the process MUST NOT
    shut down.
  - A **loopback-bound** daemon MAY skip the token (only a co-resident process
    can reach `127.0.0.1` — though a tool with stricter multi-tenant needs on a
    shared host MAY require the token unconditionally; that's still
    conforming, since §3 only mandates the token off-loopback, not that it be
    forbidden on-loopback).
  - This closes a real, observed gap: existing daemon-capable tools that expose
    an unauthenticated `/_shutdown` are fine as long as they only ever bind to
    loopback — but the same code with no gating becomes a denial-of-service
    button the moment it's bound to `0.0.0.0`. A conforming tool cannot ship
    `--host 0.0.0.0` and an unauthenticated `/_shutdown` at the same time.

---

## 4. The daemon lifecycle command — `<tool> daemon <start|stop|status>`

```
<tool> daemon start  [--host HOST] [--port PORT]
<tool> daemon stop   [--host HOST] [--port PORT]
<tool> daemon status [--host HOST] [--port PORT]
```

The process-lifecycle wrapper around §1–§3. It does not touch OS service
managers — see [README.md](README.md#scope).

### `start`

- MUST launch `<tool> serve --host H --port P` **detached** from the invoking
  terminal: a background child whose stdio is redirected to a log file, that
  survives the parent CLI process exiting.
- MUST poll `GET /_health` after launching (reference: every 100ms, 5s total
  timeout) rather than assume success from a fixed `sleep()` — a bad config can
  make the child exit immediately, and a fixed sleep either wastes time on the
  common case or races a slow start on a loaded box.
- MUST be **idempotent**: if `/_health` already responds on that host:port,
  `start` MUST NOT spawn a second instance racing for the port. It reports
  `{"ok":true,"daemon":"already_running","host":"...","port":N}` and exits 0.
- On confirmed healthy (new process): `{"ok":true,"daemon":"started","host":"...","port":N,"log":"<path>"}`,
  exit 0.
- On timeout without a healthy response: exit `100` (external/integration — the
  child process is what failed, not the CLI invocation's own input), and the
  error `message` SHOULD include the log tail.

### `stop`

- MUST probe `GET /_health` first. If unreachable, this is a **no-op success**:
  `{"ok":true,"daemon":"already_stopped"}`, exit 0 — stopping twice, or
  stopping on a machine where nothing was started, is not an error (the same
  idempotency principle as [cli-update-spec](https://github.com/javimosch/cli-update-spec)'s
  `uninstall`).
- Otherwise MUST `POST /_shutdown` per §3 (with the token, if the daemon is
  bound off-loopback — `stop` reads the same local token file `start` wrote,
  since the CLI and the daemon it manages share that trust boundary), then poll
  `GET /_health` again (reference: every 100ms, 5s timeout) to confirm the
  process actually stopped — not merely that the HTTP call returned 200, since
  a graceful shutdown may still be draining in-flight requests.
- On confirmed stopped: `{"ok":true,"daemon":"stopped"}`, exit 0.
- On timeout still responding: exit `110` (internal — the daemon didn't honor
  its own shutdown contract).

### `status`

- MUST probe `GET /_health` (no token — status only ever reads a public
  endpoint, whether or not shutdown is gated).
- Running: `{"ok":true,"daemon":"running","host":"...","port":N}`, exit `0`.
- Not running: `{"ok":true,"daemon":"stopped"}`, exit `3` — distinct from `0` so
  a script can branch on `$?` without parsing JSON (the same nagios-adjacent
  convention as a health-check tool's own exit codes: `0` = running/OK, a
  non-zero-but-not-an-error code = the other steady state).

---

## 5. The PID-file alternative (no embedded HTTP server)

A tool with no HTTP server MAY implement the same three subcommand names via a
**PID file + signal** instead of §2/§3's HTTP endpoints:

- `start`: fork/detach, write the child's PID to a file (reference:
  `~/.<tool>/<tool>.pid` or `/tmp/<tool>.pid`), redirect stdio to a log.
- `stop`: read the PID file, `kill(pid, SIGTERM)`, remove the PID file. Missing
  or stale (process no longer exists) PID file MUST be a no-op success
  (`already_stopped`), not an error — same idempotency rule as §4.
- `status`: read the PID file, `kill(pid, 0)` to check liveness without
  signaling, report `running`/`stopped` with the same exit codes as §4.

A tool **with** an HTTP server SHOULD prefer the HTTP mechanism over PID files:
a PID file can go stale across a reboot, or worse, point at a *different*
process after PID reuse — an HTTP health check that asks the process itself
"are you healthy and are you actually me" (via `service` in the `/_health`
body) can't be fooled that way. PID files remain valid, and are the only
option, for a daemon with no HTTP listener at all.

---

## 6. Interface binding is the caller's decision, not the tool's default

This is the rule the rest of the spec exists to enforce. Every daemon-capable
tool surveyed while writing this spec binds unconditionally to all interfaces
today (built on a `listen(port)`-shaped primitive with no host parameter) —
convenient to write, wrong default to ship. A convention whose entire premise
is "an agent can spin this daemon up without thinking about it" cannot default
to exposing it to the network.

A conforming tool's underlying listen call MUST accept a host parameter so
`--host 127.0.0.1` (the default) actually restricts the bind, not merely
labels it. See [RECIPE.md](RECIPE.md) for the machin-specific gap this
surfaced and the workaround/upstream-fix path.

---

## 7. Exit codes

| Code | Meaning |
|---|---|
| 0 | success: started, stopped, already-running, already-stopped, or status = running |
| 3 | `status`: daemon is stopped (steady state, not an error) |
| 80 | invalid arguments |
| 100 | `start` failed — child process did not become healthy within the timeout |
| 110 | `stop` failed — daemon still responding after its own shutdown grace period |

---

## 8. What NOT to do

- **Don't default to `0.0.0.0`.** Loopback by default; a LAN/public bind is an
  explicit `--host`.
- **Don't leave `/_shutdown` unauthenticated on a non-loopback bind.** Gate it
  with the token per §3 the moment `--host` isn't loopback.
- **Don't replace polling with a fixed `sleep()`.** Either flaky (too short on
  a loaded box) or slow (too long on the common case). Poll `/_health` with a
  bounded total timeout instead.
- **Don't fail the idempotent cases.** `start` on an already-running daemon and
  `stop` on an already-stopped one are both successes, not errors.
- **Don't block indefinitely** on `/_health`/`/_shutdown` calls from the CLI
  side. Bound every wait (reference: 5s) so a hung daemon can't hang the CLI
  that's trying to manage it.

---

## 9. Conformance summary

A tool conforms if it:

- exposes `<tool> serve --host --port` per §1, binding to `127.0.0.1` by
  default;
- exposes `GET /_health` per §2, open and fast;
- exposes `POST /_shutdown` per §3, token-gated whenever bound off-loopback;
- exposes `<tool> daemon start|stop|status` per §4, idempotent and built on
  §1–§3 — **or** the PID-file variant of §5, if the tool has no embedded HTTP
  server.
