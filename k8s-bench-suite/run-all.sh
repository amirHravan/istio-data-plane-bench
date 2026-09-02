#!/bin/bash
###################################################################
# @Description : Run EVERYTHING:
#                1) original knb bandwidth benchmark (5 modes)
#                2) latency benchmark: max-QPS (netperf+fortio) + fixed-QPS (fortio)
#                3) generate comparison, plots, and markdown report
###################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"

KNB="$SCRIPT_DIR/knb"
RUN_LATENCY="$SCRIPT_DIR/run-latency.sh"

RESULTS_DIR="${RESULTS_DIR:-$SCRIPT_DIR/../results}"

# --- switch kubectl context (the original knb has no --context flag) ---
ORIG_CTX=$(kubectl config current-context 2>/dev/null || true)
restore_ctx() {
	[ -n "$ORIG_CTX" ] && kubectl config use-context "$ORIG_CTX" >/dev/null 2>&1
}
trap restore_ctx EXIT
trap 'restore_ctx; exit 130' INT TERM
kubectl config use-context "$CONTEXT" >/dev/null 2>&1

# sanity: refuse to run against the wrong cluster
if ! kubectl get node "$CLIENT_NODE" >/dev/null 2>&1 || ! kubectl get node "$SERVER_NODE" >/dev/null 2>&1
then
	echo "FATAL: nodes $CLIENT_NODE / $SERVER_NODE not found in context '$CONTEXT'" >&2
	echo "       current context: $(kubectl config current-context)" >&2
	exit 1
fi

mkdir -p "$RESULTS_DIR"

FAILED=0

#==============================================================================
# Pass 1: original knb bandwidth benchmark
#==============================================================================
for mode in $MODES_ORDER
do
	ns="${MODES[$mode]}"
	echo "================================================================="
	echo " [knb bandwidth] mode=$mode namespace=$ns"
	echo "================================================================="
	mkdir -p "$RESULTS_DIR/$mode"
	if ! "$KNB" \
		-cn "$CLIENT_NODE" \
		-sn "$SERVER_NODE" \
		-n "$ns" \
		-d "$DURATION" \
		-ot "$KBN_TESTS" \
		-t "$POD_TIMEOUT" \
		-v \
		-f "$RESULTS_DIR/$mode/bandwidth.knbdata"
	then
		echo "[ERROR] knb bandwidth for $mode failed (continuing)" >&2
		rm -f "$RESULTS_DIR/$mode/bandwidth.knbdata"
		FAILED=1
	fi
done

#==============================================================================
# Pass 2+3: latency benchmark (max-QPS + fixed-QPS) + post-processing
#==============================================================================
export CLIENT_NODE SERVER_NODE CONTEXT DURATION POD_TIMEOUT FIXED_QPS NETPERF_IMAGE FORTIO_IMAGE FORTIO_BW_SIZE
export RESULTS_DIR

if ! "$RUN_LATENCY"; then
	FAILED=1
fi

echo ""
echo "================================================================="
echo " ALL DONE. Results:"
echo "   knb bandwidth -> $RESULTS_DIR/<mode>/bandwidth.knbdata"
echo "   latency       -> $RESULTS_DIR/<mode>/latency-*.json"
echo "   report        -> $RESULTS_DIR/REPORT.md"
echo "================================================================="

if [ "$FAILED" -ne 0 ]
then
	echo "WARNING: one or more benchmarks failed (see above). Results are INCOMPLETE." >&2
	exit 1
fi
