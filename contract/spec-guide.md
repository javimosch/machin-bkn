# The guide convention — protocol

Version 1.0. The key words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are used as in
RFC 2119.

This document defines a small convention with two parts: a **CLI command** and,
optionally, **two HTTP endpoints**. A conforming tool implements the CLI command;
a conforming tool that runs an HTTP server SHOULD also implement the endpoints.

The goal: an agent (or human) with only the binary can learn the tool's full
mental model — model, loop, concepts, commands, examples, gotchas — in one call,
with no external docs and no network fetch.

---

## 1. The guide body

The guide is a JSON object. It is the single shared data structure of the
convention; the CLI command emits it and `GET /guide` serves it.

| Field | Type | Required | Notes |
|---|---|---|---|
| `<tool>` | string | **yes** | a one-line description of what the tool is |
| `one_liner` | string | **yes** | the elevator pitch — what it does and how, in 1-3 sentences |
| `model` | object | yes | the mental model: key/value pairs explaining the architecture, the split, the moving parts |
| `loop` | array of string | yes | the canonical end-to-end workflow, one step per element, in order |
| `concepts` | object | yes | key/value (or nested) definitions of the tool's vocabulary a reader must grasp |
| `commands` | object | yes | grouped command lists (e.g. `{"local": [...], "cloud": [...]}`); each entry is a usage string |
| `examples` | array of object | yes | each has a `goal` (string) and a `do` (array of command strings) |
| `gotchas` | array of string | yes | the things that bite — footguns, defaults that surprise, security notes |
| `version` | string | no | the tool's version at build time, so an agent can detect staleness |
| `see_also` | array of string | no | related commands (typically `help-json`, `version`) |

Receivers (agents parsing the JSON) MUST ignore unknown fields (forward
compatibility). A conforming emitter MAY add tool-specific fields beyond this
shape; the canonical JSON Schema is [`guide.schema.json`](guide.schema.json).

### Two flavors

The shape above is the **JSON agent-skill** flavor (structured, machine-parseable).
A conforming tool MAY instead emit a **markdown reference** flavor — a single
markdown string (or text block) that is the complete operator reference. In that
case the JSON body is `{"guide": "<markdown string>", "version": "..."}`. Both
flavors conform; the JSON agent-skill flavor is RECOMMENDED for agent-first
tools.

---

## 2. The CLI command — `<tool> guide`

A conforming tool exposes a `guide` subcommand:

```
<tool> guide [--human]
```

Behavior:

- **Default output is JSON** (agent-first). The body is per §1, wrapped in a
  success envelope appropriate to the tool (e.g.
  `{"result":"success","version":"1.0","guide":{...}}`). stdout = the guide.
- `--human` SHOULD produce a **readable markdown rendering** of the same content.
  A tool MAY omit `--human` if it emits only markdown (the markdown-only flavor).
- The guide MUST be **embedded in the binary** (a `//go:embed`, an in-source
  constant, or a compiled-in string). It MUST NOT fetch a URL at runtime — the
  guide travels with every install, online or offline.
- The command MUST exit `0` on success. It takes no arguments other than the
  output-format flag.
- The guide SHOULD be advertised in `help` and `help-json` (the command catalog)
  so an agent discovers it exists.

### What `guide` is NOT

- It is NOT `help`. `help` lists commands; `guide` teaches the model and the
  loop. A tool SHOULD have both.
- It is NOT a man page. It is structured (JSON) and agent-first; `--human` is the
  human fallback, not the primary form.
- It is NOT fetched. Embedding is mandatory; runtime network fetch is forbidden.

---

## 3. The HTTP endpoints (optional, for tools with a server)

A conforming tool that runs an HTTP server SHOULD serve two routes:

### `GET /guide`

- Returns the same JSON body as the CLI `guide` command (§1, in the tool's
  success envelope).
- `Content-Type: application/json; charset=utf-8`.
- No auth — the guide is public (it contains no secrets; it is documentation).
- This is the canonical URL an agent fetches when it only knows the host.

### `GET /llms.txt`

- Returns a **short text breadcrumb** (`Content-Type: text/plain; charset=utf-8`)
  that orients a fresh AI assistant: what the service is, the CLI command to run
  (or the `/guide` URL to fetch), and a 3-5 line quick start.
- It is the **front door**: an agent that only knows the domain fetches
  `/llms.txt` first, which points it at `/guide` for the full skill.
- It SHOULD name the CLI command (`<tool> guide`) as the alternative to the HTTP
  fetch, so an agent with the binary knows it can read the guide offline.

A tool without an HTTP server (a pure CLI) conforms with only the CLI command
(§2) and skips this section.

---

## 4. Versioning and staleness

- The guide body SHOULD include the tool's `version` (the same version reported
  by `<tool> version`).
- An agent reading the guide can compare this `version` against `<tool> version`
  to detect a stale guide (e.g. a binary updated but the embedded guide not
  rebuilt — should not happen with embedding, but the check is cheap).
- The guide content itself is not versioned separately from the tool; it is
  rebuilt and shipped with every release.

---

## 5. Conformance summary

A **tool** conforms if it:

- exposes a `guide` CLI command per §2 (JSON by default, embedded, no network
  fetch), with `--human` markdown RECOMMENDED;
- emits a body per §1 (JSON agent-skill flavor RECOMMENDED, markdown flavor
  allowed);
- advertises `guide` in its `help` / `help-json` command catalog.

A **tool with an HTTP server** additionally conforms if it serves `GET /guide`
(§3) and `GET /llms.txt` (§3). A pure-CLI tool conforms without them.
