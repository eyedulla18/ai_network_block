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

`run-vm.sh` forwards host port 2222 to the VM's SSH. Two things have to be true
before that works.

**1. Give yourself a login.** Either set a password at the VM console:

```sh
passwd
```

or install your key, which avoids typing it on every copy:

```sh
# at the VM console, with your public key pasted in
mkdir -p /etc/dropbear
printf '%s\n' 'ssh-ed25519 AAAA... you@host' > /etc/dropbear/authorized_keys
chmod 600 /etc/dropbear/authorized_keys
```

**2. Open SSH on the WAN side — TEST ONLY.** The port forward arrives on `eth0`,
which `setup-filter.sh` puts in the WAN zone, and OpenWrt rejects WAN input by
default. Without this rule SSH fails with `kex_exchange_identification:
Connection closed`, which looks like an authentication problem but is not.

```sh
uci set firewall.testssh=rule
uci set firewall.testssh.name='TEST-ONLY-ssh-from-wan'
uci set firewall.testssh.src='wan'
uci set firewall.testssh.proto='tcp'
uci set firewall.testssh.dest_port='22'
uci set firewall.testssh.target='ACCEPT'
uci commit firewall && /etc/init.d/firewall restart
```

**Never do this on a deployed box.** On real hardware the WAN side faces the
Starlink router; this would expose the filter's SSH to it. Remove it with
`uci delete firewall.testssh` before deploying, and manage a real device from
the LAN side or the console.

Then, from the Mac:

```sh
./scripts/push-to-vm.sh --run     # copies the repo and runs setup-filter.sh
```

The VM's host key goes in `.vm/known_hosts`, not your real one, since a rebuilt
VM regenerates its keys and would otherwise look like an attack.

If SSH is not an option, the serial console is the fallback: a quoted heredoc
moves a text file verbatim, and `md5sum` on both sides confirms it. Note that a
fresh image has neither `openssl` nor a `base64` applet, so nothing can be
decoded until `setup-filter.sh` has installed packages.

## Environment B — real devices (your phone), no extra hardware

Filters a real phone through the VM. Needs `sudo` once, because bridging a VM
onto a physical interface uses Apple's vmnet framework.

```
home router 192.168.1.1
    │  Wi-Fi
   Mac en0 ──── vmnet-bridged ──── filter VM  192.168.1.50
    │                                   │
    └── QEMU user NAT (filter's uplink) ┘

phone: gateway and DNS set by hand to 192.168.1.50
```

The filter's uplink stays on QEMU's NAT, so traffic goes phone → VM → Mac →
internet and never hairpins back through the home router.

### Steps

**1. Pick a free address and switch the config.** On the filter VM:

```sh
cd /root/school-filter
sh scripts/bridged-mode.sh 192.168.1.50
```

This sets `LAN_ADDR`, `LAN_CIDR` and `LAN_DHCP=off` together and re-runs
`setup-filter.sh`. It refuses the `.1` of the subnet, anything that is not an
IPv4 address, and any address already answering on the network.

**2. Relaunch bridged.** On the Mac, stop the VM (`poweroff` at its console),
then:

```sh
sudo ./scripts/run-vm.sh --bridged en0
```

**3. Point the phone at it.** In the Wi-Fi network's settings, set **both**:

| | |
|---|---|
| Router / Gateway | `192.168.1.50` |
| DNS | `192.168.1.50` |

On iOS: Settings → Wi-Fi → (i) → Configure IP → Manual. On Android:
long-press the network → Modify → Advanced → IP settings → Static.

**4. Install the certificate.** Open `http://192.168.1.50:8080/` on the phone.
The page detects the OS and shows only the relevant steps. iOS gets a
`.mobileconfig` served as `application/x-apple-aspen-config`, which opens
directly in Settings; everything else gets the `.crt`.

iOS needs the extra step the page calls out: **Settings → General → About →
Certificate Trust Settings**, then enable the switch. The certificate does
nothing until that is on.

**5. Test.** Search on Google. AI Overviews and AI Mode should be gone, and
`chatgpt.com` should not resolve.

### Why port 8080 and not 80

The firewall redirects LAN port 80 into Squid, so a page served on port 80
would be proxied rather than delivered. The certificate page has to live
outside the redirected ports, or a device without the certificate could not
reach the thing that fixes it.

### Caveats

- **Two DHCP servers on one segment will break your home network.**
  `bridged-mode.sh` sets `LAN_DHCP=off` for you; do not turn it back on while
  bridged.
- macOS Wi-Fi bridging is less reliable than wired. This Mac has no Ethernet
  port, so `en0` is the only option without a USB adapter. If the VM cannot
  get traffic over the bridge, that is the first thing to suspect.
- **Only devices you point at the filter by hand are filtered.** This proves
  the filter works; it does not enforce anything.
- Remove the test-only WAN SSH rule before this ever goes near real hardware:
  `uci delete firewall.testssh && uci commit firewall && /etc/init.d/firewall restart`

### Going back to the two-VM lab

```sh
sed -i '/^LAN_ADDR=/d; /^LAN_CIDR=/d; /^LAN_DHCP=/d' /etc/school-filter.conf
printf 'LAN_ADDR=192.168.1.1\nLAN_CIDR=192.168.1.0/24\nLAN_DHCP=server\n' >> /etc/school-filter.conf
sh scripts/setup-filter.sh
```

Then relaunch with plain `./scripts/run-vm.sh`.

### What only this environment can answer

Whether iOS and Android actually trust the CA, whether Android apps ignore it,
whether X.509 name constraints are honored on a user-installed CA, and what
Google's background `/search` requests look like in a real browser. None of
that can be established from a VM with curl.
