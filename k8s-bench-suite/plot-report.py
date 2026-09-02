#!/usr/bin/env python3
"""
Generate the full set of report plots for the Istio mesh latency/throughput
benchmark. Reads latency-<mode>.json (max qps), latency-<mode>-qps5000.json
(fixed qps) and knb-throughput.json (bulk iperf3 bandwidth).
"""
import json
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

# NOTE: must match k8s-bench-suite/config.sh MODES / MODES_ORDER exactly.
MODES = ["simple", "sidecar-nomtls", "sidecar-mtls", "ztunnel", "waypoint"]
MODE_LABELS = {
    "simple": "no mesh",
    "sidecar-nomtls": "sidecar\nno-mTLS",
    "sidecar-mtls": "sidecar\nmTLS",
    "ztunnel": "ambient\nztunnel",
    "waypoint": "ambient\nwaypoint",
}
MODE_COLORS = {
    "simple": "#4c72b0",
    "sidecar-nomtls": "#dd8452",
    "sidecar-mtls": "#c44e52",
    "ztunnel": "#55a868",
    "waypoint": "#8172b3",
}
METRICS = ["mean_us", "p50_us", "p90_us", "p99_us"]
METRIC_TITLES = ["mean", "p50", "p90", "p99"]


def load(results_dir, name):
    """Load latency-<name>.json from each <mode>/ subdir."""
    out = {}
    for mode in MODES:
        path = os.path.join(results_dir, mode, f"latency-{name}.json")
        if os.path.exists(path):
            with open(path) as f:
                out[mode] = json.load(f)["data"]
    return out


def to_float(v):
    try:
        v = float(v)
    except (TypeError, ValueError):
        return np.nan
    return v if v > 0 else np.nan


def metric(mode_data, test, key):
    if test not in mode_data:
        return np.nan
    return to_float(mode_data[test].get(key))


def grouped_bars(ax, modes, tests, getter, xlabels, title, ylabel, log=False):
    x = np.arange(len(tests))
    width = 0.8 / max(len(modes), 1)
    for i, mode in enumerate(modes):
        vals = [getter(mode, t) for t in tests]
        ax.bar(x + (i - len(modes) / 2) * width + width / 2, vals, width,
               label=MODE_LABELS[mode], color=MODE_COLORS[mode])
    ax.set_xticks(x)
    ax.set_xticklabels(xlabels)
    ax.set_title(title, fontsize=11, fontweight="bold")
    ax.set_ylabel(ylabel)
    if log:
        ax.set_yscale("log")
    ax.grid(axis="y", alpha=0.3, linestyle="--")


def finalize(fig, axes, title, note=None, ncol=None):
    """Common layout: suptitle on top, a single legend at the bottom (so it
    never overlaps the title), and an optional italic note under the title."""
    ax0 = np.asarray(axes).flat[0]
    handles, labels = ax0.get_legend_handles_labels()
    fig.suptitle(title, fontsize=14, fontweight="bold", y=0.99)
    if note:
        fig.text(0.5, 0.94, note, ha="center", va="top",
                 fontsize=9, style="italic", color="#555555")
    fig.legend(handles, labels, loc="lower center", bbox_to_anchor=(0.5, 0.0),
               ncol=ncol or len(handles), fontsize=9, frameon=False)
    fig.subplots_adjust(top=0.86, bottom=0.12, hspace=0.35)


def latency_figure(data, fname, title, xlabels, note=None):
    fig, axes = plt.subplots(2, 2, figsize=(13, 9))
    for ax, mk, mt in zip(axes.flat, METRICS, METRIC_TITLES):
        getter = lambda mode, t: metric(data[mode], t, mk)
        grouped_bars(ax, list(data.keys()), ["http-p2p", "http-p2s"], getter,
                     xlabels, f"{title} — {mt}", "microseconds", log=True)
    finalize(fig, axes, title, note=note)
    fig.savefig(fname, dpi=120, bbox_inches="tight")
    plt.close(fig)


def main():
    results_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    fixed_qps = os.environ.get("FIXED_QPS", "5000")
    plots_dir = os.path.join(results_dir, "plots")
    os.makedirs(plots_dir, exist_ok=True)

    maxq = load(results_dir, "maxqps")
    fixed = load(results_dir, f"fixed{fixed_qps}")

    with open(os.path.join(results_dir, "knb-throughput.json")) as f:
        knb = json.load(f)

    def _knb(m, which):
        v = knb.get(m)
        if isinstance(v, dict):
            return to_float(v.get(which))
        return to_float(v) if which == "p2p" else np.nan

    knb_p2p = {m: _knb(m, "p2p") for m in MODES}
    knb_p2s = {m: _knb(m, "p2s") for m in MODES}

    modes = [m for m in MODES if m in maxq]

    # 1. HTTP latency at max QPS (saturation)
    latency_figure(maxq, os.path.join(plots_dir, "latency-http-maxqps.png"),
                   "HTTP latency at saturation (max QPS)", ["pod2pod", "pod2svc"],
                   note="missing pod2pod bars (sidecar mTLS) = STRICT mTLS rejects direct pod-IP traffic (HTTP 503)")

    # 2. HTTP latency at fixed QPS (apples-to-apples)
    if fixed:
        latency_figure(fixed, os.path.join(plots_dir, f"latency-http-fixed{fixed_qps}.png"),
                       f"HTTP latency at fixed {fixed_qps} QPS", ["pod2pod", "pod2svc"],
                       note="missing pod2pod bars (sidecar mTLS) = STRICT mTLS rejects direct pod-IP traffic (HTTP 503)")

    # 3. Throughput: HTTP qps + bulk TCP bandwidth + HTTP bandwidth
    fig, axes = plt.subplots(1, 3, figsize=(19, 6))
    x = np.arange(len(modes))
    qps = [to_float(maxq[m]["http-p2s"].get("rate")) for m in modes]
    axes[0].bar(x, qps, color=[MODE_COLORS[m] for m in modes])
    axes[0].set_xticks(x)
    axes[0].set_xticklabels([MODE_LABELS[m] for m in modes], fontsize=9)
    axes[0].set_title("HTTP max throughput (qps)", fontweight="bold")
    axes[0].set_ylabel("requests / second")
    for i, v in enumerate(qps):
        if not np.isnan(v):
            axes[0].text(i, v, f"{v:,.0f}", ha="center", va="bottom", fontsize=8)
    axes[0].grid(axis="y", alpha=0.3, linestyle="--")

    bw = [knb_p2s.get(m) for m in modes]
    axes[1].bar(x, bw, color=[MODE_COLORS[m] for m in modes])
    axes[1].set_xticks(x)
    axes[1].set_xticklabels([MODE_LABELS[m] for m in modes], fontsize=9)
    axes[1].set_title("Bulk TCP bandwidth, iperf3 pod2svc (Mbit/s)", fontweight="bold")
    axes[1].set_ylabel("Mbit/s")
    for i, v in enumerate(bw):
        if not np.isnan(v):
            axes[1].text(i, v, f"{v:,}", ha="center", va="bottom", fontsize=8)
    axes[1].grid(axis="y", alpha=0.3, linestyle="--")

    hbw = [to_float(maxq[m].get("httpbw-p2s", {}).get("bw_mbps")) for m in modes]
    axes[2].bar(x, hbw, color=[MODE_COLORS[m] for m in modes])
    axes[2].set_xticks(x)
    axes[2].set_xticklabels([MODE_LABELS[m] for m in modes], fontsize=9)
    axes[2].set_title("HTTP bandwidth, fortio (Mbit/s)", fontweight="bold")
    axes[2].set_ylabel("Mbit/s")
    for i, v in enumerate(hbw):
        if not np.isnan(v):
            axes[2].text(i, v, f"{v:,}", ha="center", va="bottom", fontsize=8)
    axes[2].grid(axis="y", alpha=0.3, linestyle="--")

    fig.suptitle("Throughput: HTTP requests, bulk TCP bytes, HTTP bytes", fontsize=13, fontweight="bold")
    fig.text(0.5, 0.90, "bulk TCP is measured via the Service (pod2svc) — the only iperf3 path that works under STRICT mTLS",
             ha="center", fontsize=9, style="italic", color="#555555")
    fig.tight_layout(rect=[0, 0, 1, 0.90])
    fig.savefig(os.path.join(plots_dir, "throughput.png"), dpi=120, bbox_inches="tight")
    plt.close(fig)

    # 4. netperf raw TCP latency
    fig, axes = plt.subplots(2, 2, figsize=(13, 9))
    for ax, mk, mt in zip(axes.flat, METRICS, METRIC_TITLES):
        getter = lambda mode, t: metric(maxq[mode], t, mk)
        grouped_bars(ax, modes, ["tcprr-p2p", "tcpcrr-p2p"], getter,
                     ["TCP_RR", "TCP_CRR"], f"Raw TCP latency — {mt}", "microseconds", log=True)
    finalize(fig, axes, "Raw TCP latency (netperf)",
             note="missing bars = test failed (STRICT mTLS rejects pod2pod; TCP_CRR resets through any sidecar)")
    fig.savefig(os.path.join(plots_dir, "latency-netperf.png"), dpi=120, bbox_inches="tight")
    plt.close(fig)

    # 5. Relative latency penalty vs baseline (mean, Service path)
    base_max = to_float(maxq["simple"]["http-p2s"].get("mean_us"))
    fig, axes = plt.subplots(1, 2, figsize=(14, 6))
    for ax, data, base, ttl in [
        (axes[0], maxq, base_max, "At saturation (max QPS)"),
        (axes[1], fixed, to_float(fixed["simple"]["http-p2s"].get("mean_us")) if fixed else np.nan, f"At fixed {fixed_qps} QPS"),
    ]:
        rel = [metric(data[m], "http-p2s", "mean_us") / base if base else np.nan for m in modes]
        ax.bar(x, rel, color=[MODE_COLORS[m] for m in modes])
        ax.axhline(1.0, color="black", linewidth=0.8, linestyle="--")
        ax.set_xticks(x)
        ax.set_xticklabels([MODE_LABELS[m] for m in modes], fontsize=9)
        ax.set_title(f"Latency penalty vs no-mesh — {ttl}", fontweight="bold")
        ax.set_ylabel("x slower than no-mesh (mean)")
        for i, v in enumerate(rel):
            if not np.isnan(v):
                ax.text(i, v, f"{v:.1f}x", ha="center", va="bottom", fontsize=8)
        ax.grid(axis="y", alpha=0.3, linestyle="--")
    fig.suptitle("Relative HTTP latency penalty (pod2svc mean)", fontsize=13, fontweight="bold")
    fig.tight_layout(rect=[0, 0, 1, 0.95])
    fig.savefig(os.path.join(plots_dir, "relative-penalty.png"), dpi=120)
    plt.close(fig)

    print(f"plots written to {plots_dir}/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
