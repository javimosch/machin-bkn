# machin-bkn — clean-room reimplementation of bkn in MFL

## The discipline

This is a **clean-room** implementation. The rule is absolute:

> Never read `~/ai/bkn/**/*.go`, or any file under `~/ai/bkn/internal/`.

What may be read, and is the whole basis of this work:

| Source | Why it is legitimate |
|---|---|
| `contract/help-json.json` | the machine-readable command catalog — literally designed as the contract |
| `contract/guide.json` | the embedded mental model, concepts, gotchas, examples |
| `contract/llms.txt` | the public front door |
| `contract/spec-*.md` | the six agent-first CLI spec protocols |
| `~/ai/bkn/test/` | the acceptance gate — 113 assertions |
| `~/ai/bkn/examples/*.js` | userland scripts the suite runs; consumers of the contract, not internals |
| the live HTTP surface | observable behaviour of a deployed instance |

Reading the reference implementation would make this a translation. Working
from the contract means the suite tests **the specification**, which is worth
far more: anywhere the two implementations differ, one of them has found an
ambiguity in the spec.

## The gate

Done is: `~/ai/bkn/test/` passes **unmodified** against this build.

```sh
export SP=~/ai/bkn/test BKN_TEST_URL=https://<this build>
for t in store kv auth files runtime stripe forms cms headless; do
  bash "$SP/t-$t.sh"
done
```

113 assertions. `BKN_TEST_URL` moves the address only; no assertion changes.

`SP` must point at `~/ai/bkn/test` — the committed harness. Pointing it at a
copy elsewhere silently runs an older `dog.sh`, which still targets the live
Go deployment: the suite then reports failures that belong to a different
server. That wasted a debugging cycle here.

### Score

| Suite | machin build |
|---|---|
| `t-store.sh` | **16 / 16** |
| `t-kv.sh` | **7 / 7** |
| everything else | not yet implemented |

The kv wire format is verified **interoperable with Node's crypto in both
directions**, not merely self-consistent — a clean-room implementation that
only round-trips through itself would pass the suite while being unable to
read the reference implementation's data.

## What machin gives us, verified not assumed

`machin guide` (v0.137.0) — 181 builtins. Checked against what the contract needs:

| Need | machin | note |
|---|---|---|
| datastore | `sqlite_open/exec/query/close` | native |
| encrypted kv | `aes_gcm_encrypt/decrypt` | exactly the payload shape the contract names |
| signatures | `hmac_sha256`, `sha256`, `to_hex`, `base64_*` | native |
| randomness | `rand_bytes` | native |
| HTTP server | `listen`, `http_request`, `http_body` | machweb |
| password hashing | `pbkdf2_sha256` | **no bcrypt** — see below |
| JS sandbox | none | **QuickJS via FFI** — see below |

### bcrypt is absent, and that is fine

The contract never names a password hashing algorithm. The suite asserts only
that a hash never appears in a response (`no password hash in payload`, which
greps for `$2a$`). pbkdf2-sha256 satisfies the contract. This is the first
place where clean-room beats translation: a port would have copied bcrypt
because the original had it.

### The script sandbox: QuickJS through the FFI

machin has no JS engine, and its FFI is documented as one-directional
(`extern` lets MFL call C). A sandbox needs the reverse — the engine calling
host functions back into MFL.

It turns out to work. MFL compiles user functions to **non-static** C symbols
named `mfl_<name>_<n>`, so a linked C shim can declare and call them.
Verified:

```c
extern int64_t mfl_mfl_double_0(int64_t x);
int64_t call_back_into_mfl(int64_t v) { return mfl_mfl_double_0(v) + 1; }
```
```
$ machin run spike.mfl
41
```

This is undocumented and the mangling is an implementation detail of the
compiler, so it is pinned by a build-time check rather than trusted.

## Dogfooding machin

Every MFL gap, bug or rough edge found while building this goes in
`notes/machin-findings.md`, with a minimal reproduction. That is half the
point of doing it in machin.

## Score

| suite | assertions | state |
|---|---|---|
| store | 16 | pass |
| kv | 7 | pass |
| auth | 14 | pass |
| files | 12 | pass |
| runtime | 14 | 10 pass, 4 blocked on the script sandbox |

59 of 113.

The four blocked assertions (`cron run over HTTP`, `scheduler fired it`,
`script run + value`, `sandbox surface`) all fail for one reason: `runScript`
in `src/script.mfl` has no evaluator. Everything around it — the registry, run
history, the scheduler, event emission, the HTTP routes — is finished and
exercised: the scheduler fires `dogtick` on time and records `cron.error`
events with the runtime's own explanation. The sandbox phase replaces one
function body.

## Gate runbook (auth needs CLI setup before the server starts)

```bash
export BKN_DATA=/tmp/mbkn.db BKN_AUTH_SECRET=... BKN_ENCRYPTION_KEY=$(openssl rand -hex 32)
mbkn auth org create dogcorp --name "Dog Corp"
echo -n dogfood-password-1 | mbkn auth user create ada@dog.io --password-stdin --name Ada
echo -n dogfood-password-2 | mbkn auth user create bob@dog.io --password-stdin
mbkn auth member add dogcorp ada@dog.io --role owner
mbkn auth member add dogcorp bob@dog.io --role member
mbkn files ns create dogpub --allow-type image/png --public
mbkn files ns create dogpriv --allow-type text/html
mbkn script create dogjob --file dogjob.js --description "dogfood probe"
mbkn cron create dogtick --schedule '@every 3s' --script dogjob
BKN_PORT=48200 BKN_ADMIN_TOKEN=dogfood mbkn serve &
```

Killing a stale server: `pgrep -x mbkn | xargs -r kill`. Do **not** match on
the command line from the agent's own shell — neither `pkill -f <pattern>` nor
`pgrep -af '<pattern>' | xargs kill` — the pattern matches the
wrapper command line that contains it, so pkill kills the shell (exit 144)
and the stale server survives. A surviving server is the failure mode that
looks like a code regression: it holds the port, the new binary's bind fails,
and the suite silently tests the *old* process against the *old* database.
