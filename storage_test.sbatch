#!/bin/bash
#SBATCH --job-name=stortest
#SBATCH --partition=standard
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=16G
#SBATCH --time=00:20:00
#SBATCH --output=stortest.%j.out
set -uo pipefail
source ./lib_cluster.sh
DIR=/scratch/zt1/project/sussman-lab/user/xt01/calibrate/iotest.$SLURM_JOB_ID
mkdir -p "$DIR"
RESULT=storage_results.$SLURM_JOB_ID.txt
NODES=($(scontrol show hostnames "$SLURM_JOB_NODELIST"))
echo "# BeeGFS storage measurement job=$SLURM_JOB_ID $(date)" > "$RESULT"
echo "# nodes: ${NODES[*]}" >> "$RESULT"
NSTREAMS=${NSTREAMS:-8}; SZMB=${SZMB:-4096}   # 8 streams x 4 GiB = 32 GiB per node

bw_node(){  # run parallel-dd write+read on one node, print aggregate GB/s
  local C="$1" tag="$2"
  srun -N1 -n1 -w "$C" bash -lc '
    D="'"$DIR"'/'"$tag"'"; mkdir -p "$D"; NS='"$NSTREAMS"'; SZ='"$SZMB"'
    sync
    t0=$(date +%s.%N); for i in $(seq 1 $NS); do dd if=/dev/zero of=$D/w$i bs=1M count=$SZ oflag=direct 2>/dev/null & done; wait; t1=$(date +%s.%N)
    awk -v ns=$NS -v sz=$SZ -v dt=$(echo "$t1 $t0" | awk "{print \$1-\$2}") "BEGIN{printf \"WRITE %.2f GB/s (%d streams x %d MiB direct)\n\", ns*sz/1024/dt, ns, sz}"
    t0=$(date +%s.%N); for i in $(seq 1 $NS); do dd if=$D/w$i of=/dev/null bs=1M iflag=direct 2>/dev/null & done; wait; t1=$(date +%s.%N)
    awk -v ns=$NS -v sz=$SZ -v dt=$(echo "$t1 $t0" | awk "{print \$1-\$2}") "BEGIN{printf \"READ  %.2f GB/s\n\", ns*sz/1024/dt}"
    rm -rf "$D"
  ' 2>/dev/null | sed "s/^/[$tag $C] /" | tee -a "$RESULT"
}

echo "### SINGLE-NODE BeeGFS bandwidth ###" | tee -a "$RESULT"
bw_node "${NODES[0]}" single

if [ "${#NODES[@]}" -ge 2 ]; then
  echo "### MULTI-NODE simultaneous (aggregate = sum of per-node) ###" | tee -a "$RESULT"
  for C in "${NODES[@]}"; do bw_node "$C" "multi" & done; wait
fi

echo "### IPoIB ping to BeeGFS servers (coarse latency / equidistance check) ###" | tee -a "$RESULT"
# OSS .240-.245, MDS .246-.247, mgmt .122
for C in "${NODES[@]}"; do
  LEAF=$(leaf_of "$C" | tail -c 7)
  srun -N1 -n1 -w "$C" bash -lc '
    for ip in 192.168.128.240 192.168.128.242 192.168.128.246 192.168.128.122; do
      r=$(ping -c 30 -i 0.2 -q $ip 2>/dev/null | awk -F/ "/rtt|round-trip/{print \$5\" ms avg (min \"\$4\")\"}")
      echo "  oss/mds $ip : ${r:-unreachable}"
    done' 2>/dev/null | sed "s/^/[from $C leaf $LEAF] /" | tee -a "$RESULT"
done

rm -rf "$DIR"
echo "=== DONE -> $RESULT ===" | tee -a "$RESULT"
