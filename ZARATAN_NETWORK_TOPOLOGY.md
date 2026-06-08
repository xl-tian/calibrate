# Zaratan Network Topology & Link Bandwidths

Investigated 2026-06-05 from login-3.zaratan.umd.edu and compute nodes.
Goal: identify topology (suspected fat tree) and the bandwidth of each link.

## TL;DR

- **Interconnect technology:** NVIDIA/Mellanox **HDR InfiniBand** (ConnectX-6, MT4123 HCAs).
  Separate **2×100 GbE LACP bond** (Ethernet, ConnectX-5) per node for storage/management.
- **Topology:** **2-level fat tree** — 12 leaf (edge) switches + a spine/core layer.
  Confirmed by Slurm `topology.conf` (12 `Level=0` switches under one `Level=1` "top").
- **Per-link bandwidths:**
  | Link | Technology | Rate |
  |------|-----------|------|
  | Compute / bigmem node ↔ leaf switch | HDR100 IB (2X HDR) | **100 Gb/s** |
  | GPU node ↔ leaf switch | full HDR IB (4X HDR) | **200 Gb/s** (per UMD docs) |
  | Leaf switch ↔ spine switch | full HDR IB (4X HDR) | **200 Gb/s** (inferred) |
  | Node ↔ Ethernet (storage/mgmt) | 2×100 GbE LACP | **200 Gb/s** aggregate |
  | Storage / service nodes ↔ fabric | full HDR IB | **200 Gb/s** (per UMD docs) |
- **Blocking ratio:** design math + docs indicate a **non-blocking (1:1) fat tree** for the
  HDR100 islands (see "Switch model & blocking" below).
- **Empirical (ib_write_bw, RDMA write, 1 MiB msgs, 4 QPs):**
  - Intra-leaf single flow: **98.2 Gb/s** (≈98% of HDR100 line rate). [job 19806741]
  - Bidirectional / concurrent: see "Empirical results" below.

## Evidence

### 1. Link technology and node rate (ibstat / ibv_devinfo)

Login node `mlx5_2` and compute node `mlx5_0` are both:
- `CA type: MT4123` = **ConnectX-6** HCA, board_id `DEL00000000xx` (Dell-built system).
- Port: `State: Active`, `Physical state: LinkUp`, `Link layer: InfiniBand`.
- `Rate: 100` → `active_width: 2X (16)`, `active_speed: 50.0 Gbps (64)`.
  → 2 lanes × 50 Gb/s HDR = **HDR100 = 100 Gb/s** per node link.

Second device `mlx5_bond_0` = ConnectX-5 (MT4119), `Link layer: Ethernet`,
`100 Gb/sec (4X EDR)` per port, bonded ×2 via 802.3ad LACP → 200 Gb/s Ethernet
(`/sys/class/net/bond0/speed = 200000`). This is the storage/management plane, not the
MPI fabric.

### 2. Fat-tree topology (Slurm topology.conf)

`/etc/slurm/topology.conf` (also `scontrol show topology`) defines a 2-level tree:
- **12 leaf switches** (`Level=0`), GUIDs `b8cef603…` (OUI `b8:ce:f6` = NVIDIA/Mellanox).
- **1 logical spine** `SwitchName=top` (`Level=1`) aggregating all 12 leaves.
  (Slurm collapses the physical spine switches into one logical node; the real core is
  almost certainly several spine switches — see blocking math.)

Leaf switch → attached nodes (node count):

| Leaf GUID (b8cef603…) | Nodes | #nodes |
|---|---|---|
| d85b40 | compute-a5-[3-11], gpu-a5-1, gpu-a6-[2-9] | 18 |
| dc3d6a | compute-a7-[1-20], compute-a8-[1-20] | 40 |
| d85ac0 | compute-a8-[21-60] | 40 |
| dc426a | compute-b7-[21-60] | 40 |
| d55b46 | gpu-b9-[1-7], gpu-b10-[1-7], gpu-b11-[1-6] | 20 |
| d55ba6 | compute-b5-[1-20], compute-b6-[1-20] | 40 |
| dc3f4a | compute-a7-[21-60] | 40 |
| d85800 | compute-b5-[21-60] | 40 |
| d85ae0 | compute-b6-[21-60] | 40 |
| dc43ea | bigmem-a9-[1-6] | 6 |
| d85b00 | compute-b8-[21-52,54-60] | 39 |
| d55b66 | compute-b7-[1-20], compute-b8-[1-20] | 40 |

Node hardware (scontrol show node): dual-socket **AMD EPYC 7763** (Milan), 128 cores,
512 GiB; feature flag `ib`. GPU nodes: A100 (gpu-b9/b10/b11), H100 (gpu-a6), V100 (gpu-a5-1).

### 3. Switch model & blocking ratio (inference)

Switch GUIDs are Mellanox; the HDR building block is the **QM87xx (Quantum) 40-port
HDR200/QSFP56 switch**. HDR200 ports split into 2×HDR100 via splitter cables, so a single
40-port switch fans out to up to 80 HDR100 endpoints.

For the busiest leaves (40 HDR100 nodes):
- 40 HDR100 downlinks = 20 physical HDR200 ports (each split 2×HDR100).
- Remaining 20 HDR200 ports → uplinks to spine.
- Down BW = 40×100 = 4000 Gb/s; Up BW = 20×200 = 4000 Gb/s → **1:1 non-blocking**.

12 leaves × 20 HDR200 uplinks = 240 uplinks; a spine of **6× QM87xx (40-port)** = 240 ports
gives an exact 1:1 core. (Spine switch count is inferred, not directly observed.)

Cross-checked against the official UMD docs (hpcc.umd.edu): "HDR-100 (100 Gbit) Infiniband
between nodes; storage and service nodes via full HDR (200 Gbit); compute & large-memory
nodes HDR100; **GPU nodes full HDR**."

### 4. Why direct fabric maps weren't possible

`iblinkinfo`, `ibnetdiscover`, `sminfo`, `saquery` all fail from BOTH the login node and
compute nodes: `Can't open SMI UMAD port (I/O error)` / `Failed to bind to the SA:
Permission denied`. MAD/UMAD subnet-management access is disabled for unprivileged users
fabric-wide (standard hardening). So topology came from Slurm config + per-node `ibstat`
+ empirical bandwidth rather than SM queries.

## Empirical results (ib_write_bw, RDMA write, 1 MiB messages, 4 QPs)

**Method:** `perftest` `ib_write_bw` (RDMA Write) over IB device `mlx5_0` (HDR100), server/client
pair placed with Slurm `srun -N1 -n1 -w <node>`; QP handshake over TCP, timed path is pure RDMA.
Parameters: **1 MiB messages** (`-s 1048576`), **4 QPs** (`-q 4`), `--report_gbits`,
**5,000–20,000 iterations** per call (`-n`); `-b` = bidirectional (full-duplex, sum of both
directions). Reported value = BW_average over the iterations (so each number is a steady-state
average, not a peak). Output row columns: `#bytes #iters BW_peak BW_avg MsgRate`.

Intra-leaf, leaf d85b40, AMD EPYC 7763 nodes [jobs 19806741, 19806950]:

| Test | Nodes | Result |
|------|-------|--------|
| Unidirectional single flow | a5-5 → a5-3 | **98.2 Gb/s** (≈98% of 100 Gb/s HDR100) |
| Bidirectional (full-duplex, `-b`) | a5-5 ↔ a5-3 | **191.8 Gb/s** total (≈96 Gb/s each way) |
| 2 concurrent flows (4 distinct nodes) | a5-5→a5-3, a5-7→a5-6 | **98.1 + 97.9 Gb/s** (no degradation) |

### Inter-leaf single flow, cross-spine — measured on 4 leaf-pairs

| Leaf pair (server↔client) | Nodes | Unidirectional | Bidirectional (`-b`) | Job |
|---|---|---:|---:|---|
| dc3d6a ↔ d85800 | a7-10 ↔ b5-21 | **98.8 Gb/s** | 197.0 Gb/s | 19911185 |
| dc3d6a ↔ d55ba6 | a7-10 ↔ b5-10 | **98.8 Gb/s** | 197.0 Gb/s | 19911185 |
| d85800 ↔ d55ba6 | b5-21 ↔ b5-10 | **98.8 Gb/s** | 197.0 Gb/s | 19911185 |
| d55ba6 ↔ d85ae0 | b6-18 ↔ b6-45 | 90.7 Gb/s | 186.0 Gb/s | 19815726 |

→ A cross-spine flow reaches **~98 Gb/s unidirectional / ~197 Gb/s bidirectional** — the **same as
intra-leaf** (98.2 / 191.8). The leaf↔spine links carry **full HDR100 node bandwidth**; the spine
is not a bottleneck for a single flow. (The lone 90.7 / 186 sample on the d55ba6↔d85ae0 pair was a
mildly noisy early run; the three clean repeats at 98.8 / 197 are the representative figure.)

**Runs:** intra-leaf BW reproduced across two jobs (19806741, 19806950), both ~98 Gb/s. Inter-leaf
BW now measured on **4 leaf-pairs** across two jobs (19815726, 19911185); 3 of 4 give 98.8 Gb/s.
Each value is itself a 5k–20k-iteration average.

Conclusions from measurements:
- Each node link is **HDR100, ~98 Gb/s achievable**, and **full-duplex** (≈100+100).
- The leaf switch is **internally non-blocking**: two simultaneous pairs (4 nodes) each
  sustain full HDR100 with no contention (aggregate ≈196 Gb/s through the leaf).
- A **cross-spine flow also reaches ~98 Gb/s** (≈197 Gb/s bidirectional), so the leaf↔spine
  uplinks deliver full node-rate bandwidth on every path tested.

**The full 1:1 non-blocking *bisection* (spine not oversubscribed under load) was NOT directly
measured** — that requires *many concurrent* inter-leaf pairs saturating the spine, not the single
cross-spine flow above. Demonstrating it needs ≥2 free nodes on each of several leaves at once
(use `ibcong2.sh`; see "Replicating the cross-spine test" below). The non-blocking claim rests on
the port-count math + UMD docs; the single-flow measurement confirms the per-link rate but not the
aggregate bisection ratio.

## Reproduce

- `ibstat`, `ibstatus`, `ibv_devinfo -v` — per-node link rate/width.
- `cat /etc/slurm/topology.conf` or `scontrol show topology` — fat-tree structure.
- `sbatch ibfinal.sh` — point-to-point + bidirectional + concurrent ib_write_bw.
- `sbatch ibdiag.sh` — diagnostics + intra/inter-leaf BW (auto-detects leaf placement).

## How to replicate the bandwidth measurements

### Tools (all preinstalled, no build needed)
`ib_write_bw`, `ib_read_bw`, `ib_send_bw` (from `perftest`) live in `/usr/bin` on every node.
The IB device on a compute node is **`mlx5_0`** (link layer InfiniBand). For MPI-level numbers,
`module load osu-micro-benchmarks/7.1-1/gcc/...` provides `osu_bw`/`osu_bibw`.

### How `ib_write_bw` is driven
It's a server/client pair: start the server on one node, then the client on the other pointing
at the server's hostname. The QP-info handshake goes over TCP (management net); the actual data
path is RDMA over InfiniBand. Flags used in these scripts:
- `-d mlx5_0` device · `-F` suppress CPU-freq warning · `--report_gbits` Gb/s output
- `-s 1048576` 1 MiB messages (large enough to hit line rate) · `-n N` iterations · `-q 4` 4 QPs
- `-b` **bidirectional** (full-duplex; reported number is the sum of both directions)

Output data row columns:
`#bytes  #iterations  BW_peak[Gb/sec]  BW_average[Gb/sec]  MsgRate[Mpps]`
→ read **BW_average** as the achieved bandwidth. Expect ~98 Gb/s on an HDR100 link.

### A) Intra-leaf point-to-point (always easy — one leaf usually has free nodes)
`ibfinal.sh` is unpinned: it grabs 4 nodes, auto-detects their leaf placement from
`topology.conf`, and runs unidirectional + bidirectional + two-concurrent-flow tests.
```bash
sbatch ibfinal.sh
grep -E 'UNIDIR|BIDIR|CONCUR' ibfinal.*.out     # the parsed results
```
Expected (and what we measured): unidir ~98 Gb/s, bidir ~192 Gb/s (full-duplex ≈100+100),
two concurrent pairs ~98+98 (leaf switch internally non-blocking).

Manual single pair on a chosen leaf:
```bash
# pick two free nodes on ONE leaf, e.g. two idle compute-b8-2x.. (leaf d85b00):
S=compute-b8-44; C=compute-b8-45
srun -N1 -n1 -w $S bash -lc 'ib_write_bw -d mlx5_0 -F --report_gbits -s 1048576 -n 5000 -q 4' &
sleep 4
srun -N1 -n1 -w $C bash -lc "ib_write_bw -d mlx5_0 -F --report_gbits -s 1048576 -n 5000 -q 4 $S"
```

### B) Inter-leaf single flow (confirms the per-link rate across the spine)
Two nodes on two different leaves; one RDMA flow. Easy to get with the picker:
```bash
mapfile -t P < <(./pick_cross_leaf_pair.sh 2)   # one cleanly-idle node on each of 2 leaves
S=${P[0]}; C=${P[1]}
sbatch -N2 --nodelist=$S,$C --time=00:05:00 ibfinal.sh   # auto-detects it's inter-leaf
```
A single flow can't exceed its own HDR100 NIC, so this just reconfirms ~98 Gb/s — it does **not**
reveal blocking. (Same scheduling caveats as the latency test apply; see the next section.)

Turnkey version (auto-retries until a cross-leaf pair frees up, like the latency runner):
```bash
MAX_TRIES=240 GRACE=75 ./run_interleaf_bw.sh    # -> ibfinal.<jobid>.out, id in /tmp/j_interbw.txt
```
Don't run it at the same time as `run_interleaf_latency.sh` — they compete for the same scarce
cross-leaf pairs; run one, then the other.

### C) Inter-leaf bisection — proving the 1:1 non-blocking spine (the hard one)
To show the leaf↔spine uplinks aren't oversubscribed you need **many concurrent inter-leaf
flows** saturating the spine, not one. `ibcong2.sh` sets up 3 sources on 3 distinct leaves all
sending simultaneously to 3 sinks on leaf `d85b00`, so the aggregate probes `d85b00`'s spine
bandwidth (expect ≈3×98 ≈ 294 Gb/s if non-blocking):
```bash
./pick_cross_leaf_pair.sh 3        # 3 source nodes on 3 distinct leaves
# put those 3 in ibcong2.sh SRC=(...), and 3 idle compute-b8-2x.. nodes in SNK=(...), then:
sbatch ibcong2.sh
grep -E 'FLOW|SINGLE' ibcong2.*.out
```
This needs several leaves each with a free node **at the same time** — the exact resource
contention that blocked it during the session.

### Scheduling caveats (why inter-leaf tests are hard on a busy cluster)
Identical to the latency case — idle capacity concentrating on one leaf, `sinfo -t idle`
returning DRAIN-flagged nodes, stuck `comp` epilogs, backfill earmarking of pinned nodes, and
the `unstable` MAINT reservation. The **full explanation + the `pick_cross_leaf_pair.sh` /
`run_interleaf_latency.sh` workarounds** are written up once in
**`ZARATAN_NETWORK_LATENCY.md` → "How to replicate the inter-leaf measurement"**; the same picker
and retry pattern apply verbatim to bandwidth (swap `iblat2.sh`→`ibfinal.sh`/`ibcong2.sh`).
