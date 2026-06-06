#!/bin/bash
#SBATCH --job-name=ibdiag
#SBATCH --partition=standard
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=8G
#SBATCH --time=00:12:00
#SBATCH --output=ibdiag.%j.out

set -x
echo "=== ALLOCATED: $SLURM_JOB_NODELIST ==="
NODES=$(scontrol show hostnames "$SLURM_JOB_NODELIST")
echo "$NODES"

TOP=/etc/slurm/topology.conf
leaf_of () {  # map a node name to its leaf switch GUID using topology.conf
  local n=$1
  while read -r line; do
    case "$line" in SwitchName=*Nodes=*)
      sw=$(echo "$line" | sed -E 's/SwitchName=([^ ]+).*/\1/')
      nl=$(echo "$line" | sed -E 's/.*Nodes=([^ ]+).*/\1/')
      if scontrol show hostnames "$nl" 2>/dev/null | grep -qx "$n"; then echo "$sw"; return; fi
    esac
  done < <(grep -v '^SwitchName=top' "$TOP")
}

declare -A LEAF
for n in $NODES; do LEAF[$n]=$(leaf_of "$n"); echo "node $n -> leaf ${LEAF[$n]}"; done

# pick an intra-leaf pair (two nodes sharing a leaf) and an inter-leaf pair
SRV=""; INTRA=""; INTER=""
arr=($NODES)
for ((i=0;i<${#arr[@]};i++)); do for ((j=i+1;j<${#arr[@]};j++)); do
  a=${arr[$i]}; b=${arr[$j]}
  if [ "${LEAF[$a]}" = "${LEAF[$b]}" ] && [ -z "$INTRA" ]; then SRV=$a; INTRA=$b; fi
  if [ "${LEAF[$a]}" != "${LEAF[$b]}" ] && [ -z "$INTER_A" ]; then INTER_A=$a; INTER_B=$b; fi
done; done
[ -z "$SRV" ] && SRV=${arr[0]}
echo "INTRA pair: $SRV <-> $INTRA   (leaf ${LEAF[$SRV]})"
echo "INTER pair: $INTER_A <-> $INTER_B   (leaves ${LEAF[$INTER_A]} / ${LEAF[$INTER_B]})"

DEV=$(srun --nodes=1 --ntasks=1 -w ${arr[0]} bash -lc \
  'for d in $(ibstat -l); do [ "$(cat /sys/class/infiniband/$d/ports/1/link_layer 2>/dev/null)" = InfiniBand ] && echo $d && break; done')
echo "=== IB DEVICE = $DEV ==="

echo "##### ibstat / ibv_devinfo on ${arr[0]} #####"
srun --nodes=1 --ntasks=1 -w ${arr[0]} bash -lc 'ibstat; echo ===devinfo===; ibv_devinfo -v 2>/dev/null | grep -iE "board_id|fw_ver|active_width|active_speed|link_layer|phys_state|node_desc"'

echo "##### Fabric discovery attempts from compute node #####"
srun --nodes=1 --ntasks=1 -w ${arr[0]} bash -lc 'echo --iblinkinfo--; timeout 50 iblinkinfo 2>&1 | head -120; echo --ibnetdiscover-counts--; timeout 50 ibnetdiscover 2>&1 | grep -ciE "^Switch"; echo --sminfo--; sminfo 2>&1; echo --saquery-SWITCHES--; timeout 30 saquery SWITCHES 2>&1 | head -30'

run_bw () {
  local LABEL="$1" S="$2" C="$3"
  [ -z "$C" ] && { echo "skip $LABEL (no pair)"; return; }
  echo "########## ib_write_bw $LABEL : server=$S client=$C dev=$DEV ##########"
  srun --nodes=1 --ntasks=1 -w $S bash -lc "ib_write_bw -d $DEV -F --report_gbits -s 1048576 -n 5000 -q 4" &
  local p=$!
  sleep 5
  srun --nodes=1 --ntasks=1 -w $C bash -lc "ib_write_bw -d $DEV -F --report_gbits -s 1048576 -n 5000 -q 4 $S"
  wait $p
}

run_bw "INTRA-LEAF" "$SRV" "$INTRA"
sleep 2
run_bw "INTER-LEAF (crosses spine)" "$INTER_A" "$INTER_B"

echo "=== DONE ==="
