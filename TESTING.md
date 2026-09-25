# Testing the filter

Two environments. The VM pair needs nothing but QEMU and runs unattended; the
bridged setup filters traffic from real phones and laptops and needs `sudo`.

Everything below was run on an Apple M2 (8 GB) on 2026-09-25.

## Environment A — two VMs, fully automated

Proves the whole chain: transparent interception, TLS bump of Google only,
URL rewriting, DNS forcing, QUIC blocking.

```
   Mac
    │  QEMU user-mode NAT  (the filter's uplink)
┌───┴──────────────────────┐
│ filter VM   eth0 = WAN   │   OpenWrt 25.12.5 + Squid + udm14.lua
│             eth1 = LAN   │   192.168.1.1
└───┬──────────────────────┘
    │  QEMU socket network (a virtual cable)
┌───┴──────────┐
│ client VM    │  DHCP client, no proxy settings at all
└──────────────┘
```

### Run it

```sh
brew install qemu

# terminal 1 -- filter
./scripts/run-vm.sh
# press Enter at the console, then:
#   copy this repo onto the device and run scripts/setup-filter.sh

# terminal 2 -- client
./scripts/run-client-vm.sh
# press Enter, then switch it to DHCP:
uci set network.lan.proto='dhcp'
uci -q delete network.lan.ipaddr
uci -q delete network.lan.netmask
uci commit network && /etc/init.d/network restart
```

`setup-filter.sh` is idempotent, so re-running it is safe and prints
`(already done)` for each step it can skip.

### What to check

On the client, with the CA installed at `/tmp/ca.crt`:

```sh
# Google: AI Mode rewritten away
curl -i --cacert /tmp/ca.crt 'https://www.google.com/search?q=photosynthesis&udm=50'
#   HTTP/1.1 302 Found
#   Location: https://www.google.com/search?q=photosynthesis&udm=14

# Everything else: untouched, and works without the CA
curl -o /dev/null -w '%{http_code}\n' https://www.instagram.com/     # 200

# DNS cannot escape
nslookup example.com 8.8.8.8      # still answered, by the local resolver
```

On the filter, confirm rules are actually being hit rather than merely loaded:

```sh
tail /var/log/squid/access.log
nft list table inet fw4 | grep schoolfilter
```

Measured on a clean run: `schoolfilter-http` 1 packet, `schoolfilter-https`
3 packets, `schoolfilter-dns` 5 packets, `schoolfilter-drop-quic` 3 packets.
A rule sitting at `packets 0` after a test means it is not wired in --
see the note about `/etc/nftables.d` in `squid/SETUP-NOTES.md`.

### Getting files onto the VM

There is no SSH password on a fresh image and no HTTP server on the host, so
the serial console is the transfer channel. A quoted heredoc moves a text file
verbatim; check with `md5sum` on both sides. A fresh image has neither
`openssl` nor a `base64` applet, so do not plan on decoding anything until
after `setup-filter.sh` has installed packages.

## Environment B — real devices, no extra hardware

Filters a real phone or laptop through the VM. Needs `sudo`, because bridging
a VM onto a physical interface uses Apple's vmnet framework.

```
home router 192.168.0.1
    │  Wi-Fi
   Mac en0 ──── vmnet-bridged ──── filter VM  192.168.0.50
    │                                   │
    └── QEMU user NAT (filter's uplink) ┘

test device: gateway and DNS set manually to 192.168.0.50
```

The filter's uplink stays on QEMU's NAT rather than the bridged interface, so
traffic goes device → VM → Mac → internet, and never hairpins back through
the home router.

### Run it

1. Pick a free address on your LAN and turn the VM's DHCP server **off**, so
   it cannot fight your home router. On the filter VM:

   ```sh
   cat >> /etc/school-filter.conf <<'EOF'
   LAN_ADDR=192.168.0.50
   LAN_CIDR=192.168.0.0/24
   LAN_DHCP=off
   EOF
   sh scripts/setup-filter.sh
   ```

2. Boot with the LAN side bridged:

   ```sh
   sudo ./scripts/run-vm.sh --bridged en0
   ```

3. On the test device, set the gateway and DNS to `192.168.0.50` by hand, and
   install the CA from `/etc/squid/ssl/ca.crt`.

### Caveats

- **Two DHCP servers on one segment will break your home network.** `LAN_DHCP=off`
  is not optional here.
- macOS Wi-Fi bridging is less reliable than wired. This Mac has no Ethernet
  port, so `en0` (Wi-Fi) is the only option without a USB adapter.
- A device whose gateway is not changed is not filtered at all. This setup
  cannot enforce anything; it only demonstrates the filter on a willing device.
- Only this arrangement can answer the questions the VMs cannot: whether iOS
  and Android trust the CA, whether Android apps ignore it, whether name
  constraints are honored, and what Google's background `/search` requests
  look like in a real browser.
