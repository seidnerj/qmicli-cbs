# qmicli-cbs

## Project Overview

Cross-compiled build of [libqmi](https://gitlab.freedesktop.org/mobile-broadband/libqmi)'s `qmicli` tool, patched to add Cell Broadcast (CBS/ETWS/CMAS) monitoring commands. The project is a packaging/build harness - it maintains a patch series against libqmi and cross-compiles for embedded targets (currently MIPS 32-bit BE soft-float with musl).

The patches have been submitted upstream as [libqmi issue #131](https://gitlab.freedesktop.org/mobile-broadband/libqmi/-/issues/131).

## Code Provenance Policy

**This repo redistributes GPL v2 code from libqmi.** Preserve all upstream copyright notices and license headers when modifying `qmicli-wms-patched.c`, patches, or any ported file. When adding new files, include an SPDX header referencing GPL-2.0-or-later to match upstream.

- **Never copy or adapt code whose license is incompatible with GPL v2.** In practice, GPL v2 is compatible with other GPL-compatible licenses but not with proprietary or strongly-copyleft (AGPL, GPL v3) code.
- **Prefer upstream patching over forking.** If a change belongs in libqmi proper, add it as a numbered patch in `patches/` and submit it upstream. Keep this repo's delta minimal.

## Test Policy

This project has no automated test suite - the verification path is "build succeeds and binary runs on the target hardware." When adding or changing patches:

1. Rebuild via `./build.sh` (or `./build.sh --dynamic` for shared linking)
2. Transfer the resulting binary to a real QMI-capable device
3. Exercise the affected command (e.g. `qmicli --wms-monitor`) against a live modem

Install the git hooks before the first commit: `pre-commit install`.

## Project Structure

```
qmicli-cbs/
├── Dockerfile              # Multi-stage cross-compile (MIPS BE soft-float, musl)
├── build.sh                # Host wrapper: builds via Docker, extracts artifacts into output/
├── qmicli-wms-patched.c    # Patched qmicli-wms source (applied on top of pinned libqmi)
├── compat/endian.h         # Portability shim for non-Linux build hosts
├── patches/                # Patch series against libqmi, submitted upstream
│   ├── 0001-qmicli-wms-show-broadcast-activation-state-in-get-cb.patch
│   ├── 0002-qmicli-wms-add-set-broadcast-activation-command.patch
│   ├── 0003-qmicli-wms-add-monitor-command-for-CBS-ETWS-CMAS-mes.patch
│   ├── 0004-proxy-use-path-based-socket-on-non-Linux-platforms.patch
│   └── 0005-endpoint-qmux-allow-overriding-proxy-device-path-via.patch
├── README.md
└── LICENSE                 # GPL v2 (inherited from libqmi)
```

## Architecture

- **Build strategy:** Everything happens inside the Docker image. Host `build.sh` just invokes `docker build` and extracts the resulting binaries into `output/`. This keeps the build hermetic and reproducible regardless of host toolchain.
- **Pinned libqmi commit:** The Dockerfile `ARG LIBQMI_COMMIT` must match `LIBQMI_COMMIT` in `build.sh`. Bump both together.
- **Linking modes:** `static` (default) produces self-contained binaries suitable for dropping onto embedded targets with no runtime dep matching. `--dynamic` produces smaller binaries that require matching system libs.
- **Target architecture:** Currently hardcoded to MIPS 32-bit BE soft-float musl (for Ubiquiti UniFi LTE Backup Pro). To retarget, adjust `Dockerfile`'s cross-compiler toolchain setup and meson cross-file.
