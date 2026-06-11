#!/bin/bash
# lib_cluster.sh — sourced helpers for characterizing an HPC interconnect.
# Generic: no hardcoded node names, devices, or leaf switches. Works on Slurm clusters that use
# the topology/tree plugin; degrades gracefully where pieces are missing.
#
#   source lib_cluster.sh
#   DEV=$(detect_ib_device)
#   leaf_of compute-x-1
#
# Override defaults via env: TOPOLOGY_FILE, PARTITION.

TOPOLOGY_FILE="${TOPOLOGY_FILE:-/etc/slurm/topology.conf}"

# --- interconnect detection -------------------------------------------------

# Print the active InfiniBand device name (link_layer==InfiniBand, port Active). Falls back to the
# first IB-layer device. Returns 1 if none. (RoCE/Ethernet devices are intentionally skipped.)
detect_ib_device(){
  local d name ll st
  for d in /sys/class/infiniband/*/; do
    [ -e "$d" ] || continue
    name=$(basename "$d"); ll=$(cat "$d/ports/1/link_layer" 2>/dev/null); st=$(cat "$d/ports/1/state" 2>/dev/null)
    if [ "$ll" = "InfiniBand" ] && echo "$st" | grep -qi active; then echo "$name"; return 0; fi
  done
  for d in /sys/class/infiniband/*/; do
    [ -e "$d" ] || continue
    [ "$(cat "$d/ports/1/link_layer" 2>/dev/null)" = InfiniBand ] && { basename "$d"; return 0; }
  done
  return 1
}

# One-line technology+rate summary for every IB/RoCE port on this host.
interconnect_summary(){
  local d name
  for d in /sys/class/infiniband/*/; do
    [ -e "$d" ] || continue
    name=$(basename "$d")
    printf '%-14s link_layer=%-11s rate=%-22s state=%s\n' "$name" \
      "$(cat "$d/ports/1/link_layer" 2>/dev/null)" \
      "$(cat "$d/ports/1/rate" 2>/dev/null)" \
      "$(cat "$d/ports/1/state" 2>/dev/null)"
  done
}

# --- Slurm topology helpers -------------------------------------------------
# Both /etc/slurm/topology.conf and `scontrol show topology` are supported; fields are matched by
# prefix (SwitchName=, Nodes=, Switches=) rather than position, so either format parses correctly.

_topo_src(){
  if [ -r "$TOPOLOGY_FILE" ]; then cat "$TOPOLOGY_FILE"; else scontrol show topology 2>/dev/null; fi
}

# leaf_of <node>  ->  prints the leaf SwitchName that contains <node> (skips spine/aggregate lines)
leaf_of(){
  local node="$1"
  _topo_src | awk -v node="$node" '
    /SwitchName=/ && /Nodes=/ && !/Switches=/{
      sw=""; nl="";
      for(i=1;i<=NF;i++){ if($i ~ /^SwitchName=/){sw=$i;sub(/SwitchName=/,"",sw)}
                          if($i ~ /^Nodes=/){nl=$i;sub(/Nodes=/,"",nl)} }
      if(nl==""){next}
      cmd="scontrol show hostnames "nl" 2>/dev/null";
      while((cmd|getline h)>0){ if(h==node){print sw; exit} } close(cmd) }'
}

# leaf_nodes <leaf-switch-name>  ->  prints that leaf's Nodes= expression (for --exclude etc.)
leaf_nodes(){
  local sw="$1"
  _topo_src | awk -v g="$sw" '
    /SwitchName=/ && /Nodes=/ && !/Switches=/{
      name=""; nl="";
      for(i=1;i<=NF;i++){ if($i ~ /^SwitchName=/){name=$i;sub(/SwitchName=/,"",name)}
                          if($i ~ /^Nodes=/){nl=$i;sub(/Nodes=/,"",nl)} }
      if(name==g){print nl; exit} }'
}

# list_leaves  ->  prints "leafname  Nodes=expr" for every leaf switch
list_leaves(){
  _topo_src | awk '
    /SwitchName=/ && /Nodes=/ && !/Switches=/{
      name=""; nl="";
      for(i=1;i<=NF;i++){ if($i ~ /^SwitchName=/){name=$i;sub(/SwitchName=/,"",name)}
                          if($i ~ /^Nodes=/){nl=$i;sub(/Nodes=/,"",nl)} }
      if(name!="" && nl!="") print name"  "nl }'
}

# --- scheduling helpers -----------------------------------------------------

# Nodes currently inside ANY Slurm reservation (expanded host names), one per line.
reserved_nodes(){
  scontrol show reservation -o 2>/dev/null | grep -oP 'Nodes=\K[^ ]+' \
    | while read -r nl; do [ -n "$nl" ] && [ "$nl" != "(null)" ] && scontrol show hostnames "$nl" 2>/dev/null; done | sort -u
}

# pick_cross_leaf_nodes <N> [partition]  ->  prints up to N node names, each on a DISTINCT leaf,
# each EXACTLY idle (DRAIN/comp/mix/alloc/down rejected — beware `sinfo -t idle` also lists
# IDLE+DRAIN nodes) and NOT in any reservation. Exit 1 if fewer than N leaves are usable.
pick_cross_leaf_nodes(){
  local want="${1:-2}" part="${2:-${PARTITION:-}}" partflag="" res idle n st L
  [ -n "$part" ] && partflag="-p $part"
  res=$(reserved_nodes)
  idle=$(sinfo $partflag -t idle -h -o "%n" 2>/dev/null | sort -u)
  declare -A PICK
  for n in $idle; do
    grep -qxF "$n" <<<"$res" && continue
    st=$(sinfo -n "$n" $partflag -h -o "%t" 2>/dev/null | head -1); [ "$st" = "idle" ] || continue
    L=$(leaf_of "$n"); [ -z "$L" ] && continue
    [ -n "${PICK[$L]:-}" ] && continue
    PICK[$L]="$n"
  done
  if [ "${#PICK[@]}" -lt "$want" ]; then
    echo "pick_cross_leaf_nodes: only ${#PICK[@]} leaf(es) usable, need $want" >&2; return 1
  fi
  local i=0
  for L in "${!PICK[@]}"; do echo "${PICK[$L]}"; i=$((i+1)); [ "$i" -ge "$want" ] && break; done
}
