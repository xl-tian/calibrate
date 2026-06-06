#!/bin/bash
# pick_cross_leaf_pair.sh
# Prints N node names, each on a DISTINCT leaf switch, that are CLEANLY idle
# (state exactly "idle", not comp/drain/mix) and NOT inside any Slurm reservation.
# Usage: ./pick_cross_leaf_pair.sh [num_leaves]   (default 2)
# Exit 0 and print the nodes (one per line) on success; exit 1 if not enough leaves free.
set -euo pipefail
WANT=${1:-2}
PART=${PART:-standard}
TOP=/etc/slurm/topology.conf

# 1) Nodes currently inside ANY reservation (expanded to host names)
RES=$(scontrol show reservation -o 2>/dev/null \
      | grep -oP 'Nodes=\K[^ ]+' \
      | while read -r nl; do [ -n "$nl" ] && [ "$nl" != "(null)" ] && scontrol show hostnames "$nl" 2>/dev/null; done \
      | sort -u || true)

# 2) Cleanly-idle nodes in the partition (sinfo -t idle excludes comp/drain/alloc/mix)
IDLE=$(sinfo -p "$PART" -t idle -h -o "%n" 2>/dev/null | sort -u)

# 3) Map each leaf -> first cleanly-idle, non-reserved node on it
declare -A PICK
leaf_of(){ awk -v node="$1" '
  /^SwitchName=.*Nodes=/ && !/Switches=/{
    sw=$1; sub(/SwitchName=/,"",sw); nl=$2; sub(/Nodes=/,"",nl);
    cmd="scontrol show hostnames "nl" 2>/dev/null";
    while((cmd|getline h)>0){ if(h==node){print sw; exit} } close(cmd) }' "$TOP"; }

for n in $IDLE; do
  grep -qxF "$n" <<<"$RES" && continue          # skip reserved
  # sinfo -t idle also returns IDLE+DRAIN nodes; require the exact short state to be "idle"
  st=$(sinfo -n "$n" -h -o "%t" 2>/dev/null | head -1)
  [ "$st" = "idle" ] || continue                # reject drain/comp/mix/idle*/alloc
  L=$(leaf_of "$n"); [ -z "$L" ] && continue
  [ -n "${PICK[$L]:-}" ] && continue            # one node per leaf
  PICK[$L]=$n
done

if [ "${#PICK[@]}" -lt "$WANT" ]; then
  echo "ERROR: only ${#PICK[@]} leaf(es) have a cleanly-idle non-reserved node; need $WANT." >&2
  echo "Leaves currently usable:" >&2
  for L in "${!PICK[@]}"; do echo "  $L -> ${PICK[$L]}" >&2; done
  exit 1
fi

# Print WANT nodes on distinct leaves
i=0
for L in "${!PICK[@]}"; do
  echo "${PICK[$L]}"
  i=$((i+1)); [ "$i" -ge "$WANT" ] && break
done
