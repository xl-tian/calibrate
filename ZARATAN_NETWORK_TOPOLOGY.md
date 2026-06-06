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

Intra-leaf, leaf d85b40, AMD EPYC 7763 nodes [jobs 19806741, 19806950]:

| Test | Nodes | Result |
|------|-------|--------|
| Unidirectional single flow | a5-5 → a5-3 | **98.2 Gb/s** (≈98% of 100 Gb/s HDR100) |
| Bidirectional (full-duplex, `-b`) | a5-5 ↔ a5-3 | **191.8 Gb/s** total (≈96 Gb/s each way) |
| 2 concurrent flows (4 distinct nodes) | a5-5→a5-3, a5-7→a5-6 | **98.1 + 97.9 Gb/s** (no degradation) |

Conclusions from measurements:
- Each node link is **HDR100, ~98 Gb/s achievable**, and **full-duplex** (≈100+100).
- The leaf switch is **internally non-blocking**: two simultaneous pairs (4 nodes) each
  sustain full HDR100 with no contention (aggregate ≈196 Gb/s through the leaf).

**Cross-spine (inter-leaf) bisection was NOT empirically measured.** At test time the cluster
was heavily loaded — idle, non-reserved capacity was concentrated on a single leaf (d85b00),
and `--nodelist`-pinned jobs spanning two leaves were unschedulable (`ReqNodeNotAvail, May be
reserved for other job`: idle nodes were backfill-earmarked for queued jobs, plus a 14-node
`unstable` MAINT reservation). A single cross-spine flow would in any case just reproduce
~98 Gb/s (one flow cannot exceed its own HDR100 NIC); demonstrating the 1:1 spine bisection
would require many concurrent inter-leaf pairs, which the current allocation could not provide.
The non-blocking spine claim therefore rests on the port-count math + UMD docs, not measurement.
To verify later, run `ibcong2.sh` (3 sources on distinct leaves → 3 sinks on one leaf) when
≥2 nodes per leaf are free on multiple leaves.

## Reproduce

- `ibstat`, `ibstatus`, `ibv_devinfo -v` — per-node link rate/width.
- `cat /etc/slurm/topology.conf` or `scontrol show topology` — fat-tree structure.
- `sbatch ibfinal.sh` — point-to-point + bidirectional + concurrent ib_write_bw.
- `sbatch ibdiag.sh` — diagnostics + intra/inter-leaf BW (auto-detects leaf placement).
