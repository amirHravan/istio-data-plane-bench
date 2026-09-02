#!/bin/bash
###################################################################
# @Description : Create the benchmark namespaces + mesh config that
#                the suite depends on. Idempotent.
#
#   - namespaces with the right labels (sidecar injection / ambient)
#   - PeerAuthentication: STRICT (mTLS mode) and DISABLE (no-mTLS mode)
#   - an ambient L7 waypoint enrolled on the waypoint namespace
###################################################################
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
CONTEXT="${CONTEXT:-stg}"

kc() {
	kubectl --context "$CONTEXT" "$@"
}

echo "[setup] creating namespaces ..."
kc apply -f "$DIR/namespaces.yaml"

echo "[setup] applying PeerAuthentication (STRICT + DISABLE) ..."
kc apply -f "$DIR/peerauthentication.yaml"

echo "[setup] enrolling ambient waypoint on benchmark-waypoint ..."
if ! command -v istioctl >/dev/null 2>&1; then
	echo "ERROR: istioctl not found in PATH — install it to enable the waypoint mode" >&2
	exit 1
fi
istioctl --context "$CONTEXT" waypoint apply -n benchmark-waypoint --enroll-namespace --overwrite

# record the Istio version for the report (ambient behavior is version-sensitive)
ISTIO_VERSION=$(istioctl --context "$CONTEXT" version 2>/dev/null | grep -i "control plane" | awk '{print $NF}')
[ -z "$ISTIO_VERSION" ] && ISTIO_VERSION="unknown"
mkdir -p "$DIR/../results"
echo "$ISTIO_VERSION" > "$DIR/../results/istio-version.txt"

echo ""
echo "[setup] done. Verify:"
echo "  kubectl --context $CONTEXT get ns -l istio-injection"
echo "  kubectl --context $CONTEXT get ns -l istio.io/dataplane-mode"
echo "  kubectl --context $CONTEXT get peerauthentication -A"
echo "  kubectl --context $CONTEXT get gateway -n benchmark-waypoint"
