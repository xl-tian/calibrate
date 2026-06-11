#!/bin/bash
# Runs ON THE LOGIN NODE under salloc. Measures login<->compute latency+bandwidth for each
# allocated compute node (on distinct leaves), to hop-count the login node's fabric attachment.
# perftest server runs on the COMPUTE node (via srun); client runs locally on the login node.
set -uo pipefail
source ./lib_cluster.sh
LDEV=$(detect_ib_device)            # login IB device (e.g. mlx5_2)
RESULT="login_results.${SLURM_JOB_ID}.txt"
echo "# login<->compute  login_dev=$LDEV  $(hostname)  $(date)" > "$RESULT"
NODES=($(scontrol show hostnames "$SLURM_JOB_NODELIST"))
P=30000
for C in "${NODES[@]}"; do
  CIP=$(srun -N1 -n1 -w "$C" bash -lc "ip -br addr show ib0 | awk '{print \$3}' | cut -d/ -f1" 2>/dev/null)
  CDEV=$(srun -N1 -n1 -w "$C" bash -lc 'for d in $(ibstat -l); do [ "$(cat /sys/class/infiniband/$d/ports/1/link_layer 2>/dev/null)" = InfiniBand ] && echo $d && break; done' 2>/dev/null)
  LEAF=$(leaf_of "$C" | tail -c 7)
  echo "### login <-> $C (leaf $LEAF, ip $CIP, dev $CDEV) ###" | tee -a "$RESULT"
  for T in ib_write_lat ib_send_lat ib_read_lat; do
    srun --overlap -N1 -n1 -w "$C" bash -lc "$T -d $CDEV -F -s 2 -n 20000 -p $P" >/dev/null 2>&1 &
    sleep 3
    $T -d "$LDEV" -F -s 2 -n 20000 -p $P "$CIP" 2>/dev/null \
      | awk -v t="$T" -v l="$LEAF" '/^ *2 +[0-9]/{printf "login-%-7s %-13s t_typical=%s us t_avg=%s us\n",l,t,$5,$6}' | tee -a "$RESULT"
    wait; sleep 1; P=$((P+1))
  done
  for m in "" "-b"; do
    srun --overlap -N1 -n1 -w "$C" bash -lc "ib_write_bw -d $CDEV -F --report_gbits $m -s 1048576 -n 5000 -q 4 -p $P" >/dev/null 2>&1 &
    sleep 3
    ib_write_bw -d "$LDEV" -F --report_gbits $m -s 1048576 -n 5000 -q 4 -p $P "$CIP" 2>/dev/null \
      | awk -v l="$LEAF" -v M="${m:-unidir}" '/^ *[0-9]+ +[0-9]/{printf "login-%-7s ib_write_bw %-6s BW_avg=%s Gb/s\n",l,M,$4}' | tee -a "$RESULT"
    wait; sleep 1; P=$((P+1))
  done
done
echo "=== DONE -> $RESULT ===" | tee -a "$RESULT"
