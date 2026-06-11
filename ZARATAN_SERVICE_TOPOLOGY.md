# Zaratan — Full Topology: Login & Storage Attachment

Investigated 2026-06-07. Extends `ZARATAN_NETWORK_TOPOLOGY.md` / `ZARATAN_NETWORK_LATENCY.md`
(which cover the compute fat tree) to the **service nodes** — how the **login node** and the
**storage servers** attach to the same HDR InfiniBand fabric, and the bandwidth + latency of those
links. Method = the network-characterization skill: infer → config → measure.

## TL;DR — the full picture

```
                         ┌─────────────────────────────┐
                         │   SPINE / core (Level-1)     │   (≈6× HDR switches, 1:1 fat tree)
                         └──┬───────┬───────┬────────┬──┘
            ┌───────────────┘       │       │        └────────────────┐
        compute leaf            compute leaf      ...            SERVICE leaf(s)
        (Level-0, ×12)          (Level-0)                        (login, BeeGFS OSS/MDS)
         │  │  │                                                  │        │       │
      compute nodes (HDR100)                                   login    OSS×6   MDS×2
                                                               HDR100   HDR200  HDR200
```

- **Login node:** HDR100 IB (ConnectX-6, `mlx5_2`), attaches to a **(service) leaf switch**,
  **3 switch hops** from compute — *equidistant* across compute leaves (same as compute↔compute
  inter-leaf). Measured login↔compute ≈ **1.72 µs**, **~97 Gb/s** (full HDR100). NOT on the spine
  (that would be 2 hops ≈ 1.45 µs).
- **Scratch storage = BeeGFS** (parallel FS, 1.5 PB): **6 OSS + 2 MDS**, all **RDMA over IB at
  full HDR (200 Gb/s)** (per UMD docs), on IPoIB subnet `192.168.128.0/19`. Files RAID0-striped
  over 4 targets (512 KiB chunks). Effective bandwidth: see measurement below.
- **Home = NFS** from `fs-1/2/3.zaratan` over **TCP/IPv6 on the Ethernet plane** (2×100 GbE LACP
  bond, `bond0`), **not** the InfiniBand fabric. A separate network from scratch.
- So Zaratan has **two storage planes**: high-performance **scratch over IB** (BeeGFS) and
  **home over Ethernet** (NFS).

## 1. Login node attachment (MEASURED)

I have a shell on the login node, so I ran perftest with the **server on a compute node** (via
`srun`) and the **client on the login node** (`mlx5_2` → compute IPoIB IP), for compute nodes on
**3 different leaves**. If login latency were uniform across leaves → equidistant; if it dipped for
one leaf → login shares that leaf. [salloc job 20067657]

| login ↔ compute on leaf | ib_write_lat | ib_send_lat | ib_read_lat (RTT) | BW unidir / bidir |
|---|---:|---:|---:|---:|
| d85800 | 1.73 µs | 1.74 | 3.41 | 97.4 / 195.6 Gb/s |
| d55b66 | 1.72 µs | 1.71 | 3.28 | 93.8 / 185.5 Gb/s |
| d85b00 | 1.71 µs | 1.63 | 3.33 | 98.7 / 196.4 Gb/s |

**Interpretation.** login↔compute = **~1.72 µs, identical across all three leaves**, and equal to
compute↔compute **inter-leaf (3 hops)** measured earlier (~1.70 µs). Hop-count via the per-hop
≈0.24 µs ladder (intra 1hop≈1.2 µs, +0.24/hop):
- 2 hops (login on spine) → would be ≈1.45 µs — **ruled out**.
- 3 hops (login on a leaf, leaf→spine→compute-leaf) → ≈1.7 µs — **matches**.

So the **login node hangs off a leaf switch one hop below the spine** (a dedicated service/edge
leaf — it was not on any of the 3 compute leaves tested), at **HDR100** (~97 Gb/s, full line rate).
Equidistance confirms symmetric routing through the spine, exactly like inter-leaf compute traffic.
The login↔compute *link* is therefore the same class as a compute node link: **HDR100, 100 Gb/s**.

## 2. Storage (BeeGFS over IB)

### Inventory (from `beegfs-ctl --listnodes --nicdetails`)
- **Management:** `mgmtd-ib` (192.168.128.122) — TCP only.
- **Metadata:** `mds-1` (…246), `mds-2` (…247) — **RDMA** over ib0.
- **Storage (OSS):** `oss-1`…`oss-6` (192.168.128.240–245) — **RDMA** over ib0.
- Default layout: RAID0, **512 KiB** chunks, **4 targets per file**, single storage pool.
- Each server also has `bond0` (10.102.32.x Ethernet) for management; the **data path is RDMA/IB**.
- Link rate: **full HDR / HDR200 = 200 Gb/s** per UMD docs (the servers' own sysfs isn't readable
  from a client; inferred + consistent with "storage/service nodes via full HDR").

### Bandwidth (MEASURED, BeeGFS effective) [job 20068330]
Parallel `dd`, 8 streams × 4 GiB per node, **O_DIRECT** (bypasses client page cache → real
storage traffic). Nodes compute-b5-21/22 (leaf d85800), during normal shared production load.

| Test | Write | Read |
|------|------:|-----:|
| Single client | **2.0 GB/s** | **3.0 GB/s** |
| 2 clients, aggregate | **2.9 GB/s** (1.81 + 1.04) | **6.8 GB/s** (2.19 + 4.62) |

**Reading these numbers.** The IB *link* to storage is HDR (the same fabric that does 97 Gb/s ≈
**12 GB/s** in raw RDMA, proven by the login/compute perftest above). BeeGFS delivers only
~2–7 GB/s here, so the bottleneck is the **filesystem / OSS / shared-load contention, NOT the IB
link**: writes barely scale from 1→2 clients (2.0→2.9 GB/s — OSS write-side contended), reads scale
better (3.0→6.8 GB/s). So:
- **Storage link bandwidth** (the wire) = **HDR200 ≈ 200 Gb/s per OSS** (inferred; the fabric
  clearly supports ≥100 Gb/s as measured to other nodes).
- **Effective scratch bandwidth a job sees** ≈ **2–3 GB/s single-client, ~7 GB/s read across a few
  clients** under current production load — a filesystem property, well below the link ceiling.

### Latency / attachment (best-effort)
No perftest server runs on the OSS/MDS, so raw RDMA latency to storage isn't directly measurable.
**IPoIB ping** (30 pings/target, from both compute nodes on leaf d85800) — note this is dominated
by the IP-over-IB software stack (~tens of µs), ~50× the RDMA path differences (~0.24 µs/hop), so
it **cannot resolve switch hops**, only gross reachability/uniformity:

| Target | avg | min |
|--------|----:|----:|
| oss `…240` | 0.10 ms | 0.07 ms |
| oss `…242` | 0.11 ms | 0.07 ms |
| mds `…246` | 0.064 ms | 0.045 ms |
| mgmt `…122` | 0.060 ms | 0.047 ms |

Both compute nodes give nearly identical values → storage is **uniformly reachable** (consistent
with equidistant, service-leaf attachment). MDS/mgmt ping ~25–30 µs below OSS even at the minimum —
*possibly* one hop closer, but IPoIB jitter makes this only suggestive, not conclusive.

**Attachment (inferred):** by analogy to the *measured* login result (service node = HDR, leaf-
attached, 3 hops, equidistant) and the UMD docs ("storage/service nodes via full HDR"), the BeeGFS
OSS/MDS most likely attach to **service/edge leaf switch(es) one hop below the spine at HDR200**,
giving every compute leaf a symmetric ~3-hop path to storage. This is inference — the exact
service-leaf switch can't be read because SM/MAD fabric discovery is blocked.

## 3. Home (NFS over Ethernet)
`/home` is NFSv4 from `fs-1/2/3.zaratan.umd.edu` over **`proto=tcp6`** to IPv6 addresses
(`2605:880:10:2::39/40/41`) — i.e. the **Ethernet** plane (the `bond0` 2×100 GbE LACP = 200 Gb/s
aggregate), not InfiniBand. Large `rsize/wsize` = 1 MiB. This is a distinct service network from
the IB fabric that carries compute MPI and BeeGFS scratch traffic.

## Method / caveats
- Login numbers are direct RDMA perftest (gold standard). Storage bandwidth is BeeGFS-level
  (includes the FS stack); raw per-OSS RDMA latency is not directly measurable (no perftest server
  on the storage nodes — they run only BeeGFS services). Storage link *rate* and *attachment depth*
  are inferred from docs + BeeGFS topology + IPoIB ping uniformity, clearly flagged below.
- SM/MAD fabric discovery remains blocked, so the exact service-leaf switch GUID isn't directly
  observable; "leaf-attached, 3 hops" is established by latency hop-counting instead.
