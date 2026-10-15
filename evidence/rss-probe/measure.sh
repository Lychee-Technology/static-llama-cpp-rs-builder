#!/usr/bin/env bash
# measure.sh <label> <static-llama-dir> <model.gguf> <out-dir> [reps] [lengths]
# Builds rss-probe against one archive set, then runs one FRESH process per (length, rep)
# under /usr/bin/time -v. Appends one JSON line per run to <out-dir>/<label>.jsonl and keeps
# the last pooled embedding of each length as <out-dir>/<label>-<n>.f32.
set -euo pipefail
label="$1" dir="$2" model="$3" out="$4" reps="${5:-3}" lengths="${6:-14 1024 4074 8192}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "${out}"
out="$(cd "${out}" && pwd)" dir="$(cd "${dir}" && pwd)"
export STATIC_LLAMA_DIR="${dir}" CARGO_TARGET_DIR="${out}/target-${label}"
cargo build --release --quiet --manifest-path "${here}/Cargo.toml"
bin="${CARGO_TARGET_DIR}/release/rss-probe"
tag="$(jq -r '.llama_cpp.tag + "@" + .llama_cpp.commit[:8]' "${dir}/build-info.json")"
: > "${out}/${label}.jsonl"
for n in ${lengths}; do
  for rep in $(seq 1 "${reps}"); do
    RSS_EMBEDDING_OUT="${out}/${label}-${n}.f32" \
      /usr/bin/time -v -o "${out}/time.txt" "${bin}" "${model}" "${n}" > "${out}/probe.json" 2> "${out}/probe-${label}-${n}.log"
    maxrss="$(sed -n 's/^[[:space:]]*Maximum resident set size (kbytes): //p' "${out}/time.txt")"
    wall="$(sed -n 's/^[[:space:]]*Elapsed (wall clock) time (h:mm:ss or m:ss): //p' "${out}/time.txt")"
    jq -c --arg label "${label}" --arg tag "${tag}" --argjson rep "${rep}" \
       --argjson maxrss "${maxrss}" --arg wall "${wall}" \
       '{label: $label, llama_cpp: $tag, rep: $rep} + . + {time_v_max_rss_kib: $maxrss, time_v_wall: $wall}' \
       "${out}/probe.json" | tee -a "${out}/${label}.jsonl"
  done
done
