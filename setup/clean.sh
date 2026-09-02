#!/bin/bash
###################################################################
# @Description : Remove the mesh resources that setup.sh created.
#                Idempotent — safe to run multiple times.
#
#   - the ambient L7 waypoint (gateway + pods + service + label)
#   - the PeerAuthentication policies (STRICT + DISABLE)
#   - the mesh labels on the namespaces
#
#   It does NOT delete the namespaces themselves: they predate the
#   benchmark and contain unrelated resources (TLS secrets, etc.).
###################################################################
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
CONTEXT="${CONTEXT:-stg}"

kc() {
	kubectl --context "$CONTEXT" "$@"
}

echo "[clean] removing ambient waypoint from benchmark-waypoint ..."
if command -v istioctl >/dev/null 2>&1; then
	istioctl --context "$CONTEXT" waypoint delete --all -n benchmark-waypoint || true
else
	kc delete gateway waypoint -n benchmark-waypoint --ignore-not-found || true
fi

echo "[clean] removing PeerAuthentication policies ..."
kc delete peerauthentication strict-mtls -n benchmark-sidecar-mtls --ignore-not-found || true
kc delete peerauthentication disable-mtls -n benchmark-sidecar-nomtls --ignore-not-found || true

echo "[clean] removing mesh labels from the namespaces ..."
kc label ns benchmark-sidecar-nomtls istio-injection- 2>/dev/null || true
kc label ns benchmark-sidecar-nomtls istio.io/rev- 2>/dev/null || true
kc label ns benchmark-sidecar-mtls istio-injection- 2>/dev/null || true
kc label ns benchmark-sidecar-mtls istio.io/rev- 2>/dev/null || true
kc label ns benchmark-ztunnel istio.io/dataplane-mode- 2>/dev/null || true
kc label ns benchmark-waypoint istio.io/dataplane-mode- 2>/dev/null || true
kc label ns benchmark-waypoint istio.io/use-waypoint- 2>/dev/null || true

echo ""
echo "[clean] done. Namespaces were left in place (they hold unrelated resources)."
