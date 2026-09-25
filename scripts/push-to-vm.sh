#!/bin/sh
#
# Copy this repository onto a running filter VM.
#
#   ./scripts/push-to-vm.sh              copy, then print the next command
#   ./scripts/push-to-vm.sh --run        copy and run setup-filter.sh
#   VM_HOST=192.168.1.50 SSH_PORT=22 ./scripts/push-to-vm.sh --run
#                                        reach a bridged VM on the LAN instead
#
# Needs a root password set on the VM first. At the VM console:
#
#   passwd
#
# A fresh OpenWrt image has no password and refuses SSH logins until one is
# set. run-vm.sh forwards host port 2222 to the VM's SSH, so this works
# without touching the guest's network configuration.
#
set -eu

PORT=${SSH_PORT:-2222}
DEST=${DEST:-/root/school-filter}
HOST=root@${VM_HOST:-127.0.0.1}
RUN=no

[ "${1:-}" = "--run" ] && RUN=yes

SRC=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# A fresh guest regenerates host keys, so a remembered key for 127.0.0.1:2222
# from a previous VM will look like an attack. Keep this VM's key out of the
# real known_hosts rather than disabling checking everywhere.
KNOWN=$SRC/.vm/known_hosts
mkdir -p "$SRC/.vm"
COMMON="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KNOWN"
# ssh takes -p for the port, scp takes -P. Using the wrong one makes scp treat
# the port number as a filename.
SSHOPTS="$COMMON -p $PORT"
# -O forces the legacy SCP protocol. Modern scp defaults to SFTP, and OpenWrt's
# dropbear ships no sftp-server, so without this every copy fails with
# "/usr/libexec/sftp-server: not found".
SCPOPTS="$COMMON -P $PORT -O"

echo "Copying to $HOST:$DEST (port $PORT) ..."
# shellcheck disable=SC2086
ssh $SSHOPTS "$HOST" "mkdir -p $DEST" </dev/null

for d in rewriter squid blocklists scripts certpage portal; do
  # shellcheck disable=SC2086
  scp $SCPOPTS -r "$SRC/$d" "$HOST:$DEST/" >/dev/null
done

echo "Copied: rewriter squid blocklists scripts certpage portal"

if [ "$RUN" = yes ]; then
  echo
  # shellcheck disable=SC2086
  ssh $SSHOPTS "$HOST" "cd $DEST && sh scripts/setup-filter.sh" </dev/null
else
  echo
  echo "Next, on the VM:"
  echo "  cd $DEST && sh scripts/setup-filter.sh"
fi
