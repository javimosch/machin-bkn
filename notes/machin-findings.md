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
