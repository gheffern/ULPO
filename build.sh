#!/usr/bin/env bash
set -euo pipefail

# ULPO Scoped Cross-Compilation Orchestrator using Zig (mimalloc & zlib-ng on amd64)
STAGE_DIR="${1:-/stage}"
SRC_DIR="/src"
BUILD_ROOT="/build"

mkdir -p "$STAGE_DIR"

# Targets matrix
# format: zig_target | libc_type | arch
TARGETS=(
    "x86_64-linux-gnu.2.28|glibc-2.28|amd64"
    "x86_64-linux-gnu.2.34|glibc-2.34|amd64"
    "x86_64-linux-gnu.2.39|glibc-2.39|amd64"
    "x86_64-linux-musl|musl|amd64"
    "aarch64-linux-gnu.2.28|glibc-2.28|arm64"
    "aarch64-linux-gnu.2.34|glibc-2.34|arm64"
    "aarch64-linux-gnu.2.39|glibc-2.39|arm64"
    "aarch64-linux-musl|musl|arm64"
)

for entry in "${TARGETS[@]}"; do
    IFS='|' read -r ZIG_TARGET LIBC ARCH <<< "$entry"
    
    if [ "$ARCH" = "amd64" ]; then
        CMAKE_SYSTEM_PROCESSOR="x86_64"
    elif [ "$ARCH" = "arm64" ]; then
        CMAKE_SYSTEM_PROCESSOR="aarch64"
    else
        CMAKE_SYSTEM_PROCESSOR="$ARCH"
    fi
    
    echo "======================================================================"
    echo "BUILDING TARGET: $ZIG_TARGET ($LIBC / $ARCH)"
    echo "======================================================================"
    
    # Establish compiler wrappers for Zig
    export CC="zig cc -target $ZIG_TARGET -Wno-date-time -flto=thin"
    export CXX="zig c++ -target $ZIG_TARGET -Wno-date-time -flto=thin"
    export AR="zig ar"
    export RANLIB="zig ranlib"

    # 1. Compile mimalloc
    echo "--> Compiling mimalloc..."
    rm -rf "$BUILD_ROOT/mimalloc"
    mkdir -p "$BUILD_ROOT/mimalloc"
    cp -r "$SRC_DIR/mimalloc/." "$BUILD_ROOT/mimalloc/"
    mkdir -p "$BUILD_ROOT/mimalloc/build"
    (
        cd "$BUILD_ROOT/mimalloc/build"
        cmake -DCMAKE_SYSTEM_NAME=Linux \
              -DCMAKE_SYSTEM_PROCESSOR="$CMAKE_SYSTEM_PROCESSOR" \
              -DCMAKE_AR="/usr/local/bin/zig-ar" \
              -DCMAKE_RANLIB="/usr/local/bin/zig-ranlib" \
              -DMI_SECURE=OFF -DMI_BUILD_SHARED=ON -DMI_BUILD_OBJECT=OFF \
              -DMI_OPT_ARCH=OFF -DMI_NO_OPT_ARCH=ON \
              -DCMAKE_SHARED_LINKER_FLAGS="-static-libgcc -static-libstdc++" ..
        make -j$(nproc)
    )
    mkdir -p "$STAGE_DIR/allocators/mimalloc/$LIBC/$ARCH"
    mkdir -p "$STAGE_DIR/debug/allocators/mimalloc/$LIBC/$ARCH"
    cp "$BUILD_ROOT/mimalloc/build/libmimalloc.so" "$STAGE_DIR/debug/allocators/mimalloc/$LIBC/$ARCH/libmimalloc.so"
    cp "$BUILD_ROOT/mimalloc/build/libmimalloc.so" "$STAGE_DIR/allocators/mimalloc/$LIBC/$ARCH/libmimalloc.so"
    llvm-strip "$STAGE_DIR/allocators/mimalloc/$LIBC/$ARCH/libmimalloc.so"

    # 2. Compile zlib-ng
    echo "--> Compiling zlib-ng..."
    rm -rf "$BUILD_ROOT/zlib-ng"
    mkdir -p "$BUILD_ROOT/zlib-ng"
    cp -r "$SRC_DIR/zlib-ng/." "$BUILD_ROOT/zlib-ng/"
    mkdir -p "$BUILD_ROOT/zlib-ng/build"
    (
        cd "$BUILD_ROOT/zlib-ng/build"
        cmake -DCMAKE_SYSTEM_NAME=Linux \
              -DCMAKE_SYSTEM_PROCESSOR="$CMAKE_SYSTEM_PROCESSOR" \
              -DCMAKE_AR="/usr/local/bin/zig-ar" \
              -DCMAKE_RANLIB="/usr/local/bin/zig-ranlib" \
              -DCMAKE_BUILD_TYPE=Release \
              -DZLIB_COMPAT=ON -DWITH_GZFILEOP=ON -DWITH_OPTIMIZATIONS=ON \
              -DZLIB_ENABLE_TESTS=OFF \
              -DCMAKE_SHARED_LINKER_FLAGS="-static-libgcc" ..
        make -j$(nproc)
    )
    mkdir -p "$STAGE_DIR/compression/zlib-ng/$LIBC/$ARCH"
    mkdir -p "$STAGE_DIR/debug/compression/zlib-ng/$LIBC/$ARCH"
    zlib_ng_file=$(find "$BUILD_ROOT/zlib-ng/build" -name "libz.so.1.*" | head -n 1)
    cp "$zlib_ng_file" "$STAGE_DIR/debug/compression/zlib-ng/$LIBC/$ARCH/libz.so.1"
    cp "$zlib_ng_file" "$STAGE_DIR/compression/zlib-ng/$LIBC/$ARCH/libz.so.1"
    llvm-strip "$STAGE_DIR/compression/zlib-ng/$LIBC/$ARCH/libz.so.1"

    # 3. Compile jemalloc
    echo "--> Compiling jemalloc..."
    rm -rf "$BUILD_ROOT/jemalloc"
    mkdir -p "$BUILD_ROOT/jemalloc"
    cp -r "$SRC_DIR/jemalloc/." "$BUILD_ROOT/jemalloc/"
    (
        cd "$BUILD_ROOT/jemalloc"
        CONFIGURE_HOST="${ZIG_TARGET%%.*}"
        ./autogen.sh \
            --host="$CONFIGURE_HOST" \
            --with-jemalloc-prefix="" \
            --enable-prof \
            --enable-stats \
            --disable-initial-exec-tls \
            AR="/usr/local/bin/zig-ar" \
            RANLIB="/usr/local/bin/zig-ranlib" \
            LDFLAGS="-static-libgcc"
        make -j$(nproc)
    )
    mkdir -p "$STAGE_DIR/allocators/jemalloc/$LIBC/$ARCH"
    mkdir -p "$STAGE_DIR/debug/allocators/jemalloc/$LIBC/$ARCH"
    cp "$BUILD_ROOT/jemalloc/lib/libjemalloc.so.2" "$STAGE_DIR/debug/allocators/jemalloc/$LIBC/$ARCH/libjemalloc.so.2"
    cp "$BUILD_ROOT/jemalloc/lib/libjemalloc.so.2" "$STAGE_DIR/allocators/jemalloc/$LIBC/$ARCH/libjemalloc.so.2"
    llvm-strip "$STAGE_DIR/allocators/jemalloc/$LIBC/$ARCH/libjemalloc.so.2"

    # 4. Verify this target's binaries
    echo "--> Verifying compiled binaries..."
    /build/verify.sh "$STAGE_DIR" "$LIBC" "$ARCH"

done

echo "======================================================================"
echo "ALL TARGETS COMPILED AND VERIFIED SUCCESSFULLY!"
echo "======================================================================"
