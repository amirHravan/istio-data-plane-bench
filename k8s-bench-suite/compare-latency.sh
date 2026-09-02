#!/bin/bash
###################################################################
# @Description : Compare latency results across modes.
#                Reads results/<mode>/latency-maxqps.json and prints
#                mean/p50/p90/p99 tables (µs). Zero / missing values
#                (failed tests) are rendered as "-", not 0.
###################################################################
set -euo pipefail

DIR="${1:-$(dirname "$0")/../results}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"

[ -x "$(which jq)" ] || { echo "jq is required"; exit 1; }

TESTS=(tcprr-p2p tcpcrr-p2p http-p2p http-p2s)

# jq filter: missing or non-positive (failed test stored as 0) -> "-"
ZERO_AS_DASH='if (tonumber? // 1) <= 0 then "-" else . end'

for metric in mean_us p50_us p90_us p99_us
do
	echo ""
	echo "=== $metric (usec) ==="
	printf "%-16s" "mode"
	for t in "${TESTS[@]}"; do
		printf "  %-14s" "$t"
	done
	echo ""
	for mode in $MODES_ORDER
	do
		json="$DIR/$mode/latency-maxqps.json"
		[ -f "$json" ] || continue
		printf "%-16s" "$mode"
		for t in "${TESTS[@]}"; do
			v=$(jq -r --arg k "$t" ".data[\$k].$metric // \"-\" | $ZERO_AS_DASH" "$json" 2>/dev/null)
			printf "  %-14s" "$v"
		done
		echo ""
	done
done

echo ""
echo "=== error count (fortio) ==="
printf "%-16s" "mode"
printf "  %-14s" "http-p2p"
printf "  %-14s" "http-p2s"
echo ""
for mode in $MODES_ORDER
do
	json="$DIR/$mode/latency-maxqps.json"
	[ -f "$json" ] || continue
	printf "%-16s" "$mode"
	printf "  %-14s" "$(jq -r '.data["http-p2p"].errors // "-"' "$json" 2>/dev/null)"
	printf "  %-14s" "$(jq -r '.data["http-p2s"].errors // "-"' "$json" 2>/dev/null)"
	echo ""
done
