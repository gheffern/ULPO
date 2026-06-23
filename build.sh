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
              -DCMAKE_BUILD_TYPE=Release \
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
        
        # strerror_r return type check can fail when cross-compiling with strict compilers/flags.
        # Bypass by explicitly passing autotools cache variables matching glibc/musl implementations.
        EXTRA_CONFIG_ARGS=()
        if [[ "$LIBC" == glibc* ]]; then
            EXTRA_CONFIG_ARGS+=("je_cv_strerror_r_returns_char_with_gnu_source=yes")
        else
            EXTRA_CONFIG_ARGS+=("je_cv_strerror_r_returns_char_with_gnu_source=no" "je_cv_strerror_r_header_pass=yes")
        fi

        ./autogen.sh \
            --host="$CONFIGURE_HOST" \
            --with-jemalloc-prefix="" \
            --enable-prof \
            --enable-stats \
            AR="/usr/local/bin/zig-ar" \
            RANLIB="/usr/local/bin/zig-ranlib" \
            LDFLAGS="-static-libgcc" \
            CFLAGS="-O3" \
            CXXFLAGS="-O3" \
            "${EXTRA_CONFIG_ARGS[@]}"
        make -j$(nproc)
    )
    mkdir -p "$STAGE_DIR/allocators/jemalloc/$LIBC/$ARCH"
    mkdir -p "$STAGE_DIR/debug/allocators/jemalloc/$LIBC/$ARCH"
    cp "$BUILD_ROOT/jemalloc/lib/libjemalloc.so.2" "$STAGE_DIR/debug/allocators/jemalloc/$LIBC/$ARCH/libjemalloc.so.2"
    cp "$BUILD_ROOT/jemalloc/lib/libjemalloc.so.2" "$STAGE_DIR/allocators/jemalloc/$LIBC/$ARCH/libjemalloc.so.2"
    llvm-strip "$STAGE_DIR/allocators/jemalloc/$LIBC/$ARCH/libjemalloc.so.2"

    # 4. Compile zlib-rs
    echo "--> Compiling zlib-rs..."
    
    # Map ZIG_TARGET to RUST_TARGET
    if [[ "$ZIG_TARGET" == x86_64-linux-gnu* ]]; then
        RUST_TARGET="x86_64-unknown-linux-gnu"
    elif [[ "$ZIG_TARGET" == x86_64-linux-musl* ]]; then
        RUST_TARGET="x86_64-unknown-linux-musl"
    elif [[ "$ZIG_TARGET" == aarch64-linux-gnu* ]]; then
        RUST_TARGET="aarch64-unknown-linux-gnu"
    elif [[ "$ZIG_TARGET" == aarch64-linux-musl* ]]; then
        RUST_TARGET="aarch64-unknown-linux-musl"
    else
        echo "FAIL: Unknown target for Rust compilation: $ZIG_TARGET"
        exit 1
    fi

    # Create temporary linker wrapper for cargo to use zig cc
    LINKER_WRAPPER="/tmp/zig-linker-${ZIG_TARGET}"
    printf '#!/bin/sh\nexec zig cc -target %s "$@"\n' "$ZIG_TARGET" > "$LINKER_WRAPPER"
    chmod +x "$LINKER_WRAPPER"
    
    # Set target linker environment variable
    RUST_TARGET_UPPER=$(echo "$RUST_TARGET" | tr 'a-z-' 'A-Z_' | tr '.' '_')
    export "CARGO_TARGET_${RUST_TARGET_UPPER}_LINKER"="$LINKER_WRAPPER"
    
    # Force SONAME and static linking of libgcc in the ELF headers
    export RUSTFLAGS="-Clink-arg=-Wl,-soname,libz.so.1 -Clink-arg=-static-libgcc"

    # Clean and build zlib-rs cdylib
    rm -rf "$BUILD_ROOT/zlib-rs"
    mkdir -p "$BUILD_ROOT/zlib-rs"
    cp -r "$SRC_DIR/zlib-rs/." "$BUILD_ROOT/zlib-rs/"
    (
        cd "$BUILD_ROOT/zlib-rs/libz-rs-sys-cdylib"
        # We disable default features (which use rust-allocator) and enable c-allocator + gz support
        cargo build \
            --target "$RUST_TARGET" \
            --release \
            --no-default-features \
            --features="c-allocator,gz"
    )
    
    mkdir -p "$STAGE_DIR/compression/zlib-rs/$LIBC/$ARCH"
    mkdir -p "$STAGE_DIR/debug/compression/zlib-rs/$LIBC/$ARCH"
    
    zlib_rs_file=$(find "$BUILD_ROOT/zlib-rs" -name "*.so" | head -n 1)
    if [ -z "$zlib_rs_file" ]; then
        echo "FAIL: Could not find compiled zlib-rs shared library"
        exit 1
    fi
    
    # Stage the library files
    cp "$zlib_rs_file" "$STAGE_DIR/debug/compression/zlib-rs/$LIBC/$ARCH/libz.so.1"
    cp "$zlib_rs_file" "$STAGE_DIR/compression/zlib-rs/$LIBC/$ARCH/libz.so.1"
    llvm-strip "$STAGE_DIR/compression/zlib-rs/$LIBC/$ARCH/libz.so.1"

    # 5. Verify this target's binaries
    echo "--> Verifying compiled binaries..."
    /build/verify.sh "$STAGE_DIR" "$LIBC" "$ARCH"

done

echo "======================================================================"
echo "ALL TARGETS COMPILED AND VERIFIED SUCCESSFULLY!"
echo "======================================================================"
