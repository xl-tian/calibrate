#!/bin/bash
# run_interleaf_latency.sh
# Robustly measure INTER-leaf (cross-spine, 3-hop) latency despite a busy cluster.
# Strategy: pick a cleanly-idle node on each of two distinct leaves, submit the pinned
# latency job, and confirm it actually STARTS within a grace window; if the scheduler
# refuses (nodes got grabbed / drained — the race that blocked the original run), cancel
# and retry with a fresh pick. Repeat up to MAX_TRIES.
#
# Usage: ./run_interleaf_latency.sh
# Produces: iblat2.inter.<jobid>.out  with ib_write_lat/ib_send_lat/ib_read_lat tables.
set -uo pipefail
cd "$(dirname "$0")"
MAX_TRIES=${MAX_TRIES:-12}
GRACE=${GRACE:-75}          # seconds to wait for a submitted job to leave PENDING

for try in $(seq 1 "$MAX_TRIES"); do
  mapfile -t PAIR < <(./pick_cross_leaf_pair.sh 2 2>/dev/null)
  if [ "${#PAIR[@]}" -lt 2 ]; then
    echo "[try $try] no cross-leaf idle pair available yet; sleeping 30s..."; sleep 30; continue
  fi
  S=${PAIR[0]}; C=${PAIR[1]}
  echo "[try $try] candidate pair: server=$S client=$C -> submitting"
  JID=$(sbatch --parsable -N2 --nodelist="$S,$C" --job-name=inter --time=00:05:00 \
        --export=ALL,S="$S",C="$C",LBL=INTER-3hop iblat2.sh 2>/dev/null) || { echo "  submit rejected"; sleep 15; continue; }

  # wait for it to start (leave PENDING) within GRACE seconds
  started=0
  for ((t=0; t<GRACE; t+=5)); do
    st=$(squeue -j "$JID" -h -o "%T" 2>/dev/null)
    [ -z "$st" ] && { started=1; break; }                 # already finished
    [ "$st" = "RUNNING" ] && { started=1; break; }
    sleep 5
  done

  if [ "$started" -eq 1 ]; then
    echo "[try $try] job $JID started; waiting for completion..."
    while [ -n "$(squeue -j "$JID" -h -o '%T' 2>/dev/null)" ]; do sleep 5; done
    OUT="iblat2.inter.$JID.out"
    echo "=== RESULTS ($OUT) ==="
    grep "LABEL=" "$OUT" 2>/dev/null
    grep -E "^ *2 +20000" "$OUT" 2>/dev/null && { echo "$JID" > /tmp/j_inter.txt; exit 0; }
    echo "  job ran but no data rows; retrying."
  else
    echo "[try $try] job $JID stuck PENDING ($(squeue -j "$JID" -h -o '%R' 2>/dev/null)); cancelling, re-picking."
    scancel "$JID" 2>/dev/null
    sleep 10
  fi
done
echo "FAILED: could not obtain an inter-leaf measurement in $MAX_TRIES tries (cluster saturated)." >&2
exit 1
