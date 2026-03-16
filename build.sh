#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output"

# Pinned libqmi commit (must match Dockerfile ARG LIBQMI_COMMIT)
LIBQMI_COMMIT="d125e7a51efbc059bc88123547ab24253842e952"

mkdir -p "${OUTPUT_DIR}"

echo "=== Building qmicli for all platforms ==="
echo ""

# Track background build PIDs
DOCKER_PID=""
NATIVE_PID=""
DOCKER_LOG="${OUTPUT_DIR}/.docker-build.log"
NATIVE_LOG="${OUTPUT_DIR}/.native-build.log"

cleanup() {
    [ -n "$DOCKER_PID" ] && kill "$DOCKER_PID" 2>/dev/null || true
    [ -n "$NATIVE_PID" ] && kill "$NATIVE_PID" 2>/dev/null || true
}
trap cleanup EXIT

# --- Docker cross-compilation (MIPS + aarch64 in parallel via BuildKit) ---
(
    echo "[docker] Building MIPS + aarch64 via Docker..."
    docker build \
        --platform linux/amd64 \
        -t qmicli-cbs-builder \
        -f "${SCRIPT_DIR}/Dockerfile" \
        "${SCRIPT_DIR}"

    CONTAINER_ID=$(docker create --platform linux/amd64 qmicli-cbs-builder /mips/qmicli)

    docker cp "${CONTAINER_ID}:/mips/qmicli" "${OUTPUT_DIR}/qmicli-mips" 2>/dev/null || true
    docker cp "${CONTAINER_ID}:/mips/qmi-proxy" "${OUTPUT_DIR}/qmi-proxy-mips" 2>/dev/null || true
    docker cp "${CONTAINER_ID}:/aarch64/qmicli" "${OUTPUT_DIR}/qmicli-aarch64" 2>/dev/null || true
    docker cp "${CONTAINER_ID}:/aarch64/qmi-proxy" "${OUTPUT_DIR}/qmi-proxy-aarch64" 2>/dev/null || true

    docker rm "${CONTAINER_ID}" > /dev/null

    echo "[docker] Done: MIPS + aarch64"
    file "${OUTPUT_DIR}/qmicli-mips" "${OUTPUT_DIR}/qmicli-aarch64"
) > "${DOCKER_LOG}" 2>&1 &
DOCKER_PID=$!
echo "Started Docker cross-compilation (PID $DOCKER_PID)"

# --- Native macOS build (parallel with Docker) ---
if [ "$(uname)" = "Darwin" ] && command -v meson >/dev/null 2>&1 && pkg-config --exists glib-2.0 2>/dev/null; then
    (
        echo "[native] Building qmicli natively for macOS..."

        NATIVE_BUILD_DIR=$(mktemp -d)

        # Clone libqmi at pinned commit if not cached
        if [ ! -d "${SCRIPT_DIR}/.libqmi-src" ]; then
            git clone https://gitlab.freedesktop.org/mobile-broadband/libqmi.git "${SCRIPT_DIR}/.libqmi-src"
        fi
        git -C "${SCRIPT_DIR}/.libqmi-src" checkout "${LIBQMI_COMMIT}" 2>/dev/null

        cp -r "${SCRIPT_DIR}/.libqmi-src" "${NATIVE_BUILD_DIR}/libqmi"

        # Apply CBS patches
        cd "${NATIVE_BUILD_DIR}/libqmi"
        git -c user.name="qmicli-cbs" -c user.email="build@qmicli-cbs" am "${SCRIPT_DIR}"/patches/*.patch

        meson setup builddir \
            --prefix="${NATIVE_BUILD_DIR}/install" \
            --buildtype=minsize \
            -Dman=false \
            -Dgtk_doc=false \
            -Dintrospection=false \
            -Dbash_completion=false \
            -Dudev=false \
            -Dqrtr=false \
            -Drmnet=false \
            -Dmbim_qmux=false \
            -Dfirmware_update=false \
            -Dmm_runtime_check=false \
            -Dcollection=full
        ninja -C builddir -j$(sysctl -n hw.ncpu 2>/dev/null || nproc)
        ninja -C builddir install

        cp "${NATIVE_BUILD_DIR}/install/bin/qmicli" "${OUTPUT_DIR}/qmicli-darwin"
        if [ -f "${NATIVE_BUILD_DIR}/install/libexec/qmi-proxy" ]; then
            cp "${NATIVE_BUILD_DIR}/install/libexec/qmi-proxy" "${OUTPUT_DIR}/qmi-proxy-darwin"
        fi

        rm -rf "${NATIVE_BUILD_DIR}"

        echo "[native] Done: macOS"
        file "${OUTPUT_DIR}/qmicli-darwin"
    ) > "${NATIVE_LOG}" 2>&1 &
    NATIVE_PID=$!
    echo "Started macOS native build (PID $NATIVE_PID)"
else
    echo "Skipping macOS native build (not on macOS or missing deps: brew install glib meson ninja)"
fi

# --- Wait for all builds ---
echo ""
echo "Waiting for builds to complete..."

FAILED=0

if [ -n "$DOCKER_PID" ]; then
    if wait "$DOCKER_PID"; then
        echo "Docker cross-compilation: SUCCESS"
    else
        echo "Docker cross-compilation: FAILED (see ${DOCKER_LOG})"
        FAILED=1
    fi
    DOCKER_PID=""
fi

if [ -n "$NATIVE_PID" ]; then
    if wait "$NATIVE_PID"; then
        echo "macOS native build: SUCCESS"
    else
        echo "macOS native build: FAILED (see ${NATIVE_LOG})"
        FAILED=1
    fi
    NATIVE_PID=""
fi

# Show logs on failure
if [ "$FAILED" -ne 0 ]; then
    echo ""
    echo "=== Build logs ==="
    for log in "${DOCKER_LOG}" "${NATIVE_LOG}"; do
        if [ -f "$log" ]; then
            echo ""
            echo "--- $(basename "$log") (last 30 lines) ---"
            tail -30 "$log"
        fi
    done
    rm -f "${DOCKER_LOG}" "${NATIVE_LOG}"
    exit 1
fi

rm -f "${DOCKER_LOG}" "${NATIVE_LOG}"

echo ""
echo "=== All builds complete ==="
echo ""
ls -la "${OUTPUT_DIR}/"
echo ""
for bin in "${OUTPUT_DIR}"/qmicli-*; do
    [ -f "$bin" ] && file "$bin"
done
echo ""
echo "Deploy to UniFi LTE Pro:"
echo "  ssh user@device 'cat > /tmp/qmicli && chmod +x /tmp/qmicli' < ${OUTPUT_DIR}/qmicli-mips"
echo ""
echo "Deploy to Raspberry Pi:"
echo "  scp ${OUTPUT_DIR}/qmicli-aarch64 pi@homebridge.local:/tmp/qmicli"
