# Shared configuration for the istio-dataplane-bench suite.
# Sourced by run-all.sh, run-latency.sh, and compare-latency.sh.
# Every value is overridable via environment variables.

# --- nodes -------------------------------------------------------
# The client node hosts the load generators, the server node the targets.
CLIENT_NODE="${CLIENT_NODE:-g9-56core-1228}"
SERVER_NODE="${SERVER_NODE:-g9-56core-1229}"
CONTEXT="${CONTEXT:-stg}"

# --- test parameters ---------------------------------------------
DURATION="${DURATION:-20}"        # seconds per test
POD_TIMEOUT="${POD_TIMEOUT:-120}" # pod ready/complete wait timeout
FIXED_QPS="${FIXED_QPS:-5000}"      # fixed-QPS pass target (0 = max)
KBN_TESTS="${KBN_TESTS:-tcp}"       # iperf3 test subset (tcp = pod2pod+pod2svc TCP)
export FORTIO_BW_SIZE="${FORTIO_BW_SIZE:-65536}"  # fortio HTTP-bandwidth payload size
# --- images ------------------------------------------------------
export NETPERF_IMAGE="${NETPERF_IMAGE:-reg.production.tpsl.ir/docker-infra-local/infrastructure/knb/knb-netperf:0.0.1}"
export FORTIO_IMAGE="${FORTIO_IMAGE:-fortio/fortio:1.75.2}"
export MONITOR_IMAGE="${MONITOR_IMAGE:-infrabuilder/bench-custom-monitor}"
export IMAGE_PULL_SECRET="${IMAGE_PULL_SECRET:-reg-pegah-credit}"

# --- mode -> namespace mapping (single source of truth) ----------
declare -A MODES=(
  [simple]="benchmark"
  [sidecar-nomtls]="benchmark-sidecar-nomtls"
  [sidecar-mtls]="benchmark-sidecar-mtls"
  [ztunnel]="benchmark-ztunnel"
  [waypoint]="benchmark-waypoint"
)

# Canonical order for tables/plots (must match the Python scripts).
MODES_ORDER="simple sidecar-nomtls sidecar-mtls ztunnel waypoint"
