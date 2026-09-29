# xcesp-modem — single-modem container built from an already-produced
# xcesppkg-arm64-<VERSION>.tgz.  The container ships everything a modem
# needs (xcespserver, xcespproc, xcespwdog, xcespcli, xcesp-on-xc's
# schema + rules) and reads its per-deployment values (MSISDN, RVP,
# transport ports, PSK) from environment variables at launch.
#
# The image is deliberately built from a shipped tarball — not from
# source — so a customer field-install matches whatever was
# QA-validated for that xcesppkg version.  Rebuild the image only when
# the underlying tarball changes.
#
# Build (from this directory, with the tarball copied in):
#   podman build --platform=linux/arm64 \
#       --build-arg XCESPPKG_TARBALL=xcespkg-arm64-0.4.64.tgz \
#       -t xcesp-modem:0.4.64-arm64 .
#
# Export for offline deployment:
#   podman save --format=docker-archive \
#       -o xcesp-modem-0.4.64-arm64.tar xcesp-modem:0.4.64-arm64
#
# Load + run on the target: see run.sh / load.sh in this directory.

FROM ubuntu:22.04
ARG XCESPPKG_TARBALL

ENV DEBIAN_FRONTEND=noninteractive

# Runtime deps only.  Kept minimal:
#   libsodium23 — ChaCha20-Poly1305 + HMAC (matches ARM builder linkage).
#   python3     — xcespmap's rule engine.
# libc, libstdc++, libm, libgcc are already in the base image; we don't
# need libcrypt1, netbase, or ca-certificates for the modem workload.
#
# The `ln -sf /bin/true /usr/sbin/ldconfig` divert stops libc-bin's
# post-install trigger from invoking ldconfig, which crashes under
# qemu-user emulation (SIGSEGV in the emulated cache builder — a
# long-standing qemu-user quirk).  We restore ldconfig on the last
# line so the container still has a working one at runtime, then let
# the base image's already-generated /etc/ld.so.cache do the lookup
# work for us.
RUN ln -sf /bin/true /usr/sbin/ldconfig \
    && apt-get update \
    && apt-get install -y --no-install-recommends libsodium23 python3 \
    && rm -rf /var/lib/apt/lists/* \
    && rm /usr/sbin/ldconfig \
    && cp /usr/sbin/ldconfig.REAL /usr/sbin/ldconfig 2>/dev/null \
       || ln -s /sbin/ldconfig /usr/sbin/ldconfig

# Unpack the xcesppkg into standard paths.  The tarball's layout
# already matches /var/xcesp — copy only the pieces the container
# needs (no doc/, no scripts/ — those are for full host installs).
COPY ${XCESPPKG_TARBALL} /tmp/pkg.tgz
RUN mkdir -p /var/xcesp/cfg /var/xcesp/schema /var/xcesp/rules \
             /var/xcesp/dsk /var/xcesp/log /var/lib/xcesp \
             /run/xcesp /usr/lib/xcesp \
    && tar xzf /tmp/pkg.tgz -C /tmp/ \
    && cp /tmp/xcespkg-*/bin/xcespserver /usr/bin/xcespserver \
    && cp /tmp/xcespkg-*/bin/xcespproc   /usr/bin/xcespproc \
    && cp /tmp/xcespkg-*/bin/xcespwdog   /usr/bin/xcespwdog \
    && cp /tmp/xcespkg-*/bin/xcespcli    /usr/bin/xcespcli \
    && cp /tmp/xcespkg-*/bin/xcesp-ip    /usr/lib/xcesp/xcesp-ip \
    && cp -r /tmp/xcespkg-*/schema/*     /var/xcesp/schema/ \
    && cp -r /tmp/xcespkg-*/rules/*      /var/xcesp/rules/ \
    && cp    /tmp/xcespkg-*/cfg/xcespproc.ini  /var/xcesp/cfg/ \
    && rm -rf /tmp/xcespkg-* /tmp/pkg.tgz \
    && chmod 0755 /usr/bin/xcespserver /usr/bin/xcespproc \
                  /usr/bin/xcespwdog /usr/bin/xcespcli \
                  /usr/lib/xcesp/xcesp-ip

# Container-tuned INI files (differ from the systemd install variants).
# The wdog directly launches server + proc — no xcesp-activate stage
# to generate proc.ini in a container.  License enforcement is off:
# the fleet is licensed centrally at the RVP.
COPY xcespserver.ini /var/xcesp/cfg/xcespserver.ini
COPY xcespwdog.ini   /var/xcesp/cfg/xcespwdog.ini

# Entrypoint synthesises xcespserver.conf from environment variables
# on every start.  This means the container is stateless w.r.t.
# config — the docker run flags define the deployment.  Any operator
# changes made via xcespcli are lost on container restart (persistent
# state should live in /var/lib/xcesp which is bind-mounted).
COPY entrypoint.sh /usr/local/bin/xcesp-entrypoint
COPY xcesp-log-rotator.sh /usr/local/bin/xcesp-log-rotator
RUN chmod 0755 /usr/local/bin/xcesp-entrypoint \
              /usr/local/bin/xcesp-log-rotator

# xcespcli control ports.  Host mode (--network=host) is the default
# runtime topology, so these EXPOSEs are documentation only — the
# operator can override at run time by dropping host networking and
# mapping ports explicitly, at the cost of the RVP registration
# source-IP breakage we hit in the xcesptest lab.
EXPOSE 9900
LABEL org.opencontainers.image.title="xcesp-modem"
LABEL org.opencontainers.image.description="Single-modem xcesp container (arm64)"

ENTRYPOINT ["/usr/local/bin/xcesp-entrypoint"]
