# The self-update convention — protocol

Version 1.1. The key words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are used as in
RFC 2119.

This document defines a convention with four parts: a **version endpoint**, an
**update command**, a **passive nudge**, and **self-installation** (`install`/
`uninstall`). A conforming tool implements the first three; self-installation is an
independently-adoptable addition (§9) for tools distributed as a bare binary.

---

## 1. Content-hash versioning

The version is `sha256[:12]` of the distributed artifact (the binary or tarball the
server serves). This is the single shared identifier of the convention.

- The version MUST be the first 12 hex characters of the SHA-256 of the artifact.
- Identical bytes MUST produce the same version. This means no version-bump
  discipline is needed: if nothing changed, the hash is the same, and no update is
  triggered.
- The version is NOT a semantic version. It is a content hash. Tools MAY additionally
  expose a semver for human display, but the update mechanism uses the content hash
  exclusively.

---

## 2. The version endpoint — `GET /version`

A conforming server exposes this route. It returns metadata about the latest
artifact it is serving.

- The endpoint is **open**: it MUST NOT require authentication.
- The response is JSON, `Content-Type: application/json`.

### Success response

```json
{
  "ok": true,
  "version": "a1b2c3d4e5f6",
  "download": "/dl/myapp",
  "sha256": "a1b2c3d4e5f67890abcdef1234567890abcdef1234567890abcdef1234567890"
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `ok` | boolean | yes | `true` on success |
| `version` | string | yes | `sha256[:12]` of the artifact currently served |
| `download` | string | yes | path (relative to the server base) or absolute URL to download the artifact |
| `sha256` | string | no | full 64-char sha256 hex; SHOULD be included for belt-and-suspenders verification |

### Error response

`404` if no artifact is published, with `{"ok":false,"error":"<message>"}`.

### Path convention

The endpoint path MAY vary per tool (`/version`, `/v1/version`, `/_version`). The
tool's CLI MUST know its own server's path. The convention is the response shape,
not the path.

---

## 3. The update command — `<tool> update`

A conforming tool exposes an `update` subcommand:

```
<tool> update [--check] [--force]
```

### Flags

| Flag | Behavior |
|---|---|
| (none) | Check → download → verify → smoke-test → swap. Exit 0 on success. |
| `--check` | Check only; do not download or swap. Exit 0 if up-to-date, exit 5 if update available. |
| `--force` | Re-download and swap even if the version matches (repair/corrupt binary). |

### Flow (MUST follow this order)

1. **Compute local version**: `sha256[:12]` of the running binary, or read a
   `VERSION` file written at install time (for bundle/tarball CLIs).
2. **Fetch server version**: `GET /version` from the server. Base URL from
   `<TOOL>_SERVER` env var, or a compiled-in default.
3. **Compare**: if local == server version and `--force` is not set, report
   up-to-date and exit 0.
4. **Download** the artifact to a temp file.
5. **Verify**: `sha256[:12]` of the downloaded file MUST match the server's
   advertised `version`. If it doesn't, reject and exit 100 (integration error).
   If `sha256` (full) was provided, SHOULD also verify the full hash.
6. **Smoke-test**: the downloaded artifact MUST be executed with a `version`
   command (or equivalent) and MUST produce valid output before it replaces the
   live binary. A truncated/corrupt download that passes the hash check (a
   self-consistent partial publish) is caught here.
7. **Atomic swap**:
   a. Move the current install to a `.bak` location.
   b. Move the new install into place.
   c. Set executable permissions.
   d. If the swap fails, restore from `.bak`.
8. **Persist version**: write the new version to a `VERSION` file (or equivalent)
   so the next check can compare without re-hashing the binary.
9. **Report**: print `{"ok":true,"updated":true,"from":"<old>","to":"<new>",...}`
   to stdout; print progress to stderr.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | success (updated or already up-to-date) |
| 5 | `--check` mode: update available (not an error) |
| 80 | invalid arguments |
| 100 | download/verification/smoke-test/swap failure (integration error) |

### Guarantees

- The update command MUST NOT leave the tool in a broken state. If any step
  fails after the swap has started, the `.bak` MUST be restored.
- The update command MUST NOT delete the `.bak` on success. The operator may
  want to roll back manually (`mv ~/.tool.bak ~/.tool`).
- The update command MUST be safe to run concurrently: a lock file or CAS guard
  SHOULD prevent two simultaneous updates from clobbering each other.

---

## 4. The passive nudge

On any command that hits the server (not on local-only commands like `version`,
`help`, `doctor`), the CLI SHOULD opportunistically fetch `/version` and compare.

- The nudge MUST go to **stderr** (stdout stays machine-parseable).
- The nudge MUST be **throttled**: at most once per hour per version (cache the
  last-check timestamp in the config directory).
- The nudge MUST be **best-effort**: if `/version` is unreachable, the CLI
  proceeds normally. The fetch SHOULD have a 3-second timeout.
- The nudge MUST NOT auto-update. It only prints a message:

```
[update] a newer myapp is available (a1b2c3d4e5f6 → f7e8d9c0b1a2). Run: myapp update
```

- The nudge MAY be disabled via an env var (`<TOOL>_NO_NUDGE=1`) or config.

---

## 5. The installer

A conforming tool SHOULD ship an installer (`install.sh` or equivalent) that:

- Downloads the artifact from the server.
- Computes `sha256[:12]` of the download.
- Extracts/installs to the tool's home directory (`~/.<tool>`).
- Writes the content-hash version to a `VERSION` file.
- Symlinks the CLI into `PATH`.
- Smoke-tests the installed binary (`<tool> version`).
- Prints a message telling users to run `<tool> update` for future updates.

---

## 6. Self-installation — `<tool> install` / `<tool> uninstall`

§5's `install.sh` gets the **first** copy of the binary onto a machine (it has no
binary to run yet, so it must fetch one). A conforming tool MAY additionally expose
`install`/`uninstall` subcommands that let a binary **already in hand** — however it
got there: `curl`, `go install`, a package manager, a colleague's `scp` — relocate
(or remove) itself to a stable location, with no separate script needed.

```
<tool> install [--prefix DIR]
<tool> uninstall [--prefix DIR]
```

### `install`

- MUST copy (not move or symlink) the **currently-running** binary to
  `<prefix>/<tool-name>` and set it executable. Copying means the original path
  (`./tool`, a `Downloads/` file, a build artifact) can be deleted or moved
  afterward without breaking the installed copy.
- Default `<prefix>` is `~/.local/bin` (no sudo; already on `$PATH` for most Linux
  desktop/dev setups and increasingly macOS). `--prefix DIR` overrides it.
- MUST be **idempotent**: installing over an existing install of the same tool
  overwrites and succeeds. It is not an error to install twice — an agent re-running
  a setup step should never see a false failure.
- MUST NOT require elevated privileges by default and MUST NOT silently invoke
  `sudo`. If `--prefix` points at a directory the process can't write to, it MUST
  fail with a clear, typed permission error (exit `90`) rather than escalating.
- MUST NOT modify shell rc files, `$PATH`, or any global config. It MAY print a
  one-line note on stdout/stderr if `<prefix>` is not currently on `$PATH`.
- MUST print a JSON result on stdout: `{"ok":true,"installed":"<full-path>"}`.

### `uninstall`

- MUST remove the file at `<prefix>/<tool-name>` (same default/`--prefix`
  resolution as `install`).
- MUST succeed as a **no-op** if the file doesn't exist —
  `{"ok":true,"removed":false,"path":"<full-path>"}`, exit `0` — not an error.
  Uninstalling twice, or uninstalling on a machine where the tool was never
  installed this way, is not a failure.
- On successful removal: `{"ok":true,"removed":true,"path":"<full-path>"}`.
- MUST NOT touch anything besides the binary at that path: no config directory, no
  data directory, no daemon/service registration (see the companion
  [cli-daemon-spec](https://github.com/javimosch/cli-daemon-spec) for daemon
  lifecycle, which is out of scope here). A tool MAY offer a separate, explicitly
  opt-in `--purge` flag to additionally remove its config/data directory — never
  the default, because deleting user data must never be a side effect of removing
  a binary.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | success (installed, uninstalled, or no-op uninstall) |
| 80 | invalid arguments (e.g. malformed `--prefix`) |
| 90 | permission denied writing to `--prefix` |

### Relationship to §5

A conforming `install.sh` SHOULD end by invoking `<tool> install` rather than
hand-duplicating the copy-to-`$PATH` logic — the script's job shrinks to "fetch a
runnable binary, then let it install itself."

---

## 7. What NOT to do

- **Don't auto-update without consent.** The default is manual (nudge only).
  Auto-update is opt-in.
- **Don't skip the hash verification.** A mid-deploy race can serve a partial
  file that passes a naive download but is corrupt.
- **Don't skip the smoke test.** The hash check catches truncation, but a
  self-consistent partial publish (file was hashed after being partially
  written) passes the hash check and still bricks the tool. Running
  `<tool> version` is the belt-and-suspenders.
- **Don't overwrite without a `.bak`.** If the swap fails or the new binary is
  bad, the operator needs a one-command rollback.
- **Don't block on the version check.** The nudge fetch is async/best-effort
  with a 3-second timeout. If `/version` is unreachable, the CLI proceeds
  normally.

---

## 8. Conformance summary

A **tool** conforms if it:

- serves `GET /version` per §2 (public, returns content-hash version + download path), **or**
  has a server that does so;
- exposes a `<tool> update` CLI command per §3 (verify-then-swap, smoke-test, `.bak`
  rollback, `--check` and `--force` flags);
- implements the passive nudge per §4 (stderr, throttled, best-effort, non-blocking);
- ships an installer per §5 that writes the content-hash version at install time.

Self-installation (§6) is independently adoptable: a tool MAY expose
`install`/`uninstall` without implementing the rest of this spec, and a tool that
does implement the rest of this spec MAY skip §6 if it has no standalone-binary
distribution story (e.g. it only ships as a Docker image).

A **server** conforms if it implements §2, computing the version from the actual
artifact on disk (not a manually-maintained version string).
