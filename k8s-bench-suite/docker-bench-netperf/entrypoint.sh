#!/bin/sh
# Dispatches between the two roles this image serves:
#   server  -> run `netserver` in the foreground (`-D` = do not daemonize,
#              which keeps the container alive and the pod "Ready").
#   anything else -> exec'd as-is, i.e. a `netperf ...` client command.
case "$1" in
  server) exec netserver -D ;;
  *) exec "$@" ;;
esac
