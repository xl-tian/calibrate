#!/bin/bash
#SBATCH --job-name=iblat
#SBATCH --partition=standard
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=4G
#SBATCH --time=00:05:00
#SBATCH --output=iblat.%j.out

set -x
DEV=mlx5_0
# intra-leaf pair (both on leaf d85b00 = 1 switch hop); inter-leaf pair (dc3f4a<->d85b00 = 3 hops)
IA=compute-b8-44; IB=compute-b8-45            # intra
EA=compute-a7-31; EB=compute-b8-21            # inter (a7-31 on leaf dc3f4a)

# confirm leaves
TOP=/etc/slurm/topology.conf
leaf_of(){ awk -v node="$1" '/^SwitchName=.*Nodes=/ && !/Switches=/{sw=$1;sub(/SwitchName=/,"",sw);nl=$2;sub(/Nodes=/,"",nl);cmd="scontrol show hostnames "nl" 2>/dev/null";while((cmd|getline h)>0){if(h==node){print sw;exit}}close(cmd)}' "$TOP"; }
for n in $IA $IB $EA $EB; do echo "leaf $n = $(leaf_of $n)"; done

run_lat(){  # label tool server client port
  local LABEL="$1" TOOL="$2" S="$3" C="$4" P="$5"
  echo "########## $TOOL $LABEL : $S <-> $C ##########"
  srun --overlap --nodes=1 --ntasks=1 -w $S bash -lc "$TOOL -d $DEV -F -s 2 -n 20000 -p $P" &
  sleep 4
  srun --overlap --nodes=1 --ntasks=1 -w $C bash -lc "$TOOL -d $DEV -F -s 2 -n 20000 -p $P $S"
  wait
  sleep 1
}

for TOOL in ib_write_lat ib_send_lat ib_read_lat; do
  run_lat "INTRA-LEAF(1 hop)" $TOOL $IA $IB 21000
  run_lat "INTER-LEAF(3 hops)" $TOOL $EA $EB 21001
done

echo "=== DONE ==="
