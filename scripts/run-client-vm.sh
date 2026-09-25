#!/bin/sh
#
# Boot a client VM behind the filter, for testing interception.
#
#   ./scripts/run-client-vm.sh
#
# Connects to the filter VM's LAN socket, so its only route to the internet is
# through the filter. Start the filter VM first with scripts/run-vm.sh.
#
# It is a second copy of the same OpenWrt image, chosen for size: it boots in
# seconds, has curl, and costs 15 MB rather than a desktop Linux install. It
# cannot tell you how a real browser behaves -- that needs a real device.
#
set -eu

MEM=${MEM:-256}
LAN_SOCKET_PORT=${LAN_SOCKET_PORT:-12855}

VMDIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/.vm
FIRMWARE=/opt/homebrew/share/qemu/edk2-aarch64-code.fd
cd "$VMDIR"

[ -f openwrt.img ] || { echo "run scripts/run-vm.sh first to fetch the image" >&2; exit 1; }

# Separate disk and EFI vars so the two VMs never share state.
[ -f client.img ] || { echo "Creating client disk ..."; cp openwrt.img client.img; }
[ -f client-efi-vars.fd ] || dd if=/dev/zero of=client-efi-vars.fd bs=1m count=64 2>/dev/null

echo "Booting client VM. Its only uplink is the filter VM."
echo
exec qemu-system-aarch64 \
  -M virt -accel hvf -cpu host -smp 1 -m "$MEM" \
  -drive if=pflash,format=raw,readonly=on,file="$FIRMWARE" \
  -drive if=pflash,format=raw,file=client-efi-vars.fd \
  -drive if=virtio,format=raw,file=client.img \
  -netdev socket,id=lan,connect=127.0.0.1:"$LAN_SOCKET_PORT" \
  -device virtio-net-pci,netdev=lan \
  -display none -serial mon:stdio
