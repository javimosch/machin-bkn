# machin-bkn

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

| Variable | Purpose |
|---|---|
| `BKN_DATA` | datastore path (default `bkn.db`) |
| `BKN_HOST` / `BKN_PORT` | serve bind defaults (`127.0.0.1` / `7799`); flags win |
| `BKN_ADMIN_TOKEN` | bearer token gating every admin route |
| `BKN_ENCRYPTION_KEY` | 32 chars; required for `kv --type encrypted` |

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
| cli-output-spec | partial — `help-json`, stdout = data, exit codes `0/80/81/85/110`, typed errors over HTTP; CLI errors do not yet carry `type`/`recoverable`/`suggestions` |
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
test/               unit mains, the concurrency harness, seed-fixtures.sh
```

## License

MIT, the same as [bkn](https://github.com/javimosch/bkn).
