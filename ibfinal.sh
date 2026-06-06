#!/bin/bash
#SBATCH --job-name=ibfinal
#SBATCH --partition=standard
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=8G
#SBATCH --time=00:12:00
#SBATCH --output=ibfinal.%j.out

set -x
DEV=mlx5_0
NODES=($(scontrol show hostnames "$SLURM_JOB_NODELIST"))
echo "=== ALLOCATED: ${NODES[@]} ==="

# Map each node to its leaf via topology.conf
TOP=/etc/slurm/topology.conf
leaf_of(){ awk -v node="$1" '/^SwitchName=.*Nodes=/ && !/Switches=/{sw=$1;sub(/SwitchName=/,"",sw);nl=$2;sub(/Nodes=/,"",nl);cmd="scontrol show hostnames "nl" 2>/dev/null";while((cmd|getline h)>0){if(h==node){print sw;exit}}close(cmd)}' "$TOP"; }
declare -A LEAF; for n in "${NODES[@]}"; do LEAF[$n]=$(leaf_of "$n"); echo "leaf $n = ${LEAF[$n]}"; done

S=${NODES[0]}; C=${NODES[1]}
echo "PAIR: server=$S client=$C  leaves=${LEAF[$S]} / ${LEAF[$C]}"
[ "${LEAF[$S]}" = "${LEAF[$C]}" ] && KIND="INTRA-LEAF" || KIND="INTER-LEAF(cross-spine)"
echo "PAIR KIND = $KIND"

echo "##### 1) Unidirectional single flow ($KIND) #####"
srun --overlap --nodes=1 --ntasks=1 -w $S bash -lc "ib_write_bw -d $DEV -F --report_gbits -s 1048576 -n 10000 -q 4 -p 20000" &
sleep 5
srun --overlap --nodes=1 --ntasks=1 -w $C bash -lc "ib_write_bw -d $DEV -F --report_gbits -s 1048576 -n 10000 -q 4 -p 20000 $S | awk '/1048576/{print \"UNIDIR avgBW=\" \$4 \" Gb/s\"}'"
wait; sleep 2

echo "##### 2) BIDIRECTIONAL single flow (full-duplex, -b) #####"
srun --overlap --nodes=1 --ntasks=1 -w $S bash -lc "ib_write_bw -d $DEV -F --report_gbits -b -s 1048576 -n 10000 -q 4 -p 20010" &
sleep 5
srun --overlap --nodes=1 --ntasks=1 -w $C bash -lc "ib_write_bw -d $DEV -F --report_gbits -b -s 1048576 -n 10000 -q 4 -p 20010 $S | awk '/1048576/{print \"BIDIR  avgBW=\" \$4 \" Gb/s (sum of both directions)\"}'"
wait; sleep 2

# 3) Concurrent flows among the 4 nodes: (N0->N1) and (N2->N3) simultaneously
if [ ${#NODES[@]} -ge 4 ]; then
  S2=${NODES[2]}; C2=${NODES[3]}
  echo "##### 3) TWO concurrent flows: $S<-$C and $S2<-$C2 (leaves ${LEAF[$S]},${LEAF[$S2]}) #####"
  srun --overlap --nodes=1 --ntasks=1 -w $S  bash -lc "ib_write_bw -d $DEV -F --report_gbits -s 1048576 -n 20000 -q 4 -p 20020" &
  srun --overlap --nodes=1 --ntasks=1 -w $S2 bash -lc "ib_write_bw -d $DEV -F --report_gbits -s 1048576 -n 20000 -q 4 -p 20021" &
  sleep 6
  srun --overlap --nodes=1 --ntasks=1 -w $C  bash -lc "ib_write_bw -d $DEV -F --report_gbits -s 1048576 -n 20000 -q 4 -p 20020 $S  | awk '/1048576/{print \"CONCUR flowA avgBW=\" \$4 \" Gb/s\"}'" &
  srun --overlap --nodes=1 --ntasks=1 -w $C2 bash -lc "ib_write_bw -d $DEV -F --report_gbits -s 1048576 -n 20000 -q 4 -p 20021 $S2 | awk '/1048576/{print \"CONCUR flowB avgBW=\" \$4 \" Gb/s\"}'" &
  wait
fi
echo "=== DONE ==="
