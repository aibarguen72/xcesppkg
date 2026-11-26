# XCESP generic container (x86_64, Debian 13) — 1.0.1.
#
# One image, several XCESP instances per host (training, testing): each
# container is one complete XCESP — routing (FRR with ldpd, strongSwan),
# TDM-PW / XC / VTRUNK, SNMP, web interface — with its own state directory
# on the host (see xcesp-ctr.sh).  Built from the Debian XCESPKG tarball
# (debian/build-debian.sh), installed with the package's own install.sh so
# a container and a host install are the same installation.
#
#   podman build --build-arg XCESPPKG_TARBALL=xcespkg-debian-1.0.1.tar.gz \
#       -t xcesp:1.0.1 .        (container/build.sh does this)
#
# No systemd: /usr/bin/systemctl is a stand-in (container/systemctl) and
# /usr/local/bin/xcesp-entrypoint plays xcesp.service.

FROM docker.io/library/debian:trixie
ARG XCESPPKG_TARBALL
ENV DEBIAN_FRONTEND=noninteractive

# Runtime packages: what install.sh would pull on a Debian host plus the
# routing / service daemons XCESP drives.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libsodium23 libsnmp40t64 libcrypt1 snmpd snmp \
        python3 python3-venv \
        frr strongswan-swanctl strongswan-charon \
        iproute2 iptables procps sudo libcap2-bin kmod util-linux \
        isc-dhcp-client dnsmasq-base chrony hostapd wpasupplicant \
        libopus0 libspandsp2t64 libspeexdsp1 \
        tcpdump curl ca-certificates iputils-ping ethtool bridge-utils \
        openssh-server \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/ssh/ssh_host_*

# systemctl stand-in first: install.sh and xcesp-activate call it.
COPY systemctl /usr/bin/systemctl
RUN chmod 0755 /usr/bin/systemctl

# Install the package (XCESP_NO_PKG_INSTALL: the packages are above).  The
# Python packages (xcesppy, xcespweb + aiohttp) install into the venv from
# the bundled wheels or the package index at build time.
COPY ${XCESPPKG_TARBALL} /tmp/pkg.tar.gz
RUN mkdir -p /tmp/pkg && tar xzf /tmp/pkg.tar.gz -C /tmp/pkg \
    && cd /tmp/pkg/xcespkg-* \
    && XCESP_NO_PKG_INSTALL=1 ./install.sh \
    && cd / && rm -rf /tmp/pkg /tmp/pkg.tar.gz

# Package defaults for a new instance's (empty, bind-mounted) state dirs.
RUN mkdir -p /usr/share/xcesp-ctr \
    && cp -a /var/xcesp/cfg /usr/share/xcesp-ctr/cfg \
    && cp -a /var/lib/xcesp /usr/share/xcesp-ctr/lib

COPY entrypoint.sh /usr/local/bin/xcesp-entrypoint
RUN chmod 0755 /usr/local/bin/xcesp-entrypoint

# xcespcli control port, web interface, documentation.
EXPOSE 22 9900 8081 8089
LABEL org.opencontainers.image.title="xcesp"
LABEL org.opencontainers.image.description="XCESP (x86_64, Debian 13), one instance per container"

ENTRYPOINT ["/usr/local/bin/xcesp-entrypoint"]
