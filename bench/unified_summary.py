#!/usr/bin/env python3
"""Print medians table from bench/results/unified/*.json."""
import json, glob, statistics, os
RES = "bench/results/unified"
def load(f):
    raw = open(f).read()
    d = json.loads(raw[raw.index("{"):])["result"]
    rps = d.get("rps", {}).get("mean", 0)
    tot = sum(d.get(k, 0) for k in ("req1xx","req2xx","req3xx","req4xx","req5xx"))
    if tot == 0: return None
    lat = d.get("latency", {}).get("percentiles", {})
    return rps, lat.get("50"), lat.get("99")
cells = sorted({os.path.basename(os.path.dirname(f)) for f in glob.glob(f"{RES}/*/*.json")})
print(f"{'cell':<18}{'server':>9}{'req/s':>11}{'p50 µs':>10}{'p99 µs':>10}")
for cell in cells:
    per = {}
    for f in glob.glob(f"{RES}/{cell}/*.json"):
        srv = "zocket" if "zocket" in os.path.basename(f) else os.path.basename(f).split("_r")[0]
        try: r = load(f)
        except Exception: continue
        if r is None: continue
        per.setdefault(srv, []).append(r)
    for srv, rows in sorted(per.items()):
        med_r = statistics.median(x[0] for x in rows)
        med_p50 = statistics.median(x[1] for x in rows if x[1])
        med_p99 = statistics.median(x[2] for x in rows if x[2])
        print(f"{cell:<18}{srv:>9}{med_r:>11,.0f}{med_p50:>10.0f}{med_p99:>10.0f}")
