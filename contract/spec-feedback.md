# The feedback convention — protocol

Version 1.0. The key words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are used as in
RFC 2119.

This document defines a small convention with three parts: a **submission endpoint**, a
**CLI command**, and a **central relay**. A conforming tool implements the endpoint and the
CLI command; a conforming relay implements the endpoint plus an admin-gated read API.

---

## 1. The submission body

A feedback submission is a JSON object. It is the single shared data structure of the
convention; both the app endpoint and the relay accept it.

| Field | Type | Required | Notes |
|---|---|---|---|
| `message` | string | **yes** | the feedback text; empty/whitespace-only MUST be rejected |
| `app` | string | yes at the relay | short tool identifier, e.g. `"hart"`. An app's *own* endpoint MAY omit/ignore it (it knows what it is); the relay MUST record it |
| `version` | string | no | the tool's version at submission time |
| `kind` | string | no | one of `bug`, `idea`, `praise`, `note`. Unknown values SHOULD be preserved as-is; default `note` |
| `context` | string | no | what the user/agent was doing (free text) |
| `reporter` | string | no | who filed it — a username, `agent`, or an email |
| `id` | string | no | client-generated idempotency key; see §4 |

Receivers MUST ignore unknown fields (forward compatibility). Receivers SHOULD clamp
oversized fields rather than reject the whole submission (the reference relay clamps `app`
to 64, `version` to 32, `kind` to 24, `reporter` to 64, and `message`/`context` to the byte
cap).

The canonical JSON Schema is [`feedback.schema.json`](feedback.schema.json).

---

## 2. The submission endpoint — `POST /v1/feedback`

Both a conforming **app** and the **relay** expose this route.

- Request: `Content-Type: application/json`, body per §1.
- The endpoint is **open**: it MUST NOT require authentication to submit.
- The endpoint MUST enforce a **size cap** and MUST return `413 Payload Too Large` when the
  body exceeds it. Reference cap: 16384 bytes (`FEEDBACK_MAX_BYTES`).
- The endpoint MUST enforce a **rate limit** and SHOULD return `429 Too Many Requests` when
  exceeded. Reference: sliding 60-second per-IP window, 30/min (`FEEDBACK_MAX_PER_MIN`).
- Missing/empty `message` MUST return `400`.
- Storage MUST be **idempotent on `id`** (see §4).

### Success response

```json
{ "ok": true, "id": "<the stored id>", "stored": true }
```

The endpoint MUST echo the `id` it stored under (the client's `id`, or a server-generated
one if the client omitted it). `stored` is `true` on a successful insert *or* an idempotent
no-op (the record already existed) — both mean "the feedback is safely recorded".

### Error responses

`4xx`/`5xx` with a JSON body `{ "ok": false, "error": "<human-readable>" }`. Status codes:
`400` (bad input), `413` (too large), `429` (rate limited), `500` (storage failure).

---

## 3. The CLI command — `<tool> feedback`

A conforming tool exposes a `feedback` subcommand:

```
<tool> feedback "<message>" [-kind bug|idea|praise|note] [-context "<what you were doing>"]
```

Behavior:

- It MUST generate a fresh `id` (see §4) and build one submission body (§1), tagging `app`
  and `version` for the tool.
- `reporter` SHOULD default to the `USER` environment variable, falling back to `agent`.
- It **dual-writes**, in this order, both best-effort:
  1. **the app's own endpoint** — base URL from `<TOOL>_URL`, then `<TOOL>_PUBLIC_URL`,
     then a compiled-in default;
  2. **the relay** — base URL from `FEEDBACK_RELAY`, default `https://feedback.intrane.fr`.
     The literal value `off` MUST disable the relay write.
- Because both writes carry the **same `id`**, delivery is idempotent: a retry, or a tool
  that later syncs its local store to the relay, never double-counts.
- It **MUST NOT fail the caller.** A failed write is reported, not raised. The command
  SHOULD exit `0` even when both writes fail, and report which succeeded:

```json
{ "ok": true, "data": { "id": "…", "stored": 1, "relayed": 1 } }
```

(`stored`/`relayed` are `1`/`0` for the app endpoint and the relay respectively.)

A tool with **no local endpoint** (a peer tool, or a thin client) MAY implement a
**relay-only** variant: skip write (1), keep write (2). It still conforms.

---

## 4. Idempotency and the `id`

`id` is a client-generated opaque string (the reference tools use 16 random bytes hex-
encoded). It exists so the same logical submission is stored once regardless of how many
times it is delivered — across the dual-write, across retries, and across an app later
replaying its local store to the relay.

- The client SHOULD generate `id` and send it on both writes.
- If the client omits `id`, the server MUST generate one and return it.
- Storage MUST treat `id` as a primary key and MUST NOT overwrite an existing row
  (`INSERT OR IGNORE` semantics). A duplicate submit is a success, not an error.

---

## 5. Reading feedback — admin-gated

Submission is open; **reading is not**.

- `GET /v1/feedback?app=<app>&limit=<n>` MUST require a bearer token
  (`Authorization: Bearer <FEEDBACK_ADMIN_TOKEN>`) and return `403` otherwise.
- If no admin token is configured, reads MUST be **off** (`403`/`404`) — never open.
- Response: `{ "ok": true, "feedback": [ { …row… }, … ] }`, newest first. Rows SHOULD omit
  the submitter IP.
- A relay MAY additionally serve a cookie-authenticated HTML dashboard at `/`, gated by the
  same token.

---

## 6. Storage

The reference storage is a single SQLite table. An app endpoint stores its own feedback;
the relay stores all apps' and therefore keeps the `app` column.

```sql
CREATE TABLE IF NOT EXISTS feedback(
  id       TEXT PRIMARY KEY,   -- idempotency key (§4)
  app      TEXT DEFAULT '',    -- relay only; an app's own table MAY omit this
  version  TEXT DEFAULT '',
  kind     TEXT DEFAULT '',
  message  TEXT,
  context  TEXT DEFAULT '',
  reporter TEXT DEFAULT '',
  created  INTEGER,            -- unix seconds
  ip       TEXT DEFAULT ''
);
```

Any store with primary-key idempotency works; SQLite is a recommendation, not a
requirement.

---

## 7. Health

A conforming relay SHOULD expose `GET /_health` returning `200` with a small JSON body.

---

## 8. Conformance summary

A **tool** conforms if it:
- exposes `POST /v1/feedback` per §2 (open, capped, rate-limited, idempotent), **or** is a
  relay-only client (§3) with no local endpoint;
- exposes a `feedback` CLI command per §3 (dual-write, never-fail, `FEEDBACK_RELAY`
  honored);
- gates reads per §5 if it stores feedback.

A **relay** conforms if it implements §2, §4, §5, §6, and §7, recording `app` for every
submission.
