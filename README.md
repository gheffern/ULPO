# Universal Linux Performance Optimizer (ULPO)

ULPO builds a single, multi-architecture (`linux/amd64`, `linux/arm64`) scratch-based OCI container image containing pre-compiled, optimized, and statically-isolated shared objects (`.so`) for:
*   **Memory Allocators**: `mimalloc` (optimized for speed, concurrency, and fragmentation) and `jemalloc` (emphasizing fragmentation avoidance and scalability).
*   **Compression Libraries**: `zlib-ng` (highly optimized zlib replacement utilizing SSE/AVX/PCLMULQDQ on x86 and NEON on Arm).

By using the native Kubernetes OCI Image Volumes feature (K8s 1.30+), you can mount this scratch image directly into your application pods and load these high-performance libraries via `LD_PRELOAD` without injecting files into your application's base image.

---

## 📂 Target Image Directory Structure

Inside the final scratch image, the compiled shared libraries are organized by **Libc Variant** and **CPU Architecture** to prevent symbol and linking mismatches:

```text
/
├── allocators/
│   ├── jemalloc/
│   │   ├── glibc-2.28/
│   │   │   ├── amd64/libjemalloc.so.2
│   │   │   └── arm64/libjemalloc.so.2
│   │   ├── glibc-2.34/ ...
│   │   ├── glibc-2.39/ ...
│   │   └── musl/ ...
│   └── mimalloc/
│       ├── glibc-2.28/
│       │   ├── amd64/libmimalloc.so
│       │   └── arm64/libmimalloc.so
│       ├── glibc-2.34/ ...
│       ├── glibc-2.39/ ...
│       └── musl/ ...
├── compression/
│   └── zlib-ng/
│       ├── glibc-2.28/
│       │   ├── amd64/libz.so.1
│       │   └── arm64/libz.so.1
│       ├── glibc-2.34/ ...
│       ├── glibc-2.39/ ...
│       └── musl/ ...
└── debug/
    └── [allocators|compression]/ ... (Contains unstripped binaries with debug symbols)
```

---

## ☸️ Kubernetes Usage (v1.30+)

Kubernetes 1.30+ supports native OCI Image Volume mounts (under the `ImageVolume` feature gate, which is beta/default-on in 1.31+). This allows you to mount the ULPO image directly without needing an init container.

### Example Pod Manifest

The following YAML demonstrates using `subPath` to mount the specific version of the pre-compiled `mimalloc` library directly to `/usr/local/lib/libmimalloc.so`. This keeps the `LD_PRELOAD` environment variable clean and decoupled from target-specific architecture and libc layouts:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: performance-app
  namespace: default
spec:
  containers:
    - name: application
      image: ubuntu:24.04
      command: ["/bin/sh", "-c"]
      args:
        - |
          echo "Starting application with preloaded mimalloc..."
          exec my-app-binary --args
      env:
        # Simpler preload path, completely decoupled from OCI image layout
        - name: LD_PRELOAD
          value: "/usr/local/lib/libmimalloc.so"
      volumeMounts:
        - name: ulpo-libs
          mountPath: /usr/local/lib/libmimalloc.so
          subPath: allocators/mimalloc/glibc-2.39/amd64/libmimalloc.so
          readOnly: true
  volumes:
    - name: ulpo-libs
      image:
        reference: registry.example.com/ulpo:latest
        pullPolicy: IfNotPresent
```


---

## 🗺️ Library Path Selection Guide

### 1. Manual Base Image Lookup

Because dynamic libraries compiled against a newer libc cannot run on systems with an older libc, choose the highest version in ULPO that is **less than or equal to** your container's libc version.

| Container OS Base | Libc Variant | Container GLIBC | Target path subset |
| :--- | :--- | :--- | :--- |
| **Alpine Linux (All versions)** | `musl` | *N/A* | `musl` |
| **Ubuntu 20.04 (Focal)** | `glibc` | 2.31 | `glibc-2.28` |
| **Ubuntu 22.04 (Jammy)** | `glibc` | 2.35 | `glibc-2.34` |
| **Ubuntu 24.04 (Noble)** | `glibc` | 2.39 | `glibc-2.39` |
| **Debian 10 (Buster)** | `glibc` | 2.28 | `glibc-2.28` |
| **Debian 11 (Bullseye)** | `glibc` | 2.31 | `glibc-2.28` |
| **Debian 12 (Bookworm)** | `glibc` | 2.36 | `glibc-2.34` |
| **Red Hat Enterprise Linux (RHEL) / Rocky 8** | `glibc` | 2.28 | `glibc-2.28` |
| **Red Hat Enterprise Linux (RHEL) / Rocky 9** | `glibc` | 2.34 | `glibc-2.34` |
| **Amazon Linux 2023** | `glibc` | 2.34 | `glibc-2.34` |

> [!WARNING]
> Legacy systems running glibc older than 2.28 (e.g., CentOS 7 or Amazon Linux 2) are not supported. Attempting to preload these libraries on them will fail due to missing linker symbols.

### 2. Dynamic Runtime Auto-Detection

You can automate path selection at runtime using an entrypoint script or shell wrapper. This is ideal if you use a mix of base images or target architectures.

Add this snippet to your container startup script:

```bash
# 1. Detect CPU Architecture
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  *) echo "ULPO: Unsupported architecture $ARCH" >&2; ARCH="" ;;
esac

# 2. Detect Libc Variant and Version
if [ -n "$ARCH" ]; then
  if ldd --version 2>&1 | grep -q -i "musl"; then
    LIBC="musl"
  else
    # Extract major.minor from ldd version output
    RAW_VER=$(ldd --version 2>&1 | head -n 1 | grep -oE '[0-9]+\.[0-9]+' | head -n 1)
    IFS='.' read -r MAJOR MINOR <<< "$RAW_VER"
    
    if [ -z "$MAJOR" ] || [ -z "$MINOR" ] || [ "$MAJOR" -ne 2 ]; then
      LIBC="glibc-2.28" # Fallback
    elif [ "$MINOR" -ge 39 ]; then
      LIBC="glibc-2.39"
    elif [ "$MINOR" -ge 34 ]; then
      LIBC="glibc-2.34"
    else
      LIBC="glibc-2.28"
    fi
  fi

  # 3. Export LD_PRELOAD paths
  # Allocator choices: mimalloc or jemalloc (do not preload both allocators simultaneously)
  ULPO_MIMALLOC="/ulpo/allocators/mimalloc/${LIBC}/${ARCH}/libmimalloc.so"
  ULPO_JEMALLOC="/ulpo/allocators/jemalloc/${LIBC}/${ARCH}/libjemalloc.so.2"
  ULPO_ZLIB="/ulpo/compression/zlib-ng/${LIBC}/${ARCH}/libz.so.1"

  # Select which allocator to enable (mimalloc preferred here as an example)
  ALLOCATOR_PRELOAD=""
  if [ -f "$ULPO_MIMALLOC" ]; then
    ALLOCATOR_PRELOAD="$ULPO_MIMALLOC"
  elif [ -f "$ULPO_JEMALLOC" ]; then
    ALLOCATOR_PRELOAD="$ULPO_JEMALLOC"
  fi

  # Validate availability and set preload
  PRELOADS=""
  [ -n "$ALLOCATOR_PRELOAD" ] && PRELOADS="$ALLOCATOR_PRELOAD"
  if [ -f "$ULPO_ZLIB" ]; then
    [ -n "$PRELOADS" ] && PRELOADS="${PRELOADS}:${ULPO_ZLIB}" || PRELOADS="$ULPO_ZLIB"
  fi

  if [ -n "$PRELOADS" ]; then
    export LD_PRELOAD="${LD_PRELOAD:+$LD_PRELOAD:}$PRELOADS"
    echo "ULPO: Preloaded performance libraries: $PRELOADS"
  fi
fi
```

---

## 🛠️ Building and Development

Detailed guidelines on configuring compiler toolchains, building release and debug images, running local host-level builds, and adding custom performance libraries to the compiler matrix are available in the [CONTRIBUTING.md](file:///home/gheffern/Projects/ULPO/CONTRIBUTING.md) developer guide.

---

## 🔍 Troubleshooting

### 1. Preload Fails: "wrong ELF class"
*   **Cause**: You are attempting to load an `arm64` library on an `amd64` container, or vice versa.
*   **Fix**: Confirm your container's architecture using `uname -m` and match it to the directory path (e.g., `amd64` vs `arm64`).

### 2. Preload Fails: "GLIBC_X.XX not found" or Segment Faults
*   **Cause**: You have mapped a `glibc-2.34` or `glibc-2.39` library to a container running an older glibc version (e.g., loading `glibc-2.39` on Ubuntu 20.04 which runs 2.31).
*   **Fix**: Lower the directory version target to `glibc-2.28`. Remember that glibc is backwards-compatible but not forwards-compatible.

### 3. LD_PRELOAD is Ignored silently
*   **Cause**: The application binary has setuid/setgid bits, or special linux capabilities configured. For security reasons, the dynamic linker disables preloading on secure binaries unless the preloaded library is placed in system directories (e.g. `/lib` or `/usr/lib`).
*   **Fix**: If your binary needs capabilities, you may need to disable them for testing or copy the libraries directly into `/lib` within your container image instead of using external mounts.

### 4. Kubernetes Volume Mount Permissions
*   **Cause**: Pod security policies or restricted Security Contexts (e.g. SELinux, read-only roots) may restrict loading executables or libraries from outside the root filesystem.
*   **Fix**: Ensure your pod's security profile allows mounting external images. By default, native Image Volumes are mounted read-only, which complies with high-security runtime policies.

### 5. Debugging Dynamic Loading issues
To see exactly why a library fails to preload, prefix your container command with `LD_DEBUG=files` or `LD_DEBUG=all`. For example:

```bash
LD_DEBUG=files LD_PRELOAD=/ulpo/allocators/mimalloc/glibc-2.39/amd64/libmimalloc.so my-app-binary
```
The dynamic linker will output verbose logs detailing which paths it searches and any missing symbol/version errors.
