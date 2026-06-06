#!/bin/bash
#SBATCH --job-name=iblat2
#SBATCH --partition=standard
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=4G
#SBATCH --time=00:05:00
#SBATCH --output=iblat2.%x.%j.out
# Submit with: sbatch -N2 --nodelist=$S,$C --export=ALL,S=<srv>,C=<cli>,LBL=<label> iblat2.sh
set -x
DEV=mlx5_0
TOP=/etc/slurm/topology.conf
leaf_of(){ awk -v node="$1" '/^SwitchName=.*Nodes=/ && !/Switches=/{sw=$1;sub(/SwitchName=/,"",sw);nl=$2;sub(/Nodes=/,"",nl);cmd="scontrol show hostnames "nl" 2>/dev/null";while((cmd|getline h)>0){if(h==node){print sw;exit}}close(cmd)}' "$TOP"; }
echo "LABEL=$LBL  server=$S ($(leaf_of $S))  client=$C ($(leaf_of $C))"

run_lat(){
  local TOOL="$1" P="$2"
  echo "########## $TOOL  $LBL : $S <-> $C ##########"
  srun --overlap --nodes=1 --ntasks=1 -w $S bash -lc "$TOOL -d $DEV -F -s 2 -n 20000 -p $P" &
  sleep 4
  srun --overlap --nodes=1 --ntasks=1 -w $C bash -lc "$TOOL -d $DEV -F -s 2 -n 20000 -p $P $S"
  wait; sleep 1
}
run_lat ib_write_lat 22000
run_lat ib_send_lat  22001
run_lat ib_read_lat  22002
echo "=== DONE $LBL ==="
