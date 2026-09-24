# machin-bkn

**<https://javimosch.github.io/machin-bkn/>**

A clean-room reimplementation of [bkn](https://github.com/javimosch/bkn) in
**machin** (MFL) — one static binary that speaks the same CLI and HTTP contract
over the same embedded SQLite.

**It is not a product.** Its only job is to keep the first one honest: if bkn's
published contract is complete, an independent implementation built from that
contract alone should pass bkn's own test suite. It does.

```
191 / 191 assertions   across store, access, kv, auth, files, forms,
                       runtime, stripe, cms, headless and script access
```

It is also how **machin dogfoods itself**. Writing a real backend in MFL is
what turns a language gap from a theory into a bug report — this port has
produced several, including
[machin#672](https://github.com/javimosch/machin/issues/672) (`sqlite_query`
returns `[]` for a query that *failed*, indistinguishable from one that matched
nothing) and [machin#673](https://github.com/javimosch/machin/issues/673) (a
goroutine satisfies its own unbuffered channel send, so the keeper-lock idiom
spins at 100% CPU).

## The clean-room rule

Absolute, and the whole basis of the exercise:

> Never read `~/ai/bkn/**/*.go`, or any file under `~/ai/bkn/internal/`.

What may be read is the published contract — `contract/help-json.json`,
`contract/guide.json`, `contract/llms.txt`, the specs in `contract/spec-*.md`,
bkn's `test/` suite and `examples/`, and the live HTTP surface. See
[AGENTS.md](AGENTS.md) for the full discipline and [VISION.md](VISION.md) for
what bkn is trying to be.

A gap found here is therefore a gap in the **contract**, not in the port: it
means something real was only ever written down in Go.

## Build

Needs the [machin](https://github.com/javimosch/machin) compiler and
`libssl-dev` (static archives, for `--static`).

```sh
./build.sh cmd/serve.mfl -o bin/bkn
```

QuickJS is vendored and linked as a static archive, so the result is a single
file with no runtime dependencies.

## Run

```sh
export BKN_DATA=bkn.db
export BKN_ADMIN_TOKEN=$(openssl rand -hex 16)
export BKN_ENCRYPTION_KEY=$(openssl rand -hex 16)   # for kv --type encrypted

bin/bkn serve --host 127.0.0.1 --port 7799
bin/bkn guide            # the whole mental model, embedded in the binary
bin/bkn help-json        # the command catalog
```

Rotating the encryption key needs no downtime: add the new key to the set,
point the id at it, and rewrite what is already sealed. Values keep the id
they were sealed under until they are rewritten, and anything `rekey` cannot
open is counted and **left untouched** rather than destroyed.

```sh
export BKN_ENCRYPTION_KEYS="v1:$OLD,v2:$NEW"
export BKN_ENCRYPTION_KEY_ID=v2
bin/bkn kv rekey
```

| Variable | Purpose |
|---|---|
| `BKN_DATA` | datastore path (default `bkn.db`) |
| `BKN_HOST` / `BKN_PORT` | serve bind defaults (`127.0.0.1` / `7799`); flags win |
| `BKN_ADMIN_TOKEN` | bearer token gating every admin route |
| `BKN_ENCRYPTION_KEY` | 32 chars; required for `kv --type encrypted`. Always stamps key id `v1` |
| `BKN_ENCRYPTION_KEYS` | the SET of keys that may decrypt, as `id:material` pairs — `"v1:$OLD,v2:$NEW"` |
| `BKN_ENCRYPTION_KEY_ID` | which of them seals new values (default `v1`) |

## A live one

<https://machin-bkn.vps1.intrane.fr> — point bkn's own suite at it rather than
take the numbers on trust:

```sh
curl -s https://machin-bkn.vps1.intrane.fr/llms.txt

cd ~/ai/bkn/test
SP=$PWD BKN_TEST_URL=https://machin-bkn.vps1.intrane.fr bash t-store.sh
```

`./test/deploy-gate.sh --on-host` runs the whole **191** against it in one
command, in two parts: 172 over HTTPS against the instance, and
`t-scriptaccess`'s 19 against the deployed binary. That suite starts its own server with its
own throwaway database, because a script can only be created by the CLI on
the machine holding the data — running it against the live instance would
mean leaving a publicly-runnable fixture script on a public host, and its
last act closes a script it opened, so the gate would mutate the deployment
on every run.

`--on-host` ships the suite to the server and runs the HTTPS half from there.
Same TLS, same Traefik, same routing — it only drops the client's last mile,
which is where the flakiness lives. Run from a laptop this gate saw stalls of
ten and thirty seconds and the odd empty body; from the host, 200 requests ran
with a median of 0.08s and nothing over a second. The Go bkn behind the same
Traefik stalled too, which is what ruled the server out.

It holds the test fixtures and nothing else, every admin route is behind a
token, and it binds the host's docker bridge rather than a public address —
Traefik terminates TLS and is the only way in.

## Verifying it against the contract

bkn's suites were written against its **live** instance and assume data seeded
there by hand, so they must be seeded before a score means anything:

```sh
export BKN_DATA=/tmp/t.db BKN_ADMIN_TOKEN=tok BKN_ENCRYPTION_KEY=$(printf 'a%.0s' {1..32})
./test/seed-fixtures.sh bin/bkn ~/ai/bkn/examples ~/ai/bkn/test
echo -n "$BKN_ADMIN_TOKEN" > ~/ai/bkn/test/admin.tok    # dog.sh reads THIS file
bin/bkn serve --host 127.0.0.1 --port 7799 &

cd ~/ai/bkn/test
SP=$PWD BKN_TEST_URL=http://127.0.0.1:7799 bash t-store.sh
```

Two things bite, both of them harness rather than port:

- `dog.sh` reads the admin token from **`$SP/admin.tok`**, not
  `$BKN_ADMIN_TOKEN`. A mismatch turns every write into a 403 and cascades into
  failures that look like missing features.
- `t-scriptaccess.sh` starts its **own** instance, because a script can only be
  created by the CLI on the machine holding the data. Point it at the binary:
  `BKN_BIN=bin/bkn bash t-scriptaccess.sh`.

One assertion a freshly seeded database cannot satisfy on the first run:
t-stripe's *"event ledger grew"* wants ≥ 4 ledgered events and one run writes
three, because the live instance it was written against had history. Run it
twice.

## Conformance

Built to the agent-first CLI spec family — <https://cli-specs.intrane.fr>.
This is a verification instrument rather than a distributed tool, so the specs
that exist to ship and support a *product* are deliberately out of scope.

| Spec | Status |
|---|---|
| cli-output-spec | **yes** — stdout = data, `help-json`, a `version` on every success, and typed errors whose `code` equals the exit code (`80/85/92/95/110`) with `type`, `recoverable` and suggestions |
| cli-guide-spec | **yes** — `bkn guide [--human]` (embedded, never fetched), `GET /guide`, `GET /llms.txt` |
| cli-daemon-spec | partial — `serve --host --port` (loopback default), `GET /_health`; no `/_shutdown`, no `daemon start\|stop\|status` |
| cli-update-spec | **out of scope** — nothing here is distributed, so there is nothing to self-update |
| cli-feedback-spec | **out of scope** — feedback on the contract belongs on bkn |
| cli-telemetry-spec | **out of scope** — a test instrument counting its own runs measures nothing |

## Layout

```
cmd/serve.mfl       routing and main()
src/                store, access, auth, kv, files, events, cron, hooks,
                    script (QuickJS host), guide, ulid, http, cli
vendor/             QuickJS + the C bridge
contract/           bkn's published contract — the ONLY legitimate source
test/               unit mains, the concurrency harness, seed-fixtures.sh,
                    and the CLI suites the contract cannot reach:
                    catalog.sh, auth-cli.sh, cli-surface.sh
```

## License

MIT, the same as [bkn](https://github.com/javimosch/bkn).
