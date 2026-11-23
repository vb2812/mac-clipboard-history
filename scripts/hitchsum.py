#!/usr/bin/env python3
"""Clipboard History hitches inside a time window of an Animation Hitches trace.
usage: hitchsum.py <trace> [from_s] [to_s]  — resolves xctrace's id/ref back-references."""
import re, subprocess, sys
xml = subprocess.run(["xcrun", "xctrace", "export", "--input", sys.argv[1], "--xpath",
                      '/trace-toc/run[@number="1"]/data/table[@schema="hitches"]'], capture_output=True, text=True).stdout
lo, hi = (float(sys.argv[2]), float(sys.argv[3])) if len(sys.argv) > 3 else (0, 1e9)
seen = {}
raw = {}
def val(row, tag, numeric=False):
    m = re.search(rf'<{tag} id="(\d+)" fmt="([^"]*)">([^<]*)<', row)
    if m:
        seen[m[1]] = m[2]; raw[m[1]] = m[3]
        return m[3] if numeric else m[2]
    r = re.search(rf'<{tag} ref="(\d+)"', row)
    return (raw if numeric else seen).get(r[1]) if r else None
hits = []
for row in re.findall(r"<row>(.*?)</row>", xml, re.S):
    # register every id in the row so later refs resolve
    start = val(row, "start-time", True); dur = val(row, "duration", True); proc = val(row, "process")
    if not (start and dur and proc and "ClipboardHistory" in proc): continue
    t = int(start) / 1e9
    if lo <= t <= hi: hits.append(int(dur) / 1e6)
print(f"Clipboard History hitches in [{lo},{hi}]s: n={len(hits)} total={sum(hits):.0f}ms worst={max(hits, default=0):.1f}ms")
