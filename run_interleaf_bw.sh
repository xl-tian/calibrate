#!/bin/bash
# run_interleaf_bw.sh
# Robustly measure INTER-leaf (cross-spine) BANDWIDTH despite a busy cluster.
# Same approach as run_interleaf_latency.sh: pick a cleanly-idle node on each of two distinct
# leaves, submit the pinned bandwidth job (ibfinal.sh, which auto-detects inter-leaf and runs
# unidirectional + bidirectional ib_write_bw), confirm it actually STARTS, else re-pick.
#
# NOTE: a single cross-spine flow only reconfirms the per-link rate (~98 Gb/s); it does NOT
# prove the 1:1 non-blocking spine. For the bisection/non-blocking test use ibcong2.sh with
# ./pick_cross_leaf_pair.sh 3 (see ZARATAN_NETWORK_TOPOLOGY.md).
#
# Usage: ./run_interleaf_bw.sh        (env: MAX_TRIES, GRACE)
set -uo pipefail
cd "$(dirname "$0")"
MAX_TRIES=${MAX_TRIES:-12}
GRACE=${GRACE:-75}

for try in $(seq 1 "$MAX_TRIES"); do
  mapfile -t PAIR < <(./pick_cross_leaf_pair.sh 2 2>/dev/null)
  if [ "${#PAIR[@]}" -lt 2 ]; then
    echo "[try $try] no cross-leaf idle pair available yet; sleeping 30s..."; sleep 30; continue
  fi
  S=${PAIR[0]}; C=${PAIR[1]}
  echo "[try $try] candidate pair: $S <-> $C -> submitting ibfinal.sh (pinned, inter-leaf)"
  JID=$(sbatch --parsable -N2 --nodelist="$S,$C" --job-name=interbw --time=00:08:00 ibfinal.sh 2>/dev/null) \
    || { echo "  submit rejected"; sleep 15; continue; }

  started=0
  for ((t=0; t<GRACE; t+=5)); do
    st=$(squeue -j "$JID" -h -o "%T" 2>/dev/null)
    [ -z "$st" ] && { started=1; break; }
    [ "$st" = "RUNNING" ] && { started=1; break; }
    sleep 5
  done

  if [ "$started" -eq 1 ]; then
    echo "[try $try] job $JID started; waiting for completion..."
    while [ -n "$(squeue -j "$JID" -h -o '%T' 2>/dev/null)" ]; do sleep 5; done
    OUT="ibfinal.$JID.out"
    echo "=== RESULTS ($OUT) ==="
    grep -E "PAIR KIND|UNIDIR|BIDIR|CONCUR" "$OUT" 2>/dev/null
    if grep -q "INTER-LEAF" "$OUT" 2>/dev/null && grep -qE "UNIDIR|BIDIR" "$OUT" 2>/dev/null; then
      echo "$JID" > /tmp/j_interbw.txt; exit 0
    fi
    echo "  ran but pair wasn't inter-leaf or no data; retrying."
  else
    echo "[try $try] job $JID stuck PENDING ($(squeue -j "$JID" -h -o '%R' 2>/dev/null)); cancelling, re-picking."
    scancel "$JID" 2>/dev/null; sleep 10
  fi
done
echo "FAILED: no inter-leaf bandwidth measurement in $MAX_TRIES tries (cluster saturated)." >&2
exit 1
