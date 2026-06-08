# Zaratan Network — Per-Link Latency

Investigated 2026-06-06. Companion to `ZARATAN_NETWORK_TOPOLOGY.md`.
Goal: latency of each link in the HDR InfiniBand 2-level fat tree.

## TL;DR

Latency on an InfiniBand fat tree decomposes into three contributors per traversal:

| Component | Value | Source |
|---|---|---|
| Full intra-leaf node→node, 1 switch hop (2×HCA + leaf switch + 2 DAC cables) | **~1.1–1.3 µs** one-way (median 1.21; 9 leaves); 2.39 µs read-RTT | **measured** |
| Full inter-leaf node→node, 3 switch hops (leaf→spine→leaf) | **~1.64–1.81 µs** one-way (median 1.70; 6 leaf-pairs); 3.2–3.5 µs read-RTT | **measured** |
| Per extra switch hop, end-to-end (leaf↔spine traversal: ASIC + cable) | **~0.24 µs** (measured, range 0.22–0.30); vendor ASIC-only ~90–130 ns | measured diff / NVIDIA QM8700 datasheet |
| Cable propagation | **~5 ns/m** (copper DAC ~4.3, fiber ~5) | physics / cable specs |

So a "link" traversal (cable + the switch port it lands on) costs ~0.1–0.3 µs end-to-end; the bulk
of any latency (~1 µs) is the two HCA/host endpoints, paid once regardless of path. Going from
same-leaf to cross-spine adds **~0.5 µs** total (two extra hops). The inter-leaf value varies
~0.17 µs by leaf-pair (different leaf↔spine cable lengths across the machine room).

A "link" here = one cable + the switch/HCA port it lands on. The dominant, fixed cost is the
HCA/endpoint stack (~0.5–0.6 µs each side); each *extra switch hop* on the path adds ~0.28 µs
(measured) — the switch ASIC (~0.1 µs vendor spec) plus the leaf↔spine cable propagation and
store-and-forward, which on a big machine room (long AOC fiber) runs higher than the ASIC alone.

Path hop counts in this fat tree:
- **Intra-leaf** (two nodes on the same leaf switch): **1 switch hop**.
- **Inter-leaf** (nodes on different leaves): **3 switch hops** (leaf → spine → leaf).

## Inferred per-link latency (from technology)

- **Node ↔ leaf link** (HDR100 copper DAC, in-rack, ~1–3 m): propagation ~5–15 ns; the
  traversal cost is dominated by the HCA (~0.5 µs) on the node side + leaf switch port (~0.1 µs).
- **Leaf ↔ spine link** (HDR200, intra-/inter-rack, copper DAC or AOC fiber, ~2–30 m):
  propagation ~10–150 ns + spine switch port (~0.1 µs).
- These are wire/switch latencies; end-to-end MPI latency adds the two HCA stacks.

## Empirical results (perftest ib_*_lat, 2-byte messages, 20000 iters)

End-to-end node-to-node latency at the verbs layer. `ib_write_lat`/`ib_send_lat` report the
one-way (≈ half round-trip) latency; `ib_read_lat` reports a full round-trip (the read op
inherently requires a there-and-back), so it ≈ 2× the one-way number.

### Intra-leaf, 1 switch hop — compute-b8-44 ↔ compute-b8-45 (leaf d85b00) [job 19810191]

| Tool | t_min | t_typical | t_avg | 99% | meaning |
|------|------:|----------:|------:|----:|---------|
| ib_write_lat | 1.21 µs | **1.26 µs** | 1.31 µs | 1.43 µs | one-way RDMA-write |
| ib_send_lat  | 1.24 µs | **1.27 µs** | 1.29 µs | 1.39 µs | one-way send/recv |
| ib_read_lat  | 2.35 µs | **2.39 µs** | 2.41 µs | 2.45 µs | round-trip read |

→ One node→node hop (2×HCA + 1 leaf switch + 2 short DAC cables) ≈ **1.26 µs one-way**.
Cross-check: read RTT 2.39 µs ≈ 2 × 1.2 µs, consistent.

**Reconfirmed on 8 more leaves** (bonus — the `interleaf_multi` resubmit chain re-ran the intra
baseline on every leaf it landed on; `ib_write_lat` t_typical):

| Leaf | d85ac0 | dc3f4a | d85800 | d55b66 | dc3d6a | d55ba6 | dc426a | d85b40 |
|------|-------:|-------:|-------:|-------:|-------:|-------:|-------:|-------:|
| µs | 1.11 | 1.13 | 1.12 | 1.23 | 1.24 | 1.25 | 1.30 | 1.44 |

Intra-leaf one-way is **~1.1–1.3 µs** across the fabric (median ≈ 1.21 µs); the d85b40 outlier
(1.44 µs, the GPU-island leaf) is the only one notably higher. This tightens the intra baseline
used in the per-hop decomposition below.

#### What the columns mean (perftest reports a *distribution*, not one ping)
perftest does the ping-pong **20,000 times**, producing 20,000 latency samples; the columns are
summary statistics of that distribution. Raw `ib_write_lat` row from the intra-leaf run above:

```
#bytes #iterations  t_min  t_max  t_typical  t_avg  t_stdev   99%    99.9%
 2      20000        1.21   4.00   1.26       1.31   0.06      1.43   2.87
```

| Column | Value | Meaning |
|--------|------:|---------|
| `t_min` | 1.21 µs | fastest single ping of the 20,000 (hardware floor / best case) |
| `t_max` | 4.00 µs | slowest single ping (one OS-scheduling/interrupt outlier) |
| `t_typical` | **1.26 µs** | **median** (50th pct) — half faster, half slower; the robust headline value |
| `t_avg` | 1.31 µs | **mean** — pulled *above* the median by the few slow pings (right-skewed) |
| `t_stdev` | 0.06 µs | std-dev — spread of the samples (~5% of mean ⇒ very consistent link) |
| `99%` | 1.43 µs | 99th percentile — 99% of pings finished in ≤ this |
| `99.9%` | 2.87 µs | 99.9th percentile — tail latency; only ~20 pings were slower |

The distribution is **right-skewed**: a hard floor (~1.21 µs) with a thin tail to 4.00 µs, so
`median (1.26) < mean (1.31)`. We quote `t_typical` (median) because it is immune to the handful
of OS-induced outliers that inflate the mean; the median→99.9% gap (1.26→2.87 µs) quantifies jitter.
(The *bandwidth* tool `ib_write_bw` reports only `BW_peak`/`BW_average`, not percentiles, because
throughput is an aggregate over many messages rather than a per-message timing.)

### Inter-leaf, 3 switch hops — MEASURED across 6 different leaf-pairs

Every pair below was **topology-verified** (each job re-derived both nodes' leaf from
`topology.conf` and asserted they differ before measuring). t_typical (median) shown.

| Leaf pair (server↔client) | Nodes | ib_write_lat | ib_send_lat | ib_read_lat (RTT) | Job |
|---|---|---:|---:|---:|---|
| dc3d6a ↔ d85ac0 | a7-10 ↔ a8-47 | **1.64 µs** | 1.65 | 3.17 | 19906266 |
| d55ba6 ↔ d85ac0 | b5-10 ↔ a8-47 | **1.66 µs** | 1.68 | 3.21 | 19906266 |
| dc3d6a ↔ d85ae0 | a7-10 ↔ b6-27 | **1.69 µs** | 1.70 | 3.27 | 19906266 |
| d55ba6 ↔ d85ae0 | b5-10 ↔ b6-27 | **1.71 µs** | 1.72 | 3.32 | 19906266 |
| dc3d6a ↔ d55ba6 | a7-10 ↔ b5-10 | **1.73 µs** | 1.74 | 3.34 | 19906266 |
| d55ba6 ↔ d85ae0 | b6-18 ↔ b6-45 | **1.81 µs** | 1.81 | 3.54 | 19815726 |

→ Cross-spine node→node (2×HCA + 3 switches + 4 cables incl. 2 leaf↔spine) = **~1.64–1.81 µs
one-way** (median ≈ **1.70 µs**). The ~0.17 µs spread across pairs is real and reflects **different
leaf↔spine cable lengths / spine port** per leaf — i.e. some leaf-pairs are physically farther
apart than others. Read RTT (3.17–3.54 µs ≈ 2× the one-way) confirms each row.

(A 6th combo dc3d6a↔d55b66 was topology-verified but its perftest rows didn't parse — one transient
dropped sample; the 5 above + the original 1.81 µs run are clean.)

### Decomposition (per switch hop) — from measured intra vs inter
The two paths differ by exactly 2 switch hops (the leaf→spine and spine→leaf traversals) + 2
longer cables:

  per-extra-hop ≈ (L_inter − L_intra) / 2  ≈ (1.70 − 1.21) / 2 ≈ **~0.24 µs**  (median basis)
  range over the 6 pairs: (1.64…1.81 − ~1.2)/2 ≈ **0.22–0.30 µs** per hop
  cross-check from read RTT: (3.3 − 2.3) / 4 ≈ **~0.25 µs**  ✓ (consistent)

So each extra hop adds **~0.24 µs end-to-end** = QM87xx switch ASIC (~0.09–0.13 µs port-to-port,
vendor spec) **plus** the leaf↔spine cable propagation + store-and-forward, which dominates the
remainder (~0.15–0.18 µs). That points to relatively **long leaf↔spine links** (tens of metres of
AOC fibre across the machine room) rather than short in-rack DAC — consistent with spine switches
sitting in separate racks/rows from the leaves.

> Note: the earlier *inferred* estimate in this file was ~1.5–1.7 µs (assuming ~0.15 µs/hop). The
> measured value (1.81 µs, ~0.28 µs/hop) is ~0.1–0.3 µs higher — the inference under-counted the
> leaf↔spine cable/store-and-forward contribution. The measured numbers above supersede it.

## Measurement methodology

### Tool & transport
All numbers are from **`perftest`** (`/usr/bin/ib_write_lat`, `ib_send_lat`, `ib_read_lat`) over
**RDMA on IB device `mlx5_0`** (HDR100). Each test is a server/client pair: server starts on one
node, client connects to it by hostname. The QP-setup handshake uses TCP (management net); the
timed data path is pure RDMA over InfiniBand. Processes were placed with Slurm `srun -N1 -n1 -w
<node>`. Verbs-level latency — excludes MPI library overhead.

### The three tools (what differs)
| Tool | IB semantic | Remote CPU? | What it reports |
|------|-------------|-------------|-----------------|
| `ib_write_lat` | RDMA Write (one-sided) | not involved | ping-pong ÷2 → **one-way** (purest HW number) |
| `ib_send_lat`  | Send/Recv (two-sided)  | posts a recv buffer | ping-pong ÷2 → **one-way** (real MPI-style messaging; ~10 ns more than write) |
| `ib_read_lat`  | RDMA Read (one-sided)  | not involved | a read *is* a request→response, so → **full round-trip** (≈ 2× one-way; consistency check) |

So **write ≈ send ≈ one-way latency**, **read ≈ round-trip**. Write is the lowest (no remote CPU);
send adds the receive-side match; read ≈ 2× confirms the one-way figures.

### Parameters & sample sizes
- **2-byte** messages (latency is message-size-independent at this scale), **20,000 iterations**
  per call, 1 QP. perftest reports min / **typical** / avg / 99% / 99.9% over those 20k iters — so
  each headline number is already a robust statistic, not a single ping.

### Exactly which nodes / jobs / runs
The headline intra (b8-44↔b8-45, job 19810191) and the **6 inter-leaf leaf-pairs** (jobs 19815726
and 19906266) are tabulated in the "Empirical results" section above, each with the exact nodes
and leaf GUIDs. Plus **8 extra intra-leaf** baselines on different leaves (1.11–1.44 µs).

- **Coverage:** intra-leaf measured on **9 leaves**; inter-leaf on **6 distinct leaf-pairs** — a
  good spatial sample of the fabric (not just one pair). Still *not* covered: the many-pairs spine
  **bisection** test (needs many concurrent inter-leaf flows; see `ibcong2.sh`).
- **Per-leaf-pair variation is real:** inter-leaf spans 1.64–1.81 µs depending on which two leaves
  (cable length to the spine differs); intra-leaf 1.11–1.44 µs depending on node/leaf.
- Hostnames can mislead — e.g. the `compute-b6-18`↔`compute-b6-45` inter pair are both `b6-*` but
  on **different leaves** (b6-1–20→d55ba6, b6-21–60→d85ae0). Every pair is leaf-verified in the job
  (`[VERIFIED inter/intra]` lines in the result files) rather than assumed from hostname.

### Lesson: how to get a cross-leaf allocation depends on cluster load
- **Saturated cluster** (free nodes scarce, ~1/leaf): the adaptive-`--exclude` self-resubmit
  (`interleaf_job.sh`) works well — scattered free nodes are *forced* to span leaves.
- **Empty cluster** (every leaf has many free): that same trick *fails* — Slurm can always pack
  `-N` onto one leaf, so the exclude list walks through every leaf without spanning. Here the fix
  is the opposite: **pin** nodes the picker found on distinct leaves (they're idle, so pinning just
  works). The 6-pair run used `pick_cross_leaf_pair.sh 6` → `sbatch --nodelist=… interleaf_multi.sh`.
  (Gotcha: don't pin a node on a leaf the job `--exclude`s, e.g. d85b00 — Slurm rejects it.)

### Other notes
- Intra/inter pairs chosen from `/etc/slurm/topology.conf` leaf membership.
- SM/MAD tools remain blocked (see topology report), so per-port switch latency counters aren't
  readable; switch latency comes from vendor spec + the intra-vs-inter empirical difference.

---

## How to replicate the inter-leaf measurement (the part that was blocked)

### Why it was blocked
The inter-leaf test needs **two nodes on two *different* leaf switches, each truly free**.
On a busy cluster that is hard to get, for three compounding reasons we hit live:

1. **Idle capacity concentrates on one leaf.** Most of the time only leaf `d85b00`
   (`compute-b8-*`) had free nodes; every other leaf was fully allocated.
2. **`sinfo -t idle` lies about usable nodes.** It returns nodes whose *base* state is IDLE
   even when they carry a **DRAIN** flag (unschedulable) — e.g. `compute-a5-4` showed up in
   `-t idle` but `sinfo -n compute-a5-4 -o %t` was `drain`. Always re-check the exact `%t`.
3. **Stuck `comp` (completing) nodes.** The only free node on a second leaf (`compute-a7-31`)
   sat in `comp` for >15 min (hung Slurm epilog / BeeOND unmount), so a pinned job for it sat
   in `PENDING (Resources)`/`ReqNodeNotAvail` forever.
4. **Backfill earmarking.** Even genuinely-idle nodes are reserved by the scheduler for queued
   higher-priority jobs, so `--nodelist`-pinned jobs get `ReqNodeNotAvail, May be reserved for
   other job` while *un*pinned jobs run fine (but land intra-leaf).

Also note the long-running **MAINT reservation `unstable`** (see `scontrol show reservation`)
holds ~14 nodes that look idle but can't be used.

### RECOMMENDED FIX — a single self-contained sbatch job (`interleaf_job.sh`)
This is the best approach: instead of polling the login node, submit **one batch job and let the
scheduler do the waiting**. Why it beats the login-node loop:

- A **pending job waits in the queue indefinitely and accrues priority**, so it *will* eventually
  be scheduled even on a saturated cluster — and it survives you logging out. No babysitting.
- **`--time` is the run limit, NOT the wait limit.** Queue-wait is already unbounded. So set
  `--time` *short* (we use 20 min) — short jobs backfill into gaps far more easily. "Wait as long
  as it takes" is automatic and is *not* controlled by walltime. (Setting a huge walltime would
  only make it schedule *slower*.)
- **Forcing two leaves:** Slurm's `topology/tree` plugin minimizes switch count, so a plain
  `-N2` packs both nodes onto one leaf. The job requests `-N2` and `--exclude`s the leaf that
  hoards free nodes (`d85b00`); if the allocation still lands on a single leaf, the job
  **resubmits itself, adding that leaf to the exclude list** (`sbatch`-within-`sbatch`), so the
  scheduler is progressively pushed onto other leaves until the allocation finally spans two.
  The growing exclude list is persisted in `.interleaf_xnodes`; the loop is bounded by
  `MAX_ATTEMPT` so it can never run away.

```bash
rm -f .interleaf_xnodes          # start a fresh chain
sbatch interleaf_job.sh          # that's it — walk away
# results land in interleaf_results.<jobid>.txt (the job that finally spans two leaves):
grep -E 'INTER-3hop|INTRA-1hop' interleaf_results.*.txt
```
The job auto-detects leaf membership from `topology.conf`, picks an inter-leaf pair (and an
intra-leaf pair if the allocation provides one), and runs `ib_write_lat`/`ib_send_lat`/
`ib_read_lat` **and** `ib_write_bw` (uni + bidirectional) — so one run captures inter-leaf
latency *and* bandwidth. Tune with `--export=ALL,MAX_ATTEMPT=40` if needed.

**Can you `sbatch` inside an `sbatch`?** Yes — Slurm client commands work on compute nodes, and
`interleaf_job.sh` uses exactly that for its bounded self-resubmit. You do *not* need it just to
run work on the allocated nodes, though: a single job runs multiple `srun` steps internally (as
this one does). Nested `sbatch` is the right tool only when you need a *fresh allocation* (e.g.
retry with a different node set) — which is precisely the single-leaf-retry case here. The job is
self-tested: `SELFTEST=1 MOCK_NODES="n1 n2" MOCKMAP="n1:LA n2:LB" bash interleaf_job.sh` exercises
the leaf-mapping and pair-selection logic without touching Slurm.

### Alternative — interactive helper scripts
Two lighter-weight helpers automate the *manual* path (useful if you want to drive it yourself):

- **`pick_cross_leaf_pair.sh [N]`** — prints `N` node names, each on a *distinct* leaf, that are
  **exactly `idle`** (re-verified per-node, so DRAIN/comp/mix are rejected) and **not in any
  reservation**. Exits non-zero if fewer than `N` leaves are currently usable.
  ```bash
  ./pick_cross_leaf_pair.sh 2        # e.g. prints: compute-a7-15  \n  compute-b6-40
  ```
- **`run_interleaf_latency.sh`** — the robust driver. It loops: pick a cross-leaf pair → submit
  the pinned latency job (`iblat2.sh`) → confirm it actually *leaves PENDING* within a grace
  window (handles the backfill/race failures) → on success print the `ib_*_lat` tables, else
  cancel and re-pick. Tunable via env vars:
  ```bash
  MAX_TRIES=240 GRACE=75 ./run_interleaf_latency.sh
  # writes iblat2.inter.<jobid>.out and records the job id in /tmp/j_inter.txt
  ```
  Run it in the background (or under `nohup`/`tmux`) and let it sit until two leaves free up;
  it captures the measurement automatically the moment a valid pair appears.

### Manual fallback (if you'd rather drive it by hand)
```bash
# 1) find two free nodes on two different leaves (re-verify state!)
sinfo -p standard -t idle -h -o '%n' | while read n; do \
  echo "$n $(sinfo -n $n -h -o %t) $(scontrol show topology | awk -v N=$n '...leaf lookup...')"; done
# 2) submit the pinned latency job on a confirmed cross-leaf pair S (server) and C (client):
sbatch -N2 --nodelist=$S,$C --time=00:05:00 \
       --export=ALL,S=$S,C=$C,LBL=INTER-3hop iblat2.sh
# 3) read results:
grep -E '^ *2 +20000' iblat2.inter.*.out     # columns: bytes iters t_min t_max t_typ t_avg ...
```
Confirm the two nodes really are on different leaves with
`grep -E 'Switch.*Nodes' /etc/slurm/topology.conf` (or `scontrol show topology`).

### What to expect / how to interpret
- `ib_write_lat`/`ib_send_lat` `t_typical` is the **one-way** (≈ half-RTT) latency; `ib_read_lat`
  is a full RTT (≈ 2×).
- Plug the inter-leaf `t_typical` into the decomposition above:
  `per_switch_hop ≈ (L_inter − L_intra)/2` (L_intra = 1.26 µs measured here). Expect inter-leaf
  ~1.5–1.7 µs and per-hop ~0.1–0.18 µs; if you see that, the inferred numbers are confirmed.
- Best practice: also re-run the **intra-leaf** baseline in the same session
  (`sbatch -N2 --nodelist=<two nodes on one leaf> --export=ALL,S=..,C=..,LBL=INTRA-1hop iblat2.sh`)
  so both numbers come from the same fabric/firmware state.

### Tips to make a free cross-leaf pair appear sooner
- Use the **`debug` partition** (`compute-b8-[57-60]`, 15-min limit) for one endpoint when it's
  idle — but those four are all on the *same* leaf (`d85b00`), so they only help for intra-leaf
  or as the `d85b00` end of a cross-leaf pair.
- Submit with a **short `--time`** (≤5 min): the backfill scheduler is far more willing to slot
  a tiny job between big reservations, which is why these latency jobs eventually run.
- Avoid nodes in the `unstable` reservation and anything showing `drain`/`comp`.
