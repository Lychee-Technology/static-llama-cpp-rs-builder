"""summarize.py <out-dir> <profile>: markdown table of old vs new peak RSS and encode time.

Reads <out-dir>/old.jsonl and new.jsonl from measure.sh. Fails (exit 1) unless both
versions encoded the same token sequences, the new build exposed no host logits and every
length has every rep. Writes <out-dir>/summary.json next to the markdown on stdout.
"""

import json
import math
import pathlib
import platform
import statistics
import struct
import sys

out, profile = pathlib.Path(sys.argv[1]), sys.argv[2]
runs = {label: [json.loads(line) for line in (out / f"{label}.jsonl").read_text().splitlines()]
        for label in ("old", "new")}
problems = []


def by_length(label):
    groups = {}
    for run in runs[label]:
        groups.setdefault(run["n_tokens"], []).append(run)
    return groups


def embedding(label, n):
    data = (out / f"{label}-{n}.f32").read_bytes()
    return struct.unpack(f"<{len(data) // 4}f", data)


old, new = by_length("old"), by_length("new")
rows = []
for n in sorted(old):
    o, w = old[n], new.get(n, [])
    if len(o) != len(w) or not o:
        problems.append(f"{n}: {len(o)} old runs vs {len(w)} new runs")
        continue
    hashes = {r["token_fnv1a"] for r in o + w}
    if len(hashes) != 1:
        problems.append(f"{n}: token sequences differ between versions: {sorted(hashes)}")
    if any(r["host_logits"] for r in w):
        problems.append(f"{n}: the new build exposed host logits")
    a, b = embedding("old", n), embedding("new", n)
    cosine = sum(x * y for x, y in zip(a, b)) / math.sqrt(sum(x * x for x in a) * sum(y * y for y in b))
    rows.append({
        "n_tokens": n,
        "reps": len(o),
        "old_max_rss_kib": max(r["time_v_max_rss_kib"] for r in o),
        "new_max_rss_kib": max(r["time_v_max_rss_kib"] for r in w),
        "old_vm_hwm_kib": max(r["vm_hwm_kib"] for r in o),
        "new_vm_hwm_kib": max(r["vm_hwm_kib"] for r in w),
        "old_encode_ms_median": statistics.median(r["encode_ms"] for r in o),
        "new_encode_ms_median": statistics.median(r["encode_ms"] for r in w),
        "old_host_logits": any(r["host_logits"] for r in o),
        "new_host_logits": any(r["host_logits"] for r in w),
        "embeddings_bit_identical": a == b,
        "embedding_cosine": cosine,
        "threads": o[0]["threads"],
    })

cpu = next((line.split(":", 1)[1].strip() for line in open("/proc/cpuinfo")
            if line.lower().startswith(("model name", "cpu part"))), "unknown")
summary = {"profile": profile, "machine": platform.machine(), "cpu": cpu,
           "old": runs["old"][0]["llama_cpp"], "new": runs["new"][0]["llama_cpp"], "rows": rows,
           "problems": problems}
(out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")

gib = 1024 * 1024
print(f"### Peak RSS, {profile} ({platform.machine()}, {cpu}, {rows[0]['threads'] if rows else '?'} threads)\n")
print(f"Old `{summary['old']}` (v0.1.159-2) vs new `{summary['new']}`. One pooled EmbeddingGemma 2 Q8_0 "
      "encode per fresh process (MEAN, non-causal, flash attention, n_ctx = n_batch = n_ubatch = 8192, "
      "n_seq_max = 1). Max of the reps of `/usr/bin/time -v` maximum RSS; median encode time.\n")
print("| Tokens | Old max RSS | New max RSS | Δ | Old encode | New encode | Host logits old → new | Embeddings |")
print("|---:|---:|---:|---:|---:|---:|:---:|:---|")
for r in rows:
    delta = (r["new_max_rss_kib"] - r["old_max_rss_kib"]) / 1024
    same = "bit-identical" if r["embeddings_bit_identical"] else f"cosine {r['embedding_cosine']:.8f}"
    print(f"| {r['n_tokens']} | {r['old_max_rss_kib']:,} KiB ({r['old_max_rss_kib'] / gib:.2f} GiB) "
          f"| {r['new_max_rss_kib']:,} KiB ({r['new_max_rss_kib'] / gib:.2f} GiB) | {delta:+,.0f} MiB "
          f"| {r['old_encode_ms_median']:,.0f} ms | {r['new_encode_ms_median']:,.0f} ms "
          f"| {str(r['old_host_logits']).lower()} → {str(r['new_host_logits']).lower()} | {same} |")
if problems:
    print("\n**Problems:** " + "; ".join(problems))
    sys.exit(1)
