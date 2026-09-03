#!/usr/bin/env python3
"""Reduce the interleaved run to medians and print the comparison.

Medians, not means: the write and script scenarios have tails measured in
seconds, and one 3-second outlier moves a mean of five samples by 600ms while
leaving the median untouched. The tail is reported separately as p99 rather
than being allowed to leak into the headline number.
"""
import json, statistics, sys
from collections import defaultdict

rows = defaultdict(list)
for line in open(sys.argv[1] if len(sys.argv) > 1 else '/tmp/bench-all.jsonl'):
    line = line.strip()
    if not line.startswith('{'):
        continue
    o = json.loads(line)
    rows[(o['label'], o['impl'])].append(o)

def med(rs, k):
    return statistics.median([r[k] for r in rs])

proc = {i: rows.get(('_process', i), []) for i in ('go', 'mfl')}
if proc['go'] and proc['mfl']:
    print("process")
    print(f"  {'':16} {'bkn (Go)':>14} {'machin-bkn':>14}")
    for k, lbl, unit in (('start_ms','cold start','ms'), ('idle_rss_kb','RSS idle','kB'), ('load_rss_kb','RSS under load','kB')):
        g, m = med(proc['go'], k), med(proc['mfl'], k)
        print(f"  {lbl:16} {g:>11.0f} {unit:<3}{m:>11.0f} {unit}")
    hooks = {i: {r['hook'] for r in proc[i]} for i in proc}
    blobs = {i: {r['blob_sha12'] for r in proc[i]} for i in proc}
    same = hooks['go'] == hooks['mfl'] and blobs['go'] == blobs['mfl']
    print(f"  identical outputs: {same}  (hook={hooks['go'] | hooks['mfl']}, blob={blobs['go'] | blobs['mfl']})")

order = ['kv-get','store-get','store-list','store-query','store-write','file-64k','hook-script']
print(f"\n{'scenario':14} {'bkn rps':>9} {'mfl rps':>9} {'ratio':>7}   "
      f"{'bkn p50':>8} {'mfl p50':>8}   {'bkn p99':>9} {'mfl p99':>9}   bad")
for label in order:
    g, m = rows.get((label,'go'), []), rows.get((label,'mfl'), [])
    if not g or not m:
        continue
    gr, mr = med(g,'rps'), med(m,'rps')
    bad = sum(r['non2xx'] for r in g) + sum(r['non2xx'] for r in m)
    flag = f"  <-- {sum(r['non2xx'] for r in m)} MFL failures" if sum(r['non2xx'] for r in m) else ""
    print(f"{label:14} {gr:9.0f} {mr:9.0f} {mr/gr:7.2f}x  "
          f"{med(g,'p50_ms'):8.2f} {med(m,'p50_ms'):8.2f}   "
          f"{med(g,'p99_ms'):9.1f} {med(m,'p99_ms'):9.1f}   {bad}{flag}")
print(f"\nn = {len(rows.get(('kv-get','go'), []))} interleaved repetitions per implementation")
