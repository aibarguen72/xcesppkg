# XCESP binaries for Debian 13 (trixie) x86_64 — builder image.
# Same packages as the Fedora build host, Debian names.  sysrepo is not
# packaged on Debian 13, so xcespserver builds without NETCONF here
# (the makefile auto-detects it); net-snmp, libsodium and the static
# libcrypt are present.
FROM docker.io/library/debian:trixie
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential pkg-config libsodium-dev libsnmp-dev libcrypt-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
