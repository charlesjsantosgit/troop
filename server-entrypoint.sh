#!/bin/sh
set -eu

# A fresh Fly volume starts root-owned. Prepare only its mount point, then
# run the game as the existing unprivileged service account.
install -d -m 0700 -o 10001 -g 10001 /data
exec runuser -u troop -- /app/troop-server.x86_64 --headless -- "$@"
