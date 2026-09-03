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
