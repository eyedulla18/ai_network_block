#!/bin/sh
#
# Switch the filter to bridged mode, for testing with real phones and laptops.
# Runs ON the filter VM.
#
#   sh scripts/bridged-mode.sh 192.168.1.50
#
# In bridged mode the filter's LAN side sits on your real network instead of a
# private one, so a phone can use it as a gateway. Two things must be true, and
# this script enforces both:
#
#   * a free address on your LAN, not the router's
#   * the DHCP server OFF -- two DHCP servers on one segment hand out
#     conflicting leases and break the network for everyone on it
#
# Afterwards, relaunch the VM on the Mac with:
#   sudo ./scripts/run-vm.sh --bridged en0
#
set -eu

ADDR=${1:-}
[ -n "$ADDR" ] || { echo "usage: $0 <free-ip-on-your-lan>   e.g. $0 192.168.1.50" >&2; exit 1; }

echo "$ADDR" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || {
  echo "not an IPv4 address: $ADDR" >&2; exit 1; }

CIDR=${2:-$(echo "$ADDR" | sed 's/\.[0-9]*$/.0\/24/')}

# Refuse the .1 of the subnet. It is almost always the home router, and taking
# its address would black-hole the whole network.
case "$ADDR" in
  *.1) echo "refusing $ADDR: .1 is nearly always your router. Pick something like ${ADDR%.1}.50" >&2; exit 1 ;;
esac

# Refuse anything already answering on the LAN.
if ping -c1 -W2 "$ADDR" >/dev/null 2>&1; then
  echo "refusing $ADDR: something already answers on that address" >&2
  exit 1
fi

CONF=/etc/school-filter.conf
touch "$CONF"
# Drop any previous values, then append the new ones.
sed -i '/^LAN_ADDR=/d; /^LAN_CIDR=/d; /^LAN_DHCP=/d' "$CONF"
cat >> "$CONF" <<EOF
LAN_ADDR=$ADDR
LAN_CIDR=$CIDR
LAN_DHCP=off
EOF

echo "Set LAN_ADDR=$ADDR  LAN_CIDR=$CIDR  LAN_DHCP=off"
echo "Applying ..."
SRC=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
sh "$SRC/scripts/setup-filter.sh"

cat <<EOF

Bridged mode is configured. Next:

  1. On the Mac, stop this VM and relaunch it bridged:
         sudo ./scripts/run-vm.sh --bridged en0

  2. On the phone, in the Wi-Fi network's settings, set BOTH:
         Router / Gateway : $ADDR
         DNS              : $ADDR

  3. On the phone, open:
         http://$ADDR:${CERT_PORT:-8080}/
     and follow the instructions to install the certificate.

  4. Search on Google. AI Overviews and AI Mode should be gone.

Nothing on your network is filtered except devices you point at $ADDR by hand.
EOF
