#!/bin/bash
#SBATCH --job-name=ibcong
#SBATCH --partition=standard
#SBATCH --nodes=8
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=8G
#SBATCH --time=00:12:00
#SBATCH --output=ibcong.%j.out

set -x
# A-side nodes are on leaf dc3f4a, B-side on leaf d85b00; every A<->B flow crosses the spine.
A=(compute-a7-27 compute-a7-46)   # clients
B=(compute-b8-21 compute-b8-42)   # servers
DEV=mlx5_0
N=${#A[@]}
echo "=== $N simultaneous cross-spine flows: A(dc3f4a) -> B(d85b00) ==="

# Single inter-leaf flow first (1 pair) for the baseline cross-spine number
echo "########## SINGLE inter-leaf flow ${A[0]} -> ${B[0]} ##########"
srun --nodes=1 --ntasks=1 -w ${B[0]} bash -lc "ib_write_bw -d $DEV -F --report_gbits -s 1048576 -n 5000 -q 4 -p 18500" &
sleep 5
srun --nodes=1 --ntasks=1 -w ${A[0]} bash -lc "ib_write_bw -d $DEV -F --report_gbits -s 1048576 -n 5000 -q 4 -p 18500 ${B[0]}"
wait
sleep 3

echo "########## $N CONCURRENT cross-spine flows (aggregate bisection probe) ##########"
# Launch all servers
for i in $(seq 0 $((N-1))); do
  port=$((18000 + i))
  srun --nodes=1 --ntasks=1 -w ${B[$i]} bash -lc "ib_write_bw -d $DEV -F --report_gbits -s 1048576 -n 20000 -q 4 -p $port" &
done
sleep 6
# Launch all clients concurrently, capture each BW
for i in $(seq 0 $((N-1))); do
  port=$((18000 + i))
  srun --nodes=1 --ntasks=1 -w ${A[$i]} bash -lc "ib_write_bw -d $DEV -F --report_gbits -s 1048576 -n 20000 -q 4 -p $port ${B[$i]} | awk '/1048576/{print \"FLOW $i BW=\" \$4 \" Gb/s (avg \" \$4 \")\"}'" &
done
wait
echo "=== DONE ==="
