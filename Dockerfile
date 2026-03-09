FROM debian:bookworm-slim AS builder

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

# Download and install musl cross-compiler for MIPS big-endian soft-float
# Using musl.cc prebuilt toolchains
ARG MUSL_CROSS_URL=https://musl.cc/mips-linux-muslsf-cross.tgz
RUN curl -sSL "$MUSL_CROSS_URL" | tar xz -C /opt
ENV PATH="/opt/mips-linux-muslsf-cross/bin:${PATH}"
ENV CROSS_PREFIX=mips-linux-muslsf

# Verify the toolchain works
RUN ${CROSS_PREFIX}-gcc --version && \
    echo "int main(){return 0;}" > /tmp/test.c && \
    ${CROSS_PREFIX}-gcc -static -o /tmp/test /tmp/test.c && \
    file /tmp/test && \
    rm /tmp/test.c /tmp/test

WORKDIR /build

# Versions
ARG ZLIB_VERSION=1.3.1
ARG LIBFFI_VERSION=3.4.6
ARG PCRE2_VERSION=10.43
ARG GLIB_VERSION=2.78.6
ARG LIBQMI_VERSION=main

# Create meson cross-compilation file
RUN cat > /build/mips-linux-musl.cross <<'CROSSEOF'
[binaries]
c = 'mips-linux-muslsf-gcc'
cpp = 'mips-linux-muslsf-g++'
ar = 'mips-linux-muslsf-ar'
strip = 'mips-linux-muslsf-strip'
pkg-config = 'pkg-config'

[built-in options]
c_args = ['-Os', '-msoft-float']
c_link_args = ['-static', '-msoft-float']

[properties]
pkg_config_libdir = ['/build/sysroot/lib/pkgconfig', '/build/sysroot/share/pkgconfig']
growing_stack = false
have_strlcpy = false
have_c99_vsnprintf = true
va_val_copy = true

[host_machine]
system = 'linux'
cpu_family = 'mips'
cpu = 'mips32r2'
endian = 'big'
CROSSEOF

# Create sysroot directory
RUN mkdir -p /build/sysroot/lib/pkgconfig /build/sysroot/include

# Build zlib (static)
RUN curl -sSL "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz" | tar xz && \
    cd zlib-${ZLIB_VERSION} && \
    CC=${CROSS_PREFIX}-gcc \
    AR=${CROSS_PREFIX}-ar \
    RANLIB=${CROSS_PREFIX}-ranlib \
    CFLAGS="-Os -msoft-float" \
    ./configure --prefix=/build/sysroot --static && \
    make -j$(nproc) && \
    make install && \
    cd .. && rm -rf zlib-${ZLIB_VERSION}

# Build libffi (static)
RUN curl -sSL "https://github.com/libffi/libffi/releases/download/v${LIBFFI_VERSION}/libffi-${LIBFFI_VERSION}.tar.gz" | tar xz && \
    cd libffi-${LIBFFI_VERSION} && \
    ./configure \
        --host=${CROSS_PREFIX} \
        --prefix=/build/sysroot \
        --enable-static --disable-shared \
        --disable-docs \
        CFLAGS="-Os -msoft-float" && \
    make -j$(nproc) && \
    make install && \
    cd .. && rm -rf libffi-${LIBFFI_VERSION}

# Build PCRE2 (static, required by glib)
RUN curl -sSL "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz" | tar xz && \
    cd pcre2-${PCRE2_VERSION} && \
    ./configure \
        --host=${CROSS_PREFIX} \
        --prefix=/build/sysroot \
        --enable-static --disable-shared \
        --disable-jit \
        CFLAGS="-Os -msoft-float" && \
    make -j$(nproc) && \
    make install && \
    cd .. && rm -rf pcre2-${PCRE2_VERSION}

# Build GLib (static, cross-compiled)
# GLib uses meson - we need a native file for the build machine too
RUN cat > /build/native.ini <<'NATIVEEOF'
[binaries]
c = 'gcc'
pkg-config = 'pkg-config'
NATIVEEOF

RUN curl -sSL "https://download.gnome.org/sources/glib/2.78/glib-${GLIB_VERSION}.tar.xz" | tar xJ && \
    cd glib-${GLIB_VERSION} && \
    meson setup builddir \
        --cross-file=/build/mips-linux-musl.cross \
        --native-file=/build/native.ini \
        --prefix=/build/sysroot \
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
        -Dglib_assert=false && \
    ninja -C builddir -j$(nproc) install && \
    cd .. && rm -rf glib-${GLIB_VERSION}

# Clone and build libqmi (from main branch with CBS support)
RUN git clone --depth=1 https://gitlab.freedesktop.org/mobile-broadband/libqmi.git /build/libqmi

# Apply our patched qmicli-wms.c
COPY qmicli-wms-patched.c /build/libqmi/src/qmicli/qmicli-wms.c

RUN cd /build/libqmi && \
    meson setup builddir \
        --cross-file=/build/mips-linux-musl.cross \
        --native-file=/build/native.ini \
        --prefix=/build/output \
        --default-library=static \
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
        -Dcollection=full && \
    ninja -C builddir -j$(nproc) install

# Strip the binary for minimal size
RUN ${CROSS_PREFIX}-strip /build/output/bin/qmicli && \
    file /build/output/bin/qmicli && \
    ls -la /build/output/bin/qmicli

# Also build qmi-proxy (needed for shared device access)
RUN if [ -f /build/output/libexec/qmi-proxy ]; then \
        ${CROSS_PREFIX}-strip /build/output/libexec/qmi-proxy && \
        file /build/output/libexec/qmi-proxy && \
        ls -la /build/output/libexec/qmi-proxy; \
    fi

# Final stage - just the binaries
FROM scratch AS output
COPY --from=builder /build/output/bin/qmicli /qmicli
COPY --from=builder /build/output/libexec/qmi-proxy /qmi-proxy
