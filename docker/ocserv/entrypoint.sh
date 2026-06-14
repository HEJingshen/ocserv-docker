#!/bin/sh
# Container entrypoint: runs pre-start checks + iptables setup, then
# execs ocserv in the foreground so it becomes PID 1.
#
# On init.sh failure the container exits non-zero; Docker's
# `restart: unless-stopped` policy then handles crash recovery.
set -eu

/usr/local/bin/init.sh

exec ocserv -c /etc/ocserv/ocserv.conf -f
