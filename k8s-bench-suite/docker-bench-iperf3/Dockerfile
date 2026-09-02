# iperf3 client/server image for the original `knb` bandwidth benchmark.
# Minimal alpine base keeps the image tiny; iperf3 is the only dependency.
FROM alpine:3
RUN apk add --update iperf3 && rm -rf /var/cache/apk/*
