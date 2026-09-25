#!/bin/sh
#
# Boot the filter VM (OpenWrt) on an Apple Silicon Mac.
#
#   ./scripts/run-vm.sh                    two NICs: WAN via NAT, LAN on a
#                                          socket for the client VM
#   ./scripts/run-vm.sh --wan-only         single NIC, internet only
#   sudo ./scripts/run-vm.sh --bridged en0 LAN bridged onto a real interface,
#                                          so real phones and laptops can use
#                                          the VM as their gateway (needs root)
#
# Exit the VM with: poweroff   (or Ctrl-A then X)
# Requires: brew install qemu
#
# VirtualBox is not an option here: it cannot run x86-64 guests on Apple
# Silicon. This uses the ARM-native armsr/armv8 build, so nothing is emulated.
#
set -eu

RELEASE=25.12.5
IMAGE=openwrt-${RELEASE}-armsr-armv8-generic-ext4-combined-efi.img.gz
BASE=https://downloads.openwrt.org/releases/${RELEASE}/targets/armsr/armv8

MEM=${MEM:-512}
SMP=${SMP:-2}
DISK_SIZE=2G
SSH_PORT=${SSH_PORT:-2222}
LAN_SOCKET_PORT=${LAN_SOCKET_PORT:-12855}

MODE=lan-socket
BRIDGE_IF=

while [ $# -gt 0 ]; do
  case "$1" in
    --wan-only) MODE=wan-only ;;
    --bridged)  MODE=bridged; BRIDGE_IF=${2:?--bridged needs an interface, e.g. en0}; shift ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

VMDIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/.vm
FIRMWARE=/opt/homebrew/share/qemu/edk2-aarch64-code.fd

mkdir -p "$VMDIR"
cd "$VMDIR"

command -v qemu-system-aarch64 >/dev/null 2>&1 || {
  echo "qemu-system-aarch64 not found. Install it with: brew install qemu" >&2; exit 1; }
[ -f "$FIRMWARE" ] || { echo "UEFI firmware missing: $FIRMWARE" >&2; exit 1; }
[ "$MODE" = bridged ] && [ "$(id -u)" != 0 ] && {
  echo "--bridged needs root (vmnet). Re-run with sudo." >&2; exit 1; }

if [ ! -f openwrt.img ]; then
  echo "Downloading $IMAGE ..."
  curl -fL --progress-bar -O "$BASE/$IMAGE"
  curl -fsSL -O "$BASE/sha256sums"

  echo "Verifying checksum ..."
  want=$(grep " \*${IMAGE}\$" sha256sums | cut -d' ' -f1)
  got=$(shasum -a 256 "$IMAGE" | cut -d' ' -f1)
  [ -n "$want" ] || { echo "no checksum published for $IMAGE" >&2; exit 1; }
  [ "$want" = "$got" ] || {
    echo "CHECKSUM MISMATCH -- refusing to boot" >&2
    echo "  expected $want" >&2; echo "  got      $got" >&2; exit 1; }
  echo "Checksum OK."

  # macOS gzip needs the Xcode command line tools, which are not always
  # working. Fall back to python3.
  gzip -dc "$IMAGE" > openwrt.img 2>/dev/null || python3 -c "
import gzip, shutil, sys
with gzip.open(sys.argv[1],'rb') as f, open('openwrt.img','wb') as o:
    shutil.copyfileobj(f,o)" "$IMAGE"

  qemu-img resize -f raw openwrt.img "$DISK_SIZE" >/dev/null
fi

# The UEFI variable store must match the firmware image size.
[ -f efi-vars.fd ] || dd if=/dev/zero of=efi-vars.fd bs=1m count=64 2>/dev/null

# WAN is always QEMU's user-mode NAT: no root needed, and it keeps the VM's
# uplink independent of whatever the Mac is doing.
set -- \
  -M virt -accel hvf -cpu host -smp "$SMP" -m "$MEM" \
  -drive if=pflash,format=raw,readonly=on,file="$FIRMWARE" \
  -drive if=pflash,format=raw,file=efi-vars.fd \
  -drive if=virtio,format=raw,file=openwrt.img \
  -netdev user,id=wan,hostfwd=tcp::"${SSH_PORT}"-:22 \
  -device virtio-net-pci,netdev=wan

case "$MODE" in
  lan-socket)
    echo "LAN: socket on port $LAN_SOCKET_PORT (start the client with scripts/run-client-vm.sh)"
    set -- "$@" \
      -netdev socket,id=lan,listen=:"$LAN_SOCKET_PORT" \
      -device virtio-net-pci,netdev=lan
    ;;
  bridged)
    echo "LAN: bridged onto $BRIDGE_IF -- real devices can use this VM as a gateway"
    set -- "$@" \
      -netdev vmnet-bridged,id=lan,ifname="$BRIDGE_IF" \
      -device virtio-net-pci,netdev=lan
    ;;
  wan-only)
    echo "LAN: none (internet only)"
    ;;
esac

echo "Booting OpenWrt ${RELEASE}. Press Enter at the console prompt."
echo
exec qemu-system-aarch64 "$@" -display none -serial mon:stdio
