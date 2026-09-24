#!/bin/sh
#
# Boot an OpenWrt VM for testing the filter, on an Apple Silicon Mac.
#
#   ./scripts/run-vm.sh
#
# Downloads the image on first run, verifies it against OpenWrt's published
# sha256sums, and boots it with QEMU using the native HVF accelerator.
# Exit the VM with: poweroff   (or Ctrl-A then X)
#
# Requires: brew install qemu
#
# Note for anyone reaching for VirtualBox instead: it cannot run x86-64
# guests on Apple Silicon. That is why this targets the armsr/armv8 build,
# which is ARM native and needs no emulation.
#
set -eu

RELEASE=25.12.5
TARGET=armsr/armv8
IMAGE=openwrt-${RELEASE}-armsr-armv8-generic-ext4-combined-efi.img.gz
BASE=https://downloads.openwrt.org/releases/${RELEASE}/targets/${TARGET}

MEM=512
SMP=2
DISK_SIZE=2G
SSH_PORT=2222

VMDIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/.vm
FIRMWARE=/opt/homebrew/share/qemu/edk2-aarch64-code.fd

mkdir -p "$VMDIR"
cd "$VMDIR"

command -v qemu-system-aarch64 >/dev/null 2>&1 || {
  echo "qemu-system-aarch64 not found. Install it with: brew install qemu" >&2
  exit 1
}
[ -f "$FIRMWARE" ] || {
  echo "UEFI firmware not found at $FIRMWARE" >&2
  exit 1
}

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
    echo "  expected $want" >&2
    echo "  got      $got" >&2
    exit 1
  }
  echo "Checksum OK."

  # macOS gzip depends on the Xcode command line tools, which are not always
  # in working order. Fall back to python3.
  if gzip -dc "$IMAGE" > openwrt.img 2>/dev/null; then
    :
  else
    python3 -c "
import gzip, shutil, sys
with gzip.open(sys.argv[1], 'rb') as f, open('openwrt.img', 'wb') as o:
    shutil.copyfileobj(f, o)
" "$IMAGE"
  fi

  # Room for installed packages. The root partition is not grown by this;
  # it just stops the disk from being the limit later.
  qemu-img resize -f raw openwrt.img "$DISK_SIZE" >/dev/null
fi

# The UEFI variable store must be the same size as the firmware image.
[ -f efi-vars.fd ] || dd if=/dev/zero of=efi-vars.fd bs=1m count=64 2>/dev/null

echo "Booting OpenWrt ${RELEASE}. Press Enter at the console prompt."
echo "SSH is forwarded from localhost:${SSH_PORT} once you set a root password."
echo

exec qemu-system-aarch64 \
  -M virt -accel hvf -cpu host -smp "$SMP" -m "$MEM" \
  -drive if=pflash,format=raw,readonly=on,file="$FIRMWARE" \
  -drive if=pflash,format=raw,file=efi-vars.fd \
  -drive if=virtio,format=raw,file=openwrt.img \
  -netdev user,id=wan,hostfwd=tcp::"${SSH_PORT}"-:22 \
  -device virtio-net-pci,netdev=wan \
  -display none -serial mon:stdio
