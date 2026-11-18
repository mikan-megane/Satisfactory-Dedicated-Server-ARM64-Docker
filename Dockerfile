# syntax=docker/dockerfile:1

# Satisfactory Dedicated Server on ARM64.
#
# The Linux server binary is x86-64 only, so it is executed through FEX-Emu.
# FEX is taken from the official PPA instead of being compiled from source:
# building FEX yourself is slow and the upstream build flags change often.
#
# Build on the same ARM64 machine that will run the server. FEX_ARCH=auto picks
# the best package for the build host (armv8.0 / armv8.2 / armv8.4).
FROM ubuntu:24.04

SHELL ["/bin/bash", "-c"]
ARG DEBIAN_FRONTEND=noninteractive
ARG FEX_ARCH=auto
ARG FEX_VERSION=

# ---------------------------------------------------------------------------
# Base packages + FEX
# ---------------------------------------------------------------------------
RUN set -eux; \
    [ "$(dpkg --print-architecture)" = "arm64" ] || { \
        echo "ERROR: this image must be built on an ARM64 (aarch64) host."; \
        echo "The Satisfactory server binary is x86-64 and FEX only runs on ARM64."; \
        exit 1; \
    }; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        expect \
        gosu \
        locales \
        procps \
        python3 \
        software-properties-common \
        squashfs-tools \
        squashfuse \
        tini; \
    add-apt-repository -y ppa:fex-emu/fex; \
    apt-get update; \
    case "${FEX_ARCH}" in \
        auto) \
            if grep -qw uscat /proc/cpuinfo; then fex_arch=armv8.4; \
            elif grep -qw asimddp /proc/cpuinfo; then fex_arch=armv8.2; \
            else fex_arch=armv8.0; fi ;; \
        armv8.0|armv8.1) fex_arch=armv8.0 ;; \
        armv8.2|armv8.3) fex_arch=armv8.2 ;; \
        armv8.4) fex_arch=armv8.4 ;; \
        *) echo "ERROR: FEX_ARCH must be auto, armv8.0, armv8.2 or armv8.4 (got ${FEX_ARCH})"; exit 1 ;; \
    esac; \
    if [ -n "${FEX_VERSION}" ]; then \
        apt-get install -y --no-install-recommends "fex-emu-${fex_arch}=${FEX_VERSION}"; \
    else \
        apt-get install -y --no-install-recommends "fex-emu-${fex_arch}"; \
    fi; \
    echo "Installed FEX package: fex-emu-${fex_arch}"; \
    FEXGetConfig --version || true; \
    apt-get purge -y --auto-remove software-properties-common; \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# steam user (UID/GID are remapped at startup with PUID/PGID)
# ---------------------------------------------------------------------------
RUN set -eux; \
    userdel -r ubuntu 2>/dev/null || true; \
    groupdel ubuntu 2>/dev/null || true; \
    groupadd -g 1000 steam; \
    useradd -m -u 1000 -g steam -s /bin/bash steam; \
    locale-gen en_US.UTF-8

# Keep FEX config + rootfs + cache in one directory so a single volume
# persists everything between container re-creations. XDG_CACHE_HOME is where
# FEX writes its JIT disk cache.
ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    HOME=/home/steam \
    XDG_DATA_HOME=/home/steam/.fex \
    XDG_CONFIG_HOME=/home/steam/.fex \
    XDG_CACHE_HOME=/home/steam/.fex

# ---------------------------------------------------------------------------
# SteamCMD
# ---------------------------------------------------------------------------
WORKDIR /home/steam
RUN set -eux; \
    mkdir -p Steam; \
    curl -fsSL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" \
        | tar -xz -C Steam; \
    chown -R steam:steam /home/steam

# ---------------------------------------------------------------------------
# Entrypoint / healthcheck
# ---------------------------------------------------------------------------
COPY --chmod=755 init-server.sh healthcheck.sh /home/steam/

ENV SATISFACTORY_DIR=/satisfactory \
    STEAMCMD_DIR=/home/steam/Steam \
    APP_ID=1690800 \
    PUID=1000 \
    PGID=1000 \
    GAME_PORT=7777 \
    MESSAGING_PORT=8888 \
    ALWAYS_UPDATE_ON_START=true \
    EXPERIMENTAL_BRANCH=false

VOLUME ["/satisfactory"]
EXPOSE 7777/tcp 7777/udp 8888/tcp

ENTRYPOINT ["/usr/bin/tini", "--", "/home/steam/init-server.sh"]
