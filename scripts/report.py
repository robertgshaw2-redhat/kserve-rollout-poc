"""Turn probe.log + timeline.tsv + splits.tsv into the zero-downtime verdict."""
import sys, gzip, pathlib, collections

res = pathlib.Path(sys.argv[1])
# The captured run is committed gzipped; a live run writes plain text.
log = res / "probe.log"
text = (gzip.open(str(log) + ".gz", "rt").read() if not log.exists()
        else log.read_text())
reqs = []
for line in text.splitlines():
    f = line.split()
    if len(f) == 4 and f[0].isdigit():
        reqs.append((int(f[0]), f[2], float(f[3])))
reqs.sort()
marks = [(int(a), b) for a, b in
         (l.split("\t") for l in (res / "timeline.tsv").read_text().splitlines() if l)]

out = []
ok = [r for r in reqs if r[1] == "200"]
bad = [r for r in reqs if r[1] != "200"]
out.append("REQUESTS")
out.append(f"  total          {len(reqs)}")
out.append(f"  http 200       {len(ok)}")
out.append(f"  non-200        {len(bad)}")
if reqs:
    span = (reqs[-1][0] - reqs[0][0]) / 1000
    out.append(f"  window         {span:.0f}s  ({len(reqs)/max(span,1):.1f} req/s)")
    lat = sorted(r[2] for r in ok)
    if lat:
        out.append(f"  latency p50/p99  {lat[len(lat)//2]:.2f}s / {lat[int(len(lat)*.99)]:.2f}s")
if bad:
    codes = collections.Counter(r[1] for r in bad)
    out.append(f"  failure codes  {dict(codes)}")

# Longest gap between consecutive successful responses = worst-case stall.
gaps = [(ok[i][0] - ok[i-1][0]) / 1000 for i in range(1, len(ok))]
if gaps:
    out.append(f"  max gap between successes  {max(gaps):.2f}s")

out.append("")
out.append("PER-REQUEST STATUS BY PHASE  (phases delimited by timeline marks)")
for i, (ts, label) in enumerate(marks):
    end = marks[i+1][0] if i + 1 < len(marks) else float("inf")
    win = [r for r in reqs if ts <= r[0] < end]
    codes = collections.Counter(r[1] for r in win)
    dur = (min(end, reqs[-1][0]) - ts) / 1000 if reqs else 0
    out.append(f"  {label:<24} {dur:6.0f}s  n={len(win):<5} {dict(codes) or '-'}")

splits = [l.split("\t") for l in (res / "splits.tsv").read_text().splitlines() if l]
if len(splits) > 1:
    out.append("")
    out.append("OBSERVED TRAFFIC SPLIT  (delta of vllm:request_success_total per version)")
    out.append(f"  {'phase':<34}{'v1':>8}{'v2':>8}{'ratio':>14}")
    for a, b in zip(splits, splits[1:]):
        d1, d2 = int(b[2]) - int(a[2]), int(b[3]) - int(a[3])
        # A counter that goes backwards means that version's pods were replaced
        # (stop/restart), so the vLLM counters reset -- the delta is meaningless.
        if d1 < 0 or d2 < 0:
            out.append(f"  {a[1]+' -> '+b[1]:<34}{'':>8}{'':>8}{'counters reset':>14}")
            continue
        tot = d1 + d2
        ratio = f"{100*d1/tot:.0f}% / {100*d2/tot:.0f}%" if tot else "-"
        out.append(f"  {a[1]+' -> '+b[1]:<34}{d1:>8}{d2:>8}{ratio:>14}")
print("\n".join(out))
