#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output"

# Pinned libqmi commit (must match Dockerfile ARG LIBQMI_COMMIT)
LIBQMI_COMMIT="d125e7a51efbc059bc88123547ab24253842e952"

# Default: static linking (self-contained binaries, no runtime deps)
# Use --dynamic for shared linking (smaller binaries, requires matching system libs)
LINK_MODE="static"
for arg in "$@"; do
    case "$arg" in
        --dynamic) LINK_MODE="shared" ;;
        --static)  LINK_MODE="static" ;;
        *) echo "Unknown option: $arg (use --static or --dynamic)"; exit 1 ;;
    esac
done

mkdir -p "${OUTPUT_DIR}"

echo "=== Building qmicli for all platforms (${LINK_MODE}) ==="
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
    echo "[docker] Building MIPS + aarch64 via Docker (${LINK_MODE})..."
    docker build \
        --platform linux/amd64 \
        --build-arg LINK_MODE="${LINK_MODE}" \
        -t qmicli-cbs-builder \
        -f "${SCRIPT_DIR}/Dockerfile" \
        "${SCRIPT_DIR}"

    CONTAINER_ID=$(docker create --platform linux/amd64 qmicli-cbs-builder /mips/qmicli)

    docker cp "${CONTAINER_ID}:/mips/qmicli" "${OUTPUT_DIR}/qmicli-mips" 2>/dev/null || true
    docker cp "${CONTAINER_ID}:/mips/qmi-proxy" "${OUTPUT_DIR}/qmi-proxy-mips" 2>/dev/null || true
    docker cp "${CONTAINER_ID}:/aarch64/qmicli" "${OUTPUT_DIR}/qmicli-aarch64" 2>/dev/null || true
    docker cp "${CONTAINER_ID}:/aarch64/qmi-proxy" "${OUTPUT_DIR}/qmi-proxy-aarch64" 2>/dev/null || true

    docker rm "${CONTAINER_ID}" > /dev/null

    echo "[docker] Done: MIPS + aarch64 (${LINK_MODE})"
    file "${OUTPUT_DIR}/qmicli-mips" "${OUTPUT_DIR}/qmicli-aarch64"
) > "${DOCKER_LOG}" 2>&1 &
DOCKER_PID=$!
echo "Started Docker cross-compilation (PID $DOCKER_PID)"

# --- Native macOS build (parallel with Docker) ---
# Builds all deps (zlib, libffi, PCRE2, GLib) from source with static linking,
# then builds libqmi against them. Produces a self-contained binary.
if [ "$(uname)" = "Darwin" ] && command -v meson >/dev/null 2>&1 && command -v ninja >/dev/null 2>&1; then
    (
        echo "[native] Building qmicli natively for macOS (static)..."

        NATIVE_BUILD_DIR=$(mktemp -d)
        SYSROOT="${NATIVE_BUILD_DIR}/sysroot"
        INSTALL_DIR="${NATIVE_BUILD_DIR}/install"
        NJOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)

        mkdir -p "${SYSROOT}/lib/pkgconfig" "${SYSROOT}/include"

        # Dependency versions
        # GLib 2.82+ drops the distutils dependency that breaks on Python 3.12+
        ZLIB_VERSION=1.3.1
        LIBFFI_VERSION=3.4.7
        PCRE2_VERSION=10.43
        GLIB_VERSION=2.82.5
        GLIB_MAJOR_MINOR=2.82

        # --- Build zlib ---
        echo "[native] Building zlib..."
        WORK=$(mktemp -d)
        curl -sSL "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz" | tar xz -C "$WORK"
        cd "$WORK"/zlib-*
        CFLAGS="-Os" ./configure --prefix="${SYSROOT}" --static
        make -j${NJOBS}
        make install
        cd /tmp && rm -rf "$WORK"

        # --- Build libffi ---
        echo "[native] Building libffi..."
        WORK=$(mktemp -d)
        curl -sSL "https://github.com/libffi/libffi/releases/download/v${LIBFFI_VERSION}/libffi-${LIBFFI_VERSION}.tar.gz" | tar xz -C "$WORK"
        cd "$WORK"/libffi-*
        ./configure --prefix="${SYSROOT}" --enable-static --disable-shared --disable-docs CFLAGS="-Os"
        make -j${NJOBS}
        make install
        cd /tmp && rm -rf "$WORK"

        # --- Build PCRE2 ---
        echo "[native] Building PCRE2..."
        WORK=$(mktemp -d)
        curl -sSL "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz" | tar xz -C "$WORK"
        cd "$WORK"/pcre2-*
        ./configure --prefix="${SYSROOT}" --enable-static --disable-shared --disable-jit CFLAGS="-Os"
        make -j${NJOBS}
        make install
        cd /tmp && rm -rf "$WORK"

        # --- Build GLib ---
        echo "[native] Building GLib..."
        WORK=$(mktemp -d)
        curl -sSL "https://download.gnome.org/sources/glib/${GLIB_MAJOR_MINOR}/glib-${GLIB_VERSION}.tar.xz" | tar xJ -C "$WORK"
        cd "$WORK"/glib-*

        # Tell meson/pkg-config where to find our static deps
        export PKG_CONFIG_PATH="${SYSROOT}/lib/pkgconfig:${SYSROOT}/share/pkgconfig"

        meson setup builddir \
            --prefix="${SYSROOT}" \
            --default-library=static \
            --buildtype=minsize \
            -Dtests=false \
            -Dglib_debug=disabled \
            -Dnls=disabled \
            -Dlibmount=disabled \
            -Ddtrace=false \
            -Dsystemtap=false \
            -Dselinux=disabled \
            -Dxattr=false \
            -Dlibelf=disabled \
            -Dglib_checks=false \
            -Dglib_assert=false
        ninja -C builddir -j${NJOBS} install
        cd /tmp && rm -rf "$WORK"

        # --- Build libqmi ---
        echo "[native] Building libqmi..."

        # Clone libqmi at pinned commit if not cached
        if [ ! -d "${SCRIPT_DIR}/.libqmi-src" ]; then
            git clone https://gitlab.freedesktop.org/mobile-broadband/libqmi.git "${SCRIPT_DIR}/.libqmi-src"
        fi
        git -C "${SCRIPT_DIR}/.libqmi-src" checkout "${LIBQMI_COMMIT}" 2>/dev/null

        cp -r "${SCRIPT_DIR}/.libqmi-src" "${NATIVE_BUILD_DIR}/libqmi"

        # Apply CBS patches
        cd "${NATIVE_BUILD_DIR}/libqmi"
        git -c user.name="qmicli-cbs" -c user.email="build@qmicli-cbs" am "${SCRIPT_DIR}"/patches/*.patch

        # Remove swi-update from utils build (requires linux/types.h, malloc.h - deeply Linux-specific)
        sed -i '' '/^executable(/,/^)/d' utils/meson.build

        meson setup builddir \
            --prefix="${INSTALL_DIR}" \
            --default-library=static \
            --buildtype=minsize \
            '-Dc_args=["-I'"${SCRIPT_DIR}"'/compat", "-Ds6_addr16=__u6_addr.__u6_addr16"]' \
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
        ninja -C builddir -j${NJOBS}
        ninja -C builddir install

        cp "${INSTALL_DIR}/bin/qmicli" "${OUTPUT_DIR}/qmicli-darwin"
        if [ -f "${INSTALL_DIR}/libexec/qmi-proxy" ]; then
            cp "${INSTALL_DIR}/libexec/qmi-proxy" "${OUTPUT_DIR}/qmi-proxy-darwin"
        fi

        rm -rf "${NATIVE_BUILD_DIR}"

        echo "[native] Done: macOS (static)"
        file "${OUTPUT_DIR}/qmicli-darwin"
    ) > "${NATIVE_LOG}" 2>&1 &
    NATIVE_PID=$!
    echo "Started macOS native build (PID $NATIVE_PID)"
else
    echo "Skipping macOS native build (not on macOS or missing deps: brew install meson ninja)"
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
echo "=== All builds complete (${LINK_MODE}) ==="
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
