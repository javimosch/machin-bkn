# store — design notes (clean room, from the contract)

## Why almost everything happens in SQL

MFL has no generic JSON value: `parse()` requires a type witness, so there is
no `map[string]any` to hold an arbitrary document. Re-serialising a document
in MFL would mean hand-rolling a JSON model.

SQLite already has one, and machin's build includes **JSON1** (3.37.2,
verified). So documents live in a TEXT column and every operation the contract
describes is expressed as SQL:

| Contract requirement | How |
|---|---|
| filter on a document field | `json_extract(doc, ?)` |
| sort on a document field | `ORDER BY (json_extract(doc,?) IS NULL), json_extract(doc,?)` |
| id merged in on read | `json_set(doc, '$.id', id)` |
| id stripped on write | `json_remove(doc, '$.id')` |
| shallow patch merge | rebuild via `json_each` + `json_group_object` |
| normalizers | `lower()`/`upper()`/`trim()` inside `json_set`, gated on `json_type = 'text'` |

## Three traps, all found by testing rather than reading

**1. Binds are text-only.** `sqlite_exec/query` take `[]string`. With SQLite's
type affinity, `json_extract(doc,'$.price') > '20'` compares a number against
text and matches nothing — silently. Numbers must be cast in SQL:
`> CAST(? AS REAL)`. The parameter stays bound, so this is not an injection
shortcut.

**2. SQL errors are invisible.** `sqlite_query` returns `[]` for a syntax
error, an unknown function and a JSON parse failure alike — identical to "no
rows". A merge query that worked on `{"a":1}` returned `[]` on `{"a":"one"}`,
which reads as a data problem rather than a query problem.

**3. `json_each`'s `value` is not JSON for scalars.** It is the SQL value, so
a JSON string arrives unquoted and `json(value)` fails to parse it. The
re-wrap must branch on the `type` column:

```sql
CASE type WHEN 'object' THEN json(value) WHEN 'array' THEN json(value)
          WHEN 'true' THEN json('true') WHEN 'false' THEN json('false')
          ELSE value END
```

## The escaping round trip

`sqlite_query` returns rows as a JSON-array-of-rows **string**. A document
stored in a TEXT column therefore comes back as a JSON *string inside* that
array, escaped. `json_get` hands back the RAW token, still quoted and still
escaped. Every read of a document goes through `jsonString()`, which strips
the quotes and then unescapes — in that order.
