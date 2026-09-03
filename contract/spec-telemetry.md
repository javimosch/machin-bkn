# cli-telemetry-spec — normative protocol

Key words MUST, MUST NOT, SHOULD, SHOULD NOT, MAY are to be interpreted as in
RFC 2119.

A tool that implements this spec is called the **sender**. The service receiving
events is the **collector**. The person or agent running the tool is the **user**.

---

## 1. Disclosure

**1.1** On the first run on a machine, the sender MUST print a disclosure notice
to **stderr**. It MUST NOT be printed to stdout (see §6).

**1.2** The notice MUST state, in plain language: that usage data is sent, the
complete list of what is sent, the destination, and the exact command or
environment variable that disables it.

**1.3** The sender MUST NOT transmit any event before the disclosure notice for
that machine has been printed. Sending the first event later in the same run, after
the notice, is permitted and RECOMMENDED — the user has been told before anything
left the machine, and can disable it before the next run.

**1.4** The sender MUST record that the notice has been shown, and SHOULD NOT
print it again.

**1.5** The notice SHOULD be at most four lines. A wall of text is not disclosure;
it is a thing people learn to skip.

A conforming notice:

```
[telemetry] myapp sends anonymous usage counts: tool, version, os/arch, which
[telemetry] verb ran, and whether it failed. No identity, arguments or data.
[telemetry] See `myapp telemetry` for the exact payload. Disable with
[telemetry] MYAPP_TELEMETRY=0 (or DO_NOT_TRACK=1).
```

---

## 2. Consent and off switches

**2.1** The sender MUST check all of the following **before executing any network
code**, and MUST send nothing if any is set:

| Switch | Meaning |
|---|---|
| `<TOOL>_TELEMETRY=0` (also `false`, `off`, `no`) | tool-specific opt-out |
| `DO_NOT_TRACK=1` | the cross-vendor convention; MUST be honoured |
| a persisted disable flag | set by `<tool> telemetry --off` |

**2.2** The sender MUST default to **disabled** when it detects a
non-interactive automation environment — `CI`, `CONTINUOUS_INTEGRATION`, or any
`GITHUB_ACTIONS`/`GITLAB_CI`/`BUILDKITE`-style marker. CI runs are not users, and
counting them inflates every number the author is trying to read.

**2.2.1** CI is one instance of a broader rule: **automated fetch-and-run is not
usage.** Audit tools, install checkers, mirrors, package scanners, uptime probes
and container image builds all download a tool into a fresh environment and run
it — which is indistinguishable, to a telemetry implementation, from a new
machine being installed and used.

Environment detection cannot catch these, because most of them set nothing. The
obligation therefore runs BOTH ways:

- **Tools** MUST honour `DO_NOT_TRACK` (§2.1), which is the only signal such a
  harness can reliably send.
- **Harnesses** that fetch and execute other people's binaries SHOULD set
  `DO_NOT_TRACK=1` — and `<TOOL>_TELEMETRY=0` where the tool is known.

This is not hypothetical. The reference implementation recorded **15 installs**,
every one of them produced by the author's own install-audit script running on a
schedule; the metric it existed to provide was entirely manufactured by the tool
measuring it. Any counter of "machines" is really a counter of "fresh
environments", and fresh environments are cheap to create by accident.

**2.3** `<tool> telemetry --off` MUST persist the opt-out so it survives future
runs, and MUST report that it did.

**2.4** A tool MAY be opt-**in** instead (disabled until `<tool> telemetry --on`).
This is the stricter choice and is conforming. A tool that handles credentials or
regulated data SHOULD be opt-in.

**2.5** The sender MUST NOT make telemetry a condition of any functionality, and
MUST NOT degrade behaviour when it is disabled.

---

## 3. What may be collected

**3.1** The payload is an **allow-list**. A field not listed here MUST NOT be sent.
Implementations MUST NOT add fields "just in case"; a deny-list leaks by default.

| Field | Type | Notes |
|---|---|---|
| `tool` | string | the tool's name |
| `version` | string | the tool's version |
| `event` | enum | `install` \| `run` \| `error` (§4) |
| `verb` | string | the subcommand name, from the tool's OWN fixed list of verbs. MUST NOT be free text and MUST NOT include arguments |
| `os` | string | e.g. `linux`, `darwin` |
| `arch` | string | e.g. `x86_64`, `arm64` |
| `exit_class` | integer | the semantic exit-code CLASS (0, 80, 90, 100, 110 — see cli-output-spec), never the message |
| `install_id` | string | see §3.3 |
| `ts` | string | RFC 3339 timestamp |

**3.2** The following MUST NOT be sent, under any field name: hostname, username,
user id, home directory, current directory, any file path, any command-line
argument, any flag *value*, any document or record content, any URL or connection
string belonging to the user, any environment variable, any error message text,
any hash derived from the above, and any persistent hardware or machine
identifier.

**3.3** `install_id`, if present, MUST be:

- generated from a cryptographic random source at first run — **not** derived
  from hostname, MAC, machine-id, username, or any other machine property;
- stored in the tool's own config directory;
- regenerable on demand (`<tool> telemetry --reset-id`);
- omitted entirely if the tool has no need to distinguish repeat runs from new
  installs. **Omitting it is the safer default.**

**3.4** The collector MUST NOT log or retain client IP addresses, and MUST NOT
attempt to enrich events with geolocation, reverse DNS, or any third-party data.

**3.5** The collector SHOULD store aggregates (counts per tool/version/day/verb)
rather than one row per event, and MUST NOT build per-user profiles.

---

## 4. Events

**4.1** Exactly three event types are defined. A tool MUST NOT invent more.

| Event | When | Answers |
|---|---|---|
| `install` | first run on a machine, once ever | did anyone actually get it running |
| `run` | a verb completed | which verbs are reached, on what platforms |
| `error` | a verb exited non-zero | where users get stuck |

**4.2** `install` is the highest-value event and the one most tools lack. It is the
difference between "nobody downloaded it" and "the download was broken".

**4.3** A tool SHOULD send at most one event per invocation. A tool MUST NOT send
events on a timer, on a background schedule, or from a daemon it starts for the
purpose.

**4.4** A long-running server MAY send one `run` event at startup. It MUST NOT
send per-request events; that is a request log, and this is not a request log.

---

## 5. Transport

**5.1** The sender MUST use a single `POST` of one JSON object to a single
configured endpoint, over HTTPS.

**5.2** The send MUST be bounded by a hard timeout (RECOMMENDED ≤ 2 seconds) and
MUST NOT retry. This is consistent with cli-output-spec: the tool reports, it does
not retry on the user's behalf.

**5.3** A failed send MUST be silent and MUST NOT change the exit code, print to
stdout, or produce a warning on stderr in normal operation. **A tool that cannot
reach the collector is working correctly.**

**5.4** The sender MUST NOT delay the user's result. It SHOULD send after the
work completes and the result has been written, or in a detached best-effort
manner.

**5.5** The endpoint MUST be visible in `<tool> telemetry` output (§6) and
MUST be overridable via `<TOOL>_TELEMETRY_URL`, so an organisation can point it
at its own collector rather than choosing between "on" and "off".

The override was RECOMMENDED in the first version of this spec and is now
required, because it is also what makes the tool auditable: a reviewer verifying
that telemetry behaves as documented has to be able to aim it somewhere harmless.
Without it, the only way to observe what a tool sends is to let it send.

**5.6** The sender MUST NOT send events for a tool invocation that failed before
the tool's own argument parsing (a crash before this spec's code runs is not an
event).

---

## 6. The `telemetry` command

**6.1** Every conforming tool MUST provide `<tool> telemetry`, which prints, on
**stdout**, as JSON (per cli-output-spec):

```json
{"ok":true,"data":{
  "enabled": true,
  "reason": "enabled",
  "endpoint": "https://t.example.com/e",
  "install_id": "7f3ac1d29b04",
  "next_payload": {"tool":"myapp","version":"1.4.0","event":"run","verb":"sync",
                   "os":"linux","arch":"x86_64","exit_class":0},
  "disable": "MYAPP_TELEMETRY=0",
  "notice_shown": true,
  "last_sent": "2026-07-30T12:04:11Z"
}}
```

**6.2** `next_payload` MUST be the **actual** payload the tool would send, produced
by the same code path that sends it — not a hand-written example. This is the
point of the command: the user verifies rather than trusts, and a payload that
drifted from its documentation is caught by anyone who looks.

**6.3** `reason` MUST explain the current state when disabled — which switch did
it (`DO_NOT_TRACK`, `CI detected`, `disabled by config`, …). "Off, and I will not
say why" is not inspectable.

**6.4** The command MUST support `--off` and (if opt-in) `--on`, and SHOULD
support `--reset-id`.

**6.5** Nothing about telemetry may appear on stdout during normal operation of
any other verb.

---

## 7. Documentation

**7.1** The tool's `guide` (see cli-guide-spec) MUST document telemetry: what is
sent, the switches, and the `telemetry` verb.

**7.2** The tool's README MUST state it in the open, not in a footnote. A user who
finds out from a packet capture is entitled to be angry; a user who read it in the
README and left it on has consented in the only way that counts.

**7.3** If a tool adds telemetry to a version that did not have it, the change MUST
be in the release notes, at the top.

---

## 8. Conformance

A tool conforms if:

1. it discloses on stderr before the first send;
1b. it honours `DO_NOT_TRACK` even when nothing else identifies the caller as
   automation (§2.2.1) — verifiable from outside with
   [stranger](https://github.com/javimosch/stranger), which asserts no outbound
   connection is made when the switch is set;
2. it honours `<TOOL>_TELEMETRY=0` and `DO_NOT_TRACK=1` before any network code;
3. it defaults off in CI;
4. it sends only allow-listed fields (validate against `event.schema.json`);
5. it never blocks, retries, fails the caller, or writes to stdout;
6. `<tool> telemetry` prints the real next payload;
7. the guide and README document it.

A tool that cannot satisfy §3.2 for its domain SHOULD ship no telemetry at all.
**No signal is better than a signal that costs the user's trust.**

### 8.1 When not to adopt this at all

Two tools in the reference estate were instrumented and then **reverted**, which
is worth recording because "adopt it everywhere" is the wrong instinct:

- One cross-compiles to four platforms with `zig cc`. Telemetry needs an HTTPS
  POST, HTTPS pulls in OpenSSL, and zig could not resolve `libssl`/`libcrypto`
  for those targets. The choice was four platforms or a usage number, and it is
  a build-time tool that runs mostly in CI — precisely what §2.2 excludes — so
  the signal would have been the weakest in the estate at the highest cost.
- One is a GUI application that binds POSIX `write(2)` through FFI. MFL has no
  namespaces, so that shadows the only builtin capable of writing to stderr, and
  §1.1 requires the disclosure to go there. Unshadowing it meant editing the
  PTY write path of a program that cannot be tested without a display.

The general rule: **if telemetry costs the tool a capability its users actually
have — a platform, a channel, a guarantee — the tool keeps the capability.** A
usage counter is a convenience for the author; the capability is the product.
