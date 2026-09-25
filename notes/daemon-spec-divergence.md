# bkn's `daemon` verbs diverge from the spec bkn cites

Found 2026-09-25 while porting cli-daemon-spec.

bkn's README claims conformance to
[cli-daemon-spec](https://cli-specs.intrane.fr). On the parts that matter most
it conforms exactly, and this build was written to match:

- `serve` announces on **stderr**, leaving stdout clean (§1)
- `GET /_health` answers `{"ok":true,"service":"bkn","pid":<real pid>}` (§2)
- `POST /_shutdown` answers `{"ok":true,"stopping":true}` **before** exiting (§3)

The `daemon` verbs are where the two part company. Measured against
`bin/bkn` built from `master`:

| §4 says | bkn does |
|---|---|
| `status` on a stopped daemon exits **3** | exits **0** |
| `{"ok":true,"daemon":"running","host":…,"port":N}` | `{"ok":true,"daemon":{"running":true,"host":…,"port":N,"pid":N,"url":…}}` |
| `{"ok":true,"daemon":"stopped"}` | `{"ok":true,"stopped":false,"was_running":false}` |
| `{"ok":true,"daemon":"started",…,"log":"<path>"}` | `{"ok":true,"daemon":{…},"log":"<path>"}` |

The exit code is the one that matters. §4 is explicit about why it is 3:

> distinct from `0` so a script can branch on `$?` without parsing JSON

bkn returns 0 for both states, so `bkn daemon status; echo $?` cannot tell a
running daemon from a stopped one — which is the single thing that exit code
exists to do.

**This build follows bkn, not the spec.** Being behaviourally interchangeable
with bkn is the job; a second implementation that "fixed" the difference would
diverge from the thing it exists to check, and the divergence would be
invisible rather than recorded. It is recorded here instead.

Whoever owns both gets to choose which moves. Either is defensible — the
shapes bkn returns are richer than the spec's — but they should not disagree
while the README cites the spec.
