# Istio Data Plane Benchmark

A small, reproducible benchmark inspired by [InfraBuilder/k8s-bench-suite](https://github.com/InfraBuilder/k8s-bench-suite) that answers one practical question: **how much does Istio's data plane actually cost?** It measures per-request latency and throughput across Istio's two architectures — the classic **sidecar** and the newer **ambient** mesh — against a no-mesh baseline. Feel free to fork it, tweak the config, and run it on your own cluster, and I'm open to any currections or improvements.

> The short version: **on the Service path, ambient ztunnel is ~5× faster than sidecar on latency and request rate; the sidecar only wins on raw pod2pod TCP bandwidth — and only in no-mTLS mode, because STRICT mTLS rejects pod2pod traffic outright.** The right mode depends on your workload, not on Istio's marketing.

> The desicion of wether you would adopt istio or not has multiple factors, only one is performance. This benchmark is only about performance, and it is not a recommendation to adopt or not adopt Istio. For many teams the maintenance cost is more important.

---

## The question

Istio can run in two fundamentally different ways:

- **Sidecar mode** injects an Envoy proxy into every workload pod. Traffic is intercepted by iptables and proxied through Envoy.
- **Ambient mode** pulls the proxy out of the pod: a node-level **ztunnel** handles L4 for everyone, and an optional **waypoint** proxy handles L7 where you want it.

Both give you the same security and observability story (mostly), but they stress the data plane very differently. This repo measures that difference so you can pick the mode that fits _your_ workload instead of guessing.

## What we measure

| Metric                           | Tool                  | What it tells you                                    |
| -------------------------------- | --------------------- | ---------------------------------------------------- |
| **Bulk TCP throughput** (Mbit/s) | iperf3 (`knb`)        | Raw single-stream bytes/sec (pod2pod)                |
| **HTTP latency + req/s**         | fortio                | Per-request cost and max request rate (pod2svc)      |
| **HTTP bandwidth** (Mbit/s)      | fortio, 64 KB payload | Bytes/sec through the full L7 mesh (pod2svc)         |
| **Raw TCP latency** (µs)         | netperf               | The pure L4 round-trip, no HTTP in the way (pod2pod) |

The tools stress different parts of the data plane, and the two architectures rank _opposite_ on them — that inversion is the whole point of this benchmark.

## Modes under test

Each mode runs the same workload, on the same two nodes, in its own namespace. The namespaces and their mesh config are created by [`setup/setup.sh`](setup/setup.sh):

| Mode             | Namespace                  | Setup                                                       |
| ---------------- | -------------------------- | ----------------------------------------------------------- |
| no mesh          | `benchmark`                | plain namespace                                             |
| sidecar, no mTLS | `benchmark-sidecar-nomtls` | `istio-injection: enabled` + `PeerAuthentication` `DISABLE` |
| sidecar, mTLS    | `benchmark-sidecar-mtls`   | `istio-injection: enabled` + `PeerAuthentication` `STRICT`  |
| ambient ztunnel  | `benchmark-ztunnel`        | `istio.io/dataplane-mode: ambient`                          |
| ambient waypoint | `benchmark-waypoint`       | ambient + `istioctl waypoint apply --enroll-namespace`      |

> Istio's default mTLS is **PERMISSIVE**, not STRICT — so the "mTLS" mode is only meaningful because `setup/peerauthentication.yaml` applies an explicit `STRICT` policy.

## Architecture at a glance

```
sidecar mode                          ambient mode
─────────────                         ─────────────
 pod ──► envoy ──► ... ──► envoy ──► pod      pod ──► ztunnel ──► ... ──► ztunnel ──► pod
       (per pod, L7)                                (per node, L4, mTLS)
        + 2 extra hops, L7 parsing                   + 1 hop, but a per-byte tunnel cost
                                                    (waypoint adds an L7 hop for services only)
```

- **Sidecar** is Envoy per pod. The TCP proxy path is near wire-speed once a connection is up, so bulk transfers stay fast — but every request pays two extra L7 hops (L7 parsing).
- **Ambient** is ztunnel per node. Connection setup and per-request cost are low, but traffic is tunneled through a userspace L4 proxy, which caps single-stream bandwidth.

Official docs: [sidecar mode](https://istio.io/latest/docs/setup/additional-setup/sidecar-mode/), [ambient overview](https://istio.io/latest/docs/ambient/overview/), [ambient architecture (ztunnel + waypoint)](https://istio.io/latest/docs/ambient/architecture/).

## Summary of findings

| Test | no mesh | sidecar no-mTLS | sidecar mTLS | ambient ztunnel | ambient waypoint |
|---|---|---|---|---|---|
| HTTP latency, fixed 5000 qps (pod2svc, µs) | ~200 | ~2564 | ~2766 | ~557 | ~3082 |
| HTTP max throughput (pod2svc, req/s) | ~99k | ~6.5k | ~6.2k | ~35k | ~5.3k |
| HTTP bandwidth, fortio (Mbit/s) | ~7888 | ~2492 | ~1793 | ~4321 | ~1338 |
| Bulk TCP bandwidth, iperf3 pod2svc (Mbit/s) | ~7694 | ~6501 | ~5187 | ~3790 | ~2469 |
| Bulk TCP bandwidth, iperf3 pod2pod (Mbit/s) | ~7140 | ~6897 | n/a | ~3804 | ~3580 |
| Raw TCP_RR latency (pod2pod, µs) | ~60 | ~178 | n/a | ~205 | ~197 |

What this means in practice:

1. **Request-oriented workloads (RPC, APIs) favor ztunnel.** On the Service path at fixed 5000 qps, ztunnel adds ~357 µs over baseline while a sidecar adds ~2.6 ms; ztunnel sustains ~5.6× more requests/sec and ~2.4× more HTTP bandwidth.
2. **STRICT mTLS rejects pod2pod traffic.** The sidecar needs the destination's Service identity to do mTLS, so direct pod-IP connections fail (fortio returns 503; iperf3/netperf hang); only Service (pod2svc) traffic works under STRICT mTLS.
3. **mTLS cost is real on the mean, larger on the tail.** Sidecar STRICT mTLS is ~8% slower than no-mTLS on the mean (2766 vs 2564 µs), but the fixed-QPS p99 is ~2.3× worse (11.0 ms vs 4.7 ms) — needs a repeat run to confirm it isn't single-sample noise.
4. **A single-replica waypoint is the slowest on the Service path.** With the waypoint scaled to 1 instance (to match the sidecar's one-pod cost), pod2svc is 3082 µs — slower than the sidecar — because a lone cross-node L7 hop becomes the bottleneck. Its pod2pod stays ztunnel-only, confirming the waypoint only intercepts Service traffic.
5. **Raw bulk TCP favors the sidecar, even under STRICT mTLS via the Service.** pod2pod iperf3 loses only ~3% with a DISABLE sidecar but ~47% with ztunnel; via the Service the STRICT-mTLS sidecar still keeps ~5187 Mbit/s vs ztunnel's ~3790 Mbit/s.

Notes about the benchmark:

1. You can't disable mTLS on ambient mode.
2. In ambient mode the waypoint proxy runs on a node of its own, so for some pods/connections it has locality but for others the L7 hop crosses nodes, adding latency. Here the waypoint is scaled to a single replica (to match the sidecar's one-pod-per-workload cost), so this effect is a single cross-node hop rather than load-balanced — a 3-replica HA waypoint behaves differently.

## Results

The full report lives in [`results/REPORT.md`](results/REPORT.md), with plots in [`results/plots/`](results/plots/). Each mode has a folder under `results/<mode>/` holding its bandwidth report, latency JSON, and raw logs — everything is committed, including the raw per-pod logs.

## Run it yourself

Requirements: `kubectl` + `istioctl` (for the waypoint mode), `python3` + `matplotlib` (for plots), and the `knb-netperf` image pushed to a registry your cluster can pull from.

```bash
# 1. create namespaces + mesh config (PeerAuthentication STRICT/DISABLE, waypoint)
./setup/setup.sh

# 2. run the full benchmark
export NETPERF_IMAGE=<your-registry>/knb-netperf:latest
./k8s-bench-suite/run-all.sh
```

`run-all.sh` runs everything in sequence — the original `knb` bandwidth benchmark, the latency benchmark at max and fixed QPS, then the comparison table, plots, and markdown report. All config (nodes, context, duration, QPS, images) lives in [`k8s-bench-suite/config.sh`](k8s-bench-suite/config.sh), sourced by every script so there's a single source of truth. See `k8s-bench-suite/README.md` for the `knb` tool itself.

## Repository layout

```
.
├── setup/                    # mesh setup (namespaces, PeerAuthentication, waypoint)
│   ├── setup.sh
│   ├── namespaces.yaml
│   └── peerauthentication.yaml
├── k8s-bench-suite/          # the tools
│   ├── config.sh             #   single source of truth (nodes, modes, images, QPS)
│   ├── knb                   #   original bandwidth benchmark (iperf3)
│   ├── knb-latency           #   latency benchmark (netperf + fortio)
│   ├── run-all.sh            #   orchestrates the whole thing
│   ├── run-latency.sh        #   latency-only runner (2 passes)
│   ├── compare-latency.sh    #   text comparison table
│   ├── plot-report.py        #   generates the plots
│   ├── gen-report.py         #   generates REPORT.md from the JSON
│   └── docker-bench-*/       #   benchmark container images
└── results/                  # the results (one folder per mode)
    ├── REPORT.md             #   the full markdown report
    ├── comparison.txt        #   text comparison table
    ├── plots/                #   PNG plots
    └── <mode>/               #   e.g. simple/, ztunnel/, waypoint/
        ├── bandwidth.knbdata     # knb bulk-throughput report
        ├── latency-maxqps.json   # latency at saturation
        ├── latency-fixed<qps>.json
        ├── raw-maxqps/           # raw per-pod logs & metrics
        └── raw-fixed<qps>/
```

## License

[MIT](LICENSE). The `knb` tool is © infraBuilder (MIT); the latency tooling and report generation are new here.
