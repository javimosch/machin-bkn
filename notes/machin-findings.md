# machin findings

Recorded while building machin-bkn. Each entry: what I expected, what happened,
the smallest reproduction.

## 1. FFI is bidirectional in practice, but undocumented

`machin guide` documents `extern` for MFL→C only; "function pointer" and
"callback" appear nowhere. That reads as "no host callbacks", which rules out
embedding any engine that needs them (QuickJS, Lua, a regex engine with a
callback API).

It is not true. User functions are emitted as non-static C symbols
`mfl_<name>_<n>`, so a linked C shim can call back in:

```c
extern int64_t mfl_mfl_double_0(int64_t x);   /* export func mfl_double(x) */
int64_t call_back_into_mfl(int64_t v) { return mfl_mfl_double_0(v) + 1; }
```

**Ask:** document the emitted symbol convention (or add an explicit
`callback`/`fnptr` type), so embedding a C library with callbacks is a
supported path rather than a discovery. Without it an agent reads the guide
and concludes, wrongly, that the whole class is impossible.

## 2. `export func` does not export for the native target

The guide describes `export func` under the wasm target. On native it changes
nothing observable — the symbol is non-static either way — so it reads like it
should produce a stable C name and does not. Mild: the mangled name works, but
`export` implying a stable ABI name would be the intuitive behaviour.

## 3. Parameter type annotations are a parse error, and the message misleads

`export func mfl_double(x int) (r int)` fails with:

```
[parse-expected] expected ")", got "int" at pos 25 in mfl_double (line 1)
```

Correct is `func mfl_double(x) (r)` — machin infers types. The diagnostic is
accurate but points at the symptom; for an agent arriving from Go, "machin
infers parameter types; drop the annotation" would save a cycle. `pos 25` also
does not line up with the offending token, which sent me looking at the
`cflags` string first.

## 4. `sqlite_query` has no error channel

Every failure returns `[]` — a syntax error, an unknown function, a JSON parse
failure inside the query — which is byte-identical to a successful query that
matched no rows.

```
sqlite_query(db, "SELCT bad")                  -> []
sqlite_query(db, "SELECT nonsense_function(1)") -> []
```

**Cost:** a shallow-merge query worked on `{"a":1,"b":2}` and returned `[]` on
`{"a":"one"}`. The first instinct is to doubt the data, not the SQL. Later, an
`IN` filter matched 2 rows instead of 3 because a bind was misaligned — again
reported as an ordinary empty result.

**Ask:** return the error. `json_get` and `http_request` are already
multi-assign `(value, err)`; `sqlite_query` could be `(rows, err)` the same
way. Without it, every SQL bug in an MFL program has the same symptom as no
data, and bisecting the query by hand is the only tool.

## 5. Binds are `[]string` only, and the failure is silent

`sqlite_exec/query` take `[]string`. SQLite orders every number before every
text, so `json_extract(doc,'$.price') > '20'` never matches — no error, just
zero rows.

Workaround: cast in SQL and keep the parameter bound — `> CAST(? AS REAL)`,
`= CAST(? AS INTEGER)` for JSON booleans. Do **not** interpolate the value
into the SQL string to dodge it.

**Ask:** a typed bind (`[]any`, or a `bind_int`/`bind_float` helper) would
remove a whole class of silently-wrong queries.

## 6. A multi-return function cannot be called as a statement

```
putDoc(db, ns, coll, id, doc)
  -> putDoc returns 2 values; use a multi-assignment (a, b := putDoc(...))
```

`_, _ = putDoc(...)` is required. The diagnostic is excellent — it names the
fix — but the constraint is stricter than Go, where discarding all results of
a call is allowed.

## 7. A type mismatch is reported against the wrong name

Passing a `bool` where a parameter was inferred as `string`:

```
error: type mismatch for 'rec' in "main": string vs bool — from "  FAIL " + label + ...
```

`rec` is an unrelated variable; the offending call was `expect(label, contains(...), true)`.
The snippet in the message is the right clue, the name is not.

## 8. Unreachable code is never typechecked

```
func dead() { println(chr(65)) }     // chr does not exist
func main() { println("alive") }
```
```
$ machin check spike.mfl   -> ok — no errors
$ machin build spike.mfl   -> built
```

Call `dead()` from `main` and both correctly report `[undefined-name]`.

So "check is clean" means "everything reachable from main is clean". A helper
written but not yet wired up is entirely unverified, and every error in it
arrives at once when you connect it. That is the worst moment for a batch of
surprises.

**Cost here:** `check` passed a file whose `urlDecode` called a nonexistent
`chr`, because the test's `main` never reached it. The error only surfaced
when the server's `main` did.

## 9. No `chr` builtin

`charat(string, int) -> string` exists; the reverse does not. Percent-decoding
a URL has no direct route. machin-bkn uses a literal table of printable ASCII
indexed by `code - 32`, which cannot reassemble UTF-8 above 126. SQLite's
`char(X)` works if a handle is already open.

## 10. `type` is a keyword and cannot name a struct field

```
type KvEntry struct { key string  value string  type string }
  -> [parse-expected] expected "", got "type"
```

Unavoidable for any table or document with a `type` column, which is common.
Workaround: alias in SQL (`SELECT type AS kind`) and name the field `kind`,
since `parse()` matches struct fields to column names. Worth a mention in the
guide's gotchas next to the existing `lambda-and-builtin-names` entry, which
covers the adjacent case (a function may not be named like a builtin).

## 11. String slicing `s[a:b]` typechecks, then emits invalid C

`machin check` accepts `base[0:semi]` where `base` is a string. Codegen then
treats it as a *slice* expression and emits `mfl_subslice(_sl, 0, semi,
sizeof(int64_t))` assigned to a `char *`, so `cc` fails with:

```
error: incompatible types when assigning to type 'char *' from type 'mfl_slice'
```

Reproduction:

```
func head(s, n) (out) {
  out = s
  if n > 0 { out = s[0:n] }
}
func main() { println(head("image/png; charset=x", 9)) }
```

`machin check` → ok. `machin build` → cc failure inside the generated C.

Workaround: `substr(s, 0, n)`. The gap is that the failure surfaces from the C
compiler with generated-code line numbers, not from the MFL frontend that
already had the type information to reject it — the one place where MFL's
"compile through C" leaks. Either the checker should reject slicing a string
or codegen should lower it to `substr`.

## 12. `machin check` only typechecks what is reachable from `main`

A function nothing calls is not checked at all — including calls to functions
that do not exist.

```
func never_called(x) (out) {
  a, b := totally_undefined(x)
  out = str(a) + b
}
func main() { println("hi") }
```

`machin check` → `ok — no errors`. Make `main` call `never_called` and the
same file fails with `[undefined-name] ... totally_undefined`.

This bit while building cron: `src/cron.mfl` called `runScript`, which had not
been written yet, and the whole tree checked clean because nothing had wired
the routes up to it. A library file appears correct right up until the moment
something uses it, which is the opposite of what a checker is for — the value
of checking a library is precisely that you have not written its caller yet.

Note the reachability rule is deliberate elsewhere (the wasm target treats
`export func` as a root, so a module needs no `main`). The gap is that there
is no way to ask for a whole-program check of a library: `--all` or treating
every top-level func as a root under `check` would close it.

## 13. Linking a C library that calls back into MFL: two rules, both undocumented

Embedding QuickJS meant a C archive that both *is called by* MFL and *calls*
MFL. Two things have to be right and neither is written down.

**1. `cflags` goes before the source; `link` goes after.** From `build.go`:

```go
// foreign linkage: extern cflags go before the source; -l libs after it
```

So an archive named in `cflags "-L… -lfoo"` is scanned *before* the object
file that defines the MFL symbols it needs, and every callback comes out
`undefined reference`. The `link "foo"` clause emits the same `-lfoo` after
the source, which is the only ordering that works:

```
extern "bknqjs" {
  cflags "-L/abs/path/vendor"
  link "bknqjs"
  link "m"
  fn bkn_js_eval(string, string, int, int) string
}
```

`link` is in the parser (`parser.go:227`) but not in the guide's `ffi-extern`
example, which shows `cflags "-lm"` — fine for libm, wrong for anything that
calls back.

**2. The callee must be `export func`, or dead-code elimination deletes it.**
MFL emits only functions reachable from `main` (see finding 12), and a
reference from a C file is invisible to that analysis. The C shim then fails
to link against a function that is right there in the source. `export func`
is documented for the wasm target ("reachability roots, so a wasm module needs
no main") and works identically on a native build:

```
export func hostCall(op, argsJSON) (out) { … }
```

Codegen renders it `char* mfl_hostCall_0(char* v_op, char* v_argsJSON)` —
non-static, so a linked C file can declare and call it. The `_0` suffix is an
implementation detail, so `build.sh` greps the emitted C for the exact
signature and stops with an explanation if it ever moves.

### And one shell trap, twice

`set -o pipefail` plus `grep -q` is a false negative generator: `grep -q`
exits at the first match, the writer takes SIGPIPE, and the pipeline reports
failure *because the match succeeded*. It bit here first as
`machin build --emit-c | grep -q` (read as "the compiler failed") and then
again as `printf '%s' "$C" | grep -q` after capturing the output to avoid it.
The fix is not to pipe at all: `[[ "$C" != *"needle"* ]]`.
