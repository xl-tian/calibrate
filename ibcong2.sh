#!/bin/bash
#SBATCH --job-name=ibcong2
#SBATCH --partition=standard
#SBATCH --nodes=6
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=8G
#SBATCH --time=00:10:00
#SBATCH --output=ibcong2.%j.out

set -x
DEV=mlx5_0
# Sources, each on a DISTINCT leaf; sinks all on leaf d85b00. Every flow crosses the spine.
SRC=(compute-a7-31 compute-a5-4 compute-b8-11)   # leaves dc3f4a, d85b40, d55b66
SNK=(compute-b8-21 compute-b8-42 compute-b8-43)  # all leaf d85b00
N=${#SRC[@]}

echo "##### Baseline: single cross-spine flow ${SRC[0]} -> ${SNK[0]} #####"
srun --overlap --nodes=1 --ntasks=1 -w ${SNK[0]} bash -lc "ib_write_bw -d $DEV -F --report_gbits -s 1048576 -n 5000 -q 4 -p 19500" &
sleep 5
srun --overlap --nodes=1 --ntasks=1 -w ${SRC[0]} bash -lc "ib_write_bw -d $DEV -F --report_gbits -s 1048576 -n 5000 -q 4 -p 19500 ${SNK[0]} | sed 's/^/SINGLE /'"
wait
sleep 3

echo "##### $N CONCURRENT cross-spine flows converging on leaf d85b00 (bisection probe) #####"
for i in $(seq 0 $((N-1))); do
  p=$((19000+i))
  srun --overlap --nodes=1 --ntasks=1 -w ${SNK[$i]} bash -lc "ib_write_bw -d $DEV -F --report_gbits -s 1048576 -n 30000 -q 4 -p $p" &
done
sleep 6
for i in $(seq 0 $((N-1))); do
  p=$((19000+i))
  srun --overlap --nodes=1 --ntasks=1 -w ${SRC[$i]} bash -lc "ib_write_bw -d $DEV -F --report_gbits -s 1048576 -n 30000 -q 4 -p $p ${SNK[$i]} | awk -v f=$i '/1048576/{printf \"FLOW %d (%s->%s) avgBW=%s Gb/s\n\", f, \"${SRC[$i]}\", \"${SNK[$i]}\", \$4}'" &
done
wait
echo "=== DONE ==="
