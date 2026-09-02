# Raw TCP latency image for the benchmark suite.
#
# Provides both `netperf` (client) and `netserver` (server), used by
# knb-latency to measure TCP_RR / TCP_CRR round-trip latency in microseconds.
#
# Why debian-slim and not alpine: the `netperf` package is not available in
# Alpine's repositories, so we fall back to Debian where it ships in main.
FROM debian:stable-slim

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends netperf \
 && rm -rf /var/lib/apt/lists/*

# entrypoint dispatches between server and client roles (see entrypoint.sh).
COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
