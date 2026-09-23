FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
# libsodium-dev needed since the PSK encryption sprint (xcesppkg
# 0.4.61+): xcesp-on-xc's CryptoEnvelope + SMS/CSD codecs link against
# libsodium (ChaCha20-Poly1305 + HKDF-SHA256).  The x86 host build
# picks it up from the Fedora libsodium-devel package; the ARM64
# builder needs the Ubuntu equivalent.
RUN apt-get update && apt-get install -y build-essential libsodium-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
