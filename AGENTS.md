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
