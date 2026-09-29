#!/bin/bash
# load.sh — run this on the TARGET ARM device to load the image tar
# into the local docker daemon.  One-shot, no dependencies beyond docker.
set -euo pipefail

TAR="${1:-}"
if [ -z "$TAR" ]; then
    echo "usage: $0 <xcesp-modem-*.tar>" >&2
    exit 2
fi
[ -f "$TAR" ] || {
    echo "not found: $TAR" >&2
    exit 1
}

echo "==> loading $TAR into docker"
docker load -i "$TAR"

echo "==> installed images:"
docker images | grep -E '^(REPOSITORY|xcesp-modem)'
