#!/bin/bash
###################################################################
# @Description : Run the Istio latency benchmark.
#                1) max-QPS pass (netperf + fortio) per mode
#                2) fixed-QPS pass (fortio only) per mode
#                3) extract knb bulk-throughput, compare, plot, report
#
# Results layout (all under RESULTS_DIR):
#   <mode>/latency-maxqps.json      <mode>/raw-maxqps/
#   <mode>/latency-fixed<qps>.json  <mode>/raw-fixed<qps>/
#   knb-throughput.json  comparison.txt  REPORT.md  plots/
###################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"

KNB="$SCRIPT_DIR/knb-latency"
PLOT="$SCRIPT_DIR/plot-report.py"
COMPARE="$SCRIPT_DIR/compare-latency.sh"
REPORT="$SCRIPT_DIR/gen-report.py"

RESULTS_DIR="${RESULTS_DIR:-$SCRIPT_DIR/../results}"

# sanity: refuse to run against a cluster that lacks our nodes
if ! kubectl --context "$CONTEXT" get node "$CLIENT_NODE" >/dev/null 2>&1 \
	|| ! kubectl --context "$CONTEXT" get node "$SERVER_NODE" >/dev/null 2>&1
then
	echo "FATAL: nodes $CLIENT_NODE / $SERVER_NODE not found in context '$CONTEXT'" >&2
	exit 1
fi

INTERRUPTED=0
on_signal() {
	echo "" >&2
	echo "[run-latency] signal received, finishing current mode then stopping ..." >&2
	INTERRUPTED=1
}
trap on_signal INT TERM

mkdir -p "$RESULTS_DIR"
if [ -z "$RESULTS_DIR" ] || [ "$RESULTS_DIR" = "/" ] || [ "$RESULTS_DIR" = "." ]
then
	echo "FATAL: RESULTS_DIR is '$RESULTS_DIR' — refusing to rm -rf" >&2
	exit 1
fi
rm -rf "$RESULTS_DIR"/*/raw-* 2>/dev/null || true

FAILED=0

#--- Pass 1: max QPS (netperf + fortio) ---------------------------
for mode in $MODES_ORDER
do
	ns="${MODES[$mode]}"
	mkdir -p "$RESULTS_DIR/$mode"
	echo "================================================================="
	echo " [pass 1/2 max-QPS] mode=$mode namespace=$ns"
	echo "================================================================="
	if ! "$KNB" \
		--context "$CONTEXT" \
		-cn "$CLIENT_NODE" \
		-sn "$SERVER_NODE" \
		-n "$ns" \
		-d "$DURATION" \
		-t "$POD_TIMEOUT" \
		-v \
		-o json \
		-f "$RESULTS_DIR/$mode/latency-maxqps.json" \
		--data-dir "$RESULTS_DIR/$mode/raw-maxqps"
	then
		echo "[ERROR] max-QPS benchmark for $mode failed" >&2
		rm -f "$RESULTS_DIR/$mode/latency-maxqps.json"
		FAILED=1
	fi
	[ "$INTERRUPTED" -ne 0 ] && break
done

#--- Pass 2: fixed QPS (fortio only) ------------------------------
for mode in $MODES_ORDER
do
	ns="${MODES[$mode]}"
	mkdir -p "$RESULTS_DIR/$mode"
	echo "================================================================="
	echo " [pass 2/2 fixed ${FIXED_QPS} qps] mode=$mode namespace=$ns"
	echo "================================================================="
	if ! "$KNB" \
		--context "$CONTEXT" \
		-cn "$CLIENT_NODE" \
		-sn "$SERVER_NODE" \
		-n "$ns" \
		-d "$DURATION" \
		-t "$POD_TIMEOUT" \
		-v \
		-ot http \
		--qps "$FIXED_QPS" \
		-o json \
		-f "$RESULTS_DIR/$mode/latency-fixed${FIXED_QPS}.json" \
		--data-dir "$RESULTS_DIR/$mode/raw-fixed${FIXED_QPS}"
	then
		echo "[ERROR] fixed-QPS benchmark for $mode failed" >&2
		rm -f "$RESULTS_DIR/$mode/latency-fixed${FIXED_QPS}.json"
		FAILED=1
	fi
	[ "$INTERRUPTED" -ne 0 ] && break
done

#--- Extract knb bulk throughput (pod2pod + pod2svc) ---------------
python3 - "$RESULTS_DIR" "$RESULTS_DIR" <<'PY'
import json, os, sys, glob
root, out = sys.argv[1], sys.argv[2]

def extract_bw(txt, section):
    for block in txt.split(section)[1:2]:
        for line in block.splitlines():
            if "bandwidth" in line:
                v = float(line.split("=")[1].strip().split()[0])
                return v if v > 0 else None
    return None

res = {}
for mode in ("simple", "sidecar-nomtls", "sidecar-mtls", "ztunnel", "waypoint"):
    for p in glob.glob(os.path.join(root, mode, "*.knbdata")):
        txt = open(p).read()
        res[mode] = {
            "p2p": extract_bw(txt, "Pod to pod :"),
            "p2s": extract_bw(txt, "Pod to Service :"),
        }
with open(os.path.join(out, "knb-throughput.json"), "w") as fh:
    json.dump(res, fh, indent=2)
print("knb-throughput.json:", res)
PY

#--- Comparison table ----------------------------------------------
echo ""
echo "================================================================="
echo " Generating comparison table"
echo "================================================================="
"$COMPARE" "$RESULTS_DIR" | tee "$RESULTS_DIR/comparison.txt"

#--- Plots ---------------------------------------------------------
echo ""
echo "================================================================="
echo " Generating plots"
echo "================================================================="
if python3 -c "import matplotlib" 2>/dev/null; then
	FIXED_QPS="$FIXED_QPS" FORTIO_BW_SIZE="$FORTIO_BW_SIZE" python3 "$PLOT" "$RESULTS_DIR"
else
	echo "[WARN] matplotlib not available, skipping plots"
fi

#--- Report --------------------------------------------------------
echo ""
echo "================================================================="
echo " Generating report"
echo "================================================================="
FIXED_QPS="$FIXED_QPS" FORTIO_BW_SIZE="$FORTIO_BW_SIZE" python3 "$REPORT" "$RESULTS_DIR"

echo ""
if [ "$FAILED" -ne 0 ]
then
	echo "WARNING: one or more modes failed (see above). Results are INCOMPLETE." >&2
	exit 1
fi
echo "Done. Results in $RESULTS_DIR"
