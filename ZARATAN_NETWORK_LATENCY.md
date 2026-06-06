# Zaratan Network — Per-Link Latency

Investigated 2026-06-06. Companion to `ZARATAN_NETWORK_TOPOLOGY.md`.
Goal: latency of each link in the HDR InfiniBand 2-level fat tree.

## TL;DR

Latency on an InfiniBand fat tree decomposes into three contributors per traversal:

| Component | Value | Source |
|---|---|---|
| Full intra-leaf node→node, 1 switch hop (2×HCA + leaf switch + 2 DAC cables) | **~1.26 µs** one-way (ib_write/ib_send); 2.39 µs read-RTT | **measured** |
| Full inter-leaf node→node, 3 switch hops (leaf→spine→leaf) | **~1.81 µs** one-way (ib_write/ib_send); 3.54 µs read-RTT | **measured** |
| Per extra switch hop, end-to-end (leaf↔spine traversal: ASIC + cable) | **~0.28 µs** (measured); vendor ASIC-only ~90–130 ns | measured diff / NVIDIA QM8700 datasheet |
| Cable propagation | **~5 ns/m** (copper DAC ~4.3, fiber ~5) | physics / cable specs |

So a "link" traversal (cable + the switch port it lands on) costs ~0.1–0.3 µs end-to-end; the bulk
of any latency (~1 µs) is the two HCA/host endpoints, paid once regardless of path. Going from
same-leaf to cross-spine adds **~0.55 µs** total (two extra hops).

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

### Inter-leaf, 3 switch hops — compute-b6-18 (leaf d55ba6) ↔ compute-b6-45 (leaf d85ae0) [job 19815726]

**MEASURED** (2026-06-06 02:17). Path = leaf d55ba6 → spine → leaf d85ae0 (verified the two nodes
are on different leaves). Captured by `interleaf_job.sh` after the cluster freed up — see
"How to replicate the inter-leaf measurement" below for the (non-trivial) scheduling story.

| Tool | t_typical | t_avg | meaning |
|------|----------:|------:|---------|
| ib_write_lat | **1.81 µs** | 1.90 µs | one-way RDMA-write |
| ib_send_lat  | **1.81 µs** | 2.13 µs | one-way send/recv |
| ib_read_lat  | **3.54 µs** | 3.70 µs | round-trip read |

→ Cross-spine node→node (2×HCA + 3 switches + 4 cables incl. 2 leaf↔spine) ≈ **1.81 µs one-way**.
Cross-check: read RTT 3.54 µs ≈ 2 × 1.8 µs, consistent.

### Decomposition (per switch hop) — from measured intra vs inter
The two paths differ by exactly 2 switch hops (the leaf→spine and spine→leaf traversals) + 2
longer cables:

  per-extra-hop ≈ (L_inter − L_intra) / 2  ≈ (1.81 − 1.26) / 2 ≈ **~0.28 µs**  (one-way basis)
  cross-check from read RTT: (3.54 − 2.39) / 4 ≈ **~0.29 µs**  ✓ (consistent)

So each extra hop adds **~0.28 µs end-to-end** = QM87xx switch ASIC (~0.09–0.13 µs port-to-port,
vendor spec) **plus** the leaf↔spine cable propagation + store-and-forward, which dominates the
remainder (~0.15–0.18 µs). That points to relatively **long leaf↔spine links** (tens of metres of
AOC fibre across the machine room) rather than short in-rack DAC — consistent with spine switches
sitting in separate racks/rows from the leaves.

> Note: the earlier *inferred* estimate in this file was ~1.5–1.7 µs (assuming ~0.15 µs/hop). The
> measured value (1.81 µs, ~0.28 µs/hop) is ~0.1–0.3 µs higher — the inference under-counted the
> leaf↔spine cable/store-and-forward contribution. The measured numbers above supersede it.

## Method notes
- Measured with `ib_write_lat` (RDMA write, lowest), `ib_send_lat` (send/recv), `ib_read_lat`.
  These report one-way ≈ half-round-trip latency at the verbs level (excludes MPI overhead).
- Intra-leaf pair and inter-leaf pair chosen from `/etc/slurm/topology.conf` leaf membership.
- SM/MAD tools remain blocked (see topology report), so switch-internal latency counters
  (e.g. per-port) are not directly readable; switch latency taken from vendor spec + the
  intra-vs-inter empirical difference.

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
