#!/bin/bash
#SBATCH --job-name=interleaf
#SBATCH --partition=standard
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=8G
#SBATCH --time=00:20:00
#SBATCH --exclude=compute-b8-[21-52,54-60]
#SBATCH --output=interleaf.%j.out
#
# Self-contained inter-leaf (cross-spine) latency + bandwidth measurement.
#
# WHY THIS WORKS where login-node pinning failed:
#   * A pending job waits in the queue indefinitely and gains priority, so it WILL eventually be
#     scheduled even on a saturated cluster (no need to keep a polling loop alive on the login node).
#   * --time is SHORT (20 min) on purpose: short jobs backfill into gaps far more easily. Queue wait
#     is unbounded regardless, so "wait as long as needed" is automatic — it is NOT the walltime.
#   * --exclude of leaf d85b00 (compute-b8-[21-52,54-60]) stops Slurm from packing all nodes onto
#     that one always-free leaf; the remaining scattered free nodes land on DIFFERENT leaves, which
#     is exactly the cross-spine pair we need. The job then auto-detects leaves and measures.
#
# Self-test (no Slurm needed):  SELFTEST=1 MOCK_NODES="n1 n2 n3" MOCKMAP="n1:LA n2:LB n3:LA" bash interleaf_job.sh
set -uo pipefail
DEV=${DEV:-mlx5_0}
TOP=/etc/slurm/topology.conf

# Map a node -> its leaf-switch GUID. In SELFTEST mode, read from MOCKMAP ("node:leaf" space list).
leaf_of(){
  if [ "${SELFTEST:-0}" = 1 ]; then
    local n="$1"; for kv in $MOCKMAP; do [ "${kv%%:*}" = "$n" ] && { echo "${kv##*:}"; return; }; done; return
  fi
  awk -v node="$1" '/^SwitchName=.*Nodes=/ && !/Switches=/{
    sw=$1; sub(/SwitchName=/,"",sw); nl=$2; sub(/Nodes=/,"",nl);
    cmd="scontrol show hostnames "nl" 2>/dev/null";
    while((cmd|getline h)>0){ if(h==node){print sw; exit} } close(cmd) }' "$TOP"
}

# Given a leaf-switch GUID, print its Nodes= expression (e.g. compute-b5-[21-60]) for --exclude.
leaf_nodes(){ awk -v g="$1" '$1=="SwitchName="g{for(i=1;i<=NF;i++) if($i ~ /^Nodes=/){s=$i; sub(/Nodes=/,"",s); print s}}' "$TOP"; }

# Given the global NODES array + LEAF map, choose an intra-leaf pair and an inter-leaf pair.
pick_pairs(){
  INTRA_S=""; INTRA_C=""; INTER_S=""; INTER_C=""
  local i j a b
  for ((i=0;i<${#NODES[@]};i++)); do for ((j=i+1;j<${#NODES[@]};j++)); do
    a=${NODES[$i]}; b=${NODES[$j]}
    if [ "${LEAF[$a]}" = "${LEAF[$b]}" ] && [ -z "$INTRA_S" ]; then INTRA_S=$a; INTRA_C=$b; fi
    if [ "${LEAF[$a]}" != "${LEAF[$b]}" ] && [ -z "$INTER_S" ]; then INTER_S=$a; INTER_C=$b; fi
  done; done
}

# Build NODES + LEAF
if [ "${SELFTEST:-0}" = 1 ]; then
  NODES=($MOCK_NODES)
else
  NODES=($(scontrol show hostnames "$SLURM_JOB_NODELIST"))
fi
declare -A LEAF
for n in "${NODES[@]}"; do LEAF[$n]=$(leaf_of "$n"); done
pick_pairs

echo "=== allocation leaf map ==="
for n in "${NODES[@]}"; do echo "  $n -> ${LEAF[$n]}"; done
echo "INTRA pair: ${INTRA_S:-none} <-> ${INTRA_C:-none}"
echo "INTER pair: ${INTER_S:-none} <-> ${INTER_C:-none}"

if [ "${SELFTEST:-0}" = 1 ]; then echo "(selftest: stopping before measurement)"; exit 0; fi

RESULT="interleaf_results.${SLURM_JOB_ID}.txt"
{ echo "# inter-leaf measurement  job=$SLURM_JOB_ID  $(date)"
  echo "# allocation: ${NODES[*]}"; } > "$RESULT"

measure_lat(){  # label server client
  local L="$1" S="$2" C="$3" TOOL P=24000
  for TOOL in ib_write_lat ib_send_lat ib_read_lat; do
    srun --overlap -N1 -n1 -w "$S" bash -lc "$TOOL -d $DEV -F -s 2 -n 20000 -p $P" >/dev/null 2>&1 &
    sleep 4
    srun --overlap -N1 -n1 -w "$C" bash -lc "$TOOL -d $DEV -F -s 2 -n 20000 -p $P $S" 2>/dev/null \
      | awk -v t="$TOOL" -v lbl="$L" '/^ *2 +20000/{printf "%s  %-13s t_typical=%s us  t_avg=%s us\n", lbl, t, $5, $6}' | tee -a "$RESULT"
    wait; sleep 1; P=$((P+1))
  done
}
measure_bw(){   # label server client
  local L="$1" S="$2" C="$3" P=25000
  for mode in "" "-b"; do
    srun --overlap -N1 -n1 -w "$S" bash -lc "ib_write_bw -d $DEV -F --report_gbits $mode -s 1048576 -n 5000 -q 4 -p $P" >/dev/null 2>&1 &
    sleep 4
    srun --overlap -N1 -n1 -w "$C" bash -lc "ib_write_bw -d $DEV -F --report_gbits $mode -s 1048576 -n 5000 -q 4 -p $P $S" 2>/dev/null \
      | awk -v lbl="$L" -v m="${mode:-unidir}" '/^ *1048576/{printf "%s  ib_write_bw %-6s BW_avg=%s Gb/s\n", lbl, m, $4}' | tee -a "$RESULT"
    wait; sleep 1; P=$((P+1))
  done
}

# Always grab the intra-leaf baseline if the allocation gives one (same-session reference).
if [ -n "$INTRA_S" ]; then
  echo "### INTRA-LEAF (1 hop) baseline ###" | tee -a "$RESULT"
  measure_lat "INTRA-1hop" "$INTRA_S" "$INTRA_C"
  measure_bw  "INTRA-1hop" "$INTRA_S" "$INTRA_C"
fi

if [ -n "$INTER_S" ]; then
  echo "### INTER-LEAF (3 hops: leaf->spine->leaf) ###" | tee -a "$RESULT"
  measure_lat "INTER-3hop" "$INTER_S" "$INTER_C"
  measure_bw  "INTER-3hop" "$INTER_S" "$INTER_C"
  rm -f .interleaf_xnodes          # success: clear accumulated-exclude state for next manual run
  echo "=== DONE (inter-leaf captured) -> $RESULT ==="
else
  # Allocation packed onto ONE leaf (Slurm minimizes switch count). Resubmit a fresh attempt
  # (sbatch-within-sbatch) that ALSO excludes this offending leaf, so the scheduler is forced
  # toward other leaves until the allocation finally spans two. Bounded by MAX_ATTEMPT.
  # The growing exclude list is kept in .interleaf_xnodes (a file, not --export, because the
  # nodelist expression contains commas which --export would mis-split).
  ATTEMPT=${ATTEMPT:-1}; MAX_ATTEMPT=${MAX_ATTEMPT:-40}
  XNODES=$(cat .interleaf_xnodes 2>/dev/null || echo 'compute-b8-[21-52,54-60]')
  OFFEND=$(leaf_nodes "${LEAF[${NODES[0]}]}")
  NEWX="$XNODES,$OFFEND"
  echo "WARNING: single-leaf alloc on ${LEAF[${NODES[0]}]} ($OFFEND); no inter pair (attempt $ATTEMPT/$MAX_ATTEMPT)." | tee -a "$RESULT"
  if [ "$ATTEMPT" -lt "$MAX_ATTEMPT" ]; then
    echo "$NEWX" > .interleaf_xnodes
    echo "Excluding it too; resubmitting attempt $((ATTEMPT+1)) with --exclude=$NEWX" | tee -a "$RESULT"
    sbatch --exclude="$NEWX" --export=ALL,ATTEMPT=$((ATTEMPT+1)),MAX_ATTEMPT=$MAX_ATTEMPT interleaf_job.sh
  else
    echo "Reached MAX_ATTEMPT; giving up. Clear .interleaf_xnodes and re-run later." | tee -a "$RESULT"
    rm -f .interleaf_xnodes
  fi
fi
