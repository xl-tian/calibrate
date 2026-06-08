#!/bin/bash
#SBATCH --job-name=ileafmulti
#SBATCH --partition=standard
#SBATCH --nodes=6
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=8G
#SBATCH --time=00:20:00
#SBATCH --exclude=compute-b8-[21-52,54-60]
#SBATCH --output=ileafmulti.%j.out
#
# Measure inter-leaf latency on SEVERAL distinct cross-leaf pairs (one per leaf-combination in the
# allocation) plus ONE intra-leaf pair. Same node-acquisition trick as interleaf_job.sh: a pending
# job waits in queue; if the allocation packs onto a single leaf it self-resubmits (sbatch-within-
# sbatch) adding that leaf to a growing --exclude (state in .interleaf_multi_xnodes), bounded by
# MAX_ATTEMPT. Requesting more nodes (-N6) makes the allocation span multiple leaves, yielding
# several different inter-leaf pairs in one run.
#
# Self-test: SELFTEST=1 MOCK_NODES="n1 n2 n3 n4" MOCKMAP="n1:LA n2:LA n3:LB n4:LC" bash interleaf_multi.sh
set -uo pipefail
DEV=${DEV:-mlx5_0}
TOP=/etc/slurm/topology.conf
MAXINTER=${MAXINTER:-6}

leaf_of(){
  if [ "${SELFTEST:-0}" = 1 ]; then
    local n="$1"; for kv in $MOCKMAP; do [ "${kv%%:*}" = "$n" ] && { echo "${kv##*:}"; return; }; done; return
  fi
  awk -v node="$1" '/^SwitchName=.*Nodes=/ && !/Switches=/{
    sw=$1; sub(/SwitchName=/,"",sw); nl=$2; sub(/Nodes=/,"",nl);
    cmd="scontrol show hostnames "nl" 2>/dev/null";
    while((cmd|getline h)>0){ if(h==node){print sw; exit} } close(cmd) }' "$TOP"
}
leaf_nodes(){ awk -v g="$1" '$1=="SwitchName="g{for(i=1;i<=NF;i++) if($i ~ /^Nodes=/){s=$i; sub(/Nodes=/,"",s); print s}}' "$TOP"; }

# Build NODES + per-leaf node lists
if [ "${SELFTEST:-0}" = 1 ]; then NODES=($MOCK_NODES); else NODES=($(scontrol show hostnames "$SLURM_JOB_NODELIST")); fi
declare -A LEAF LEAFNODES
for n in "${NODES[@]}"; do L=$(leaf_of "$n"); LEAF[$n]=$L; LEAFNODES[$L]+=" $n"; done
LEAVES=("${!LEAFNODES[@]}")

echo "=== allocation: ${NODES[*]} ==="
for L in "${LEAVES[@]}"; do echo "  leaf $L :${LEAFNODES[$L]}"; done

# intra pair: first leaf holding >=2 nodes
INTRA_S=""; INTRA_C=""; INTRA_L=""
for L in "${LEAVES[@]}"; do a=(${LEAFNODES[$L]}); if [ ${#a[@]} -ge 2 ]; then INTRA_S=${a[0]}; INTRA_C=${a[1]}; INTRA_L=$L; break; fi; done

# inter pairs: one node-pair per DISTINCT leaf-combination (up to MAXINTER)
INTER_PAIRS=()
for ((i=0;i<${#LEAVES[@]};i++)); do for ((j=i+1;j<${#LEAVES[@]};j++)); do
  [ ${#INTER_PAIRS[@]} -ge "$MAXINTER" ] && break 2
  ai=(${LEAFNODES[${LEAVES[$i]}]}); aj=(${LEAFNODES[${LEAVES[$j]}]})
  INTER_PAIRS+=("${ai[0]} ${aj[0]} ${LEAVES[$i]} ${LEAVES[$j]}")
done; done

echo "INTRA pair: ${INTRA_S:-none} <-> ${INTRA_C:-none}"
echo "INTER pairs (${#INTER_PAIRS[@]}):"; for p in "${INTER_PAIRS[@]}"; do echo "  $p"; done

if [ "${SELFTEST:-0}" = 1 ]; then echo "(selftest: stop before measurement)"; exit 0; fi

RESULT="interleaf_multi_results.${SLURM_JOB_ID}.txt"
{ echo "# multi-pair inter-leaf latency  job=$SLURM_JOB_ID  $(date)"; echo "# allocation: ${NODES[*]}"; } > "$RESULT"

PBASE=26000
measure_lat(){  # label server client
  local L="$1" S="$2" C="$3" TOOL
  for TOOL in ib_write_lat ib_send_lat ib_read_lat; do
    srun --overlap -N1 -n1 -w "$S" bash -lc "$TOOL -d $DEV -F -s 2 -n 20000 -p $PBASE" >/dev/null 2>&1 &
    sleep 4
    srun --overlap -N1 -n1 -w "$C" bash -lc "$TOOL -d $DEV -F -s 2 -n 20000 -p $PBASE $S" 2>/dev/null \
      | awk -v t="$TOOL" -v lbl="$L" '/^ *2 +20000/{printf "%-26s %-13s t_typical=%s us  t_avg=%s us\n", lbl, t, $5, $6}' | tee -a "$RESULT"
    wait; sleep 1; PBASE=$((PBASE+1))
  done
}

# Re-derive each node's leaf straight from topology.conf at measure time and ASSERT the
# intra/inter relation actually holds before trusting the numbers. Returns 0 if OK, 1 to skip.
verify_pair(){  # kind(INTRA|INTER) server client
  local kind="$1" S="$2" C="$3" ls lc
  ls=$(leaf_of "$S"); lc=$(leaf_of "$C")
  if [ "$kind" = INTRA ]; then
    if [ "$ls" = "$lc" ] && [ -n "$ls" ]; then
      echo "  [VERIFIED intra] $S and $C BOTH on leaf $ls" | tee -a "$RESULT"; return 0
    fi
    echo "  [SKIP] $S/$C expected same leaf but got $ls vs $lc" | tee -a "$RESULT"; return 1
  else
    if [ "$ls" != "$lc" ] && [ -n "$ls" ] && [ -n "$lc" ]; then
      echo "  [VERIFIED inter] $S on $ls  <->  $C on $lc  (different leaves => crosses spine)" | tee -a "$RESULT"; return 0
    fi
    echo "  [SKIP] $S/$C expected different leaves but got $ls / $lc" | tee -a "$RESULT"; return 1
  fi
}

# one intra pair (user: one more is enough)
if [ -n "$INTRA_S" ]; then
  echo "### INTRA-LEAF (1 hop)  ${INTRA_L} ###" | tee -a "$RESULT"
  if verify_pair INTRA "$INTRA_S" "$INTRA_C"; then
    measure_lat "INTRA ${INTRA_L: -6} $INTRA_S/$INTRA_C" "$INTRA_S" "$INTRA_C"
  fi
fi

# several inter pairs
NMEAS=0
if [ ${#INTER_PAIRS[@]} -gt 0 ]; then
  for p in "${INTER_PAIRS[@]}"; do
    set -- $p; S=$1; C=$2; Ls=$3; Lc=$4
    echo "### INTER-LEAF (3 hops)  ${Ls: -6} <-> ${Lc: -6} : $S <-> $C ###" | tee -a "$RESULT"
    if verify_pair INTER "$S" "$C"; then
      measure_lat "INTER ${Ls: -6}/${Lc: -6}" "$S" "$C"; NMEAS=$((NMEAS+1))
    fi
  done
fi
if [ "$NMEAS" -gt 0 ]; then
  rm -f .interleaf_multi_xnodes
  echo "=== DONE ($NMEAS verified inter-leaf pairs) -> $RESULT ==="
else
  # single-leaf allocation: resubmit excluding this leaf too (bounded)
  ATTEMPT=${ATTEMPT:-1}; MAX_ATTEMPT=${MAX_ATTEMPT:-40}
  XNODES=$(cat .interleaf_multi_xnodes 2>/dev/null || echo 'compute-b8-[21-52,54-60]')
  OFFEND=$(leaf_nodes "${LEAF[${NODES[0]}]}")
  NEWX="$XNODES,$OFFEND"
  echo "WARNING: single-leaf alloc on ${LEAF[${NODES[0]}]} ($OFFEND); no inter pair (attempt $ATTEMPT/$MAX_ATTEMPT)." | tee -a "$RESULT"
  if [ "$ATTEMPT" -lt "$MAX_ATTEMPT" ]; then
    echo "$NEWX" > .interleaf_multi_xnodes
    echo "Resubmitting attempt $((ATTEMPT+1)) with --exclude=$NEWX" | tee -a "$RESULT"
    sbatch --exclude="$NEWX" --export=ALL,ATTEMPT=$((ATTEMPT+1)),MAX_ATTEMPT=$MAX_ATTEMPT interleaf_multi.sh
  else
    echo "Reached MAX_ATTEMPT; giving up." | tee -a "$RESULT"; rm -f .interleaf_multi_xnodes
  fi
fi
