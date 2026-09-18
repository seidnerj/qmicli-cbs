# qmicli-cbs

Cross-compiled `qmicli` with Cell Broadcast (CBS/ETWS/CMAS) monitoring support.

## What this is

A patched build of [libqmi](https://gitlab.freedesktop.org/mobile-broadband/libqmi)'s `qmicli` tool that adds two new WMS commands for Cell Broadcast reception:

- `--wms-set-broadcast-activation` - Activate Cell Broadcast reception on the modem
- `--wms-monitor` - Monitor for incoming CBS/ETWS/CMAS messages in real-time (enables event reporting internally)

It also improves the existing `--wms-get-cbs-channels` output to show the broadcast activation state.

These complement the existing CBS commands already in libqmi main:
- `--wms-set-cbs-channels` - Configure which CBS channel IDs to receive
- `--wms-get-cbs-channels` - Query current CBS channel configuration

## Why

Cell Broadcast is the backbone of emergency alert systems worldwide (EU-Alert, CMAS/WEA in the US, Israel's Home Front Command alerts, Japan's ETWS, etc.). While phones handle these natively, embedded devices with QMI modems (routers, IoT gateways) have no built-in way to receive them.

This project bridges that gap - giving any QMI-capable device the ability to receive cell broadcast alerts directly from the cellular network, with no internet connection required.

## Upstream contribution

The patches have been submitted upstream to libqmi on [freedesktop.org GitLab (issue #131)](https://gitlab.freedesktop.org/mobile-broadband/libqmi/-/issues/131).

See `patches/` for the 3-commit patch series against libqmi main:

1. `0001` - Show broadcast activation state in `--wms-get-cbs-channels` output
2. `0002` - Add `--wms-set-broadcast-activation` command
3. `0003` - Add `--wms-monitor` command with CBS/ETWS/CMAS indication decoding

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

# Monitor for incoming Cell Broadcast messages (Ctrl+C to stop)
/tmp/qmicli -d /dev/cdc-wdm0 --device-open-proxy --wms-monitor
```

Replace `/dev/cdc-wdm0` with your QMI device path.

## Point-to-point SMS and `--wms-monitor`

`--wms-monitor` was written for Cell Broadcast, but WMS event report indications also carry ordinary point-to-point (MT) SMS. Whether the monitor shows you the message *content* depends on how the modem's WMS routes are configured, and there are two distinct outcomes.

**Transferred to the client.** The indication carries the `Transfer Route MT Message` TLV, and the monitor prints the ack indicator, transaction ID, format and the complete raw PDU as hex. The CBS page-header decode is an additional branch that runs only when the format is `gsm-wcdma-broadcast`, so a point-to-point message still prints its full PDU, with the format shown as point-to-point. The PDU can then be decoded externally.

**Stored on the SIM or in modem memory.** The indication carries only a storage pointer, and the monitor prints:

```
  MT Message (stored):
    Storage Type: sim
    Memory Index: 3
```

That is the entire output: no sender, no timestamp, no text. Reading the message itself then requires a WMS command such as `--wms-get-message`.

Which of the two you get is determined by the receipt action in the modem's WMS route configuration. Inspect it with `--wms-get-routes` and change it with `--wms-set-routes`.

### Why this matters when a monitor is already running

WMS permits one client at a time. A long-lived `--wms-monitor` holds the WMS service, so a second WMS client (`--wms-get-routes`, `--wms-list-messages`, `--wms-get-message`) cannot be opened without stopping the monitor. If the modem is configured to store rather than transfer, an inbound SMS is therefore visible only as a storage index for as long as the monitor runs, and its content is unreachable over QMI. Where the monitor feeds an alerting pipeline, stopping it to read one message is usually not acceptable.

Two ways around this, neither of which requires stopping the monitor:

- Check the route configuration *before* starting the long-lived monitor, and set the receipt action to transfer if you need message content.
- Use the modem's AT interface, which on many devices is a separate character device (for example `/dev/ttyUSB2`). It allocates no QMI client and cannot preempt WMS: `AT+CMGF=1` followed by `AT+CMGL="ALL"` lists stored messages with sender and text.

Other QMI services are unaffected by the WMS limit. NAS, DMS and UIM allocate their own clients and coexist with a running monitor through `qmi-proxy`.

A note on how much of this is verified: the stored-versus-transferred distinction is read from the indication handler in `qmicli-wms-patched.c`. Only the broadcast path has been exercised against real hardware here.

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
