# BPI-W2 (RTD1296) mainline kernel -- cross-compile environment.
# The distro's aarch64 GCC, dtc, and dtschema for dt-validate. Imported from
# the PiKVM repository's docker/builder-mainline.Dockerfile (2026-10-05).
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# A closer Debian mirror if the default CDN is slow from here, e.g.
# make builder DEBIAN_MIRROR=http://free.nchc.org.tw/debian
ARG DEBIAN_MIRROR=
RUN if [ -n "$DEBIAN_MIRROR" ]; then \
        sed -i "s#^URIs: http://deb.debian.org/debian\$#URIs: $DEBIAN_MIRROR#" /etc/apt/sources.list.d/debian.sources; \
    fi

RUN apt-get update && apt-get install -y --no-install-recommends \
        bc \
        bison \
        build-essential \
        ca-certificates \
        cpio \
        device-tree-compiler \
        file \
        flex \
        gawk \
        gcc-aarch64-linux-gnu \
        git \
        gzip \
        kmod \
        libelf-dev \
        libfdt-dev \
        libncurses-dev \
        libssl-dev \
        lz4 \
        lzop \
        make \
        pahole \
        pkg-config \
        python3 \
        python3-dev \
        python3-pip \
        rsync \
        swig \
        u-boot-tools \
        xz-utils \
        zstd \
        yamllint \
    && rm -rf /var/lib/apt/lists/*

# dtschema, for `CHECK_DTBS=1 make kernel` and the binding checks. Not packaged in trixie,
# and its pylibfdt dependency is built from source -- hence swig, libfdt-dev,
# python3-dev and pkg-config above.
RUN pip3 install --break-system-packages --no-cache-dir --root-user-action=ignore \
        dtschema

# Run as the caller's uid/gid so build outputs are not left owned by root.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
