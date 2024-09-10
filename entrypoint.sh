#!/bin/sh

iptables -t nat -A POSTROUTING -j MASQUERADE

sysctl -w net.ipv4.ip_forward=1

# Run Ocserv Server
exec "$@"
