# syntax=docker/dockerfile:1

# =====================================================================
# STAGE 1: UNIFIED CROSS-COMPILATION BUILDER
# =====================================================================
FROM ubuntu:24.04 AS builder
ENV DEBIAN_FRONTEND=noninteractive

# Install core build packaging and utility dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    git \
    curl \
    file \
    xz-utils \
    llvm \
    autoconf \
    && rm -rf /var/lib/apt/lists/*

# Install Zig compiler (0.16.0 stable)
RUN ZIG_ARCH=$(uname -m) && \
    curl -Lo /tmp/zig.tar.xz "https://ziglang.org/download/0.16.0/zig-${ZIG_ARCH}-linux-0.16.0.tar.xz" && \
    tar -xf /tmp/zig.tar.xz -C /usr/local && \
    ln -s /usr/local/zig-${ZIG_ARCH}-linux-0.16.0/zig /usr/local/bin/zig && \
    rm /tmp/zig.tar.xz

# Create zig-ar and zig-ranlib wrappers to bypass CMake picking up host llvm-ar
RUN echo '#!/bin/sh\nexec /usr/local/bin/zig ar "$@"' > /usr/local/bin/zig-ar && \
    echo '#!/bin/sh\nexec /usr/local/bin/zig ranlib "$@"' > /usr/local/bin/zig-ranlib && \
    chmod +x /usr/local/bin/zig-ar /usr/local/bin/zig-ranlib

# Set up source and staging directories
RUN mkdir -p /src /build /stage

# renovate: datasource=github-tags depName=microsoft/mimalloc
ARG MIMALLOC_VERSION=v3.3.2
# renovate: datasource=github-tags depName=zlib-ng/zlib-ng
ARG ZLIB_NG_VERSION=2.2.4
# renovate: datasource=github-tags depName=jemalloc/jemalloc
ARG JEMALLOC_VERSION=5.3.1

# Clone targets for mimalloc, zlib-ng, and jemalloc
RUN git clone --depth 1 -b ${MIMALLOC_VERSION} https://github.com/microsoft/mimalloc.git /src/mimalloc
RUN git clone --depth 1 -b ${ZLIB_NG_VERSION} https://github.com/zlib-ng/zlib-ng.git /src/zlib-ng
RUN git clone --depth 1 -b ${JEMALLOC_VERSION} https://github.com/jemalloc/jemalloc.git /src/jemalloc

# Copy build and quality-gate verification scripts
COPY verify.sh /build/verify.sh
COPY build.sh /build/build.sh

# Run scoped compilation and verification
RUN /build/build.sh /stage


# =====================================================================
# STAGE 2a: DEBUG ARTIFACT ASSEMBLY
# =====================================================================
FROM scratch AS debug
COPY --from=builder /stage/ /

# =====================================================================
# STAGE 2b: RELEASE ARTIFACT ASSEMBLY (DEFAULT)
# =====================================================================
FROM scratch AS release
COPY --from=builder /stage/allocators /allocators
COPY --from=builder /stage/compression /compression
