#!/usr/bin/env bash
set -euo pipefail

# Universal Linux Performance Optimizer (ULPO) Quality Gate Verification Script

STAGING_DIR="${1:-/stage}"
LIBC_TYPE="${2:-glibc}" # glibc or musl
ARCH="${3:-amd64}"      # amd64 or arm64

echo "======================================================================"
echo "RUNNING ULPO QUALITY GATE: Dir=$STAGING_DIR, Libc=$LIBC_TYPE, Arch=$ARCH"
echo "======================================================================"

verify_glibc_version() {
    local file=$1
    echo "Checking GLIBC symbol versions for: $file"
    
    # Exclude non-ELF files
    if ! file "$file" | grep -q "ELF"; then
        echo "Skip: $file is not an ELF file"
        return 0
    fi
    
    # Determine GLIBC minor limit from LIBC_TYPE (e.g. glibc-2.34 -> limit_minor=34)
    # Default/fallback to 28 if not specified
    local limit_minor=28
    if [[ "$LIBC_TYPE" =~ glibc-([0-9]+)\.([0-9]+) ]]; then
        limit_minor="${BASH_REMATCH[2]}"
    fi
    
    local versions
    versions=$(readelf -V "$file" 2>/dev/null | grep -oE "GLIBC_[0-9.]+" | sort -u || true)
    
    if [ -z "$versions" ]; then
        echo "OK: No GLIBC references found in $file"
        return 0
    fi
    
    echo "Found GLIBC versions: $(echo "$versions" | tr '\n' ' ')"
    for ver in $versions; do
        local ver_num=${ver#GLIBC_}
        local major=${ver_num%%.*}
        local rest=${ver_num#*.}
        local minor=${rest%%.*}
        
        # Check against parsed limit
        if [ "$major" -eq 2 ] && [ "$minor" -gt "$limit_minor" ] || [ "$major" -gt 2 ]; then
            echo "FAIL: $file references GLIBC version $ver (exceeds GLIBC_2.$limit_minor compatibility limit)"
            return 1
        fi
    done
    echo "OK: All symbols compatible with GLIBC <= 2.$limit_minor"
}

verify_isolated_dependencies() {
    local file=$1
    echo "Checking isolated linkages (static helper dependencies) for: $file"
    
    # Exclude non-ELF files
    if ! file "$file" | grep -q "ELF"; then
        return 0
    fi
    
    # Use readelf -d (statically) to find dynamic dependencies rather than ldd
    # which fails for cross-compiled architectures
    local deps
    deps=$(readelf -d "$file" 2>/dev/null | grep NEEDED || true)
    
    # Assert that no references exist for libstdc++.so or libgcc_s.so
    if echo "$deps" | grep -qE "libstdc\+\+|libgcc_s"; then
        echo "FAIL: $file dynamically depends on unwanted helper libraries:"
        echo "$deps" | grep -E "libstdc\+\+|libgcc_s"
        return 1
    fi
    echo "OK: No dependencies on libstdc++ or libgcc_s detected in NEEDED headers"
}

verify_intel_instructions() {
    local file=$1
    echo "Verifying Intel SSE/PCLMULQDQ intrinsics for: $file"
    
    # Exclude non-ELF files
    if ! file "$file" | grep -q "ELF"; then
        return 0
    fi
    
    if [ "$ARCH" != "amd64" ] && [ "$ARCH" != "x86_64" ]; then
        echo "Skip: Non-amd64 target ($ARCH)"
        return 0
    fi
    
    # Assert that objdump can find carryless multiplication intrinsics
    # Wait, we might need a target-specific objdump if host is not amd64, 
    # but since host is x86_64, standard objdump works for amd64 binaries.
    if ! objdump -d "$file" 2>/dev/null | grep -qi "pclmul"; then
        echo "FAIL: $file does not contain 'pclmul' instruction family"
        return 1
    fi
    echo "OK: Verified pclmul instruction presence"
}

verify_ld_preload() {
    local file=$1
    echo "Smoke-testing LD_PRELOAD loading for: $file"
    
    # Exclude non-ELF files
    if ! file "$file" | grep -q "ELF"; then
        return 0
    fi
    
    # Detect host environment
    local host_arch
    host_arch=$(uname -m)
    local host_arch_mapped="amd64"
    if [ "$host_arch" = "aarch64" ]; then
         host_arch_mapped="arm64"
    fi
    
    # We can only perform runtime execution tests if target matches host architecture and host is glibc
    if [ "$ARCH" != "$host_arch_mapped" ] || [[ "$LIBC_TYPE" != glibc* ]]; then
        echo "Skip: Cannot run execution smoke-test for cross-compiled target ($ARCH / $LIBC_TYPE) on host ($host_arch_mapped / glibc)"
        return 0
    fi
    
    # Basic loader test (LD_PRELOAD=file true)
    if ! LD_PRELOAD="$file" true; then
        echo "FAIL: Basic true execution failed under LD_PRELOAD"
        return 1
    fi
    
    # Python loader test
    if command -v python3 >/dev/null; then
        if ! LD_PRELOAD="$file" python3 -c "print('Success')" 2>/dev/null; then
            echo "FAIL: Python execution failed/segfaulted under LD_PRELOAD"
            return 1
        fi
    fi
    echo "OK: Smoke-test LD_PRELOAD execution succeeded"
}

# Find all shared libraries in staging directory for this target
# Build.sh stages into: $STAGING_DIR/<lib_name>/$LIBC_TYPE/$ARCH/
libs=$(find "$STAGING_DIR" -path "*/$LIBC_TYPE/$ARCH/*.so*" -type f || true)

if [ -z "$libs" ]; then
    echo "ERROR: No shared libraries found in staging for $LIBC_TYPE/$ARCH"
    exit 1
fi

errors=0
for lib in $libs; do
    echo "------------------------------------------------------------"
    echo "Testing library: $lib"
    
    # 1. Symbol check (GLIBC only)
    if [[ "$LIBC_TYPE" == glibc* ]]; then
        if ! verify_glibc_version "$lib"; then
            errors=$((errors+1))
        fi
    fi
    
    # 2. Dependency isolation
    if ! verify_isolated_dependencies "$lib"; then
        errors=$((errors+1))
    fi
    
    # 3. Intel-specific validation (Only for zlib-intel)
    if [[ "$lib" == *"zlib-intel"* ]]; then
        if ! verify_intel_instructions "$lib"; then
            errors=$((errors+1))
        fi
    fi
    
    # 4. Smoke test preload loading
    if ! verify_ld_preload "$lib"; then
        errors=$((errors+1))
    fi
done

echo "------------------------------------------------------------"
if [ "$errors" -gt 0 ]; then
    echo "Quality gate failed with $errors error(s)."
    exit 1
else
    echo "Quality gate passed successfully!"
    exit 0
fi
