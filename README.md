# qmicli-cbs

Cross-compiled `qmicli` with Cell Broadcast (CBS/ETWS/CMAS) monitoring support.

## What this is

A patched build of [libqmi](https://gitlab.freedesktop.org/mobile-broadband/libqmi)'s `qmicli` tool that adds three new WMS commands for Cell Broadcast reception:

- `--wms-set-event-report` - Enable MT message event reporting
- `--wms-set-broadcast-activation` - Activate Cell Broadcast reception on the modem
- `--wms-monitor` - Monitor for incoming CBS/ETWS/CMAS messages in real-time

It also improves the existing `--wms-get-cbs-channels` output to show the broadcast activation state.

These complement the existing CBS commands already in libqmi main:
- `--wms-set-cbs-channels` - Configure which CBS channel IDs to receive
- `--wms-get-cbs-channels` - Query current CBS channel configuration

## Why

Cell Broadcast is the backbone of emergency alert systems worldwide (EU-Alert, CMAS/WEA in the US, Israel's Home Front Command alerts, Japan's ETWS, etc.). While phones handle these natively, embedded devices with QMI modems (routers, IoT gateways) have no built-in way to receive them.

This project bridges that gap - giving any QMI-capable device the ability to receive cell broadcast alerts directly from the cellular network, with no internet connection required.

## Upstream contribution

The patches have been submitted upstream to libqmi on [freedesktop.org GitLab (issue #131)](https://gitlab.freedesktop.org/mobile-broadband/libqmi/-/issues/131).

See `patches/` for the 4-commit patch series against libqmi main:

1. `0001` - Show broadcast activation state in `--wms-get-cbs-channels` output
2. `0002` - Add `--wms-set-event-report` command
3. `0003` - Add `--wms-set-broadcast-activation` command
4. `0004` - Add `--wms-monitor` command with CBS/ETWS/CMAS indication decoding

## Current build target

The included Dockerfile cross-compiles for **MIPS 32-bit big-endian soft-float (musl)**, targeting embedded devices like the Ubiquiti UniFi LTE Backup Pro. To target a different architecture, adapt the Dockerfile's cross-compiler toolchain and meson cross-file.

## Building

Requires Docker:

```bash
./build.sh
```

This builds a statically linked qmicli binary in a Docker container using:
- musl.cc MIPS cross-compiler toolchain
- zlib, libffi, PCRE2, GLib (all static)
- libqmi from git main (with CBS patches applied)

Output goes to `./output/qmicli` (and `./output/qmi-proxy`).

## Deploying

Copy the binary to your device:

```bash
scp output/qmicli user@device:/tmp/
```

## Usage

```bash
# Check current CBS channel config
/tmp/qmicli -d /dev/cdc-wdm0 --device-open-proxy --wms-get-cbs-channels

# Set CBS channels to receive
/tmp/qmicli -d /dev/cdc-wdm0 --device-open-proxy --wms-set-cbs-channels=4370-4383

# Activate broadcast reception
/tmp/qmicli -d /dev/cdc-wdm0 --device-open-proxy --wms-set-broadcast-activation

# Enable event reporting
/tmp/qmicli -d /dev/cdc-wdm0 --device-open-proxy --wms-set-event-report

# Monitor for incoming Cell Broadcast messages (Ctrl+C to stop)
/tmp/qmicli -d /dev/cdc-wdm0 --device-open-proxy --wms-monitor
```

Replace `/dev/cdc-wdm0` with your QMI device path.

## CBS channel reference

### International (CMAS/ETWS)

| Channel | Purpose |
|---------|---------|
| 4370 | Presidential Alert (highest severity) |
| 4371-4372 | Extreme alerts |
| 4373-4378 | Severe alerts |
| 4379 | AMBER alerts |
| 4380-4382 | Test/exercise |
| 4383 | EU-Alert Level 1 |

### Country-specific examples

| Channel | Country | Purpose |
|---------|---------|---------|
| 919 | Israel | Home Front Command emergency alerts |
| 50 | India | Disaster alerts |
| 4396 | Netherlands | NL-Alert |

## Example: integration with red-alert

This project was originally built to enable [red-alert](https://github.com/seidnerj/red-alert) CBS integration on a UniFi LTE Backup Pro. The red-alert CBS integration parses the `--wms-monitor` output to track Israeli emergency alert state in real-time. See the [CBS integration docs](https://github.com/seidnerj/red-alert/blob/main/docs/integrations/CBS.md) for details.

## Files

- `Dockerfile` - Multi-stage Docker build for cross-compilation
- `build.sh` - Build script (wraps Docker build + binary extraction)
- `patches/` - git format-patch series against libqmi main
- `qmicli-wms-patched.c` - Full patched source file for reference

## License

GPL-2.0 © 2025 seidnerj (patches); see [LICENSE](LICENSE) for original libqmi contributors.

This software is provided "as is" without warranty of any kind. See [LICENSE](LICENSE) for full terms.
