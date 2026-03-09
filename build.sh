#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output"

echo "=== Building qmicli for MIPS big-endian soft-float (musl static) ==="
echo "This will take a while on first run (downloading toolchain + building deps)..."
echo ""

# Build using Docker
docker build \
    --platform linux/amd64 \
    -t qmicli-cbs-builder \
    -f "${SCRIPT_DIR}/Dockerfile" \
    "${SCRIPT_DIR}"

# Extract binaries from the final stage
mkdir -p "${OUTPUT_DIR}"

# Create a temporary container to copy files out
CONTAINER_ID=$(docker create --platform linux/amd64 qmicli-cbs-builder /qmicli)
docker cp "${CONTAINER_ID}:/qmicli" "${OUTPUT_DIR}/qmicli" 2>/dev/null || true
docker cp "${CONTAINER_ID}:/qmi-proxy" "${OUTPUT_DIR}/qmi-proxy" 2>/dev/null || true
docker rm "${CONTAINER_ID}" > /dev/null

echo ""
echo "=== Build complete ==="
echo "Binaries:"
ls -la "${OUTPUT_DIR}/"
echo ""
file "${OUTPUT_DIR}/qmicli"
echo ""
echo "To deploy to your device:"
echo "  scp ${OUTPUT_DIR}/qmicli user@device:/tmp/"
echo ""
echo "Then on the device:"
echo "  /tmp/qmicli -d /dev/cdc-wdm0 --device-open-proxy --wms-set-cbs-channels=4370-4383"
echo "  /tmp/qmicli -d /dev/cdc-wdm0 --device-open-proxy --wms-set-broadcast-activation"
echo "  /tmp/qmicli -d /dev/cdc-wdm0 --device-open-proxy --wms-set-event-report"
echo "  /tmp/qmicli -d /dev/cdc-wdm0 --device-open-proxy --wms-monitor"
