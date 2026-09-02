# Node monitor image: samples host CPU (sar) and RAM (free) once per second
# into /data/metrics.log. Used by `knb` (and `knb-latency`) to capture
# node-level utilization during each test.
FROM alpine:3
RUN apk add --update sysstat && rm -rf /var/cache/apk/* && mkdir /data
COPY *.sh /
CMD ["sh","/monit.sh"]
