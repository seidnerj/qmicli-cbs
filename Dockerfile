FROM debian:bookworm-slim AS base

# Avoid interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

# Install build tools and meson/ninja
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git \
    python3 \
    python3-pip \
    python3-venv \
    pkg-config \
    ninja-build \
    autoconf \
    automake \
    libtool \
    gettext \
    xz-utils \
    file \
    && rm -rf /var/lib/apt/lists/*

# Install meson via pip (need recent version for cross-compilation)
RUN python3 -m pip install --break-system-packages meson

WORKDIR /build

# Dependency versions (defaults match build.sh; overridden via --build-arg)
ARG ZLIB_VERSION=1.3.1
ARG LIBFFI_VERSION=3.4.7
ARG PCRE2_VERSION=10.43
ARG GLIB_VERSION=2.82.5

# Linking mode: "static" (default, self-contained binary) or "shared" (smaller, needs system libs)
ARG LINK_MODE=static

# Download all source tarballs once (shared across targets)
RUN GLIB_MAJOR_MINOR=$(echo "${GLIB_VERSION}" | sed 's/\.[^.]*$//') && \
    curl -sSL "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz" -o /build/zlib.tar.gz && \
    curl -sSL "https://github.com/libffi/libffi/releases/download/v${LIBFFI_VERSION}/libffi-${LIBFFI_VERSION}.tar.gz" -o /build/libffi.tar.gz && \
    curl -sSL "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz" -o /build/pcre2.tar.gz && \
    curl -sSL "https://download.gnome.org/sources/glib/${GLIB_MAJOR_MINOR}/glib-${GLIB_VERSION}.tar.xz" -o /build/glib.tar.xz

# Clone libqmi at the pinned commit our patches are based on
# Pinned to the commit our patches are based on (qmicli: wds: Allow to get CBS channels)
# Patches also apply cleanly on current main, but pinning ensures reproducible builds.
ARG LIBQMI_COMMIT=d125e7a51efbc059bc88123547ab24253842e952
RUN git clone https://gitlab.freedesktop.org/mobile-broadband/libqmi.git /build/libqmi-src && \
    cd /build/libqmi-src && \
    git checkout ${LIBQMI_COMMIT}

# Apply CBS patches via git am (preserves authorship and commit messages)
COPY patches/ /build/patches/
RUN cd /build/libqmi-src && \
    git config user.email "build@qmicli-cbs" && \
    git config user.name "qmicli-cbs build" && \
    git am /build/patches/*.patch

# Native meson file (for glib build-time tools that run on the build machine)
RUN cat > /build/native.ini <<'EOF'
[binaries]
c = 'gcc'
pkg-config = 'pkg-config'
EOF

# Build script that compiles all deps + libqmi for a given cross-compiler target.
# Usage: /build/build-target.sh <cross_prefix> <sysroot> <output_dir> <cross_file> [static|shared]
COPY <<'BUILDSCRIPT' /build/build-target.sh
#!/bin/bash
set -euo pipefail

CROSS_PREFIX="$1"
SYSROOT="$2"
OUTPUT_DIR="$3"
CROSS_FILE="$4"
LINK_MODE="${5:-static}"

# Detect extra CFLAGS from the cross file (e.g., -msoft-float for MIPS)
EXTRA_CFLAGS=""
if grep -q "msoft-float" "$CROSS_FILE" 2>/dev/null; then
    EXTRA_CFLAGS="-msoft-float"
fi

STATIC_FLAG=""
SHARED_DISABLE=""
MESON_DEFAULT_LIB="shared"
if [ "$LINK_MODE" = "static" ]; then
    STATIC_FLAG="--static"
    SHARED_DISABLE="--enable-static --disable-shared"
    MESON_DEFAULT_LIB="static"
fi

mkdir -p "${SYSROOT}/lib/pkgconfig" "${SYSROOT}/include"

echo "--- Building zlib for ${CROSS_PREFIX} (${LINK_MODE}) ---"
WORK=$(mktemp -d)
tar xzf /build/zlib.tar.gz -C "$WORK"
cd "$WORK"/zlib-*
CC=${CROSS_PREFIX}-gcc AR=${CROSS_PREFIX}-ar RANLIB=${CROSS_PREFIX}-ranlib \
    CFLAGS="-Os ${EXTRA_CFLAGS}" \
    ./configure --prefix="${SYSROOT}" ${STATIC_FLAG}
make -j$(nproc)
make install
cd /build && rm -rf "$WORK"

echo "--- Building libffi for ${CROSS_PREFIX} (${LINK_MODE}) ---"
WORK=$(mktemp -d)
tar xzf /build/libffi.tar.gz -C "$WORK"
cd "$WORK"/libffi-*
./configure --host=${CROSS_PREFIX} --prefix="${SYSROOT}" \
    ${SHARED_DISABLE} --disable-docs \
    CFLAGS="-Os ${EXTRA_CFLAGS}"
make -j$(nproc)
make install
cd /build && rm -rf "$WORK"

echo "--- Building PCRE2 for ${CROSS_PREFIX} (${LINK_MODE}) ---"
WORK=$(mktemp -d)
tar xzf /build/pcre2.tar.gz -C "$WORK"
cd "$WORK"/pcre2-*
./configure --host=${CROSS_PREFIX} --prefix="${SYSROOT}" \
    ${SHARED_DISABLE} --disable-jit \
    CFLAGS="-Os ${EXTRA_CFLAGS}"
make -j$(nproc)
make install
cd /build && rm -rf "$WORK"

echo "--- Building GLib for ${CROSS_PREFIX} (${LINK_MODE}) ---"
WORK=$(mktemp -d)
tar xJf /build/glib.tar.xz -C "$WORK"
cd "$WORK"/glib-*
meson setup builddir \
    --cross-file="${CROSS_FILE}" \
    --native-file=/build/native.ini \
    --prefix="${SYSROOT}" \
    --default-library=${MESON_DEFAULT_LIB} \
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
ninja -C builddir -j$(nproc) install
cd /build && rm -rf "$WORK"

echo "--- Building libqmi for ${CROSS_PREFIX} (${LINK_MODE}) ---"
cp -r /build/libqmi-src /build/libqmi-build-$$
cd /build/libqmi-build-$$
meson setup builddir \
    --cross-file="${CROSS_FILE}" \
    --native-file=/build/native.ini \
    --prefix="${OUTPUT_DIR}" \
    --default-library=${MESON_DEFAULT_LIB} \
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
ninja -C builddir -j$(nproc) install
cd /build && rm -rf /build/libqmi-build-$$

echo "--- Stripping binaries ---"
${CROSS_PREFIX}-strip "${OUTPUT_DIR}/bin/qmicli"
if [ -f "${OUTPUT_DIR}/libexec/qmi-proxy" ]; then
    ${CROSS_PREFIX}-strip "${OUTPUT_DIR}/libexec/qmi-proxy"
fi

echo "--- Done: ${CROSS_PREFIX} (${LINK_MODE}) ---"
file "${OUTPUT_DIR}/bin/qmicli"
ls -la "${OUTPUT_DIR}/bin/qmicli"
BUILDSCRIPT
RUN chmod +x /build/build-target.sh

# ============================================================
# Target 1: MIPS big-endian soft-float (UniFi LTE Backup Pro)
# ============================================================
FROM base AS mips-builder
ARG LINK_MODE=static

# Download MIPS cross-compiler
RUN curl -sSL https://musl.cc/mips-linux-muslsf-cross.tgz | tar xz -C /opt
ENV PATH="/opt/mips-linux-muslsf-cross/bin:${PATH}"

# Verify toolchain
RUN mips-linux-muslsf-gcc --version

# Create meson cross file (c_link_args set dynamically based on LINK_MODE)
RUN STATIC_LINK_ARGS="" && \
    if [ "$LINK_MODE" = "static" ]; then STATIC_LINK_ARGS="'-static', "; fi && \
    cat > /build/cross-mips.ini <<EOF
[binaries]
c = 'mips-linux-muslsf-gcc'
cpp = 'mips-linux-muslsf-g++'
ar = 'mips-linux-muslsf-ar'
strip = 'mips-linux-muslsf-strip'
pkg-config = 'pkg-config'

[built-in options]
c_args = ['-Os', '-msoft-float']
c_link_args = [${STATIC_LINK_ARGS}'-msoft-float']

[properties]
pkg_config_libdir = ['/build/sysroot-mips/lib/pkgconfig', '/build/sysroot-mips/share/pkgconfig']
growing_stack = false
have_strlcpy = false
have_c99_vsnprintf = true
va_val_copy = true

[host_machine]
system = 'linux'
cpu_family = 'mips'
cpu = 'mips32r2'
endian = 'big'
EOF

RUN /build/build-target.sh mips-linux-muslsf /build/sysroot-mips /build/output-mips /build/cross-mips.ini ${LINK_MODE}

# ============================================================
# Target 2: aarch64 (Raspberry Pi 4/5, Debian Bookworm)
# ============================================================
FROM base AS aarch64-builder
ARG LINK_MODE=static

# Download aarch64 cross-compiler
RUN curl -sSL https://musl.cc/aarch64-linux-musl-cross.tgz | tar xz -C /opt
ENV PATH="/opt/aarch64-linux-musl-cross/bin:${PATH}"

# Verify toolchain
RUN aarch64-linux-musl-gcc --version

# Create meson cross file (c_link_args set dynamically based on LINK_MODE)
RUN STATIC_LINK_ARGS="" && \
    if [ "$LINK_MODE" = "static" ]; then STATIC_LINK_ARGS="'-static'"; fi && \
    cat > /build/cross-aarch64.ini <<EOF
[binaries]
c = 'aarch64-linux-musl-gcc'
cpp = 'aarch64-linux-musl-g++'
ar = 'aarch64-linux-musl-ar'
strip = 'aarch64-linux-musl-strip'
pkg-config = 'pkg-config'

[built-in options]
c_args = ['-Os']
c_link_args = [${STATIC_LINK_ARGS}]

[properties]
pkg_config_libdir = ['/build/sysroot-aarch64/lib/pkgconfig', '/build/sysroot-aarch64/share/pkgconfig']
growing_stack = false
have_strlcpy = false
have_c99_vsnprintf = true
va_val_copy = true

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF

RUN /build/build-target.sh aarch64-linux-musl /build/sysroot-aarch64 /build/output-aarch64 /build/cross-aarch64.ini ${LINK_MODE}

# ============================================================
# Output stage - just the binaries
# ============================================================
FROM scratch AS output
COPY --from=mips-builder /build/output-mips/bin/qmicli /mips/qmicli
COPY --from=mips-builder /build/output-mips/libexec/qmi-proxy /mips/qmi-proxy
COPY --from=aarch64-builder /build/output-aarch64/bin/qmicli /aarch64/qmicli
COPY --from=aarch64-builder /build/output-aarch64/libexec/qmi-proxy /aarch64/qmi-proxy
